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

module Control.Concurrent.CHP.Channels.Base where

import Control.Concurrent.STM
import Control.Monad
import Data.Unique (Unique)

import Control.Concurrent.CHP.Base
import Control.Concurrent.CHP.Event
import Control.Concurrent.CHP.Poison


-- | A reading channel-end type.
--
-- See 'reader' to obtain one, and 'ReadableChannel' for how to use one.
--
-- Eq instance added in version 1.1.1
newtype Chanin a = Chanin (STMChannel a) deriving Eq

-- | A writing channel-end type.
--
-- See 'writer' to obtain one, and 'WritableChannel' for how to use one.
-- 
-- Eq instance added in version 1.1.1
newtype Chanout a = Chanout (STMChannel a) deriving Eq

newtype STMChannel a = STMChan (Event, TVar (WithPoison (Maybe a, Maybe ())))
  deriving Eq

-- | A channel type, that can be used to get the ends of the channel via 'reader'
-- and 'writer'
data Chan r w a = Chan {
  -- | Gets the channel's identifier.  Useful if you need to be able to identify
  -- a channel in the trace later on.
  getChannelIdentifier :: Unique,
  -- | Gets the reading end of a channel from its 'Chan' type.
  reader :: r a,
  -- | Gets the writing end of a channel from its 'Chan' type.
  writer :: w a}


instance Poisonable (Chanin a) where
  poison (Chanin c) = liftCHP . liftIO_CHP $ poisonReadC c
  checkForPoison (Chanin c) = liftCHP $ liftIO_CHP (checkPoisonReadC c) >>= checkPoison

instance Poisonable (Chanout a) where
  poison (Chanout c) = liftCHP . liftIO_CHP $ poisonWriteC c
  checkForPoison (Chanout c) = liftCHP $ liftIO_CHP (checkPoisonWriteC c) >>= checkPoison


stmChannel :: Int -> (a -> String) -> IO (Unique, STMChannel a)
stmChannel pri sh =
  do c <- atomically $ newTVar $ NoPoison (Nothing, Nothing)
     e <- newEventPri (liftM (ChannelComm . maybe "" sh . getVal) $ readTVar c) 2 pri
     return (getEventUnique e, STMChan (e,c))
  where
    getVal PoisonItem = Nothing
    getVal (NoPoison (x, _)) = x

-- Some of this is defensive programming -- the writer should never be able
-- to discover poison in the channel variable, for example

consumeData :: TVar (WithPoison (Maybe a, Maybe ())) -> STM (WithPoison a)
consumeData tv = do d <- readTVar tv
                    case d of
                      PoisonItem -> return PoisonItem
                      NoPoison (Nothing, _) -> retry
                      NoPoison (Just x, a) -> do writeTVar tv $ NoPoison (Nothing, a)
                                                 return $ NoPoison x

sharedError :: String -> String
sharedError s
  = unlines ["CHP: Assumption violated; found " ++ s ++ " when placing " ++ s ++ "."
            ,"This is typically because you have multiple writers or multiple readers accessing a unshared (one-to-one) channel."
            ,"If you want to have many writers or many readers, use an appropriate (any-to-one, one-to-any or any-to-any) shared channel, using the claim function."
            ]

sendData :: TVar (WithPoison (Maybe a, Maybe ())) -> a -> STM (WithPoison ())
sendData tv x  = do y <- readTVar tv
                    case y of
                      PoisonItem -> return PoisonItem
                      NoPoison (Just _, _) -> error $ sharedError "data"
                      NoPoison (Nothing, a) -> do writeTVar tv $ NoPoison (Just x, a)
                                                  return $ NoPoison ()

consumeAck :: TVar (WithPoison (Maybe a, Maybe ())) -> STM (WithPoison ())
consumeAck tv = do d <- readTVar tv
                   case d of
                      PoisonItem -> return PoisonItem
                      NoPoison (_, Nothing) -> retry
                      NoPoison (x, Just _) -> do writeTVar tv $ NoPoison (x, Nothing)
                                                 return $ NoPoison ()

sendAck ::  TVar (WithPoison (Maybe a, Maybe ())) -> STM (WithPoison ())
sendAck tv =    do d <- readTVar tv
                   case d of
                      PoisonItem -> return PoisonItem
                      NoPoison (_, Just _) -> error $ sharedError "ack"
                      NoPoison (x, Nothing) -> do writeTVar tv $ NoPoison (x, Just ())
                                                  return $ NoPoison ()

-- Start gets the event and the transaction that will wait for data.  You
-- sync on the event (possible extended write occurs) then wait for data
startReadChannelC :: STMChannel a -> (Event, STM (WithPoison a))
startReadChannelC (STMChan (e,tv)) = (e, consumeData tv)

-- (extended read action goes here)
-- Read releases the writer
endReadChannelC :: STMChannel a -> STM (WithPoison ())
endReadChannelC (STMChan (_,tv)) = sendAck tv

-- First action is to be done as part of the completion:
readChannelC :: STMChannel a -> (Event, STM (), STM (WithPoison a))
readChannelC (STMChan (e, tv))
  = (e, sendAck tv >> return (), consumeData tv)

poisonReadC :: STMChannel a -> IO ()
poisonReadC (STMChan (e,tv))
    = atomically $ do poisonEvent e
                      writeTVar tv PoisonItem

checkPoisonReadC :: STMChannel a -> IO (WithPoison ())
checkPoisonReadC (STMChan (e,_)) = atomically $ checkEventForPoison e

-- Start checks for poison and gets the event:
startWriteChannelC :: STMChannel a -> (Event, STM (WithPoison ()))
startWriteChannelC (STMChan (e,tv))
    = (e, do x <- readTVar tv
             case x of
               PoisonItem -> return PoisonItem
               NoPoison _ -> return $ NoPoison ())

-- (extended write action goes here)
-- Send actually transmits the value:
sendWriteChannelC :: STMChannel a -> a -> STM (WithPoison ())
sendWriteChannelC (STMChan (_, tv)) = sendData tv

-- (extended read action goes here)
-- End waits for the reader to tell us we're done, must be done in a different
-- transaction to the send
endWriteChannelC :: STMChannel a -> STM (WithPoison ())
endWriteChannelC (STMChan (_, tv))
    = consumeAck tv

-- First action is to be done as part of the completion:
writeChannelC :: STMChannel a -> a -> (Event, STM (), STM (WithPoison ()))
writeChannelC (STMChan (e, tv)) val
    = (e, sendData tv val >> return (), consumeAck tv)

poisonWriteC :: STMChannel a -> IO ()
poisonWriteC (STMChan (e,tv))
  = atomically $ do poisonEvent e
                    writeTVar tv PoisonItem

checkPoisonWriteC :: STMChannel a -> IO (WithPoison ())
checkPoisonWriteC (STMChan (e,_)) = atomically $ checkEventForPoison e
