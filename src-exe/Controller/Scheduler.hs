{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE StrictData        #-}

-- WARNING: the code that follows will make you cry;
--          a safety pig is provided below for your benefit.
--
--                           _
--   _._ _..._ .-',     _.._(`))
--  '-. `     '  /-._.-'    ',/
--     )         \            '.
--    / _    _    |             \
--   |  a    a    /              |
--   \   .-.                     ;
--    '-('' ).-'       ,'       ;
--       '-;           |      .'
--          \           \    /
--          | 7  .__  _.-\   \
--          | |  |  ``/  /`  /
--         /,_|  |   /,_/   /
--            /,_/      '`-'
--

-- |
-- Copyright: © 2018 Herbert Valerio Riedel
-- SPDX-License-Identifier: GPL-3.0-or-later
--
module Controller.Scheduler (runScheduler) where

import           Prelude.Local

import           Control.Concurrent
import qualified Control.Concurrent.FairRWLock           as RW
import           Control.Concurrent.STM

import           Control.Monad.Except
import qualified Data.Aeson                              as J
import qualified Data.Map.Strict                         as Map
import           Data.Pool
import qualified Data.Set                                as Set
import qualified Data.Text                               as T
import qualified Database.PostgreSQL.Simple              as PGS
import qualified Database.PostgreSQL.Simple.Notification as PGS
import           Database.PostgreSQL.Simple.Types        (Only (..))
import           Servant
import           Servant.Client.Core                     (BaseUrl (..))

import           Controller.Api
import           Controller.Db
import           Job
import           Log
import           PkgId
import           PlanJson                                as PJ
import           Text.Printf                             (printf)
import           WorkerApi
import           WorkerApi.Client

data App = App
  { appDbPool       :: Pool PGS.Connection
  , appQThreads     :: RW.RWLock
  , appWorkers      :: [(BaseUrl,CompilerID)]
  , appWorkerIdleEv :: TMVar ()
  , appDbEvents     :: TChan DbEvent
  , appNeedFwdProp  :: MVar ()
  }

runScheduler :: PGS.ConnectInfo -> [(BaseUrl,CompilerID)] -> IO ()
runScheduler ci appWorkers = do
    logInfo "Starting scheduler..."

    appDbPool       <- createPool mkConn killConn 1 10.5 4
    appQThreads     <- RW.new
    appWorkerIdleEv <- newEmptyTMVarIO
    appDbEvents     <- newBroadcastTChanIO
    appNeedFwdProp  <- newMVar ()

    let app = App{..}

    _threadid <- forkIO (scheduler app)

    ex <- try $ forever (threadDelay 10000000)

    case ex of
      Left UserInterrupt -> logInfo "Ctrl-C received... (a 2nd ctrl-c will terminate instantly!)"
      Left e             -> throwIO e
      Right _            -> fail "the impossible happened"

    logInfo "waiting for scheduler to halt..."
    RW.acquireWrite appQThreads
    logInfo "...halted!"

    pure ()
  where
    mkConn = do
        logDebug "opening new dbconn"
        PGS.connect ci

    killConn c = do
        logDebug "closing a dbconn"
        PGS.close c


data DbEvent = DbEventQueue
             | DbEventPkgIdx
             deriving (Eq,Show)

waitForEv :: TChan DbEvent -> (DbEvent -> Bool) -> IO ()
waitForEv bchan f = do
    ev <- atomically (readTChan bchan)
    unless (f ev) $
        waitForEv bchan f

flushEvs :: TChan DbEvent -> IO ()
flushEvs bchan = do
    mev <- atomically $ tryReadTChan bchan
    unless (mev == Nothing) $
        flushEvs bchan

eventListener :: PGS.Connection -> TChan DbEvent -> IO ()
eventListener dbconn bchan = do
    _ <- PGS.execute_ dbconn "LISTEN table_event";
    forever $ do
        n@PGS.Notification{..} <- PGS.getNotification dbconn
        logDebug (tshow n)
        when (notificationChannel == "table_event") $ do
            case notificationData of
              "queue"    -> atomically (writeTChan bchan DbEventQueue)
              "pkgindex" -> atomically (writeTChan bchan DbEventPkgIdx)
              _          -> pure () -- noop

-- | Auto-queues recent pkgindex additions
autoQueuer :: App -> IO ()
autoQueuer App{..} = do
    bchan <- atomically (dupTChan appDbEvents)

    forever $ do
        -- auto-queue recent uploads/revisions; we preemptively avoid
        -- queueing a (pname,ptime) entry if it's already in the queue
        -- to avoid redundant trigger activations
        withResource appDbPool $ \dbconn -> do
            recentPkgs <- PGS.query_ dbconn
                          "(SELECT pname,max(ptime) mptime FROM pkgindex GROUP BY pname ORDER BY mptime DESC LIMIT 70) EXCEPT (SELECT pname,ptime FROM queue)"
--                          "SELECT pname,max(ptime) mptime FROM pkgindex WHERE pname NOT IN (SELECT pname FROM queue) AND ptime > (SELECT max(ptime) FROM pkgindex)-2*86400 GROUP BY pname ORDER BY mptime DESC LIMIT 50"

            forM_ recentPkgs $ \(pname,ptime) -> do
                todo <- isJust <$> queryNextJobTask dbconn allCompilerIds pname ptime
                when todo $ do
                    tmp <- PGS.execute dbconn "INSERT INTO queue(pname,prio,ptime) VALUES (?,-11,?) ON CONFLICT DO NOTHING" (pname,ptime)
                    logInfo ((if tmp == 0 then "NOT adding" else "Adding ") <> tshow (pname,ptime) <> " to queue... ")

        waitForEv bchan (== DbEventPkgIdx)
        flushEvs bchan
  where
    allCompilerIds = map snd appWorkers

-- | Auto-queues least recently built packages
autoQueuer2 :: App -> IO ()
autoQueuer2 App{..} = forever $ do
    atomically $ takeTMVar appWorkerIdleEv

    cnt1 <- withResource appDbPool $ \dbconn -> do
        toInsert <- PGS.query_ dbconn "(SELECT t.pname FROM (SELECT pname FROM pname_max_ptime WHERE pname NOT IN (SELECT pname FROM QUEUE) GROUP BY pname ORDER BY max(ptime)) t WHERE (SELECT count(*) FROM queue) < 30) LIMIT 2"

        if null toInsert
            then pure 0
            else PGS.executeMany dbconn "INSERT INTO queue(pname,prio) VALUES (?,?) ON CONFLICT DO NOTHING"
                                        [ (pname::Text, -50::Int) | Only pname <- toInsert ]

    logDebug ("Worker got IDLE! " <> tshow cnt1)

-- | Forward-propagator thread
fwdPropagator :: App -> IO ()
fwdPropagator App{..} = forever $ do
    takeMVar appNeedFwdProp

    -- forward-propagate fail_deps
    withResource appDbPool $ \dbconn -> whileM_ $ do
        -- TODO: this is costly
        -- instead use 'row1' or a RETURNING clause as seed for traversing
        (dt5,foo5) <- timeIt $ PGS.execute_ dbconn
                      "UPDATE iplan_unit SET bstatus = 'fail_deps' \
                      \WHERE xunitid IN (SELECT DISTINCT a.xunitid FROM iplan_unit a \
                                        \JOIN iplan_comp_dep ON (a.xunitid = parent) \
                                        \JOIN iplan_unit b ON (b.xunitid = child) \
                                        \WHERE a.bstatus IS NULL AND b.bstatus IN ('fail','fail_deps'))"
        logDebug ("iplan_unit UPDATE => " <> tshow (foo5,dt5))
        pure (foo5 /= 0)

    pure ()

-- background thread
scheduler :: App -> IO ()
scheduler App{..} = do
    -- initalise 'workers' table
    withResource appDbPool $ \dbconn -> do
        -- TODO: implement mutex in db with
        -- SELECT pg_try_advisory_lock(1);

        void $ PGS.execute_ dbconn "DELETE FROM worker";
        void $ PGS.executeMany dbconn "INSERT INTO worker(wid,wstate) VALUES (?,?)"
                                      [ (wid,"idle"::Text) | (wid,_) <- appWorkers' ]

    _ <- forkIO $ withResource appDbPool $ \dbconn -> eventListener dbconn appDbEvents

    void $ forkIO $ autoQueuer     App{..}
    void $ forkIO $ autoQueuer2    App{..}
    void $ forkIO $ fwdPropagator  App{..}

    -- startup worker threads
    _thrIds <- forM appWorkers' $ \(wid,(wuri,cid)) -> forkIO (forever $ go appDbEvents wid wuri cid)


    forever $ do
        -- logInfo ("MARK")

        withResource appDbPool $ \dbconn -> do
            qents <- queryQEntries dbconn
            forM_ qents $ \QEntryRow{..} -> do
                queryNextQTask dbconn allCompilerIds QEntryRow{..} >>= \case
                    Nothing -> do
                        logDebug ("deleting completed " <> tshow QEntryRow{..})
                        deleteQEntry dbconn QEntryRow{..}

                    Just _ -> pure ()

        threadDelay 3000000
  where
    appWorkers' = zip [0::Int ..] appWorkers
    allCompilerIds = map snd appWorkers

    go dbEvChan0 wid wuri cid = RW.withRead appQThreads $ do
        dbEvChan <- atomically (dupTChan dbEvChan0)
        mtask <- withResource appDbPool $ \dbconn -> do
            qents <- queryQEntries dbconn
            firstJustM (queryNextQTask dbconn [cid]) qents

        case mtask of
          Nothing -> do
              logInfo ("nothing to do left in queue; sleeping a bit... " <> tshow cid)
              void $ atomically (tryPutTMVar appWorkerIdleEv ())
              waitForEv dbEvChan (== DbEventQueue)

          Just js -> go2 wid wuri js

    -- initWJob :: JobSpec -> Int -> BaseUrl -> IO _
    initWJob jspec@(JobSpec pid@(PkgId pname pver) idxts gv) wid wuri = do
        logJob jspec "Initialising"
        withResource appDbPool $ \dbconn ->
            void $ PGS.execute dbconn ("UPDATE worker SET mtime = DEFAULT, wstate = 'init', pname = ?, pver = ?, ptime = ?, compiler = ? WHERE wid = ?") (pname, pver, idxts, gv, wid)

        CreateJobRes wjid <- either (fail . show) pure =<< runExceptT
                             (runClientM' wuri $ createJob (CreateJobReq gv (Just idxts) pid))
        pure (wjid,wid,wuri)

    doneWJob gv (wjid,wid,wuri) = do
        NoContent <- either (fail . show) pure =<< runExceptT (runClientM' wuri $ destroyJob wjid)

        withResource appDbPool $ \dbconn ->
            void $ PGS.execute dbconn ("UPDATE worker SET mtime = DEFAULT, wstate = 'idle', pname = NULL, pver = NULL, ptime = NULL, compiler = NULL WHERE wid = ?") (Only wid)

        pis <- either (fail . show) pure =<< runExceptT (runClientM' wuri $ listPkgDbStore gv)
        let pisLen = length pis
        logDebug $ mconcat ["store size[", tdisplay gv, "] = ", tshow pisLen]

        when (pisLen > 1000) $ do
            NoContent <- either (fail . show) pure =<< runExceptT (runClientM' wuri $ destroyPkgDbStore gv)
            pure ()

    go2 :: Int -> BaseUrl -> JobSpec -> IO ()
    go2 wid0 wuri0 jspec@(JobSpec pid idxts ghcver) =
      bracket (initWJob jspec wid0 wuri0)
              (doneWJob ghcver)
              $ \(wjid,wid,wuri) -> do

        withResource appDbPool $ \dbconn ->
            void $ PGS.execute dbconn ("UPDATE worker SET mtime = DEFAULT, wstate = 'solve' WHERE wid = ?") (Only wid)

        sinfo <- either (fail . show) pure =<< runExceptT
                 (runClientM' wuri $ getJobSolveInfo wjid)

        let PkgId pidn pidv = pid

        let logDbAction :: String -> Int -> IO Int64 -> IO ()
            logDbAction msg l0 act = do
              (dt0,l0') <- timeIt act
              logJob jspec $ T.pack (printf "%s -> %d/%d %.3fs" msg l0' l0 dt0)
              pure ()

        case jpPlan sinfo of
          Nothing -> do
              case jpSolve sinfo of
                Nothing -> do
                    logJob jspec "fetch-step failed? WTF?!?"
                    withResource appDbPool $ \dbconn -> do
                        _ <- PGS.execute dbconn (doNothing "INSERT INTO pkg_blacklist(pname,pver) VALUES (?,?)") (pidn,pidv)
                        pure ()
                Just solvejs -> do
                    withResource appDbPool $ \dbconn -> do
                        foo1 <- PGS.execute dbconn (doNothing "INSERT INTO solution_fail(ptime,pname,pver,compiler,solvererr,dt) VALUES (?,?,?,?,?,?)")
                                (idxts,pidn,pidv,ghcver,jsLog solvejs,jsDuration solvejs)
                        logJob jspec ("solution_fail insert -> " <> tshow foo1) --print (jsLog solvejs)
          Just jplan -> do
              pj <- case J.fromJSON jplan of
                      J.Error e   -> fail e
                      J.Success x -> pure x

              -- compute job-id from plan.json only
              let dbunits0 = planJson2DbUnitComps mempty pj
                  dbJobUids = sort [ xuid | (DB_iplan_unit xuid _ _ PILocal pn pv _ _ _ _,_) <- dbunits0
                                          , pn == pidn, pv == pidv ]
                  dbJobId = toUUID (display pid, display (pjCompilerId pj), pjOs pj, pjArch pj, dbJobUids) -- maybe hash over jplan?

              -- check whether job-id already exists in DB
              -- TODO: check whether we need to (re)compute results
              (jobExists, jobNeedsRecomp) <- withResource appDbPool $ \dbconn -> (,) <$> queryJobExists dbconn dbJobId
                                                                                     <*> queryJobNeedsRecomp dbconn dbJobId

              logJob jspec $ mconcat
                  [ "Job ", tshow dbJobId
                  , if jobExists then " exists already!" else " doesn't exist already"
                  , if jobNeedsRecomp then " ... BUT NEEDS RECOMPUTING!!!!" else ""
                  ]

              unless (jobExists && not jobNeedsRecomp) $ do
                  withResource appDbPool $ \dbconn ->
                    void $ PGS.execute dbconn ("UPDATE worker SET mtime = DEFAULT, wstate = 'build-deps' WHERE wid = ?") (Only wid)

                  bdinfo <- either (fail . show) pure =<< runExceptT
                            (runClientM' wuri $ getJobBuildDepsInfo wjid)

                  withResource appDbPool $ \dbconn ->
                    void $ PGS.execute dbconn ("UPDATE worker SET mtime = DEFAULT, wstate = 'build' WHERE wid = ?") (Only wid)

                  binfo <- either (fail . show) pure =<< runExceptT
                           (runClientM' wuri $ getJobBuildInfo wjid)

                  withResource appDbPool $ \dbconn ->
                    void $ PGS.execute dbconn ("UPDATE worker SET mtime = DEFAULT, wstate = 'done' WHERE wid = ?") (Only wid)

                  let stats0 =
                          Map.fromList [ (k,(if k `Set.member` (jrFailedUnits bdinfo <> jrFailedUnits2 binfo) then IPBuildFail else IPOk,v))
                                       | (k,v) <- Map.toList $ (jrBuildLogs bdinfo <> jrBuildLogs2 binfo)
                                       ]
                          `mappend` -- NB: first entry is retained
                          Map.fromList [ (k,(IPBuildFail,"")) | k <- (Set.toList $ jrFailedUnits bdinfo <> jrFailedUnits2 binfo) ]

                      stats = Map.fromList [ (k,(st,lm,Map.lookup k (jrBuildTimes bdinfo <> jrBuildTimes2 binfo)))
                                           | (k,(st,lm)) <- Map.toList stats0 ]

                  -- compute real dbunits
                  let dbunits = planJson2DbUnitComps stats pj

                  withResource appDbPool $ \dbconn -> do
                      let rows1 = map fst dbunits
                      -- TODO: use COALESCE() in ON CONFLICT clause?

                      logDbAction "iplan_unit insert" (length rows1) $
                        PGS.executeMany dbconn (db_iplan_unit_insert `mappend`
                                                      " ON CONFLICT (xunitid) \
                                                      \ DO UPDATE SET bstatus = EXCLUDED.bstatus, logmsg = EXCLUDED.logmsg, dt = EXCLUDED.dt \
                                                      \ WHERE iplan_unit.bstatus IS NULL") $
                              rows1

                      -- TODO: update entries with NULL status

                      let rows2 = concatMap snd dbunits
                      logDbAction "iplan_comp_dep insert" (length rows2) $
                        PGS.executeMany dbconn (doNothing db_iplan_comp_dep_insert) rows2

                      logDbAction "iplan_job insert" 1 $
                        PGS.execute dbconn (doNothing db_iplan_job_insert) $
                              DB_iplan_job dbJobId pidn pidv (pjCompilerId pj) jplan (UUIDs dbJobUids)

                      -- trigger forward-propagate fail_deps
                      void $ tryPutMVar appNeedFwdProp ()

              -- in any case, register a solution now
              withResource appDbPool $ \dbconn -> do
                  logDbAction "solution insert" 1 $
                    PGS.execute dbconn (doNothing "INSERT INTO solution(ptime,jobid,dt) VALUES (?,?,?)")
                          (idxts,dbJobId,jsDuration <$> jpSolve sinfo)

queryNextQTask :: PGS.Connection -> [CompilerID] -> QEntryRow -> IO (Maybe JobSpec)
queryNextQTask dbconn cids q0 = queryNextJobTask dbconn cids (qrPkgname q0) (qrIdxstate q0)

timeIt :: IO a -> IO (Double,a)
timeIt act = do
    t0 <- getPOSIXTime
    res <- act
    t1 <- getPOSIXTime
    let dt = realToFrac (t1-t0)
    pure $! seq dt (dt,res)


logJob :: JobSpec -> Text -> IO ()
logJob (JobSpec pid idxts gv) msg = do
    let pfx = concat [display pid, "@", fmtPkgIdxTs idxts, "/", display gv, " >>> "]
    logInfo $ T.pack pfx <> msg

planItemAllDeps :: PlanItem -> Set UnitID
planItemAllDeps PlanItem{..} = mconcat [ ciLibDeps <> ciExeDeps | CompInfo{..} <- Map.elems piComps ]

planJsonIdGrap :: PlanJson -> Map UnitID (Set UnitID)
planJsonIdGrap PlanJson{..} = Map.map planItemAllDeps pjItems

-- NB: emits DB rows in topological order, i.e. not violating FK-constraints
-- TODO: compute/propagate fail-deps?
planJson2DbUnitComps :: Map UnitID (IPStatus,Text,Maybe NominalDiffTime) -> PlanJson -> [(DB_iplan_unit,[DB_iplan_comp_dep])]
planJson2DbUnitComps smap PlanJson{..} = go mempty topoUnits
    -- let rootunits = [ piId | PlanItem{..} <- Map.elems pjItems, piType == PILocal ]
    -- print rootunits
    -- let topoUnits = toposort (planJsonIdGrap PlanJson{..})
    -- forM_ topoUnits print
    -- mapM_ (logInfo . groom) $ go mempty topoUnits
  where
    topoUnits = toposort (planJsonIdGrap PlanJson{..})

    go :: (Map UnitID UUID) -> [UnitID] -> [(DB_iplan_unit,[DB_iplan_comp_dep])]
    go _ [] = []
    go m (uid0:uids) = (DB_iplan_unit xuid piId pjCompilerId piType pn pv jflags pkind logmsg dt, cs)
                       : go (Map.insert uid0 xuid m) uids
      where
        xuid = case piType of
                 -- short-cut, we trust the unit-id for global packages to be unique within comp/os/arch
                 PIGlobal -> toUUID (unUnitID uid0,display pjCompilerId,pjOs,pjArch)
                 -- in all other cases, the unit-id is not unique outside plan.json
                 _ -> toUUID (unUnitID uid0,display piPId,display pjCompilerId,pjOs,pjArch,piType,Map.toAscList piFlags,cs')

        pkind = stat ^? _Just._1

        logmsg = case stat ^? _Just._2 of
                   Nothing -> Nothing
                   Just "" -> Nothing
                   Just t  -> Just t

        dt = stat ^? _Just._3._Just

        stat = case piType of
                 PIBuiltin -> Just (IPOk,"",Nothing)
                 _         -> Map.lookup uid0 smap

        Just PlanItem{..} = Map.lookup uid0 pjItems
        PkgId pn pv = piPId

        jflags = toJSON piFlags

        cs' = [ (cn,(sort $ map lupUUID $ Set.toList ciLibDeps),(sort $ map lupUUID $ Set.toList ciExeDeps))
              | (cn,CompInfo{..}) <- Map.toAscList piComps ]

        -- cs = [ DB_iplan_comp xuid cn (UUIDs ldeps) (UUIDs edeps) | (cn,ldeps,edeps) <- cs' ]
        cs = [ DB_iplan_comp_dep xuid cn DepKindLib child  | (cn,ldeps,_) <- cs', child <- ldeps ] ++
             [ DB_iplan_comp_dep xuid cn DepKindExe child  | (cn,_,edeps) <- cs', child <- edeps ]

        lupUUID k = Map.findWithDefault (error "lupUUID") k m
