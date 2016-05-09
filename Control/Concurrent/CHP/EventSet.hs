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

module Control.Concurrent.CHP.EventSet (delete, deleteOrFail, empty, fromList, insert, intersection, member, null, toList, toMap, union) where

import Control.Arrow ((&&&))
import Control.Concurrent.CHP.EventType
import qualified Data.List as List

type ListSet k = [k]

empty :: ListSet k
empty = []

toList :: ListSet k -> [k]
toList x = x

delete :: Ord k => k -> ListSet k -> ListSet k
{-# SPECIALISE delete :: Event -> ListSet Event -> ListSet Event #-}
{-# SPECIALISE delete :: OfferSet -> ListSet OfferSet -> ListSet OfferSet #-}
delete e = delete'
  where
    delete' [] = []
    delete' allxs@(x:xs) = case compare e x of
      LT -> allxs
      EQ -> xs
      GT -> x : delete' xs

-- If the element is present, returns Just the set without it
-- If the element is not present, returns Nothing
deleteOrFail :: Ord k => k -> ListSet k -> Maybe (ListSet k)
{-# SPECIALISE deleteOrFail :: Event -> ListSet Event -> Maybe (ListSet Event) #-}
deleteOrFail e = deleteOrFail'
  where
    deleteOrFail' [] = Nothing
    deleteOrFail' (x:xs) = case compare e x of
      LT -> Nothing
      EQ -> Just xs
      GT -> case deleteOrFail' xs of
              Just xs' -> Just (x : xs')
              Nothing -> Nothing

member :: Ord k => k -> ListSet k -> Bool
{-# SPECIALISE member :: Event -> ListSet Event -> Bool #-}
member e = member'
  where
    member' [] = False
    member' (x:xs) = case compare e x of
      LT -> False
      EQ -> True
      GT -> member' xs

insert :: Ord k => k -> ListSet k -> ListSet k
{-# SPECIALISE insert :: OfferSet -> ListSet OfferSet -> ListSet OfferSet #-}
insert k = insert'
  where
    insert' [] = [k]
    insert' allxs@(x:xs) = case compare k x of
      LT -> k : allxs
      EQ -> k : xs -- replace with new value
      GT -> x : insert' xs


union :: Ord k => ListSet k -> ListSet k -> ListSet k
{-# SPECIALISE union :: ListSet Event -> ListSet Event -> ListSet Event #-}
union [] ys = ys
union xs [] = xs
union allxs@(x:xs) allys@(y:ys) = case compare x y of
  LT -> x : union xs allys
  EQ -> x : union xs ys -- left-bias
  GT -> y : union allxs ys

intersection :: Ord k => ListSet k -> ListSet k -> ListSet k
{-# SPECIALISE intersection :: ListSet OfferSet -> ListSet OfferSet -> ListSet OfferSet #-}
intersection [] _ = []
intersection _ [] = []
intersection allxs@(x:xs) allys@(y:ys) = case compare x y of
  LT -> intersection xs allys
  EQ -> x : intersection xs ys -- left-bias
  GT -> intersection allxs ys

fromList :: Ord k => [k] -> ListSet k
{-# SPECIALISE fromList :: [Event] -> ListSet Event #-}
fromList = List.sort

toMap :: (k -> v) -> [k] -> [(k, v)]
toMap f = map (id &&& f)
