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

-- | A module containing broadcast channels (one-to-many).  Whereas a one-to-any
-- channel features one writer sending a /single/ value to /one/ (of many) readers, a
-- one-to-many channel features one writer sending the /same/ value to /many/
-- readers.  So a one-to-any channel involves claiming the channel-end to ensure
-- exclusivity, but a one-to-many channel involves enrolling on the channel-end
-- (subscribing) before it can engage in communication.
--
-- A communication on a one-to-many channel only takes place when the writer
-- and all readers currently enrolled agree to communicate.  What happens when
-- the writer wants to communicate and no readers are enrolled was undefined
-- in versions 1.5.1 and earlier (the writer may block, or may communicate
-- happily to no-one).  However, in version 1.6.0 onwards the semantics are
-- clear: a writer that communicates on a broadcast channel with no readers
-- involved will succeed immediately, communicating to no-one (i.e. the data
-- is lost).  Similarly, a read from a reduce channel will immediately return
-- 'mempty' when no writers are enrolled.  It is possible to get into a state
-- of livelock (by repeatedly performing these instant communications) in
-- these sorts of situations.
--
-- This module also contains reduce channels (added in version 1.1.1).  Because
-- in CHP channels must have the same type at both ends, we use the Monoid
-- type-class.  It is important to be aware that the order of mappends will be
-- non-deterministic, and thus you should either use an mappend that is commutative
-- or code around this restruction.
--
-- For example, a common thing to do would be to use lists as the type for
-- reduce channels, make each writer write a single item list (but more is
-- possible), then use the list afterwards, but be aware that it is unordered.
--  If it is important to have an ordered list, make each writer write a pair
-- containing a (unique) index value and the real data, then sort by the index
-- value and discard it.
--
-- Since reduce channels were added after the initial library design, there
-- is a slight complication: it is not possible to use newChannel (and all
-- similar functions) with reduce channels because it is impossible to express
-- the Monoid constraint for the Channel instance.  Instead, you must use manyToOneChannel
-- and manyToAnyChannel.
module Control.Concurrent.CHP.Channels.BroadcastReduce (BroadcastChanin, BroadcastChanout,
  OneToManyChannel, AnyToManyChannel, oneToManyChannel, anyToManyChannel,
    oneToManyChannel', anyToManyChannel', ReduceChanin,
    ReduceChanout, sameReduceChannel, ManyToOneChannel, ManyToAnyChannel, manyToOneChannel,
    manyToAnyChannel, manyToOneChannel', manyToAnyChannel')
      where

import Control.Arrow
import Control.Concurrent.STM
import Control.Monad
import Data.Monoid

import Control.Concurrent.CHP.Barriers
import Control.Concurrent.CHP.Base
import Control.Concurrent.CHP.Channels
import Control.Concurrent.CHP.Channels.Base
import Control.Concurrent.CHP.CSP
import Control.Concurrent.CHP.Enroll
import Control.Concurrent.CHP.Event
import Control.Concurrent.CHP.Mutex
import Control.Concurrent.CHP.Traces.Base

-- | The Eq instance was added in version 1.4.0.
--
-- In versions 1.5.0-1.7.0, the broadcast and reduce channels do not appear correctly
-- in the traces.
newtype BroadcastChannel a = BC (Barrier, TVar (Maybe a), ManyToOneTVar Int)

instance Eq (BroadcastChannel a) where
  (BC (_, tvX, _)) == (BC (_, tvY, _)) = tvX == tvY

-- | The reading end of a broadcast channel.  You must enroll on it before
-- you can read from it or poison it.
-- 
-- The Eq instance was added in version 1.4.0.
newtype BroadcastChanin a = BI (BroadcastChannel a) deriving (Eq)

-- | The writing end of a broadcast channel.
-- 
-- The Eq instance was added in version 1.4.0.
newtype BroadcastChanout a = BO (BroadcastChannel a) deriving (Eq)

instance Enrollable BroadcastChanin a where
  enroll c@(BI (BC (b,_,_))) f = enroll b (const $ f (Enrolled c))
  resign (Enrolled (BI (BC (b,_,_)))) = resign (Enrolled b)

instance WriteableChannel BroadcastChanout where
  extWriteChannel' (BO (BC (b, tvSend, tvAck))) m
    = do syncBarrierWith (indivRecJust ChannelWrite)
           (resetManyToOneTVar tvAck . pred) $ Enrolled b
           -- subtract one for writer
         (x, r) <- m
         liftSTM $ writeTVar tvSend $ Just x
         -- Must be two separate transactions:
         _ <- liftSTM $ readManyToOneTVar tvAck
         return r

instance ReadableChannel (Enrolled BroadcastChanin) where
  extReadChannel (Enrolled (BI (BC (b, tvSend, tvAck)))) f
    = do syncBarrierWith (indivRecJust ChannelRead)
           (resetManyToOneTVar tvAck . pred) $ Enrolled b
         x <- liftSTM $ readTVar tvSend >>= maybe retry return
         y <- f x
         _ <- liftSTM $ writeManyToOneTVar pred tvAck
         return y

instance Poisonable (BroadcastChanout a) where
  poison (BO (BC (b,_,_))) = poison $ Enrolled b
  checkForPoison (BO (BC (b,_,_))) = checkForPoison $ Enrolled b

instance Poisonable (Enrolled BroadcastChanin a) where
  poison (Enrolled (BI (BC (b,_,_)))) = poison $ Enrolled b
  checkForPoison (Enrolled (BI (BC (b,_,_)))) = checkForPoison $ Enrolled b

newBroadcastChannel :: CHP (BroadcastChannel a)
newBroadcastChannel
  = do b@(Barrier (e, _, _)) <- newBarrier
       -- Writer is always enrolled:
       _ <- liftSTM $ enrollEvent e
       tvSend <- liftSTM $ newTVar Nothing
       tvAck <- liftSTM $ newManyToOneTVar (== 0) (return 0) 0
       return $ BC (b, tvSend, tvAck)

instance Channel BroadcastChanin BroadcastChanout where
  newChannel' _sh = liftCHP $ do
    c@(BC (b, _, _)) <- newBroadcastChannel
    return $ Chan (getBarrierIdentifier b) (BI c) (BO c)
  sameChannel (BI x) (BO y) = x == y

instance Channel BroadcastChanin (Shared BroadcastChanout) where
  newChannel' _sh = liftCHP $ do
    m <- liftIO_CHP newMutex
    c <- newChannel
    return $ Chan (getChannelIdentifier c) (reader c) (Shared (m, writer c))
  sameChannel (BI x) (Shared (_, BO y)) = x == y

type OneToManyChannel = Chan BroadcastChanin BroadcastChanout
type AnyToManyChannel = Chan BroadcastChanin (Shared BroadcastChanout)

oneToManyChannel :: MonadCHP m => m (OneToManyChannel a)
oneToManyChannel = newChannel

anyToManyChannel :: MonadCHP m => m (AnyToManyChannel a)
anyToManyChannel = newChannel

-- | Added in version 1.5.0.
--
-- In versions 1.5.0-1.7.0, the broadcast and reduce channels do not appear correctly
-- in the traces.
oneToManyChannel' :: MonadCHP m => ChanOpts a -> m (OneToManyChannel a)
oneToManyChannel' = newChannel'

-- | Added in version 1.5.0.
--
-- In versions 1.5.0-1.7.0, the broadcast and reduce channels do not appear correctly
-- in the traces.
anyToManyChannel' :: MonadCHP m => ChanOpts a -> m (AnyToManyChannel a)
anyToManyChannel' = newChannel'


-- | The Eq instance was added in version 1.4.0.
-- 
-- In versions 1.5.0-1.7.0, the broadcast and reduce channels do not appear correctly
-- in the traces.
newtype ReduceChannel a = GC (Barrier, ManyToOneTVar (Int, Maybe (a, TVar Bool)), (a -> a -> a, a))

instance Eq (ReduceChannel a) where
  (GC (_, tvX, _)) == (GC (_, tvY, _)) = tvX == tvY

-- | The reading end of a reduce channel.
--
-- The Eq instance was added in version 1.4.0.
newtype ReduceChanin a = GI (ReduceChannel a) deriving (Eq)

-- | The writing end of a reduce channel.  You must enroll on it before
-- you can read from it or poison it.
--
-- The Eq instance was added in version 1.4.0.
newtype ReduceChanout a = GO (ReduceChannel a) deriving (Eq)

instance Enrollable ReduceChanout a where
  enroll c@(GO (GC (b,_,_))) f = enroll b (const $ f (Enrolled c))
  resign (Enrolled (GO (GC (b,_,_)))) = resign (Enrolled b)
      
instance WriteableChannel (Enrolled ReduceChanout) where
  extWriteChannel' (Enrolled (GO (GC (b, tv, (f,_))))) m
    = do syncBarrierWith (indivRecJust ChannelWrite)
           (\n -> resetManyToOneTVar tv (pred n, Nothing)) $ Enrolled b
           -- Subtract one for reader
         (x, r) <- m
         (_, Just (_, rtvb)) <- liftSTM $ do
           tvb <- newTVar False
           let upd (n, mx) = (pred n, Just $ maybe (x, tvb) (first $ f x) mx)
           writeManyToOneTVar upd tv
         -- Has to be two separate transactions
         liftSTM $ readTVar rtvb >>= flip unless retry
         return r

instance ReadableChannel ReduceChanin where
  extReadChannel (GI (GC (b, tv, (_, empty)))) f
    = do syncBarrierWith (indivRecJust ChannelRead)
           (\n -> resetManyToOneTVar tv (pred n, Nothing)) $ Enrolled b
           -- Subtract one for reader
         (_, val) <- liftSTM $ readManyToOneTVar tv
         case val of
           Just (x, tvb) -> do y <- f x
                               liftSTM $ writeTVar tvb True
                               return y
           Nothing -> f empty

instance Poisonable (Enrolled ReduceChanout a) where
  poison (Enrolled (GO (GC (b,_,_)))) = poison $ Enrolled b
  checkForPoison (Enrolled (GO (GC (b,_,_)))) = checkForPoison $ Enrolled b

instance Poisonable (ReduceChanin a) where
  poison (GI (GC (b,_,_))) = poison $ Enrolled b
  checkForPoison (GI (GC (b,_,_))) = checkForPoison $ Enrolled b

newReduceChannel :: Monoid a => CHP (ReduceChannel a)
newReduceChannel
  = do b@(Barrier (e, _, _)) <- newBarrier
       -- Writer is always enrolled:
       _ <- liftSTM $ enrollEvent e
       mtv <- liftSTM $ newManyToOneTVar ((== 0) . fst) (return (0, Nothing)) (0, Nothing)
       return $ GC (b, mtv, (mappend, mempty))

-- | The reduce channel version of sameChannel.
-- 
-- This function was added in version 1.4.0.
sameReduceChannel :: ReduceChanin a -> ReduceChanout a -> Bool
sameReduceChannel (GI x) (GO y) = x == y

type ManyToOneChannel = Chan ReduceChanin ReduceChanout
type ManyToAnyChannel = Chan (Shared ReduceChanin) ReduceChanout

manyToOneChannel :: (Monoid a, MonadCHP m) => m (ManyToOneChannel a)
manyToOneChannel = do
    c@(GC (b,_,_)) <- liftCHP newReduceChannel
    return $ Chan (getBarrierIdentifier b) (GI c) (GO c)


manyToAnyChannel :: (Monoid a, MonadCHP m) => m (ManyToAnyChannel a)
manyToAnyChannel = do
    m <- liftCHP $ liftIO_CHP newMutex
    c <- manyToOneChannel
    return $ Chan (getChannelIdentifier c) (Shared (m, reader c)) (writer c)

-- | Added in version 1.5.0.
-- 
-- In versions 1.5.0-1.7.0, the broadcast and reduce channels do not appear correctly
-- in the traces.
manyToOneChannel' :: (Monoid a, MonadCHP m) => ChanOpts a -> m (ManyToOneChannel a)
manyToOneChannel' = const manyToOneChannel --TODO

-- | Added in version 1.5.0.
-- 
-- In versions 1.5.0-1.7.0, the broadcast and reduce channels do not appear correctly
-- in the traces.
manyToAnyChannel' :: (Monoid a, MonadCHP m) => ChanOpts a -> m (ManyToAnyChannel a)
manyToAnyChannel' = const manyToAnyChannel --TODO
