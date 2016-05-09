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

-- | This module contains all the central monads in the CHP library.
module Control.Concurrent.CHP.Monad
  (
   -- * CHP Monad
  CHP, MonadCHP(..), liftIO_CHP, runCHP, runCHP_,
  embedCHP, embedCHP_, embedCHP1, embedCHP1_,

  onPoisonTrap, onPoisonRethrow, throwPoison, Poisonable(..), poisonAll,

  -- * Primitive actions
  skip, stop, waitFor,

  -- * chp-spec items
  foreverP, liftIO_CHP', process, subProcess
   ) where

import Control.Monad (liftM, forever)
import Data.Unique

-- This module primarily re-exports the public definitions from
-- Control.Concurrent.CHP.{Base,CSP,Poison}:

import Control.Concurrent.CHP.Base
import Control.Concurrent.CHP.Guard
import Control.Concurrent.CHP.Poison
import Control.Concurrent.CHP.Traces.TraceOff

-- | Runs a CHP program.  You should use this once, at the top-level of your
-- program.  Do not ever use this function twice in parallel and attempt to
-- communicate between those processes using channels.  Instead, run this function
-- once and use it to spawn off the parallel processes that you need.
runCHP :: CHP a -> IO (Maybe a)
runCHP = liftM fst . (runCHPAndTrace :: CHP a -> IO (Maybe a, TraceOff Unique))

-- | Runs a CHP program.  Like 'runCHP' but discards the output.
runCHP_ :: CHP a -> IO ()
runCHP_ p = runCHP p >> return ()

-- | Exactly the same as 'forever'.  Useful only because it mirrors a different definition
-- from the chp-spec library.
--
-- Added in version 2.2.0.
foreverP :: CHP a -> CHP b
foreverP = forever

-- | Acts as @const id@.  Useful only because it mirrors a different definition in the
-- chp-spec library.
--
-- Added in version 2.2.0.
process :: String -> a -> a
process = const id

-- | Acts as @const id@.  Useful only because it mirrors a different definition in the
-- chp-spec library.
--
-- Added in version 2.2.0.
subProcess :: String -> a -> a
subProcess = const id

-- | Allows embedding of the CHP monad back into the IO monad.  The argument
-- that this function takes is a CHP action (with arbitrary behaviour).  The
-- function is monadic, and returns something of type: IO a.  This
-- is an IO action that you can now use in the IO monad wherever you like.
-- What it returns is the result of your original action.
--
-- This function is intended for use wherever you need to supply an IO callback
-- (for example with the OpenGL libraries) that needs to perform CHP communications.
--  It is the safe way to do things, rather than using runCHP twice (and also works
-- with CSP and VCR traces -- but not structural traces!).
embedCHP :: CHP a -> CHP (IO (Maybe a))
embedCHP m = liftM ($ ()) $ embedCHP1 (\() -> m)

-- | A convenient version of embedCHP that ignores the result
embedCHP_ :: CHP a -> CHP (IO ())
embedCHP_ = liftM (>> return ()) . embedCHP

-- | A helper like embedCHP for callbacks that take an argument
embedCHP1 :: (a -> CHP b) -> CHP (a -> IO (Maybe b))
embedCHP1 f = do t <- getTrace
                 return $ runCHPProgramWith t . f

-- | A convenient version of embedCHP1 that ignores the result
embedCHP1_ :: (a -> CHP b) -> CHP (a -> IO ())
embedCHP1_ = liftM (\m x -> m x >> return ()) . embedCHP1

-- | Waits for the specified number of microseconds (millionths of a second).
-- There is no guaranteed precision, but the wait will never complete in less
-- time than the parameter given.
-- 
-- Suitable for use in an 'Control.Concurrent.CHP.Alt.alt', but note that 'waitFor' 0 is not the same
-- as 'skip'.  'waitFor' 0 'Control.Concurrent.CHP.Alt.</>' x will not always select the first guard,
-- depending on x.  Included in this is the lack of guarantee that
-- 'waitFor' 0 'Control.Concurrent.CHP.Alt.</>' 'waitFor' n will select the first guard for any value
-- of n (including 0).  It is not useful to use two 'waitFor' guards in a
-- single 'Control.Concurrent.CHP.Alt.alt' anyway.
--
-- /NOTE:/ If you wish to use this as part of a choice, you must use @-threaded@
-- as a GHC compilation option (at least under 6.8.2).
waitFor :: Int -> CHP ()
waitFor n = makeAltable [(guardWaitFor n, return $ NoPoison ())]
-- TODO maybe fix the above lack of guarantees by keeping timeout guards explicit.

-- TODO add waitUntil

-- | The classic skip process\/guard.  Does nothing, and is always ready.
--
-- Suitable for use in an 'Control.Concurrent.CHP.Alt.alt'.
skip :: CHP ()
skip = makeAltable [(skipGuard, return $ NoPoison ())]

-- | Acts as @const liftIO_CHP@.  Useful only because it mirrors a different definition in the
-- chp-spec library.
--
-- Added in version 2.2.0.
liftIO_CHP' :: String -> IO a -> CHP a
liftIO_CHP' = const liftIO_CHP
