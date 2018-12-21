{-# OPTIONS_GHC -fno-warn-type-defaults #-}
-- | The kernel of the wallet implementation
--
-- The goal is to keep this module mostly self-contained, and not use to many
-- Cardano specific types (except those types that appear in the translation
-- of the UTxO DSL), so that we can test it outside of a node context also
-- (in unit tests).
module Cardano.Wallet.Kernel (
      -- * Passive wallet
      PassiveWallet -- opaque
    , bracketPassiveWallet
    -- * Configuration
    , DatabaseMode(..)
    , DatabaseOptions(..)
    , useDefaultPaths
    , defaultAcidStatePath
    , defaultSqlitePath
      -- ** Lenses
    , walletNode
    , walletLogMessage
    , walletPassive
    , walletMeta
      -- * Active wallet
    , ActiveWallet -- opaque
    , bracketActiveWallet
    ) where

import           Universum hiding (State)

import           Control.Concurrent.Async (async, cancel)
import           Data.Acid (AcidState, createArchive, createCheckpoint,
                     openLocalStateFrom)
import           Data.Acid.Memory (openMemoryState)
import qualified Data.List as List
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Strict.Maybe as StrictMaybe
import           System.Directory (doesPathExist, removePathForcibly)

import           Pos.Chain.Block (HeaderHash, getBlockHeader, headerHash,
                     mainBlockSlot, mainBlockTxPayload)
import           Pos.Chain.Txp (Tx (..), TxAux (..), TxIn (..), Utxo, txpTxs,
                     utxoToLookup)
import           Pos.Core (getCurrentTimestamp)
import           Pos.Core.Chrono (OldestFirst (..))
import           Pos.Crypto (ProtocolMagic)
import           Pos.Infra.InjectFail (FInjects)
import           Pos.Util.Wlog (Severity (..))

import           Cardano.Wallet.Kernel.DB.AcidState (DB, defDB)
import           Cardano.Wallet.Kernel.DB.BlockContext (BlockContext (..))
import           Cardano.Wallet.Kernel.DB.InDb
import           Cardano.Wallet.Kernel.DB.Read (pendingByAccount)
import           Cardano.Wallet.Kernel.DB.Resolved (ResolvedBlock (..),
                     ResolvedTx (..))
import           Cardano.Wallet.Kernel.DB.TxMeta
import           Cardano.Wallet.Kernel.Diffusion (WalletDiffusion (..))
import           Cardano.Wallet.Kernel.Internal
import           Cardano.Wallet.Kernel.Keystore (Keystore)
import           Cardano.Wallet.Kernel.NodeStateAdaptor (NodeStateAdaptor,
                     getCoreConfig)
import           Cardano.Wallet.Kernel.Pending (cancelPending)
import           Cardano.Wallet.Kernel.Read (getWalletSnapshot)
import           Cardano.Wallet.Kernel.Submission (WalletSubmission,
                     addPendings, emptyWalletSubmission, tick)
import           Cardano.Wallet.Kernel.Submission.Worker (tickDiffusionLayer,
                     tickSubmissionLayer)
import           Cardano.Wallet.Kernel.Util.Core (txOuts, utxoRemoveInputs,
                     utxoUnions)
import qualified Cardano.Wallet.Kernel.Util.Strict as Strict
import           UTxO.Context (CardanoContext (..), initCardanoContext)

{-------------------------------------------------------------------------------
  Passive Wallet Resource Management
-------------------------------------------------------------------------------}

-- | This type is used to configure the database location.
data DatabaseMode
    = UseInMemory
    -- ^ This constructor is used when you want to run the database in memory.
    -- This is useful for testing as it does not require a disk. The database
    -- will start out with the fresh, default, uninitialized state.
    | UseFilePath DatabaseOptions
    -- ^ Load the databases from the given paths.

-- | A configuration type for specifying where to load the databases from.
data DatabaseOptions
    = DatabaseOptions
    { dbPathAcidState :: FilePath
    -- ^ The path for the @acid-state@ database.
    , dbPathMetadata  :: FilePath
    -- ^ This path is used for the SQLite database that contains the transaction
    -- metadata.
    , dbRebuild       :: Bool
    -- ^ Whether we want to rebuild the db in case it exists.
    } deriving (Eq, Show)

-- | Use the default paths on disk. See 'DatabaseOptions' for more details.
useDefaultPaths :: DatabaseMode
useDefaultPaths =
    UseFilePath $ DatabaseOptions defaultAcidStatePath defaultSqlitePath False

defaultAcidStatePath :: FilePath
defaultAcidStatePath = "wallet-db-acid"

defaultSqlitePath :: FilePath
defaultSqlitePath = "./wallet-db-sqlite.sqlite3"

-- | Allocate wallet resources
--
-- Here and elsewhere we'll want some constraints on this monad here, but
-- it shouldn't be too specific.
bracketPassiveWallet
    :: (MonadMask m, MonadIO m)
    => ProtocolMagic
    -> DatabaseMode
    -> (Severity -> Text -> IO ())
    -> Keystore
    -> NodeStateAdaptor IO
    -> FInjects IO
    -> (PassiveWallet -> m a) -> m a
bracketPassiveWallet pm mode logMsg keystore node fInjects f =
    bracket (liftIO $ handlesOpen mode)
            (liftIO . handlesClose mode)
            (\ handles ->
                bracket
                  (liftIO $ initPassiveWallet pm logMsg keystore handles node fInjects)
                  (\_ -> return ())
                  f)

data WalletHandles = Handles {
    hAcid :: AcidState DB,
    hMeta :: MetaDBHandle
}

-- TODO(kde): this will be run with asynchronous exceptions masked.
-- and we should rethink if migrateMetaDB should happen here.
handlesOpen :: DatabaseMode -> IO WalletHandles
handlesOpen mode =
    case mode of
        UseInMemory -> do
            db <- openMemoryState defDB
            metadb <- openMetaDB ":memory:"
            migrateMetaDB metadb
            return $ Handles db metadb
        UseFilePath (DatabaseOptions acidDb sqliteDb rebuildDB) -> do
            let deleteMaybe fp = do
                    when rebuildDB $ do
                        itsHere <- doesPathExist fp
                        when itsHere $ removePathForcibly fp
            deleteMaybe acidDb
            db <- openLocalStateFrom acidDb defDB
            deleteMaybe sqliteDb
            metadb <- openMetaDB sqliteDb
            migrateMetaDB metadb
            return $ Handles db metadb

handlesClose :: DatabaseMode -> WalletHandles -> IO ()
handlesClose dbMode (Handles acidDb meta) = do
    closeMetaDB meta
    case dbMode of
        UseInMemory ->
            pure ()
        UseFilePath DatabaseOptions{} -> do
            createCheckpoint acidDb
            createArchive acidDb

{-------------------------------------------------------------------------------
  Wallet Initialisers
-------------------------------------------------------------------------------}

-- | Initialise Passive Wallet
initPassiveWallet :: ProtocolMagic
                  -> (Severity -> Text -> IO ())
                  -> Keystore
                  -> WalletHandles
                  -> NodeStateAdaptor IO
                  -> FInjects IO
                  -> IO PassiveWallet
initPassiveWallet pm logMessage keystore handles node fInjects = do
    pw <- preparePassiveWallet
    initSubmission pw
    return pw
    where
        -- | Prepare Passive Wallet for initialisation.
        -- NOTE: the Submission Layer is not initialised yet since that would require
        -- access to the PassiveWallet state
        preparePassiveWallet :: IO PassiveWallet
        preparePassiveWallet = do
            submission <- newMVar emptyWalletSubmission
            restore    <- newRestorationTasks
            return PassiveWallet {
                  _walletLogMessage      = logMessage
                , _walletKeystore        = keystore
                , _wallets               = hAcid handles
                , _walletProtocolMagic   = pm
                , _walletMeta            = hMeta handles
                , _walletNode            = node
                , _walletSubmission      = submission
                , _walletRestorationTask = restore
                , _walletFInjects        = fInjects
                }

        -- | Since the submission layer state is not persisted, we need to initialise
        -- the submission layer with all pending transactions present in the wallet state.
        initSubmission :: PassiveWallet -> IO ()
        initSubmission pw_  = do
            pendings <- pendingByAccount <$> getWalletSnapshot pw_
            Strict.modifyMVar_ (_walletSubmission pw_) $
                return . addPendings pendings

{-------------------------------------------------------------------------------
  Active wallet
-------------------------------------------------------------------------------}

-- | Initialize the active wallet
bracketActiveWallet :: (MonadMask m, MonadIO m)
                    => PassiveWallet
                    -> WalletDiffusion
                    -> (ActiveWallet -> m a) -> m a
bracketActiveWallet walletPassive
                    walletDiffusion
                    runActiveWallet = do
    submissionLayerTicker <- liftIO $ async $
      tickSubmissionLayer
        (walletPassive ^. walletLogMessage)
        (tickFunction (walletPassive ^. walletSubmission))

    genesisConfig <- liftIO $ getCoreConfig $ walletPassive ^. walletNode
    let initialUtxo = ccUtxo $ initCardanoContext genesisConfig

    applyingBlockTicker <- liftIO $ async $
       tickDiffusionLayer
        (walletPassive ^. walletLogMessage)
        tickDiffusionFunction
        (([],[]), initialUtxo)

    bracket
      (return ActiveWallet{..})
      (\_ -> liftIO $ do
                 (_walletLogMessage walletPassive) Error "stopping the wallet submission layer..."
                 cancel submissionLayerTicker
                 cancel applyingBlockTicker
      )
      runActiveWallet
    where
        -- NOTE(adn) We might want to discuss diffusion layer throttling
        -- with Alex & Duncan.
        -- By default the diffusion layer should correctly throttle and debounce
        -- requests, but we might want in the future to adopt more sophisticated
        -- strategies.
        sendTransactions :: [TxAux] -> IO ()
        sendTransactions [] = return ()
        sendTransactions (tx:txs) = do
            void $ (walletSendTx walletDiffusion) tx
            sendTransactions txs

        tickFunction :: MVar WalletSubmission -> IO ()
        tickFunction submissionLayer = do
            toSend <-
                Strict.modifyMVar submissionLayer $ \layer -> do
                    let (e, s, state') = tick layer
                    -- cancelPending is called in the MVar IO action so that we can reset the
                    -- state of the wallet using the MVar to block this thread.
                    -- If left outside, this thread could potentially
                    -- cancel Txs that were added after the reset.
                    unless (Map.null e) $
                        cancelPending walletPassive e
                    return (state', s)
            -- This can`t change the state of the wallet, so it`s left outside the MVar IO action.
            sendTransactions toSend

        tickDiffusionFunction
            :: (([HeaderHash], [HeaderHash]), Utxo)
            -> IO (([HeaderHash], [HeaderHash]), Utxo)
        tickDiffusionFunction ((inProgressHeader, consumedHeader),utxo) = do
            nodeBlockHeaderMap <- walletRequestTip walletDiffusion
            let [(nodeId, headerIO)] = Map.toList nodeBlockHeaderMap
            header <- headerIO
            void $ print "-------------- tick"

            case inProgressHeader of
                [h1, h2] -> do
                    blocksDowloaded <- walletGetBlocks walletDiffusion nodeId h2 (take 1 consumedHeader)
                    let accomodatedHeaders =  map (headerHash . getBlockHeader) $ getOldestFirst blocksDowloaded
                    --void $ print "currentHeaders :  "
                    --void $ print accomodatedHeaders
                    --let prevHeaders =  map (\block -> block ^. prevBlockL) $ getOldestFirst blocksDowloaded
                    -- TO-DO what if GenesisBlock is in the middle
                    -- now handle the case if it is the oldest
                    --void $ print "prevHeaders :  "
                    let prevHeaders = case consumedHeader of
                                          [] -> (take 1 accomodatedHeaders) ++ ((reverse . drop 1 . reverse) accomodatedHeaders)
                                          cs -> (take 1 cs) ++ ((reverse . drop 1 . reverse) accomodatedHeaders)
                    --void $ print prevHeaders
                    let slotId = map (\genericBlock -> case genericBlock of
                                                           Right block -> Just $ block ^. mainBlockSlot
                                                           Left _  -> Nothing
                                     )
                                 $ getOldestFirst blocksDowloaded
                    --void $ print "slotId :  "
                    --void $ print slotId
                    -- TO DO make sure utxo is updated every pass, no in the end
                    let txPayload = map (\genericBlock -> case genericBlock of
                                                           Right block ->
                                                               let transactionsInBlock = block ^. mainBlockTxPayload . txpTxs
                                                                   outputs = utxoUnions $ map txOuts transactionsInBlock
                                                                   inputs = map _txInputs transactionsInBlock
                                                                   inputsToRemove = concat $ map toList inputs
                                                                   findUtxo = utxoToLookup utxo
                                                                   inputsE = concat $ map (catMaybes . map findUtxo) $ map toList inputs
                                                               in Just (inputsToRemove, (inputsE, outputs))
                                                           Left _  -> Nothing
                                        )
                                    $ getOldestFirst blocksDowloaded
                    --void $ print "txPayload :  "
                    --void $ print txPayload
                    now <- getCurrentTimestamp
                    --void $ print now
                    let createBlockContext arg1 arg2 arg3 =
                            if (arg2 == arg3) then
                                BlockContext (InDb $ arg1) (InDb $ arg2) (StrictMaybe.Nothing)
                            else
                                BlockContext (InDb $ arg1) (InDb $ arg2) (StrictMaybe.Just (InDb $ arg3))
                    let context = List.zipWith3 createBlockContext (catMaybes slotId) accomodatedHeaders prevHeaders
                    --void $ print context
                    let createResolvedTx txIn payload time =
                            let resolvedTxIn = fst payload
                                resolvedTxOut = (fst . snd) payload
                                theUtxo = (snd . snd) payload
                            in ResolvedTx (InDb $ NonEmpty.fromList $ zip resolvedTxIn resolvedTxOut) (InDb theUtxo) (InDb $ (txIn,time))
                    let  resolvedTxs =
                             map (\payload -> case List.nub (fst payload) of
                                                  [(TxInUtxo justOne _)]  -> Just $ createResolvedTx justOne payload now
                                                  _ -> Nothing
                                          ) $ catMaybes txPayload
                    --void $ print resolvedTxs
                    let createResolvedBlock resTx bCtx =
                            case resTx of
                                Just resolvedTx ->
                                    let (_, timestamp) = _fromDb $ _rtxMeta resolvedTx
                                    in ResolvedBlock [resolvedTx] bCtx timestamp
                                Nothing  ->
                                    ResolvedBlock [] bCtx now
                    let resolvedBlocks = List.zipWith createResolvedBlock resolvedTxs context
                    void $ print resolvedBlocks

                    --mapM_ (Kernel.applyBlock walletPassive) resolvedBlocks

                    void $ print "-------------- end tick 1 "
                    let utxoToAdd = map (snd . snd) $ catMaybes txPayload
                    let utxoAfterAddition = utxoUnions $ utxo : utxoToAdd
                    let utxoSetToDel = Set.fromList $ concat $ map fst $ catMaybes txPayload
                    let updatedUtxo = utxoRemoveInputs utxoAfterAddition utxoSetToDel
                    pure $ (([h1], (reverse accomodatedHeaders) ++ consumedHeader), updatedUtxo)
                _ -> do
                    void $ print "-------------- end tick 2 "
                    pure $ ((List.nub $ (headerHash header) : inProgressHeader, consumedHeader), utxo)
