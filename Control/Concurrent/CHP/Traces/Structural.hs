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

-- | This module contains support for structural traces.  Structural
-- traces reflect the parallel composition of your program.  Effectively,
-- each process records its own local trace.  Parallel traces are then
-- merged as parallel compositions, and you end up with a big tree of
-- sequentially and parallel-composed traces.  Note that in this tracing
-- style, unlike CSP and VCR, events are recorded by /every/ process
-- involved in them, not just once per occurrence.
module Control.Concurrent.CHP.Traces.Structural (StructuralTrace(..), EventHierarchy(..), getStructuralPlain, runCHP_StructuralTrace, runCHP_StructuralTraceAndPrint,
  getAllEventsInHierarchy) where

import Control.Applicative hiding (empty)
import qualified Data.Foldable as F
import Data.IORef
import Data.List
import qualified Data.Map as Map
import Data.Maybe
import qualified Data.Traversable as T
import Data.Unique
import Text.PrettyPrint.HughesPJ

import Control.Concurrent.CHP.Base
import Control.Concurrent.CHP.Traces.Base

-- | A data type representing a hierarchy of events.  The count on the StructuralSequence
-- count is a replicator count for that list of sequential items.
--
-- The Show, Read, Foldable and Traversable instances were added in version 1.3.0.
--
-- The Eq instance was added in version 1.5.0.
data EventHierarchy a =
  SingleEvent a
  | StructuralSequence Int [EventHierarchy a]
  | StructuralParallel [EventHierarchy a]
  deriving (Show, Read)

instance Eq a => Eq (EventHierarchy a) where
  (SingleEvent x) == (SingleEvent y) = x == y
  (StructuralSequence m es) == (StructuralSequence m' es')
    = concat (replicate m es) == concat (replicate m' es')
  (StructuralParallel es) == (StructuralParallel es')
    = es `bagsEq` es'

  (StructuralSequence 1 [x]) == y = x == y
  x == (StructuralSequence 1 [y]) = x == y
  (StructuralParallel [x]) == y = x == y
  x == (StructuralParallel [y]) = x == y
  _ == _ = False

instance Functor EventHierarchy where
  fmap f (SingleEvent x) = SingleEvent $ f x
  fmap f (StructuralSequence n es) = StructuralSequence n $ map (fmap f) es
  fmap f (StructuralParallel es) = StructuralParallel $ map (fmap f) es

instance F.Foldable EventHierarchy where
  foldr f y (SingleEvent x) = f x y
  foldr f y (StructuralSequence _ es) = F.foldr (flip $ F.foldr f) y es
  foldr f y (StructuralParallel es) = F.foldr (flip $ F.foldr f) y es

instance T.Traversable EventHierarchy where
  traverse f (SingleEvent x) = SingleEvent <$> f x
  traverse f (StructuralSequence n es) = StructuralSequence n <$> T.traverse (T.traverse f) es
  traverse f (StructuralParallel es) = StructuralParallel <$> T.traverse (T.traverse f) es

-- | Flattens the events into a list.  The resulting list may contain duplicates, and it
-- should not be assumed that the order relates in any way to the original
-- hierarchy.
getAllEventsInHierarchy :: EventHierarchy a -> [a]
getAllEventsInHierarchy (SingleEvent e) = [e]
getAllEventsInHierarchy (StructuralSequence _ es) = concatMap getAllEventsInHierarchy es
getAllEventsInHierarchy (StructuralParallel es) = concatMap getAllEventsInHierarchy es


-- | A nested (or hierarchical) trace.  The trace is an event hierarchy, wrapped
-- in a Maybe type to allow for representation of the empty trace (Nothing).
newtype StructuralTrace u = StructuralTrace (ChannelLabels u, Maybe (EventHierarchy (RecordedIndivEvent u)))

instance Ord u => Show (StructuralTrace u) where
  show = renderStyle (Style OneLineMode 1 1) . prettyPrint

instance Trace StructuralTrace where
  emptyTrace = StructuralTrace (Map.empty, Nothing)
  runCHPAndTrace p = do trV <- newIORef $ RevSeq []
                        let st = (Hierarchy trV)
                        runCHPProgramWith' st (flip toPublic st) p

  prettyPrint (StructuralTrace (_,Nothing)) = empty
  prettyPrint (StructuralTrace (labels, Just h))
    = pp $ T.mapM nameIndivEvent h `labelWith` labels
    where
      pp :: EventHierarchy String -> Doc
      pp (SingleEvent x) = text x
      pp (StructuralSequence 1 es)
        = sep $ intersperse (text "->") $ map pp es
      pp (StructuralSequence n es)
        = int n <> char '*' <> parens (sep $
            intersperse (text "->") $ map pp es)
      pp (StructuralParallel es)
        = parens $ sep $ intersperse (text "||") $ map pp es

  labelAll (StructuralTrace (_, Nothing)) = StructuralTrace (Map.empty, Nothing)
  labelAll (StructuralTrace (labels, Just h))
    = StructuralTrace (Map.empty, Just $ T.mapM nameIndivEvent' h `labelWith` labels)

toPublic :: ChannelLabels Unique -> SubTraceStore -> IO (StructuralTrace Unique)
toPublic l (Hierarchy hv)
  = do h <- readIORef hv
       return $ StructuralTrace (l, conv h)
  where
    nonEmptyListToMaybe :: ([a] -> b) -> [a] -> Maybe b
    nonEmptyListToMaybe _ [] = Nothing
    nonEmptyListToMaybe f xs = Just $ f xs

    mapToMaybe :: ([b] -> c) -> (a -> Maybe b) -> [a] -> Maybe c
    mapToMaybe f g = nonEmptyListToMaybe f . mapMaybe g
    
    conv :: Ord a => Structured a -> Maybe (EventHierarchy a)
    conv (StrEvent x) = Just $ SingleEvent x
    conv (Par es) = mapToMaybe StructuralParallel conv es
    conv (RevSeq []) = Nothing
    conv (RevSeq [(0, _)]) = Nothing
    conv (RevSeq [(n, ss)]) = mapToMaybe (StructuralSequence n) conv (reverse ss)
    conv (RevSeq es) = trans
      where
        rev = reverse es
        trans = mapToMaybe (StructuralSequence 1) (\(n,s) -> mapToMaybe (StructuralSequence n) conv $
          reverse s) rev
toPublic _ _ = error "Error in Structural trace -- tracing type got switched"

-- | A helper function for pulling out the interesting bit from a Structural trace processed
-- by labelAll.
--
-- Added in version 1.5.0.
getStructuralPlain :: StructuralTrace String -> Maybe (EventHierarchy (RecordedIndivEvent String))
getStructuralPlain (StructuralTrace (ls, t))
  | Map.null ls = t
  | otherwise = error "getStructuralPlain: remaining unused labels"

runCHP_StructuralTrace :: CHP a -> IO (Maybe a, StructuralTrace Unique)
runCHP_StructuralTrace = runCHPAndTrace

runCHP_StructuralTraceAndPrint :: CHP a -> IO ()
runCHP_StructuralTraceAndPrint p
  = do (_, tr) <- runCHP_StructuralTrace p
       putStrLn $ show tr


