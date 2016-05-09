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


-- | The module containing all the different types of channels in CHP.
-- 
-- A communication in CHP is always synchronised: the writer must wait until the
-- reader arrives to take the data.  There is thus no automatic or underlying buffering
-- of data.  (If you want to use buffers, see the Control.Concurrent.CHP.Buffers
-- module in the chp-plus package).
--
-- If it helps, a channel communication can be thought of as a distributed binding.
--  Imagine you have a process that creates a channel and then becomes the parallel
-- composition of two sub-processes that at some point communicate on that channel
-- (formatted here as two columns for illustration):
--
-- > do                      c <- oneToOneChannel
-- >                                    (<||>)
-- >    do p                                   do p'
-- >       q                                      y <- q'
-- >       x <- readChannel (reader c)            writeChannel (writer c) y
-- >       r                                      r'
-- >       s x                                    s'
--
-- It is as if, at the point where the two processes want to communicate, they come
-- together and directly bind the value from one process in the other:
-- 
-- > do                      c <- oneToOneChannel
-- >                                    (<||>)
-- >    do p                                   do p'
-- >       q                                      y <- q'
-- >       x                            <-        return y
-- >       r                                      r'
-- >       s x                                    s'
--
-- The "Control.Concurrent.CHP.Channels.Creation" contains functions relating to
-- the creation of channels.  Channels are used via their ends -- see the "Control.Concurrent.CHP.Channels.Ends"
-- module, and the "Control.Concurrent.CHP.Channels.Communication" module.
--
-- Broadcast and reduce channels are available in the "Control.Concurrent.CHP.Channels.BroadcastReduce"
-- module, which is not automatically re-exported here.
-- 
-- This module was split into several smaller modules in version 1.5.0.  Since
-- it re-exports all the new modules, your code should not be affected at all.
module Control.Concurrent.CHP.Channels (
  -- * Channel Creation and Types
  module Control.Concurrent.CHP.Channels.Creation,
  getChannelIdentifier,
  -- * Channel-Ends
  module Control.Concurrent.CHP.Channels.Ends,

  -- * Reading and Writing with Channels
  module Control.Concurrent.CHP.Channels.Communication,

  -- * Useful Type and Function Synonyms
  module Control.Concurrent.CHP.Channels.Synonyms

  )
  where


import Control.Concurrent.CHP.Channels.Base
import Control.Concurrent.CHP.Channels.Communication
import Control.Concurrent.CHP.Channels.Creation
import Control.Concurrent.CHP.Channels.Ends
import Control.Concurrent.CHP.Channels.Synonyms
