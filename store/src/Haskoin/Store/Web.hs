{-# LANGUAGE CPP                 #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE MultiWayIf          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# LANGUAGE TupleSections       #-}
{-# OPTIONS_GHC -Wno-deprecations #-}
module Haskoin.Store.Web
    ( -- * Web
      WebConfig (..)
    , Except (..)
    , WebLimits (..)
    , WebTimeouts (..)
    , runWeb
    ) where

import           Conduit                                 (ConduitT, await,
                                                          concatMapMC, dropC,
                                                          dropWhileC, mapC,
                                                          runConduit, sinkList,
                                                          takeC, takeWhileC,
                                                          yield, (.|))
import           Control.Applicative                     ((<|>))
import           Control.Arrow                           (second)
import           Control.Concurrent.STM                  (check)
import           Control.Lens                            ((.~), (^.))
import           Control.Monad                           (forM, forever, unless,
                                                          when, (<=<))
import           Control.Monad.Logger                    (MonadLoggerIO,
                                                          logDebugS, logErrorS,
                                                          logInfoS, logWarnS)
import           Control.Monad.Reader                    (ReaderT, ask, asks,
                                                          local, runReaderT)
import           Control.Monad.Trans                     (lift)
import           Control.Monad.Trans.Control             (liftWith, restoreT)
import           Control.Monad.Trans.Maybe               (MaybeT (..),
                                                          runMaybeT)
import           Data.Aeson                              (Encoding, ToJSON (..),
                                                          Value, object, (.=))
import qualified Data.Aeson                              as A
import           Data.Aeson.Encode.Pretty                (Config (..),
                                                          defConfig,
                                                          encodePretty')
import           Data.Aeson.Encoding                     (encodingToLazyByteString,
                                                          list)
import           Data.Aeson.Text                         (encodeToLazyText)
import           Data.ByteString                         (ByteString)
import qualified Data.ByteString                         as B
import qualified Data.ByteString.Base16                  as B16
import           Data.ByteString.Builder                 (lazyByteString)
import qualified Data.ByteString.Char8                   as C
import qualified Data.ByteString.Lazy                    as L
import           Data.Bytes.Get
import           Data.Bytes.Put
import           Data.Bytes.Serial
import           Data.Char                               (isSpace)
import           Data.Default                            (Default (..))
import           Data.Function                           (on, (&))
import           Data.HashMap.Strict                     (HashMap)
import qualified Data.HashMap.Strict                     as HashMap
import           Data.HashSet                            (HashSet)
import qualified Data.HashSet                            as HashSet
import           Data.Int                                (Int64)
import           Data.List                               (nub)
import qualified Data.Map.Strict                         as Map
import           Data.Maybe                              (catMaybes, fromJust,
                                                          fromMaybe, isJust,
                                                          listToMaybe, mapMaybe,
                                                          maybeToList)
import           Data.Proxy                              (Proxy (..))
import qualified Data.Set                                as Set
import           Data.String                             (fromString)
import           Data.String.Conversions                 (cs)
import           Data.Text                               (Text)
import qualified Data.Text                               as T
import qualified Data.Text.Encoding                      as T
import           Data.Text.Lazy                          (toStrict)
import qualified Data.Text.Lazy                          as TL
import           Data.Time.Clock                         (NominalDiffTime,
                                                          diffUTCTime)
import           Data.Time.Clock.System                  (getSystemTime,
                                                          systemSeconds,
                                                          systemToUTCTime)
import qualified Data.Vault.Lazy                         as V
import           Data.Word                               (Word32, Word64)
import           Database.RocksDB                        (Property (..),
                                                          getProperty)
import           Haskoin.Address
import qualified Haskoin.Block                           as H
import           Haskoin.Constants
import           Haskoin.Keys
import           Haskoin.Network
import           Haskoin.Node                            (Chain,
                                                          OnlinePeer (..),
                                                          PeerManager,
                                                          chainGetBest,
                                                          getPeers, sendMessage)
import           Haskoin.Store.BlockStore
import           Haskoin.Store.Cache
import           Haskoin.Store.Common
import           Haskoin.Store.Data
import           Haskoin.Store.Database.Reader
import           Haskoin.Store.Logic
import           Haskoin.Store.Manager
import           Haskoin.Store.Stats
import           Haskoin.Store.WebCommon
import           Haskoin.Transaction
import           Haskoin.Util
import           NQE                                     (Inbox, receive,
                                                          withSubscription)
import           Network.HTTP.Types                      (Status (..),
                                                          requestEntityTooLarge413,
                                                          status400, status403,
                                                          status404, status409,
                                                          status500, status503,
                                                          statusIsClientError,
                                                          statusIsServerError,
                                                          statusIsSuccessful)
import           Network.Wai                             (Middleware,
                                                          Request (..),
                                                          Response,
                                                          getRequestBodyChunk,
                                                          responseLBS,
                                                          responseStatus)
import           Network.Wai.Handler.Warp                (defaultSettings,
                                                          setHost, setPort)
import           Network.Wai.Middleware.RequestSizeLimit
import qualified Network.Wreq                            as Wreq
import           System.IO.Unsafe                        (unsafeInterleaveIO)
import qualified System.Metrics                          as Metrics
import qualified System.Metrics.Counter                  as Metrics (Counter)
import qualified System.Metrics.Counter                  as Metrics.Counter
import qualified System.Metrics.Gauge                    as Metrics (Gauge)
import qualified System.Metrics.Gauge                    as Metrics.Gauge
import           Text.Printf                             (printf)
import           UnliftIO                                (MonadIO,
                                                          MonadUnliftIO, TVar,
                                                          askRunInIO,
                                                          atomically, bracket,
                                                          bracket_, handleAny,
                                                          liftIO, modifyTVar,
                                                          newTVarIO, readTVar,
                                                          readTVarIO, timeout,
                                                          withAsync,
                                                          withRunInIO,
                                                          writeTVar)
import           UnliftIO.Concurrent                     (threadDelay)
import           Web.Scotty.Internal.Types               (ActionT)
import           Web.Scotty.Trans                        (Parsable)
import qualified Web.Scotty.Trans                        as S

type WebT m = ActionT Except (ReaderT WebState m)

data WebLimits = WebLimits
    { maxLimitCount      :: !Word32
    , maxLimitFull       :: !Word32
    , maxLimitOffset     :: !Word32
    , maxLimitDefault    :: !Word32
    , maxLimitGap        :: !Word32
    , maxLimitInitialGap :: !Word32
    }
    deriving (Eq, Show)

instance Default WebLimits where
    def =
        WebLimits
            { maxLimitCount = 200000
            , maxLimitFull = 5000
            , maxLimitOffset = 50000
            , maxLimitDefault = 100
            , maxLimitGap = 32
            , maxLimitInitialGap = 20
            }

data WebConfig = WebConfig
    { webHost       :: !String
    , webPort       :: !Int
    , webStore      :: !Store
    , webMaxDiff    :: !Int
    , webMaxPending :: !Int
    , webMaxLimits  :: !WebLimits
    , webTimeouts   :: !WebTimeouts
    , webVersion    :: !String
    , webNoMempool  :: !Bool
    , webStats      :: !(Maybe Metrics.Store)
    , webPriceGet   :: !Int
    }

data WebState = WebState
    { webConfig  :: !WebConfig
    , webTicker  :: !(TVar (HashMap Text BinfoTicker))
    , webMetrics :: !(Maybe WebMetrics)
    }

data WebMetrics = WebMetrics
    { everyStat       :: !StatDist
    , blockStat       :: !StatDist
    , rawBlockStat    :: !StatDist
    , txStat          :: !StatDist
    , txsBlockStat    :: !StatDist
    , txAfterStat     :: !StatDist
    , postTxStat      :: !StatDist
    , mempoolStat     :: !StatDist
    , addrTxStat      :: !StatDist
    , addrTxFullStat  :: !StatDist
    , addrBalanceStat :: !StatDist
    , addrUnspentStat :: !StatDist
    , xPubStat        :: !StatDist
    , xPubTxStat      :: !StatDist
    , xPubTxFullStat  :: !StatDist
    , xPubUnspentStat :: !StatDist
    , multiaddrStat   :: !StatDist
    , rawaddrStat     :: !StatDist
    , balanceStat     :: !StatDist
    , unspentStat     :: !StatDist
    , rawtxStat       :: !StatDist
    , historyStat     :: !StatDist
    , peerStat        :: !StatDist
    , healthStat      :: !StatDist
    , dbStatsStat     :: !StatDist
    , eventsConnected :: !Metrics.Gauge
    , statKey         :: !(V.Key (TVar (Maybe (WebMetrics -> StatDist))))
    , itemsKey        :: !(V.Key (TVar Int))
    }

createMetrics :: MonadIO m => Metrics.Store -> m WebMetrics
createMetrics s = liftIO $ do
    everyStat         <- d "all"
    blockStat         <- d "block"
    rawBlockStat      <- d "block_raw"
    txStat            <- d "tx"
    txsBlockStat      <- d "txs_block"
    txAfterStat       <- d "tx_after"
    postTxStat        <- d "tx_post"
    mempoolStat       <- d "mempool"
    addrBalanceStat   <- d "addr_balance"
    addrTxStat        <- d "addr_tx"
    addrTxFullStat    <- d "addr_tx_full"
    addrUnspentStat   <- d "addr_unspent"
    xPubStat          <- d "xpub_balance"
    xPubTxStat        <- d "xpub_tx"
    xPubTxFullStat    <- d "xpub_tx_full"
    xPubUnspentStat   <- d "xpub_unspent"
    rawaddrStat       <- d "rawaddr"
    multiaddrStat     <- d "multiaddr"
    balanceStat       <- d "balance"
    rawtxStat         <- d "rawtx"
    historyStat       <- d "history"
    unspentStat       <- d "unspent"
    peerStat          <- d "peer"
    healthStat        <- d "health"
    dbStatsStat       <- d "dbstats"
    eventsConnected   <- g "events.connected"
    statKey           <- V.newKey
    itemsKey          <- V.newKey
    return WebMetrics{..}
  where
    d x = createStatDist       ("web." <> x) s
    g x = Metrics.createGauge  ("web." <> x) s

withGaugeIncrease :: MonadUnliftIO m
                  => (WebMetrics -> Metrics.Gauge)
                  -> WebT m a
                  -> WebT m a
withGaugeIncrease gf go =
    lift (asks webMetrics) >>= \case
        Nothing -> go
        Just m -> do
            s <- liftWith $ \run ->
                bracket_
                (start m)
                (end m)
                (run go)
            restoreT $ return s
  where
    start m = liftIO $ Metrics.Gauge.inc (gf m)
    end m = liftIO $ Metrics.Gauge.dec (gf m)

setMetrics :: MonadUnliftIO m
           => (WebMetrics -> StatDist)
           -> Int
           -> WebT m ()
setMetrics df i = asks webMetrics >>= \case
    Nothing -> return ()
    Just m -> do
        req <- S.request
        let stat_var = fromMaybe e $ V.lookup (statKey m) (vault req)
            item_var = fromMaybe e $ V.lookup (itemsKey m) (vault req)
        atomically $ do
            writeTVar stat_var (Just df)
            writeTVar item_var i
  where
    e = error "the ways of the warrior are yet to be mastered"

data WebTimeouts = WebTimeouts
    { txTimeout    :: !Word64
    , blockTimeout :: !Word64
    }
    deriving (Eq, Show)

data SerialAs = SerialAsBinary | SerialAsJSON | SerialAsPrettyJSON
    deriving (Eq, Show)

instance Default WebTimeouts where
    def = WebTimeouts {txTimeout = 300, blockTimeout = 7200}

instance (MonadUnliftIO m, MonadLoggerIO m) =>
         StoreReadBase (ReaderT WebState m) where
    getNetwork = runInWebReader getNetwork
    getBestBlock = runInWebReader getBestBlock
    getBlocksAtHeight height = runInWebReader (getBlocksAtHeight height)
    getBlock bh = runInWebReader (getBlock bh)
    getTxData th = runInWebReader (getTxData th)
    getSpender op = runInWebReader (getSpender op)
    getUnspent op = runInWebReader (getUnspent op)
    getBalance a = runInWebReader (getBalance a)
    getMempool = runInWebReader getMempool

instance (MonadUnliftIO m, MonadLoggerIO m) =>
         StoreReadExtra (ReaderT WebState m) where
    getMaxGap = runInWebReader getMaxGap
    getInitialGap = runInWebReader getInitialGap
    getBalances as = runInWebReader (getBalances as)
    getAddressesTxs as = runInWebReader . getAddressesTxs as
    getAddressesUnspents as = runInWebReader . getAddressesUnspents as
    xPubBals = runInWebReader . xPubBals
    xPubSummary xpub = runInWebReader . xPubSummary xpub
    xPubUnspents xpub xbals = runInWebReader . xPubUnspents xpub xbals
    xPubTxs xpub xbals = runInWebReader . xPubTxs xpub xbals
    xPubTxCount xpub = runInWebReader . xPubTxCount xpub
    getNumTxData = runInWebReader . getNumTxData

instance (MonadUnliftIO m, MonadLoggerIO m) => StoreReadBase (WebT m) where
    getNetwork = lift getNetwork
    getBestBlock = lift getBestBlock
    getBlocksAtHeight = lift . getBlocksAtHeight
    getBlock = lift . getBlock
    getTxData = lift . getTxData
    getSpender = lift . getSpender
    getUnspent = lift . getUnspent
    getBalance = lift . getBalance
    getMempool = lift getMempool

instance (MonadUnliftIO m, MonadLoggerIO m) => StoreReadExtra (WebT m) where
    getBalances = lift . getBalances
    getAddressesTxs as = lift . getAddressesTxs as
    getAddressesUnspents as = lift . getAddressesUnspents as
    xPubBals = lift . xPubBals
    xPubSummary xpub = lift . xPubSummary xpub
    xPubUnspents xpub xbals = lift . xPubUnspents xpub xbals
    xPubTxs xpub xbals = lift . xPubTxs xpub xbals
    xPubTxCount xpub = lift . xPubTxCount xpub
    getMaxGap = lift getMaxGap
    getInitialGap = lift getInitialGap
    getNumTxData = lift . getNumTxData

-------------------
-- Path Handlers --
-------------------

runWeb :: (MonadUnliftIO m, MonadLoggerIO m) => WebConfig -> m ()
runWeb cfg@WebConfig{ webHost = host
                    , webPort = port
                    , webStore = store
                    , webStats = stats
                    , webPriceGet = pget
                    } = do
    ticker <- newTVarIO HashMap.empty
    metrics <- mapM createMetrics stats
    let st = WebState
             { webConfig = cfg
             , webTicker = ticker
             , webMetrics = metrics
             }
        net = storeNetwork store
    withAsync (price net pget ticker) $ \_ -> do
        reqLogger <- logIt metrics
        runner <- askRunInIO
        S.scottyOptsT opts (runner . (`runReaderT` st)) $ do
            S.middleware reqLogger
            S.middleware reqSizeLimit
            S.defaultHandler defHandler
            handlePaths
            S.notFound $ raise_ ThingNotFound
  where
    opts = def {S.settings = settings defaultSettings}
    settings = setPort port . setHost (fromString host)

getRates :: (MonadUnliftIO m, MonadLoggerIO m)
         => Network -> Text -> [Word64] -> m [BinfoRate]
getRates net currency times = do
    handleAny err $ do
        r <- liftIO $ Wreq.asJSON =<< Wreq.postWith opts url body
        return $ r ^. Wreq.responseBody
  where
    err e = do
        $(logErrorS) "Web" "Could not get historic prices"
        return []
    body = toJSON times
    base = Wreq.defaults &
           Wreq.param "base" .~ [T.toUpper (T.pack (getNetworkName net))]
    opts = base & Wreq.param "quote" .~ [currency]
    url = "https://api.blockchain.info/price/index-series"

price :: (MonadUnliftIO m, MonadLoggerIO m)
      => Network
      -> Int
      -> TVar (HashMap Text BinfoTicker)
      -> m ()
price net pget v =
    case code of
        Nothing -> return ()
        Just s  -> go s
  where
    code | net == btc = Just "btc"
         | net == bch = Just "bch"
         | otherwise = Nothing
    go s = forever $ do
        let err e = $(logErrorS) "Price" $ cs (show e)
            url = "https://api.blockchain.info/ticker" <> "?" <>
                  "base" <> "=" <> s
        handleAny err $ do
            r <- liftIO $ Wreq.asJSON =<< Wreq.get url
            atomically . writeTVar v $ r ^. Wreq.responseBody
        threadDelay pget

raise_ :: MonadIO m => Except -> WebT m a
raise_ err =
    lift (asks webMetrics) >>= \case
    Nothing -> S.raise err
    Just metrics -> do
        let status = errStatus err
        if | statusIsClientError status ->
                 liftIO $ addClientError (everyStat metrics)
           | statusIsServerError status ->
                 liftIO $ addServerError (everyStat metrics)
           | otherwise ->
                 return ()
        S.raise err

raise :: MonadIO m => (WebMetrics -> StatDist) -> Except -> WebT m a
raise metric err =
    lift (asks webMetrics) >>= \case
    Nothing -> S.raise err
    Just metrics -> do
        let status = errStatus err
        if | statusIsClientError status ->
                 liftIO $ do
                 addClientError (everyStat metrics)
                 addClientError (metric metrics)
           | statusIsServerError status ->
                 liftIO $ do
                 addServerError (everyStat metrics)
                 addServerError (metric metrics)
           | otherwise ->
                 return ()
        S.raise err

errStatus :: Except -> Status
errStatus ThingNotFound     = status404
errStatus BadRequest        = status400
errStatus UserError{}       = status400
errStatus StringError{}     = status400
errStatus ServerError       = status500
errStatus TxIndexConflict{} = status409
errStatus ServerTimeout     = status500

defHandler :: Monad m => Except -> WebT m ()
defHandler e = do
    setHeaders
    S.status $ errStatus e
    S.json e

handlePaths :: (MonadUnliftIO m, MonadLoggerIO m)
            => S.ScottyT Except (ReaderT WebState m) ()
handlePaths = do
    -- Block Paths
    pathCompact
        (GetBlock <$> paramLazy <*> paramDef)
        scottyBlock
        blockDataToEncoding
        blockDataToJSON
    pathCompact
        (GetBlocks <$> param <*> paramDef)
        (fmap SerialList . scottyBlocks)
        (\n -> list (blockDataToEncoding n) . getSerialList)
        (\n -> json_list blockDataToJSON  n . getSerialList)
    pathCompact
        (GetBlockRaw <$> paramLazy)
        scottyBlockRaw
        (const toEncoding)
        (const toJSON)
    pathCompact
        (GetBlockBest <$> paramDef)
        scottyBlockBest
        blockDataToEncoding
        blockDataToJSON
    pathCompact
        (GetBlockBestRaw & return)
        scottyBlockBestRaw
        (const toEncoding)
        (const toJSON)
    pathCompact
        (GetBlockLatest <$> paramDef)
        (fmap SerialList . scottyBlockLatest)
        (\n -> list (blockDataToEncoding n) . getSerialList)
        (\n -> json_list blockDataToJSON n . getSerialList)
    pathCompact
        (GetBlockHeight <$> paramLazy <*> paramDef)
        (fmap SerialList . scottyBlockHeight)
        (\n -> list (blockDataToEncoding n) . getSerialList)
        (\n -> json_list blockDataToJSON n . getSerialList)
    pathCompact
        (GetBlockHeights <$> param <*> paramDef)
        (fmap SerialList . scottyBlockHeights)
        (\n -> list (blockDataToEncoding n) . getSerialList)
        (\n -> json_list blockDataToJSON n . getSerialList)
    pathCompact
        (GetBlockHeightRaw <$> paramLazy)
        scottyBlockHeightRaw
        (const toEncoding)
        (const toJSON)
    pathCompact
        (GetBlockTime <$> paramLazy <*> paramDef)
        scottyBlockTime
        blockDataToEncoding
        blockDataToJSON
    pathCompact
        (GetBlockTimeRaw <$> paramLazy)
        scottyBlockTimeRaw
        (const toEncoding)
        (const toJSON)
    pathCompact
        (GetBlockMTP <$> paramLazy <*> paramDef)
        scottyBlockMTP
        blockDataToEncoding
        blockDataToJSON
    pathCompact
        (GetBlockMTPRaw <$> paramLazy)
        scottyBlockMTPRaw
        (const toEncoding)
        (const toJSON)
    -- Transaction Paths
    pathCompact
        (GetTx <$> paramLazy)
        scottyTx
        transactionToEncoding
        transactionToJSON
    pathCompact
        (GetTxs <$> param)
        (fmap SerialList . scottyTxs)
        (\n -> list (transactionToEncoding n) . getSerialList)
        (\n -> json_list transactionToJSON n . getSerialList)
    pathCompact
        (GetTxRaw <$> paramLazy)
        scottyTxRaw
        (const toEncoding)
        (const toJSON)
    pathCompact
        (GetTxsRaw <$> param)
        scottyTxsRaw
        (const toEncoding)
        (const toJSON)
    pathCompact
        (GetTxsBlock <$> paramLazy)
        (fmap SerialList . scottyTxsBlock)
        (\n -> list (transactionToEncoding n) . getSerialList)
        (\n -> json_list transactionToJSON n . getSerialList)
    pathCompact
        (GetTxsBlockRaw <$> paramLazy)
        scottyTxsBlockRaw
        (const toEncoding)
        (const toJSON)
    pathCompact
        (GetTxAfter <$> paramLazy <*> paramLazy)
        scottyTxAfter
        (const toEncoding)
        (const toJSON)
    pathCompact
        (PostTx <$> parseBody)
        scottyPostTx
        (const toEncoding)
        (const toJSON)
    pathCompact
        (GetMempool <$> paramOptional <*> parseOffset)
        (fmap SerialList . scottyMempool)
        (const toEncoding)
        (const toJSON)
    -- Address Paths
    pathCompact
        (GetAddrTxs <$> paramLazy <*> parseLimits)
        (fmap SerialList . scottyAddrTxs)
        (const toEncoding)
        (const toJSON)
    pathCompact
        (GetAddrsTxs <$> param <*> parseLimits)
        (fmap SerialList . scottyAddrsTxs)
        (const toEncoding)
        (const toJSON)
    pathCompact
        (GetAddrTxsFull <$> paramLazy <*> parseLimits)
        (fmap SerialList . scottyAddrTxsFull)
        (\n -> list (transactionToEncoding n) . getSerialList)
        (\n -> json_list transactionToJSON n . getSerialList)
    pathCompact
        (GetAddrsTxsFull <$> param <*> parseLimits)
        (fmap SerialList . scottyAddrsTxsFull)
        (\n -> list (transactionToEncoding n) . getSerialList)
        (\n -> json_list transactionToJSON n . getSerialList)
    pathCompact
        (GetAddrBalance <$> paramLazy)
        scottyAddrBalance
        balanceToEncoding
        balanceToJSON
    pathCompact
        (GetAddrsBalance <$> param)
        (fmap SerialList . scottyAddrsBalance)
        (\n -> list (balanceToEncoding n) . getSerialList)
        (\n -> json_list balanceToJSON n . getSerialList)
    pathCompact
        (GetAddrUnspent <$> paramLazy <*> parseLimits)
        (fmap SerialList . scottyAddrUnspent)
        (\n -> list (unspentToEncoding n) . getSerialList)
        (\n -> json_list unspentToJSON n . getSerialList)
    pathCompact
        (GetAddrsUnspent <$> param <*> parseLimits)
        (fmap SerialList . scottyAddrsUnspent)
        (\n -> list (unspentToEncoding n) . getSerialList)
        (\n -> json_list unspentToJSON n . getSerialList)
    -- XPubs
    pathCompact
        (GetXPub <$> paramLazy <*> paramDef <*> paramDef)
        scottyXPub
        (const toEncoding)
        (const toJSON)
    pathCompact
        (GetXPubTxs <$> paramLazy <*> paramDef <*> parseLimits <*> paramDef)
        (fmap SerialList . scottyXPubTxs)
        (const toEncoding)
        (const toJSON)
    pathCompact
        (GetXPubTxsFull <$> paramLazy <*> paramDef <*> parseLimits <*> paramDef)
        (fmap SerialList . scottyXPubTxsFull)
        (\n -> list (transactionToEncoding n) . getSerialList)
        (\n -> json_list transactionToJSON n . getSerialList)
    pathCompact
        (GetXPubBalances <$> paramLazy <*> paramDef <*> paramDef)
        (fmap SerialList . scottyXPubBalances)
        (\n -> list (xPubBalToEncoding n) . getSerialList)
        (\n -> json_list xPubBalToJSON n . getSerialList)
    pathCompact
        (GetXPubUnspent <$> paramLazy <*> paramDef <*> parseLimits <*> paramDef)
        (fmap SerialList . scottyXPubUnspent)
        (\n -> list (xPubUnspentToEncoding n) . getSerialList)
        (\n -> json_list xPubUnspentToJSON n . getSerialList)
    -- Network
    pathCompact
        (GetPeers & return)
        (fmap SerialList . scottyPeers)
        (const toEncoding)
        (const toJSON)
    pathCompact
         (GetHealth & return)
         scottyHealth
         (const toEncoding)
         (const toJSON)
    S.get "/events" scottyEvents
    S.get "/dbstats" scottyDbStats
    -- Blockchain.info
    S.post "/blockchain/multiaddr" scottyMultiAddr
    S.get  "/blockchain/multiaddr" scottyMultiAddr
    S.get  "/blockchain/balance" scottyShortBal
    S.post "/blockchain/balance" scottyShortBal
    S.get  "/blockchain/rawaddr/:addr" scottyRawAddr
    S.post "/blockchain/unspent" scottyBinfoUnspent
    S.get  "/blockchain/unspent" scottyBinfoUnspent
    S.get  "/blockchain/rawtx/:txid" scottyBinfoTx
    S.get  "/blockchain/rawblock/:block" scottyBinfoBlock
    S.get  "/blockchain/latestblock" scottyBinfoLatest
    S.get  "/blockchain/unconfirmed-transactions" scottyBinfoMempool
    S.get  "/blockchain/block-height/:height" scottyBinfoBlockHeight
    S.get  "/blockchain/blocks/:milliseconds" scottyBinfoBlocksDay
    S.get  "/blockchain/export-history" scottyBinfoHistory
    S.post "/blockchain/export-history" scottyBinfoHistory
  where
    json_list f net = toJSONList . map (f net)

pathPretty ::
       (ApiResource a b, MonadIO m)
    => WebT m a
    -> (a -> WebT m b)
    -> (Network -> b -> Encoding)
    -> (Network -> b -> Value)
    -> S.ScottyT Except (ReaderT WebState m) ()
pathPretty parser action encJson encValue =
    pathCommon parser action encJson encValue True

pathCompact ::
       (ApiResource a b, MonadIO m)
    => WebT m a
    -> (a -> WebT m b)
    -> (Network -> b -> Encoding)
    -> (Network -> b -> Value)
    -> S.ScottyT Except (ReaderT WebState m) ()
pathCompact parser action encJson encValue =
    pathCommon parser action encJson encValue False

pathCommon ::
       (ApiResource a b, MonadIO m)
    => WebT m a
    -> (a -> WebT m b)
    -> (Network -> b -> Encoding)
    -> (Network -> b -> Value)
    -> Bool
    -> S.ScottyT Except (ReaderT WebState m) ()
pathCommon parser action encJson encValue pretty =
    S.addroute (resourceMethod proxy) (capturePath proxy) $ do
        setHeaders
        proto <- setupContentType pretty
        net <- lift $ asks (storeNetwork . webStore . webConfig)
        apiRes <- parser
        res <- action apiRes
        S.raw $ protoSerial proto (encJson net) (encValue net) res
  where
    toProxy :: WebT m a -> Proxy a
    toProxy = const Proxy
    proxy = toProxy parser

streamEncoding :: Monad m => Encoding -> WebT m ()
streamEncoding e = do
   S.setHeader "Content-Type" "application/json; charset=utf-8"
   S.raw (encodingToLazyByteString e)

protoSerial
    :: Serial a
    => SerialAs
    -> (a -> Encoding)
    -> (a -> Value)
    -> a
    -> L.ByteString
protoSerial SerialAsBinary _ _     = runPutL . serialize
protoSerial SerialAsJSON f _       = encodingToLazyByteString . f
protoSerial SerialAsPrettyJSON _ g =
    encodePretty' defConfig {confTrailingNewline = True} . g

setHeaders :: (Monad m, S.ScottyError e) => ActionT e m ()
setHeaders = S.setHeader "Access-Control-Allow-Origin" "*"

waiExcept :: Status -> Except -> Response
waiExcept s e =
    responseLBS s hs e'
  where
    hs = [ ("Access-Control-Allow-Origin", "*")
         , ("Content-Type", "application/json")
         ]
    e' = A.encode e


setupJSON :: Monad m => Bool -> ActionT Except m SerialAs
setupJSON pretty = do
    S.setHeader "Content-Type" "application/json"
    p <- S.param "pretty" `S.rescue` const (return pretty)
    return $ if p then SerialAsPrettyJSON else SerialAsJSON

setupBinary :: Monad m => ActionT Except m SerialAs
setupBinary = do
    S.setHeader "Content-Type" "application/octet-stream"
    return SerialAsBinary

setupContentType :: Monad m => Bool -> ActionT Except m SerialAs
setupContentType pretty = do
    accept <- S.header "accept"
    maybe (setupJSON pretty) setType accept
  where
    setType "application/octet-stream" = setupBinary
    setType _                          = setupJSON pretty

-- GET Block / GET Blocks --

scottyBlock ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetBlock -> WebT m BlockData
scottyBlock (GetBlock h (NoTx noTx)) = do
    setMetrics blockStat 1
    getBlock h >>= maybe
        (raise blockStat ThingNotFound)
        (return . pruneTx noTx)

getBlocks :: (MonadUnliftIO m, MonadLoggerIO m)
          => [H.BlockHash]
          -> Bool
          -> WebT m [BlockData]
getBlocks hs notx =
    (pruneTx notx <$>) . catMaybes <$> mapM getBlock (nub hs)

scottyBlocks ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetBlocks -> WebT m [BlockData]
scottyBlocks (GetBlocks hs (NoTx notx)) = do
    setMetrics blockStat (length hs)
    getBlocks hs notx

pruneTx :: Bool -> BlockData -> BlockData
pruneTx False b = b
pruneTx True b  = b {blockDataTxs = take 1 (blockDataTxs b)}

-- GET BlockRaw --

scottyBlockRaw :: (MonadUnliftIO m, MonadLoggerIO m)
               => GetBlockRaw -> WebT m (RawResult H.Block)
scottyBlockRaw (GetBlockRaw h) = do
    setMetrics rawBlockStat 1
    RawResult <$> getRawBlock h

getRawBlock :: (MonadUnliftIO m, MonadLoggerIO m)
            => H.BlockHash -> WebT m H.Block
getRawBlock h = do
    b <- getBlock h >>= maybe
        (raise rawBlockStat ThingNotFound)
        return
    lift (toRawBlock b)

toRawBlock :: (MonadUnliftIO m, StoreReadBase m) => BlockData -> m H.Block
toRawBlock b = do
    let ths = blockDataTxs b
    txs <- mapM f ths
    return H.Block {H.blockHeader = blockDataHeader b, H.blockTxns = txs}
  where
    f x = withRunInIO $ \run ->
          unsafeInterleaveIO . run $
          getTransaction x >>= \case
              Nothing -> undefined
              Just t  -> return $ transactionData t

-- GET BlockBest / BlockBestRaw --

scottyBlockBest ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetBlockBest -> WebT m BlockData
scottyBlockBest (GetBlockBest (NoTx notx)) = do
    setMetrics blockStat 1
    getBestBlock >>= \case
        Nothing -> raise blockStat ThingNotFound
        Just bb -> getBlock bb >>= \case
            Nothing -> raise blockStat ThingNotFound
            Just b  -> return $ pruneTx notx b

scottyBlockBestRaw ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => GetBlockBestRaw
    -> WebT m (RawResult H.Block)
scottyBlockBestRaw _ = do
    setMetrics rawBlockStat 1
    bb <- getBestBlock
    RawResult <$> maybe
        (raise rawBlockStat ThingNotFound)
        getRawBlock
        bb

-- GET BlockLatest --

scottyBlockLatest ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => GetBlockLatest
    -> WebT m [BlockData]
scottyBlockLatest (GetBlockLatest (NoTx noTx)) = do
    setMetrics blockStat 100
    getBestBlock >>= maybe
        (raise blockStat ThingNotFound)
        (go [] <=< getBlock)
  where
    go acc Nothing = return acc
    go acc (Just b)
        | blockDataHeight b <= 0 = return acc
        | length acc == 99 = return (b:acc)
        | otherwise = do
            let prev = H.prevBlock (blockDataHeader b)
            go (pruneTx noTx b : acc) =<< getBlock prev

-- GET BlockHeight / BlockHeights / BlockHeightRaw --

scottyBlockHeight ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetBlockHeight -> WebT m [BlockData]
scottyBlockHeight (GetBlockHeight h (NoTx notx)) = do
    setMetrics blockStat 1
    (`getBlocks` notx) =<< getBlocksAtHeight (fromIntegral h)

scottyBlockHeights ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => GetBlockHeights
    -> WebT m [BlockData]
scottyBlockHeights (GetBlockHeights (HeightsParam heights) (NoTx notx)) = do
    setMetrics blockStat (length heights)
    bhs <- concat <$> mapM getBlocksAtHeight (fromIntegral <$> heights)
    getBlocks bhs notx

scottyBlockHeightRaw ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => GetBlockHeightRaw
    -> WebT m (RawResultList H.Block)
scottyBlockHeightRaw (GetBlockHeightRaw h) = do
    setMetrics rawBlockStat 1
    RawResultList <$> (mapM getRawBlock =<< getBlocksAtHeight (fromIntegral h))

-- GET BlockTime / BlockTimeRaw --

scottyBlockTime :: (MonadUnliftIO m, MonadLoggerIO m)
                => GetBlockTime -> WebT m BlockData
scottyBlockTime (GetBlockTime (TimeParam t) (NoTx notx)) = do
    setMetrics blockStat 1
    ch <- lift $ asks (storeChain . webStore . webConfig)
    m <- blockAtOrBefore ch t
    maybe (raise blockStat ThingNotFound) (return . pruneTx notx) m

scottyBlockMTP :: (MonadUnliftIO m, MonadLoggerIO m)
               => GetBlockMTP -> WebT m BlockData
scottyBlockMTP (GetBlockMTP (TimeParam t) (NoTx noTx)) = do
    setMetrics blockStat 1
    ch <- lift $ asks (storeChain . webStore . webConfig)
    m <- blockAtOrAfterMTP ch t
    maybe (raise blockStat ThingNotFound) (return . pruneTx noTx) m

scottyBlockTimeRaw :: (MonadUnliftIO m, MonadLoggerIO m)
                   => GetBlockTimeRaw -> WebT m (RawResult H.Block)
scottyBlockTimeRaw (GetBlockTimeRaw (TimeParam t)) = do
    setMetrics rawBlockStat 1
    ch <- lift $ asks (storeChain . webStore . webConfig)
    m <- blockAtOrBefore ch t
    b <- maybe (raise rawBlockStat ThingNotFound) return m
    RawResult <$> lift (toRawBlock b)

scottyBlockMTPRaw :: (MonadUnliftIO m, MonadLoggerIO m)
                  => GetBlockMTPRaw -> WebT m (RawResult H.Block)
scottyBlockMTPRaw (GetBlockMTPRaw (TimeParam t)) = do
    setMetrics rawBlockStat 1
    ch <- lift $ asks (storeChain . webStore . webConfig)
    m <- blockAtOrAfterMTP ch t
    b <- maybe (raise rawBlockStat ThingNotFound) return m
    RawResult <$> lift (toRawBlock b)

-- GET Transactions --

scottyTx :: (MonadUnliftIO m, MonadLoggerIO m) => GetTx -> WebT m Transaction
scottyTx (GetTx txid) = do
    setMetrics txStat 1
    maybe (raise txStat ThingNotFound) return =<< getTransaction txid

scottyTxs ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetTxs -> WebT m [Transaction]
scottyTxs (GetTxs txids) = do
    setMetrics txStat (length txids)
    catMaybes <$> mapM f (nub txids)
  where
    f x = lift $ withRunInIO $ \run ->
        unsafeInterleaveIO . run $
        getTransaction x

scottyTxRaw ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetTxRaw -> WebT m (RawResult Tx)
scottyTxRaw (GetTxRaw txid) = do
    setMetrics txStat 1
    tx <- maybe (raise txStat ThingNotFound) return =<< getTransaction txid
    return $ RawResult $ transactionData tx

scottyTxsRaw ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => GetTxsRaw
    -> WebT m (RawResultList Tx)
scottyTxsRaw (GetTxsRaw txids) = do
    setMetrics txStat (length txids)
    txs <- catMaybes <$> mapM f (nub txids)
    return $ RawResultList $ transactionData <$> txs
  where
    f x = lift $ withRunInIO $ \run ->
          unsafeInterleaveIO . run $
          getTransaction x

getTxsBlock :: (MonadUnliftIO m, MonadLoggerIO m)
            => H.BlockHash
            -> WebT m [Transaction]
getTxsBlock h = do
    b <- maybe (raise txsBlockStat ThingNotFound) return =<< getBlock h
    mapM f (blockDataTxs b)
  where
    f x = lift $ withRunInIO $ \run ->
          unsafeInterleaveIO . run $
          getTransaction x >>= \case
              Nothing -> undefined
              Just t  -> return t

scottyTxsBlock ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetTxsBlock -> WebT m [Transaction]
scottyTxsBlock (GetTxsBlock h) =
    setMetrics txsBlockStat 1 >> getTxsBlock h

scottyTxsBlockRaw ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => GetTxsBlockRaw
    -> WebT m (RawResultList Tx)
scottyTxsBlockRaw (GetTxsBlockRaw h) = do
    setMetrics txsBlockStat 1
    RawResultList . fmap transactionData <$> getTxsBlock h

-- GET TransactionAfterHeight --

scottyTxAfter ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => GetTxAfter
    -> WebT m (GenericResult (Maybe Bool))
scottyTxAfter (GetTxAfter txid height) = do
    setMetrics txAfterStat 1
    GenericResult <$> cbAfterHeight (fromIntegral height) txid

-- | Check if any of the ancestors of this transaction is a coinbase after the
-- specified height. Returns 'Nothing' if answer cannot be computed before
-- hitting limits.
cbAfterHeight ::
       (MonadIO m, StoreReadBase m)
    => H.BlockHeight
    -> TxHash
    -> m (Maybe Bool)
cbAfterHeight height txid =
    inputs 10000 HashSet.empty HashSet.empty [txid]
  where
    inputs 0 _ _ [] = return Nothing
    inputs i is ns [] =
        let is' = HashSet.union is ns
            ns' = HashSet.empty
            ts = HashSet.toList (HashSet.difference ns is)
        in case ts of
               [] -> return (Just False)
               _  -> inputs i is' ns' ts
    inputs i is ns (t:ts) = getTransaction t >>= \case
        Nothing -> return Nothing
        Just tx | height_check tx ->
                      if cb_check tx
                      then return (Just True)
                      else let ns' = HashSet.union (ins tx) ns
                          in inputs (i - 1) is ns' ts
                | otherwise -> inputs (i - 1) is ns ts
    cb_check = any isCoinbase . transactionInputs
    ins = HashSet.fromList . map (outPointHash . inputPoint) . transactionInputs
    height_check tx =
        case transactionBlock tx of
            BlockRef h _ -> h > height
            _            -> True

-- POST Transaction --

scottyPostTx :: (MonadUnliftIO m, MonadLoggerIO m) => PostTx -> WebT m TxId
scottyPostTx (PostTx tx) = do
    setMetrics postTxStat 1
    lift (asks webConfig) >>= \cfg -> lift (publishTx cfg tx) >>= \case
        Right ()             -> return $ TxId (txHash tx)
        Left e@(PubReject _) -> raise postTxStat $ UserError $ show e
        _                    -> raise postTxStat ServerError

-- | Publish a new transaction to the network.
publishTx ::
       (MonadUnliftIO m, MonadLoggerIO m, StoreReadBase m)
    => WebConfig
    -> Tx
    -> m (Either PubExcept ())
publishTx cfg tx =
    withSubscription pub $ \s ->
        getTransaction (txHash tx) >>= \case
            Just _  -> return $ Right ()
            Nothing -> go s
  where
    pub = storePublisher (webStore cfg)
    mgr = storeManager (webStore cfg)
    net = storeNetwork (webStore cfg)
    go s =
        getPeers mgr >>= \case
            [] -> return $ Left PubNoPeers
            OnlinePeer {onlinePeerMailbox = p}:_ -> do
                MTx tx `sendMessage` p
                let v =
                        if getSegWit net
                            then InvWitnessTx
                            else InvTx
                sendMessage
                    (MGetData (GetData [InvVector v (getTxHash (txHash tx))]))
                    p
                f p s
    t = 5 * 1000 * 1000
    f p s
      | webNoMempool cfg = return $ Right ()
      | otherwise =
        liftIO (timeout t (g p s)) >>= \case
            Nothing         -> return $ Left PubTimeout
            Just (Left e)   -> return $ Left e
            Just (Right ()) -> return $ Right ()
    g p s =
        receive s >>= \case
            StoreTxReject p' h' c _
                | p == p' && h' == txHash tx -> return . Left $ PubReject c
            StorePeerDisconnected p'
                | p == p' -> return $ Left PubPeerDisconnected
            StoreMempoolNew h'
                | h' == txHash tx -> return $ Right ()
            _ -> g p s

-- GET Mempool / Events --

scottyMempool ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetMempool -> WebT m [TxHash]
scottyMempool (GetMempool limitM (OffsetParam o)) = do
    setMetrics mempoolStat 1
    wl <- lift $ asks (webMaxLimits . webConfig)
    let wl' = wl { maxLimitCount = 0 }
        l = Limits (validateLimit wl' False limitM) (fromIntegral o) Nothing
    map snd . applyLimits l <$> getMempool

scottyEvents :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyEvents =
    withGaugeIncrease eventsConnected $ do
    setHeaders
    proto <- setupContentType False
    pub <- lift $ asks (storePublisher . webStore . webConfig)
    S.stream $ \io flush' ->
        withSubscription pub $ \sub ->
            forever $
            flush' >> receiveEvent sub >>= maybe (return ()) (io . serial proto)
  where
    serial proto e =
        lazyByteString $ protoSerial proto toEncoding toJSON e <> newLine proto
    newLine SerialAsBinary     = mempty
    newLine SerialAsJSON       = "\n"
    newLine SerialAsPrettyJSON = mempty

receiveEvent :: Inbox StoreEvent -> IO (Maybe Event)
receiveEvent sub = do
    se <- receive sub
    return $
        case se of
            StoreBestBlock b  -> Just (EventBlock b)
            StoreMempoolNew t -> Just (EventTx t)
            _                 -> Nothing

-- GET Address Transactions --

scottyAddrTxs ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetAddrTxs -> WebT m [TxRef]
scottyAddrTxs (GetAddrTxs addr pLimits) = do
    setMetrics addrTxStat 1
    getAddressTxs addr =<< paramToLimits False pLimits

scottyAddrsTxs ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetAddrsTxs -> WebT m [TxRef]
scottyAddrsTxs (GetAddrsTxs addrs pLimits) = do
    setMetrics addrTxStat (length addrs)
    getAddressesTxs addrs =<< paramToLimits False pLimits

scottyAddrTxsFull ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => GetAddrTxsFull
    -> WebT m [Transaction]
scottyAddrTxsFull (GetAddrTxsFull addr pLimits) = do
    setMetrics addrTxFullStat 1
    txs <- getAddressTxs addr =<< paramToLimits True pLimits
    catMaybes <$> mapM (getTransaction . txRefHash) txs

scottyAddrsTxsFull :: (MonadUnliftIO m, MonadLoggerIO m)
                   => GetAddrsTxsFull -> WebT m [Transaction]
scottyAddrsTxsFull (GetAddrsTxsFull addrs pLimits) = do
    setMetrics addrTxFullStat (length addrs)
    txs <- getAddressesTxs addrs =<< paramToLimits True pLimits
    catMaybes <$> mapM (getTransaction . txRefHash) txs

scottyAddrBalance :: (MonadUnliftIO m, MonadLoggerIO m)
                  => GetAddrBalance -> WebT m Balance
scottyAddrBalance (GetAddrBalance addr) = do
    setMetrics addrBalanceStat 1
    getDefaultBalance addr

scottyAddrsBalance ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetAddrsBalance -> WebT m [Balance]
scottyAddrsBalance (GetAddrsBalance addrs) = do
    setMetrics addrBalanceStat (length addrs)
    getBalances addrs

scottyAddrUnspent ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetAddrUnspent -> WebT m [Unspent]
scottyAddrUnspent (GetAddrUnspent addr pLimits) = do
    setMetrics addrUnspentStat 1
    getAddressUnspents addr =<< paramToLimits False pLimits

scottyAddrsUnspent ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetAddrsUnspent -> WebT m [Unspent]
scottyAddrsUnspent (GetAddrsUnspent addrs pLimits) = do
    setMetrics addrUnspentStat (length addrs)
    getAddressesUnspents addrs =<< paramToLimits False pLimits

-- GET XPubs --

scottyXPub ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetXPub -> WebT m XPubSummary
scottyXPub (GetXPub xpub deriv (NoCache noCache)) =  do
    setMetrics xPubStat 1
    let xspec = XPubSpec xpub deriv
    xbals <- xPubBals xspec
    lift . runNoCache noCache $ xPubSummary xspec xbals

getXPubTxs :: (MonadUnliftIO m, MonadLoggerIO m)
           => XPubKey -> DeriveType -> LimitsParam -> Bool -> WebT m [TxRef]
getXPubTxs xpub deriv plimits nocache = do
    limits <- paramToLimits False plimits
    let xspec = XPubSpec xpub deriv
    xbals <- xPubBals xspec
    lift . runNoCache nocache $ xPubTxs xspec xbals limits

scottyXPubTxs ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetXPubTxs -> WebT m [TxRef]
scottyXPubTxs (GetXPubTxs xpub deriv plimits (NoCache nocache)) = do
    setMetrics xPubTxStat 1
    getXPubTxs xpub deriv plimits nocache

scottyXPubTxsFull ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => GetXPubTxsFull
    -> WebT m [Transaction]
scottyXPubTxsFull (GetXPubTxsFull xpub deriv plimits (NoCache nocache)) = do
    setMetrics xPubTxFullStat 1
    refs <- getXPubTxs xpub deriv plimits nocache
    txs <- lift . runNoCache nocache $ mapM (getTransaction . txRefHash) refs
    return $ catMaybes txs

scottyXPubBalances ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetXPubBalances -> WebT m [XPubBal]
scottyXPubBalances (GetXPubBalances xpub deriv (NoCache noCache)) = do
    setMetrics xPubStat 1
    filter f <$> lift (runNoCache noCache (xPubBals spec))
  where
    spec = XPubSpec xpub deriv
    f = not . nullBalance . xPubBal

scottyXPubUnspent ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => GetXPubUnspent
    -> WebT m [XPubUnspent]
scottyXPubUnspent (GetXPubUnspent xpub deriv pLimits (NoCache noCache)) = do
    setMetrics xPubUnspentStat 1
    limits <- paramToLimits False pLimits
    let xspec = XPubSpec xpub deriv
    xbals <- xPubBals xspec
    lift . runNoCache noCache $ xPubUnspents xspec xbals limits

---------------------------------------
-- Blockchain.info API Compatibility --
---------------------------------------

netBinfoSymbol :: Network -> BinfoSymbol
netBinfoSymbol net
  | net == btc =
        BinfoSymbol{ getBinfoSymbolCode = "BTC"
                   , getBinfoSymbolString = "BTC"
                   , getBinfoSymbolName = "Bitcoin"
                   , getBinfoSymbolConversion = 100 * 1000 * 1000
                   , getBinfoSymbolAfter = True
                   , getBinfoSymbolLocal = False
                   }
  | net == bch =
        BinfoSymbol{ getBinfoSymbolCode = "BCH"
                   , getBinfoSymbolString = "BCH"
                   , getBinfoSymbolName = "Bitcoin Cash"
                   , getBinfoSymbolConversion = 100 * 1000 * 1000
                   , getBinfoSymbolAfter = True
                   , getBinfoSymbolLocal = False
                   }
  | otherwise =
        BinfoSymbol{ getBinfoSymbolCode = "XTS"
                   , getBinfoSymbolString = "¤"
                   , getBinfoSymbolName = "Test"
                   , getBinfoSymbolConversion = 100 * 1000 * 1000
                   , getBinfoSymbolAfter = False
                   , getBinfoSymbolLocal = False
                   }

binfoTickerToSymbol :: Text -> BinfoTicker -> BinfoSymbol
binfoTickerToSymbol code BinfoTicker{..} =
    BinfoSymbol{ getBinfoSymbolCode = code
               , getBinfoSymbolString = binfoTickerSymbol
               , getBinfoSymbolName = name
               , getBinfoSymbolConversion =
                       100 * 1000 * 1000 / binfoTicker15m -- sat/usd
               , getBinfoSymbolAfter = False
               , getBinfoSymbolLocal = True
               }
  where
    name = case code of
        "EUR" -> "Euro"
        "USD" -> "U.S. dollar"
        "GBP" -> "British pound"
        x     -> x

getBinfoAddrsParam :: MonadIO m
                   => (WebMetrics -> StatDist)
                   -> Text
                   -> WebT m (HashSet BinfoAddr)
getBinfoAddrsParam metric name = do
    net <- lift (asks (storeNetwork . webStore . webConfig))
    p <- S.param (cs name) `S.rescue` const (return "")
    case parseBinfoAddr net p of
        Nothing -> raise metric (UserError "invalid active address")
        Just xs -> return $ HashSet.fromList xs

getBinfoActive :: MonadIO m
               => (WebMetrics -> StatDist)
               -> WebT m (HashMap XPubKey XPubSpec, HashSet Address)
getBinfoActive metric = do
    active <- getBinfoAddrsParam metric "active"
    p2sh <- getBinfoAddrsParam metric "activeP2SH"
    bech32 <- getBinfoAddrsParam metric "activeBech32"
    let xspec d b = (\x -> (x, XPubSpec x d)) <$> xpub b
        xspecs = HashMap.fromList $ concat
                 [ mapMaybe (xspec DeriveNormal) (HashSet.toList active)
                 , mapMaybe (xspec DeriveP2SH) (HashSet.toList p2sh)
                 , mapMaybe (xspec DeriveP2WPKH) (HashSet.toList bech32)
                 ]
        addrs = HashSet.fromList . mapMaybe addr $ HashSet.toList active
    return (xspecs, addrs)
  where
    addr (BinfoAddr a) = Just a
    addr (BinfoXpub x) = Nothing
    xpub (BinfoXpub x) = Just x
    xpub (BinfoAddr _) = Nothing

getNumTxId :: MonadIO m => WebT m Bool
getNumTxId = fmap not $ S.param "txidindex" `S.rescue` const (return False)

getChainHeight :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m H.BlockHeight
getChainHeight = do
    ch <- lift $ asks (storeChain . webStore . webConfig)
    fmap H.nodeHeight $ chainGetBest ch

scottyBinfoUnspent :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoUnspent =
    getBinfoActive unspentStat >>= \(xspecs, addrs) ->
    getNumTxId >>= \numtxid ->
    get_limit >>= \limit ->
    get_min_conf >>= \min_conf -> do
    let len = HashSet.size addrs + HashMap.size xspecs
    setMetrics unspentStat len
    net <- lift $ asks (storeNetwork . webStore . webConfig)
    height <- getChainHeight
    let mn BinfoUnspent{..} = min_conf > getBinfoUnspentConfirmations
        xspecs' = HashSet.fromList $ HashMap.elems xspecs
    bus <- lift . runConduit $
           getBinfoUnspents numtxid height xspecs' addrs .|
           (dropWhileC mn >> takeC limit .| sinkList)
    setHeaders
    streamEncoding (binfoUnspentsToEncoding net (BinfoUnspents bus))
  where
    get_limit = fmap (min 1000) $ S.param "limit" `S.rescue` const (return 250)
    get_min_conf = S.param "confirmations" `S.rescue` const (return 0)

getBinfoUnspents :: (StoreReadExtra m, MonadIO m)
                 => Bool
                 -> H.BlockHeight
                 -> HashSet XPubSpec
                 -> HashSet Address
                 -> ConduitT () BinfoUnspent m ()
getBinfoUnspents numtxid height xspecs addrs = do
    cs <- conduits
    joinDescStreams cs .| mapC (uncurry binfo)
  where
    binfo Unspent{..} xp =
        let conf = case unspentBlock of
                       MemRef{}     -> 0
                       BlockRef h _ -> height - h + 1
            hash = outPointHash unspentPoint
            idx = outPointIndex unspentPoint
            val = unspentAmount
            script = unspentScript
            txi = encodeBinfoTxId numtxid hash
        in BinfoUnspent
           { getBinfoUnspentHash = hash
           , getBinfoUnspentOutputIndex = idx
           , getBinfoUnspentScript = script
           , getBinfoUnspentValue = val
           , getBinfoUnspentConfirmations = fromIntegral conf
           , getBinfoUnspentTxIndex = txi
           , getBinfoUnspentXPub = xp
           }
    point_hash = outPointHash . unspentPoint
    conduits = (<>) <$> xconduits <*> pure acounduits
    xconduits = lift $ do
        let f x (XPubUnspent u p) =
                let path = toSoft (listToPath p)
                    xp = BinfoXPubPath (xPubSpecKey x) <$> path
                in (u, xp)
            g x = do
                bs <- xPubBals x
                return $
                    streamThings
                    (xPubUnspents x bs)
                    Nothing
                    def{limit = 250} .|
                    mapC (f x)
        mapM g (HashSet.toList xspecs)
    acounduits =
        let f u = (u, Nothing)
            g a = streamThings
                  (getAddressUnspents a)
                  Nothing
                  def{limit = 250} .|
                  mapC f
        in map g (HashSet.toList addrs)

getBinfoTxs :: (StoreReadExtra m, MonadIO m)
            => HashMap Address (Maybe BinfoXPubPath) -- address book
            -> HashSet XPubSpec -- show xpubs
            -> HashSet Address -- show addrs
            -> HashSet Address -- balance addresses
            -> BinfoFilter
            -> Bool -- numtxid
            -> Bool -- prune outputs
            -> Int64 -- starting balance
            -> ConduitT () BinfoTx m ()
getBinfoTxs abook sxspecs saddrs baddrs bfilter numtxid prune bal = do
    cs <- conduits
    joinDescStreams cs .| go bal
  where
    sxspecs_ls = HashSet.toList sxspecs
    saddrs_ls = HashSet.toList saddrs
    conduits = (<>) <$> mapM xpub_c sxspecs_ls <*> pure (map addr_c saddrs_ls)
    xpub_c x = lift $ do
        bs <- xPubBals x
        return $ streamThings (xPubTxs x bs) (Just txRefHash) def{limit = 50}
    addr_c a = streamThings (getAddressTxs a) (Just txRefHash) def{limit = 50}
    binfo_tx b = toBinfoTx numtxid abook prune b
    compute_bal_change BinfoTx{..} =
        let ins = mapMaybe getBinfoTxInputPrevOut getBinfoTxInputs
            out = getBinfoTxOutputs
            f b BinfoTxOutput{..} =
                let val = fromIntegral getBinfoTxOutputValue
                in case getBinfoTxOutputAddress of
                       Nothing -> 0
                       Just a | a `HashSet.member` baddrs ->
                                    if b then val else negate val
                              | otherwise -> 0
        in sum $ map (f False) ins <> map (f True) out
    go b = await >>= \case
        Nothing -> return ()
        Just (TxRef _ t) -> lift (getTransaction t) >>= \case
            Nothing -> go b
            Just x -> do
                let a = binfo_tx b x
                    b' = b - compute_bal_change a
                    c = isJust (getBinfoTxBlockHeight a)
                    Just (d, _) = getBinfoTxResultBal a
                    r = d + fromIntegral (getBinfoTxFee a)
                case bfilter of
                    BinfoFilterAll ->
                        yield a >> go b'
                    BinfoFilterSent
                        | 0 > r -> yield a >> go b'
                        | otherwise -> go b'
                    BinfoFilterReceived
                        | r > 0 -> yield a >> go b'
                        | otherwise -> go b'
                    BinfoFilterMoved
                        | r == 0 -> yield a >> go b'
                        | otherwise -> go b'
                    BinfoFilterConfirmed
                        | c -> yield a >> go b'
                        | otherwise -> go b'
                    BinfoFilterMempool
                        | c -> return ()
                        | otherwise -> yield a >> go b'

getCashAddr :: Monad m => WebT m Bool
getCashAddr = S.param "cashaddr" `S.rescue` const (return False)

scottyBinfoHistory :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoHistory =
    getBinfoActive historyStat >>= \(xspecs, addrs) ->
    get_dates >>= \(startM, endM) -> do
    setMetrics historyStat (HashSet.size addrs + HashMap.size xspecs)
    (code, price) <- getPrice
    xpubs <- mapM (\x -> (,) x <$> xPubBals x) (HashMap.elems xspecs)
    let xaddrs = HashSet.fromList $ concatMap (map get_addr . snd) xpubs
        aaddrs = xaddrs <> addrs
        cur = binfoTicker15m price
        cs = conduits xpubs addrs endM
    txs <- lift . runConduit $
        joinDescStreams cs
        .| takeWhileC (is_newer startM)
        .| concatMapMC get_transaction
        .| sinkList
    let times = map transactionTime txs
    net <- lift $ asks (storeNetwork . webStore . webConfig)
    rates <- map binfoRatePrice <$> lift (getRates net code times)
    let hs = zipWith (convert cur aaddrs) txs (rates <> repeat 0.0)
    setHeaders
    streamEncoding $ toEncoding hs
  where
    is_newer (Just BlockData{..}) TxRef{txRefBlock = BlockRef{..}} =
        blockRefHeight >= blockDataHeight
    is_newer _ _ = True
    get_addr = balanceAddress . xPubBal
    get_transaction TxRef{txRefHash = h, txRefBlock = BlockRef{..}} =
        getTransaction h
    convert cur addrs tx rate =
        let ins = transactionInputs tx
            outs = transactionOutputs tx
            fins = filter (input_addr addrs) ins
            fouts = filter (output_addr addrs) outs
            vin = fromIntegral . sum $ map inputAmount fins
            vout = fromIntegral . sum $ map outputAmount fouts
            v = vout - vin
            t = transactionTime tx
            h = txHash $ transactionData tx
        in toBinfoHistory v t rate cur h
    input_addr addrs' StoreInput{inputAddress = Just a} =
        a `HashSet.member` addrs'
    input_addr _ _ = False
    output_addr addrs' StoreOutput{outputAddr = Just a} =
        a `HashSet.member` addrs'
    output_addr _ _ = False
    get_dates = do
        BinfoDate start <- S.param "start"
        BinfoDate end' <- S.param "end"
        let end = end' + 24 * 60 * 60
        ch <- lift $ asks (storeChain . webStore . webConfig)
        startM <- blockAtOrAfter ch start
        endM <- blockAtOrBefore ch end
        return (startM, endM)
    conduits xpubs addrs endM =
        map (uncurry (xpub_c endM)) xpubs
        <>
        map (addr_c endM) (HashSet.toList addrs)
    addr_c endM a =
        streamThings (getAddressTxs a)
        (Just txRefHash)
        def{ limit = 50
           , start = AtBlock . blockDataHeight <$> endM
           }
    xpub_c endM x bs =
        streamThings
        (xPubTxs x bs)
        (Just txRefHash)
        def{ limit = 50
           , start = AtBlock . blockDataHeight <$> endM
           }

getPrice :: MonadIO m => WebT m (Text, BinfoTicker)
getPrice = do
    code <- T.toUpper <$> S.param "currency" `S.rescue` const (return "USD")
    ticker <- lift $ asks webTicker
    prices <- readTVarIO ticker
    case HashMap.lookup code prices of
        Nothing -> return (code, def)
        Just p  -> return (code, p)

getSymbol :: MonadIO m => WebT m BinfoSymbol
getSymbol = uncurry binfoTickerToSymbol <$> getPrice

scottyBinfoBlocksDay :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoBlocksDay = do
    setMetrics blockStat 144
    t <- min h . (`div` 1000) <$> S.param "milliseconds"
    ch <- lift $ asks (storeChain . webStore . webConfig)
    m <- blockAtOrBefore ch t
    bs <- go (d t) m
    streamEncoding $ toEncoding $ map toBinfoBlockInfo bs
  where
    h = fromIntegral (maxBound :: H.Timestamp)
    d = subtract (24 * 3600)
    go _ Nothing = return []
    go t (Just b)
        | H.blockTimestamp (blockDataHeader b) <= fromIntegral t =
              return []
        | otherwise = do
              b' <- getBlock (H.prevBlock (blockDataHeader b))
              (b :) <$> go t b'


scottyMultiAddr :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyMultiAddr = do
    setMetrics multiaddrStat 1
    (addrs', xpubs, saddrs, sxpubs, xspecs) <- get_addrs
    numtxid <- getNumTxId
    cashaddr <- getCashAddr
    local <- getSymbol
    offset <- getBinfoOffset multiaddrStat
    n <- getBinfoCount
    prune <- get_prune
    fltr <- get_filter
    let len = HashSet.size addrs' + HashSet.size xpubs
    xbals <- get_xbals xspecs
    xtxns <- get_xpub_tx_count xbals xspecs
    let sxbals = subset sxpubs xbals
        xabals = compute_xabals xbals
        addrs = addrs' `HashSet.difference` HashMap.keysSet xabals
    abals <- get_abals addrs
    let sxspecs = compute_sxspecs sxpubs xspecs
        sxabals = compute_xabals sxbals
        sabals = subset saddrs abals
        sallbals = sabals <> sxabals
        sbal = compute_bal sallbals
        allbals = abals <> xabals
        abook = compute_abook addrs xbals
        sxaddrs = compute_xaddrs sxbals
        salladdrs = saddrs <> sxaddrs
        bal = compute_bal allbals
    let ibal = fromIntegral sbal
    ftxs <-
        lift . runConduit $
        getBinfoTxs abook sxspecs saddrs salladdrs fltr numtxid prune ibal .|
        (dropC offset >> takeC n .| sinkList)
    best <- get_best_block
    peers <- get_peers
    net <- lift $ asks (storeNetwork . webStore . webConfig)
    let baddrs = toBinfoAddrs sabals sxbals xtxns
        abaddrs = toBinfoAddrs abals xbals xtxns
        recv = sum $ map getBinfoAddrReceived abaddrs
        sent = sum $ map getBinfoAddrSent abaddrs
        txn = fromIntegral $ length ftxs
        wallet =
            BinfoWallet
            { getBinfoWalletBalance = bal
            , getBinfoWalletTxCount = txn
            , getBinfoWalletFilteredCount = txn
            , getBinfoWalletTotalReceived = recv
            , getBinfoWalletTotalSent = sent
            }
        coin = netBinfoSymbol net
        block =
            BinfoBlockInfo
            { getBinfoBlockInfoHash = H.headerHash (blockDataHeader best)
            , getBinfoBlockInfoHeight = blockDataHeight best
            , getBinfoBlockInfoTime = H.blockTimestamp (blockDataHeader best)
            , getBinfoBlockInfoIndex = blockDataHeight best
            }
        info =
            BinfoInfo
            { getBinfoConnected = peers
            , getBinfoConversion = 100 * 1000 * 1000
            , getBinfoLocal = local
            , getBinfoBTC = coin
            , getBinfoLatestBlock = block
            }
    setHeaders
    streamEncoding $ binfoMultiAddrToEncoding net
        BinfoMultiAddr
        { getBinfoMultiAddrAddresses = baddrs
        , getBinfoMultiAddrWallet = wallet
        , getBinfoMultiAddrTxs = ftxs
        , getBinfoMultiAddrInfo = info
        , getBinfoMultiAddrRecommendFee = True
        , getBinfoMultiAddrCashAddr = cashaddr
        }
  where
    get_xpub_tx_count xbals =
        let f (k, s) =
                case HashMap.lookup k xbals of
                    Nothing -> return (k, 0)
                    Just bs -> do
                        n <- xPubTxCount s bs
                        return (k, fromIntegral n)
        in fmap HashMap.fromList . mapM f . HashMap.toList
    get_filter = S.param "filter" `S.rescue` const (return BinfoFilterAll)
    get_best_block =
        getBestBlock >>= \case
        Nothing -> raise multiaddrStat ThingNotFound
        Just bh -> getBlock bh >>= \case
            Nothing -> raise multiaddrStat ThingNotFound
            Just b  -> return b
    get_price ticker = do
        code <- T.toUpper <$> S.param "currency" `S.rescue` const (return "USD")
        prices <- readTVarIO ticker
        case HashMap.lookup code prices of
            Nothing -> return def
            Just p  -> return $ binfoTickerToSymbol code p
    get_prune = fmap not $ S.param "no_compact"
        `S.rescue` const (return False)
    subset ks =
        HashMap.filterWithKey (\k _ -> k `HashSet.member` ks)
    compute_sxspecs sxpubs =
        HashSet.fromList . HashMap.elems . subset sxpubs
    addr (BinfoAddr a) = Just a
    addr (BinfoXpub x) = Nothing
    xpub (BinfoXpub x) = Just x
    xpub (BinfoAddr _) = Nothing
    get_addrs = do
        (xspecs, addrs) <- getBinfoActive multiaddrStat
        sh <- getBinfoAddrsParam multiaddrStat "onlyShow"
        let xpubs = HashMap.keysSet xspecs
            actives = HashSet.map BinfoAddr addrs <>
                      HashSet.map BinfoXpub xpubs
            sh' = if HashSet.null sh then actives else sh
            saddrs = HashSet.fromList . mapMaybe addr $ HashSet.toList sh'
            sxpubs = HashSet.fromList . mapMaybe xpub $ HashSet.toList sh'
        return (addrs, xpubs, saddrs, sxpubs, xspecs)
    get_xbals =
        let f = not . nullBalance . xPubBal
            g = HashMap.fromList . map (second (filter f))
            h (k, s) = (,) k <$> xPubBals s
        in fmap g . mapM h . HashMap.toList
    get_abals =
        let f b = (balanceAddress b, b)
            g = HashMap.fromList . map f
        in fmap g . getBalances . HashSet.toList
    addr_in_set s t =
        let f StoreCoinbase{}                    = False
            f StoreInput{inputAddress = Nothing} = False
            f StoreInput{inputAddress = Just a}  = a `HashSet.member` s
            g StoreOutput{outputAddr = m} = case m of
                Nothing -> False
                Just a  -> a `HashSet.member` s
            i = any f (transactionInputs t)
            o = any g (transactionOutputs t)
        in i || o
    get_peers = do
        ps <- lift $ getPeersInformation =<<
            asks (storeManager . webStore . webConfig)
        return (fromIntegral (length ps))
    compute_txids = map txRefHash . Set.toDescList
    compute_etxids prune abook =
        let f = relevantTxs (HashMap.keysSet abook) prune
        in HashSet.toList . foldl HashSet.union HashSet.empty . map f
    compute_xabals =
        let f b = (balanceAddress (xPubBal b), xPubBal b)
        in HashMap.fromList . concatMap (map f) . HashMap.elems
    compute_bal =
        let f b = balanceAmount b + balanceZero b
        in sum . map f . HashMap.elems
    compute_abook addrs xbals =
        let f k XPubBal{..} =
                let a = balanceAddress xPubBal
                    e = error "lions and tigers and bears"
                    s = toSoft (listToPath xPubBalPath)
                    m = fromMaybe e s
                in (a, Just (BinfoXPubPath k m))
            g k = map (f k)
            amap = HashMap.map (const Nothing) $
                   HashSet.toMap addrs
            xmap = HashMap.fromList .
                   concatMap (uncurry g) $
                   HashMap.toList xbals
        in amap <> xmap
    compute_xaddrs =
        let f = map (balanceAddress . xPubBal)
        in HashSet.fromList . concatMap f . HashMap.elems
    sent BinfoTx{getBinfoTxResultBal = Just (r, _)}
      | r < 0 = fromIntegral (negate r)
      | otherwise = 0
    sent _ = 0
    received BinfoTx{getBinfoTxResultBal = Just (r, _)}
      | r > 0 = fromIntegral r
      | otherwise = 0
    received _ = 0

getBinfoCount :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m Int
getBinfoCount = do
        d <- lift (asks (maxLimitDefault . webMaxLimits . webConfig))
        x <- lift (asks (maxLimitFull . webMaxLimits . webConfig))
        i <- min x <$> (S.param "n" `S.rescue` const (return d))
        return (fromIntegral i :: Int)

getBinfoOffset :: (MonadUnliftIO m, MonadLoggerIO m)
               => (WebMetrics -> StatDist)
               -> WebT m Int
getBinfoOffset stat = do
        x <- lift (asks (maxLimitOffset . webMaxLimits . webConfig))
        o <- S.param "offset" `S.rescue` const (return 0)
        when (o > x) $
            raise stat $
            UserError $ "offset exceeded: " <> show o <> " > " <> show x
        return (fromIntegral o :: Int)

scottyRawAddr :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyRawAddr = do
    setMetrics rawaddrStat 1
    addr <- get_addr
    numtxid <- getNumTxId
    n <- getBinfoCount
    off <- getBinfoOffset rawaddrStat
    bal <- fromMaybe (zeroBalance addr) <$> getBalance addr
    net <- lift $ asks (storeNetwork . webStore . webConfig)
    let abook = HashMap.singleton addr Nothing
        xspecs = HashSet.empty
        saddrs = HashSet.singleton addr
        bfilter = BinfoFilterAll
        b = fromIntegral $ balanceAmount bal + balanceZero bal
    txs <- lift . runConduit $
        getBinfoTxs abook xspecs saddrs saddrs bfilter numtxid False b .|
        (dropC off >> takeC n .| sinkList)
    setHeaders
    streamEncoding $ binfoRawAddrToEncoding net $ BinfoRawAddr bal txs
  where
    get_addr = do
        txt <- S.param "addr"
        net <- lift $ asks (storeNetwork . webStore . webConfig)
        case textToAddr net txt of
            Nothing -> raise rawaddrStat ThingNotFound
            Just a  -> return a

scottyShortBal :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyShortBal =
    getBinfoActive balanceStat >>= \(xspecs, addrs) ->
    getCashAddr >>= \cashaddr ->
    getNumTxId >>= \numtxid -> do
    setMetrics balanceStat (HashSet.size addrs + HashMap.size xspecs)
    net <- lift $ asks (storeNetwork . webStore . webConfig)
    abals <- catMaybes <$>
             mapM (get_addr_balance net cashaddr) (HashSet.toList addrs)
    xbals <- mapM (get_xspec_balance net) (HashMap.elems xspecs)
    let res = HashMap.fromList (abals <> xbals)
    setHeaders
    streamEncoding $ toEncoding res
  where
    to_short_bal Balance{..} =
        BinfoShortBal
        {
            binfoShortBalFinal = balanceAmount + balanceZero,
            binfoShortBalTxCount = balanceTxCount,
            binfoShortBalReceived = balanceTotalReceived
        }
    get_addr_balance net cashaddr a =
        let net' = if | cashaddr       -> net
                      | net == bch     -> btc
                      | net == bchTest -> btcTest
                      | otherwise      -> net
        in case addrToText net' a of
               Nothing -> return Nothing
               Just a' -> getBalance a >>= \case
                   Nothing -> return $ Just (a', to_short_bal (zeroBalance a))
                   Just b  -> return $ Just (a', to_short_bal b)
    is_ext XPubBal{xPubBalPath = 0:_} = True
    is_ext _                          = False
    get_xspec_balance net xpub = do
        xbals <- xPubBals xpub
        xts <- xPubTxCount xpub xbals
        let val = sum $ map balanceAmount $ map xPubBal xbals
            zro = sum $ map balanceZero $ map xPubBal xbals
            exs = filter is_ext xbals
            rcv = sum $ map balanceTotalReceived $ map xPubBal exs
            sbl =
                BinfoShortBal
                {
                    binfoShortBalFinal = val + zro,
                    binfoShortBalTxCount = fromIntegral xts,
                    binfoShortBalReceived = rcv
                }
        return (xPubExport net (xPubSpecKey xpub), sbl)

getBinfoHex :: Monad m => WebT m Bool
getBinfoHex =
    (== ("hex" :: Text)) <$>
    S.param "format" `S.rescue` const (return "json")

scottyBinfoBlockHeight :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoBlockHeight =
    getNumTxId >>= \numtxid ->
    S.param "height" >>= \height ->
    setMetrics rawBlockStat 1 >>
    getBlocksAtHeight height >>= \block_hashes -> do
    block_headers <- catMaybes <$> mapM getBlock block_hashes
    next_block_hashes <- getBlocksAtHeight (height + 1)
    next_block_headers <- catMaybes <$> mapM getBlock next_block_hashes
    binfo_blocks <-
        mapM (get_binfo_blocks numtxid next_block_headers) block_headers
    setHeaders
    net <- lift $ asks (storeNetwork . webStore . webConfig)
    streamEncoding $ binfoBlocksToEncoding net binfo_blocks
  where
    get_tx th =
        withRunInIO $ \run ->
        unsafeInterleaveIO $
        run $ fromJust <$> getTransaction th
    get_binfo_blocks numtxid next_block_headers block_header = do
        let my_hash = H.headerHash (blockDataHeader block_header)
            get_prev = H.prevBlock . blockDataHeader
            get_hash = H.headerHash . blockDataHeader
        txs <- lift $ mapM get_tx (blockDataTxs block_header)
        let next_blocks = map get_hash $
                          filter ((== my_hash) . get_prev)
                          next_block_headers
        let binfo_txs = map (toBinfoTxSimple numtxid) txs
            binfo_block = toBinfoBlock block_header binfo_txs next_blocks
        return binfo_block

scottyBinfoLatest :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoLatest = do
    numtxid <- getNumTxId
    setMetrics blockStat 1
    best <- get_best_block
    let binfoTxIndices = map (encodeBinfoTxId numtxid) (blockDataTxs best)
        binfoHeaderHash = H.headerHash (blockDataHeader best)
        binfoHeaderTime = H.blockTimestamp (blockDataHeader best)
        binfoHeaderIndex = binfoHeaderTime
        binfoHeaderHeight = blockDataHeight best
    streamEncoding $ toEncoding BinfoHeader{..}
  where
    get_best_block =
        getBestBlock >>= \case
        Nothing -> raise blockStat ThingNotFound
        Just bh -> getBlock bh >>= \case
            Nothing -> raise blockStat ThingNotFound
            Just b  -> return b

scottyBinfoBlock :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoBlock =
    getNumTxId >>= \numtxid ->
    getBinfoHex >>= \hex ->
    setMetrics rawBlockStat 1 >>
    S.param "block" >>= \case
    BinfoBlockHash bh -> go numtxid hex bh
    BinfoBlockIndex i ->
        getBlocksAtHeight i >>= \case
        []   -> raise rawBlockStat ThingNotFound
        bh:_ -> go numtxid hex bh
  where
    get_tx th =
        withRunInIO $ \run ->
        unsafeInterleaveIO $
        run $ fromJust <$> getTransaction th
    go numtxid hex bh =
        getBlock bh >>= \case
        Nothing -> raise rawBlockStat ThingNotFound
        Just b -> do
            txs <- lift $ mapM get_tx (blockDataTxs b)
            let my_hash = H.headerHash (blockDataHeader b)
                get_prev = H.prevBlock . blockDataHeader
                get_hash = H.headerHash . blockDataHeader
            nxt_headers <-
                fmap catMaybes $
                mapM getBlock =<<
                getBlocksAtHeight (blockDataHeight b + 1)
            let nxt = map get_hash $
                      filter ((== my_hash) . get_prev)
                      nxt_headers
            if hex
              then do
                let x = H.Block (blockDataHeader b) (map transactionData txs)
                setHeaders
                S.text . encodeHexLazy . runPutL $ serialize x
              else do
                let btxs = map (toBinfoTxSimple numtxid) txs
                    y = toBinfoBlock b btxs nxt
                setHeaders
                net <- lift $ asks (storeNetwork . webStore . webConfig)
                streamEncoding $ binfoBlockToEncoding net y

scottyBinfoTx :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoTx =
    getNumTxId >>= \numtxid ->
    getBinfoHex >>= \hex ->
    S.param "txid" >>= \txid ->
    setMetrics rawtxStat 1 >>
    let f (BinfoTxIdHash h)  = maybeToList <$> getTransaction h
        f (BinfoTxIdIndex i) = getNumTransaction i
    in f txid >>= \case
        [] -> raise rawtxStat ThingNotFound
        [t] -> if hex then hx t else js numtxid t
        ts ->
            let tids = map (txHash . transactionData) ts
            in raise rawtxStat (TxIndexConflict tids)
  where
    js numtxid t = do
        net <- lift $ asks (storeNetwork . webStore . webConfig)
        setHeaders
        streamEncoding $ binfoTxToEncoding net $ toBinfoTxSimple numtxid t
    hx t = do
        setHeaders
        S.text . encodeHexLazy . runPutL . serialize $ transactionData t

scottyBinfoMempool :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyBinfoMempool = do
    setMetrics mempoolStat 1
    numtxid <- getNumTxId
    offset <- getBinfoOffset mempoolStat
    n <- getBinfoCount
    mempool <- getMempool
    let txids = map snd $ take n $ drop offset mempool
    txs <- catMaybes <$> mapM getTransaction txids
    net <- lift $ asks (storeNetwork . webStore . webConfig)
    setHeaders
    let mem = BinfoMempool $ map (toBinfoTxSimple numtxid) txs
    streamEncoding $ binfoMempoolToEncoding net mem

-- GET Network Information --

scottyPeers :: (MonadUnliftIO m, MonadLoggerIO m)
            => GetPeers
            -> WebT m [PeerInformation]
scottyPeers _ = do
    setMetrics peerStat 1
    lift $ getPeersInformation =<< asks (storeManager . webStore . webConfig)

-- | Obtain information about connected peers from peer manager process.
getPeersInformation
    :: MonadLoggerIO m => PeerManager -> m [PeerInformation]
getPeersInformation mgr =
    mapMaybe toInfo <$> getPeers mgr
  where
    toInfo op = do
        ver <- onlinePeerVersion op
        let as = onlinePeerAddress op
            ua = getVarString $ userAgent ver
            vs = version ver
            sv = services ver
            rl = relay ver
        return
            PeerInformation
                { peerUserAgent = ua
                , peerAddress = show as
                , peerVersion = vs
                , peerServices = sv
                , peerRelay = rl
                }

scottyHealth ::
       (MonadUnliftIO m, MonadLoggerIO m) => GetHealth -> WebT m HealthCheck
scottyHealth _ = do
    setMetrics healthStat 1
    h <- lift $ asks webConfig >>= healthCheck
    unless (isOK h) $ S.status status503
    return h

blockHealthCheck :: (MonadUnliftIO m, MonadLoggerIO m, StoreReadBase m)
                 => WebConfig -> m BlockHealth
blockHealthCheck cfg = do
    let ch = storeChain $ webStore cfg
        blockHealthMaxDiff = fromIntegral $ webMaxDiff cfg
    blockHealthHeaders <-
        H.nodeHeight <$> chainGetBest ch
    blockHealthBlocks <-
        maybe 0 blockDataHeight <$>
        runMaybeT (MaybeT getBestBlock >>= MaybeT . getBlock)
    return BlockHealth {..}

lastBlockHealthCheck :: (MonadUnliftIO m, MonadLoggerIO m, StoreReadBase m)
                     => Chain -> WebTimeouts -> m TimeHealth
lastBlockHealthCheck ch tos = do
    n <- fromIntegral . systemSeconds <$> liftIO getSystemTime
    t <- fromIntegral . H.blockTimestamp . H.nodeHeader <$> chainGetBest ch
    let timeHealthAge = n - t
        timeHealthMax = fromIntegral $ blockTimeout tos
    return TimeHealth {..}

lastTxHealthCheck :: (MonadUnliftIO m, MonadLoggerIO m, StoreReadBase m)
                  => WebConfig -> m TimeHealth
lastTxHealthCheck WebConfig {..} = do
    n <- fromIntegral . systemSeconds <$> liftIO getSystemTime
    b <- fromIntegral . H.blockTimestamp . H.nodeHeader <$> chainGetBest ch
    t <- listToMaybe <$> getMempool >>= \case
        Just t -> let x = fromIntegral $ fst t
                  in return $ max x b
        Nothing -> return b
    let timeHealthAge = n - t
        timeHealthMax = fromIntegral to
    return TimeHealth {..}
  where
    ch = storeChain webStore
    to = if webNoMempool then blockTimeout webTimeouts else txTimeout webTimeouts

pendingTxsHealthCheck :: (MonadUnliftIO m, MonadLoggerIO m, StoreReadBase m)
                      => WebConfig -> m MaxHealth
pendingTxsHealthCheck cfg = do
    let maxHealthMax = fromIntegral $ webMaxPending cfg
    maxHealthNum <-
        fromIntegral <$>
        blockStorePendingTxs (storeBlock (webStore cfg))
    return MaxHealth {..}

peerHealthCheck :: (MonadUnliftIO m, MonadLoggerIO m, StoreReadBase m)
                => PeerManager -> m CountHealth
peerHealthCheck mgr = do
    let countHealthMin = 1
    countHealthNum <- fromIntegral . length <$> getPeers mgr
    return CountHealth {..}

healthCheck :: (MonadUnliftIO m, MonadLoggerIO m, StoreReadBase m)
            => WebConfig -> m HealthCheck
healthCheck cfg@WebConfig {..} = do
    healthBlocks     <- blockHealthCheck cfg
    healthLastBlock  <- lastBlockHealthCheck (storeChain webStore) webTimeouts
    healthLastTx     <- lastTxHealthCheck cfg
    healthPendingTxs <- pendingTxsHealthCheck cfg
    healthPeers      <- peerHealthCheck (storeManager webStore)
    let healthNetwork = getNetworkName (storeNetwork webStore)
        healthVersion = webVersion
        hc = HealthCheck {..}
    unless (isOK hc) $ do
        let t = toStrict $ encodeToLazyText hc
        $(logErrorS) "Web" $ "Health check failed: " <> t
    return hc

scottyDbStats :: (MonadUnliftIO m, MonadLoggerIO m) => WebT m ()
scottyDbStats = do
    setMetrics dbStatsStat 1
    setHeaders
    db <- lift $ asks (databaseHandle . storeDB . webStore . webConfig)
    statsM <- lift (getProperty db Stats)
    S.text $ maybe "Could not get stats" cs statsM

-----------------------
-- Parameter Parsing --
-----------------------

-- | Returns @Nothing@ if the parameter is not supplied. Raises an exception on
-- parse failure.
paramOptional :: (Param a, MonadIO m) => WebT m (Maybe a)
paramOptional = go Proxy
  where
    go :: (Param a, MonadIO m) => Proxy a -> WebT m (Maybe a)
    go proxy = do
        net <- lift $ asks (storeNetwork . webStore . webConfig)
        tsM :: Maybe [Text] <- p `S.rescue` const (return Nothing)
        case tsM of
            Nothing -> return Nothing -- Parameter was not supplied
            Just ts -> maybe (raise_ err) (return . Just) $ parseParam net ts
      where
        l = proxyLabel proxy
        p = Just <$> S.param (cs l)
        err = UserError $ "Unable to parse param " <> cs l

-- | Raises an exception if the parameter is not supplied
param :: (Param a, MonadIO m) => WebT m a
param = go Proxy
  where
    go :: (Param a, MonadIO m) => Proxy a -> WebT m a
    go proxy = do
        resM <- paramOptional
        case resM of
            Just res -> return res
            _ ->
                raise_ . UserError $
                "The param " <> cs (proxyLabel proxy) <> " was not defined"

-- | Returns the default value of a parameter if it is not supplied. Raises an
-- exception on parse failure.
paramDef :: (Default a, Param a, MonadIO m) => WebT m a
paramDef = fromMaybe def <$> paramOptional

-- | Does not raise exceptions. Will call @Scotty.next@ if the parameter is
-- not supplied or if parsing fails.
paramLazy :: (Param a, MonadIO m) => WebT m a
paramLazy = do
    resM <- paramOptional `S.rescue` const (return Nothing)
    maybe S.next return resM

parseBody :: (MonadIO m, Serial a) => WebT m a
parseBody = do
    b <- L.toStrict <$> S.body
    case hex b <> bin b of
        Left _  -> raise_ $ UserError "Failed to parse request body"
        Right x -> return x
  where
    bin = runGetS deserialize
    hex b = case B16.decodeBase16 $ C.filter (not . isSpace) b of
                Right x -> bin x
                Left s  -> Left (T.unpack s)

parseOffset :: MonadIO m => WebT m OffsetParam
parseOffset = do
    res@(OffsetParam o) <- paramDef
    limits <- lift $ asks (webMaxLimits . webConfig)
    when (maxLimitOffset limits > 0 && fromIntegral o > maxLimitOffset limits) $
        raise_ . UserError $
        "offset exceeded: " <> show o <> " > " <> show (maxLimitOffset limits)
    return res

parseStart ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => Maybe StartParam
    -> WebT m (Maybe Start)
parseStart Nothing = return Nothing
parseStart (Just s) =
    runMaybeT $
    case s of
        StartParamHash {startParamHash = h}     -> start_tx h <|> start_block h
        StartParamHeight {startParamHeight = h} -> start_height h
        StartParamTime {startParamTime = q}     -> start_time q
  where
    start_height h = return $ AtBlock $ fromIntegral h
    start_block h = do
        b <- MaybeT $ getBlock (H.BlockHash h)
        return $ AtBlock (blockDataHeight b)
    start_tx h = do
        _ <- MaybeT $ getTxData (TxHash h)
        return $ AtTx (TxHash h)
    start_time q = do
        ch <- lift $ asks (storeChain . webStore . webConfig)
        b <- MaybeT $ blockAtOrBefore ch q
        let g = blockDataHeight b
        return $ AtBlock g

parseLimits :: MonadIO m => WebT m LimitsParam
parseLimits = LimitsParam <$> paramOptional <*> parseOffset <*> paramOptional

paramToLimits ::
       (MonadUnliftIO m, MonadLoggerIO m)
    => Bool
    -> LimitsParam
    -> WebT m Limits
paramToLimits full (LimitsParam limitM o startM) = do
    wl <- lift $ asks (webMaxLimits . webConfig)
    Limits (validateLimit wl full limitM) (fromIntegral o) <$> parseStart startM

validateLimit :: WebLimits -> Bool -> Maybe LimitParam -> Word32
validateLimit wl full limitM =
    f m $ maybe d (fromIntegral . getLimitParam) limitM
  where
    m | full && maxLimitFull wl > 0 = maxLimitFull wl
      | otherwise = maxLimitCount wl
    d = maxLimitDefault wl
    f a 0 = a
    f 0 b = b
    f a b = min a b

---------------
-- Utilities --
---------------

runInWebReader ::
       MonadIO m
    => CacheT (DatabaseReaderT m) a
    -> ReaderT WebState m a
runInWebReader f = do
    bdb <- asks (storeDB . webStore . webConfig)
    mc <- asks (storeCache . webStore . webConfig)
    lift $ runReaderT (withCache mc f) bdb

runNoCache :: MonadIO m => Bool -> ReaderT WebState m a -> ReaderT WebState m a
runNoCache False f = f
runNoCache True f = local g f
  where
    g s = s { webConfig = h (webConfig s) }
    h c = c { webStore = i (webStore c) }
    i s = s { storeCache = Nothing }

logIt :: (MonadUnliftIO m, MonadLoggerIO m)
      => Maybe WebMetrics -> m Middleware
logIt metrics = do
    runner <- askRunInIO
    return $ \app req respond -> do
        var <- newTVarIO B.empty
        req' <-
            let rb = req_body var (getRequestBodyChunk req)
                rq = req{requestBody = rb}
            in case metrics of
                   Nothing -> return rq
                   Just m -> do
                       stat_var <- newTVarIO Nothing
                       item_var <- newTVarIO 0
                       let vt = V.insert (statKey m) stat_var $
                                V.insert (itemsKey m) item_var $
                                vault rq
                       return rq{vault = vt}
        bracket start (end var runner req') $ \t1 ->
            app req' $ \res -> do
                t2 <- systemToUTCTime <$> getSystemTime
                b <- readTVarIO var
                let s = responseStatus res
                    msg = fmtReq b req' <> ": " <> fmtStatus s
                if statusIsSuccessful s
                    then runner $ $(logDebugS) "Web" msg
                    else runner $ $(logErrorS) "Web" msg
                respond res
  where
    start = systemToUTCTime <$> getSystemTime
    req_body var old_body = do
        b <- old_body
        unless (B.null b) . atomically $ modifyTVar var (<> b)
        return b
    add_stat d i s = do
        addStatQuery s
        addStatTime s d
        addStatItems s (fromIntegral i)
    end var runner req t1 = do
        t2 <- systemToUTCTime <$> getSystemTime
        let diff = round $ diffUTCTime t2 t1 * 1000
        case metrics of
            Nothing -> return ()
            Just m -> do
                let m_stat_var = V.lookup (statKey m) (vault req)
                    m_item_var = V.lookup (itemsKey m) (vault req)
                i <- case m_item_var of
                    Nothing       -> return 0
                    Just item_var -> readTVarIO item_var
                add_stat diff i (everyStat m)
                case m_stat_var of
                    Nothing -> return ()
                    Just stat_var ->
                        readTVarIO stat_var >>= \case
                            Nothing -> return ()
                            Just f  -> add_stat diff i (f m)
        when (diff > 10000) $ do
            b <- readTVarIO var
            runner $ $(logWarnS) "Web" $
                "Slow [" <> cs (show diff) <> " ms]: " <> fmtReq b req

reqSizeLimit :: Middleware
reqSizeLimit = requestSizeLimitMiddleware lim
  where
    max_len _req = return (Just (256 * 1024))
    lim = setOnLengthExceeded too_big $
          setMaxLengthForRequest max_len $
          defaultRequestSizeLimitSettings
    too_big w64 = \_app _req send -> send $
        waiExcept requestEntityTooLarge413 RequestTooLarge

fmtReq :: ByteString -> Request -> Text
fmtReq bs req =
    let m = requestMethod req
        v = httpVersion req
        p = rawPathInfo req
        q = rawQueryString req
        txt = case T.decodeUtf8' bs of
                  Left _   -> " {invalid utf8}"
                  Right "" -> ""
                  Right t  -> " [" <> t <> "]"
    in T.decodeUtf8 (m <> " " <> p <> q <> " " <> cs (show v)) <> txt

fmtStatus :: Status -> Text
fmtStatus s = cs (show (statusCode s)) <> " " <> cs (statusMessage s)

