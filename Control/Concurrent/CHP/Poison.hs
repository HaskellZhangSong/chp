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

module Control.Concurrent.CHP.Poison where

import Control.Concurrent.STM
import Control.Monad
-- | A Maybe-like poison wrapper.
data WithPoison a = PoisonItem | NoPoison a deriving (Eq, Show)

instance Functor WithPoison where
  fmap f (NoPoison x) = NoPoison $ f x
  fmap _ PoisonItem = PoisonItem

instance Monad WithPoison where
  return = NoPoison
  PoisonItem >>= _ = PoisonItem
  NoPoison x >>= f = f x

instance Applicative WithPoison where
  pure = return
  (<*>) = ap
  
mergeWithPoison :: [WithPoison a] -> WithPoison ()
mergeWithPoison = sequence_

waitForOrPoison :: (a -> Maybe b) -> TVar (WithPoison a) -> STM (WithPoison b)
waitForOrPoison f tv = do x <- readTVar tv
                          case fmap f x of
                            PoisonItem -> return PoisonItem
                            NoPoison Nothing -> retry
                            NoPoison (Just y) -> return $ NoPoison y

flipMaybe :: Maybe a -> Maybe ()
flipMaybe (Just _) = Nothing
flipMaybe Nothing = Just ()
