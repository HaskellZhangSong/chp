
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

--TODO document this (for internal purposes)
module Control.Concurrent.CHP.Event (RecordedEventType(..), Event, getEventUnique,
  SignalVar, SignalValue(..), enableEvents, disableEvents,
  newEvent, newEventPri, newEventUnique, enrollEvent, resignEvent, poisonEvent, checkEventForPoison,
  getEventTypeVal
#ifdef CHP_TEST
  , testAll
#endif
  ) where

import Control.Applicative
import Control.Arrow
import Control.Concurrent
import Control.Concurrent.STM hiding (always)
import Control.Concurrent.CHP.EventType
import Control.Monad
#ifdef CHP_TEST
import Control.Monad.State
#endif
import Data.Function
import Data.List hiding (or)
import Data.Ord
import qualified Control.Concurrent.CHP.EventMap as EventMap (empty, toList, unionWith)
import qualified Control.Concurrent.CHP.EventSet as EventSet (deleteOrFail,
#ifdef CHP_TEST
  empty,
#endif
  fromList, member, toList, union)
import qualified Control.Concurrent.CHP.EventMap as OfferSetMap (insert, keysSet, minViewWithKey, unionWithM, values)
import qualified Control.Concurrent.CHP.EventSet as OfferSetSet (delete, insert, intersection, null, toMap)
--import qualified Data.IntMap as IntMap
import qualified Data.Map as Map
import Data.Maybe
import qualified Data.Set as Set
import qualified Data.Traversable as T
import Data.Unique
import Prelude hiding (cos, or, seq)
#ifdef CHP_TEST
import Test.HUnit hiding (test, State)
#endif

import Control.Concurrent.CHP.Poison
import Control.Concurrent.CHP.ProcessId

type DiscoverM = WithPoisonMaybeT STM

type OfferSetMap v = [(OfferSet, v)]
type OfferSetSet = [OfferSet]

data SearchState = SS
  { visited :: OfferSetMap SearchResult, notVisited :: OfferSetMap [TrimmedOffer] }

data CurOfferSet = New OfferSet | Old OfferSet | Resigning

data TrimmedOffer = TrimmedOffer { pristineOffer :: Offer, trimmedEvents :: EventSet }

addResult :: OfferSet -> SearchResult -> SearchState -> SearchState
addResult os r (SS v nv) = SS (OfferSetMap.insert os r v) nv

-- First parameter is Left for original,  (Just offerSet) if existing, Just
-- Nothing if resigning
checkEvent :: CurOfferSet -> SearchState -> Event -> DiscoverM SearchState
checkEvent cos ss e = do
  s <- liftWPMT $ readTVar $ getEventTVar e
  case s of
    PoisonItem -> WPMT $ return PoisonItem
    NoPoison (enrollCount, _, offers) ->
      let numOffers = length offers
      in if numOffers >= enrollCount || (numOffers >= enrollCount - 1 && isDefinitelyNew)
           then WPMT . return . NoPoison $ addFilter (deleteCur offers) e ss
           else backtrack
  where
    isDefinitelyNew = case cos of
      New _ -> True
      _ -> False

    deleteCur = case cos of
      Old os -> OfferSetSet.delete os
      _ -> id
      -- No need to delete new offerset as it won't be there

--TODO could merge this with checkEvent

-- The current offer-set will have been removed from the list:
addFilter :: OfferSetSet -> Event -> SearchState -> Maybe SearchState
addFilter allos e ss
  | OfferSetSet.null allos = Just ss
  | not . OfferSetSet.null $ OfferSetSet.intersection allos (OfferSetMap.keysSet $ visited ss) = Nothing
  | otherwise = SS (visited ss) <$> OfferSetMap.unionWithM merge (notVisited ss) (OfferSetSet.toMap getOffers allos)
  where
    nullNothing [] = Nothing
    nullNothing xs = Just xs

    -- Will only return Just if at least one given trimmed offer contains the event we're
    -- interested in; and if so it will return only those offers that contained
    -- the event -- but with that event removed from the offers
    mustHaveThenStrike :: [TrimmedOffer] -> Maybe [TrimmedOffer]
    mustHaveThenStrike = nullNothing . mapMaybe (\(TrimmedOffer p es) -> TrimmedOffer p <$> EventSet.deleteOrFail e es)

    merge :: Maybe [TrimmedOffer] -> Maybe [TrimmedOffer] -> Maybe [TrimmedOffer]
    merge (Just t) Nothing = Just t -- Nothing new here
    merge Nothing (Just t) = mustHaveThenStrike t -- We are new; insert filtered
    merge (Just t) (Just _) = mustHaveThenStrike t -- Have old; filter that one
    merge Nothing Nothing = error "Event.merge"
    
getOffers :: OfferSet -> [TrimmedOffer]
getOffers os = [TrimmedOffer o (eventsSet o) | o <- offersSet os]

    -- Each event in the map can have three possible values:
    -- PoisonItem; event is poisoned, can always be completed
    -- NoPoison True; event has been chosen by previous process, you must choose
    -- it too
    -- NoPoison False; event has been rejected by previous process, you cannot
    -- choose it

--eventSet :: EventMap a -> EventSet
--eventSet = EventMap.map (const ()) -- IntMap.fromList . map (\(e, _) -> (hashUnique $ getEventUnique e, e)) . EventMap.toList

eventMap :: (Event -> a) -> EventSet -> EventMap a
eventMap f = map (\e -> (e, f e))

allEventsInOffer :: OfferSet -> EventSet
allEventsInOffer = foldl1 EventSet.union . map eventsSet . offersSet

getAndIncCounter :: Event -> (a, b) -> STM (WithPoison (Integer, a))
getAndIncCounter e (r, _)
  = do x <- readTVar (getEventTVar e)
       case x of
         PoisonItem -> return PoisonItem
         NoPoison (a, !n, c) -> do writeTVar (getEventTVar e) $
                                     NoPoison (a, succ n, c)
                                   return $ NoPoison (n, r)


-- Here is how it all works.  There are events
-- Each event is:
-- * poisoned
-- * not poisoned and has:
--   * an enrollment count EC
--   * a list of offer-sets.
-- Each offer-set represents a process, and is:
-- * a list of conjunctions (offers), where each conjunction/offer is:
--   * an event-set (no duplicates allowed!)
--
-- All the event-handling code is called for one of two reasons:
-- * resignation from an event.  This may:
--   * cause that single event to complete
-- * making an offer-set.  This may:
--   * cause one of the conjunctions/offers to complete
--
-- So, we begin with either an event or an offer-set:
-- * Offer-set.  You examine each offer in turn:
--   * You have a set of events, S.  All must be able to complete.  Check each event:
--     * If the event is poisoned, we stop with poison
--     * If the event has less than EC-1 offer-sets, this whole offer cannot complete
--     * If the event has EC-1 offer-sets, it can complete providing all its offer-sets
--       can.  For each offer-set:
--       * Filter the offer-sets to those that include the parent event.  Then
--         recurse to the top-level and see if those offer-sets can be completed,
--         with the proviso that any-time you encounter an event from S, it only needs
--         its EC-1 offer-sets; all other events require EC offers.  Also, do not
--         count any offers in the current offer-set but not the current offer;
--         or put another way, do not consider any events containing this offer-set
--         not in this offer.
--           

type SearchResult = ( [(SignalVar, SignalValue, STM ())]
                    , EventMap (STM RecordedEventType, Set.Set ProcessId)
                    )
combineSearch :: [SearchResult] -> SearchResult
combineSearch [] = ([], EventMap.empty)
combineSearch rs = foldl1 f rs
  where
    f (xs, xm) (ys, ym) = (xs ++ ys, xm `combineMap` ym)
    combineMap = EventMap.unionWith (\(x, y) (_, z) -> (x, y `Set.union` z))

data WithPoisonMaybeT m a = WPMT { runWPMT :: m (WithPoison (Maybe a)) }
instance Monad m => Monad (WithPoisonMaybeT m) where
  return = WPMT . return . NoPoison . Just
  m >>= f = WPMT $ do
    x <- runWPMT m
    case x of
      PoisonItem -> return PoisonItem
      NoPoison Nothing -> return $ NoPoison Nothing
      NoPoison (Just y) -> runWPMT $ f y

instance Monad m => Functor (WithPoisonMaybeT m) where
  fmap f = WPMT . liftM (fmap (fmap f)) . runWPMT

liftWPMT :: Monad m => m a -> WithPoisonMaybeT m a
liftWPMT = WPMT . liftM (NoPoison . Just)



instance (Monad m) => Applicative (WithPoisonMaybeT m) where
  pure = return
  (<*>) = ap

instance (Monad m) => Alternative (WithPoisonMaybeT m) where
  empty = WPMT $ return $ NoPoison Nothing
  (<|>) a b = WPMT $ runWPMT a >>= \x -> case x of
    PoisonItem -> return PoisonItem
    NoPoison Nothing -> runWPMT b
    y -> return y

backtrack :: Alternative f => f a
backtrack = empty

search :: (Alternative f, Monad f) => [f a] -> f a
search [] = empty
search xs = foldl1 (<|>) xs

searchWith :: (Alternative f, Monad f) => (a -> f b) -> [a] -> f b
searchWith = (search .) . map

searchOfferSet :: CurOfferSet -> [TrimmedOffer] -> SearchState -> DiscoverM SearchResult
searchOfferSet cos offers ss
  = searchWith searchOffer offers
  where
    searchOffer offer
      = do ss' <- foldM (checkEvent cos) ss (trimmedEvents offer)
           processNext $ case cos of
             New os -> addResult os ([(signalVar os, signalValue o, offerAction o)],
               eventMap (\e -> (getEventType e, Set.singleton $ processId os)) $ eventsSet o) ss'
             Resigning -> ss
             Old os -> addResult os ([(signalVar os, signalValue o, offerAction o >> retractOfferSet os)]
                      , eventMap (\e -> (getEventType e, Set.singleton $ processId os)) (eventsSet o)) ss'
      where
        o = pristineOffer offer

searchOriginalOfferSet :: OfferSet -> DiscoverM SearchResult
searchOriginalOfferSet os = searchOfferSet (New os) (sortBy (flip $ comparing (getEventPriority . head . trimmedEvents)) $ getOffers os) (SS [] [])

processNext :: SearchState -> DiscoverM SearchResult
processNext s = case OfferSetMap.minViewWithKey (notVisited s) of
                  -- All visited:
                  Nothing -> return $ combineSearch (OfferSetMap.values $ visited s)
                  -- At least one left:
                  Just ((os, next), rest) -> searchOfferSet (Old os) next (s { notVisited = rest })
         
-- Given a list of offers that could possibly complete, check if any set
-- of offers can.  If so, complete it (including all retractions and
-- notifications for each process), otherwise leave things untouched.
--
-- Takes an optional tvar identifier for the newest process to make an offer, the
-- list of all offer-sets that need to be considered (they will have come from
-- all events in a connected sub-graph), the map of relevant events to their status,
-- and returns the map of event-identifiers that did complete.
discoverAndResolve :: Either OfferSet Event
  -> STM (WithPoison (Map.Map Unique (RecordedEventType, Set.Set ProcessId)))
discoverAndResolve start = do
 r <- runWPMT $ either searchOriginalOfferSet
        (processNext <=< checkEvent Resigning (SS [] []))
        start
 case r of
   PoisonItem -> do either (flip writeTVar (Just (Signal PoisonItem, Map.empty)) . signalVar)
                           (const $ return ()) start
                    return PoisonItem
   NoPoison Nothing ->
     -- Must record our offers
     (const Map.empty <$>) <$> case start of
         Left offerSet -> makeAllOffers offerSet
         Right _ -> return $ NoPoison ()
   NoPoison (Just (actPossDup, ret)) ->
    do let act = nubBy ((==) `on` (\(var, _, _) -> var)) actPossDup
       -- The associated event-action must come first as that puts the values in the channels:
       mapM_ (\(_, _, m) -> m) act
       -- These values are then read by these on-completion bits:
       ret' <- mapM (\(k, (em, y)) -> do x <- em
                                         return (k, (x, y))) $ EventMap.toList ret
       NoPoison eventCounts <- liftM T.sequence . T.sequence $ map (\(k, v) -> liftM
         ((,) k) <$> getAndIncCounter k v) ret'
       let uniqCounts = Map.fromList $ map (first getEventUnique) eventCounts
       mapM_ (\(tv, x, _) -> writeTVar tv (Just (x, uniqCounts))) act

       return $ NoPoison (Map.fromAscList $ map (first getEventUnique) ret')


-- Semantics of poison with waiting for multiple events is that if /any/ of
-- the events are poisoned, that whole offer will be available immediately
-- even if the other channels are not ready, and the body will throw a poison
-- exception rather than running any of the guards.  This is because in situations
-- where for example you want to wait for two inputs (e.g. invisible process
-- or philosopher's forks) you usually want to forward poison from one onto
-- the other.

newEventUnique :: IO Unique
newEventUnique = newUnique

enrollEvent :: Event -> STM (WithPoison ())
enrollEvent e
  = do x <- readTVar $ getEventTVar e
       case x of
         PoisonItem -> return PoisonItem
         NoPoison (count, seq, offers) ->
           do writeTVar (getEventTVar e) $ NoPoison (count + 1, seq, offers)
              return $ NoPoison ()

-- If the event completes, we return details related to it:
resignEvent :: Event -> STM (WithPoison [((RecordedEventType, Unique), Set.Set ProcessId)])
resignEvent e
  = do x <- readTVar $ getEventTVar e
       case x of
         PoisonItem -> return PoisonItem
         NoPoison (count, seq, offers) ->
           do writeTVar (getEventTVar e) $ NoPoison (count - 1, seq, offers)
              if count - 1 == length offers
                then liftM (fmap $ \mu -> [((r,u),pids) | (u,(r,pids)) <- Map.toList mu])
                       $ discoverAndResolve $ Right e
                else return $ NoPoison []

-- Given the list of identifiers paired with all the events that that process might
-- be engaged in, retracts all the offers that are associated with the given TVar;
-- i.e. the TVar is used as an identifier for the process
retractOffers :: [(OfferSet, EventSet)] -> STM ()
retractOffers = mapM_ retractAll
  where
    retractAll :: (OfferSet, EventSet) -> STM ()
    retractAll (offerSet, evts) = mapM_ retract (EventSet.toList evts)
      where
        retract :: Event -> STM ()
        retract e
          = do x <- readTVar $ getEventTVar e
               case x of
                 PoisonItem -> return ()
                 NoPoison (enrolled, seq, offers) ->
                   let reducedOffers = OfferSetSet.delete offerSet offers in
                   writeTVar (getEventTVar e) $ NoPoison (enrolled, seq, reducedOffers)

retractOfferSet :: OfferSet -> STM ()
retractOfferSet = retractOffers . (:[]) . (id &&& allEventsInOffer)
      

-- Simply adds the offers but doesn't check if that will complete an event:
-- Returns PoisonItem if any of the events were poisoned
makeOffer :: OfferSet -> (Event -> STM (WithPoison ()))
makeOffer offers = makeOffer'
  where
    makeOffer' :: Event -> STM (WithPoison ())
    makeOffer' e
      = do x <- readTVar $ getEventTVar e
           case x of
             PoisonItem -> return PoisonItem
             NoPoison (count, seq, prevOffers) ->
               do writeTVar (getEventTVar e) $ NoPoison (count, seq, OfferSetSet.insert offers prevOffers)
                  return $ NoPoison ()

makeAllOffers :: OfferSet -> STM (WithPoison ())
makeAllOffers offerSet
  = sequence_ <$> mapM (makeOffer offerSet) (EventSet.toList $ allEventsInOffer offerSet)

-- Returns Nothing if no events were ready.  Returns Just with the signal value
-- if an event was immediately available, followed by the information for each
-- event involved in the synchronisation.  If poison was encounted, this list will
-- be empty.
enableEvents :: SignalVar
                  -- ^ Variable used to signal the process once a choice is made
                -> (ThreadId, ProcessId)
                  -- ^ The id of the process making the choice
                -> [((SignalValue, STM ()), [Event])]
                  -- ^ The list of options.  Each option has a signalvalue to return
                  -- if chosen, and a list of events (conjoined together).
                  --  So this list is the disjunction of conjunctions, with a little
                  -- more information.
                -> Bool
                  -- ^ True if it can commit to waiting.  If there is an event
                  -- combination ready during the transaction, it will chosen regardless
                  -- of the value of this flag.  However, if there no events ready,
                  -- passing True will leave the offers there, but False will retract
                  -- the offers.
                -> STM (Either
                          (STM (Maybe (SignalValue, Map.Map Unique (Integer, RecordedEventType))))
                          ((SignalValue, Map.Map Unique (Integer, RecordedEventType)), [((RecordedEventType, Unique), Set.Set ProcessId)])
                       )
enableEvents tvNotify (tid, pid) events canCommitToWait
  = do let offer = makeOfferSet tvNotify pid tid [(nid, EventSet.fromList es) | (nid, es) <- events]
       -- Then spider out and see if anything can be resolved:
       pmu <- discoverAndResolve (Left offer)
       case (canCommitToWait, pmu) of
         (_, PoisonItem) -> return $ Right ((Signal PoisonItem, Map.empty), [])
         (True, NoPoison mu) | Map.null mu -> return $ Left $ disableEvents offer (concatMap snd events)
         (False, NoPoison mu) | Map.null mu ->
           do retractOffers [(offer, EventSet.fromList $ concatMap snd events)]
              return $ Left $ error "enableEvents"
         (_, NoPoison mu) -> -- Need to turn all the Unique ids back into the custom-typed
                   -- parameter that the user gave in the list.  We assume
                   -- it will be present:
                do {- let y = mapMaybe (\(k,v) -> listToMaybe [(x,v) | (x,_,_,es) <- events,
                              k `elem` map getEventUnique es]) $ Map.toList mu
                                -}
                   Just chosenItem <- readTVar tvNotify
                   return $ Right (chosenItem, [((r,u),pids) | (u,(r,pids)) <- Map.toList mu])

-- | Given the variable used to signal the process, and the list of events that
-- were involved in its offers, attempts to disable the events.  If the variable
-- has been signalled (i.e. has a Just value), that is returned and nothing is done, if the variable
-- has not been signalled (i.e. is Nothing), the events are disabled and Nothing
-- is returned.
disableEvents :: OfferSet -> [Event] -> STM (Maybe (SignalValue, Map.Map Unique (Integer,
  RecordedEventType)))
disableEvents offer events
  = do x <- readTVar $ signalVar offer
       -- Since the transaction will be atomic, we know
       -- now that we can disable the barriers and nothing fired:
       when (isNothing x) $
         retractOffers [(offer, EventSet.fromList events)]
       return x

checkEventForPoison :: Event -> STM (WithPoison ())
checkEventForPoison e
  = do x <- readTVar $ getEventTVar e
       case x of
         PoisonItem -> return PoisonItem
         _ -> return (NoPoison ())

poisonEvent :: Event -> STM ()
poisonEvent e
  = do x <- readTVar $ getEventTVar e
       case x of
         PoisonItem -> return ()
         NoPoison (_, _, offers) ->
           do retractOffers $ map (id &&& allEventsInOffer) offers
              sequence_ [writeTVar (signalVar o) (Just (addPoison $ pickInts (offersSet o), Map.empty))
                        | o <- offers]
              writeTVar (getEventTVar e) PoisonItem
  where
    pickInts :: [Offer] -> SignalValue
    pickInts es = case filter ((e `EventSet.member`) . eventsSet) es of
      [] -> nullSignalValue -- Should never happen
      (o:_) -> signalValue o

----------------------------------------------------------------------
----------------------------------------------------------------------
-- Testing:
----------------------------------------------------------------------
----------------------------------------------------------------------
#ifdef CHP_TEST

unionAll :: [EventSet] -> EventSet
unionAll [] = EventSet.empty
unionAll ms = foldl1 EventSet.union ms


-- Tests if two lists have the same elements, but not necessarily in the same order:
(**==**) :: Eq a => [a] -> [a] -> Bool
a **==** b = (length a == length b) && null (a \\ b)

(**/=**) :: Eq a => [a] -> [a] -> Bool
a **/=** b = not $ a **==** b

testPoison :: Test
testPoison = TestCase $ do
  test "Poison empty event" [(NoPoison $ EventInfo 2 0, PoisonItem)] [] 0
  test "Poison, single offerer" [(NoPoison $ EventInfo 2 0, PoisonItem)] [[[0]]] 0
  test "Poison, offered on two (AND)" [(NoPoison $ EventInfo 2 0, PoisonItem), (NoPoison $ EventInfo 2 0, NoPoison [])] [[[0,1]]] 0
  test "Poison, offered on two (OR)" [(NoPoison $ EventInfo 2 0, PoisonItem), (NoPoison $ EventInfo 2 0, NoPoison [])] [[[0],[1]]] 0
  where
    test :: String ->
      [(WithPoison EventInfo {-count -}, WithPoison [Int] {- remaining offers -})] ->
      {- Offers: -} [[[Int] {- events -}]] -> Int {-Poison Event-} -> IO ()

    test testName eventCounts offerSets poisoned = do
      (events, realOffers) <- makeTestEvents (map fst eventCounts) $
        map (map (flip (,) (return ()))) offerSets
      atomically $ poisonEvent $ events !! poisoned
      -- Now we must check that the event is poisoned, and that all processes
      -- that were offering on that event have had their offers retracted (by
      -- checking that only the specified offers remain on each event)

      sequence_ [do x <- atomically $ readTVar $ getEventTVar $ events !! n
                    case (expect, x) of
                      (PoisonItem, PoisonItem) -> return ()
                      (NoPoison _, PoisonItem) -> assertFailure $ testName ++
                        " expected no poison but found it"
                      (PoisonItem, NoPoison _) -> assertFailure $ testName ++
                        " expected poison but found none"
                      (NoPoison expOff, NoPoison (_, _, actOff)) ->
                        when (map (realOffers !!) expOff **/=** actOff) $
                          assertFailure $ testName ++ " offers did not match"
                | (n, (_, expect)) <- zip [0..] eventCounts]


    
testAll :: Test
testAll = TestList [{-testDiscover, testTrim, -}testResolve, testPoison]

makeTestEvents ::
            {- Events: -} [WithPoison EventInfo {-count -}] ->
            {- Offers: -} [[([Int] {- events -}, STM ())]] -> IO ([Event], [OfferSet])
            -- Offers is a list of list of list of ints
            -- Outermost list is one-per-process
            -- Middle list is one-per-offer
            -- Inner list is a conjunction of events
makeTestEvents eventCounts offerSets
      = do events <- mapM (\x -> uncurry (newEventPri (return $ ChannelComm "")) $ case x of
             NoPoison (EventInfo n pri) -> (n, pri)
             PoisonItem -> (0, 0)) eventCounts
           -- Poison all the events marked as poisoned:
           atomically $ sequence_ [writeTVar (getEventTVar e) PoisonItem | (n, e) <- zip [0..] events, eventCounts !! n == PoisonItem]
           -- Nasty, but it's only for testing:
           tids <- replicateM (length offerSets) $ forkIO (threadDelay 1000000)
           realOffers <- sequence
             [ do tv <- atomically $ newTVar Nothing
                  let pid = testProcessId processN
                      -- TODO test the STM actions too
                      offSub = [ ((Signal $ NoPoison (processN + offerN), act),
                                  EventSet.fromList (map (events !!) singleOffer))
                               | (offerN, (singleOffer, act)) <- zip [0..] processOffers]
                      off = makeOfferSet tv pid tid offSub
                  when (processN /= 1000 * (length offerSets - 1)) $ mapM_ (\e -> atomically $ do
                    x <- readTVar (getEventTVar e)
                    case x of
                      NoPoison (count, s, offs) ->
                        writeTVar (getEventTVar e) $ NoPoison (count, s, OfferSetSet.insert off offs)
                      PoisonItem -> return ()
                    ) (EventSet.toList $ unionAll $ map snd offSub)
                  return off
             | (tid, processN, processOffers) <- zip3 tids (map (*1000) [0..]) offerSets]
           return (events, realOffers)

data EventInfo = EventInfo {eventEnrolled :: Int, eventPriority :: Int}
  deriving (Eq, Show)

type CProcess = [CEvent] -- The list of conjunctions
newtype EventDSL a = EventDSL (State ([EventInfo], [CProcess])  a)
  deriving (Monad)

data ProcOrders = ProcOrders { procFinals :: [COffer]
                             , procAll :: [COffer]
                             }

runDSL :: EventDSL (ProcOrders, Outcome) ->
 [(([WithPoison EventInfo {- enrolled count -}],
    [[ Either [(Int, Int)] {- success: expected process, offer indexes -}
              [Int] {- remaining offers -}
    ]])
  ,{- Offers: -} [[[Int] {- events -}]])]
runDSL (EventDSL m)
  = let ((procOrders, Many outcomes), (evts, ps)) = runState m ([], [])
        orderings = [(h, procAll procOrders \\ [h]) | h <- procFinals procOrders]
    in
   [let conv p
            | p == cOffer new = length already
            | p < cOffer new = p
            | otherwise = p - 1
    in ((map NoPoison evts
        ,[let completing = nub $ concatMap cEvent [(ps !! p) !! i | (p, i) <- o]
              completers e = [(conv p, i) | (p, i) <- o, e `elem` cEvent ((ps !! p) !! i)]
              allCompleters = nub $ concatMap (map fst . completers) is
              is = [0..(length evts - 1)]
          in
          [if i `elem` completing
            then Left $ completers i
            else Right [conv j | (j, p) <- zip [0..] ps
                       , conv j `notElem` allCompleters
                       , i `elem` concatMap cEvent p]
          | i <- is ]
         | o <- outcomes]
        )
       , map (map cEvent . (ps !!) . cOffer) already ++ [map cEvent $ ps !! cOffer new] -- TODO iron this out later on
       )
    | (new, already) <- orderings]

evt :: Int -> EventDSL CEvent
evt n = evtNPri n 0

evtNPri :: Int -> Int -> EventDSL CEvent
evtNPri n pri = EventDSL $ do (evts, x) <- get
                              put (evts ++ [EventInfo n pri], x)
                              return $ CEvent [length evts]

newtype CEvent = CEvent {cEvent :: [Int]}
newtype COffer = COffer {cOffer :: Int}
  deriving Eq

offer :: [CEvent] -> EventDSL COffer
offer o = EventDSL $
  do (x, ps) <- get
     put (x, ps ++ [o])
     return $ COffer (length ps)

class Andable c where
  (&) :: c -> c -> c

instance Andable CEvent where
  (&) (CEvent a) (CEvent b) = CEvent (a ++ b)

-- Many is (process index, offer index)
data Outcome = Many [[(Int, Int)]]

(~>) :: COffer -> Int -> Outcome
(~>) (COffer p) i = Many [[(p, i)]]

instance Andable Outcome where
  (&) (Many [a]) (Many [b]) = Many [a++b]

(==>) :: [COffer] -> Outcome -> EventDSL (ProcOrders, Outcome)
(==>) finals o = EventDSL $ do
  (_, ps) <- get
  let allProcs = map COffer [0..(length ps - 1)]
  if null finals
    then return (ProcOrders allProcs allProcs, o)
    else return (ProcOrders finals allProcs, o)

none :: Outcome
none = Many [[]]

or :: Outcome -> Outcome -> Outcome
or (Many a) (Many b) = Many (a ++ b)

infix 0 ==>
infix 2 ~>
infixl 1 &

always = ([] ==>)

testResolve :: Test
testResolve = TestList $
     [ testD "Single offer on single event" $ do
         a <- evt 1
         p <- offer [a]
         always$ p ~> 0
     , testD "Not enough; one offer on two-party event" $ do
         a <- evt 2
         p <- offer [a]
         always$ none
     , testD "Not enough; two offers on three-party event" $ do
         a <- evt 3
         p <- offer [a]
         q <- offer [a]
         always$ none
     , testD "One channel, standard communication" $ do
         a <- evt 2
         p <- offer [a]
         q <- offer [a]
         always$ p ~> 0 & q ~> 0
     , testD "Two channels, two single offerers and one double" $ do
         a <- evt 2
         b <- evt 2
         p <- offer [a&b]
         q <- offer [a]
         r <- offer [b]
         always$ p ~> 0 & q ~> 0 & r ~> 0
     , testD "Two channels, two single offerers and one choosing" $ do
         a <- evt 2
         b <- evt 2
         p <- offer [a, b]
         q <- offer [a]
         r <- offer [b]
         [p] ==> (p ~> 0 & q ~> 0) `or` (p ~> 1 & r ~> 0)
     , testD "Two channels, both could complete" $ do
         [a, b] <- replicateM 2 $ evt 2
         [p, q] <- replicateM 2 $ offer [a, b]
         always$ (p ~> 0 & q ~> 0) `or` (p ~> 1 & q ~> 1)
     , testD "Two channels, both could complete, one pri" $ do
         [a, b] <- mapM (evtNPri 2) [0, 1]
         [p, q] <- sequence [offer [a, b], offer [b, a]]
         always$ (p ~> 1 & q ~> 0)
     , testD "Three channels, two could complete" $ do
         [a, b, c] <- replicateM 3 $ evt 2
         p <- offer [a, b, c]
         q <- offer [a]
         r <- offer [c]
         [p] ==> (p ~> 0 & q ~> 0) `or` (p ~> 2 & r ~> 0)
     , testD "Three channels, any could complete" $ do
         [a, b, c] <- replicateM 3 $ evt 2
         p <- offer [a, b, c]
         q <- offer [a]
         r <- offer [b]
         s <- offer [c]
         [p] ==> (p ~> 0 & q ~> 0) `or` (p ~> 1 & r ~> 0) `or` (p ~> 2 & s ~> 0)
     , testD "Three channels, both offering different overlapping pair" $ do
         [a, b, c] <- replicateM 3 $ evt 2
         p <- offer [a, b]
         q <- offer [b, c]
         always$ p ~> 1 & q ~> 0
     , testD "Three channels, one guy offering three pairs, two single offerers" $ do
         [a, b, c] <- replicateM 3 $ evt 2
         p <- offer [a&b, a&c, b&c]
         q <- offer [a]
         r <- offer [c]
         always$ p ~> 1 & q ~> 0 & r ~> 0
     , testD "Three channels, one guy offering three pairs, three single offerers" $ do
         [a, b, c] <- replicateM 3 $ evt 2
         p <- offer [a&b, b&c, a&c]
         q <- offer [a]
         r <- offer [b]
         s <- offer [c]
         [p] ==> (p ~> 0 & q ~> 0 & r ~> 0)
                 `or` (p ~> 1 & r ~> 0 & s ~> 0)
                 `or` (p ~> 2 & q ~> 0 & s ~> 0)
     , testD "Four channels, one guy offering sets of three, three single offerers" $ do
         [a, b, c,d ] <- replicateM 4 $ evt 2
         p <- offer [a&b&c, a&b&d, a&b&c, b&c&d]
         q <- offer [b]
         r <- offer [c]
         s <- offer [d]
         always$ p ~> 3 & q ~> 0 & r ~> 0 & s ~> 0
     , testD "Four channels, one guy offering sets of three, two single offerers" $ do
         [a, b, c,d ] <- replicateM 4 $ evt 2
         p <- offer [a&b&c, a&b&d, a&b&c, b&c&d]
         q <- offer [b]
         r <- offer [c]
         always$ none
     , testD "Four channels, one guy offering sets of three, one single offerer and one double" $ do
         [a, b, c,d ] <- replicateM 4 $ evt 2
         p <- offer [a&b&c, a&b&d, a&b&c, b&c&d]
         q <- offer [b&c]
         r <- offer [d]
         always$ p ~> 3 & q ~> 0 & r ~> 0
     , testD "Four channels, one guy offering sets of three, one single offerer and one on two" $ do
         [a, b, c,d ] <- replicateM 4 $ evt 2
         p <- offer [a&b&c, a&b&d, a&b&c, b&c&d]
         q <- offer [b, c]
         r <- offer [d]
         always$ none
     , testD "Links 1" $ do
         [a, b, c, d] <- replicateM 4 $ evt 2
         p <- offer [a&b]
         q <- offer [b&c&d]
         r <- offer [c, d]
         always$ none
     , testD "Links 2" $ do
         [a, b, c, d, e] <- replicateM 5 $ evt 2
         p <- offer [b]
         q <- offer [b&c&d&e]
         r <- offer [c, d]
         s <- offer [e]
         always$ none
     , testD "Links 3" $ do
         [a, b, c, d, e] <- replicateM 5 $ evt 2
         p <- offer [b]
         q <- offer [b&c&d&e]
         r <- offer [c&a, d&a]
         s <- offer [e]
         t <- offer [a]
         always$ none
     , testD "Ring 1" $ do
         [a, b, c, d] <- replicateM 4 $ evt 2
         p <- offer [a&b]
         q <- offer [b&c]
         r <- offer [c&d]
         s <- offer [d&a]
         always$ foldl1 (&) $ map (~> 0) [p, q, r, s]
     , testD "Ring 2" $ do
         [a, b, c, d] <- replicateM 4 $ evt 2
         p <- offer [a&b]
         q <- offer [b&c]
         r <- offer [c,d]
         s <- offer [d&a]
         always$ none
     , testD "Ring 3" $ do
         [a, a', b, c, d] <- replicateM 5 $ evt 2
         p <- offer [a&b, a']
         q <- offer [b&c]
         r <- offer [c&d]
         s <- offer [d&a']
         always$ none
     , testD "Pipeline 1" $ do
         [a,b,c,d,e,f] <- replicateM 6 $ evt 2
         p <- offer [a, b]
         q <- offer [a & c, b & c, b & d]
         r <- offer [d & e, d & f, c & e]
         s <- offer [f]
         always$ p ~> 1 & q ~> 2 & r ~> 1 & s ~> 0

       -- test resolutions with poison:
       --
     , test' "One event, poisoned" True
         ([PoisonItem], [[Left [(0,0)]]])
         [[[0]]]
     , test' "Two events, one poisoned" True
         ([PoisonItem, NoPoison $ EventInfo 2 0], [[Left [(0,0)], Left [(0,0)]]])
         [[[0,1]]]
     ]
  where
    testD testName = TestList . map (uncurry (test' testName False)) . runDSL

    test testName eventCounts offerSets = test' testName False (second (:[]) $
      unzip eventCounts) offerSets
    
    test' :: String -> Bool {-Poisoned-} -> 
      -- List of events:
      ([WithPoison EventInfo] {- enrolled count -}
      ,[[Either [(Int, Int)] {- success: expected process, offer indexes -}
               [Int] {- remaining offers -}
       ] {- a single possibility, as long as the list of enroll counts -}
       ] {- the list of possibilities -}) ->
      {- Offers: -} [[[Int] {- events -}]] -> Test

    test' testName poisoned eventCounts offerSets = TestLabel testName $ TestCase $ do
           tv <- atomically $ newTVar Map.empty
           let add x = readTVar tv >>= (writeTVar tv . Map.insertWith (+) x 1)
               offerSets' = [ [ (offer, add (i, j))
                              | offer <- offerSet | j <- [0..]]
                            | offerSet <- offerSets | i <- [0..]]
           (events, realOffers) <- makeTestEvents (fst eventCounts) offerSets'

           actualResult <- liftM (liftM (fmap snd)) $ atomically $ discoverAndResolve $ Left $ last realOffers

           actionResult <- atomically $ readTVar tv

           let combinedActual = (,) actionResult <$> actualResult

           let expectedResults = if poisoned then [PoisonItem] else map NoPoison $
                                [(Map.fromList $ zip (nub $ concat [x | Left x <- poss]) (repeat 1)
                                 ,Map.fromList [ (getEventUnique e,
                                                  Set.fromList $ map (testProcessId . (*1000) . fst) is)
                                               | (e, Left is) <- zip events poss]
                                 )
                                | poss <- snd eventCounts]
           when (combinedActual `notElem` expectedResults) $
             assertFailure $ testName ++ " failed on direct result/actions, expected one of: ["
               ++ intercalate "," (map showStuff expectedResults) ++ "] got: " ++ showStuff combinedActual
                ++ " (params: " ++ show offerSets ++ ")"

           vals <- mapM (atomically . readTVar . signalVar) realOffers
           let
             expAct = [
               [(unzip [(fst <$> (vals !! pn)
                        ,Just $ (if poisoned then addPoison else id)
                                (Signal $ NoPoison ((pn*1000)+en)))
                       | (pn, en) <- exp]
                , map fst exp)
               | Left exp <- poss]
              | poss <- snd eventCounts]
           (poss, allFired) <- case findIndex (all (uncurry (==) . fst)) expAct of
             Nothing -> do assertFailure $ testName ++ "No possible firing outcomes matched"
                           return $ error $ testName ++ "No possible firing outcomes matched"
             Just n -> return (snd eventCounts !! n, concatMap snd (expAct !! n))

           -- test the others are unchanged
           sequence_ [ let tv = signalVar $ realOffers !! n in
                         do x <- atomically $ readTVar tv
                            case x of
                              Nothing -> return ()
                              Just _ -> assertFailure $ testName ++ " Unexpected win for process: " ++
                                show n
                     | n <- [0 .. length offerSets - 1] \\ allFired]
           -- check events are blanked afterwards:
           c <- sequence
                     [ let e = events !! n
                           expVal = case st of
                             Left _ -> []
                             Right ns -> map (realOffers !!) ns
                       in do
                         x <- atomically $ readTVar $ getEventTVar e
                         case x of
                           NoPoison (c, _, e') -> return $ Just ((count, sort expVal), (EventInfo c (getEventPriority e), sort e'))
                           _ -> do assertFailure $ testName ++ " unexpected poison"
                                   return Nothing
{-                           NoPoison (c, _, e') | c == count && e' == expVal -> return ()
                           _ ->
                             assertFailure $ testName ++ "Event " ++ show n ++
                             " not as expected after, exp: " ++ show (length expVal)
                             ++ " act: " ++ (let NoPoison (_,_,act) = x in show (length act))-}
                     | (n, NoPoison count, st) <- zip3 [0..] (fst eventCounts) poss]
           uncurry (assertEqual (testName ++ " not blanked " ++ show eventCounts
             ++ show offerSets)) (unzip $ catMaybes c)

    showStuff :: WithPoison (Map.Map (Int, Int) Int, Map.Map Unique (Set.Set ProcessId)) -> String
    showStuff = show . fmap (Map.toList *** (map (first hashUnique) . Map.toList))

#endif
-- CHP_TEST

