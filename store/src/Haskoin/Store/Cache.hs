{-# LANGUAGE ApplicativeDo     #-}
{-# LANGUAGE DeriveAnyClass    #-}
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE MultiWayIf        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE TupleSections     #-}
module Haskoin.Store.Cache
    ( CacheConfig(..)
    , CacheMetrics
    , CacheT
    , CacheError(..)
    , newCacheMetrics
    , withCache
    , connectRedis
    , blockRefScore
    , scoreBlockRef
    , CacheWriter
    , CacheWriterInbox
    , cacheNewBlock
    , cacheWriter
    , isInCache
    ) where

import           Control.DeepSeq             (NFData)
import           Control.Monad               (forM, forM_, forever, guard,
                                              unless, void, when)
import           Control.Monad.Logger        (MonadLoggerIO, logDebugS,
                                              logErrorS, logInfoS, logWarnS)
import           Control.Monad.Reader        (ReaderT (..), ask, asks)
import           Control.Monad.Trans         (lift)
import           Control.Monad.Trans.Maybe   (MaybeT (..), runMaybeT)
import           Data.Bits                   (complement, shift, (.&.), (.|.))
import           Data.ByteString             (ByteString)
import qualified Data.ByteString             as B
import           Data.Default                (def)
import           Data.Either                 (fromRight, isRight, rights)
import           Data.HashMap.Strict         (HashMap)
import qualified Data.HashMap.Strict         as HashMap
import           Data.HashSet                (HashSet)
import qualified Data.HashSet                as HashSet
import qualified Data.IntMap.Strict          as I
import           Data.List                   (sort)
import qualified Data.Map.Strict             as Map
import           Data.Maybe                  (catMaybes, fromMaybe, isNothing,
                                              mapMaybe)
import           Data.Serialize              (Serialize, decode, encode)
import           Data.String.Conversions     (cs)
import           Data.Text                   (Text)
import           Data.Time.Clock             (NominalDiffTime, diffUTCTime)
import           Data.Time.Clock.System      (getSystemTime, systemSeconds,
                                              systemToUTCTime)
import           Data.Word                   (Word32, Word64)
import           Database.Redis              (Connection, Redis, RedisCtx,
                                              Reply, checkedConnect,
                                              defaultConnectInfo, hgetall,
                                              parseConnectInfo, zadd,
                                              zrangeWithscores,
                                              zrangebyscoreWithscoresLimit,
                                              zrem)
import qualified Database.Redis              as Redis
import           GHC.Generics                (Generic)
import           Haskoin                     (Address, BlockHash,
                                              BlockHeader (..), BlockNode (..),
                                              DerivPathI (..), KeyIndex,
                                              OutPoint (..), Tx (..), TxHash,
                                              TxIn (..), TxOut (..), XPubKey,
                                              blockHashToHex, derivePubPath,
                                              eitherToMaybe, headerHash,
                                              pathToList, scriptToAddressBS,
                                              txHash, xPubAddr,
                                              xPubCompatWitnessAddr, xPubExport,
                                              xPubWitnessAddr)
import           Haskoin.Node                (Chain, chainBlockMain,
                                              chainGetAncestor, chainGetBest,
                                              chainGetBlock)
import           Haskoin.Store.Common
import           Haskoin.Store.Data
import           Haskoin.Store.Stats
import           NQE                         (Inbox, Listen, Mailbox,
                                              inboxToMailbox, query, receive,
                                              send)
import qualified System.Metrics              as Metrics
import qualified System.Metrics.Counter      as Metrics (Counter)
import qualified System.Metrics.Counter      as Metrics.Counter
import qualified System.Metrics.Distribution as Metrics (Distribution)
import qualified System.Metrics.Distribution as Metrics.Distribution
import qualified System.Metrics.Gauge        as Metrics (Gauge)
import qualified System.Metrics.Gauge        as Metrics.Gauge
import           System.Random               (randomIO, randomRIO)
import           UnliftIO                    (Exception, MonadIO, MonadUnliftIO,
                                              TQueue, TVar, async, atomically,
                                              bracket, liftIO, link, modifyTVar,
                                              newTVarIO, readTQueue, readTVar,
                                              throwIO, wait, withAsync,
                                              writeTQueue, writeTVar)
import           UnliftIO.Concurrent         (threadDelay)

runRedis :: MonadLoggerIO m => Redis (Either Reply a) -> CacheX m a
runRedis action =
    asks cacheConn >>= \conn ->
    liftIO (Redis.runRedis conn action) >>= \case
        Right x -> return x
        Left e -> do
            $(logErrorS) "Cache" $ "Got error from Redis: " <> cs (show e)
            throwIO (RedisError e)

data CacheConfig = CacheConfig
    { cacheConn       :: !Connection
    , cacheMin        :: !Int
    , cacheMax        :: !Integer
    , cacheChain      :: !Chain
    , cacheRefresh    :: !Int -- millisenconds
    , cacheRetryDelay :: !Int -- microseconds
    , cacheMetrics    :: !(Maybe CacheMetrics)
    }

data CacheMetrics = CacheMetrics
    { cacheHits            :: !Metrics.Counter
    , cacheMisses          :: !Metrics.Counter
    , cacheIgnore          :: !Metrics.Counter
    , cacheRefreshes       :: !Metrics.Counter
    , cacheLockAcquired    :: !Metrics.Counter
    , cacheLockReleased    :: !Metrics.Counter
    , cacheLockFailed      :: !Metrics.Counter
    , cacheIndexTime       :: !StatDist
    , cacheMempoolSyncTime :: !StatDist
    , cacheBlockSyncTime   :: !StatDist
    }

newCacheMetrics :: MonadIO m => Metrics.Store -> m CacheMetrics
newCacheMetrics s = liftIO $ do
    cacheHits            <- c "hits"
    cacheMisses          <- c "misses"
    cacheIgnore          <- c "ignore"
    cacheRefreshes       <- c "refreshes"
    cacheLockAcquired    <- c "lock_acquired"
    cacheLockReleased    <- c "lock_released"
    cacheLockFailed      <- c "lock_failed"
    cacheIndexTime       <- d "index"
    cacheMempoolSyncTime <- d "mempool_sync"
    cacheBlockSyncTime   <- d "block_sync"
    return CacheMetrics{..}
  where
    c x = Metrics.createCounter ("cache." <> x) s
    d x = createStatDist        ("cache." <> x) s

withMetrics :: MonadUnliftIO m
            => (CacheMetrics -> StatDist)
            -> CacheX m a
            -> CacheX m a
withMetrics df go =
    asks cacheMetrics >>= \case
        Nothing -> go
        Just m ->
            bracket
            (systemToUTCTime <$> liftIO getSystemTime)
            (end m)
            (const go)
  where
    end metrics t1 = do
        t2 <- systemToUTCTime <$> liftIO getSystemTime
        let diff = round $ diffUTCTime t2 t1 * 1000
        df metrics `addStatTime` diff
        df metrics `addStatItems` 1
        addStatQuery (df metrics)

incrementCounter :: MonadIO m
                 => (CacheMetrics -> Metrics.Counter)
                 -> CacheX m ()
incrementCounter cf =
    asks cacheMetrics >>= \case
        Nothing -> return ()
        Just m  -> liftIO $ Metrics.Counter.inc (cf m)

type CacheT = ReaderT (Maybe CacheConfig)
type CacheX = ReaderT CacheConfig

data CacheError = RedisError Reply
    | RedisTxError !String
    | LogicError !String
    deriving (Show, Eq, Generic, NFData, Exception)

connectRedis :: MonadIO m => String -> m Connection
connectRedis redisurl = do
    conninfo <-
        if null redisurl
            then return defaultConnectInfo
            else case parseConnectInfo redisurl of
                     Left e  -> error e
                     Right r -> return r
    liftIO (checkedConnect conninfo)

instance (MonadUnliftIO m, MonadLoggerIO m, StoreReadBase m) =>
         StoreReadBase (CacheT m) where
    getNetwork = lift getNetwork
    getBestBlock = lift getBestBlock
    getBlocksAtHeight = lift . getBlocksAtHeight
    getBlock = lift . getBlock
    getTxData = lift . getTxData
    getSpender = lift . getSpender
    getBalance = lift . getBalance
    getUnspent = lift . getUnspent
    getMempool = lift getMempool

instance (MonadUnliftIO m , MonadLoggerIO m, StoreReadExtra m) =>
         StoreReadExtra (CacheT m) where
    getBalances = lift . getBalances
    getAddressesTxs addrs = lift . getAddressesTxs addrs
    getAddressTxs addr = lift . getAddressTxs addr
    getAddressUnspents addr = lift . getAddressUnspents addr
    getAddressesUnspents addrs = lift . getAddressesUnspents addrs
    getMaxGap = lift getMaxGap
    getInitialGap = lift getInitialGap
    getNumTxData = lift . getNumTxData
    xPubBals xpub =
        ask >>= \case
            Nothing  -> lift $
                xPubBals xpub
            Just cfg -> lift $
                runReaderT (getXPubBalances xpub) cfg
    xPubUnspents xpub xbals limits =
        ask >>= \case
            Nothing  -> lift $
                xPubUnspents xpub xbals limits
            Just cfg -> lift $
                runReaderT (getXPubUnspents xpub xbals limits) cfg
    xPubTxs xpub xbals limits =
        ask >>= \case
            Nothing  -> lift $
                xPubTxs xpub xbals limits
            Just cfg -> lift $
                runReaderT (getXPubTxs xpub xbals limits) cfg
    xPubTxCount xpub xbals =
        ask >>= \case
            Nothing  -> lift $
                xPubTxCount xpub xbals
            Just cfg -> lift $
                runReaderT (getXPubTxCount xpub xbals) cfg

withCache :: StoreReadBase m => Maybe CacheConfig -> CacheT m a -> m a
withCache s f = runReaderT f s

balancesPfx :: ByteString
balancesPfx = "b"

txSetPfx :: ByteString
txSetPfx = "t"

utxoPfx :: ByteString
utxoPfx = "u"

idxPfx :: ByteString
idxPfx = "i"

getXPubTxs ::
       (MonadUnliftIO m, MonadLoggerIO m, StoreReadExtra m)
    => XPubSpec -> [XPubBal] -> Limits -> CacheX m [TxRef]
getXPubTxs xpub xbals limits = go False
  where
    go m = isXPubCached xpub >>= \case
        True -> do
            unless m $ incrementCounter cacheHits
            cacheGetXPubTxs xpub limits
        False ->
            case m of
                True -> lift $ xPubTxs xpub xbals limits
                False -> do
                    newXPubC xpub xbals
                    go True

getXPubTxCount :: (MonadUnliftIO m, MonadLoggerIO m, StoreReadExtra m)
               => XPubSpec -> [XPubBal] -> CacheX m Word32
getXPubTxCount xpub xbals =
    go False
  where
    go t = isXPubCached xpub >>= \case
        True -> do
            unless t $ incrementCounter cacheHits
            cacheGetXPubTxCount xpub
        False ->
            if t
            then lift $ xPubTxCount xpub xbals
            else do
                newXPubC xpub xbals
                go True

getXPubUnspents :: (MonadUnliftIO m, MonadLoggerIO m, StoreReadExtra m)
                => XPubSpec -> [XPubBal] -> Limits -> CacheX m [XPubUnspent]
getXPubUnspents xpub xbals limits =
    go False
  where
    xm = let f x = (balanceAddress (xPubBal x), x)
             g = (> 0) . balanceUnspentCount . xPubBal
         in HashMap.fromList $ map f $ filter g xbals
    go m = isXPubCached xpub >>= \case
        True -> do
            unless m $ incrementCounter cacheHits
            process
        False -> case m of
            True ->
                lift $ xPubUnspents xpub xbals limits
            False -> do
                newXPubC xpub xbals
                go True
    process = do
        ops <- map snd <$> cacheGetXPubUnspents xpub limits
        uns <- catMaybes <$> lift (mapM getUnspent ops)
        let f u = either
                  (const Nothing)
                  (\a -> Just (a, u))
                  (scriptToAddressBS (unspentScript u))
            g a = HashMap.lookup a xm
            h u x =
                XPubUnspent
                {
                    xPubUnspent = u,
                    xPubUnspentPath = xPubBalPath x
                }
            us = mapMaybe f uns
            i a u = h u <$> g a
        return $ mapMaybe (uncurry i) us

getXPubBalances :: (MonadUnliftIO m, MonadLoggerIO m, StoreReadExtra m)
                => XPubSpec -> CacheX m [XPubBal]
getXPubBalances xpub = isXPubCached xpub >>= \case
    True -> do
        incrementCounter cacheHits
        cacheGetXPubBalances xpub
    False -> do
        bals <- lift $ xPubBals xpub
        newXPubC xpub bals
        return bals

isInCache :: MonadLoggerIO m => XPubSpec -> CacheT m Bool
isInCache xpub =
    ask >>= \case
    Nothing  -> return False
    Just cfg -> runReaderT (isXPubCached xpub) cfg

isXPubCached :: MonadLoggerIO m => XPubSpec -> CacheX m Bool
isXPubCached = runRedis . redisIsXPubCached

redisIsXPubCached :: RedisCtx m f => XPubSpec -> m (f Bool)
redisIsXPubCached xpub = Redis.exists (balancesPfx <> encode xpub)

cacheGetXPubBalances :: MonadLoggerIO m => XPubSpec -> CacheX m [XPubBal]
cacheGetXPubBalances xpub = do
    bals <- runRedis $ redisGetXPubBalances xpub
    touchKeys [xpub]
    return bals

cacheGetXPubTxCount :: (MonadUnliftIO m, MonadLoggerIO m, StoreReadExtra m)
                    => XPubSpec -> CacheX m Word32
cacheGetXPubTxCount xpub = do
    count <- fromInteger <$> runRedis (redisGetXPubTxCount xpub)
    touchKeys [xpub]
    return count

redisGetXPubTxCount :: RedisCtx m f => XPubSpec -> m (f Integer)
redisGetXPubTxCount xpub = Redis.zcard (txSetPfx <> encode xpub)

cacheGetXPubTxs ::
       (StoreReadBase m, MonadLoggerIO m)
    => XPubSpec
    -> Limits
    -> CacheX m [TxRef]
cacheGetXPubTxs xpub limits =
    case start limits of
        Nothing ->
            go1 Nothing
        Just (AtTx th) -> lift (getTxData th) >>= \case
            Just TxData {txDataBlock = b@BlockRef{}} ->
                go1 $ Just (blockRefScore b)
            _ ->
                go2 th
        Just (AtBlock h) ->
            go1 (Just (blockRefScore (BlockRef h maxBound)))
  where
    go1 score = do
        xs <- runRedis $
            getFromSortedSet
                (txSetPfx <> encode xpub)
                score
                (offset limits)
                (limit limits)
        touchKeys [xpub]
        return $ map (uncurry f) xs
    go2 hash = do
        xs <- runRedis $
            getFromSortedSet
                (txSetPfx <> encode xpub)
                Nothing
                0
                0
        touchKeys [xpub]
        let xs' = if any ((== hash) . fst) xs
                  then dropWhile ((/= hash) . fst) xs
                  else []
        return
            $ map (uncurry f)
            $ l
            $ drop (fromIntegral (offset limits)) xs'
    l = if limit limits > 0
        then take (fromIntegral (limit limits))
        else id
    f t s = TxRef {txRefHash = t, txRefBlock = scoreBlockRef s}

cacheGetXPubUnspents ::
       (StoreReadBase m, MonadLoggerIO m)
    => XPubSpec
    -> Limits
    -> CacheX m [(BlockRef, OutPoint)]
cacheGetXPubUnspents xpub limits =
    case start limits of
        Nothing ->
            go1 Nothing
        Just (AtTx th) -> lift (getTxData th) >>= \case
            Just TxData {txDataBlock = b@BlockRef{}} ->
                go1 (Just (blockRefScore b))
            _ ->
                go2 th
        Just (AtBlock h) ->
            go1 (Just (blockRefScore (BlockRef h maxBound)))
  where
    go1 score = do
        xs <-
            runRedis $
            getFromSortedSet
                (utxoPfx <> encode xpub)
                score
                (offset limits)
                (limit limits)
        touchKeys [xpub]
        return $ map (uncurry f) xs
    go2 hash = do
        xs <- runRedis $
            getFromSortedSet
                (utxoPfx <> encode xpub)
                Nothing
                0
                0
        touchKeys [xpub]
        let xs' = if any ((== hash) . outPointHash . fst) xs
                  then dropWhile ((/= hash) . outPointHash . fst) xs
                  else []
        return
            $ map (uncurry f)
            $ l
            $ drop (fromIntegral (offset limits)) xs'
    l = if limit limits > 0
        then take (fromIntegral (limit limits))
        else id
    f o s = (scoreBlockRef s, o)

redisGetXPubBalances :: (Functor f, RedisCtx m f) => XPubSpec -> m (f [XPubBal])
redisGetXPubBalances xpub =
    fmap (sort . map (uncurry f)) <$> getAllFromMap (balancesPfx <> encode xpub)
  where
    f p b = XPubBal {xPubBalPath = p, xPubBal = b}

blockRefScore :: BlockRef -> Double
blockRefScore BlockRef {blockRefHeight = h, blockRefPos = p} =
    fromIntegral (0x001fffffffffffff - (h' .|. p'))
  where
    h' = (fromIntegral h .&. 0x07ffffff) `shift` 26 :: Word64
    p' = (fromIntegral p .&. 0x03ffffff) :: Word64
blockRefScore MemRef {memRefTime = t} = negate t'
  where
    t' = fromIntegral (t .&. 0x001fffffffffffff)

scoreBlockRef :: Double -> BlockRef
scoreBlockRef s
    | s < 0 = MemRef {memRefTime = n}
    | otherwise = BlockRef {blockRefHeight = h, blockRefPos = p}
  where
    n = truncate (abs s) :: Word64
    m = 0x001fffffffffffff - n
    h = fromIntegral (m `shift` (-26))
    p = fromIntegral (m .&. 0x03ffffff)

getFromSortedSet ::
       (Applicative f, RedisCtx m f, Serialize a)
    => ByteString
    -> Maybe Double
    -> Word32
    -> Word32
    -> m (f [(a, Double)])
getFromSortedSet key Nothing off 0 = do
    xs <- zrangeWithscores key (fromIntegral off) (-1)
    return $ do
        ys <- map (\(x, s) -> (, s) <$> decode x) <$> xs
        return (rights ys)
getFromSortedSet key Nothing off count = do
    xs <-
        zrangeWithscores
            key
            (fromIntegral off)
            (fromIntegral off + fromIntegral count - 1)
    return $ do
        ys <- map (\(x, s) -> (, s) <$> decode x) <$> xs
        return (rights ys)
getFromSortedSet key (Just score) off 0 = do
    xs <-
        zrangebyscoreWithscoresLimit
            key
            score
            (1 / 0)
            (fromIntegral off)
            (-1)
    return $ do
        ys <- map (\(x, s) -> (, s) <$> decode x) <$> xs
        return (rights ys)
getFromSortedSet key (Just score) off count = do
    xs <-
        zrangebyscoreWithscoresLimit
            key
            score
            (1 / 0)
            (fromIntegral off)
            (fromIntegral count)
    return $ do
        ys <- map (\(x, s) -> (, s) <$> decode x) <$> xs
        return (rights ys)

getAllFromMap ::
       (Functor f, RedisCtx m f, Serialize k, Serialize v)
    => ByteString
    -> m (f [(k, v)])
getAllFromMap n = do
    fxs <- hgetall n
    return $ do
        xs <- fxs
        return
            [ (k, v)
            | (k', v') <- xs
            , let Right k = decode k'
            , let Right v = decode v'
            ]

data CacheWriterMessage
    = CacheNewBlock
    | CachePing !(Listen ())

type CacheWriterInbox = Inbox CacheWriterMessage
type CacheWriter = Mailbox CacheWriterMessage

data AddressXPub = AddressXPub
    { addressXPubSpec :: !XPubSpec
    , addressXPubPath :: ![KeyIndex]
    }
    deriving (Show, Eq, Generic, NFData, Serialize)

mempoolSetKey :: ByteString
mempoolSetKey = "mempool"

addrPfx :: ByteString
addrPfx = "a"

bestBlockKey :: ByteString
bestBlockKey = "head"

maxKey :: ByteString
maxKey = "max"

xPubAddrFunction :: DeriveType -> XPubKey -> Address
xPubAddrFunction DeriveNormal = xPubAddr
xPubAddrFunction DeriveP2SH   = xPubCompatWitnessAddr
xPubAddrFunction DeriveP2WPKH = xPubWitnessAddr

cacheWriter ::
       (MonadUnliftIO m, MonadLoggerIO m, StoreReadExtra m)
    => CacheConfig -> CacheWriterInbox -> m ()
cacheWriter cfg inbox =
    withAsync ping $ \a ->
    link a >> runReaderT go cfg
  where
    ping = forever $ do
        threadDelay (cacheRefresh cfg * 1000)
        cachePing (inboxToMailbox inbox)
    go = do
        newBlockC
        forever $ do
            x <- receive inbox
            cacheWriterReact x

lockIt :: MonadLoggerIO m => CacheX m (Maybe Word32)
lockIt = do
    rnd <- liftIO randomIO
    go rnd >>= \case
        Right Redis.Ok -> do
            $(logDebugS) "Cache" $
                "Acquired lock with value " <> cs (show rnd)
            incrementCounter cacheLockAcquired
            return (Just rnd)
        Right Redis.Pong -> do
            $(logErrorS) "Cache"
                "Unexpected pong when acquiring lock"
            incrementCounter cacheLockFailed
            return Nothing
        Right (Redis.Status s) -> do
            $(logErrorS) "Cache" $
                "Unexpected status acquiring lock: " <> cs s
            incrementCounter cacheLockFailed
            return Nothing
        Left (Redis.Bulk Nothing) -> do
            $(logDebugS) "Cache" "Lock already taken"
            incrementCounter cacheLockFailed
            return Nothing
        Left e -> do
            $(logErrorS) "Cache"
                "Error when trying to acquire lock"
            incrementCounter cacheLockFailed
            throwIO (RedisError e)
  where
    go rnd = do
        conn <- asks cacheConn
        liftIO . Redis.runRedis conn $ do
            let opts =
                    Redis.SetOpts
                        { Redis.setSeconds = Just 300
                        , Redis.setMilliseconds = Nothing
                        , Redis.setCondition = Just Redis.Nx
                        }
            Redis.setOpts "lock" (cs (show rnd)) opts


unlockIt :: MonadLoggerIO m => Maybe Word32 -> CacheX m ()
unlockIt Nothing = return ()
unlockIt (Just i) =
    runRedis (Redis.get "lock") >>= \case
        Nothing ->
            $(logErrorS) "Cache" $
            "Not releasing lock with value " <> cs (show i) <>
            ": not locked"
        Just bs ->
            if read (cs bs) == i
            then do
                void $ runRedis (Redis.del ["lock"])
                $(logDebugS) "Cache" $
                    "Released lock with value " <>
                    cs (show i)
                incrementCounter cacheLockReleased
            else
                $(logErrorS) "Cache" $
                    "Could not release lock: value is not " <>
                    cs (show i)

withLock ::
       (MonadLoggerIO m, MonadUnliftIO m)
    => CacheX m a
    -> CacheX m (Maybe a)
withLock f =
    bracket lockIt unlockIt $ \case
        Just _  -> Just <$> f
        Nothing -> return Nothing

smallDelay :: MonadUnliftIO m => CacheX m ()
smallDelay = do
    delay <- asks cacheRetryDelay
    let delayMin = delay `div` 2
    let delayMax = delay * 3 `div` 2
    threadDelay =<< liftIO (randomRIO (delayMin, delayMax))

withLockForever
    :: (MonadLoggerIO m, MonadUnliftIO m)
    => CacheX m a
    -> CacheX m a
withLockForever go =
    withLock go >>= \case
    Nothing -> do
        smallDelay
        $(logDebugS) "Cache" "Retrying lock aquisition without limits"
        withLockForever go
    Just x -> return x

withLockRetry
    :: (MonadLoggerIO m, MonadUnliftIO m)
    => Int
    -> CacheX m a
    -> CacheX m (Maybe a)
withLockRetry i f
  | i <= 0 = return Nothing
  | otherwise = withLock f >>= \case
        Nothing -> do
            smallDelay
            $(logDebugS) "Cache" $
                "Retrying lock acquisition: " <>
                cs (show i) <> " tries remaining"
            withLockRetry (i - 1) f
        x -> return x

pruneDB :: (MonadUnliftIO m, MonadLoggerIO m, StoreReadBase m)
        => CacheX m Integer
pruneDB = do
    x <- asks cacheMax
    s <- runRedis Redis.dbsize
    if s > x then flush (s - x) else return 0
  where
    flush n =
        case n `div` 64 of
        0 -> return 0
        x -> fmap (fromMaybe 0) $ withLock $ do
            ks <- fmap (map fst) . runRedis $
                  getFromSortedSet maxKey Nothing 0 (fromIntegral x)
            $(logDebugS) "Cache" $
                "Pruning " <> cs (show (length ks)) <> " old xpubs"
            delXPubKeys ks

touchKeys :: MonadLoggerIO m => [XPubSpec] -> CacheX m ()
touchKeys xpubs = do
    now <- systemSeconds <$> liftIO getSystemTime
    runRedis $ redisTouchKeys now xpubs

redisTouchKeys :: (Monad f, RedisCtx m f, Real a) => a -> [XPubSpec] -> m (f ())
redisTouchKeys _ [] = return $ return ()
redisTouchKeys now xpubs =
    void <$> Redis.zadd maxKey (map ((realToFrac now, ) . encode) xpubs)

cacheWriterReact ::
       (MonadUnliftIO m, MonadLoggerIO m, StoreReadExtra m)
    => CacheWriterMessage -> CacheX m ()
cacheWriterReact CacheNewBlock =
    doSync
cacheWriterReact (CachePing respond) =
    doSync >> atomically (respond ())

doSync :: (MonadUnliftIO m, MonadLoggerIO m, StoreReadExtra m)
       => CacheX m ()
doSync =
    inSync >>= \s -> when s $ do
        newBlockC
        syncMempoolC
        void pruneDB

lenNotNull :: [XPubBal] -> Int
lenNotNull = length . filter (not . nullBalance . xPubBal)

newXPubC ::
       (MonadUnliftIO m, MonadLoggerIO m, StoreReadExtra m)
    => XPubSpec -> [XPubBal] -> CacheX m ()
newXPubC xpub xbals = should_index >>= \i ->
    if i
    then do
        incrementCounter cacheMisses
        withMetrics cacheIndexTime index
    else incrementCounter cacheIgnore
  where
    op XPubUnspent {xPubUnspent = u} = (unspentPoint u, unspentBlock u)
    should_index =
        asks cacheMin >>= \x ->
        if x <= lenNotNull xbals then inSync else return False
    index =
        bracket set_index unset_index $ \y -> when y $
        withMetrics cacheIndexTime $ do
        xpubtxt <- xpubText xpub
        $(logDebugS) "Cache" $
            "Caching " <> xpubtxt <> ": " <>
            cs (show (length xbals)) <> " addresses / " <>
            cs (show (lenNotNull xbals)) <> " used"
        utxo <- lift $ xPubUnspents xpub xbals def
        $(logDebugS) "Cache" $
            "Caching " <> xpubtxt <> ": " <> cs (show (length utxo)) <>
            " utxos"
        xtxs <- lift $ xPubTxs xpub xbals def
        $(logDebugS) "Cache" $
            "Caching " <> xpubtxt <> ": " <> cs (show (length xtxs)) <>
            " txs"
        now <- systemSeconds <$> liftIO getSystemTime
        runRedis $ do
            b <- redisTouchKeys now [xpub]
            c <- redisAddXPubBalances xpub xbals
            d <- redisAddXPubUnspents xpub (map op utxo)
            e <- redisAddXPubTxs xpub xtxs
            return $ b >> c >> d >> e >> return ()
        $(logDebugS) "Cache" $ "Cached " <> xpubtxt
    key = idxPfx <> encode xpub
    opts = Redis.SetOpts
           { Redis.setSeconds = Just 600
           , Redis.setMilliseconds = Nothing
           , Redis.setCondition = Just Redis.Nx
           }
    red = Redis.setOpts key "1" opts
    unset_index y = when y . void . runRedis $ Redis.del [key]
    set_index =
        asks cacheConn >>= \conn ->
        liftIO (Redis.runRedis conn red) >>= return . isRight

inSync :: (MonadUnliftIO m, MonadLoggerIO m, StoreReadExtra m)
       => CacheX m Bool
inSync =
    lift getBestBlock >>= \case
    Nothing -> return False
    Just bb ->
        asks cacheChain >>= \ch ->
        chainGetBest ch >>= \cb ->
        return $ headerHash (nodeHeader cb) == bb

newBlockC :: (MonadUnliftIO m, MonadLoggerIO m, StoreReadExtra m)
          => CacheX m ()
newBlockC =
    inSync >>= \s -> when s $ do
    lift getBestBlock >>= \case
        Nothing -> $(logWarnS) "Cache" "No best block"
        Just bb ->
            asks cacheChain >>= \ch ->
            chainGetBest ch >>= \cn ->
            cacheGetHead >>= \case
                Nothing -> do
                    $(logInfoS) "Cache" "Initializing best cache block"
                    void $ importBlockC bb
                Just hb ->
                    if hb == headerHash (nodeHeader cn)
                    then $(logDebugS) "Cache" "Cache in sync"
                    else sync ch hb bb
  where
    sync ch hb bb =
        chainGetBlock hb ch >>= \case
            Nothing ->
                $(logErrorS) "Cache" $
                "Cache head block node not found: " <>
                blockHashToHex hb
            Just hn ->
                chainBlockMain hb ch >>= \m ->
                    if m
                    then
                        chainGetBlock bb ch >>= \case
                            Just bn -> next ch bn hn
                            Nothing -> do
                                $(logErrorS) "Cache" $
                                    "Cache head node not found: "
                                    <> blockHashToHex bb
                                throwIO $
                                    LogicError $
                                    "Cache head node not found: "
                                    <> cs (blockHashToHex bb)
                    else do
                        $(logDebugS) "Cache" $
                            "Reverting cache head not in main chain: " <>
                            blockHashToHex hb
                        removeHeadC hb >>= \s -> when s newBlockC
    next ch bn hn =
        if | prevBlock (nodeHeader bn) == headerHash (nodeHeader hn) ->
                 void $ importBlockC (headerHash (nodeHeader bn))
           | nodeHeight bn > nodeHeight hn ->
                 chainGetAncestor (nodeHeight hn + 1) bn ch >>= \case
                     Nothing ->
                         $(logWarnS) "Cache" $
                         "Ancestor not found at height "
                         <> cs (show (nodeHeight hn + 1))
                         <> " for block: "
                         <> blockHashToHex (headerHash (nodeHeader bn))
                     Just hn' ->
                         importBlockC (headerHash (nodeHeader hn')) >>= \s ->
                         when s newBlockC
           | otherwise ->
                 $(logInfoS) "Cache" "Cache best block higher than this node's"

importBlockC :: (MonadUnliftIO m, StoreReadExtra m, MonadLoggerIO m)
             => BlockHash -> CacheX m Bool
importBlockC bh =
    fmap (maybe False (const True)) $ withLock $
    withMetrics cacheBlockSyncTime $
    cacheGetHead >>= \case
        Nothing -> go
        Just cb ->
            asks cacheChain >>= \ch ->
            chainGetBlock bh ch >>= \case
                Nothing -> return ()
                Just bn ->
                    if prevBlock (nodeHeader bn) == cb
                    then go
                    else return ()
  where
    go = lift (getBlock bh) >>= \case
        Just bd -> do
            let ths = blockDataTxs bd
            tds <- sortTxData . catMaybes <$> mapM (lift . getTxData) ths
            $(logDebugS) "Cache" $
                "Importing " <> cs (show (length tds)) <>
                " transactions from block " <>
                blockHashToHex bh
            importMultiTxC tds
            $(logDebugS) "Cache" $
                "Done importing " <> cs (show (length tds)) <>
                " transactions from block " <>
                blockHashToHex bh
            cacheSetHead bh
        Nothing -> do
            $(logErrorS) "Cache" $
                "Could not get block: "
                <> blockHashToHex bh
            throwIO . LogicError . cs $
                "Could not get block: "
                <> blockHashToHex bh

removeHeadC :: (StoreReadExtra m, MonadUnliftIO m, MonadLoggerIO m)
            => BlockHash -> CacheX m Bool
removeHeadC cb =
    fmap (maybe False (const True)) $ withLock $
    void . runMaybeT $ do
    bh <- MaybeT cacheGetHead
    guard (cb == bh)
    bd <- MaybeT (lift (getBlock bh))
    lift $ do
        tds <- sortTxData . catMaybes <$>
               mapM (lift . getTxData) (blockDataTxs bd)
        $(logDebugS) "Cache" $ "Reverting head: " <> blockHashToHex bh
        importMultiTxC tds
        $(logWarnS) "Cache" $
            "Reverted block head "
            <> blockHashToHex bh
            <> " to parent "
            <> blockHashToHex (prevBlock (blockDataHeader bd))
        cacheSetHead (prevBlock (blockDataHeader bd))

importMultiTxC ::
       (MonadUnliftIO m, StoreReadExtra m, MonadLoggerIO m)
    => [TxData] -> CacheX m ()
importMultiTxC txs = do
    $(logDebugS) "Cache" $ "Processing " <> cs (show (length txs)) <> " txs"
    $(logDebugS) "Cache" $
        "Getting address information for "
        <> cs (show (length alladdrs))
        <> " addresses"
    addrmap <- getaddrmap
    let addrs = HashMap.keys addrmap
    $(logDebugS) "Cache" $
        "Getting balances for "
        <> cs (show (HashMap.size addrmap))
        <> " addresses"
    balmap <- getbalances addrs
    $(logDebugS) "Cache" $
        "Getting unspent data for "
        <> cs (show (length allops))
        <> " outputs"
    unspentmap <- getunspents
    gap <- lift getMaxGap
    now <- systemSeconds <$> liftIO getSystemTime
    let xpubs = allxpubsls addrmap
    forM_ (zip [(1 :: Int) ..] xpubs) $ \(i, xpub) -> do
        xpubtxt <- xpubText xpub
        $(logDebugS) "Cache" $
            "Affected xpub "
            <> cs (show i) <> "/" <> cs (show (length xpubs))
            <> ": " <> xpubtxt
    addrs' <- do
        $(logDebugS) "Cache" $
            "Getting xpub balances for "
            <> cs (show (length xpubs)) <> " xpubs"
        xmap <- getxbals xpubs
        let addrmap' = faddrmap (HashMap.keysSet xmap) addrmap
        $(logDebugS) "Cache" "Starting Redis import pipeline"
        runRedis $ do
            x <- redisImportMultiTx addrmap' unspentmap txs
            y <- redisUpdateBalances addrmap' balmap
            z <- redisTouchKeys now (HashMap.keys xmap)
            return $ x >> y >> z >> return ()
        $(logDebugS) "Cache" "Completed Redis pipeline"
        return $ getNewAddrs gap xmap (HashMap.elems addrmap')
    cacheAddAddresses addrs'
  where
    alladdrsls = HashSet.toList alladdrs
    faddrmap xmap = HashMap.filter (\a -> addressXPubSpec a `elem` xmap)
    getaddrmap =
        HashMap.fromList . catMaybes . zipWith (\a -> fmap (a, )) alladdrsls <$>
        cacheGetAddrsInfo alladdrsls
    getunspents =
        HashMap.fromList . catMaybes . zipWith (\p -> fmap (p, )) allops <$>
        lift (mapM getUnspent allops)
    getbalances addrs =
        HashMap.fromList . zip addrs <$> mapM (lift . getDefaultBalance) addrs
    getxbals xpubs = do
        bals <- runRedis . fmap sequence . forM xpubs $ \xpub -> do
            bs <- redisGetXPubBalances xpub
            return $ (,) xpub <$> bs
        return $ HashMap.filter (not . null) (HashMap.fromList bals)
    allops = map snd $ concatMap txInputs txs <> concatMap txOutputs txs
    alladdrs =
        HashSet.fromList . map fst $
        concatMap txInputs txs <> concatMap txOutputs txs
    allxpubsls addrmap = HashSet.toList (allxpubs addrmap)
    allxpubs addrmap =
        HashSet.fromList . map addressXPubSpec $ HashMap.elems addrmap

redisImportMultiTx ::
       (Monad f, RedisCtx m f)
    => HashMap Address AddressXPub
    -> HashMap OutPoint Unspent
    -> [TxData]
    -> m (f ())
redisImportMultiTx addrmap unspentmap txs = do
    xs <- mapM importtxentries txs
    return $ sequence_ xs
  where
    uns p i =
        case HashMap.lookup p unspentmap of
        Just u ->
            redisAddXPubUnspents (addressXPubSpec i) [(p, unspentBlock u)]
        Nothing -> redisRemXPubUnspents (addressXPubSpec i) [p]
    addtx tx a p =
        case HashMap.lookup a addrmap of
        Just i -> do
            let tr = TxRef { txRefHash = txHash (txData tx)
                           , txRefBlock = txDataBlock tx
                           }
            x <- redisAddXPubTxs (addressXPubSpec i) [tr]
            y <- uns p i
            return $ x >> y >> return ()
        Nothing -> return (pure ())
    remtx tx a p =
        case HashMap.lookup a addrmap of
        Just i -> do
            x <- redisRemXPubTxs (addressXPubSpec i) [txHash (txData tx)]
            y <- uns p i
            return $ x >> y >> return ()
        Nothing -> return (pure ())
    importtxentries tx =
        if txDataDeleted tx
        then do
            x <- mapM (uncurry (remtx tx)) (txaddrops tx)
            y <- redisRemFromMempool [txHash (txData tx)]
            return $ sequence_ x >> void y
        else do
            a <- sequence <$> mapM (uncurry (addtx tx)) (txaddrops tx)
            b <-
                case txDataBlock tx of
                    b@MemRef {} ->
                        let tr = TxRef { txRefHash = txHash (txData tx)
                                       , txRefBlock = b
                                       }
                        in redisAddToMempool [tr]
                    _ -> redisRemFromMempool [txHash (txData tx)]
            return $ a >> b >> return ()
    txaddrops td = txInputs td <> txOutputs td

redisUpdateBalances ::
       (Monad f, RedisCtx m f)
    => HashMap Address AddressXPub
    -> HashMap Address Balance
    -> m (f ())
redisUpdateBalances addrmap balmap =
    fmap (fmap mconcat . sequence) . forM (HashMap.keys addrmap) $ \a ->
    case (HashMap.lookup a addrmap, HashMap.lookup a balmap) of
    (Just ainfo, Just bal) ->
        redisAddXPubBalances (addressXPubSpec ainfo) [xpubbal ainfo bal]
    _ -> return (pure ())
  where
    xpubbal ainfo bal =
        XPubBal {xPubBalPath = addressXPubPath ainfo, xPubBal = bal}

cacheAddAddresses ::
       (StoreReadExtra m, MonadUnliftIO m, MonadLoggerIO m)
    => [(Address, AddressXPub)]
    -> CacheX m ()
cacheAddAddresses [] = $(logDebugS) "Cache" "No further addresses to add"
cacheAddAddresses addrs = do
    $(logDebugS) "Cache" $
        "Adding " <> cs (show (length addrs)) <> " new generated addresses"
    $(logDebugS) "Cache" "Getting balances"
    balmap <- HashMap.fromListWith (<>) <$> mapM (uncurry getbal) addrs
    $(logDebugS) "Cache" "Getting unspent outputs"
    utxomap <- HashMap.fromListWith (<>) <$> mapM (uncurry getutxo) addrs
    $(logDebugS) "Cache" "Getting transactions"
    txmap <- HashMap.fromListWith (<>) <$> mapM (uncurry gettxmap) addrs
    $(logDebugS) "Cache" "Running Redis pipeline"
    runRedis $ do
        a <- forM (HashMap.toList balmap) (uncurry redisAddXPubBalances)
        b <- forM (HashMap.toList utxomap) (uncurry redisAddXPubUnspents)
        c <- forM (HashMap.toList txmap) (uncurry redisAddXPubTxs)
        return $ sequence_ a >> sequence_ b >> sequence_ c
    $(logDebugS) "Cache" "Completed Redis pipeline"
    let xpubs = HashSet.toList
              . HashSet.fromList
              . map addressXPubSpec
              $ Map.elems amap
    $(logDebugS) "Cache" "Getting xpub balances"
    xmap <- getbals xpubs
    gap <- lift getMaxGap
    let notnulls = getnotnull balmap
        addrs' = getNewAddrs gap xmap notnulls
    cacheAddAddresses addrs'
  where
    getbals xpubs = runRedis $ do
        bs <- sequence <$> forM xpubs redisGetXPubBalances
        return $
            HashMap.filter (not . null) . HashMap.fromList . zip xpubs <$> bs
    amap = Map.fromList addrs
    getnotnull =
        let f xpub =
                map $ \bal ->
                    AddressXPub
                        { addressXPubSpec = xpub
                        , addressXPubPath = xPubBalPath bal
                        }
            g = filter (not . nullBalance . xPubBal)
         in concatMap (uncurry f) . HashMap.toList . HashMap.map g
    getbal a i =
        let f b = ( addressXPubSpec i
                  , [XPubBal {xPubBal = b, xPubBalPath = addressXPubPath i}] )
         in f <$> lift (getDefaultBalance a)
    getutxo a i =
        let f us = ( addressXPubSpec i
                   , map (\u -> (unspentPoint u, unspentBlock u)) us )
         in f <$> lift (getAddressUnspents a def)
    gettxmap a i =
        let f ts = (addressXPubSpec i, ts)
         in f <$> lift (getAddressTxs a def)

getNewAddrs :: KeyIndex
            -> HashMap XPubSpec [XPubBal]
            -> [AddressXPub]
            -> [(Address, AddressXPub)]
getNewAddrs gap xpubs =
    concatMap $ \a ->
    case HashMap.lookup (addressXPubSpec a) xpubs of
    Nothing   -> []
    Just bals -> addrsToAdd gap bals a

withCool :: (MonadLoggerIO m)
         => ByteString
         -> Integer
         -> CacheX m a
         -> CacheX m (Maybe a)
withCool key milliseconds run =
    is_cool >>= \c ->
    if c
    then do
        $(logDebugS) "Cache" $ "Cooldown reached for key: " <> cs (show key)
        x <- run
        cooldown
        return (Just x)
    else do
        $(logDebugS) "Cache" $ "Cooldown NOT reached for key: " <> cs (show key)
        return Nothing
  where
    is_cool = isNothing <$> runRedis (Redis.get key)
    cooldown =
        let opts = Redis.SetOpts
                   { Redis.setSeconds = Nothing
                   , Redis.setMilliseconds = Just milliseconds
                   , Redis.setCondition = Just Redis.Nx }
        in void . runRedis $ Redis.setOpts key "0" opts

syncMempoolC :: (MonadUnliftIO m, MonadLoggerIO m, StoreReadExtra m)
             => CacheX m ()
syncMempoolC =
    toInteger <$> asks cacheRefresh >>= \refresh ->
    void . withLock . withCool "cool" (refresh * 9 `div` 10) $
    withMetrics cacheMempoolSyncTime $ do
    nodepool <- HashSet.fromList . map snd <$> lift getMempool
    cachepool <- HashSet.fromList . map snd <$> cacheGetMempool
    getem (HashSet.difference nodepool cachepool)
    getem (HashSet.difference cachepool nodepool)
    incrementCounter cacheRefreshes
  where
    getem tset = do
        let tids = HashSet.toList tset
        txs <- catMaybes <$> mapM (lift . getTxData) tids
        unless (null txs) $ do
            $(logDebugS) "Cache" $
                "Importing mempool transactions: " <> cs (show (length txs))
            importMultiTxC txs


cacheGetMempool :: MonadLoggerIO m => CacheX m [(UnixTime, TxHash)]
cacheGetMempool = runRedis redisGetMempool

cacheGetHead :: MonadLoggerIO m => CacheX m (Maybe BlockHash)
cacheGetHead = runRedis redisGetHead

cacheSetHead :: (MonadLoggerIO m, StoreReadBase m) => BlockHash -> CacheX m ()
cacheSetHead bh = do
    $(logDebugS) "Cache" $ "Cache head set to: " <> blockHashToHex bh
    void $ runRedis (redisSetHead bh)

cacheGetAddrsInfo ::
       MonadLoggerIO m => [Address] -> CacheX m [Maybe AddressXPub]
cacheGetAddrsInfo as = runRedis (redisGetAddrsInfo as)

redisAddToMempool :: (Applicative f, RedisCtx m f) => [TxRef] -> m (f Integer)
redisAddToMempool [] = return (pure 0)
redisAddToMempool btxs =
    zadd mempoolSetKey $
    map (\btx -> (blockRefScore (txRefBlock btx), encode (txRefHash btx)))
        btxs

redisRemFromMempool ::
       (Applicative f, RedisCtx m f) => [TxHash] -> m (f Integer)
redisRemFromMempool [] = return (pure 0)
redisRemFromMempool xs = zrem mempoolSetKey $ map encode xs

redisSetAddrInfo ::
       (Functor f, RedisCtx m f) => Address -> AddressXPub -> m (f ())
redisSetAddrInfo a i = void <$> Redis.set (addrPfx <> encode a) (encode i)

delXPubKeys ::
       (MonadUnliftIO m, MonadLoggerIO m, StoreReadBase m)
    => [XPubSpec]
    -> CacheX m Integer
delXPubKeys [] = return 0
delXPubKeys xpubs = do
    forM_ xpubs $ \x -> do
        xtxt <- xpubText x
        $(logDebugS) "Cache" $ "Deleting xpub: " <> xtxt
    xbals <-
        runRedis . fmap sequence . forM xpubs $ \xpub -> do
            bs <- redisGetXPubBalances xpub
            return $ (xpub, ) <$> bs
    runRedis $ fmap sum . sequence <$> forM xbals (uncurry redisDelXPubKeys)

redisDelXPubKeys ::
       (Monad f, RedisCtx m f) => XPubSpec -> [XPubBal] -> m (f Integer)
redisDelXPubKeys xpub bals = go (map (balanceAddress . xPubBal) bals)
  where
    go addrs = do
        addrcount <-
            case addrs of
                [] -> return (pure 0)
                _  -> Redis.del (map ((addrPfx <>) . encode) addrs)
        txsetcount <- Redis.del [txSetPfx <> encode xpub]
        utxocount <- Redis.del [utxoPfx <> encode xpub]
        balcount <- Redis.del [balancesPfx <> encode xpub]
        x <- Redis.zrem maxKey [encode xpub]
        return $ do
            _ <- x
            addrs' <- addrcount
            txset' <- txsetcount
            utxo' <- utxocount
            bal' <- balcount
            return $ addrs' + txset' + utxo' + bal'

redisAddXPubTxs ::
       (Applicative f, RedisCtx m f) => XPubSpec -> [TxRef] -> m (f Integer)
redisAddXPubTxs _ [] = return (pure 0)
redisAddXPubTxs xpub btxs =
    zadd (txSetPfx <> encode xpub) $
    map (\t -> (blockRefScore (txRefBlock t), encode (txRefHash t))) btxs

redisRemXPubTxs ::
       (Applicative f, RedisCtx m f) => XPubSpec -> [TxHash] -> m (f Integer)
redisRemXPubTxs _ []      = return (pure 0)
redisRemXPubTxs xpub txhs = zrem (txSetPfx <> encode xpub) (map encode txhs)

redisAddXPubUnspents ::
       (Applicative f, RedisCtx m f)
    => XPubSpec
    -> [(OutPoint, BlockRef)]
    -> m (f Integer)
redisAddXPubUnspents _ [] =
    return (pure 0)
redisAddXPubUnspents xpub utxo =
    zadd (utxoPfx <> encode xpub) $
    map (\(p, r) -> (blockRefScore r, encode p)) utxo

redisRemXPubUnspents ::
       (Applicative f, RedisCtx m f) => XPubSpec -> [OutPoint] -> m (f Integer)
redisRemXPubUnspents _ [] =
    return (pure 0)
redisRemXPubUnspents xpub ops =
    zrem (utxoPfx <> encode xpub) (map encode ops)

redisAddXPubBalances ::
       (Monad f, RedisCtx m f) => XPubSpec -> [XPubBal] -> m (f ())
redisAddXPubBalances _ [] = return (pure ())
redisAddXPubBalances xpub bals = do
    xs <- mapM (uncurry (Redis.hset (balancesPfx <> encode xpub))) entries
    ys <- forM bals $ \b ->
        redisSetAddrInfo
        (balanceAddress (xPubBal b))
        AddressXPub
        {
            addressXPubSpec = xpub,
            addressXPubPath = xPubBalPath b
        }
    return $ sequence_ xs >> sequence_ ys
  where
    entries = map (\b -> (encode (xPubBalPath b), encode (xPubBal b))) bals

redisSetHead :: RedisCtx m f => BlockHash -> m (f Redis.Status)
redisSetHead bh = Redis.set bestBlockKey (encode bh)

redisGetAddrsInfo ::
       (Monad f, RedisCtx m f) => [Address] -> m (f [Maybe AddressXPub])
redisGetAddrsInfo [] = return (pure [])
redisGetAddrsInfo as = do
    is <- mapM (\a -> Redis.get (addrPfx <> encode a)) as
    return $ do
        is' <- sequence is
        return $ map (eitherToMaybe . decode =<<) is'

addrsToAdd :: KeyIndex -> [XPubBal] -> AddressXPub -> [(Address, AddressXPub)]
addrsToAdd gap xbals addrinfo
    | null fbals = []
    | otherwise = zipWith f addrs list
  where
    f a p = (a, AddressXPub {addressXPubSpec = xpub, addressXPubPath = p})
    dchain = head (addressXPubPath addrinfo)
    fbals = filter ((== dchain) . head . xPubBalPath) xbals
    maxidx = maximum (map (head . tail . xPubBalPath) fbals)
    xpub = addressXPubSpec addrinfo
    aidx = (head . tail) (addressXPubPath addrinfo)
    ixs =
        if gap > maxidx - aidx
            then [maxidx + 1 .. aidx + gap]
            else []
    paths = map (Deriv :/ dchain :/) ixs
    keys = map (\p -> derivePubPath p (xPubSpecKey xpub)) paths
    list = map pathToList paths
    xpubf = xPubAddrFunction (xPubDeriveType xpub)
    addrs = map xpubf keys

sortTxData :: [TxData] -> [TxData]
sortTxData tds =
    let txm = Map.fromList (map (\d -> (txHash (txData d), d)) tds)
        ths = map (txHash . snd) (sortTxs (map txData tds))
     in mapMaybe (`Map.lookup` txm) ths

txInputs :: TxData -> [(Address, OutPoint)]
txInputs td =
    let is = txIn (txData td)
        ps = I.toAscList (txDataPrevs td)
        as = map (scriptToAddressBS . prevScript . snd) ps
        f (Right a) i = Just (a, prevOutput i)
        f (Left _) _  = Nothing
     in catMaybes (zipWith f as is)

txOutputs :: TxData -> [(Address, OutPoint)]
txOutputs td =
    let ps =
            zipWith
                (\i _ ->
                     OutPoint
                         {outPointHash = txHash (txData td), outPointIndex = i})
                [0 ..]
                (txOut (txData td))
        as = map (scriptToAddressBS . scriptOutput) (txOut (txData td))
        f (Right a) p = Just (a, p)
        f (Left _) _  = Nothing
     in catMaybes (zipWith f as ps)

redisGetHead :: (Functor f, RedisCtx m f) => m (f (Maybe BlockHash))
redisGetHead = do
    x <- Redis.get bestBlockKey
    return $ (eitherToMaybe . decode =<<) <$> x

redisGetMempool :: (Applicative f, RedisCtx m f) => m (f [(UnixTime, TxHash)])
redisGetMempool = do
    xs <- getFromSortedSet mempoolSetKey Nothing 0 0
    return $ map (uncurry f) <$> xs
  where
    f t s = (memRefTime (scoreBlockRef s), t)

xpubText :: (MonadUnliftIO m, MonadLoggerIO m, StoreReadBase m)
         => XPubSpec -> CacheX m Text
xpubText xpub = do
    net <- lift getNetwork
    let suffix = case xPubDeriveType xpub of
                     DeriveNormal -> ""
                     DeriveP2SH   -> "/p2sh"
                     DeriveP2WPKH -> "/p2wpkh"
    return . cs $ suffix <> xPubExport net (xPubSpecKey xpub)

cacheNewBlock :: MonadIO m => CacheWriter -> m ()
cacheNewBlock = send CacheNewBlock

cachePing :: MonadIO m => CacheWriter -> m ()
cachePing = query CachePing
