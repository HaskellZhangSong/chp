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

-- | This module contains support for CSP-style tracing.  A CSP trace is simply
-- a flat list of events in the order in which they occurred.
module Control.Concurrent.CHP.Traces.CSP (CSPTrace(..), getCSPPlain, runCHP_CSPTrace, runCHP_CSPTraceAndPrint) where

import Control.Concurrent.STM
import Control.Monad (liftM)
import qualified Data.Map as Map
import Data.Unique
import Text.PrettyPrint.HughesPJ

import Control.Concurrent.CHP.Base
import Control.Concurrent.CHP.Traces.Base

-- | A classic CSP trace.  It is simply the channel labels, and a list of recorded
-- events in sequence -- the head of the list is the first (oldest) event.
newtype CSPTrace u = CSPTrace (ChannelLabels u, [RecordedEvent u])

instance Ord u => Show (CSPTrace u) where
  show = renderStyle (Style OneLineMode 1 1) . prettyPrint

instance Trace CSPTrace where
  emptyTrace = CSPTrace (Map.empty, [])
  runCHPAndTrace p = do tv <- atomically $ newTVar []
                        let st = CSPTraceRev tv
                        runCHPProgramWith' st (flip toPublic st) p

  prettyPrint (CSPTrace (labels, events))
    = char '<' <+> sep (punctuate (char ',') $ mapM (liftM text . nameEvent) events `labelWith` labels) <+> char '>'

  labelAll (CSPTrace (labels, events))
    = CSPTrace (Map.empty, mapM nameEvent' events `labelWith` labels)

toPublic :: ChannelLabels Unique -> SubTraceStore -> IO (CSPTrace Unique)
toPublic l (CSPTraceRev tv)
  = do list <- atomically $ readTVar tv
       return $ CSPTrace (l, concatMap (\(n,es) -> concat $ replicate n $ reverse es) $ reverse list)
toPublic _ _ = error "Error in CSP trace -- tracing type got switched"

-- | A helper function for pulling out the interesting bit from a CSP trace processed
-- by labelAll.
--
-- Added in version 1.5.0.
getCSPPlain :: CSPTrace String -> [RecordedEvent String]
getCSPPlain (CSPTrace (ls, t))
  | Map.null ls = t
  | otherwise = error "getCSPPlain: remaining unused labels"

runCHP_CSPTrace :: CHP a -> IO (Maybe a, CSPTrace Unique)
runCHP_CSPTrace = runCHPAndTrace

runCHP_CSPTraceAndPrint :: CHP a -> IO ()
runCHP_CSPTraceAndPrint p = do (_, tr) <- runCHP_CSPTrace p
                               putStrLn $ show tr


