-- Communicating Haskell Processes.
-- Copyright (c) 2008, University of Kent.
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



-- | A module containing various definitions relating to the CSP\/CSPPoison
-- monads, and poison.  Not publicly visible.
module Control.Concurrent.CHP.Base where

import Control.Applicative
import Control.Arrow
import Control.Concurrent (myThreadId, threadDelay)
import Control.Concurrent.STM
import qualified Control.Exception.Extensible as C
import Control.Monad
import Data.Function (on)
import Data.List (findIndex, nub)
import qualified Data.Map as Map
import Data.Maybe (fromMaybe, isNothing, mapMaybe)
import qualified Data.Set as Set
import Data.Unique
import System.IO
import qualified Text.PrettyPrint.HughesPJ

import Control.Concurrent.CHP.Event
import Control.Concurrent.CHP.Guard
import Control.Concurrent.CHP.Poison
import Control.Concurrent.CHP.ProcessId
import Control.Concurrent.CHP.Traces.Base

-- ======
-- Types:
-- ======

-- | An enrolled wrapper for barriers that shows at the type-level whether
-- you are enrolled on a barrier.  Enrolled Barriers should never be passed
-- to two (or more) processes running in parallel; if two processes synchronise
-- based on a single enroll call, undefined behaviour will result.
newtype Enrolled b a = Enrolled (b a) deriving (Eq)

-- | The central monad of the library.  You can use
-- 'Control.Concurrent.CHP.Monad.runCHP' and
-- 'Control.Concurrent.CHP.Monad.runCHP_' to execute programs in this
-- monad.
--
-- The Alternative instance was added in version 2.2.0.
newtype CHP a = PoisonT {runPoisonT :: forall b. TraceStore -> (a -> CHP' b) -> CHP' b}
--  deriving (Functor, Monad, MonadIO)

instance Functor CHP where
  fmap f m = PoisonT $ \t c -> runPoisonT m t (c . f)

instance Monad CHP where
  return a = PoisonT $ const ($ a)
  m >>= k  = PoisonT $ \t c -> runPoisonT m t (\a -> runPoisonT (k a) t c)
            
instance Applicative CHP where
  pure = return
  (<*>) = ap

instance Alternative CHP where
  empty = stop
  a <|> b = priAlt [a, b]
  -- Like the default definition but makes clear
  -- which the leading action is:
--  some p = do x <- p
--              xs <- many p
--              return (x : xs)

-- | An implementation of liftIO for the CHP monad; this function lifts IO actions
-- into the CHP monad.
--
-- Added in version 2.2.0.
liftIO_CHP :: IO a -> CHP a
liftIO_CHP m = PoisonT $ const $ \f -> (Standard (liftM NoPoison m) >>= f)

data CHP' a = Return a 
  -- The guard, and body to execute after the guard
  | Altable TraceStore [(Guard, IO (WithPoison a))]
  -- The body to execute without a guard
  | Standard (IO (WithPoison a))

-- ========
-- Classes:
-- ========

-- | A monad transformer class that is very similar to 'MonadIO'.  This can be
-- useful if you want to add monad transformers (such as 'StateT', 'ReaderT') on
-- top of the 'CHP' monad.
class Monad m => MonadCHP m where
  liftCHP :: CHP a -> m a

-- | A class representing a type of trace.  The main useful function is 'runCHPAndTrace',
-- but because its type is only determined by its return type, you may wish
-- to use the already-typed functions offered in each trace module -- see the
-- modules in "Control.Concurrent.CHP.Traces".
--
-- The trace type involved became parameterised in version 1.3.0.
class Trace t where
  -- | Runs the given CHP program, and returns its return value and the trace.
  --  The return value is a Maybe type because the process may have exited
  -- due to uncaught poison.  In that case Nothing is return as the result.
  runCHPAndTrace :: CHP a -> IO (Maybe a, t Unique)
  -- | The empty trace.
  emptyTrace :: t u
  -- | Pretty-prints the given trace using the "Text.PrettyPrint.HughesPJ"
  -- module.
  prettyPrint :: Ord u => t u -> Text.PrettyPrint.HughesPJ.Doc

  -- | Added in version 1.3.0.
  labelAll :: Ord u => t u -> t String

-- | A class indicating that something is poisonable.
class Poisonable c where
  -- | Poisons the given item.
  poison :: MonadCHP m => c -> m ()
  -- | Checks if the given item is poisoned.  If it is, a poison exception
  -- will be thrown.
  --
  -- Added in version 1.0.2.
  checkForPoison :: MonadCHP m => c -> m ()

-- ==========
-- Functions: 
-- ==========

makeAltable :: [(Guard, IO (WithPoison a))] -> CHP a
makeAltable gas = PoisonT $ \t f -> Altable t (map (second (&>>= pullOutStandard . f)) gas)

makeAltable' :: (TraceStore -> [(Guard, IO (WithPoison a))]) -> CHP a
makeAltable' gas = PoisonT $ \t f -> Altable t (map (second (&>>= pullOutStandard . f)) (gas t))

pullOutStandard :: CHP' a -> IO (WithPoison a)
pullOutStandard (Return x) = return (NoPoison x)
pullOutStandard (Altable tr gas) = selectFromGuards tr gas
pullOutStandard (Standard m) = m

wrapPoison :: TraceStore -> CHP a -> CHP' a
wrapPoison t (PoisonT m) = m t return

--unwrapPoison :: (TraceStore -> CHP' a) -> CHP a
--unwrapPoison m = PoisonT $ \t f -> m t >>= f

  
-- | Checks for poison, and either returns the value, or throws a poison exception
checkPoison :: WithPoison a -> CHP a
checkPoison (NoPoison x) = return x
checkPoison PoisonItem = PoisonT $ \_ _ -> Standard $ return PoisonItem

liftPoison :: (TraceStore -> CHP' a) -> CHP a
liftPoison m = PoisonT ((>>=) . m)

-- | Throws a poison exception.
throwPoison :: CHP a
throwPoison = checkPoison PoisonItem

-- | Allows you to provide a handler for sections with poison.  It is usually
-- used in an infix form as follows:
--
-- > (readChannel c >>= writeChannel d) `onPoisonTrap` (poison c >> poison d)
--
-- It handles the poison and does not rethrow it (unless your handler
-- does so).  If you want to rethrow (and actually, you'll find you usually
-- do), use 'onPoisonRethrow'
onPoisonTrap :: CHP a -> CHP a -> CHP a
onPoisonTrap (PoisonT body) (PoisonT handler)
  = PoisonT $ \t f ->
     let trap PoisonItem = pullOutStandard $ handler t f
         trap (NoPoison x) = pullOutStandard $ f x in
    case body t return of
      Return x -> f x
      Altable tr gas -> Altable tr (map (second (>>= trap)) gas)
      Standard m -> Standard $ m >>= trap


-- | Like 'onPoisonTrap', this function allows you to provide a handler
--  for poison.  The difference with this function is that even if the
--  poison handler does not throw, the poison exception will always be
--  re-thrown after the handler anyway.  That is, the following lines of
--  code all have identical behaviour:
--
-- > foo
-- > foo `onPoisonRethrow` throwPoison
-- > foo `onPoisonRethrow` return ()
onPoisonRethrow :: CHP a -> CHP () -> CHP a
onPoisonRethrow (PoisonT body) (PoisonT handler)
  = PoisonT $ \t f ->
     let handle PoisonItem = PoisonItem <$ (pullOutStandard $ handler t return)
         handle (NoPoison x) = pullOutStandard $ f x in
    case body t return of
      Return x -> f x
      Altable tr gas -> Altable tr (map (second (>>= handle)) gas)
      Standard m -> Standard $ m >>= handle

-- | Poisons all the given items.  A handy shortcut for @mapM_ poison@.
poisonAll :: (Poisonable c, MonadCHP m) => [c] -> m ()
poisonAll = mapM_ poison

getTrace :: CHP TraceStore
getTrace = PoisonT (flip ($))

liftSTM :: STM a -> CHP a
liftSTM = liftIO_CHP . atomically

getProcessId :: TraceStore -> ProcessId
getProcessId (Trace (pid,_,_)) = pid
getProcessId (NoTrace pid) = pid

wrapProcess :: CHP a -> TraceStore -> (CHP' a -> IO (WithPoison a)) -> IO (Maybe (WithPoison a))
wrapProcess (PoisonT proc) t unwrapInner
  = (Just <$> unwrapInner (proc t return)) `C.catches` allHandlers
  where
    response :: C.Exception e => e -> IO (Maybe a)
    response x = do hPutStrLn stderr $ "(CHP) Thread terminated with: " ++ show x
                    return Nothing

    allHandlers = [C.Handler (response :: C.IOException -> IO (Maybe a))
                  ,C.Handler (response :: C.AsyncException -> IO (Maybe a))
                  ,C.Handler (response :: C.NonTermination -> IO (Maybe a))
#if __GLASGOW_HASKELL__ >= 611
                  ,C.Handler (response :: C.BlockedIndefinitelyOnSTM -> IO (Maybe a))
#else
                  ,C.Handler (response :: C.BlockedIndefinitely -> IO (Maybe a))
#endif
                  ,C.Handler (response :: C.Deadlock -> IO (Maybe a))
                  ]

runCHPProgramWith :: TraceStore -> CHP a -> IO (Maybe a)
runCHPProgramWith start p
  = do r <- wrapProcess p start pullOutStandard
       case r of
         Nothing -> putStrLn "Deadlock" >> return Nothing
         Just PoisonItem -> putStrLn "Uncaught Poison" >> return Nothing
         Just (NoPoison x) -> return (Just x)

runCHPProgramWith' :: SubTraceStore -> (ChannelLabels Unique -> IO t) -> CHP a -> IO (Maybe a, t)
runCHPProgramWith' subStart f p
  = do tv <- atomically $ newTVar Map.empty
       x <- runCHPProgramWith (Trace (rootProcessId, tv, subStart)) p
--                             `C.catch` const (return (Nothing,
--                               Trace (undefined, undefined, subStart)))
       l <- atomically $ readTVar tv
       t' <- f l
       return (x, t')

data ManyToOneTVar a = ManyToOneTVar
  { mtoIsFinalValue :: a -> Bool
  , mtoReset :: STM a
  , mtoInter :: TVar a
  , mtoFinal :: TVar (Maybe a)
  }

instance Eq (ManyToOneTVar a) where
  (==) = (==) `on` mtoFinal

newManyToOneTVar :: (a -> Bool) -> STM a -> a -> STM (ManyToOneTVar a)
newManyToOneTVar f r x
  = do tvInter <- newTVar x
       tvFinal <- newTVar $ if f x then Just x else Nothing
       return $ ManyToOneTVar f r tvInter tvFinal

writeManyToOneTVar :: (a -> a) -> ManyToOneTVar a -> STM a
writeManyToOneTVar f (ManyToOneTVar done reset tvInter tvFinal)
  = do x <- readTVar tvInter
       if done (f x)
         then do writeTVar tvFinal $ Just $ f x
                 reset >>= writeTVar tvInter
         else writeTVar tvInter $ f x
       return $ f x

readManyToOneTVar :: ManyToOneTVar a -> STM a
readManyToOneTVar (ManyToOneTVar _done _reset _tvInter tvFinal)
  = do x <- readTVar tvFinal >>= maybe retry return
       writeTVar tvFinal Nothing
       return x

-- If the value is final, it is stored as final!
resetManyToOneTVar :: ManyToOneTVar a -> a -> STM ()
resetManyToOneTVar (ManyToOneTVar done reset tvInter tvFinal) x
  | done x = (reset >>= writeTVar tvInter) >> writeTVar tvFinal (Just x)
  | otherwise = writeTVar tvInter x >> writeTVar tvFinal Nothing

-- ==========
-- Instances: 
-- ==========

instance MonadCHP CHP where
  liftCHP = id

-- The monad is lazy, and very similar to the writer monad
instance Monad CHP' where
  -- m :: AltableT g m a
  -- f :: a -> AltableT g m b
  m >>= f = case m of
             Return x -> f x
             Altable tr altBody -> Altable tr $ map (second (&>>= pullOutStandard . f)) altBody
             Standard s -> Standard $ s &>>= pullOutStandard . f
  return = Return

instance Functor CHP' where
  fmap = liftM

infixr 8 &>>=
(&>>=) :: IO (WithPoison a) -> (a -> IO (WithPoison b)) -> IO (WithPoison b)
(&>>=) m f = do v <- m
                case v of
                  PoisonItem -> return PoisonItem
                  NoPoison x -> f x


-- ====
-- Alt:
-- ====

-- Performs the select operation on all the guards, and then executes the body
selectFromGuards :: forall a. TraceStore -> [(Guard, IO (WithPoison a))] -> IO (WithPoison a)
selectFromGuards tr items
  | null (eventGuards guards)
     = join $ liftM snd $ waitNormalGuards items Nothing
  | otherwise = do
      tv <- newTVarIO Nothing
      tid <- myThreadId
      mn <- atomically $ do
              ret <- enableEvents tv (tid, pid)
                (maybe id take earliestReady $ eventGuards guards)
                (isNothing earliestReady)
              either (const $ return ()) whenLast ret
              return $ either Left (Right . getRec . fst) ret
      case (mn, earliestReady) of
        -- An event -- and we were the last person to arrive:
        -- The event must have been higher priority than any other
        -- ready guards
        (Right r, _) -> recordAndRun r
        -- No events were ready, but there was an available normal
        -- guards.  Re-run the normal guards; at least one will be ready
        (Left _, Just _) ->
          join $ liftM snd $ waitNormalGuards items Nothing
        -- No events ready, no other guards ready either
        -- Events will have been enabled; wait for everything:
        (Left disable, Nothing) ->
            do (wasAltingBarrier, pr) <- waitNormalGuards
                 guardsAndRec $ Just $ liftM getRec $ waitAlting tv
               if wasAltingBarrier
                 then recordAndRun pr -- It was a barrier, all done
                 else
                    -- Another guard fired, but we must check in case
                    -- we have meanwhile been committed to taking an
                    -- event:
                    do mn' <- atomically $ disable
                       case mn' of
                         -- An event overrides our non-event choice:
                         Just pr' -> recordAndRun $ getRec pr'
                         -- Go with the original option, no events
                         -- became ready:
                         Nothing -> recordAndRun pr
  where
    guards = map fst items
    earliestReady = findIndex isSkipGuard guards

    recordAndRun :: WithPoison ([RecordedIndivEvent Unique], IO (WithPoison a)) -> IO (WithPoison a)
    recordAndRun PoisonItem = return PoisonItem
    recordAndRun (NoPoison (r, m)) = recordEvent r tr >> m

    guardsAndRec :: [(Guard, WithPoison ([RecordedIndivEvent Unique], IO (WithPoison a)))]
    guardsAndRec = map (second (NoPoison . (,) [])) items

    getRec :: (SignalValue, Map.Map Unique (Integer, RecordedEventType))
           -> WithPoison ([RecordedIndivEvent Unique], IO (WithPoison a))
    getRec (Signal PoisonItem, _) = PoisonItem
    getRec (Signal (NoPoison n), m)
      = case items !! n of
          (EventGuard recF _ _, body) ->
            NoPoison (recF (makeLookup m), body)
          (_, body) -> NoPoison ([], body)

    whenLast ((sigVal,_),es)
      = do recordEventLast (nub es) tr
           case sigVal of
             Signal PoisonItem -> return ()
             Signal (NoPoison n) ->
               let EventGuard _ act _ = guards !! n
               in actWhenLast act (Map.fromList $ map (snd *** Set.size) es)

    pid = getProcessId tr

waitAlting :: SignalVar -> STM (SignalValue, Map.Map Unique (Integer, RecordedEventType))
waitAlting tv = do b <- readTVar tv
                   case b of
                     Nothing -> retry
                     Just ns -> return ns

makeLookup :: Map.Map Unique (Integer, RecordedEventType) -> Unique -> (Integer,
  RecordedEventType)
makeLookup m u = fromMaybe (error "CHP: Unique not found in alt") $ Map.lookup u m

-- The alting barrier guards:
eventGuards :: [Guard] -> [((SignalValue, STM ()), [Event])]
eventGuards guards = [((Signal $ NoPoison n, actAlways acts), ab)
                     | (n, EventGuard _ acts ab) <- zip [0..] guards]


-- Waits for one of the normal (non-alting barrier) guards to be ready,
-- or the given transaction to complete
waitNormalGuards :: [(Guard, b)] -> Maybe (STM b) -> IO (Bool, b)
waitNormalGuards guards extra
  = do enabled <- sequence $ mapMaybe enable guards
       atomically $ foldr orElse retry $ maybe id ((:) . liftM ((,) True)) extra $ enabled
  where
    enable :: (Guard, b) -> Maybe (IO (STM (Bool, b)))
    enable (SkipGuard, x) = Just $ return $ return (False, x)
    enable (TimeoutGuard g, x) = Just $ liftM (>> return (False, x)) g
    enable _ = Nothing -- This effectively ignores other guards




-- | An alt between several actions, with descending priority.  The first
-- available action is chosen (biased towards actions nearest the beginning
-- of the list), its body run, and its value returned.
--
-- What priority means here is a difficult thing, and in some ways a historical
-- artifact.  We can group the guards into three categories:
--
-- 1. synchronisation guards (reading from and writing to channels, and synchronising
-- on barriers)
--
-- 2. time-out guards (such as 'Control.Concurrent.CHP.Monad.waitFor')
--
-- 3. dummy guards ('Control.Concurrent.CHP.Monad.skip', 'Control.Concurrent.CHP.Monad.stop'
-- and things like IO actions)
--
-- There exists priority when comparing dummy guards to anything else.  So for
-- example,
--
-- > priAlt [ skip, x ]
--
-- Will always select the first guard (the skip guard), whereas:
--
-- > priAlt [ x , skip ]
--
-- Is an effective way to poll and see if x is ready, otherwise the 'Control.Concurrent.CHP.Monad.skip' will
-- be chosen.  However, there is no priority between synchronisation guards and
-- time-out guards.  So the two lines:
--
-- > priAlt [ x, y ]
-- > priAlt [ y, x ]
--
-- May have the same or different behaviour (when x and y are not dummy guards),
-- there is no guarantee either way.  The reason behind this is that if you ask
-- for:
--
-- > priAlt [ readChannel c, writeChannel d 6 ]
--
-- And the process at the other end is asking for:
--
-- > priAlt [ readChannel d, writeChannel c 8 ]
--
-- Whichever channel is chosen by both processes will not satisfy the priority
-- at one end (if such priority between channels was supported).  If you do want
-- priority that is globally consistent, look at the channel and barrier creation
-- methods for ways to set priority on events.
priAlt :: [CHP a] -> CHP a
priAlt xs = PoisonT $ \t f -> priAlt' t (map (wrapPoison t) xs) >>= f

priAlt' :: TraceStore -> [CHP' a] -> CHP' a
priAlt' tr = Altable tr . filter (not . isStopGuard . fst) . concatMap getAltable
  where
    getAltable :: CHP' a -> [(Guard, IO (WithPoison a))]
    getAltable (Return x) = [(SkipGuard, return $ NoPoison x)]
    getAltable (Altable _ gs) = gs
    getAltable (Standard m) = [(SkipGuard, m)]


-- | The stop guard.  Its main use is that it is never ready in a choice, so
-- can be used to mask out guards.  If you actually execute 'stop', that process
-- will do nothing more.  Any parent process waiting for it to complete will
-- wait forever.
--
-- The type of this function was generalised in CHP 1.6.0.
stop :: CHP a
stop = makeAltable [(stopGuard, hang)]
  where
    -- Strangely, I can't work out a good way to actually implement stop.
    -- If you wait on a variable that will never be ready, GHC will wake
    -- you up with an exception.  If you loop doing that, you'll burn the
    -- CPU.  Throwing an exception would be caught and terminate the
    -- process, which is not the desired behaviour.  The only thing I can think
    -- to do is to repeatedly wait for a very long time.
    hang :: IO a
    hang = forever $ threadDelay maxBound
