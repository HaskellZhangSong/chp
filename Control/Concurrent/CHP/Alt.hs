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


-- | A module containing constructs for choice, or alting.  An ALT (a term inherited from
-- occam) is a choice between several alternate events.  Events that inherently support choice are:
--
-- * 'Control.Concurrent.CHP.Monad.skip'
--
-- * 'Control.Concurrent.CHP.Monad.stop'
-- 
-- * 'Control.Concurrent.CHP.Monad.waitFor'
-- 
-- * Reading from a channel (including extended reads): that is, calls to 'Control.Concurrent.CHP.Channels.Communication.readChannel'
-- and 'Control.Concurrent.CHP.Channels.Communication.extReadChannel'
-- 
-- * Writing to a channel (including extended writes): that is, calls to 'Control.Concurrent.CHP.Channels.Communication.writeChannel'
-- and 'Control.Concurrent.CHP.Channels.Communication.extWriteChannel'
-- 
-- * Synchronising on a barrier (using 'Control.Concurrent.CHP.Barriers.syncBarrier')
-- 
-- * An alting construct (that is, you can nest alts) such as 'alt', 'priAlt' (or
-- the operator versions)
-- 
-- * A sequential composition, if the first event supports alting (i.e. is in this
-- list)
--
-- * A call to 'every', which joins together several items (see the documentation
-- on 'every').
--
-- There are several other events that can occur in CHP; these are assumed to be
-- always-ready when they are included in a choice.  Examples include:
--
-- * Enrolling and resigning with a barrier
-- 
-- * Poisoning a channel
-- 
-- * Processes composed in parallel (using 'runParallel', etc)
-- 
-- * Any lifted IO event
--
-- * Creating channels, barriers, etc
--
-- * Claiming a shared channel (yet...)
--
-- * A return statement by itself
--
-- Here are some examples of using alting:
--
-- * Wait for an integer channel, or 1 second to elapse:
--
-- > liftM Just (readChannel c) <|> (waitFor 1000000 >> return Nothing)
--
-- * Check if a channel is ready, otherwise return immediately; this can be done
-- using the 'optional' function from "Control.Applicative":
-- 
-- > optional (readChannel c)
--
-- * Wait for input from one of two (identically typed) channels
-- 
-- > readChannel c0 <|> readChannel c1
--
-- * Check if a channel is ready; if so send, it on, otherwise return immediately:
-- 
-- > (readChannel c >>= writeChannel d) <|> skip
--
-- Note that if you wait for a sequential composition:
--
-- > (readChannel c >>= writeChannel d) <|> (writeChannel e 6 >> readChannel f)
--
-- This only waits for the first action in both (reading from channel c, or writing
-- to channel e), not for all of the actions (as, for example, an STM transaction
-- would).
module Control.Concurrent.CHP.Alt (alt, (<->), priAlt, (</>), every, every_, (<&>)) where

import Control.Applicative ((<$>), (<|>))
import Data.Monoid (mappend)

import Control.Concurrent.CHP.Base (CHP(..), CHP'(..), liftIO_CHP, makeAltable', priAlt, throwPoison, wrapPoison)
import Control.Concurrent.CHP.Guard (Guard(..))
import Control.Concurrent.CHP.Monad (skip)
import Control.Concurrent.CHP.Parallel (runParallel)
import Control.Concurrent.CHP.Poison (WithPoison(..))

-- | An alt between several actions, with arbitrary priority.  The first
-- available action is chosen (with an arbitrary choice if many actions are
-- available at the same time), its body run, and its value returned.
alt :: [CHP a] -> CHP a
alt = priAlt

-- | A useful operator to perform an 'alt'.  This operator is associative,
-- and has arbitrary priority.  When you have lots of guards, it is probably easier
-- to use the 'alt' function.  'alt' /may/ be more efficent than
-- foldl1 (\<-\>)
(<->) :: CHP a -> CHP a -> CHP a
(<->) a b = alt [a,b]
  
-- | A useful operator to perform a 'priAlt'.  This operator is
-- associative, and has descending priority (that is, it is
-- left-biased).  When you have lots of actions, it is probably easier
-- to use the 'priAlt' function.  'priAlt' /may/ be more efficent than
-- foldl1 (\<\/\>)
--
-- Since version 2.2.0, this operator is deprecated in favour of the (<|>) operator
-- from the Alternative type-class.
(</>) :: CHP a -> CHP a -> CHP a
(</>) = (<|>)

infixl </>
infixl <->
infixl <&>

-- | Runs all the given processes in parallel with each other, but only when the
-- choice at the beginning of each item is ready.
--
-- So for example, if you do:
--
-- > every [ readChannel c >>= writeChannel d, readChannel e >>= writeChannel f]
--
-- This will forward values from c and e to d and f respectively in parallel, but
-- only once both channels c and e are ready to be read from.  So f cannot be written
-- to before c is read from (contrast this with what would happen if 'every' were
-- replaced with 'runParallel').
--
-- This behaviour can be somewhat useful, but 'every' is much more powerful when
-- used as part of an 'alt'.  This code:
--
-- > alt [ every [ readChannel c, readChannel d]
-- >     , every [ writeChannel e 6, writeChannel f 8] ]
--
-- Waits to either read from channels c and d, or to write to channels e and f.
--
-- The events involved can partially overlap, e.g.
--
-- > alt [ every [ readChannel a, readChannel b]
-- >     , every [ readChannel a, writeChannel c 6] ]
-- 
-- This will wait to either read from channels a and b, or to read from a and write
-- to c, whichever combination is ready first.  If both are ready, the choice between
-- them will be arbitrary (just as with any other choices; see 'alt' for more details).
--
-- The sets can even be subsets of each other, such as:
--
-- > alt [ every [ readChannel a, readChannel b]
-- >     , every [ readChannel a, readChannel b, readChannel b] ]
--
-- In this case there are no guarantees as to which choice will happen.  Do not
-- assume it will be the smaller, and do not assume it will be the larger.  
--
-- Be wary of what happens if a single event is included multiple times in the same 'every', as
-- this may not do what you expect (with or without choice).  Consider:
-- 
-- > every [ readChannel c >> writeChannel d 6
-- >       , readChannel c >> writeChannel d 8 ]
--
-- What will happen is that the excecution will wait to read from c, but then it
-- will execute only one of the bodies (an arbitrary choice).  In general, do not
-- rely on this behaviour, and instead try to avoid having the same events in an
-- 'every'.  Also note that if you synchronise on a barrier twice in an 'every',
-- this will only count as one member enrolling, even if you have two enrolled
-- ends!  For such a use, look at 'runParallel' instead.
--
-- Also note that this currently applies to both ends of channels, so that:
--
-- > every [ readChannel c, writeChannel c 2 ]
--
-- Will block indefinitely, rather than completing the communication.
--
-- Each item 'every' must support choice (and in fact
-- only a subset of the items supported by 'alt' are supported by 'every').  Currently the items
-- in the list passed to 'every' must be one of the following:
--
-- * A call to 'Control.Concurrent.CHP.Channels.readChannel' (or 'Control.Concurrent.CHP.Channels.extReadChannel').
-- 
-- * A call to 'Control.Concurrent.CHP.Channels.writeChannel' (or 'Control.Concurrent.CHP.Channels.extWriteChannel').
--
-- * 'Control.Concurrent.CHP.Monad.skip', the always-ready guard.
--
-- * 'Control.Concurrent.CHP.Monad.stop', the never-ready guard (will cause the whole 'every' to never be ready,
-- since 'every' has to wait for all guards).
--
-- * A call to 'Control.Concurrent.CHP.Monad.syncBarrier'.
--
-- * A sequential composition where the first item is one of the things in this
-- list.
--
-- * A call to 'every' (you can nest 'every' blocks inside each other).
--
-- Timeouts (e.g. 'Control.Concurrent.CHP.Monad.waitFor') are currently not supported.  You can always get another
-- process to synchronise on an event with you once a certain time has passed.
--
-- Note also that you cannot put an 'alt' inside an 'every'.  So you cannot say:
--
-- > every [ readChannel c
-- >       , alt [ readChannel d, readChannel e ] ]
--
-- To wait for c and (d or e) like this you must expand it out into (c and d) or
-- (c and e):
--
-- > alt [ every [ readChannel c, readChannel d]
-- >     , every [ readChannel c, readChannel e] ]
--
-- As long as x meets the conditions laid out above, 'every' [x] will have the same
-- behaviour as x.
--
-- Added in version 1.1.0
every :: [CHP a] -> CHP [a]
every [] = skip >> return []
every xs = makeAltable' (\tr -> let gs = map fst $ getAltable tr
  in [(foldl1 merge gs, return $ NoPoison ())]) >> wrapped
  where
    wrapped = PoisonT $ \t f -> let bodies = map snd $ getAltable t
      in wrapPoison t (runParallel (map wrap bodies)) >>= f

    wrap m = liftIO_CHP m >>= \v -> case v of
      PoisonItem -> throwPoison
      NoPoison x -> return x

    getAltable tr = flip map xs $ \x -> case runPoisonT x tr return of
      Altable _ [ga] -> ga
      _ -> error "Bad item in every"

    merge :: Guard -> Guard -> Guard
    merge SkipGuard g = g
    merge g SkipGuard = g
    merge StopGuard _ = StopGuard
    merge _ StopGuard = StopGuard
    merge (EventGuard recx actx esx) (EventGuard recy acty esy)
      = EventGuard (\n -> recx n ++ recy n) (actx `mappend` acty) (esx ++ esy)
    merge _ _ = error "every: merging unsupported guards"


-- | Like 'every' but discards the results.
--
-- Added in version 1.8.0.
every_ :: [CHP a] -> CHP ()
every_ ps = every ps >> return ()

-- | A useful operator that acts like 'every'.  The operator is associative and
-- commutative (see 'every' for notes on idempotence).  When you have lots of things
-- to join with this operator, it's probably easier to use the 'every' function.
--
-- Added in version 1.1.0
(<&>) :: CHP a -> CHP b -> CHP (a, b)
(<&>) a b = merge <$> every [Left <$> a, Right <$> b]
  where
    merge :: [Either a b] -> (a, b)
    merge [Left x, Right y] = (x, y)
    merge [Right y, Left x] = (x, y)
    merge _ = error "Invalid merge possibility in <&>"


