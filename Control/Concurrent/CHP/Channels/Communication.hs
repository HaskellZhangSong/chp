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

-- | All the channel-ends in CHP are instances of 'ReadableChannel' (for ends that
-- you can read from) or 'WriteableChannel' (for ends that you can write to).
--
-- The 'readChannel' and 'writeChannel' functions are the standard way to communicate
-- on a channel.  These functions wait for the other party in the communication
-- to arrive, then exchange the data, then complete.  In pseudo-code, the semantics
-- are like this when two parties (shown here as two columns) communicate:
--
-- > do sync                          sync
-- >    x                        <-   return y
-- >    done                          done
--
-- Further options are offered by the 'extReadChannel' and 'extWriteChannel' channels,
-- which allow either side to perform additional (so-called extended) actions during the communication.
--  The semantics when both sides are performing extended actions are:
--
-- > do sync                          sync
-- >                                  y <- extWriteAction
-- >    x                        <-   return y
-- >    x' <- extReadAction x         done
-- >    done                          done
-- >    return x'
--
-- Neither end need know that the other is performing an extended action, and any
-- combination is possible (e.g. a normal 'writeChannel' with an 'extReadChannel').
module Control.Concurrent.CHP.Channels.Communication (
  ReadableChannel(..), WriteableChannel(..), writeValue, writeChannelStrict
  ) where

import Control.Concurrent.STM (atomically)
import Control.DeepSeq
import Control.Monad
import Data.Monoid

import Control.Concurrent.CHP.Base
import Control.Concurrent.CHP.CSP
import Control.Concurrent.CHP.Channels.Base
import Control.Concurrent.CHP.Guard
import Control.Concurrent.CHP.Poison
import Control.Concurrent.CHP.Traces.Base

-- | A class indicating that a channel can be read from.
class ReadableChannel chanEnd where -- minimal implementation: extReadChannel
  -- | Reads from the given reading channel-end
  readChannel :: chanEnd a -> CHP a
  readChannel c = extReadChannel c return
  -- | Performs an extended read from the channel, performing the given action
  -- before freeing the writer
  extReadChannel :: chanEnd a -> (a -> CHP b) -> CHP b

-- | A class indicating that a channel can be written to.
class WriteableChannel chanEnd where -- minimal implementation: extWriteChannel
  -- | Writes from the given writing channel-end
  writeChannel :: chanEnd a -> a -> CHP ()
  writeChannel c x = extWriteChannel c (return x) >> return ()

  -- | Starts the communication, then performs the given extended action, then
  -- sends the result of that down the channel.
  extWriteChannel :: chanEnd a -> CHP a -> CHP ()
  extWriteChannel c = extWriteChannel' c . liftM (flip (,) ())

  -- | Like extWriteChannel, but allows a value to be returned from the inner action.
  --
  -- This function was added in version 1.4.0.
  extWriteChannel' :: chanEnd a -> CHP (a, b) -> CHP b
  

-- ==========
-- Functions: 
-- ==========

-- | A useful synonym for @flip writeChannel@.  Especially useful with 'claim'
-- so that instead of writing @claim output (flip writeChannel 6)@ you can write
-- @claim output (writeValue 6)@.
--
-- Added in version 1.5.0.
writeValue :: WriteableChannel chanEnd => a -> chanEnd a -> CHP ()
writeValue = flip writeChannel

-- | A helper function that uses the parallel strategies library (see the
-- paper: \"Algorithm + Strategy = Parallelism\", P.W. Trinder et al, JFP
-- 8(1) 1998,
-- <http://www.macs.hw.ac.uk/~dsg/gph/papers/html/Strategies/strategies.html>)
-- to make sure that the value sent down a channel is strictly evaluated
-- by the sender before transmission.
--
-- This is useful when you want to write worker processes that evaluate data
--  and send it back to some \"harvester\" process.  By default the values sent
-- back may be unevaluated, and thus the harvester might end up doing the evaluation.
--  If you use this function, the value is guaranteed to be completely evaluated
-- before sending.
--
-- Added in version 1.0.2.
writeChannelStrict :: (NFData a, WriteableChannel chanEnd) => chanEnd a -> a -> CHP ()
writeChannelStrict c x = case rnf x of () -> writeChannel c x

-- ==========
-- Instances: 
-- ==========

instance ReadableChannel Chanin where
  readChannel (Chanin c)
    = let (e, mdur, mafter) = readChannelC c in
      buildOnEventPoison (wrapIndiv $ indivRecJust ChannelRead) e
        (EventActions (const $ return ()) mdur)
        (atomically mafter)

  extReadChannel (Chanin c) body
    = let (e, m) = startReadChannelC c in
      scopeBlock
        (buildOnEventPoison (wrapIndiv $ indivRecJust ChannelRead) e mempty (atomically m))
        (\val -> do x <- body val
                    _ <- liftSTM $ endReadChannelC c
                    return x)
        (poisonReadC c)

instance WriteableChannel Chanout where
  writeChannel (Chanout c) x
    = let (e, mdur, mafter) = writeChannelC c x in
        buildOnEventPoison (wrapIndiv $ indivRecJust ChannelWrite) e
          (EventActions (const $ return ()) mdur) (atomically mafter)
  extWriteChannel' (Chanout c) body
    = let (e, m) = startWriteChannelC c in
      scopeBlock
        (buildOnEventPoison (wrapIndiv $ indivRecJust ChannelWrite)
          e mempty (atomically m))
        (const $ do (x, r) <- body
                    sequence [liftSTM $ sendWriteChannelC c x
                             ,liftSTM (endWriteChannelC c)]
                      >>= checkPoison . mergeWithPoison
                    return r)
        (poisonWriteC c)
