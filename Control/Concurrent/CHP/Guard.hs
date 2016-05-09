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

module Control.Concurrent.CHP.Guard where

import Control.Concurrent.STM
import Control.Monad
import qualified Data.Map as Map
import Data.Monoid
import Data.Unique

import Control.Concurrent.CHP.Event
import Control.Concurrent.CHP.Traces.Base

-- Setup (giving transaction)
data Guard = TimeoutGuard (IO (STM ()))
             | SkipGuard
             | StopGuard
             -- The STM item is an action to take in the same transaction as
             -- completing the event (before it is completed).
             | EventGuard ((Unique -> (Integer, RecordedEventType)) -> [RecordedIndivEvent Unique]) EventActions [Event]

data EventActions = EventActions { actWhenLast :: Map.Map Unique Int -> STM ()
                                 , actAlways :: STM () }

instance Monoid EventActions where
  mempty = EventActions (const $ return ()) (return ())
  mappend (EventActions a a') (EventActions b b')
    = EventActions (\n -> a n >> b n) (a' >> b')

skipGuard :: Guard
skipGuard = SkipGuard

isSkipGuard :: Guard -> Bool
isSkipGuard SkipGuard = True
isSkipGuard _ = False

badGuard :: String -> Either String a
badGuard = Left

stopGuard :: Guard
stopGuard = StopGuard

isStopGuard :: Guard -> Bool
isStopGuard StopGuard = True
isStopGuard _ = False

-- Microseconds
guardWaitFor :: Int -> Guard
guardWaitFor n
  = TimeoutGuard $ 
     do signalDone <- registerDelay n
        return $ do b <- readTVar signalDone
                    when (not b) retry



