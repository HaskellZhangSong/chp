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

-- | Channels in CHP must be used via their ends.  It is generally these ends that
-- you pass around to processes that want to communicate on the channel -- thus
-- it is possible to see from the type ('Chanin'\/'Chanout') whether the process
-- will use it for reading or writing.  The channel-ends are named from the perspective
-- of processes: a Chanin is a channel-end that a process may input values from,
-- whereas a Chanout is a channel-end that a process may output values to.
module Control.Concurrent.CHP.Channels.Ends (
  Chanin, Chanout, Shared,
  reader, writer, readers, writers,
  claim) where

import Control.Concurrent.CHP.Base
import Control.Concurrent.CHP.CSP
import Control.Concurrent.CHP.Channels.Base
import Control.Concurrent.CHP.Mutex

-- | Gets all the reading ends of a list of channels.  A shorthand for @map
-- reader@.
readers :: [Chan r w a] -> [r a]
readers = map reader

-- | Gets all the writing ends of a list of channels.  A shorthand for @map
-- writer@.
writers :: [Chan r w a] -> [w a]
writers = map writer

-- | Claims the given channel-end, executes the given block, then releases
-- the channel-end and returns the output value.  If poison or an IO
-- exception is thrown inside the block, the channel is released and the
-- poison\/exception re-thrown.
claim :: Shared c a -> (c a -> CHP b) -> CHP b
claim (Shared (lock, c)) body
  = scopeBlock
       (liftIO_CHP (claimMutex lock) >> return c)
       (\y -> do x <- body y
                 liftIO_CHP $ releaseMutex lock
                 return x)
       (releaseMutex lock)
