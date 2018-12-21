{-# OPTIONS_GHC -fno-warn-type-defaults #-}
{-# LANGUAGE RankNTypes #-}
module Cardano.Wallet.Kernel.Diffusion (
    WalletDiffusion(..)
  , fromDiffusion
  ) where

import           Universum

import qualified Data.Map.Strict as Map

import           Pos.Chain.Block (Block, BlockHeader, HeaderHash, prevBlockL)
import           Pos.Chain.Txp (TxAux)
import           Pos.Core ()
import           Pos.Core.Chrono (OldestFirst (..))
import           Pos.DB.Block
import           Pos.Infra.Communication.Types.Protocol (NodeId)
import           Pos.Infra.Diffusion.Subscription.Status (SubscriptionStatus,
                     ssMap)
import           Pos.Infra.Diffusion.Types


-- | Wallet diffusion layer
--
-- Limited diffusion that the active wallet needs
--
-- This has two design objectives:
--
-- * We should be able to easily instantiate this from the unit tests
--   (with some kind of mock diffusion layer)
-- * We should be able to translate @Diffusion m@ into @WalletDiffusion@ for
--   any @m@ that we can lower to @IO@ (to isolate us from the specific monad
--   stacks that are used in the full node).
--
-- Note that the latter requirement implies avoiding functionality from the full
-- diffusion layer with negative occurrences of the monad parameter.
data WalletDiffusion = WalletDiffusion {
      -- | Submit a transaction to the network
      walletSendTx                :: TxAux -> IO Bool

      -- | Get subscription status (needed for the node settings endpoint)
    , walletGetSubscriptionStatus :: IO (Map NodeId SubscriptionStatus)

      -- | Request tip-of-chain from the network
    , walletRequestTip            :: IO (Map NodeId (IO BlockHeader))

      -- | Get blocks from checkpoint up to the header (not-included) from the node
    , walletGetBlocks
        :: NodeId
        -> HeaderHash
        -> [HeaderHash]
        -> IO (OldestFirst [] Block)

    }

-- | Extract necessary functionality from the full diffusion layer
fromDiffusion :: forall m ctx .
                 (MonadBlockVerify ctx m)
              => (forall a. m a -> IO a)
              -> Diffusion m
              -> WalletDiffusion
fromDiffusion nat d = WalletDiffusion {
      walletSendTx                = nat . sendTx d
    , walletGetSubscriptionStatus = readTVarIO $ ssMap (subscriptionStates d)
    , walletRequestTip            = do
           fromDiff <- nat $ requestTip d
           pure $ Map.map nat fromDiff
    , walletGetBlocks             =
            let
                getPrevBlock
                    :: NodeId
                    -> HeaderHash
                    -> Maybe HeaderHash
                    -> [Block]
                    -> m (OldestFirst [] Block)
                getPrevBlock nodeId from toMaybe blocksInThisBatch = do
                    --void $ print "*********"
                    --void $ print from
                    --void $ print toMaybe
                    --void $ print "*********"
                    downloadedBlock <- getBlocks d nodeId from [from]
                    let downloadedBlockStripped = getOldestFirst downloadedBlock
                    --void $ print toMaybe
                    case downloadedBlockStripped of
                        [block@(Right _)] -> do
                            -- here we are dealing with MainBlock
                            --void $ print "Right"
                            let prevBlockHeader = block ^. prevBlockL
                            --void $ print prevBlockHeader
                            case toMaybe of
                                Just upToHeader ->
                                    if (prevBlockHeader /= upToHeader) then
                                        -- still need to download backwards
                                        getPrevBlock nodeId prevBlockHeader toMaybe (block : blocksInThisBatch)
                                    else
                                    -- we just downloaded the last missing block
                                        pure $ OldestFirst $ block : blocksInThisBatch  --
                                Nothing -> do
                                    getPrevBlock nodeId prevBlockHeader Nothing (block : blocksInThisBatch)  --
                        [(Left _)] -> do
                            -- here we come to the GenesisBlock, we stop and we do not want to include it in a batch
                            --void $ print "Left"
                            pure $ OldestFirst blocksInThisBatch --
                        _ -> do
                            -- unexpected so returning current blocks in the batch
                            --void $ print "N"
                            pure $ OldestFirst blocksInThisBatch --
            in
            \nodeId from toNotIncluding -> do
                 case toNotIncluding of
                     [lastConsumedHeader] -> do
                         nat $ getPrevBlock nodeId from (Just lastConsumedHeader) []
                     _ -> do
                         nat $ getPrevBlock nodeId from Nothing []
    }
