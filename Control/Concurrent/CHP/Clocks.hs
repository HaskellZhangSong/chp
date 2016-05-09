-- Communicating Haskell Processes.
-- Copyright (c) 2009, University of Kent.
-- All rights reserved.
-- 
-- Redistribution and use in source and binary forms, with or without
-- modification, are permitted provided that the following conditions are
-- met:
--
--  * Redistributions of source code must retain the above copyright
--    notice, this list of conditions and the following disclaimer.
--  * Redistributions in binary form must reproduce the above copyright
--    notice, this list of conditions and the following disclaimer in the
--    documentation and/or other materials provided with the distribution.
--  * Neither the name of the University of Kent nor the names of its
--    contributors may be used to endorse or promote products derived from
--    this software without specific prior written permission.
--
-- THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS
-- IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
-- THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
-- PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR
-- CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
-- EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
-- PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
-- PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
-- LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
-- NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
-- SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

-- | Clocks, based on an idea by Adam Sampson.
--
-- A clock is similar to a timer, but it is entirely concerned with logical
-- time, rather than any relation to actual time, and all clocks are entirely
-- independent.  A clock has the concept of enrollment, so at any time there
-- are N processes enrolled on the clock.  Each process may wait on the clock
-- for a specific time.  Once all N enrolled processes are waiting for a time
-- (giving a list of times Ts), the clock moves forward to the next time in
-- Ts.
--
-- Let's consider an example.  Three processes are enrolled on an Int clock.  The
-- current time of the clock is 0.  One process asks to wait for time 3, and blocks.
--  A second process asks to wait for time 5, and blocks.  Finally, the third process
-- waits for time 3.  At this point, the first and third process are free to proceed,
-- and the new clock time is 3.  The second process (waiting for time 5) stays
-- waiting until the two processes have returned and waited again.
--
-- There is also the option to wait for the next available time.  If our two enrolled
-- processes wait again, with the first waiting for time 7, and the third waiting for
-- the next available time, the second and third will wake up, with the new time
-- on the clock being 5 (the first stays waiting for time 7).
--
-- There is also the ability for time to wrap around.  If /all/ processes are
-- waiting for a time that is /before/ the current time (using less-than from
-- the Ord instance) or just the next available time, the earliest time of
-- those will be taken.  So if the current time is 26, and the processes are waiting
-- for 11, 21 and next available time, the first and third will wake up and the
-- new time will be 11.  This is particularly useful for using your own algebraic
-- type (@data Phase = PhaseA | PhaseB | PhaseC deriving (Eq, Ord)@).  If you want
-- to, you can use Integer and never use the time wrapping ability (see 'waitUnbounded').
--
-- What the units of a clock mean is entirely up to you.  The only requirement
-- is an Ord instance for comparing two times, to use the above rules.  The item
-- in a clock may be an Int, a Double, an Integer, or even types like Bool or Either,
-- your own types or newtypes, or things like lists!
--
-- The following rules apply to clocks:
--
-- * If there are no processes enrolled, the time never changes.
--
-- * Time never advances (and processes are never woken up) until all processes
-- enrolled on the clock have waited for a time (either the next available, or
-- a specific time).
-- 
-- * If all processes enrolled wait for the next available time, they will not
-- wake up (until another process enrolls and asks for a specific time).  To make
-- sure that time advances, use the 'Control.Concurrent.CHP.Common.advanceTime'
-- process.
-- 
-- * The clock always advances to the earliest (minimum) specific offer that is
-- stricly after the current time, unless:
-- 
-- * If all processes that are waiting for specific times, ask for times that
-- are before the current time, the earliest (minimum) of these is taken, and
-- thus time effectively moves backwards (wraps around).  In this case, all
-- processes waiting for the next time will also be woken up.
--
-- * As a consequence of all of the above, if you wait and return being told the
-- current time, that time cannot change until you next wait, or if you resign
-- from the clock (temporarily or permanently).
--
-- * Note that waiting for clocks cannot be used as part of a choice
-- ('Control.Concurrent.CHP.Alt.alt' and 'Control.Concurrent.CHP.Alt.every').
-- The semantics of allowing this are unclear.  If a clock waits for time 5,
-- but later backs out, should it be possible for two other processes to
-- advance the time to 3 in the mean-time?  Due to this, clocks cannot be used
-- in a choice.  If you want to have a choice involving a time change, have a
-- process that waits for the next available time, then sends it down a
-- channel to the process making the choice.
--
-- Clocks are similar to phased barriers (indeed, both have an instance of
-- 'Waitable').  The fundamental differences are:
--
-- * A barrier can only move one phase at a time.  If you use barriers to skip
-- past several phases at once, this will be much less efficient than using a clock.
-- This is also true if not every process enrolled on a barrier wants to take action
-- every phase -- a clock allows those processes to remain sleeping, rather than
-- wake up only to sleep again,
-- 
-- * Barriers support choice, but clocks do not.  This means clocks are both
-- less powerful, but also faster than barriers.
-- 
-- * Barriers choose their next phase using their incrementing function.  Clocks
-- are more flexible, in that their next phase is chosen solely by looking at the
-- requests from the various processes.  Hence why Double is a suitable type for
-- a Clock time, but not for a PhasedBarrier phase.
-- 
-- This whole module was first added in version 1.2.0.
module Control.Concurrent.CHP.Clocks (Clock, Waitable(..),
  waitUnbounded, newClock, newClockWithLabel) where

import Control.Concurrent.STM (STM, TVar, atomically, newTVar, readTVar, writeTVar)
import Control.Monad hiding (mapM, mapM_)
import Data.Foldable (mapM_)
-- Needed for testing:
--import Data.Maybe
import qualified Data.Sequence as Seq
import qualified Data.Set as Set
import Data.Unique
import Prelude hiding (mapM, mapM_)

import Control.Concurrent.CHP.Barriers
import Control.Concurrent.CHP.Base
import qualified Control.Concurrent.CHP.Event as Event
import Control.Concurrent.CHP.Enroll
import Control.Concurrent.CHP.Poison
import Control.Concurrent.CHP.ProcessId
import Control.Concurrent.CHP.Traces.Base

-- | A type-class for things that you can on for a specific time\/phase.  The
-- instance for 'PhasedBarrier' repeatedly syncs until the specific phase is
-- reached.  Clock waits until the time is reached.
class Waitable c where
  -- | Given an enrolled item, waits for the specific time\/phase (if
  -- you pass a Just value) or the next available time\/phase. (if you
  -- pass Nothing).  The value returned is the new current time.  Note that
  -- waiting for the current time\/phase or a past time\/phase on a
  -- clock\/barrier will /not/ return immediately -- see the rules at the top
  -- of this module, and see 'waitUnbounded'.
  wait :: Ord t => Enrolled c t -> Maybe t -> CHP t
  -- | Gets the current time\/phase.
  getCurrentTime :: Ord t => Enrolled c t -> CHP t

instance Waitable PhasedBarrier where
  wait eb Nothing = syncBarrier eb
  -- If they ask for the current time, they will always go around again, so we
  -- sync once then wait for the next phase (which may require no further syncs)
  wait eb (Just ph) = syncBarrier eb >> waitForPhase ph eb >> return ph
  getCurrentTime = currentPhase

{- This was perhaps an instance too far:
instance Waitable BroadcastChanin where
  wait ec Nothing = readChannel ec
  wait ec (Just t) = do x <- readChannel ec
                        if x == t
                          then return x
                          else wait ec (Just t)
  getCurrentTime = readChannel
-}

-- | A clock that measures time using the given type.  Only Ord is required on
-- the type, so it can be all sorts.  Obvious possibilities are numeric types such
-- as Int and Double -- if you want monotonically-increasing time, see 'waitUnbounded'.
--  Other possibilities include your own algebraic types, if you want a clock that
-- cycles around a given set of phases.  If every process enrolled on the clock
-- always just waits for the next time, you may want to consider using a 'PhasedBarrier'.
--  If you want a clock that works in reverse or anything else strange, you can
-- always wrap your type in a newtype to give a custom Ord instance.
--
-- See the documentation at the beginning of this module for more information on
-- clocks.
newtype Ord time => Clock time
  = Clock (TVar (WithPoison (TimerData time)), Unique, time -> String)

-- | Normally, when waiting on a clock, if you wait for a time equal to (or earlier
-- than) the current time, you will block until the clock wraps around.  Sometimes,
-- however, you may want your clock to never wrap around (and use Integer as the
-- inner type, usually), and want to make sure that if a process waits for the
-- current time or earlier, it returns instantly.  That is what this function achieves.
--
-- Calling this function with Nothing has indentical behaviour to calling 'wait'
-- with Nothing.  If you wait for the current time or earlier, all of the other
-- processes waiting on the clock will remain blocked.  Processes who have asked
-- to wait for the current time will remain blocked -- it is generally not useful
-- to mix 'waitUnbounded' and 'wait' on the same clock.
waitUnbounded :: (Waitable c, Ord t) => Enrolled c t -> Maybe t -> CHP t
waitUnbounded clock Nothing = wait clock Nothing
waitUnbounded clock (Just waitT)
  = do realT <- getCurrentTime clock
       if waitT <= realT
         then return realT
         else wait clock (Just waitT)

modifyTVar :: TVar (WithPoison a) -> (a -> a) -> STM (WithPoison ())
modifyTVar tv f = do x <- readTVar tv
                     case x of
                       PoisonItem -> return PoisonItem
                       NoPoison y -> do writeTVar tv $ NoPoison $ f y
                                        return $ NoPoison ()

modifyTVar' :: TVar (WithPoison a) -> (a -> STM a) -> STM (WithPoison ())
modifyTVar' tv f = do x <- readTVar tv
                      case x of
                        PoisonItem -> return PoisonItem
                        NoPoison y -> do f y >>= writeTVar tv . NoPoison
                                         return $ NoPoison ()


poisonTVar :: TVar (WithPoison a) -> STM ()
poisonTVar = flip writeTVar PoisonItem

type TimeVar time = TVar (WithPoison (Maybe (time, Integer)))

data TimerData time
  = TimerData {
      curTime :: time
     ,seqTime :: Integer
     ,enrolledOnTimer :: Int
     -- A slightly more efficient way of knowing current offers:
     ,offeredOnTimer :: Int
      -- Offers are held, sorted by time.  We rely on the fact that for all x,
      -- Nothing < Just x
     ,timerOffersNext :: Maybe ([ProcessId], TimeVar time)
     ,timerOffersBefore :: [([ProcessId], (time, TimeVar time))]
     ,timerOffersAfter :: [([ProcessId], (time, TimeVar time))]
     ,timerEventPool :: Seq.Seq (TimeVar time)
     }
-- Uncomment these lines while testing:
--  deriving (Eq, Show)
--instance Show (TVar (WithPoison (Maybe a))) where show = const "<tv>"

emptyTimerData :: time -> TimerData time
emptyTimerData t = TimerData t 0 0 0 Nothing [] [] Seq.empty

enrollTimerData :: Maybe (TimeVar time) -> TimerData time -> TimerData time
enrollTimerData me td
  = td {enrolledOnTimer = enrolledOnTimer td + 1
       -- It's important that the event goes on the front, so that we don't re-use
       -- the event at the back until necessary:
       ,timerEventPool = maybe id (Seq.<|) me $ timerEventPool td}

resignTimerData :: Bool -> TimerData time -> TimerData time
resignTimerData removeOneFromPool td
  = td {enrolledOnTimer = enrolledOnTimer td - 1
       ,timerEventPool = case (Seq.viewl $ timerEventPool td, removeOneFromPool) of
         (_ Seq.:< es, True) -> es
         _ -> timerEventPool td}

poisonTimerData :: TimerData time -> STM ()
poisonTimerData td
  = do mapM_ (poisonTVar . snd . snd) (timerOffersAfter td)
       mapM_ (poisonTVar . snd . snd) (timerOffersBefore td)
       maybe (return ()) (poisonTVar . snd) (timerOffersNext td)
       mapM_ poisonTVar $ timerEventPool td

-- Gets the first spare event and makes sure the value is empty:
spareEvent :: Seq.Seq (TVar (WithPoison (Maybe a)))
  -> STM (TVar (WithPoison (Maybe a)), Seq.Seq (TVar (WithPoison (Maybe a))))
spareEvent evs = case Seq.viewl evs of
      (e Seq.:< es) -> do writeTVar e $ NoPoison Nothing
                          return (e, es)
      _ -> error "Event pool unexpectedly depleted"


offerTimerData :: forall time. Ord time => ProcessId -> Maybe time -> TimerData time
  -> STM (TimerData time, TimeVar time)
offerTimerData pid Nothing td = case timerOffersNext td of
  Nothing -> do
    (e, pool) <- spareEvent $ timerEventPool td
    return (td { offeredOnTimer = offeredOnTimer td + 1
               , timerOffersNext = Just ([pid], e)
               , timerEventPool = pool
               }
           , e)
  Just (pids, e) -> return (td { offeredOnTimer = offeredOnTimer td + 1
                               , timerOffersNext = Just (pid:pids, e)
                               }
                           , e)
offerTimerData pid (Just t) td
  | t <= curTime td
    = do (newOffers, newPool, e) <- insert (timerOffersBefore td) (timerEventPool td)
         return (td { offeredOnTimer = offeredOnTimer td + 1
                    , timerOffersBefore = newOffers
                    , timerEventPool = newPool
                    }
                , e)
  | otherwise
    = do (newOffers, newPool, e) <- insert (timerOffersAfter td) (timerEventPool td)
         return (td { offeredOnTimer = offeredOnTimer td + 1
                    , timerOffersAfter = newOffers
                    , timerEventPool = newPool
                    }
                , e)

  where
    insert :: [([ProcessId], (time, TVar (WithPoison (Maybe a))))]
      -> Seq.Seq (TVar (WithPoison (Maybe a)))
      -> STM ( [([ProcessId], (time, TVar (WithPoison (Maybe a))))]
             , Seq.Seq (TVar (WithPoison (Maybe a)))
             , TVar (WithPoison (Maybe a)))
    insert [] pool = do (e, es) <- spareEvent pool
                        return ([([pid], (t, e))], es, e)
    insert (off@(pids, (toff, eoff)):offs) pool
      = case compare toff t of
          LT -> do (offs', es', e') <- insert offs pool
                   return (off:offs', es', e')
          GT -> do (e, es) <- spareEvent pool
                   return (([pid], (t, e)):off:offs, es, e)
          EQ -> return ((pid:pids, (toff, eoff)):offs, pool, eoff)


instance Ord time =>
  Enrollable Clock time where
  enroll tim@(Clock (tv, u, sh)) f
    = do ev <- liftSTM $ newTVar (NoPoison Nothing)
         liftSTM (modifyTVar tv $ enrollTimerData $ Just ev)
           >>= checkPoison
         x <- f $ Enrolled tim
         ts <- getTrace
         liftSTM (modifyTVar' tv $ checkCompletion u sh ts . resignTimerData True)
           >>= checkPoison
         return x

  -- For temporary resignations, we don't touch the event pool
  resign (Enrolled (Clock (tv, u, sh))) m
    = do ts <- getTrace
         liftSTM (modifyTVar' tv (checkCompletion u sh ts . resignTimerData False))
           >>= checkPoison
         x <- m
         liftSTM (modifyTVar tv $ enrollTimerData Nothing)
           >>= checkPoison
         return x         

checkCompletion :: Ord time => Unique -> (time -> String) -> TraceStore -> TimerData time -> STM (TimerData time)
checkCompletion u sh ts td
  | offeredOnTimer td == enrolledOnTimer td =
      case timerOffersAfter td of
        ((pids, (newT, ev)):rest) -> do
          writeTVar ev $ NoPoison $ Just (newT, seqTime td)
          maybe (return ()) (flip writeTVar (NoPoison $ Just (newT, seqTime td)) . snd) (timerOffersNext td)
          recordEventLast [((Event.ClockSync $ sh newT,u)
            , Set.fromList $ pids ++ maybe [] fst (timerOffersNext td))]
            ts
          return $ td { timerOffersAfter = rest
                      , seqTime = succ $ seqTime td
                      , offeredOnTimer =
                          offeredOnTimer td
                            - (length pids + maybe 0 (length . fst) (timerOffersNext td))
                      , curTime = newT
                      , timerOffersNext = Nothing
                      -- The event will only be re-used once we get to the
                      -- end of the list, and thus all the people are ready
                      -- to go again, so there shouldn't be any overlap involving
                      -- re-use
                      , timerEventPool =
                          maybe id (flip (Seq.|>) . snd) (timerOffersNext td)
                            $ timerEventPool td Seq.|> ev
                      }
        [] -> case timerOffersBefore td of
                ((pids, (newT, ev)):rest) -> do
                  writeTVar ev $ NoPoison $ Just (newT, seqTime td)
                  maybe (return ()) (flip writeTVar (NoPoison $ Just (newT, seqTime td)) . snd) (timerOffersNext td)
                  return $
                    td { timerOffersAfter = rest
                       , timerOffersBefore = []
                       , offeredOnTimer =
                           offeredOnTimer td
                             - (length pids + maybe 0 (length . fst) (timerOffersNext td))
                       , curTime = newT
                       , seqTime = succ $ seqTime td
                       , timerOffersNext = Nothing
                       -- The event will only be re-used once we get to the
                       -- end of the list, and thus all the people are ready
                       -- to go again, so there shouldn't be any overlap involving
                       -- re-use
                       , timerEventPool =
                          maybe id (flip (Seq.|>) . snd) (timerOffersNext td)
                            (timerEventPool td Seq.|> ev)
                       }
                [] -> return td -- Everyone waiting for the next time!
  | otherwise = return td

waitClock :: Ord time =>
  ProcessId -> TraceStore -> Enrolled Clock time -> Maybe time -> STM (STM (WithPoison (time, Integer)))
waitClock pid ts (Enrolled (Clock (tv, u, sh))) ph
  = do x <- readTVar tv
       case x of
         PoisonItem -> return $ return PoisonItem
         NoPoison td ->
              do (td', ev) <- offerTimerData pid ph td
                 checkCompletion u sh ts td' >>= writeTVar tv . NoPoison
                 return $ waitForOrPoison id ev

-- | Creates a clock that starts at the given time.  The Show instance is needed
-- to display times in traces.
newClock :: (Ord time, Show time) => time -> CHP (Clock time)
newClock t = do tv <- liftSTM $ newTVar $ NoPoison $ emptyTimerData t
                u <- liftIO_CHP Event.newEventUnique
                return $ Clock (tv, u, show)

-- | Creates a clock that starts at the given time, and gives it the given
-- label in traces.  The Show instance is needed to display times in traces.
newClockWithLabel :: (Ord time, Show time) =>
  time -> String -> CHP (Clock time)
newClockWithLabel t l = getTrace >>= \tr -> liftIO_CHP $
                        do tv <- atomically $ newTVar $ NoPoison $ emptyTimerData t
                           u <- Event.newEventUnique
                           labelUnique tr u l
                           return $ Clock (tv, u, show)

instance Waitable Clock where
  getCurrentTime (Enrolled (Clock (tv, _, _)))
    = liftSTM (liftM (fmap curTime) $ readTVar tv) >>= checkPoison
  wait c@(Enrolled (Clock (_, u, sh))) mt
    = do tr <- getTrace
         let pid = getProcessId tr
         waitAct <- liftSTM $ waitClock pid tr c mt
         (t, s) <- liftSTM waitAct >>= checkPoison
         liftIO_CHP $ recordEvent [ClockSyncIndiv u s $ sh t] tr
         return t

instance Ord time => Poisonable (Enrolled Clock time) where
  poison (Enrolled (Clock (tv,_,_)))
    = liftCHP . liftSTM $ do
                   x <- readTVar tv
                   case x of
                     PoisonItem -> return ()
                     NoPoison td -> do poisonTimerData td
                                       writeTVar tv PoisonItem
  checkForPoison (Enrolled (Clock (tv,_,_)))
    = liftCHP $ liftSTM (readTVar tv) >>= checkPoison . fmap (const ())

{-
test_Clock :: IO ()
test_Clock
  = do let begin = emptyTimerData (7::Int)
       tv <- newTVar' $ NoPoison begin
       tv3 <- replicateM 3 $ newTVar' $ NoPoison Nothing
       let withTV f = atomically $ readTVar tv >>= \(NoPoison x) -> f x
           assertTVs vals = atomically (mapM readTVar tv3) >>=
             zipWithM assert1 (map (==) vals) . zip [0..]
           assert checks = atomically (readTVar tv)
             >>= zipWithM (assert1) checks . zip [0..] . repeat
           assert1 :: Show a => (a -> Bool) -> (Int, WithPoison a) -> IO ()
           assert1 f (n, NoPoison x)
             | f x = return ()
             | otherwise = putStrLn $ "Assertion " ++ show n ++ " failed: " ++ show x
           noComplete = do tvVals <- atomically $ mapM readTVar tv3
                           (td, td') <- atomically $ do
                             NoPoison td <- readTVar tv
                             td' <- checkCompletion (error "Unique") show NoTrace td
                             return (td, td')
                           tvVals' <- atomically $ mapM readTVar tv3
                           if td /= td' || tvVals /= tvVals'
                             then putStrLn "Completion unexpected!"
                             else return ()
           complete = atomically $ readTVar tv >>= \(NoPoison x) ->
             checkCompletion (error "Unique") show NoTrace x
               >>= writeTVar tv . NoPoison
       writeTVar' tv $ NoPoison $ foldr (enrollTimerData) begin (map Just tv3)
       assert [(== Seq.fromList tv3) . timerEventPool
              ,(== 3) . enrolledOnTimer
              ,(== 0) . offeredOnTimer
              ,(== 7) . curTime
              ,isNothing . timerOffersNext
              ,null . timerOffersBefore
              ,null . timerOffersAfter
              ]
       noComplete

       -- This sequence has two guys waiting for the next time, and one waiting
       -- for the next time after:
       withTV (offerTimerData (testProcessId 0) Nothing) >>= \(td, ev) ->
         do writeTVar' tv $ NoPoison td
            assert [(== Seq.fromList (tail tv3)) . timerEventPool
                   ,(== 3) . enrolledOnTimer
                   ,(== 1) . offeredOnTimer
                   ,(== 7) . curTime
                   ,(== Just ([testProcessId 0], head tv3)) . timerOffersNext
                   ,null . timerOffersBefore
                   ,null . timerOffersAfter
                   ,const $ head tv3 == ev
                   ]
       noComplete
       withTV (offerTimerData (testProcessId 1) Nothing) >>= \(td, ev) ->
         do writeTVar' tv $ NoPoison td
            assert [(== Seq.fromList (tail tv3)) . timerEventPool
                   ,(== 3) . enrolledOnTimer
                   ,(== 2) . offeredOnTimer
                   ,(== 7) . curTime
                   ,(== Just ([testProcessId 1, testProcessId 0], head tv3)) . timerOffersNext
                   ,null . timerOffersBefore
                   ,null . timerOffersAfter
                   ,const $ head tv3 == ev
                   ]
       noComplete
       withTV (offerTimerData (testProcessId 2) (Just 9)) >>= \(td, ev) ->
         do writeTVar' tv $ NoPoison td
            assert [(== Seq.fromList [last tv3]) . timerEventPool
                   ,(== 3) . enrolledOnTimer
                   ,(== 3) . offeredOnTimer
                   ,(== 7) . curTime
                   ,(== Just ([testProcessId 1, testProcessId 0], head tv3)) . timerOffersNext
                   ,null . timerOffersBefore
                   ,(== [([testProcessId 2], (9, sec tv3))]) . timerOffersAfter
                   ,const $ sec tv3 == ev
                   ]
       complete
       assertTVs [Just 9, Just 9, Nothing]
       readTVar' tv >>= \td ->
            assert [(== Seq.fromList (reverse tv3)) . timerEventPool
                   ,(== 3) . enrolledOnTimer
                   ,(== 0) . offeredOnTimer
                   ,(== 9) . curTime
                   ,isNothing . timerOffersNext
                   ,null . timerOffersBefore
                   ,null . timerOffersAfter
                   ]
       -- This sequence has one waiting before, one after and one before:
       withTV (offerTimerData (testProcessId 0) (Just 5)) >>= \(td, ev) ->
         do writeTVar' tv $ NoPoison td
            assert [(== Seq.fromList [sec tv3, head tv3]) . timerEventPool
                   ,(== 3) . enrolledOnTimer
                   ,(== 1) . offeredOnTimer
                   ,(== 9) . curTime
                   ,isNothing . timerOffersNext
                   ,(== [([testProcessId 0], (5, last tv3))]) . timerOffersBefore
                   ,null . timerOffersAfter
                   ,const $ last tv3 == ev
                   ]
       assertTVs [Just 9, Just 9, Nothing]
       noComplete
       withTV (offerTimerData (testProcessId 1) (Nothing)) >>= \(td, ev) ->
         do writeTVar' tv $ NoPoison td
            assert [(== Seq.fromList [head tv3]) . timerEventPool
                   ,(== 3) . enrolledOnTimer
                   ,(== 2) . offeredOnTimer
                   ,(== 9) . curTime
                   ,(== Just ([testProcessId 1], sec tv3)) . timerOffersNext
                   ,(== [([testProcessId 0], (5, last tv3))]) . timerOffersBefore
                   ,null . timerOffersAfter
                   ,const $ sec tv3 == ev
                   ]
       assertTVs $ [Just 9, Nothing, Nothing]
       noComplete
       withTV (offerTimerData (testProcessId 2) (Just 11)) >>= \(td, ev) ->
         do writeTVar' tv $ NoPoison td
            assert [(== Seq.fromList []) . timerEventPool
                   ,(== 3) . enrolledOnTimer
                   ,(== 3) . offeredOnTimer
                   ,(== 9) . curTime
                   ,(== Just ([testProcessId 1], sec tv3)) . timerOffersNext
                   ,(== [([testProcessId 0], (5, last tv3))]) . timerOffersBefore
                   ,(== [([testProcessId 2], (11, head tv3))]) . timerOffersAfter
                   ,const $ head tv3 == ev
                   ]
       assertTVs [Nothing, Nothing, Nothing]
       complete
       assertTVs [Just 11, Just 11, Nothing]
       readTVar' tv >>= \td ->
            assert [(== Seq.fromList [head tv3, sec tv3]) . timerEventPool
                   ,(== 3) . enrolledOnTimer
                   ,(== 1) . offeredOnTimer
                   ,(== 11) . curTime
                   ,isNothing . timerOffersNext
                   ,(== [([testProcessId 0], (5, last tv3))]) . timerOffersBefore
                   ,null . timerOffersAfter
                   ]
       -- This sequence has one joining in before on the same time, and one joining
       -- in before on the current time, which should count as before:
       noComplete
       withTV (offerTimerData (testProcessId 1) (Just 5)) >>= \(td, ev) ->
         do writeTVar' tv $ NoPoison td
            assert [(== Seq.fromList [head tv3, sec tv3]) . timerEventPool
                   ,(== 3) . enrolledOnTimer
                   ,(== 2) . offeredOnTimer
                   ,(== 11) . curTime
                   ,isNothing . timerOffersNext
                   ,(== [([testProcessId 1, testProcessId 0], (5, last tv3))]) . timerOffersBefore
                   ,null . timerOffersAfter
                   ,const $ last tv3 == ev
                   ]
       assertTVs [Just 11, Just 11, Nothing]
       noComplete
       withTV (offerTimerData (testProcessId 2) (Just 11)) >>= \(td, ev) ->
         do writeTVar' tv $ NoPoison td
            assert [(== Seq.fromList [sec tv3]) . timerEventPool
                   ,(== 3) . enrolledOnTimer
                   ,(== 3) . offeredOnTimer
                   ,(== 11) . curTime
                   ,isNothing . timerOffersNext
                   ,(== [([testProcessId 1, testProcessId 0], (5, last tv3))
                        ,([testProcessId 2], (11, head tv3))]) . timerOffersBefore
                   ,null . timerOffersAfter
                   ,const $ head tv3 == ev
                   ]
       assertTVs [Nothing, Just 11, Nothing]
       complete
       assertTVs [Nothing, Just 11, Just 5]
       readTVar' tv >>= \td ->
            assert [(== Seq.fromList [sec tv3, last tv3]) . timerEventPool
                   ,(== 3) . enrolledOnTimer
                   ,(== 1) . offeredOnTimer
                   ,(== 5) . curTime
                   ,isNothing . timerOffersNext
                   ,null . timerOffersBefore
                   ,(== [([testProcessId 2], (11, head tv3))]) . timerOffersAfter
                   ]
       return ()
  where
    sec (_:x:_) = x
    sec _ = error "sec"
    readTVar' = atomically . readTVar
    writeTVar' tv = atomically . writeTVar tv
    newTVar' = atomically . newTVar
-}
