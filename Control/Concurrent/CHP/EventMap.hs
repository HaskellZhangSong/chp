-- Communicating Haskell Processes.
-- Copyright (c) 2010, Neil Brown.
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

module Control.Concurrent.CHP.EventMap (empty, insert, keysSet, minViewWithKey, toList, unionWith, unionWithM, values) where

import Control.Concurrent.CHP.EventType
import Control.Monad (liftM)
import Data.Ord (comparing)
import Prelude hiding (lookup)

{-
instance Functor EventMap where
  fmap f = List.map (second f)

instance Foldable EventMap where
  foldr f x = foldr (f . snd) x

instance Traversable EventMap where
  traverse f = traverse (\(e, v) -> (,) e <$> f v)
-}

type ListMap k v = [(k, v)]

empty :: ListMap k v
empty = []

unionWith :: Ord k => (a -> a -> a) -> ListMap k a -> ListMap k a -> ListMap k a
{-# SPECIALISE unionWith :: (a -> a -> a) -> ListMap Event a -> ListMap Event a -> ListMap Event a #-}
unionWith f = union'
  where
    union' [] ys = ys
    union' xs [] = xs
    union' allxs@(x:xs) allys@(y:ys) = case comparing fst x y of
      LT -> x : union' xs allys
      EQ -> (fst x, f (snd x) (snd y)) : union' xs ys
      GT -> y : union' allxs ys

unionWithM :: (Ord k, Monad m) => (Maybe a -> Maybe b -> m c) ->
  ListMap k a -> ListMap k b -> m (ListMap k c)
{-# SPECIALISE unionWithM :: (Maybe a -> Maybe b -> Maybe c) ->
  ListMap OfferSet a -> ListMap OfferSet b -> Maybe (ListMap OfferSet c) #-}
unionWithM f = (sequence .) . union'
  where
    mapSM g = map (\(x, y) -> (,) x `liftM` g y)

    union' [] ys = mapSM (f Nothing . Just) ys
    union' xs [] = mapSM (flip f Nothing . Just) xs
    union' allxs@(x:xs) allys@(y:ys) = case compare (fst x) (fst y) of
      LT -> (,) (fst x) `liftM` f (Just $ snd x) Nothing : union' xs allys
      EQ -> ((,) (fst x) `liftM` f (Just $ snd x) (Just $ snd y)) : union' xs ys
      GT -> (,) (fst y) `liftM` f Nothing (Just $ snd y) : union' allxs ys

keysSet :: ListMap k a -> [k]
keysSet = map fst

toList :: ListMap k a -> [(k, a)]
toList = id

insert :: Ord k => k -> a -> ListMap k a -> ListMap k a
{-# SPECIALISE insert :: OfferSet -> a -> ListMap OfferSet a -> ListMap OfferSet a #-}
insert k v = insert'
  where
    insert' [] = [(k, v)]
    insert' allxs@(x:xs) = case compare k (fst x) of
      LT -> (k, v) : allxs
      EQ -> (k, v) : xs
      GT -> x : insert' xs

minViewWithKey :: ListMap k v -> Maybe ((k, v), ListMap k v)
minViewWithKey [] = Nothing
minViewWithKey (x:xs) = Just (x, xs)

values :: ListMap k v -> [v]
values = map snd
