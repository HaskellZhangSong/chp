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

-- | A module containing barriers.
--
-- A barrier is a synchronisation primitive.  When N processes are enrolled
-- on a barrier, all N must synchronise on the barrier before any synchronisations
-- may complete, at which point they all complete.  That is, when a single
-- process synchronises on a barrier, it must then wait until all the other
-- enrolled processes also synchronise before it can finish.
--
-- Only processes enrolled on a barrier may synchronise on it.  Enrolled barriers
-- should not be passed around between processes, or used twice in a parallel
-- composition.  Instead, each process should enroll on the barrier itself.
--
-- Barriers support choice (alting).  This can lead to a lot of non-determinism
-- and some confusion.  Consider these two processes, both enrolled on barriers a and b:
--
-- > (sync a <-> sync b)
-- > (sync b <-> sync a)
--
-- Which barrier completes is determined by the run-time, and will be an arbitrary
-- choice.  This is even the case when priority is involved:
--
-- > (sync a </> sync b)
-- > (sync b </> sync a)
--
-- Clearly there is no way to resolve this to satisfy both priorities; the
-- run-time will end up choosing.
--
-- Barrier poison can be detected when syncing, enrolling or resigning.  You
-- may only poison a barrier that you are currently enrolled on.
--
-- Barriers can also support phases.  The idea behind a phased barrier is that
-- a barrier is always on a certain phase P.  Whenever a barrier successfully
-- completes, the phase is incremented (but it does not have to be an integer).
--  Everyone is told the new phase once they complete a synchronisation, and
-- may query the current phase for any barrier that they are currently enrolled
-- on.
module Control.Concurrent.CHP.Barriers (Barrier, EnrolledBarrier, newBarrier, newBarrierPri, newBarrierWithLabel,
  PhasedBarrier, newPhasedBarrier, newPhasedBarrier', BarOpts(..), defaultIncPhase, defaultBarOpts,
    barLabel, currentPhase, waitForPhase, syncAndWaitForPhase,
    syncBarrier, getBarrierIdentifier) where

import Control.Concurrent.STM
import Control.Monad (liftM, unless, when)
import Data.Unique

import Control.Concurrent.CHP.Base
import Control.Concurrent.CHP.CSP
import Control.Concurrent.CHP.Event
import Control.Concurrent.CHP.Traces.Base

-- | A special case of the PhasedBarrier that has no useful phases, i.e. a
-- standard barrier.
type Barrier = PhasedBarrier ()

-- | A useful type synonym for enrolled barriers with no phases
--
-- Added in 1.1.0
type EnrolledBarrier = Enrolled PhasedBarrier ()

-- | Synchronises on the given barrier.  You must be enrolled on a barrier in order
-- to synchronise on it.  Returns the new phase, following the synchronisation.
syncBarrier :: Enrolled PhasedBarrier phase -> CHP phase
syncBarrier = syncBarrierWith (indivRecJust BarrierSyncIndiv) (const $ return ())
    
-- | Finds out the current phase a barrier is on.
currentPhase :: Enrolled PhasedBarrier phase -> CHP phase
currentPhase (Enrolled (Barrier (_, tv, _))) = liftSTM $ readTVar tv

repeatUntil :: (Monad m) => (a -> Bool) -> m a -> m ()
repeatUntil target comp = do x <- comp
                             unless (target x) $ repeatUntil target comp

-- | If the barrier is not in the given phase, synchronises on the barrier
-- repeatedly until it /is/ in the given phase.
waitForPhase :: Eq phase => phase -> Enrolled PhasedBarrier phase -> CHP ()
waitForPhase ph b = do phCur <- currentPhase b
                       when (ph /= phCur) $
                         repeatUntil (== ph) (syncBarrier b)

-- | Synchronises on the barrier at least once, until it is in the given phase.
--
-- Note that @syncAndWaitForPhase ph bar == syncBarrier bar >> waitForPhase ph
-- bar@.
--
-- Added in version 1.7.0.
syncAndWaitForPhase :: Eq phase => phase -> Enrolled PhasedBarrier phase -> CHP ()
syncAndWaitForPhase ph = repeatUntil (== ph) . syncBarrier

-- | Options for barrier creation; a function to show the inner data, and an optional
-- label (both only affect tracing).  These options can be passed to newPhasedBarrier'.
--
-- Added in version 1.7.0.
data BarOpts phase = BarOpts { barIncPhase :: phase -> phase
  -- ^ Aside from the standard 'defaultIncPhase', you can use succ or (+1) with
  -- Integer as the inner type to get a barrier that never cycles.  You can also
  -- do things like supplying (+2) as the incrementing function, or even using
  -- lists as the phase type to do crazy things.
  , barPriority :: Int
  -- ^ Added in version 2.1.0.  See 'Control.Concurrent.CHP.Channels.Creation.ChanOpts'.
  , barOptsShow :: phase -> String
  , barOptsLabel :: Maybe String }

-- | The default phase incrementing function.  If the phase is already at 'maxBound',
-- it sets it to 'minBound'; otherwise it uses 'succ' to increment the phase.
defaultIncPhase :: (Enum phase, Bounded phase, Eq phase) => phase -> phase
defaultIncPhase p
  | p == maxBound = minBound
  | otherwise = succ p

-- | The default: don't show anything, don't label anything, use Enum+Bounded+Eq to
-- work out the phase increment.
-- 
-- Added in version 1.7.0.
defaultBarOpts :: (Enum phase, Bounded phase, Eq phase) => BarOpts phase
defaultBarOpts = BarOpts defaultIncPhase 0 (const "") Nothing

-- | Uses the Show instance for showing the data in traces, and the given label.
--
-- Added in version 1.7.0.
barLabel :: (Enum phase, Bounded phase, Eq phase, Show phase) => String -> BarOpts phase
barLabel = BarOpts defaultIncPhase 0 show . Just

-- | Creates a new barrier with no processes enrolled
newBarrier :: CHP Barrier
newBarrier = newBarrierPri 0

-- | Creates a new barrier with no processes enrolled and the given priority.
--
-- Added in version 2.1.0.
newBarrierPri :: Int -> CHP Barrier
newBarrierPri n = newPhasedBarrier' () $ BarOpts (const ()) n (const "") Nothing

newBarrierEvent :: (phase -> String) -> Int -> TVar phase -> IO Event
newBarrierEvent sh pri tv = newEventPri (liftM (BarrierSync . sh) $ readTVar tv) 0 pri

-- | Creates a new barrier with no processes enrolled, that will be on the
-- given phase.  You will often want to pass in the last value in your phase
-- cycle, so that the first synchronisation moves it on to the first
--
-- The Show constraint was added in version 1.5.0
newPhasedBarrier :: (Enum phase, Bounded phase, Eq phase, Show phase) => phase -> CHP (PhasedBarrier phase)
newPhasedBarrier ph = newPhasedBarrier' ph $ BarOpts defaultIncPhase 0 show Nothing

-- | Like 'newPhasedBarrier' but allows you to customise the options.
newPhasedBarrier' :: phase -> BarOpts phase -> CHP (PhasedBarrier phase)
newPhasedBarrier' ph (BarOpts incPh pri showPh label) = getTrace >>= \tr -> liftIO_CHP $ do
  tv <- atomically $ newTVar ph
  e <- newBarrierEvent showPh pri tv
  maybe (return ()) (labelEvent tr e) label
  return $ Barrier (e, tv, incPh)

-- | Creates a new barrier with no processes enrolled and labels it in traces
-- using the given label.  See 'newBarrier'.
newBarrierWithLabel :: String -> CHP Barrier
newBarrierWithLabel = newPhasedBarrier' () . BarOpts (const ()) 0 (const "") . Just

-- | Gets the identifier of a Barrier.  Useful if you want to identify it in
-- the trace later on.
getBarrierIdentifier :: PhasedBarrier ph -> Unique
getBarrierIdentifier (Barrier (e, _, _)) = getEventUnique e

