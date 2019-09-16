{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE OverloadedLabels #-}

module Streamly.Extra where

import Control.Arrow
import Control.Concurrent hiding (yield)
import Control.Monad
import Control.Monad.IO.Class
import Data.IORef
import Data.Map.Strict (Map)
import qualified Control.Concurrent.STM.TChan as TChan
import qualified Control.Monad.STM as STM
import qualified Data.Internal.SortedSet as ZSet
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Streamly as S
import qualified Streamly.Fold as FL
import qualified Streamly.Internal as SI
import qualified Streamly.Prelude as SP
import Streamly.Internal

-- | Group the stream into a smaller set of keys and fold elements of a specific key
demuxByM
  :: Eq b
  => Ord b
  => Monad m
  => (a -> m b)
  -> FL.Fold m a c
  -> FL.Fold m a [(b, c)]
demuxByM f (Fold step' begin' done')
  = Fold step begin done
  where
    begin = pure mempty
    step hm a = do
      b <- f a
      (\c -> Map.insert b c hm) <$>
        (maybe begin' pure (Map.lookup b hm) >>= flip step' a)
    done = fmap Map.toList <<< mapM done'

demuxAndAggregateByInterval
  :: Eq b
  => Ord b
  => S.MonadAsync m
  => S.IsStream t
  => (a -> m b)
  -> Double
  -> FL.Fold m a c
  -> t m a
  -> t m [(b, c)]
demuxAndAggregateByInterval f delay agg =
  FL.sessionsOf delay (demuxByM f agg)

demuxAndAggregateInChunks
  :: Eq b
  => Ord b
  => S.MonadAsync m
  => S.IsStream t
  => (a -> m b)
  -> Int
  -> FL.Fold m a c
  -> t m a
  -> t m [(b, c)]
demuxAndAggregateInChunks f chunkSize agg =
  FL.chunksOf chunkSize (demuxByM f agg)

demuxByAndAggregateInChunksOf
  :: Eq b
  => Ord b
  => Show b
  => S.MonadAsync m
  => (a -> m b)
  -> Int
  -> FL.Fold m a c
  -> S.SerialT m a
  -> S.SerialT m (b, c)
demuxByAndAggregateInChunksOf f i (Fold step' begin' done') src
  = SP.mapMaybe id $ FL.scanl' (Fold step begin done) src
  where
  begin = pure (mempty, Nothing)
  step (hm, _) a = do
    b <- f a
    (j, x) <- maybe ((1, ) <$> begin') pure (Map.lookup b hm)
    (\x' -> if j < i
      then (Map.insert b (j+1, x') hm, Nothing)
      else (Map.delete b hm, Just (b, x'))) <$> step' x a
  done (_, Just (b, x')) = Just . (b, ) <$> done' x'
  done _ = pure Nothing

-- | Collects elements from the stream into a key given by the `keyFn`
--   Once the stream for that key is completed or on a configurable timeout, it is available on the output stream.
collectTillEndOrTimeout
  :: Eq b
  => S.MonadAsync m
  => Ord b
  => (a -> b)
  -> ([a] -> Bool)
  -> Int
  -> S.SerialT m a
  -> S.SerialT m (Maybe [a])
collectTillEndOrTimeout keyFn isEnd timeout src =
  liftIO TChan.newTChanIO >>= \chan ->
    completedSessionStream chan `S.parallel` incompletedSessionsStream chan
  where
    completedSessionStream c =
      FL.scanl'
        (Fold
          -- State is (IORef (HM b (ThreadId, [a])), IORef (Maybe [a]))
          -- First HM is a IORef because it should be modifiable by another thread
          -- Second is a IORef because every time an extract is called, it has to be cleared
          (\(hmRef, outRef) a -> liftIO $ do
            let b = keyFn a
            mTIdAndLogs <- Map.lookup b <$> readIORef hmRef
            case mTIdAndLogs of
              Nothing ->
                if isEnd [a]
                then
                  (hmRef, outRef) <$ atomicWriteIORef outRef (Just [a])
                else do
                  tId <- liftIO $
                    forkIO $
                      threadDelay (timeout * 1000000)
                      *> atomicModifyIORef' hmRef (\hm -> (Map.delete b hm, snd <$> Map.lookup b hm))
                        >>= STM.atomically . TChan.writeTChan c
                  atomicModifyIORef' hmRef (\hm -> (Map.insert b (tId, [a]) hm, ()))
                  atomicWriteIORef outRef Nothing
                  pure (hmRef, outRef)
              Just (tId, as) ->
                let as' = a : as
                in (hmRef, outRef) <$
                  if isEnd as'
                    then
                      killThread tId
                      *> atomicWriteIORef outRef (Just as')
                      *> atomicModifyIORef' hmRef (\hm -> (Map.delete b hm, ()))
                    else
                      atomicWriteIORef outRef Nothing
                      *> atomicModifyIORef' hmRef (\hm -> (Map.insert b (tId, as') hm, ()))
          )
          ((,) <$> liftIO (newIORef mempty) <*> liftIO (newIORef mempty))
          (\(_, outRef) -> liftIO $ atomicModifyIORef' outRef (\mAs -> (Nothing, mAs))))
        src
    incompletedSessionsStream c = SP.repeatM (liftIO $ STM.atomically $ TChan.readTChan c)

duplicate
  :: MonadIO m
  => S.SerialT IO a
  -> m (S.SerialT IO a, S.SerialT IO a)
duplicate src =
  liftIO $ do
    chan <- TChan.newBroadcastTChanIO
    chan' <- STM.atomically $ TChan.dupTChan chan
    chan'' <- STM.atomically $ TChan.dupTChan chan
    forkIO $
      SP.mapM_ (STM.atomically . TChan.writeTChan chan) src
    pure (S.maxBuffer (-1) (SP.repeatM (STM.atomically $ TChan.readTChan chan')), S.maxBuffer (-1) (SP.repeatM (STM.atomically $ TChan.readTChan chan'')))

threeWaySplit
  :: MonadIO m
  => S.SerialT IO a
  -> m (S.SerialT IO a, S.SerialT IO a, S.SerialT IO a)
threeWaySplit =
  duplicate
  >=> (\(c1, c2) -> (\t -> (c1,fst t, snd t)) <$> duplicate c2)

tap
  :: S.MonadAsync m
  => S.IsStream t
  => t m a
  -> (a -> m b)
  -> t m a
tap s f = SP.mapM (\x -> x <$ f x) s

(|>>)
  :: S.MonadAsync m
  => S.IsStream t
  => t m a
  -> (a -> m b)
  -> t m a
(|>>) = tap

infixl 5 |>>

firstOcc
  :: Ord a
  => Monad m
  => S.SerialT m a
  -> S.SerialT m a
firstOcc =
  SP.mapMaybe id
  .  FL.scanl' (Fold step begin end)
  where
  step (x, _) a =
    pure (Set.insert a x, if Set.member a x then Nothing else Just a)
  begin =
    pure (Set.empty, Nothing)
  end = snd >>> pure

runAllWith
  :: (forall c. S.SerialT IO c -> S.SerialT IO c -> S.SerialT IO c)
  -> [ S.SerialT IO a -> S.SerialT IO () ]
  -> S.SerialT IO a
  -> S.SerialT IO ()
runAllWith _ [] _ = pure ()
runAllWith run (f:fs) src = do
  (s1, s2) <- liftIO $ duplicate src
  run (f s1) (runAllWith run fs s2)

-- | Stream which samples from the latest value from the first stream at times when the second stream yields
--   Note : Doesn't produce values until one value is yield'ed from each stream
--   everyNSecsIncBy n i =
--     SP.iterateM (\j -> threadDelay (n * 1000000) >> pure (i + j)) (pure 0)
--   everyNSecondsAddOrSub n =
--     snd <$>
--       SP.iterateM
--         (\(b, _) -> threadDelay (n * 1000000) >> pure (if b then (False, (\x -> (x,2+x))) else (True, (\x -> (x,x-2)) )))
--         (pure (True, (\x -> (x,x-2)) ))
--   SP.mapM_ print $ sampleOn (everyNSecsIncBy 1 2) (everyNSecondsAddOrSub 4)
--   outputs :
--   (0,-2)
--   (6,8)
--   (14,12)
--   (22,24)
--   (30,28)
--   (38,40)
--   (46,44)
--   (54,56)
--   (62,60)
sampleOn
  :: S.MonadAsync m
  => S.SerialT m a
  -> S.SerialT m (a -> b)
  -> S.SerialT m b
sampleOn src pulse =
  SP.mapMaybe id $
    FL.scanl' fld combined
  where
  combined =
    S.serially $ (Left <$> src) `S.async` (Right <$> pulse)
  fld = Fold step begin done
  -- First is the latest value of source,
  -- second is the value which to be yield'ed
  step _ (Left a) = pure (Just a, Nothing)
  step (x, _) (Right f) = pure (x, f <$> x)
  begin = pure (Nothing, Nothing)
  done (_, out) = pure out

applyWithLatestM
  :: S.MonadAsync m
  => (a -> b -> m c)
  -> S.SerialT m a
  -> S.SerialT m b
  -> S.SerialT m c
applyWithLatestM f s1 s2 =
  SP.mapMaybe id $
    FL.scanl' fld combined
  where
  combined =
    S.serially $ (Left <$> s1) `S.async` (Right <$> s2)
  fld = Fold step begin done
  begin = pure (Nothing, Nothing)
  step (Just b, _) (Left a) = (Just b,) . Just <$> f a b
  step (Nothing, _) (Left a) = pure (Nothing, Nothing)
  step _ (Right b) = pure (Just b, Nothing)
  done (_, out) = pure out
-- | Stream which produces values as fast as the faster stream(the first argument)
--   using the latest value from the slower stream(the second argument)
--   Note : Doesn't produce values until one value is yield'ed from each stream
--   everyNSecsIncBy n i =
--     SP.iterateM
--       (\j -> threadDelay (n * 1000000) >> pure (i + j))
--       (pure 0)
--   everyNSecondsAddOrSub n =
--     snd <$>
--       SP.iterateM
--         (\(b, _) -> threadDelay (n * 1000000) >> pure (if b then (False, (\x -> (x,2+x))) else (True, (\x -> (x,x-2)) )))
--         (pure (True, (\x -> (x,x-2)) ))
--   SP.mapM_ print $ applyWithLatest (everyNSecsIncBy 1 2) (everyNSecondsAddOrSub 4)
--   outputs :
--   (2,0)
--   (4,2)
--   (6,4)
--   (8,10)
--   (10,12)
--   (12,14)
--   (14,16)
--   (16,14)
--   (18,16)
--   (20,18)
--   (22,20)
--   (24,26)
--   (26,28)
--   (28,30)
--   (30,32)
--   (32,30)
applyWithLatest
  :: S.MonadAsync m
  => S.SerialT m a
  -> S.SerialT m (a -> b)
  -> S.SerialT m b
applyWithLatest src pulse =
  SP.mapMaybe id $
    FL.scanl' fld combined
  where
  combined =
    S.serially $ (Left <$> src) `S.async` (Right <$> pulse)
  fld = Fold step begin done
  -- First is the latest value of pulse,
  -- second is the value which to be yield'ed
  begin = pure (Nothing, Nothing)
  step (Just f, _) (Left a) = pure (Just f, Just (f a))
  step (Nothing, _) (Left _) = pure (Nothing, Nothing)
  step _ (Right f') = pure (Just f', Nothing)
  done (_, out) = pure out


-- | Stream which races a function stream and a argument stream
--   and uses the latest value of the other stream whenever any of the stream yields a value
--   Note : Doesn't produce values until one value is yield'ed from each stream
--   everyNSecsIncBy n i =
--     SP.iterateM
--       (\j -> threadDelay (n * 1000000) >> pure (i + j))
--       (pure 0)
--   everyNSecondsAddOrSub n =
--     snd <$>
--       SP.iterateM
--         (\(b, _) -> threadDelay (n * 1000000) >> pure (if b then (False, (\x -> (x,2+x))) else (True, (\x -> (x,x-2)) )))
--         (pure (True, (\x -> (x,x-2)) ))
--   SP.mapM_ print $ zipAsyncly' (everyNSecsIncBy 4 2)  (everyNSecondsAddOrSub 1)
--   outputs :
--   (0,-2)
--   (0,2)
--   (0,-2)
--   (0,2)
--   (2,4)
--   (2,0)
--   (2,4)
--   (2,0)
--   (2,4)
--   (4,6)
--   (4,2)
--   (4,6)
--   (4,2)
--   (4,6)
--   (6,8)
--   (6,4)
--   (6,8)
--   (6,4)
--   (6,8)
--   (8,10)
--   (8,6)
--   (8,10)
--   SP.mapM_ print $ zipAsyncly' (everyNSecsIncBy 1 2)  (everyNSecondsAddOrSub 4)
--   (0,-2)
--   (2,0)
--   (4,2)
--   (6,4)
--   (6,8)
--   (8,10)
--   (10,12)
--   (12,14)
--   (14,16)
--   (14,12)
--   (16,14)
--   (18,16)
--   (20,18)
--   (22,20)
--   (22,24)
--   (24,26)
--   (26,28)
--   (28,30)
--   (30,32)
zipAsyncly'
  :: S.MonadAsync m
  => S.SerialT m a
  -> S.SerialT m (a -> b)
  -> S.SerialT m b
zipAsyncly' aSrc fSrc =
  SP.mapMaybe id $
    FL.scanl' fld combined
  where
  combined =
    S.serially $ (Left <$> aSrc) `S.async` (Right <$> fSrc)
  fld = Fold step begin done
  -- First is the latest value of a -> b,
  -- Second is the latest value of a,
  -- Third is the value which to be yield'ed
  begin = pure (Nothing, Nothing, Nothing)
  step (maybeF, _, _) (Left a) =
    pure $
      maybe
        (Nothing, Just a, Nothing)
        (\f -> (Just f, Just a, Just (f a)))
        maybeF
  step (_, maybeA, _) (Right f) =
    pure $
      maybe
        (Just f, Nothing, Nothing)
        (\a -> (Just f, Just a, Just (f a)))
        maybeA
  done (_, _, out) = pure out

-- | Group incoming elements into buckets of @tickInterval × timeThreshold@
--   microseconds and output only the first occurrence of each element.
--   This will yield "1" every five seconds:
--   >>> num1Every1MilliSec = SP.repeatM (threadDelay 1000 *> pure 1)
--   >>> SP.mapM_ print $ firstOccWithin 1000000 5 num1Every1MilliSec
--   New elements will be yielded only once per @tickInterval@, so choose it
--   depending on the needed granularity.
firstOccWithin
  :: Ord a
  => S.MonadAsync m
  => Int
  -> Int
  -> S.SerialT m a
  -> S.SerialT m a
firstOccWithin tickInterval timeThreshold src
  =
  SP.mapMaybe id $
    FL.scanl'
      (Fold step begin end)
      srcWithTicker
  where
  step (x, _) (a, (up, down)) =
    pure (if ZSet.zMember a newX then (newX, Nothing) else (ZSet.zAdd a up newX, Just a))
    where
      newX = if down == 0 then ZSet.zRangeGTByScore (up - timeThreshold) x else x
  begin =
    pure (ZSet.zempty, Nothing)
  end = pure . snd

  ticker =
    SP.mapM (<$ liftIO (threadDelay tickInterval)) $
    SP.fromFoldable $
    zip [0..] (cycle [timeThreshold, timeThreshold - 1 .. 0])

  srcWithTicker =
    src `applyWithLatest` ((\i a -> (a, i)) <$> ticker)

groupConsecutiveBy
  :: Eq b
  => Monad m
  => (a -> b)
  -> FL.Fold m (Maybe a) (Maybe [a])
groupConsecutiveBy f = SI.Fold step begin end
  where
  -- State is a tuple of 3 elements
  -- First is the optional Last Id we have seen.
  -- Second is the accumulated a's for the identifier represented by the first element
  -- Third is a Maybe [a], if Just xs then it is a completed set of a's
  -- Else if Nothing, it means that the set of a's seen till now is not completed
  begin = pure (Nothing, [], Nothing)
  end (_, _, maybeXS) = pure maybeXS
  step (Just oldId, oldXS, _) (Just newElem)
    | oldId == f newElem = pure (Just oldId, newElem : oldXS, Nothing)
    | otherwise = pure (Just (f newElem), [newElem], Just oldXS)
  step (Just _, oldXS, _) Nothing = pure (Nothing, [], Just oldXS)
  step (Nothing, _, _) maybeNewElem =
    maybe
      (pure (Nothing, [], Nothing))
      (\newElem -> pure (Just (f newElem), [newElem], Nothing))
      maybeNewElem

counts
  :: Applicative m
  => Ord a
  => FL.Fold m a (Map a Int)
counts = SI.Fold step begin end
  where
  step x a =
    pure $ Map.alter (Just . maybe 1 (+1)) a x
  begin = pure mempty
  end = pure
