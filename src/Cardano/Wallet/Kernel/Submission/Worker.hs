module Cardano.Wallet.Kernel.Submission.Worker (
    tickSubmissionLayer
    , tickDiffusionLayer
    ) where

import           Universum

import           Control.Concurrent (threadDelay)
import           Formatting (sformat, (%))
import qualified Formatting as F

import           Pos.Chain.Block (HeaderHash)
import           Pos.Chain.Txp (Utxo)
import           Pos.Util.Wlog (Severity (..))


tickSubmissionLayer :: forall m. (MonadCatch m, MonadIO m)
                    => (Severity -> Text -> m ())
                    -- ^ A logging function
                    -> IO ()
                    -- ^ A function to call at each 'tick' of the worker.
                    -- This callback will be responsible for doing any pre
                    -- and post processing of the state.
                    -> m ()
tickSubmissionLayer logFunction tick =
    go `catch` (\(e :: SomeException) ->
                   let msg = "Terminating tickSubmissionLayer due to " % F.shown
                   in logFunction Error (sformat msg e)
               )
    where
      go :: m ()
      go = do
          logFunction Debug "ticking the slot in the submission layer..."
          liftIO tick
          -- Wait 5 seconds between the next tick. In principle we could have
          -- chosen 20 seconds to make this delay match the @block time@ of the
          -- underlying protocol, but our submission layer's concept of time
          -- is completely independent by the time of the underlying blockchain,
          -- and this arbitrary choice of 5 seconds delay is yet another witness
          -- of such independence.
          liftIO $ threadDelay tickRate
          go

-- | The tick rate for resubmitting transactions. This value is documented in
-- @docs/RelatingWalletSpecToCardano.md@, and if this value is changed, then
-- section 10.4 should be updated.
tickRate :: Int
tickRate = 5000000


tickDiffusionLayer :: forall m. (MonadCatch m, MonadIO m)
                   => (Severity -> Text -> m ())
                      -- ^ A logging function
                   -> ((([HeaderHash],[HeaderHash]),Utxo) -> m (([HeaderHash],[HeaderHash]), Utxo))
                      -- ^ A function to call at each 'tick' of the worker.
                      -- This callback will be responsible for doing any pre
                      -- and post processing of the state.
                   -> (([HeaderHash],[HeaderHash]),Utxo)
                   -> m ()
tickDiffusionLayer logFunction tick start =
    go start `catch` (\(e :: SomeException) ->
                   let msg = "Terminating tickDiffusionLayer due to " % F.shown
                   in logFunction Error (sformat msg e)
               )
    where
      go :: (([HeaderHash],[HeaderHash]), Utxo) -> m ()
      go previousOutput  = do
          logFunction Debug "ticking the slot in the diffusion layer..."
          currentOutput <- tick previousOutput
          liftIO $ threadDelay tickDiffusionRate
          go currentOutput

tickDiffusionRate :: Int
tickDiffusionRate = 1000000
