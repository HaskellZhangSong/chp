-- Communicating Haskell Processes.
-- Copyright (c) 2010, University of Kent, Neil Brown.
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

module Control.Concurrent.CHP.EventType (
  Event, EventMap, EventSet, getEventTVar, getEventType, getEventTypeVal, getEventUnique, getEventPriority, newEvent, newEventPri,
  Offer(signalValue, offerAction, eventsSet),
  OfferSet(signalVar, offersSet, processId), makeOfferSet,
  RecordedEventType(..),
  SignalVar, SignalValue(..), addPoison, nullSignalValue, isNullSignal
  ) where

import Control.Arrow
import Data.Function (on)
import qualified Data.Map as Map
import Data.Unique
import Control.Concurrent
import Control.Concurrent.STM
import Control.Concurrent.CHP.Poison
import Control.Concurrent.CHP.ProcessId

type EventMap v = [(Event, v)]
type EventSet = [Event]
type OfferSetSet = [OfferSet]

-- | The type of an event in the CSP and VCR traces.
--
-- ClockSync was added in version 1.2.0.
--
-- The extra parameter on ChannelComm and BarrierSync (which are the result of
-- showing the value sent and phase ended respectively) was added in version 1.5.0.
data RecordedEventType
  = ChannelComm String
  | BarrierSync String
  | ClockSync String deriving (Eq, Ord, Show)

getEventTypeVal :: RecordedEventType -> String
getEventTypeVal (ChannelComm s) = s
getEventTypeVal (BarrierSync s) = s
getEventTypeVal (ClockSync s) = s

-- Not really a CSP event, more like an enrollable poisonable alting barrier!
data Event = Event {
  getEventUnique :: Unique, -- Event identifier
  getEventPriority :: Int, -- Priority
  getEventType :: STM RecordedEventType, -- Event type for trace recording
  getEventTVar :: TVar (WithPoison
    (Int, -- Enrolled count
     Integer, -- Event sequence count
     OfferSetSet) -- A list of offer sets
 )}

instance Eq Event where
  (==) = (==) `on` getEventUnique

instance Ord Event where
  compare = compare `on` getEventUnique

-- For testing:
instance Show Event where
  show e = "Event " ++ show (hashUnique $ getEventUnique e)

newEvent :: STM RecordedEventType -> Int -> IO Event
newEvent t n
  = do u <- newUnique
       atomically $ do tv <- newTVar (NoPoison (n, 0, []))
                       return $ Event u 0 t tv

newEventPri :: STM RecordedEventType -> Int -> Int -> IO Event
newEventPri t n pri
  = do u <- newUnique
       atomically $ do tv <- newTVar (NoPoison (n, 0, []))
                       return $ Event u pri t tv


-- The value used to pass information to a waiting process once one of their events
-- has fired (and they have been committed to it).  The Int is an index into their
-- list of guards
newtype SignalValue = Signal (WithPoison Int)
  deriving (Eq, Show)

type SignalVar = TVar (Maybe (SignalValue, Map.Map Unique (Integer, RecordedEventType)))

addPoison :: SignalValue -> SignalValue
addPoison = const $ Signal PoisonItem

nullSignalValue :: SignalValue
nullSignalValue = Signal $ NoPoison (-1)

isNullSignal :: SignalValue -> Bool
isNullSignal (Signal n) = n == NoPoison (-1)

data Offer = Offer {signalValue :: SignalValue, offerAction :: STM (), eventsSet :: EventSet}

data OfferSet = OfferSet { signalVar :: SignalVar -- Variable to use to signal when committed
                         , threadId :: ThreadId
                         , processId :: ProcessId -- Id of the process making the offer
                         , offersSet :: [Offer]} -- Value to send when committed
                                                 -- A list of all sets of events currently offered

instance Eq OfferSet where
  (==) = (==) `on` threadId

instance Ord OfferSet where
  compare = compare `on` threadId

instance Show OfferSet where
  show os = "OfferSet " ++ show (processId os, map (signalValue &&& eventsSet) $ offersSet os)

makeOfferSet :: SignalVar -> ProcessId -> ThreadId -> [((SignalValue, STM ()), EventSet)] -> OfferSet
makeOfferSet v pid tid = OfferSet v tid pid . map (uncurry (uncurry Offer))
