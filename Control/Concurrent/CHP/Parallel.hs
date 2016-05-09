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

module Control.Concurrent.CHP.Parallel (runParallel, runParallel_, (<||>), (<|*|>),
  runParMapM, runParMapM_ , ForkingT, liftForking, forking, fork) where

import Control.Concurrent
import Control.Concurrent.STM
import Control.Monad (liftM)
import qualified Control.Exception.Extensible as C
import Data.List
import Data.Maybe
import Data.Ord

import Control.Concurrent.CHP.Base
import Control.Concurrent.CHP.Poison
import Control.Concurrent.CHP.Traces.Base

-- | This type-class supports parallel composition of processes.  You may use
-- the 'runParallel' function to run a list of processes, or the '<||>' operator
-- to run just a pair of processes.
-- 
-- In each case, the composition waits for all processes to finish, either
-- successfully or with poison.  At the end of this, if /any/ process
-- exited with poison, the composition will \"rethrow\" this poison.  If all
-- the processes completed successfully, the results will be returned.  If
-- you want to ignore poison from the sub-processes, use an empty poison
-- handler and 'onPoisonTrap' with each branch.

-- | Runs the given list of processes in parallel, and then returns a list
-- of the results, in the same order as the processes given.  Will only return
-- when all the inner processes have completed.
--
-- In version 1.5.0, a bug was introduced such that @runParallel []@ would deadlock;
-- this was fixed in version 1.5.1.
runParallel :: [CHP a] -> CHP [a]
runParallel = runParallelPoison

-- | A shorthand for applying mapM in parallel; really the composition of 'runParallel'
-- and 'map'.
--
-- Added in version 1.5.0.
runParMapM :: (a -> CHP b) -> [a] -> CHP [b]
runParMapM f = runParallel . map f

-- | A shorthand for applying mapM_ in parallel; really the composition of 'runParallel_'
-- and 'map'.
--
-- Added in version 1.5.0.
runParMapM_ :: (a -> CHP b) -> [a] -> CHP ()
runParMapM_ f = runParallel_ . map f


-- | A useful operator for performing a two process equivalent of 'runParallel'
-- that gives the return values back as a pair rather than a list.  This also
-- allows the values to have different types
(<||>) :: CHP a -> CHP b -> CHP (a, b)
(<||>) p q = do [x, y] <- runParallel [liftM Left p, liftM Right q]
                combine x y
    where
      combine :: Monad m => Either a b -> Either a b -> m (a, b)
      combine (Left x) (Right y) = return (x, y)
      combine (Right y) (Left x) = return (x, y)
      -- An extra case to keep the compiler happy:
      combine _ _ = error "Impossible combination values in <|^|>"

-- | An operator similar to '<||>' that discards the output (more like an operator
-- version of 'runParallel_').
--
-- Added in version 1.1.0.
(<|*|>) :: CHP a -> CHP b -> CHP ()
(<|*|>) p q = runParallel_ [p >> return (), q >> return ()]

-- | Runs all the given processes in parallel and discards any output.  Does
-- not return until all the processes have completed.  'runParallel_' ps is effectively equivalent
-- to 'runParallel' ps >> return ().
--
-- In version 1.5.0, a bug was introduced such that @runParallel_ []@ would deadlock;
-- this was fixed in version 1.5.1.
runParallel_ :: [CHP a] -> CHP ()
runParallel_ procs = runParallel procs >> return ()

-- We right associate to allow the liftM fst ((readResult) <||> runParallel_
-- workers) pattern
infixr <||>
-- Doesn't really matter for this operator:
infixr <|*|>

-- | Runs all the processes in parallel and returns their results once they
-- have all finished.  The length and ordering of the results reflects the
-- length and ordering of the input
runParallelPoison :: [CHP a] -> CHP [a]
runParallelPoison processes
  = do resultVar <- liftIO_CHP $ atomically $ newManyToOneTVar
         ((== length processes) . length) (return []) []
       trace <- getTrace
       blanks <- liftIO_CHP $ blankTraces trace (length processes)
       liftIO_CHP $ 
         mapM_ forkIO [do y <- wrapProcess p btr pullOutStandard
                          C.block $ atomically $
                            writeManyToOneTVar
                             ((:) (case y of
                                 Nothing -> (n, Nothing)
                                 Just (NoPoison x) -> (n, Just x)
                                 Just PoisonItem -> (n, Nothing)
                                 )) resultVar
                             >> return ()
                      | (p, btr, n) <- zip3 processes blanks [(0::Int)..]]
       results <- liftIO_CHP $ atomically $ readManyToOneTVar resultVar
       let sortedResults = map snd $ sortBy (comparing fst) results
       liftIO_CHP $ mergeSubProcessTraces blanks trace
       mapM (maybe throwPoison return) sortedResults

-- | A monad transformer used for introducing forking blocks.
newtype ForkingT m a = Forking {runForkingT :: TVar (Bool, Int) -> m a }

instance Monad m => Monad (ForkingT m) where
  return = liftForking . return
  m >>= k = Forking $ \tv -> runForkingT m tv >>= (flip runForkingT tv . k)

instance MonadCHP m => MonadCHP (ForkingT m) where
  liftCHP = liftForking . liftCHP

-- TODO in future, get forking working with structural traces

-- | An implementation of lift for the ForkingT monad transformer.
--
-- Added in version 2.2.0.
liftForking :: Monad m => m a -> ForkingT m a
liftForking = Forking . const

-- | Executes a forking block.  Processes may be forked off inside (using the
-- 'fork' function).  When the block completes, it waits for all the forked
-- off processes to complete before returning the output, as long as none of
-- the processes terminated with uncaught poison.  If they did, the poison
-- is propagated (rethrown).
forking :: MonadCHP m => ForkingT m a -> m a
-- Like with parallel, this could probably be made a little more efficient
forking (Forking m) = do b <- liftCHP . liftSTM $ newTVar (False, 0)
                         output <- m b
                         p <- liftCHP . liftSTM $ do
                           (p,n) <- readTVar b
                           if n == 0
                             then return p
                             else retry
                         if p
                           then liftCHP throwPoison
                           else return output
                         

-- | Forks off the given process.  The process then runs in parallel with this
-- code, until the end of the 'forking' block, when all forked-off processes
-- are waited for.  At that point, once all of the processes have finished,
-- if any of them threw poison it is propagated.
fork :: MonadCHP m => CHP () -> ForkingT m ()
fork p = Forking $ \b ->
           do liftCHP . liftSTM $ do
                (pa, n) <- readTVar b
                writeTVar b (pa, n + 1)
              trace <- liftCHP getTrace
              [blank] <- liftCHP . liftIO_CHP $ blankTraces trace 1
              _ <- liftCHP . liftIO_CHP $ forkIO $ do
                r <- wrapProcess p blank pullOutStandard
                C.block $ atomically $ do
                  (poisonedAlready, n) <- readTVar b
                  writeTVar b (poisonedAlready || isNothing r, n - 1)
              return ()

