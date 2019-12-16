{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

{-# OPTIONS_GHC -fno-warn-redundant-constraints #-}

-- |
-- Copyright: © 2018-2019 IOHK
-- License: Apache-2.0
--
-- API handlers and server using the underlying wallet layer to provide
-- endpoints reachable through HTTP.

module Cardano.Wallet.Api.Server
    ( Listen (..)
    , ListenError (..)
    , HostPreference
    , start
    , newApiLayer
    , withListeningSocket
    , defaultWorkerAfter
    ) where

import Prelude

import Cardano.BM.Trace
    ( Trace, logError, logNotice )
import Cardano.Pool.Metadata
    ( StakePoolMetadata )
import Cardano.Pool.Metrics
    ( ErrListStakePools (..)
    , ErrMetricsInconsistency (..)
    , StakePool (..)
    , StakePoolLayer (..)
    )
import Cardano.Wallet
    ( ErrAdjustForFee (..)
    , ErrCoinSelection (..)
    , ErrDecodeSignedTx (..)
    , ErrFetchRewards (..)
    , ErrJoinStakePool (..)
    , ErrListTransactions (..)
    , ErrListUTxOStatistics (..)
    , ErrMkTx (..)
    , ErrNoSuchWallet (..)
    , ErrPostTx (..)
    , ErrQuitStakePool (..)
    , ErrRemovePendingTx (..)
    , ErrSelectCoinsExternal (..)
    , ErrSelectForDelegation (..)
    , ErrSelectForPayment (..)
    , ErrSignDelegation (..)
    , ErrSignPayment (..)
    , ErrStartTimeLaterThanEndTime (..)
    , ErrSubmitExternalTx (..)
    , ErrSubmitTx (..)
    , ErrUpdatePassphrase (..)
    , ErrValidateSelection
    , ErrWalletAlreadyExists (..)
    , ErrWithRootKey (..)
    , ErrWrongPassphrase (..)
    , HasGenesisData
    , HasLogger
    , HasNetworkLayer
    , genesisData
    , networkLayer
    )
import Cardano.Wallet.Api
    ( Addresses
    , Api
    , ApiLayer (..)
    , CoinSelections
    , CompatibilityApi
    , CoreApi
    , HasDBFactory
    , HasWorkerRegistry
    , StakePoolApi
    , Transactions
    , Wallets
    , dbFactory
    , workerRegistry
    )
import Cardano.Wallet.Api.Types
    ( AddressAmount (..)
    , ApiAddress (..)
    , ApiBlockReference (..)
    , ApiByronWallet (..)
    , ApiByronWalletBalance (..)
    , ApiByronWalletMigrationInfo (..)
    , ApiCoinSelection (..)
    , ApiCoinSelectionInput (..)
    , ApiEpochInfo (..)
    , ApiErrorCode (..)
    , ApiFee (..)
    , ApiNetworkInformation (..)
    , ApiNetworkTip (..)
    , ApiSelectCoinsData (..)
    , ApiStakePool (..)
    , ApiStakePoolMetrics (..)
    , ApiT (..)
    , ApiTimeReference (..)
    , ApiTransaction (..)
    , ApiTxId (..)
    , ApiTxInput (..)
    , ApiUtxoStatistics (..)
    , ApiWallet (..)
    , ApiWalletPassphrase (..)
    , ByronWalletPostData (..)
    , DecodeAddress (..)
    , EncodeAddress (..)
    , Iso8601Time (..)
    , PostExternalTransactionData (..)
    , PostTransactionData
    , PostTransactionFeeData
    , WalletBalance (..)
    , WalletPostData (..)
    , WalletPutData (..)
    , WalletPutPassphraseData (..)
    , getApiMnemonicT
    )
import Cardano.Wallet.DB
    ( DBFactory )
import Cardano.Wallet.Network
    ( ErrNetworkTip (..), ErrNetworkUnavailable (..), NetworkLayer )
import Cardano.Wallet.Primitive.AddressDerivation
    ( DelegationAddress (..)
    , HardDerivation (..)
    , NetworkDiscriminant (..)
    , PaymentAddress (..)
    , WalletKey (..)
    , digest
    , publicKey
    )
import Cardano.Wallet.Primitive.AddressDerivation.Byron
    ( ByronKey )
import Cardano.Wallet.Primitive.AddressDerivation.Shelley
    ( ShelleyKey (..) )
import Cardano.Wallet.Primitive.AddressDiscovery
    ( IsOurs )
import Cardano.Wallet.Primitive.AddressDiscovery.Random
    ( RndState, mkRndState )
import Cardano.Wallet.Primitive.AddressDiscovery.Sequential
    ( SeqState (..), defaultAddressPoolGap, mkSeqState )
import Cardano.Wallet.Primitive.CoinSelection
    ( CoinSelection (..), changeBalance, feeBalance, inputBalance )
import Cardano.Wallet.Primitive.Model
    ( Wallet, availableBalance, currentTip, getState, totalBalance )
import Cardano.Wallet.Primitive.Types
    ( Address
    , AddressState
    , Block
    , BlockchainParameters
    , ChimericAccount (..)
    , Coin (..)
    , Hash (..)
    , HistogramBar (..)
    , PoolId
    , SortOrder (..)
    , SyncTolerance
    , TransactionInfo (TransactionInfo)
    , Tx (..)
    , TxIn (..)
    , TxOut (..)
    , TxStatus (..)
    , UTxOStatistics (..)
    , UnsignedTx (..)
    , WalletId (..)
    , WalletMetadata (..)
    , WalletName
    , slotAt
    , slotMinBound
    , syncProgressRelativeToTime
    )
import Cardano.Wallet.Registry
    ( HasWorkerCtx (..), MkWorker (..), newWorker, workerResource )
import Cardano.Wallet.Transaction
    ( TransactionLayer )
import Cardano.Wallet.Unsafe
    ( unsafeRunExceptT )
import Control.Arrow
    ( second )
import Control.DeepSeq
    ( NFData )
import Control.Exception
    ( AsyncException (..)
    , IOException
    , SomeException
    , asyncExceptionFromException
    , bracket
    , tryJust
    )
import Control.Monad
    ( forM, forM_, void, when )
import Control.Monad.IO.Class
    ( MonadIO, liftIO )
import Control.Monad.Trans.Except
    ( ExceptT, except, throwE, withExceptT )
import Data.Aeson
    ( (.=) )
import Data.Function
    ( (&) )
import Data.Functor
    ( ($>), (<&>) )
import Data.Generics.Internal.VL.Lens
    ( Lens', (.~), (^.) )
import Data.Generics.Labels
    ()
import Data.List
    ( isInfixOf, isSubsequenceOf, sortOn )
import Data.Maybe
    ( fromMaybe, isJust )
import Data.Proxy
    ( Proxy (..) )
import Data.Quantity
    ( Quantity (..) )
import Data.Set
    ( Set )
import Data.Streaming.Network
    ( HostPreference, bindPortTCP, bindRandomPortTCP )
import Data.Text
    ( Text )
import Data.Text.Class
    ( toText )
import Data.Time
    ( UTCTime )
import Data.Time.Clock
    ( getCurrentTime )
import Data.Word
    ( Word32, Word64 )
import Fmt
    ( Buildable, pretty )
import Network.HTTP.Media.RenderHeader
    ( renderHeader )
import Network.HTTP.Types.Header
    ( hContentType )
import Network.Socket
    ( Socket, close )
import Network.Wai
    ( Request, pathInfo )
import Network.Wai.Handler.Warp
    ( Port )
import Network.Wai.Middleware.Logging
    ( ApiLog (..), newApiLoggerSettings, obfuscateKeys, withApiLogger )
import Network.Wai.Middleware.ServantError
    ( handleRawError )
import Numeric.Natural
    ( Natural )
import Servant
    ( (:<|>) (..)
    , (:>)
    , Application
    , JSON
    , NoContent (..)
    , Server
    , contentType
    , err400
    , err403
    , err404
    , err409
    , err410
    , err500
    , err503
    , serve
    )
import Servant.Server
    ( Handler (..), ServantErr (..) )
import System.IO.Error
    ( ioeGetErrorType
    , isAlreadyInUseError
    , isDoesNotExistError
    , isPermissionError
    , isUserError
    )
import System.Random
    ( getStdRandom, random )

import qualified Cardano.Wallet as W
import qualified Cardano.Wallet.Network as NW
import qualified Cardano.Wallet.Primitive.AddressDerivation.Byron as Rnd
import qualified Cardano.Wallet.Primitive.AddressDerivation.Shelley as Seq
import qualified Cardano.Wallet.Primitive.Types as W
import qualified Cardano.Wallet.Registry as Registry
import qualified Data.Aeson as Aeson
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Network.Wai.Handler.Warp as Warp

-- | How the server should listen for incoming requests.
data Listen
    = ListenOnPort Port
      -- ^ Listen on given TCP port
    | ListenOnRandomPort
      -- ^ Listen on an unused TCP port, selected at random
    deriving (Show, Eq)

-- | Start the application server, using the given settings and a bound socket.
start
    :: forall t (n :: NetworkDiscriminant).
        ( Buildable (ErrValidateSelection t)
        , DecodeAddress n
        , EncodeAddress n
        , DelegationAddress n ShelleyKey
        , PaymentAddress n ByronKey
        )
    => Warp.Settings
    -> Trace IO ApiLog
    -> Socket
    -> ApiLayer (RndState 'Mainnet) t ByronKey
    -> ApiLayer (SeqState n ShelleyKey) t ShelleyKey
    -> StakePoolLayer IO
    -> IO ()
start settings tr socket rndCtx seqCtx spl = do
    logSettings <- newApiLoggerSettings <&> obfuscateKeys (const sensitive)
    Warp.runSettingsSocket settings socket
        $ handleRawError (curry handler)
        $ withApiLogger tr logSettings
        application
  where
    -- | A Servant server for our wallet API
    server :: Server (Api n)
    server = coreApiServer seqCtx
        :<|> compatibilityApiServer @t @n rndCtx seqCtx
        :<|> stakePoolServer seqCtx spl

    application :: Application
    application = serve (Proxy @("v2" :> Api n)) server

    sensitive :: [Text]
    sensitive =
        [ "passphrase"
        , "old_passphrase"
        , "new_passphrase"
        , "mnemonic_sentence"
        , "mnemonic_second_factor"
        ]

-- | Run an action with a TCP socket bound to a port specified by the `Listen`
-- parameter.
withListeningSocket
    :: HostPreference
    -- ^ Which host to bind.
    -> Listen
    -- ^ Whether to listen on a given port, or random port.
    -> (Either ListenError (Port, Socket) -> IO a)
    -- ^ Action to run with listening socket.
    -> IO a
withListeningSocket hostPreference portOpt = bracket acquire release
  where
    acquire = tryJust handleErr $ case portOpt of
        ListenOnPort port -> (port,) <$> bindPortTCP port hostPreference
        ListenOnRandomPort -> bindRandomPortTCP hostPreference
    release (Right (_, socket)) = liftIO $ close socket
    release (Left _) = pure ()
    handleErr = ioToListenError hostPreference portOpt

data ListenError
    = ListenErrorAddressAlreadyInUse (Maybe Port)
    | ListenErrorOperationNotPermitted
    | ListenErrorHostDoesNotExist HostPreference
    | ListenErrorInvalidAddress HostPreference
    deriving (Show, Eq)

ioToListenError :: HostPreference -> Listen -> IOException -> Maybe ListenError
ioToListenError hostPreference portOpt e
    -- A socket is already listening on that address and port
    | isAlreadyInUseError e =
        Just (ListenErrorAddressAlreadyInUse (listenPort portOpt))
    -- Usually caused by trying to listen on a privileged port
    | isPermissionError e =
        Just ListenErrorOperationNotPermitted
    -- Bad hostname -- Linux and Darwin
    | isDoesNotExistError e =
        Just (ListenErrorHostDoesNotExist hostPreference)
    -- Bad hostname (bind: WSAEOPNOTSUPP) -- Windows
    | isUserError e && (hasDescription "11001" || hasDescription "10045") =
        Just (ListenErrorHostDoesNotExist hostPreference)
    -- Address is valid, but can't be used for listening -- Linux
    | show (ioeGetErrorType e) == "invalid argument" =
        Just (ListenErrorInvalidAddress hostPreference)
    -- Address is valid, but can't be used for listening -- Darwin
    | show (ioeGetErrorType e) == "unsupported operation" =
        Just (ListenErrorInvalidAddress hostPreference)
    -- Address is valid, but can't be used for listening -- Windows
    | isOtherError e &&
      (hasDescription "WSAEINVAL" || hasDescription "WSAEADDRNOTAVAIL") =
        Just (ListenErrorInvalidAddress hostPreference)
    -- Listening on an unavailable or privileged port -- Windows
    | isOtherError e && hasDescription "WSAEACCESS" =
        Just (ListenErrorAddressAlreadyInUse (listenPort portOpt))
    | otherwise =
        Nothing
  where
    listenPort (ListenOnPort port) = Just port
    listenPort ListenOnRandomPort = Nothing

    isOtherError ex = show (ioeGetErrorType ex) == "failed"
    hasDescription text = text `isInfixOf` show e

{-------------------------------------------------------------------------------
                                   Core API
-------------------------------------------------------------------------------}

coreApiServer
    :: forall ctx s t k n.
        ( DelegationAddress n k
        , Buildable (ErrValidateSelection t)
        , k ~ ShelleyKey
        , s ~ SeqState n k
        , ctx ~ ApiLayer s t k
        )
    => ctx
    -> Server (CoreApi n)
coreApiServer ctx =
    addresses ctx
    :<|> wallets ctx
    :<|> coinSelections ctx
    :<|> transactions ctx
    :<|> network ctx

stakePoolServer
    :: forall ctx s t n k.
        ( DelegationAddress n k
        , Buildable (ErrValidateSelection t)
        , k ~ ShelleyKey
        , s ~ SeqState n k
        , HardDerivation k
        , ctx ~ ApiLayer s t k
        )
    => ctx
    -> StakePoolLayer IO
    -> Server (StakePoolApi n)
stakePoolServer = stakePools

{-------------------------------------------------------------------------------
                                    Wallets
-------------------------------------------------------------------------------}

wallets
    :: forall ctx s t k n.
        ( DelegationAddress n k
        , k ~ ShelleyKey
        , s ~ SeqState n k
        , ctx ~ ApiLayer s t k
        )
    => ctx
    -> Server Wallets
wallets ctx =
    deleteWallet ctx
    :<|> getWallet ctx
    :<|> listWallets ctx
    :<|> postWallet ctx
    :<|> putWallet ctx
    :<|> putWalletPassphrase ctx
    :<|> getUTxOsStatistics ctx

deleteWallet
    :: forall ctx s t k n.
        ( s ~ SeqState n k
        , ctx ~ ApiLayer s t k
        )
    => ctx
    -> ApiT WalletId
    -> Handler NoContent
deleteWallet ctx (ApiT wid) = do
    liftHandler $ withWorkerCtx @_ @s @k ctx wid throwE $ \_ -> pure ()
    liftIO $ (df ^. #removeDatabase) wid
    liftIO $ Registry.remove re wid
    return NoContent
  where
    re = ctx ^. workerRegistry @s @k
    df = ctx ^. dbFactory @s @k

getWallet
    :: forall ctx s t k n.
        ( s ~ SeqState n k
        , ctx ~ ApiLayer s t k
        , WalletKey k
        )
    => ctx
    -> ApiT WalletId
    -> Handler ApiWallet
getWallet ctx (ApiT wid) =
    fst <$> getWalletWithCreationTime ctx wid

listWallets
    :: forall ctx s t k n.
        ( s ~ SeqState n k
        , ctx ~ ApiLayer s t k
        , WalletKey k
        )
    => ctx
    -> Handler [ApiWallet]
listWallets ctx = do
    wids <- liftIO $ Registry.keys re
    fmap fst . sortOn snd <$>
        mapM (getWalletWithCreationTime ctx) wids
  where
    re = ctx ^. workerRegistry @s @k

postWallet
    :: forall ctx s t k n.
        ( DelegationAddress n k
        , s ~ SeqState n k
        , k ~ ShelleyKey
        , ctx ~ ApiLayer s t k
        , HasDBFactory s k ctx
        , HasWorkerRegistry s k ctx
        )
    => ctx
    -> WalletPostData
    -> Handler ApiWallet
postWallet ctx body = do
    let seed = getApiMnemonicT (body ^. #mnemonicSentence)
    let secondFactor =
            maybe mempty getApiMnemonicT (body ^. #mnemonicSecondFactor)
    let pwd = getApiT (body ^. #passphrase)
    let rootXPrv = Seq.generateKeyFromSeed (seed, secondFactor) pwd
    let g = maybe defaultAddressPoolGap getApiT (body ^. #addressPoolGap)
    let s = mkSeqState (rootXPrv, pwd) g
    let wid = WalletId $ digest $ publicKey rootXPrv
    let wName = getApiT (body ^. #name)
    void $ liftHandler $ createWallet @_ @s @t @k ctx wid wName s
    liftHandler $ withWorkerCtx @_ @s @k ctx wid throwE $ \wrk ->
        W.attachPrivateKey @_ @s @k wrk wid (rootXPrv, pwd)
    getWallet ctx (ApiT wid)

putWallet
    :: forall ctx s t k n.
        ( s ~ SeqState n k
        , ctx ~ ApiLayer s t k
        , WalletKey k
        )
    => ctx
    -> ApiT WalletId
    -> WalletPutData
    -> Handler ApiWallet
putWallet ctx (ApiT wid) body = do
    case body ^. #name of
        Nothing ->
            return ()
        Just (ApiT wName) -> liftHandler $ withWorkerCtx ctx wid throwE $ \wrk ->
            W.updateWallet wrk wid (modify wName)
    getWallet ctx (ApiT wid)
  where
    modify :: W.WalletName -> WalletMetadata -> WalletMetadata
    modify wName meta = meta { name = wName }

putWalletPassphrase
    :: forall ctx s t k n.
        ( WalletKey k
        , s ~ SeqState n k
        , ctx ~ ApiLayer s t k
        )
    => ctx
    -> ApiT WalletId
    -> WalletPutPassphraseData
    -> Handler NoContent
putWalletPassphrase ctx (ApiT wid) body = do
    let (WalletPutPassphraseData (ApiT old) (ApiT new)) = body
    liftHandler $ withWorkerCtx ctx wid liftE $ \wrk ->
        W.updateWalletPassphrase wrk wid (old, new)
    return NoContent
  where
    liftE = throwE . ErrUpdatePassphraseNoSuchWallet

getUTxOsStatistics
    :: forall ctx s t k n.
        ( s ~ SeqState n k
        , ctx ~ ApiLayer s t k
        )
    => ctx
    -> ApiT WalletId
    -> Handler ApiUtxoStatistics
getUTxOsStatistics ctx (ApiT wid) = do
    stats <- liftHandler $ withWorkerCtx ctx wid liftE $ \wrk ->
        W.listUtxoStatistics wrk wid
    let (UTxOStatistics histo totalStakes bType) = stats
    return ApiUtxoStatistics
        { total = Quantity (fromIntegral totalStakes)
        , scale = ApiT bType
        , distribution = Map.fromList $ map (\(HistogramBar k v)-> (k,v)) histo
        }
  where
    liftE = throwE . ErrListUTxOStatisticsNoSuchWallet

{-------------------------------------------------------------------------------
                                  Coin Selections
-------------------------------------------------------------------------------}

coinSelections
    :: forall ctx s t k n.
        ( Buildable (ErrValidateSelection t)
        , DelegationAddress n k
        , k ~ ShelleyKey
        , s ~ SeqState n k
        , ctx ~ ApiLayer s t k
        )
    => ctx
    -> Server (CoinSelections n)
coinSelections =
    selectCoins

selectCoins
    :: forall ctx s t k n.
        ( Buildable (ErrValidateSelection t)
        , DelegationAddress n k
        , k ~ ShelleyKey
        , s ~ SeqState n k
        , ctx ~ ApiLayer s t k
        )
    => ctx
    -> ApiT WalletId
    -> ApiSelectCoinsData n
    -> Handler (ApiCoinSelection n)
selectCoins ctx (ApiT wid) body =
    fmap mkApiCoinSelection
        $ liftHandler
        $ withWorkerCtx ctx wid liftE
        $ \wrk -> W.selectCoinsExternal @_ @s @t @k wrk wid ()
        $ coerceCoin <$> body ^. #payments
  where
    liftE = throwE . ErrSelectCoinsExternalNoSuchWallet

{-------------------------------------------------------------------------------
                                    Addresses
-------------------------------------------------------------------------------}

addresses
    :: forall ctx s t k n.
        ( DelegationAddress n k
        , k ~ ShelleyKey
        , s ~ SeqState n k
        , ctx ~ ApiLayer s t k
        )
    => ctx
    -> Server (Addresses n)
addresses = listAddresses

listAddresses
    :: forall ctx s t k n.
        ( DelegationAddress n k
        , k ~ ShelleyKey
        , s ~ SeqState n k
        , ctx ~ ApiLayer s t k
        )
    => ctx
    -> ApiT WalletId
    -> Maybe (ApiT AddressState)
    -> Handler [ApiAddress n]
listAddresses ctx (ApiT wid) stateFilter = do
    addrs <- liftHandler $ withWorkerCtx ctx wid throwE $ \wrk ->
        W.listAddresses @_ @s @k @n wrk wid
    return $ coerceAddress <$> filter filterCondition addrs
  where
    filterCondition :: (Address, AddressState) -> Bool
    filterCondition = case stateFilter of
        Nothing -> const True
        Just (ApiT s) -> (== s) . snd
    coerceAddress (a, s) = ApiAddress (ApiT a, Proxy @n) (ApiT s)

{-------------------------------------------------------------------------------
                                    Transactions
-------------------------------------------------------------------------------}

transactions
    :: forall ctx s t k n.
        ( DelegationAddress n k
        , Buildable (ErrValidateSelection t)
        , s ~ SeqState n k
        , k ~ ShelleyKey
        , ctx ~ ApiLayer s t k
        )
    => ctx
    -> Server (Transactions n)
transactions ctx =
    postTransaction ctx
    :<|> listTransactions ctx
    :<|> postTransactionFee ctx
    :<|> postExternalTransaction ctx
    :<|> deleteTransaction ctx

postTransaction
    :: forall ctx s t k n.
        ( Buildable (ErrValidateSelection t)
        , DelegationAddress n k
        , k ~ ShelleyKey
        , s ~ SeqState n k
        , ctx ~ ApiLayer s t k
        )
    => ctx
    -> ApiT WalletId
    -> PostTransactionData n
    -> Handler (ApiTransaction n)
postTransaction ctx (ApiT wid) body = do
    let outs = coerceCoin <$> (body ^. #payments)
    let pwd = getApiT $ body ^. #passphrase

    selection <- liftHandler $ withWorkerCtx ctx wid liftE1 $ \wrk ->
        W.selectCoinsForPayment @_ @s @t wrk wid outs

    (tx, meta, time, wit) <- liftHandler $ withWorkerCtx ctx wid liftE2 $ \wrk ->
        W.signPayment @_ @s @t @k wrk wid () pwd selection

    liftHandler $ withWorkerCtx ctx wid liftE3 $ \wrk ->
        W.submitTx @_ @s @t @k wrk wid (tx, meta, wit)

    pure $ mkApiTransaction
        (txId tx)
        (fmap Just <$> selection ^. #inputs)
        (tx ^. #outputs)
        (meta, time)
        #pendingSince
  where
    liftE1 = throwE . ErrSelectForPaymentNoSuchWallet
    liftE2 = throwE . ErrSignPaymentNoSuchWallet
    liftE3 = throwE . ErrSubmitTxNoSuchWallet

postExternalTransaction
    :: forall ctx s t k n.
        ( s ~ SeqState n k
        , ctx ~ ApiLayer s t k
        )
    => ctx
    -> PostExternalTransactionData
    -> Handler ApiTxId
postExternalTransaction ctx (PostExternalTransactionData load) = do
    tx <- liftHandler $ W.submitExternalTx @ctx @t @k ctx load
    return $ ApiTxId (ApiT (txId tx))

deleteTransaction
    :: forall ctx s t k. ctx ~ ApiLayer s t k
    => ctx
    -> ApiT WalletId
    -> ApiTxId
    -> Handler NoContent
deleteTransaction ctx (ApiT wid) (ApiTxId (ApiT (tid))) = do
    liftHandler $ withWorkerCtx ctx wid liftE $ \wrk ->
        W.forgetPendingTx wrk wid tid
    return NoContent
  where
    liftE = throwE . ErrRemovePendingTxNoSuchWallet

listTransactions
    :: forall ctx s t k n. (ctx ~ ApiLayer s t k)
    => ctx
    -> ApiT WalletId
    -> Maybe Iso8601Time
    -> Maybe Iso8601Time
    -> Maybe (ApiT SortOrder)
    -> Handler [ApiTransaction n]
listTransactions ctx (ApiT wid) mStart mEnd mOrder = do
    txs <- liftHandler $ withWorkerCtx ctx wid liftE $ \wrk ->
        W.listTransactions wrk wid
            (getIso8601Time <$> mStart)
            (getIso8601Time <$> mEnd)
            (maybe defaultSortOrder getApiT mOrder)
    return $ map mkApiTransactionFromInfo txs
  where
    liftE = throwE . ErrListTransactionsNoSuchWallet
    defaultSortOrder :: SortOrder
    defaultSortOrder = Descending

    -- Populate an API transaction record with 'TransactionInfo' from the wallet
    -- layer.
    mkApiTransactionFromInfo :: TransactionInfo -> ApiTransaction n
    mkApiTransactionFromInfo (TransactionInfo txid ins outs meta depth txtime) =
        apiTx { depth  }
      where
        apiTx = mkApiTransaction txid ins outs (meta, txtime) $
            case meta ^. #status of
                Pending  -> #pendingSince
                InLedger -> #insertedAt

postTransactionFee
    :: forall ctx s t k n.
        ( Buildable (ErrValidateSelection t)
        , s ~ SeqState n k
        , ctx ~ ApiLayer s t k
        )
    => ctx
    -> ApiT WalletId
    -> PostTransactionFeeData n
    -> Handler ApiFee
postTransactionFee ctx (ApiT wid) body = do
    let outs = coerceCoin <$> (body ^. #payments)
    liftHandler $ withWorkerCtx ctx wid liftE $ \wrk ->
        apiFee <$> W.selectCoinsForPayment @_ @s @t @k wrk wid outs
  where
    apiFee = ApiFee . Quantity . fromIntegral . feeBalance
    liftE = throwE . ErrSelectForPaymentNoSuchWallet

{-------------------------------------------------------------------------------
                                    Stake Pools
-------------------------------------------------------------------------------}

stakePools
    :: forall ctx s t n k.
        ( DelegationAddress n k
        , Buildable (ErrValidateSelection t)
        , k ~ ShelleyKey
        , s ~ SeqState n k
        , HardDerivation k
        , ctx ~ ApiLayer s t k
        )
    => ctx
    -> StakePoolLayer IO
    -> Server (StakePoolApi n)
stakePools ctx spl =
    listPools spl
    :<|> joinStakePool ctx spl
    :<|> quitStakePool ctx
    :<|> delegationFee ctx

listPools
    :: StakePoolLayer IO
    -> Handler [ApiStakePool]
listPools spl =
    liftHandler $ map (uncurry mkApiStakePool) <$> listStakePools spl
  where
    mkApiStakePool
        :: StakePool
        -> Maybe StakePoolMetadata
        -> ApiStakePool
    mkApiStakePool sp meta =
        ApiStakePool
            (ApiT $ poolId sp)
            (ApiStakePoolMetrics
                (Quantity $ fromIntegral $ getQuantity $ stake sp)
                (Quantity $ fromIntegral $ getQuantity $ production sp))
            (sp ^. #apparentPerformance)
            meta
            (fromIntegral <$> sp ^. #cost)
            (Quantity $ sp ^. #margin)

joinStakePool
    :: forall ctx s t n k.
        ( DelegationAddress n k
        , Buildable (ErrValidateSelection t)
        , s ~ SeqState n k
        , k ~ ShelleyKey
        , HardDerivation k
        , ctx ~ ApiLayer s t k
        )
    => ctx
    -> StakePoolLayer IO
    -> ApiT PoolId
    -> ApiT WalletId
    -> ApiWalletPassphrase
    -> Handler (ApiTransaction n)
joinStakePool ctx spl (ApiT pid) (ApiT wid) (ApiWalletPassphrase (ApiT pwd)) = do
    pools <- liftIO $ knownStakePools spl

    (tx, txMeta, txTime) <- liftHandler $ withWorkerCtx ctx wid liftE $ \wrk ->
        W.joinStakePool @_ @s @t @k wrk wid (pid, pools) () pwd

    pure $ mkApiTransaction
        (txId tx)
        (second (const Nothing) <$> tx ^. #resolvedInputs)
        (tx ^. #outputs)
        (txMeta, txTime)
        #pendingSince
  where
    liftE = throwE . ErrJoinStakePoolNoSuchWallet

delegationFee
    :: forall ctx s t n k.
        ( DelegationAddress n k
        , Buildable (ErrValidateSelection t)
        , s ~ SeqState n k
        , k ~ ShelleyKey
        , HardDerivation k
        , ctx ~ ApiLayer s t k
        )
    => ctx
    -> ApiT WalletId
    -> Handler ApiFee
delegationFee ctx (ApiT wid) = do
    liftHandler $ withWorkerCtx ctx wid liftE $ \wrk ->
         apiFee <$> W.selectCoinsForDelegation @_ @s @t @k wrk wid
  where
    apiFee = ApiFee . Quantity . fromIntegral . feeBalance
    liftE = throwE . ErrSelectForDelegationNoSuchWallet

quitStakePool
    :: forall ctx s t n k.
        ( DelegationAddress n k
        , Buildable (ErrValidateSelection t)
        , s ~ SeqState n k
        , k ~ ShelleyKey
        , HardDerivation k
        , ctx ~ ApiLayer s t k
        )
    => ctx
    -> ApiT PoolId
    -> ApiT WalletId
    -> ApiWalletPassphrase
    -> Handler (ApiTransaction n)
quitStakePool ctx (ApiT pid) (ApiT wid) (ApiWalletPassphrase (ApiT pwd)) = do
    (tx, txMeta, txTime) <- liftHandler $ withWorkerCtx ctx wid liftE $ \wrk ->
        W.quitStakePool @_ @s @t @k wrk wid pid () pwd

    pure $ mkApiTransaction
        (txId tx)
        (second (const Nothing) <$> tx ^. #resolvedInputs)
        (tx ^. #outputs)
        (txMeta, txTime)
        #pendingSince
  where
    liftE = throwE . ErrQuitStakePoolNoSuchWallet

{-------------------------------------------------------------------------------
                                    Network
-------------------------------------------------------------------------------}

network
    :: forall s t k. ()
    => ApiLayer s t k
    -> Handler ApiNetworkInformation
network ctx = do
    now <- liftIO getCurrentTime
    nextEpoch <- liftHandler $ except $ calculateNextEpoch sp now
    nodeTip <- liftHandler (NW.networkTip nl)
    let ntrkTip = fromMaybe slotMinBound (slotAt sp now)
    pure $ ApiNetworkInformation
        { syncProgress =
            ApiT $ syncProgressRelativeToTime st sp nodeTip now
        , nextEpoch = nextEpoch
        , nodeTip =
            ApiBlockReference
                { epochNumber = ApiT $ nodeTip ^. (#slotId . #epochNumber)
                , slotNumber  = ApiT $ nodeTip ^. (#slotId . #slotNumber)
                , height = natural (nodeTip ^. #blockHeight)
                }
        , networkTip =
            ApiNetworkTip
                { epochNumber = ApiT $ ntrkTip ^. #epochNumber
                , slotNumber = ApiT $ ntrkTip ^. #slotNumber
                }
        }
  where
    nl = ctx ^. networkLayer @t
    (_, bp, st) = ctx ^. genesisData
    sp :: W.SlotParameters
    sp = W.SlotParameters
        (bp ^. #getEpochLength)
        (bp ^. #getSlotLength)
        (bp ^. #getGenesisBlockDate)

newtype ErrNextEpoch = ErrNextEpochCannotBeCalculated Iso8601Time

calculateNextEpoch
    :: W.SlotParameters -> UTCTime -> Either ErrNextEpoch ApiEpochInfo
calculateNextEpoch sps time = case W.epochCeiling sps time of
    Nothing -> Left $ ErrNextEpochCannotBeCalculated $ Iso8601Time time
    Just en -> Right $ ApiEpochInfo
        { epochNumber = ApiT en
        , epochStartTime = W.epochStartTime sps en
        }

{-------------------------------------------------------------------------------
                               Compatibility API
-------------------------------------------------------------------------------}

compatibilityApiServer
    :: forall t n.
        ( Buildable (ErrValidateSelection t)
        , DelegationAddress n ShelleyKey
        )
    => ApiLayer (RndState 'Mainnet) t ByronKey
    -> ApiLayer (SeqState n ShelleyKey) t ShelleyKey
    -> Server (CompatibilityApi n)
compatibilityApiServer rndCtx seqCtx =
    deleteByronWallet rndCtx
    :<|> getByronWallet rndCtx
    :<|> getByronWalletMigrationInfo rndCtx
    :<|> listByronWallets rndCtx
    :<|> listByronTransactions rndCtx
    :<|> migrateByronWallet rndCtx seqCtx
    :<|> postByronWallet rndCtx
    :<|> deleteByronTransaction rndCtx

deleteByronWallet
    :: forall s t k. (s ~ RndState 'Mainnet)
    => ApiLayer s t k
    -> ApiT WalletId
    -> Handler NoContent
deleteByronWallet ctx (ApiT wid) = do
    liftHandler $ withWorkerCtx ctx wid throwE $
        \worker -> W.deleteWallet worker wid
    liftIO $ Registry.remove re wid
    liftIO $ (df ^. #removeDatabase) wid
    return NoContent
  where
    re = ctx ^. workerRegistry @s @k
    df = ctx ^. dbFactory @s @k

getByronWallet
    :: forall t k. ()
    => ApiLayer (RndState 'Mainnet) t k
    -> ApiT WalletId
    -> Handler ApiByronWallet
getByronWallet ctx (ApiT wid) =
    fst <$> getByronWalletWithCreationTime ctx wid

getByronWalletMigrationInfo
    :: forall ctx s t k.
       ( s ~ RndState 'Mainnet
       , ctx ~ ApiLayer s t k )
    => ApiLayer s t k
        -- ^ Source wallet context (Byron)
    -> ApiT WalletId
        -- ^ Source wallet (Byron)
    -> Handler ApiByronWalletMigrationInfo
getByronWalletMigrationInfo ctx (ApiT wid) = do
    sels <- getSelections
    when (null sels) $ liftHandler $ throwE $ ErrMigratingEmptyWallet wid
    return $ infoFromSelections sels
  where
    infoFromSelections :: [CoinSelection] -> ApiByronWalletMigrationInfo
    infoFromSelections =
        ApiByronWalletMigrationInfo
            . Quantity
            . fromIntegral
            . sum
            . fmap selectionFee

    selectionFee :: CoinSelection -> Word64
    selectionFee s = inputBalance s - changeBalance s

    getSelections :: Handler [CoinSelection]
    getSelections =
        liftHandler
            $ withWorkerCtx ctx wid throwE
            $ flip (W.selectCoinsForMigration @_ @s @t @k) wid

migrateByronWallet
    :: forall t n. DelegationAddress n ShelleyKey
    => ApiLayer (RndState 'Mainnet) t ByronKey
        -- ^ Source wallet context (Byron)
    -> ApiLayer (SeqState n ShelleyKey) t ShelleyKey
        -- ^ Target wallet context (Shelley)
    -> ApiT WalletId
        -- ^ Source wallet (Byron)
    -> ApiT WalletId
        -- ^ Target wallet (Shelley)
    -> ApiWalletPassphrase
    -> Handler [ApiTransaction n]
migrateByronWallet rndCtx seqCtx (ApiT rndWid) (ApiT seqWid) migrateData = do
    -- FIXME
    -- Better error handling here to inform users if they messed up with the
    -- wallet ids.
    cs <- liftHandler $
        withWorkerCtx rndCtx rndWid throwE $ \rndWrk ->
        withWorkerCtx seqCtx seqWid throwE $ \seqWrk -> do
            cs <- W.selectCoinsForMigration @_ @_ @t rndWrk rndWid
            W.assignMigrationTargetAddresses seqWrk seqWid () cs

    when (null cs) $ liftHandler $ throwE $ ErrMigratingEmptyWallet rndWid

    forM cs $ \selection -> do
        (tx, meta, time, wit) <- liftHandler
            $ withWorkerCtx rndCtx rndWid (throwE . ErrSignPaymentNoSuchWallet)
            $ \wrk ->
                W.withRootKey
                    wrk rndWid passphrase ErrSignPaymentWithRootKey
            $ \xprv ->
                W.signPayment @_ @_ @t
                    wrk rndWid (xprv, passphrase) passphrase selection
        liftHandler
            $ withWorkerCtx rndCtx rndWid (throwE . ErrSubmitTxNoSuchWallet)
            $ \wrk -> W.submitTx @_ @_ @t wrk rndWid (tx, meta, wit)
        pure $ mkApiTransaction
            (txId tx)
            (fmap Just <$> selection ^. #inputs)
            (selection ^. #outputs)
            (meta, time)
            #pendingSince
  where
    passphrase = getApiT $ migrateData ^. #passphrase

listByronWallets
    :: forall s t k. (s ~ RndState 'Mainnet)
    => ApiLayer s t k
    -> Handler [ApiByronWallet]
listByronWallets ctx = do
    wids <- liftIO $ Registry.keys re
    fmap fst . sortOn snd <$>
        mapM (getByronWalletWithCreationTime ctx) wids
  where
    re = ctx ^. workerRegistry @s @k

postByronWallet
    :: forall t. ()
    => ApiLayer (RndState 'Mainnet) t ByronKey
    -> ByronWalletPostData
    -> Handler ApiByronWallet
postByronWallet ctx body = do
    void
        . liftHandler
        . createWallet @_ @_ @t ctx wid name
        . mkRndState rootXPrv
        =<< liftIO (getStdRandom random)
    liftHandler $ withWorkerCtx ctx wid throwE $ \worker ->
        W.attachPrivateKey worker wid (rootXPrv, passphrase)
    getByronWallet ctx (ApiT wid)
  where
    mnemonicSentence = getApiMnemonicT (body ^. #mnemonicSentence)
    name = getApiT (body ^. #name)
    passphrase = getApiT (body ^. #passphrase)
    rootXPrv = Rnd.generateKeyFromSeed mnemonicSentence passphrase
    wid = WalletId $ digest $ publicKey rootXPrv

listByronTransactions
    :: forall ctx s t k n. (ctx ~ ApiLayer s t k)
    => ctx
    -> ApiT WalletId
    -> Maybe Iso8601Time
    -> Maybe Iso8601Time
    -> Maybe (ApiT SortOrder)
    -> Handler [ApiTransaction n]
listByronTransactions =
    listTransactions

deleteByronTransaction
    :: forall ctx s t k.
        ( s ~ RndState 'Mainnet
        , ctx ~ ApiLayer s t k
        )
    => ctx
    -> ApiT WalletId
    -> ApiTxId
    -> Handler NoContent
deleteByronTransaction ctx (ApiT wid) (ApiTxId (ApiT (tid))) = do
    liftHandler $ withWorkerCtx ctx wid liftE $ \wrk ->
        W.forgetPendingTx wrk wid tid
    return NoContent
  where
    liftE = throwE . ErrRemovePendingTxNoSuchWallet

{-------------------------------------------------------------------------------
                                Helpers
-------------------------------------------------------------------------------}

-- | see 'Cardano.Wallet#createWallet'
createWallet
    :: forall ctx s t k.
        ( HasWorkerRegistry s k ctx
        , HasDBFactory s k ctx
        , HasLogger ctx
        , HasGenesisData (WorkerCtx ctx)
        , HasNetworkLayer t (WorkerCtx ctx)
        , HasLogger (WorkerCtx ctx)
        , Show s
        , NFData s
        , IsOurs s Address
        , IsOurs s ChimericAccount
        )
    => ctx
    -> WalletId
    -> WalletName
    -> s
    -> ExceptT ErrCreateWallet IO WalletId
createWallet ctx wid a0 a1 =
    liftIO (Registry.lookup re wid) >>= \case
        Just _ ->
            throwE $ ErrCreateWalletAlreadyExists $ ErrWalletAlreadyExists wid
        Nothing ->
            liftIO (newWorker @_ @_ @ctx ctx wid config) >>= \case
                Nothing ->
                    throwE ErrCreateWalletFailedToCreateWorker
                Just worker ->
                    liftIO (Registry.insert re worker) $> wid
  where
    config = MkWorker
        { workerBefore = \ctx' _ -> do
            -- FIXME:
            -- Review error handling here
            void $ unsafeRunExceptT $
                W.createWallet @(WorkerCtx ctx) @s @k ctx' wid a0 a1

        , workerMain = \ctx' _ -> do
            -- FIXME:
            -- Review error handling here
            unsafeRunExceptT $
                W.restoreWallet @(WorkerCtx ctx) @s @t @k ctx' wid

        , workerAfter =
            defaultWorkerAfter

        , workerAcquire =
            (df ^. #withDatabase) wid
        }
    re = ctx ^. workerRegistry @s @k
    df = ctx ^. dbFactory @s @k

-- | Makes an 'ApiCoinSelection' from the given 'UnsignedTx'.
mkApiCoinSelection :: forall n. UnsignedTx -> ApiCoinSelection n
mkApiCoinSelection (UnsignedTx inputs outputs) =
    ApiCoinSelection
        (mkApiCoinSelectionInput <$> inputs)
        (mkAddressAmount <$> outputs)
  where
    mkAddressAmount :: TxOut -> AddressAmount n
    mkAddressAmount (TxOut addr (Coin c)) =
        AddressAmount (ApiT addr, Proxy @n) (Quantity $ fromIntegral c)

    mkApiCoinSelectionInput :: (TxIn, TxOut) -> ApiCoinSelectionInput n
    mkApiCoinSelectionInput (TxIn txid index, TxOut addr (Coin c)) =
        ApiCoinSelectionInput
            { id = ApiT txid
            , index = index
            , address = (ApiT addr, Proxy @n)
            , amount = Quantity $ fromIntegral c
            }

mkApiTransaction
    :: forall n.
       Hash "Tx"
    -> [(TxIn, Maybe TxOut)]
    -> [TxOut]
    -> (W.TxMeta, UTCTime)
    -> Lens' (ApiTransaction n) (Maybe ApiTimeReference)
    -> ApiTransaction n
mkApiTransaction txid ins outs (meta, timestamp) setTimeReference =
    tx & setTimeReference .~ Just timeReference
  where
    tx :: ApiTransaction n
    tx = ApiTransaction
        { id = ApiT txid
        , amount = meta ^. #amount
        , insertedAt = Nothing
        , pendingSince = Nothing
        , depth = Quantity 0
        , direction = ApiT (meta ^. #direction)
        , inputs = [ApiTxInput (fmap toAddressAmount o) (ApiT i) | (i, o) <- ins]
        , outputs = toAddressAmount <$> outs
        , status = ApiT (meta ^. #status)
        }

    timeReference :: ApiTimeReference
    timeReference = ApiTimeReference
        { time = timestamp
        , block = ApiBlockReference
            { slotNumber = ApiT $ meta ^. (#slotId . #slotNumber )
            , epochNumber = ApiT $ meta ^. (#slotId . #epochNumber)
            , height = natural (meta ^. #blockHeight)
            }
        }

    toAddressAmount :: TxOut -> AddressAmount n
    toAddressAmount (TxOut addr (Coin c)) =
        AddressAmount (ApiT addr, Proxy @n) (Quantity $ fromIntegral c)

coerceCoin :: AddressAmount t -> TxOut
coerceCoin (AddressAmount (ApiT addr, _) (Quantity c)) =
    TxOut addr (Coin $ fromIntegral c)

natural :: Quantity q Word32 -> Quantity q Natural
natural = Quantity . fromIntegral . getQuantity

getWalletWithCreationTime
    :: forall s t k n. (s ~ SeqState n k, WalletKey k)
    => ApiLayer s t k
    -> WalletId
    -> Handler (ApiWallet, UTCTime)
getWalletWithCreationTime ctx wid = do
    (wallet, meta, pending) <-
        liftHandler $ withWorkerCtx ctx wid throwE $
            \wrk -> W.readWallet wrk wid
    reward <- liftHandler $ withWorkerCtx ctx wid (throwE . ErrFetchRewardsNoSuchWallet) $
            \wrk -> W.fetchRewardBalance @_ @s @k @t wrk wid
    progress <- liftIO $ W.walletSyncProgress ctx wallet

    let apiWallet = ApiWallet
            { addressPoolGap = ApiT $ getState wallet ^. #externalPool . #gap
            , balance = getWalletBalance wallet pending reward
            , delegation = ApiT $ ApiT <$> meta ^. #delegation
            , id = ApiT wid
            , name = ApiT $ meta ^. #name
            , passphrase = ApiT <$> meta ^. #passphraseInfo
            , state = ApiT progress
            , tip = getWalletTip wallet
            }
    return (apiWallet, meta ^. #creationTime)


getByronWalletWithCreationTime
    :: forall s t k. (s ~ RndState 'Mainnet)
    => ApiLayer s t k
    -> WalletId
    -> Handler (ApiByronWallet, UTCTime)
getByronWalletWithCreationTime ctx wid = do
    (wallet, meta, pending) <-
        liftHandler $ withWorkerCtx ctx wid throwE $
            \wrk -> W.readWallet wrk wid
    progress <- liftIO $ W.walletSyncProgress ctx wallet

    let apiByronWallet = ApiByronWallet
            { balance = getByronWalletBalance wallet pending
            , id = ApiT wid
            , name = ApiT $ meta ^. #name
            , passphrase = ApiT <$> meta ^. #passphraseInfo
            , state = ApiT progress
            , tip = getWalletTip wallet
            }
    return (apiByronWallet, meta ^. #creationTime)

getWalletBalance
    :: Wallet s
    -> Set Tx
    -> Quantity "lovelace" Word64
    -> ApiT WalletBalance
getWalletBalance wallet pending (Quantity rewardBalance) = ApiT $ WalletBalance
    { available = Quantity $ availableBalance pending wallet
    , total = Quantity $ totalBalance pending wallet
    , reward = Quantity $ fromIntegral rewardBalance
    }

getByronWalletBalance :: Wallet s -> Set Tx -> ApiByronWalletBalance
getByronWalletBalance wallet pending = ApiByronWalletBalance
    { available = Quantity $ availableBalance pending wallet
    , total = Quantity $ totalBalance pending wallet
    }

getWalletTip :: Wallet s -> ApiBlockReference
getWalletTip wallet = ApiBlockReference
    { epochNumber = ApiT $ (currentTip wallet) ^. #slotId . #epochNumber
    , slotNumber = ApiT $ (currentTip wallet) ^. #slotId . #slotNumber
    , height = natural $ (currentTip wallet) ^. #blockHeight
    }

{-------------------------------------------------------------------------------
                                Api Layer
-------------------------------------------------------------------------------}

-- | Create a new instance of the wallet layer.
newApiLayer
    :: forall ctx s t k. ctx ~ ApiLayer s t k
    => Trace IO Text
    -> (Block, BlockchainParameters, SyncTolerance)
    -> NetworkLayer IO t Block
    -> TransactionLayer t k
    -> DBFactory IO s k
    -> [WalletId]
    -> IO ctx
newApiLayer tr g0 nw tl df wids = do
    re <- Registry.empty
    let ctx = ApiLayer tr g0 nw tl df re
    forM_ wids (registerWorker re ctx)
    return ctx
  where
    registerWorker re ctx wid = do
        let config = MkWorker
                { workerBefore =
                    \_ _ -> return ()

                , workerMain = \ctx' _ -> do
                    -- FIXME:
                    -- Review error handling here
                    unsafeRunExceptT $
                        W.restoreWallet @(WorkerCtx ctx) @s @t ctx' wid

                , workerAfter =
                    defaultWorkerAfter

                , workerAcquire =
                    (df ^. #withDatabase) wid
                }
        newWorker @_ @_ @ctx ctx wid config >>= \case
            Nothing ->
                return ()
            Just worker ->
                Registry.insert re worker

-- | Run an action in a particular worker context. Fails if there's no worker
-- for a given id.
withWorkerCtx
    :: forall ctx s k m a.
        ( HasWorkerRegistry s k ctx
        , MonadIO m
        )
    => ctx
        -- ^ A context that has a registry
    -> WalletId
        -- ^ Wallet to look for
    -> (ErrNoSuchWallet -> m a)
        -- ^ Wallet not present, handle error
    -> (WorkerCtx ctx -> m a)
        -- ^ Do something with the wallet
    -> m a
withWorkerCtx ctx wid onMissing action =
    Registry.lookup re wid >>= \case
        Nothing ->
            onMissing (ErrNoSuchWallet wid)
        Just wrk ->
            action $ hoistResource (workerResource wrk) ctx
  where
    re = ctx ^. workerRegistry @s @k

defaultWorkerAfter :: Trace IO Text -> Either SomeException a -> IO ()
defaultWorkerAfter tr = \case
    Right _ ->
        logNotice tr "Worker has exited: main action is over."
    Left e -> case asyncExceptionFromException e of
        Just ThreadKilled ->
            logNotice tr "Worker has exited: killed by parent."
        Just UserInterrupt ->
            logNotice tr "Worker has exited: killed by user."
        _ ->
            logError tr $ "Worker has exited unexpectedly: " <> pretty (show e)

{-------------------------------------------------------------------------------
                                Error Handling
-------------------------------------------------------------------------------}

-- | Lift our wallet layer into servant 'Handler', by mapping each error to a
-- corresponding servant error.
class LiftHandler e where
    liftHandler :: ExceptT e IO a -> Handler a
    liftHandler action = Handler (withExceptT handler action)
    handler :: e -> ServantErr

apiError :: ServantErr -> ApiErrorCode -> Text -> ServantErr
apiError err code message = err
    { errBody = Aeson.encode $ Aeson.object
        [ "code" .= code
        , "message" .= T.replace "\n" " " message
        ]
    }

data ErrCreateWallet
    = ErrCreateWalletAlreadyExists ErrWalletAlreadyExists
        -- ^ Wallet already exists
    | ErrCreateWalletFailedToCreateWorker
        -- ^ Somehow, we couldn't create a worker or open a db connection
    deriving (Eq, Show)

newtype ErrMigrateWallet
    = ErrMigratingEmptyWallet WalletId
        -- ^ User attempted to migrate an empty wallet
    deriving (Eq, Show)

-- | Small helper to easy show things to Text
showT :: Show a => a -> Text
showT = T.pack . show

instance LiftHandler ErrMigrateWallet where
    handler = \case
        ErrMigratingEmptyWallet wid ->
            apiError err403 NothingToMigrate $ mconcat
                [ "I can't migrate the wallet with the given id: "
                , toText wid
                , ", because it's either empty or full of small coins "
                , "which wouldn't be worth migrating."
                ]

instance LiftHandler ErrNextEpoch where
    handler = \case
        ErrNextEpochCannotBeCalculated time ->
            apiError err500 UnexpectedError $ mconcat
                [ "I'm unable to calculate the next epoch that starts after "
                , "time: "
                , toText time
                , ". This is unexpected, and unlikely to be your fault."
                ]

instance LiftHandler ErrNoSuchWallet where
    handler = \case
        ErrNoSuchWallet wid ->
            apiError err404 NoSuchWallet $ mconcat
                [ "I couldn't find a wallet with the given id: "
                , toText wid
                ]

instance LiftHandler ErrWalletAlreadyExists where
    handler = \case
        ErrWalletAlreadyExists wid ->
            apiError err409 WalletAlreadyExists $ mconcat
                [ "This operation would yield a wallet with the following id: "
                , toText wid
                , " However, I already know of a wallet with this id."
                ]

instance LiftHandler ErrCreateWallet where
    handler = \case
        ErrCreateWalletAlreadyExists e -> handler e
        ErrCreateWalletFailedToCreateWorker ->
            apiError err500 UnexpectedError $ mconcat
                [ "That's embarassing. Your wallet looks good, but I couldn't "
                , "open a new database to store its data. This is unexpected "
                , "and likely not your fault. Perhaps, check your filesystem's "
                , "permissions or available space?"
                ]

instance LiftHandler ErrWithRootKey where
    handler = \case
        ErrWithRootKeyNoRootKey wid ->
            apiError err404 NoRootKey $ mconcat
                [ "I couldn't find a root private key for the given wallet: "
                , toText wid, ". However, this operation requires that I do "
                , "have such a key. Either there's no such wallet, or I don't "
                , "fully own it."
                ]
        ErrWithRootKeyWrongPassphrase wid ErrWrongPassphrase ->
            apiError err403 WrongEncryptionPassphrase $ mconcat
                [ "The given encryption passphrase doesn't match the one I use "
                , "to encrypt the root private key of the given wallet: "
                , toText wid
                ]

instance Buildable e => LiftHandler (ErrSelectCoinsExternal e) where
    handler = \case
        ErrSelectCoinsExternalNoSuchWallet e ->
            handler e
        ErrSelectCoinsExternalUnableToMakeSelection e ->
            handler e
        ErrSelectCoinsExternalUnableToAssignInputs wid ->
            apiError err500 UnexpectedError $ mconcat
                [ "I was unable to assign inputs while generating a coin "
                , "selection for the specified wallet: "
                , toText wid
                ]
        ErrSelectCoinsExternalUnableToAssignOutputs wid ->
            apiError err500 UnexpectedError $ mconcat
                [ "I was unable to assign outputs while generating a coin "
                , "selection for the specified wallet: "
                , toText wid
                ]

instance Buildable e => LiftHandler (ErrCoinSelection e) where
    handler = \case
        ErrNotEnoughMoney utxo payment ->
            apiError err403 NotEnoughMoney $ mconcat
                [ "I can't process this payment because there's not enough "
                , "UTxO available in the wallet. The total UTxO sums up to "
                , showT utxo, " Lovelace, but I need ", showT payment
                , " Lovelace (excluding fee amount) in order to proceed "
                , " with the payment."
                ]
        ErrUtxoNotEnoughFragmented nUtxo nOuts ->
            apiError err403 UtxoNotEnoughFragmented $ mconcat
                [ "When creating new transactions, I'm not able to re-use "
                , "the same UTxO for different outputs. Here, I only have "
                , showT nUtxo, " available, but there are ", showT nOuts
                , " outputs."
                ]
        ErrMaximumInputsReached n ->
            apiError err403 TransactionIsTooBig $ mconcat
                [ "I had to select ", showT n, " inputs to construct the "
                , "requested transaction. Unfortunately, this would create a "
                , "transaction that is too big, and this would consequently "
                , "be rejected by a core node. Try sending a smaller amount."
                ]
        ErrInputsDepleted ->
            apiError err403 InputsDepleted $ mconcat
                [ "I had to select inputs to construct the "
                , "requested transaction. Unfortunately, one output of the "
                , "transaction depleted all available inputs. "
                , "Try sending a smaller amount."
                ]
        ErrInvalidSelection e ->
            apiError err403 InvalidCoinSelection $ pretty e

instance LiftHandler ErrAdjustForFee where
    handler = \case
        ErrCannotCoverFee missing ->
            apiError err403 CannotCoverFee $ mconcat
                [ "I'm unable to adjust the given transaction to cover the "
                , "associated fee! In order to do so, I'd have to select one "
                , "or more additional inputs, but I can't do that without "
                , "increasing the size of the transaction beyond the "
                , "acceptable limit. Note that I am only missing "
                , showT missing, " Lovelace."
                ]

instance Buildable e => LiftHandler (ErrSelectForPayment e) where
    handler = \case
        ErrSelectForPaymentNoSuchWallet e -> handler e
        ErrSelectForPaymentCoinSelection e -> handler e
        ErrSelectForPaymentFee e -> handler e

instance LiftHandler ErrListUTxOStatistics where
    handler = \case
        ErrListUTxOStatisticsNoSuchWallet e -> handler e

instance LiftHandler ErrMkTx where
    handler = \case
        ErrKeyNotFoundForAddress addr ->
            apiError err500 KeyNotFoundForAddress $ mconcat
                [ "That's embarassing. I couldn't sign the given transaction: "
                , "I haven't found the corresponding private key for a known "
                , "input address I should keep track of: ", showT addr, ". "
                , "Retrying may work, but something really went wrong..."
                ]

instance LiftHandler ErrSignPayment where
    handler = \case
        ErrSignPaymentMkTx e -> handler e
        ErrSignPaymentNoSuchWallet e -> (handler e)
            { errHTTPCode = 410
            , errReasonPhrase = errReasonPhrase err410
            }
        ErrSignPaymentWithRootKey e@ErrWithRootKeyNoRootKey{} -> (handler e)
            { errHTTPCode = 410
            , errReasonPhrase = errReasonPhrase err410
            }
        ErrSignPaymentWithRootKey e@ErrWithRootKeyWrongPassphrase{} -> handler e

instance LiftHandler ErrDecodeSignedTx where
    handler = \case
        ErrDecodeSignedTxWrongPayload _ ->
            apiError err400 MalformedTxPayload $ mconcat
                [ "I couldn't verify that the payload has the correct binary "
                , "format. Therefore I couldn't send it to the node. Please "
                , "check the format and try again."
                ]
        ErrDecodeSignedTxNotSupported ->
            apiError err404 UnexpectedError $ mconcat
                [ "This endpoint is not supported by the backend currently "
                , "in use. Please try a different backend."
                ]

instance LiftHandler ErrSubmitExternalTx where
    handler = \case
        ErrSubmitExternalTxNetwork e -> case e of
            ErrPostTxNetworkUnreachable e' ->
                handler e'
            ErrPostTxBadRequest err ->
                apiError err500 CreatedInvalidTransaction $ mconcat
                    [ "That's embarrassing. It looks like I've created an "
                    , "invalid transaction that could not be parsed by the "
                    , "node. Here's an error message that may help with "
                    , "debugging: ", pretty err
                    ]
            ErrPostTxProtocolFailure err ->
                apiError err500 RejectedByCoreNode $ mconcat
                    [ "I successfully submitted a transaction, but "
                    , "unfortunately it was rejected by a relay. This could be "
                    , "because the fee was not large enough, or because the "
                    , "transaction conflicts with another transaction that "
                    , "uses one or more of the same inputs, or it may be due "
                    , "to some other reason. Here's an error message that may "
                    , "help with debugging: ", pretty err
                    ]
        ErrSubmitExternalTxDecode e -> (handler e)
            { errHTTPCode = 400
            , errReasonPhrase = errReasonPhrase err400
            }

instance LiftHandler ErrRemovePendingTx where
    handler = \case
        ErrRemovePendingTxNoSuchWallet wid -> handler wid
        ErrRemovePendingTxNoSuchTransaction tid ->
            apiError err404 NoSuchTransaction $ mconcat
                [ "I couldn't find a transaction with the given id: "
                , toText tid
                ]
        ErrRemovePendingTxTransactionNoMorePending tid ->
            apiError err403 TransactionNotPending $ mconcat
                [ "The transaction with id: ", toText tid,
                  " cannot be forgotten as it is not pending anymore."
                ]

instance LiftHandler ErrPostTx where
    handler = \case
        ErrPostTxNetworkUnreachable e -> handler e
        ErrPostTxBadRequest err ->
            apiError err500 CreatedInvalidTransaction $ mconcat
            [ "That's embarrassing. It looks like I've created an "
            , "invalid transaction that could not be parsed by the "
            , "node. Here's an error message that may help with "
            , "debugging: ", pretty err
            ]
        ErrPostTxProtocolFailure err ->
            apiError err500 RejectedByCoreNode $ mconcat
            [ "I successfully submitted a transaction, but "
            , "unfortunately it was rejected by a relay. This could be "
            , "because the fee was not large enough, or because the "
            , "transaction conflicts with another transaction that "
            , "uses one or more of the same inputs, or it may be due "
            , "to some other reason. Here's an error message that may "
            , "help with debugging: ", pretty err
            ]

instance LiftHandler ErrSubmitTx where
    handler = \case
        ErrSubmitTxNetwork e -> handler e
        ErrSubmitTxNoSuchWallet e@ErrNoSuchWallet{} -> (handler e)
            { errHTTPCode = 410
            , errReasonPhrase = errReasonPhrase err410
            }

instance LiftHandler ErrNetworkUnavailable where
    handler = \case
        ErrNetworkUnreachable _err ->
            apiError err503 NetworkUnreachable $ mconcat
                [ "The node backend is unreachable at the moment. Trying again "
                , "in a bit might work."
                ]
        ErrNetworkInvalid n ->
            apiError err503 NetworkMisconfigured $ mconcat
                [ "The node backend is configured for the wrong network: "
                , n, "."
                ]

instance LiftHandler ErrUpdatePassphrase where
    handler = \case
        ErrUpdatePassphraseNoSuchWallet e -> handler e
        ErrUpdatePassphraseWithRootKey e  -> handler e

instance LiftHandler ErrListTransactions where
    handler = \case
        ErrListTransactionsNoSuchWallet e -> handler e
        ErrListTransactionsStartTimeLaterThanEndTime e -> handler e

instance LiftHandler ErrStartTimeLaterThanEndTime where
    handler err = apiError err400 StartTimeLaterThanEndTime $ mconcat
        [ "The specified start time '"
        , toText $ Iso8601Time $ errStartTime err
        , "' is later than the specified end time '"
        , toText $ Iso8601Time $ errEndTime err
        , "'."
        ]

instance LiftHandler ErrNetworkTip where
    handler = \case
        ErrNetworkTipNetworkUnreachable e -> handler e
        ErrNetworkTipNotFound -> apiError err503 NetworkTipNotFound $ mconcat
            [ "I couldn't get the current network tip at the moment. It's "
            , "probably because the node is down or not started yet. Retrying "
            , "in a bit might give better results!"
            ]

instance LiftHandler ErrListStakePools where
     handler = \case
         ErrListStakePoolsMetricsInconsistency e -> handler e
         ErrListStakePoolsErrNetworkTip e -> handler e
         ErrMetricsIsUnsynced p ->
             apiError err503 NotSynced $ mconcat
                 [ "I can't list stake pools yet because I need to scan the "
                 , "blockchain for metrics first. I'm at "
                 , toText p
                 ]

instance LiftHandler ErrMetricsInconsistency where
    handler = \case
        ErrProducerNotInDistribution producer ->
            apiError err500 UnexpectedError $ mconcat
                [ "Something is terribly wrong with the metrics I collected. "
                , "I recorded that some blocks were produced by "
                , toText producer
                , " but the node doesn't know about this stake pool!"
                ]

instance LiftHandler ErrSelectForDelegation where
    handler = \case
        ErrSelectForDelegationNoSuchWallet e -> handler e
        ErrSelectForDelegationFee (ErrCannotCoverFee cost) ->
            apiError err403 CannotCoverFee $ mconcat
                [ "I'm unable to select enough coins to pay for a "
                , "delegation certificate. I need: ", showT cost, " Lovelace."
                ]

instance LiftHandler ErrSignDelegation where
    handler = \case
        ErrSignDelegationMkTx e -> handler e
        ErrSignDelegationNoSuchWallet e -> (handler e)
            { errHTTPCode = 410
            , errReasonPhrase = errReasonPhrase err410
            }
        ErrSignDelegationWithRootKey e@ErrWithRootKeyNoRootKey{} -> (handler e)
            { errHTTPCode = 410
            , errReasonPhrase = errReasonPhrase err410
            }
        ErrSignDelegationWithRootKey e@ErrWithRootKeyWrongPassphrase{} -> handler e

instance LiftHandler ErrJoinStakePool where
    handler = \case
        ErrJoinStakePoolNoSuchWallet e -> handler e
        ErrJoinStakePoolSubmitTx e -> handler e
        ErrJoinStakePoolSignDelegation e -> handler e
        ErrJoinStakePoolSelectCoin e -> handler e
        ErrJoinStakePoolAlreadyDelegating pid ->
            apiError err403 PoolAlreadyJoined $ mconcat
                [ "I couldn't join a stake pool with the given id: "
                , toText pid
                , ". I have already joined this pool; joining again would incur"
                , " an unnecessary fee!"
                ]
        ErrJoinStakePoolNoSuchPool pid ->
            apiError err404 NoSuchPool $ mconcat
                [ "I couldn't find any stake pool with the given id: "
                , toText pid
                ]

instance LiftHandler ErrFetchRewards where
    handler = \case
        ErrFetchRewardsNoSuchWallet e -> handler e
        ErrFetchRewardsNetworkUnreachable e -> handler e

instance LiftHandler ErrQuitStakePool where
    handler = \case
        ErrQuitStakePoolNoSuchWallet e -> handler e
        ErrQuitStakePoolSelectCoin e -> handler e
        ErrQuitStakePoolSignDelegation e -> handler e
        ErrQuitStakePoolSubmitTx e -> handler e
        ErrQuitStakePoolNotDelegatingTo pid ->
            apiError err403 NotDelegatingTo $ mconcat
                [ "I couldn't quit a stake pool with the given id: "
                , toText pid
                , ", because I'm not a member of this stake pool."
                , " Please check if you are using correct stake pool id"
                , " in your request."
                ]

instance LiftHandler (Request, ServantErr) where
    handler (req, err@(ServantErr code _ body headers))
      | not (isJSON body) = case code of
        400 | "Failed reading" `BS.isInfixOf` BL.toStrict body ->
            apiError err' BadRequest $ mconcat
                [ "I couldn't understand the content of your message. If your "
                , "message is intended to be in JSON format, please check that "
                , "the JSON is valid."
                ]
        400 -> apiError err' BadRequest (utf8 body)
        404 -> apiError err' NotFound $ mconcat
            [ "I couldn't find the requested endpoint. If the endpoint "
            , "contains path parameters, please ensure they are well-formed, "
            , "otherwise I won't be able to route them correctly."
            ]
        405 -> apiError err' MethodNotAllowed $ mconcat
            [ "You've reached a known endpoint but I don't know how to handle "
            , "the HTTP method specified. Please double-check both the "
            , "endpoint and the method: one of them is likely to be incorrect "
            , "(for example: POST instead of PUT, or GET instead of POST...)."
            ]
        406 -> apiError err' NotAcceptable $ mconcat
            [ "It seems as though you don't accept 'application/json', but "
            , "unfortunately I only speak 'application/json'! Please "
            , "double-check your 'Accept' request header and make sure it's "
            , "set to 'application/json'."
            ]
        415 ->
            let cType =
                    if ["proxy", "transactions"] `isSubsequenceOf` pathInfo req
                        then "application/octet-stream"
                        else "application/json"
            in apiError err' UnsupportedMediaType $ mconcat
            [ "I'm really sorry but I only understand '", cType, "'. I need you "
            , "to tell me what language you're speaking in order for me to "
            , "understand your message. Please double-check your 'Content-Type' "
            , "request header and make sure it's set to '", cType, "'."
            ]
        _ -> apiError err' UnexpectedError $ mconcat
            [ "It looks like something unexpected went wrong. Unfortunately I "
            , "don't yet know how to handle this type of situation. Here's "
            , "some information about what happened: ", utf8 body
            ]
      | otherwise = err
      where
        utf8 = T.replace "\"" "'" . T.decodeUtf8 . BL.toStrict
        isJSON = isJust . Aeson.decode @Aeson.Value
        err' = err
            { errHeaders =
                ( hContentType
                , renderHeader $ contentType $ Proxy @JSON
                ) : headers
            }
