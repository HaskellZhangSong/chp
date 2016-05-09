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

-- | A module for recording View Centric Reasoning (VCR) traces.  A view centric
-- reasnoning trace is a list of sets of events.  Each set contains independent
-- events that have no causal relationship between them.  Hopefully we will
-- publish a paper explaining all this in detail soon.
module Control.Concurrent.CHP.Traces.VCR (VCRTrace(..), getVCRPlain, runCHP_VCRTrace, runCHP_VCRTraceAndPrint) where

import Control.Concurrent.STM
import Control.Monad (liftM)
import qualified Data.Map as Map
import qualified Data.Set as Set
import Data.Unique
import Text.PrettyPrint.HughesPJ

import Control.Concurrent.CHP.Base
import Control.Concurrent.CHP.Traces.Base

-- | A VCR (View-Centric Reasoning) trace.  It is the channel labels,
-- accompanied by a sequential list of sets of recorded events.  Each of
-- the sets is a set of independent events.  The set at the head of the
-- list is the first-recorded (oldest).
--
-- The type became parameterised in version 1.3.0
newtype VCRTrace u = VCRTrace (ChannelLabels u, [Set.Set (RecordedEvent u)])

instance Ord u => Show (VCRTrace u) where
  show = renderStyle (Style OneLineMode 1 1) . prettyPrint

instance Trace VCRTrace where
  emptyTrace = VCRTrace (Map.empty, [])
  runCHPAndTrace p = do tv <- atomically $ newTVar []
                        let st = VCRTraceRev tv
                        runCHPProgramWith' st (flip toPublic st) p

  prettyPrint (VCRTrace (labels, eventSets))
    = char '<' <+> sep (punctuate (char ',') $ map (braces . sep . punctuate (char ',')) ropes) <+> char '>'
    where
      es = mapM nameVCR eventSets `labelWith` labels

      ropes :: [[Doc]]
      ropes = map (map text . Set.toList) es

  labelAll (VCRTrace (labels, eventSets))
    = VCRTrace (Map.empty, mapM nameVCR' eventSets `labelWith` labels)

toPublic :: ChannelLabels Unique -> SubTraceStore -> IO (VCRTrace Unique)
toPublic l (VCRTraceRev tv)
  = do setList <- atomically $ readTVar tv
       return $ VCRTrace (l, map (Set.map snd) $ reverse setList)
toPublic _ _ = error "Error in VCR trace -- tracing type got switched"

nameVCR :: Ord u => Set.Set (RecordedEvent u) -> LabelM u (Set.Set String)
nameVCR = liftM Set.fromList . mapM nameEvent . Set.toList

nameVCR' :: Ord u => Set.Set (RecordedEvent u) -> LabelM u (Set.Set (RecordedEvent String))
nameVCR' = liftM Set.fromList . mapM nameEvent' . Set.toList

-- | A helper function for pulling out the interesting bit from a VCR trace processed
-- by labelAll.
--
-- Added in version 1.5.0.
getVCRPlain :: VCRTrace String -> [Set.Set (RecordedEvent String)]
getVCRPlain (VCRTrace (ls, t))
  | Map.null ls = t
  | otherwise = error "getVCRPlain: remaining unused labels"

runCHP_VCRTrace :: CHP a -> IO (Maybe a, VCRTrace Unique)
runCHP_VCRTrace = runCHPAndTrace

runCHP_VCRTraceAndPrint :: CHP a -> IO ()
runCHP_VCRTraceAndPrint p = do (_, tr) <- runCHP_VCRTrace p
                               putStrLn $ show tr


