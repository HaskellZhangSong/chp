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

-- | A module containing a few miscellaneous items that can't go in Control.Concurrent.CHP.Base
-- because they would form a cyclic module link.  Not publicly visible.
-- TODO rename this module.
module Control.Concurrent.CHP.CSP where

import Control.Applicative
import Control.Concurrent.STM
import Control.Exception
import Control.Monad (when)
import Data.List
import qualified Data.Map as Map
import Data.Unique

import Control.Concurrent.CHP.Base
import qualified Control.Concurrent.CHP.Event as Event
import Control.Concurrent.CHP.Enroll
import Control.Concurrent.CHP.Guard
import Control.Concurrent.CHP.Poison
import Control.Concurrent.CHP.Traces.Base

-- First engages in event, then executes the body.  The returned value is suitable
-- for use in an alt
buildOnEventPoison :: (Unique -> (Unique -> (Integer, Event.RecordedEventType)) -> [RecordedIndivEvent Unique]) -> Event.Event -> EventActions -> IO (WithPoison a) -> CHP a
buildOnEventPoison recE e act body
  = makeAltable [(theGuard, body)]
  where
    theGuard = EventGuard (recE (Event.getEventUnique e)) act [e]

scopeBlock :: CHP a -> (a -> CHP b) -> IO () -> CHP b
scopeBlock start body errorEnd
    = do x <- start
         tr <- getTrace
         y <- liftIO_CHP $ bracketOnError (return ()) (const errorEnd) $ const
           $ pullOutStandard (wrapPoison tr $ body x)
         checkPoison y `onPoisonRethrow` (liftIO_CHP errorEnd)

wrapIndiv :: (Unique -> (Unique -> Integer) -> String -> [RecordedIndivEvent Unique])
          -> Unique -> (Unique -> (Integer, Event.RecordedEventType))
          -> [RecordedIndivEvent Unique]
wrapIndiv recE u lu = recE u (fst . lu) (Event.getEventTypeVal $ snd $ lu u)

-- | Synchronises on the given barrier.  You must be enrolled on a barrier in order
-- to synchronise on it.  Returns the new phase, following the synchronisation.
syncBarrierWith :: (Unique -> (Unique -> Integer) -> String -> [RecordedIndivEvent Unique])
  -> (Int -> STM ()) -> Enrolled PhasedBarrier phase -> CHP phase
syncBarrierWith recE storeN (Enrolled (Barrier (e,tv, fph)))
    = buildOnEventPoison (wrapIndiv recE) e (EventActions incPhase (return ()))
        (NoPoison <$> (atomically $ readTVar tv))
    where
      incPhase :: Map.Map Unique Int -> STM ()
      incPhase m = do readTVar tv >>= writeTVar tv . fph
                      maybe (return ()) storeN $ Map.lookup (Event.getEventUnique e) m

-- | A phased barrier that is capable of being poisoned and throwing poison.
--  You will need to enroll on it to do anything useful with it.
-- For the phases you can use any type that satisfies 'Enum', 'Bounded' and 'Eq'.
--  The phase increments every time the barrier completes.  Incrementing consists
-- of: @if p == maxBound then minBound else succ p@.  Examples of things that
-- make sense for phases:
--
-- * The () type (see the 'Barrier' type).  This effectively has a single repeating
-- phase, and acts like a non-phased barrier.
--
-- * A bounded integer type.  This increments the count every time the barrier completes.
--  But don't forget that the count will wrap round when it reaches the end.
--  You cannot use 'Integer' for a phase because it is unbounded.  If you really
-- want to have an infinitely increasing count, you can wrap 'Integer' in a newtype and
-- provide a 'Bounded' instance for it (with minBound and maxBound set to -1,
-- if you start on 0).
--
-- * A boolean.  This implements a simple black-white barrier, where the state
-- flips on each iteration.
--
-- * A custom data type that has only constructors.  For example, @data MyPhases
-- = Discover | Plan | Move@.  Haskell supports deriving 'Enum', 'Bounded' and
-- 'Eq' automatically on such types.
newtype PhasedBarrier phase = Barrier (Event.Event, TVar phase, phase -> phase)

instance Enrollable PhasedBarrier phase where
  enroll b@(Barrier (e, _, _)) f
    = do liftSTM (Event.enrollEvent e) >>= checkPoison
         x <- f $ Enrolled b
         liftSTM (Event.resignEvent e) >>= checkPoison >>= (\es ->
           do tr <- getTrace
              when (not $ null es) $ liftSTM $ recordEventLast (nub es) tr)
         return x

  resign (Enrolled (Barrier (e, _, _))) m
    = do liftSTM (Event.resignEvent e) >>= checkPoison >>= (\es ->
           do tr <- getTrace
              when (not $ null es) $ liftSTM $ recordEventLast (nub es) tr)
         x <- m
         liftSTM (Event.enrollEvent e) >>= checkPoison
         return x

instance Poisonable (Enrolled PhasedBarrier phase) where
  poison (Enrolled (Barrier (e, _, _)))
    = liftCHP . liftSTM $ Event.poisonEvent e
  checkForPoison (Enrolled (Barrier (e, _, _)))
    = liftCHP $ liftSTM (Event.checkEventForPoison e) >>= checkPoison



