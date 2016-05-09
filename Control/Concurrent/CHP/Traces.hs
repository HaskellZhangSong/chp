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

-- | A module that re-exports all the parts of the library related to tracing.
--
-- The idea of tracing is to record the concurrent events (i.e. channel communications
-- and barrier synchronisations) that occur during a run of the program.  You
-- can think of it as automatically turning on a lot of debug logging.
--
-- Typically, at the top-level of your program you should have:
--
-- > main :: IO ()
-- > main = runCHP myMainProcess
--
-- To turn on the tracing mechanism of your choice (for example, CSP-style tracing)
-- to automatically print out the trace after completion of your program, just
-- use the appropriate helper function:
--
-- > main :: IO ()
-- > main = runCHP_CSPTraceAndPrint myMainProcess
--
-- It could hardly be easier.  If you want more fine-grained control and examination
-- of the trace, you can use the helper functions of the form 'runCHP_CSPTrace'
-- that give back a data structure representing the trace, which you can then
-- manipulate.
--
-- The Doc used by the traces is from the 'Text.PrettyPrint.HughesPJ'
-- module that currently comes with GHC (I think).
--
-- For more details on the theory behind the tracing, the logic behind its
-- implementation, and example traces, see the paper \"Representation and Implementation
-- of CSP and VCR Traces\", N.C.C. Brown and M.L. Smith, CPA 2008.  An online version can
-- be found at: <http://twistedsquare.com/Traces.pdf>
module Control.Concurrent.CHP.Traces
  (module Control.Concurrent.CHP.Traces.CSP
  ,module Control.Concurrent.CHP.Traces.Structural
  ,module Control.Concurrent.CHP.Traces.TraceOff
  ,module Control.Concurrent.CHP.Traces.VCR
  ,RecordedEvent
  ,ChannelLabels
  ,RecordedEventType(..)
  ,RecordedIndivEvent(..)
  ,recordedIndivEventLabel
  ,recordedIndivEventSeq
  ,Trace(..)
  ,vcrToCSP
  ,structuralToCSP
  ,structuralToVCR
  ) where

import Control.Arrow
--import Control.Monad.Cont
--import Control.Monad.State
import qualified Data.Foldable as F
import Data.List
import qualified Data.Map as Map
import Data.Monoid
import qualified Data.Set as Set

import Control.Concurrent.CHP.Base
import Control.Concurrent.CHP.Event
import Control.Concurrent.CHP.ProcessId
import Control.Concurrent.CHP.Traces.Base
import Control.Concurrent.CHP.Traces.CSP
import Control.Concurrent.CHP.Traces.Structural
import Control.Concurrent.CHP.Traces.TraceOff
import Control.Concurrent.CHP.Traces.VCR

-- | Takes a VCR trace and forms all the possible CSP traces (without
-- duplicates) that could have arisen from the same execution.
--
-- This is done by taking all permutations of each set in the VCR trace (which
-- is a list of sets) and concatenating them with the results of the same process
-- on the rest of the trace.  Thus the maximum size of the returned set of CSP traces
-- is the product of the sizes of all the non-empty sets in the VCR trace.
--
-- This function was added in version 1.5.0.
vcrToCSP :: Eq u => VCRTrace u -> [CSPTrace u]
vcrToCSP (VCRTrace (ls, sets)) = [CSPTrace (ls, es) | es <- nub $ process sets]
  where
    process :: [Set.Set a] -> [[a]]
    process [] = [[]]
    process (s:ss)
      | Set.null s = process ss
      | otherwise = [a ++ b | a <- chp_permutations (Set.toList s), b <- process ss]

--type SeqId = Integer
--type CM eventId = ContT (EventMap eventId) (State (Seq.Seq (Set.Set (RecordedEvent eventId))))

type EventMap eventId = Map.Map (RecordedIndivEvent eventId) (Set.Set ProcessId)

combine :: Ord u => [EventMap u] -> EventMap u
combine = foldl (Map.unionWith Set.union) Map.empty

participants :: Ord u => EventHierarchy (RecordedIndivEvent u)
             -> Map.Map (RecordedIndivEvent u) Int
{-participants (SingleEvent e)
  = Map.singleton (recordedIndivEventLabel e, recordedIndivEventSeq e) 1
participants (StructuralSequence _ ss)
  = combine $ map participants ss
participants (StructuralParallel ps)
  = combine $ map participants ps
-}
participants = F.foldr
 (\e -> Map.insertWith (+) e 1)
 Map.empty

single :: RecordedIndivEvent u -> ProcessId -> EventMap u
single k v = Map.singleton k (Set.singleton v)

data Cont u = Cont (EventMap u) ([RecordedIndivEvent u] -> Cont u)
            | ContDone

instance Monoid (Cont u) where
  mempty = ContDone
  mappend ContDone r = r
  mappend (Cont m f) r = Cont m (\e -> f e `mappend` r)

makeCont :: Ord u => EventHierarchy (RecordedIndivEvent u) -> ProcessId -> Cont u
makeCont (SingleEvent e) pid = c
  where
    c = Cont (single e pid) wait
    wait e'
      | e `elem` e' = ContDone
      | otherwise = c
makeCont (StructuralSequence 0 _) _ = ContDone
makeCont (StructuralSequence n es) pid
  = mconcat (zipWith makeCont es pidsPlusOne)
      `mappend` makeCont (StructuralSequence (n-1) es) (last pidsPlusOne)
  where
    pidsPlusOne = take (1 + length es) $ iterate incPid pid

    incPid (ProcessId ps) = ProcessId $ init ps ++ [ParSeq p (succ s)]
      where
        ParSeq p s = last ps
makeCont (StructuralParallel es) pid
  = mergePar (zipWith makeCont es (parPids pid))
  where
    parPids (ProcessId ps) = [ProcessId $ ps ++ [ParSeq i 0] | i <- [0..]]

mergePar :: Ord u => [Cont u] -> Cont u
mergePar cs = case [ m | Cont m _f <- cs] of
                [] -> ContDone
                ms -> Cont (combine ms) (\e -> mergePar [f e | Cont _m f <- cs])

-- | Takes a structural trace and forms all the possible VCR traces (without
-- duplicates) that could have arisen from the same execution.
--
-- This is done -- roughly speaking -- by replaying the structural trace in all
-- possible execution orderings and pulling out the VCR trace for each ordering.
--
-- This function was added in version 1.5.0.
structuralToVCR :: Ord u => StructuralTrace u -> [VCRTrace u]
structuralToVCR (StructuralTrace (ls, Nothing)) = [VCRTrace (ls, [])]
structuralToVCR (StructuralTrace (ls, Just str))
  = nubBy eq [VCRTrace (ls, map (Set.map snd) $ reverse $ toVCR $ reverse tr) | tr <- flattenStructural str]
  where
    eq (VCRTrace (_, a)) (VCRTrace (_, b)) = a == b

toVCR :: Ord u => [(RecordedEvent u, Set.Set ProcessId)]
      -> [(Set.Set (Set.Set ProcessId, RecordedEvent u))]
toVCR [] = []
toVCR ((e, pids) : rest)
  = prependVCR (toVCR rest) pids [(pids, e)]

-- | Takes a structural trace and forms all the possible CSP traces (without
-- duplicates) that could have arisen from the same execution.
--
-- This is done -- roughly speaking -- by replaying the structural trace in all
-- possible execution orderings and pulling out the CSP trace for each ordering.
--
-- It should be the case for all structural traces @t@ that do not use conjunction ('every' and
-- '(\<&\>)'):
-- 
-- > structuralToCSP t =~= (concatMap vcrToCSP . structuralToVCR) t
-- >   where a =~= b = or [a' == b' | a' <- permutations a, b' <- permutations  b]
--
-- This function was added in version 1.5.0.
structuralToCSP :: Ord u => StructuralTrace u -> [CSPTrace u]
structuralToCSP (StructuralTrace (ls, Nothing)) = [CSPTrace (ls, [])]
structuralToCSP (StructuralTrace (ls, Just str))
  = [CSPTrace (ls, map fst tr) | tr <- flattenStructural str]

flattenStructural :: forall u. Ord u => EventHierarchy (RecordedIndivEvent u) -> [[(RecordedEvent u, Set.Set ProcessId)]]
flattenStructural tr
  = process $ makeCont tr rootProcessId
  where
    ps = participants tr

    process :: Cont u -> [[(RecordedEvent u, Set.Set ProcessId)]]
    process ContDone = [[]]
    process (Cont m f)
      = concat [map ((e, pids) :) $ process (f ie)
               | (e,(ie,pids)) <- Map.toAscList eventsWithAllParticipants]
      where
        indivEventsWithAllParticipants :: Map.Map (RecordedIndivEvent u) (Set.Set ProcessId)
        indivEventsWithAllParticipants = Map.map fst $ Map.filter (\(s, n) -> Set.size s == n) (Map.intersectionWith (,) m ps)

        eventsWithAllParticipants :: Map.Map (RecordedEvent u) ([RecordedIndivEvent u], Set.Set ProcessId)
        eventsWithAllParticipants
          = Map.map snd $
              Map.filterWithKey fixEvents $
              Map.mapKeysWith mergeVals toWhole $
              Map.map ((,) False . first (:[])) $
              Map.mapWithKey (,) $
              indivEventsWithAllParticipants
          where
            mergeVals :: (Bool, ([RecordedIndivEvent u], Set.Set ProcessId))
                      -> (Bool, ([RecordedIndivEvent u], Set.Set ProcessId))
                      -> (Bool, ([RecordedIndivEvent u], Set.Set ProcessId))
            mergeVals (_, (es, pids)) (_, (es', pids'))
              = (True, (es ++ es', Set.union pids pids'))

    fixEvents :: RecordedEvent a -> (Bool, b) -> Bool
    fixEvents (ChannelComm _, _) (b, _) = b -- Channel comms need to have both sides
    fixEvents _ _ = True

    toWhole :: RecordedIndivEvent a -> RecordedEvent a
    toWhole (ChannelWrite x _ s) = (ChannelComm s, x)
    toWhole (ChannelRead x _ s) = (ChannelComm s, x)
    toWhole (BarrierSyncIndiv x _ s) = (BarrierSync s, x)
    toWhole (ClockSyncIndiv x _ t) = (ClockSync t, x)
    
