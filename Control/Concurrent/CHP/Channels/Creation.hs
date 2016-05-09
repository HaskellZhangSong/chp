-- Communicating Haskell Processes.
-- Copyright (c) 2008--2009, University of Kent.
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

-- | This module contains a proliferation of channel creation methods.
--
-- For most uses, 'newChannel' is the only method needed from this module.  This
-- creates a channel for you to use.  The channel will be automatically destroyed
-- during garbage collection when it falls out of use, so there is no need to do
-- anything to destroy it.
--
-- It is often possible for the type system to infer which channel you want when
-- you use 'newChannel'.  If the types of the ends are known by the type system,
-- the channel-type can be inferred.  So you can usually just write 'newChannel',
-- and depending on how you use the channel, the type system will figure out
-- which one you needed.
--
-- If this gives a type error along the lines of:
-- 
-- >    Ambiguous type variables `r', `w' in the constraint:
-- >      `Channel r w' arising from a use of `newChannel' at tmp.hs:3:24-33
-- >    Probable fix: add a type signature that fixes these type variable(s)
--
-- Then you must either explicitly type the channel ends you are using, or more
-- simply, use one of the synonyms in "Control.Concurrent.CHP.Channels.Synonyms"
-- to indicate which kind of channel you are allocating.
--
-- Several other functions in this module, such as 'newChannelWR', 'newChannels'
-- and 'newChannelList' are helpers built with newChannel to ease dealing with
-- channel creation.
--
-- The remainder of the functions in this module are related to traces (see "Control.Concurrent.CHP.Traces"),
-- and allowing the channels to show up usefully in traces: see 'newChannel'' and
-- 'ChanOpts'.
--
-- The channel creation methods were refactored in version 1.5.0.  Your code will
-- only be affected if you were using the trace-related methods (for labelling
-- the channels in traces).  Instead of using @oneToOneChannelWithLabel "foo"@,
-- you should use @oneToOneChannel' $ chanLabel "foo"@.
module Control.Concurrent.CHP.Channels.Creation (
  Chan, Channel(..), newChannel, ChanOpts(..), defaultChanOpts, chanLabel, newChannelWR, newChannelRW,
  newChannelList, newChannelListWithLabels, newChannelListWithStem,
  labelChannel
  ) where

import Control.Monad
import Data.Unique

import Control.Concurrent.CHP.Base
import Control.Concurrent.CHP.Channels.Base
import Control.Concurrent.CHP.Mutex
import Control.Concurrent.CHP.Traces.Base

-- | A class used for allocating new channels, and getting the reading and
-- writing ends.  There is a bijective assocation between the channel, and
-- its pair of end types.  You can see the types in the list of instances below.
-- Thus, 'newChannel' may be used, and the compiler will infer which type of
-- channel is required based on what end-types you get from 'reader' and 'writer'.
-- Alternatively, if you explicitly type the return of 'newChannel', it will
-- be definite which ends you will use.  If you do want to fix the type of
-- the channel you are using when you allocate it, consider using one of the
-- many 'oneToOneChannel'-like shorthand functions that fix the type.
class Channel r w where
  -- | Like 'newChannel' but allows you to specify a way to convert the values
  -- into Strings in order to display them in the traces, and a label for the traces.  If
  -- you don't use traces, you can use 'newChannel'.
  --
  -- Added in version 1.5.0.
  newChannel' :: MonadCHP m => ChanOpts a -> m (Chan r w a)

  -- | Determines if two channel-ends refer to the same channel.
  --
  -- This function was added in version 1.4.0.
  sameChannel :: r a -> w a -> Bool

-- | Options for channel creation; a function to show the inner data, and an optional
-- label (both only affect tracing).  These options can be passed to newChannel'.
--
-- Added in version 1.5.0.
data ChanOpts a = ChanOpts {
  chanOptsPriority :: Int,
  -- ^ Added in version 2.1.0.  Priority is per-event, static and system-wide.
  --  If it is possible at any given moment for a process to resolve a choice one
  -- of several ways, the channel/barrier with the highest priority is chosen.
  --  If the choice is a conjunction and all events in one conjunction are higher
  -- than all the events in the other, the higher one is chosen (otherwise no guarantees
  -- are made).  The default is zero, and the range is the full range of Int (both
  -- positive and negative).
  chanOptsShow :: a -> String, chanOptsLabel :: Maybe String }

-- | The default: don't show anything, don't label anything
-- 
-- Added in version 1.5.0.
defaultChanOpts :: ChanOpts a
defaultChanOpts = ChanOpts 0 (const "") Nothing

-- | Uses the Show instance for showing the data in traces, and the given label.
--
-- Added in version 1.5.0.
chanLabel :: Show a => String -> ChanOpts a
chanLabel = ChanOpts 0 show . Just

-- | Allocates a new channel.  Nothing need be done to
-- destroy\/de-allocate the channel when it is no longer in use.
--
-- This function does not add any information to the traces: see newChannel' for
-- that purpose.
--
-- In version 1.5.0, this function was moved out of the 'Channel' class, but that
-- should only matter if you were declaring your own instances of that class (very
-- unlikely).
newChannel :: (MonadCHP m, Channel r w) => m (Chan r w a)
newChannel = newChannel' defaultChanOpts

-- | A helper that is like 'newChannel' but returns the reading and writing
-- end of the channels directly.
newChannelRW :: (Channel r w, MonadCHP m) => m (r a, w a)
newChannelRW = do c <- newChannel
                  return (reader c, writer c)

-- | A helper that is like 'newChannel' but returns the writing and reading
-- end of the channels directly.
newChannelWR :: (Channel r w, MonadCHP m) => m (w a, r a)
newChannelWR = do c <- newChannel
                  return (writer c, reader c)

-- | Creates a list of channels of the same type with the given length.  If
-- you need to access some channels by index, use this function.  Otherwise
-- you may find using 'newChannels' to be easier.
newChannelList :: (Channel r w, MonadCHP m) => Int -> m [Chan r w a]
newChannelList n = replicateM n newChannel

-- | A helper that is like 'newChannelList', but labels the channels according
-- to a pattern.  Given a stem such as foo, it names the channels in the list
-- foo0, foo1, foo2, etc.
newChannelListWithStem :: (Channel r w, MonadCHP m) => Int -> String -> m [Chan r w a]
newChannelListWithStem n s = sequence [newChannel' $ ChanOpts 0 (const "") (Just $ s ++ show i) | i <- [0 .. (n - 1)]]

-- | A helper that is like 'newChannelList', but labels the channels with the
-- given list.  The number of channels returned is the same as the length of
-- the list of labels
newChannelListWithLabels :: (Channel r w, MonadCHP m) => [String] -> m [Chan r w a]
newChannelListWithLabels = mapM (newChannel' . ChanOpts 0 (const "") . Just)

-- | Labels a channel in the traces.  It is easiest to do this at creation.
-- The effect of re-labelling channels after their first use is undefined.
--
-- Added in version 1.5.0.
labelChannel :: MonadCHP m => Chan r w a -> String -> m ()
labelChannel c s = liftCHP $ getTrace >>= \t -> liftIO_CHP $ labelUnique t (getChannelIdentifier c) s


instance Channel Chanin Chanout where
  newChannel' o = do c <- chan (liftCHP . liftIO_CHP $ stmChannel (chanOptsPriority o) (chanOptsShow o)) Chanin Chanout
                     maybe (return ()) (labelChannel c) (chanOptsLabel o)
                     return c
  sameChannel (Chanin x) (Chanout y) = x == y

instance Channel (Shared Chanin) Chanout where
  newChannel' o = do
                  m <- liftCHP . liftIO_CHP $ newMutex
                  c <- newChannel' o
                  return $ Chan (getChannelIdentifier c) (Shared (m, reader c)) (writer c)
  sameChannel (Shared (_, Chanin x)) (Chanout y) = x == y

instance Channel Chanin (Shared Chanout) where
  newChannel' o = do
                  m <- liftCHP . liftIO_CHP $ newMutex
                  c <- newChannel' o
                  return $ Chan (getChannelIdentifier c) (reader c) (Shared (m, writer c))
  sameChannel (Chanin x) (Shared (_, Chanout y)) = x == y

instance Channel (Shared Chanin) (Shared Chanout) where
  newChannel' o = do
                  m <- liftCHP . liftIO_CHP $ newMutex
                  m' <- liftCHP . liftIO_CHP $ newMutex
                  c <- newChannel' o
                  return $ Chan (getChannelIdentifier c) (Shared (m, reader c)) (Shared (m', writer c))
  sameChannel (Shared (_, Chanin x)) (Shared (_, Chanout y)) = x == y

chan :: Monad m => m (Unique, c a) -> (c a -> r a) -> (c a -> w a) -> m (Chan r w a)
chan m r w = do (u, x) <- m
                return $ Chan u (r x) (w x)
