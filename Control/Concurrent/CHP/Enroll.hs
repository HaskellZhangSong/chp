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

-- | A module with support for things that are enrollable (barriers and broadcast
-- channels).

module Control.Concurrent.CHP.Enroll (Enrolled, Enrollable(..), furtherEnroll,
  enrollPair, enrollList, enrollAll, enrollAll_, enrollAllT, enrollOneMany) where

import Control.Concurrent.CHP.Base
import Control.Concurrent.CHP.Parallel

class Enrollable b z where
  -- | Enrolls on the given barrier, then executes the given function (passing
  -- it in the enrolled barrier) and when that function body finishes, resigns
  -- from the barrier and returns the result.  If a poison or IO exception is thrown
  -- in the inside block, the barrier will be correctly resigned from, and
  -- the exception rethrown.
  --
  -- Do not attempt to return the
  -- enrolled barrier out of the inner function and use it afterwards.
  enroll :: b z -> (Enrolled b z -> CHP a) -> CHP a

  -- | Resigns from a barrier, then executes the given action, and when the
  -- action finishes, re-enrolls on the barrier and continues.  This function
  -- is designed for use from /inside/ the body of the 'enroll' function, to
  -- temporarily resign from a barrier, do some things, then re-enroll.  Do
  -- not use the enrolled barrier inside the resign block.  However, you may
  -- enroll on the barrier inside this, nesting enroll and resign blocks as
  -- much as you like
  resign :: Enrolled b z -> CHP a -> CHP a

-- | Just like enroll, but starts with an already enrolled item.  During the
-- body, you are enrolled twice -- once from the original enrolled item (which
-- is still valid in the body) and once from the new enrolled item passed to
-- the inner function.  Afterwards, you are enrolled once, on the original item
-- you had.
--
-- This function was added in version 1.3.2.
furtherEnroll :: Enrollable b z => Enrolled b z -> (Enrolled b z -> CHP a) -> CHP a
furtherEnroll (Enrolled x) = enroll x

-- | Like 'enroll' but enrolls on the given pair of barriers
enrollPair :: (Enrollable b p, Enrollable b' p') => (b p, b' p') -> ((Enrolled
  b p, Enrolled b' p') -> CHP a) -> CHP a
enrollPair (b0,b1) f = enroll b0 $ \eb0 -> enroll b1 $ \eb1 -> f (eb0, eb1)

-- | Like 'enroll' but enrolls on the given list of barriers
enrollList :: Enrollable b p => [b p] -> ([Enrolled b p] -> CHP a) -> CHP a
enrollList [] f = f []
enrollList (b:bs) f = enroll b $ \eb -> enrollList bs $ f . (eb:)

-- | Given a command to allocate a new barrier, and a list of processes that use
-- that barrier, enrolls the appropriate number of times (i.e. the list length)
-- and runs all the processes in parallel using that barrier, then returns a list
-- of the results.
--
-- If you have already allocated the barrier, pass @return bar@ as the first parameter.
--
-- Added in version 1.7.0.
enrollAll :: Enrollable b p => CHP (b p) -> [Enrolled b p -> CHP a] -> CHP [a]
enrollAll = enrollAllT runParallel

enrollAllT :: Enrollable b p => ([a] -> CHP c) -> CHP (b p) -> [Enrolled b p -> a] -> CHP c
enrollAllT run mbar ps = mbar >>= flip enrollList (run . zipWith ($) ps) . replicate (length ps)

enrollOneMany :: Enrollable b p => ([Enrolled b p] -> CHP a) -> [(CHP (b p), Enrolled b p -> CHP c)] -> CHP (a, [c])
enrollOneMany p [] = p [] >>= \x -> return (x, [])
enrollOneMany p ((mbar, q) : rest)
  = do bar <- mbar
       enrollPair (bar, bar) $ \(b0, b1) ->
         do ((p', q'), rest') <- enrollOneMany (\bs -> p (b0:bs) <||> q b1) rest
            return (p', q' : rest')
--TODO there is probably a better way to implement the above


-- | Like enrollAll, but discards the results.
--
-- Added in version 1.7.0.
enrollAll_ :: Enrollable b p => CHP (b p) -> [Enrolled b p -> CHP a] -> CHP ()
enrollAll_ = enrollAllT runParallel_
