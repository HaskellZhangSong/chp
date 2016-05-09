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

-- | A module containing some useful type synonyms for dealing with channels.
--
-- If you get a type error such as:
--
-- >    Ambiguous type variables `r', `w' in the constraint:
-- >      `Channel r w' arising from a use of `newChannel' at tmp.hs:3:24-33
-- >    Probable fix: add a type signature that fixes these type variable(s)
--
-- Then you may want to substitute your use of 'newChannel' for 'oneToOneChannel'
-- (if you are not using channel sharing).
module Control.Concurrent.CHP.Channels.Synonyms (
  -- * Specific Channel Types
  -- | All the functions here are equivalent to newChannel (or newChannelWithLabel), but typed.  So for
  -- example, @oneToOneChannel = newChannel :: MonadCHP m => m OneToOneChannel@.
  OneToOneChannel, oneToOneChannel, oneToOneChannel',
  OneToAnyChannel, oneToAnyChannel, oneToAnyChannel',
  AnyToOneChannel, anyToOneChannel, anyToOneChannel',
  AnyToAnyChannel, anyToAnyChannel, anyToAnyChannel'
  ) where

import Control.Concurrent.CHP.Base
import Control.Concurrent.CHP.Channels.Creation
import Control.Concurrent.CHP.Channels.Ends

type OneToOneChannel = Chan Chanin Chanout
type AnyToOneChannel = Chan (Chanin) (Shared Chanout)
type OneToAnyChannel = Chan (Shared Chanin) (Chanout)
type AnyToAnyChannel = Chan (Shared Chanin) (Shared Chanout)

-- | A type-constrained version of newChannel.
oneToOneChannel :: MonadCHP m => m (OneToOneChannel a)
oneToOneChannel = newChannel

-- | A type-constrained version of newChannel'.
--
-- Added in version 1.5.0.
oneToOneChannel' :: MonadCHP m => ChanOpts a -> m (OneToOneChannel a)
oneToOneChannel' = newChannel'

-- | A type-constrained version of newChannel.
anyToOneChannel :: MonadCHP m => m (AnyToOneChannel a)
anyToOneChannel = newChannel

-- | A type-constrained version of newChannel.
oneToAnyChannel :: MonadCHP m => m (OneToAnyChannel a)
oneToAnyChannel = newChannel

-- | A type-constrained version of newChannel.
anyToAnyChannel :: MonadCHP m => m (AnyToAnyChannel a)
anyToAnyChannel = newChannel

-- | A type-constrained version of newChannel'.
--
-- Added in version 1.5.0.
anyToOneChannel' :: MonadCHP m => ChanOpts a -> m (AnyToOneChannel a)
anyToOneChannel' = newChannel'

-- | A type-constrained version of newChannel'.
--
-- Added in version 1.5.0.
oneToAnyChannel' :: MonadCHP m => ChanOpts a -> m (OneToAnyChannel a)
oneToAnyChannel' = newChannel'

-- | A type-constrained version of newChannel'.
--
-- Added in version 1.5.0.
anyToAnyChannel' :: MonadCHP m => ChanOpts a -> m (AnyToAnyChannel a)
anyToAnyChannel' = newChannel'
