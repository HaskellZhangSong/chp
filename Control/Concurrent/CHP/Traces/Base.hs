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

module Control.Concurrent.CHP.Traces.Base where

import Control.Concurrent.STM
import Control.Monad (liftM)
import Data.IORef
import Data.List
import qualified Data.Map as Map
import qualified Data.Set as Set
import Data.Unique

import Control.Concurrent.CHP.Event
import Control.Concurrent.CHP.ProcessId

-- | A globally recorded event, found in CSP and VCR traces.  Either a
-- channel communication (with a unique identifier of the channel) or a
-- barrier synchronisation (with a unique identifier of the barrier).  The
-- identifiers are per channel\/barrier, not per event.  Currently,
-- channels and barriers can never have the same Unique as each other, but
-- do not rely on this behaviour.
--
-- The type became parameterised in version 1.3.0.
type RecordedEvent u = (RecordedEventType, u)

-- | An individual record of an event, found in nested traces.  Either a
-- channel write or read, or a barrier synchronisation, each with a unique
-- identifier for the barrier\/channel.  The event will be recorded by
-- everyone involved, and a ChannelWrite will have the same channel
-- identifier as the corresponding channel-read.  The identifiers are per
-- channel\/barrier, not per event.  Currently, channels and barriers can
-- never have the same Unique as each other, but do not rely on this
-- behaviour.
--
-- The type u item is the unique identifier of the channel/barrier/clock, and the
-- Integer is a sequence identifier for that channel/barrier/clock (first sync
-- is 0, second sync is 1, etc), and finally the String shows the value-sent/phase-ended/time
-- involved.
--
-- ClockSyncIndiv was added in version 1.2.0.
--
-- The type became parameterised, and the Show and Read instances were added in version 1.3.0.
--
-- The String parameters on ChannelWrite, ChannelRead and BarrierSyncIndiv were
-- added in version 1.5.0.
data RecordedIndivEvent u = 
  ChannelWrite u Integer String
  | ChannelRead u Integer String
  | BarrierSyncIndiv u Integer String
  | ClockSyncIndiv u Integer String
  deriving (Eq, Ord, Read, Show)

-- | Added in version 1.3.0.
recordedIndivEventLabel :: RecordedIndivEvent u -> u
recordedIndivEventLabel (ChannelWrite x _ _) = x
recordedIndivEventLabel (ChannelRead x _ _) = x
recordedIndivEventLabel (BarrierSyncIndiv x _ _) = x
recordedIndivEventLabel (ClockSyncIndiv x _ _) = x

-- | Added in version 1.3.0.
recordedIndivEventSeq :: RecordedIndivEvent u -> Integer
recordedIndivEventSeq (ChannelWrite _ n _) = n
recordedIndivEventSeq (ChannelRead _ n _) = n
recordedIndivEventSeq (BarrierSyncIndiv _ n _) = n
recordedIndivEventSeq (ClockSyncIndiv _ n _) = n

indivRec :: (u -> Integer -> String -> RecordedIndivEvent u)
            -> u -> (u -> Integer) -> String -> (RecordedIndivEvent u)
indivRec r u f = r u (f u)

indivRecJust :: (u -> Integer -> String -> RecordedIndivEvent u)
                -> u -> (u -> Integer) -> String -> [RecordedIndivEvent u]
indivRecJust r u f x = [indivRec r u f x]

type RecEvents = ([RecordedEvent Unique], [RecordedIndivEvent Unique])

data LabelM u a = LabelM { runLabelM :: ChannelLabels u -> (a, ChannelLabels u) }

labelWith :: LabelM u a -> ChannelLabels u -> a
labelWith = (fst .) . runLabelM

instance Monad (LabelM u) where
  return = LabelM . (,)
  m >>= k = LabelM $ \s -> let (a, s') = runLabelM m s in runLabelM (k a) s'

getName :: Ord u => String -> u -> LabelM u String
getName prefix u = LabelM $ \m ->
               case Map.lookup u m of
                 Just x -> (x, m)
                 Nothing -> let x = prefix ++ show (Map.size m) in (x, Map.insert u x m)

nameEvent :: Ord u => RecordedEvent u -> LabelM u String
nameEvent (t, c) = liftM (++ suffix) $ getName prefix c
  where
    (prefix, suffix) = case t of
      ChannelComm x -> ("_c", if null x then "" else '.' : x)
      BarrierSync x -> ("_b", if null x then "" else '.' : x)
      ClockSync st -> ("_t", ':' : st)

nameEvent' :: Ord u => RecordedEvent u -> LabelM u (RecordedEvent String)
nameEvent' (t, c) = do c' <- getName prefix c
                       return (t, c' ++ suffix)
  where
    (prefix, suffix) = case t of
      ChannelComm _ -> ("_c", "")
      BarrierSync _ -> ("_b", "")
      ClockSync st -> ("_t", ':' : st)


nameIndivEvent :: Ord u => RecordedIndivEvent u -> LabelM u String
nameIndivEvent (ChannelWrite c n _) = do c' <- getName "_c" c
                                         return $ c' ++ "![" ++ show n ++ "]"
nameIndivEvent (ChannelRead c n _) = do c' <- getName "_c" c
                                        return $ c' ++ "?[" ++ show n ++ "]"
nameIndivEvent (BarrierSyncIndiv c n _) = do c' <- getName "_b" c
                                             return $ c' ++ "[" ++ show n ++ "]"
nameIndivEvent (ClockSyncIndiv c n t) = do c' <- getName "_t" c
                                           return $ c' ++ ":" ++ t
                                             ++ "[" ++ show n ++ "]"

nameIndivEvent' :: Ord u => RecordedIndivEvent u -> LabelM u (RecordedIndivEvent String)
nameIndivEvent' (ChannelWrite c n x) = do c' <- getName "_c" c
                                          return $ ChannelWrite c' n x
nameIndivEvent' (ChannelRead c n x) = do c' <- getName "_c" c
                                         return $ ChannelRead c' n x
nameIndivEvent' (BarrierSyncIndiv c n x) = do c' <- getName "_b" c
                                              return $ BarrierSyncIndiv c' n x
nameIndivEvent' (ClockSyncIndiv c n t) = do c' <- getName "_t" c
                                            return $ ClockSyncIndiv c' n t


data TraceStore =
  NoTrace ProcessId
  | Trace (ProcessId, TVar (ChannelLabels Unique), SubTraceStore)

mapSubTrace :: Monad m => (SubTraceStore -> m ()) -> TraceStore -> m ()
mapSubTrace _ (NoTrace {}) = return ()
mapSubTrace f (Trace (_pid, _tv, s)) = f s

type ChannelLabels u = Map.Map u String

data SubTraceStore =
  Hierarchy (IORef (Structured (RecordedIndivEvent Unique)))
  | CSPTraceRev (TVar [(Int, [RecordedEvent Unique])])
  | VCRTraceRev (TVar [Set.Set (Set.Set ProcessId, RecordedEvent Unique)])

data Ord a => Structured a =
  StrEvent a
  | Par [Structured a]
  | RevSeq [(Int, [Structured a])]
  deriving (Eq, Ord)

-- | Records an event where you were the last person to engage in the event
recordEventLast :: [(RecordedEvent Unique, Set.Set ProcessId)] -> TraceStore -> STM ()
recordEventLast news y
           =    case y of
                  Trace (_,_,CSPTraceRev tv) ->
                    do t <- readTVar tv
                       writeTVar tv $! foldl (flip addRLE) t (map fst news)
                  Trace (pid, _, VCRTraceRev tv) -> do
                    t <- readTVar tv
                    let news' = map (\(a,b) -> (b,a)) news
                        pidSet = (foldl Set.union (Set.singleton pid) $ map fst news')
                        t' = prependVCR t pidSet news'
                    writeTVar tv $! t'
                  _ -> return ()

prependVCR :: Ord u =>
             [Set.Set (Set.Set ProcessId, RecordedEvent u)]
          -> Set.Set ProcessId
          -> [(Set.Set ProcessId, RecordedEvent u)]
          -> [Set.Set (Set.Set ProcessId, RecordedEvent u)]
prependVCR t pidSet news'
  = case t of
      -- Trace previously empty:
      [] -> [Set.fromList news']
      (z:zs) | shouldMakeNewSetVCR pidSet z
                 -> Set.fromList news' : t
             | otherwise
                 -> foldl (flip Set.insert) z news' : zs

-- | Records an event where you were one of the people involved
recordEvent :: [RecordedIndivEvent Unique] -> TraceStore -> IO ()
recordEvent e = mapSubTrace recH
  where
    recH (Hierarchy es) = modifyIORef es (addParEventsH (map StrEvent e))
    recH _ = return ()

mergeSubProcessTraces :: [TraceStore] -> TraceStore -> IO ()
mergeSubProcessTraces ts
  = mapSubTrace merge
  where
    ts' = mapM readIORef [t | Trace (_,_,Hierarchy t) <- ts]
    merge (Hierarchy es) = ts' >>= modifyIORef es . addParEventsH
    merge _ = return ()

shouldMakeNewSetVCR :: Ord u => Set.Set ProcessId -> Set.Set (Set.Set ProcessId, RecordedEvent u)
  -> Bool
shouldMakeNewSetVCR newpids existingSet
  = exists existingSet $ \(bigP,_) -> exists bigP $ \p -> exists newpids $ \q ->
      p `pidLessThanOrEqual` q
  where
    -- Like the any function (flipped), but for sets:
    exists :: Ord a => Set.Set a -> (a -> Bool) -> Bool
    exists s f = not . Set.null $ Set.filter f s


compress :: (Eq a, Ord a) => Structured a -> Structured a
compress (RevSeq ((1,s):(n,s'):ss))
  | n == 1 && (s `isPrefixOf` s') = compress $ RevSeq $ (2,s):(1,drop (length s) s'):ss
  | s == s' = compress $ RevSeq $ (n+1,s'):ss
compress x = x


addParEventsH :: (Eq a, Ord a) => [Structured a] -> Structured a -> Structured a
addParEventsH es t = let n = es in case t of
  StrEvent _ -> RevSeq [(1, [Par n, t])]
  Par _ -> RevSeq [(1, [Par n, t])]
  RevSeq ((1,s):ss) -> compress $ RevSeq $ (1,Par n : s) : ss
  RevSeq ss -> compress $ RevSeq $ (1, [Par n]):ss

addSeqEventH :: (Eq a, Ord a) => a -> Structured a -> Structured a
addSeqEventH e (StrEvent e') = RevSeq [(1,[StrEvent e, StrEvent e'])]
addSeqEventH e (Par p) = RevSeq [(1,[StrEvent e, Par p])]
addSeqEventH e (RevSeq ((1,s):ss))
  | (StrEvent e) `notElem` s = compress $ RevSeq $ (1,StrEvent e:s):ss
addSeqEventH e (RevSeq ss) = compress $ RevSeq $ (1,[StrEvent e]):ss


addRLE :: Eq a => a -> [(Int,[a])] -> [(Int,[a])]
-- Single event in most recent list:
addRLE x ((n,[e]):nes)
  -- If we have the same event, bump up the count:
  | x == e = (n+1,[e]):nes
-- Only one list thus far
addRLE x allEs@[(1,es)]
  -- If we are the same as the most recent event, break it off and aggregate:
  | x == head es = [(2, [x]), (1, tail es)]
  -- If we're already in that list, start a new one:
  | x `elem` es = (1,[x]):allEs
  -- Otherwise join the queue!
  | otherwise = [(1,x:es)]
-- Most recent list has count of 1
addRLE x allEs@((1,es):(n,es'):nes)
  -- If adding us to the most recent list forms an identical list to the one
  -- before that, aggregate
  | x == head es' && es == tail es' = (n+1,es'):nes
  -- If we're already in that list, start a new one:
  | x `elem` es = (1,[x]):allEs
  -- Otherwise, join the most recent list
  | otherwise = (1,x:es):(n,es'):nes
-- If no special cases hold, start a new list:
addRLE x nes = (1,[x]):nes


labelEvent :: TraceStore -> Event -> String -> IO ()
labelEvent t e = labelUnique t (getEventUnique e)

labelUnique :: TraceStore -> Unique -> String -> IO ()
labelUnique t u l
  = case t of
       NoTrace {} -> return ()
       Trace (_,tvls,_) -> add tvls
  where
    add :: TVar (Map.Map Unique String) -> IO ()
    add tv = atomically $ do
      m <- readTVar tv
      writeTVar tv $ Map.insert u l m

newIds :: Int -> ProcessId -> [ProcessId]
newIds n pid = let ProcessId parts = pid in
  [ProcessId $ parts ++ [ParSeq i 0] | i <- [0 .. (n - 1)]]

blankTraces :: TraceStore -> Int -> IO [TraceStore]
blankTraces (NoTrace pid) n = return $ map NoTrace $ newIds n pid
blankTraces (Trace (pid, tvls, subT)) n =
  sequence [liftM (\s -> Trace (newId, tvls, s)) newSubT | newId <- newIds n pid]
  where
    newSubT :: IO SubTraceStore
    newSubT = case subT of
      Hierarchy {} -> liftM Hierarchy $ newIORef $ RevSeq []
      _ -> return subT

-- Taken from base-4, as we only require base-3:
chp_permutations            :: [b] -> [[b]]
chp_permutations xs0        =  xs0 : perms xs0 []
        where
          perms []     _  = []
          perms (t:ts) is = foldr interleave (perms ts (t:is)) (chp_permutations is)
            where
                interleave    xs     r = let (_,zs) = interleave' id xs r in zs
                interleave' _ []     r = (ts, r)
                interleave' f (y:ys) r = let (us,zs) = interleave' (f . (y:)) ys r
                                         in (y:us, f (t:y:us) : zs)

bagsEq :: Eq a => [a] -> [a] -> Bool
bagsEq a b = or [a' == b' | a' <- chp_permutations a, b' <- chp_permutations b]

        
