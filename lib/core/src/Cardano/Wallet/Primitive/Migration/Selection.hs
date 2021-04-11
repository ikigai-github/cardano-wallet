{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}

module Cardano.Wallet.Primitive.Migration.Selection
    (
    ----------------------------------------------------------------------------
    -- Public interface
    ----------------------------------------------------------------------------

    -- * Classes
      Size (..)

    -- * Selection parameters
    , SelectionParameters (..)

    -- * Selections
    , Selection (..)
    , SelectionError (..)
    , SelectionFullError (..)

    -- * Creating a selection
    , create

    -- * Extending a selection
    , addInput
    , addRewardWithdrawal
    , SelectionAddInput

    ----------------------------------------------------------------------------
    -- Internal interface
    ----------------------------------------------------------------------------

    -- * Computing bulk properties of a selection
    , computeCurrentFee
    , computeCurrentSize
    , computeMinimumFee

    -- * Selection parameter functions
    , costOfOutputCoin
    , excessAdaForOutput
    , minimumAdaQuantityForOutputCoin
    , outputIsValid
    , outputSatisfiesMinimumAdaQuantity
    , outputSizeWithinLimit
    , sizeOfOutputCoin

    -- * Selection invariants
    , SelectionInvariantStatus (..)
    , checkInvariant

    -- * Selection queries
    , outputOrdering

    -- * Adding entries to selections
    , addInputToExistingOutput
    , addInputToNewOutput
    , addInputToNewOutputWithoutReclaimingAda

    -- * Coalescing token bundles
    , coalesceOutputs

    -- * Reclaiming ada from outputs
    , ReclaimAdaResult (..)
    , reclaimAda

    -- * Minimizing fee excess
    , minimizeFeeExcess
    , minimizeFeeExcessForOutput

    -- * Miscellaneous functions
    , findFixedPoint

    ) where

import Prelude

import Cardano.Wallet.Primitive.Types.Coin
    ( Coin (..), subtractCoin )
import Cardano.Wallet.Primitive.Types.TokenBundle
    ( TokenBundle (..) )
import Cardano.Wallet.Primitive.Types.TokenMap
    ( TokenMap )
import Cardano.Wallet.Primitive.Types.TokenQuantity
    ( TokenQuantity )
import Data.Either.Extra
    ( eitherToMaybe, maybeToEither )
import Data.Function
    ( (&) )
import Data.Functor
    ( (<&>) )
import Data.Generics.Internal.VL.Lens
    ( view )
import Data.Generics.Labels
    ()
import Data.List.NonEmpty
    ( NonEmpty (..) )
import Data.Maybe
    ( catMaybes, fromMaybe, mapMaybe, listToMaybe )
import Data.Ord
    ( comparing )
import GHC.Generics
    ( Generic )

import qualified Cardano.Wallet.Primitive.Types.Coin as Coin
import qualified Cardano.Wallet.Primitive.Types.TokenBundle as TokenBundle
import qualified Cardano.Wallet.Primitive.Types.TokenMap as TokenMap
import qualified Data.Foldable as F
import qualified Data.List as L
import qualified Data.List.NonEmpty as NE

--------------------------------------------------------------------------------
-- Selection parameters
--------------------------------------------------------------------------------

data SelectionParameters s = SelectionParameters
    { costOfEmptySelection :: Coin
      -- ^ The constant cost of an empty selection.
    , costOfInput :: Coin
      -- ^ The constant cost of a selection input.
    , costOfOutput :: TokenBundle -> Coin
      -- ^ The variable cost of a selection output.
    , costOfRewardWithdrawal :: Coin -> Coin
      -- ^ The variable cost of a reward withdrawal.
    , sizeOfEmptySelection :: s
      -- ^ The constant size of an empty selection.
    , sizeOfInput :: s
      -- ^ The constant size of a selection input.
    , sizeOfOutput :: TokenBundle -> s
      -- ^ The variable size of a selection output.
    , sizeOfRewardWithdrawal :: Coin -> s
      -- ^ The variable size of a reward withdrawal.
    , maximumSizeOfOutput :: s
      -- ^ The maximum size of a selection output.
    , maximumSizeOfSelection :: s
      -- ^ The maximum size of a selection.
    , maximumTokenQuantity :: TokenQuantity
      -- ^ The maximum token quantity of an output.
    , minimumAdaQuantityForOutput :: TokenMap -> Coin
      -- ^ The variable minimum ada quantity for an output.
    }

--------------------------------------------------------------------------------
-- Selection parameter functions
--------------------------------------------------------------------------------

costOfOutputCoin :: SelectionParameters s -> Coin -> Coin
costOfOutputCoin params = costOfOutput params . TokenBundle.fromCoin

excessAdaForOutput :: SelectionParameters s -> TokenBundle -> Coin
excessAdaForOutput params bundle =
    fromMaybe (Coin 0) result
  where
    result = subtractCoin
        (view #coin bundle)
        (minimumAdaQuantityForOutput params $ view #tokens bundle)

minimumAdaQuantityForOutputCoin :: SelectionParameters s -> Coin
minimumAdaQuantityForOutputCoin =
    flip minimumAdaQuantityForOutput TokenMap.empty

sizeOfOutputCoin :: SelectionParameters s -> Coin -> s
sizeOfOutputCoin params = sizeOfOutput params . TokenBundle.fromCoin

outputIsValid
    :: forall s. Size s
    => SelectionParameters s
    -> TokenBundle
    -> Bool
outputIsValid params b = and $ conditions <&> (\f -> f params b)
  where
    conditions :: [SelectionParameters s -> TokenBundle -> Bool]
    conditions =
        [ outputSatisfiesMinimumAdaQuantity
        , outputSizeWithinLimit
        ]

outputSatisfiesMinimumAdaQuantity
    :: SelectionParameters s -> TokenBundle -> Bool
outputSatisfiesMinimumAdaQuantity params (TokenBundle c m) =
    c >= minimumAdaQuantityForOutput params m

outputSizeWithinLimit :: Size s => SelectionParameters s -> TokenBundle -> Bool
outputSizeWithinLimit params b =
    sizeOfOutput params b <= maximumSizeOfOutput params

--------------------------------------------------------------------------------
-- Selections
--------------------------------------------------------------------------------

data Selection i s = Selection
    { inputs :: NonEmpty (i, TokenBundle)
      -- ^ The selected inputs, in the reverse order to which they were added.
    , outputs :: NonEmpty TokenBundle
      -- ^ The generated outputs, in descending order of excess ada.
    , feeExcess :: !Coin
      -- ^ The excess over the minimum permissible fee for this selection.
    , size :: !s
      -- ^ The current size of this selection.
    , rewardWithdrawal :: !Coin
      -- ^ The reward withdrawal amount, if any.
    }
    deriving (Eq, Generic, Show)

--------------------------------------------------------------------------------
-- Selection invariants
--------------------------------------------------------------------------------

data SelectionInvariantStatus s
    = SelectionInvariantHolds
    | SelectionInvariantAssetBalanceIncorrect
      SelectionInvariantAssetBalanceIncorrectError
    | SelectionInvariantFeeExcessIncorrect
      SelectionInvariantFeeExcessIncorrectError
    | SelectionInvariantFeeInsufficient
      SelectionInvariantFeeInsufficientError
    | SelectionInvariantOutputBelowMinimumAdaQuantity
      SelectionInvariantOutputBelowMinimumAdaQuantityError
    | SelectionInvariantOutputSizeExceedsLimit
      SelectionInvariantOutputSizeExceedsLimitError
    | SelectionInvariantOutputOrderIncorrect
      SelectionInvariantOutputOrderIncorrectError
    | SelectionInvariantSizeExceedsLimit
     (SelectionInvariantSizeExceedsLimitError s)
    | SelectionInvariantSizeIncorrect
     (SelectionInvariantSizeIncorrectError s)
    deriving (Eq, Show)

checkInvariant
    :: Size s
    => SelectionParameters s
    -> Selection i s
    -> SelectionInvariantStatus s
checkInvariant params selection
    | Just e <- checkAssetBalance selection =
        SelectionInvariantAssetBalanceIncorrect e
    | Just e <- checkFeeSufficient params selection =
        SelectionInvariantFeeInsufficient e
    | Just e <- checkFeeExcess params selection =
        SelectionInvariantFeeExcessIncorrect e
    | Just e <- checkOutputMinimumAdaQuantities params selection =
        SelectionInvariantOutputBelowMinimumAdaQuantity e
    | Just e <- checkOutputSizes params selection =
        SelectionInvariantOutputSizeExceedsLimit e
    | Just e <- checkOutputOrder params selection =
        SelectionInvariantOutputOrderIncorrect e
    | Just e <- checkSizeWithinLimit params selection =
        SelectionInvariantSizeExceedsLimit e
    | Just e <- checkSizeCorrectness params selection =
        SelectionInvariantSizeIncorrect e
    | otherwise =
        SelectionInvariantHolds

--------------------------------------------------------------------------------
-- Selection invariant: asset balance correctness
--------------------------------------------------------------------------------

data SelectionInvariantAssetBalanceIncorrectError =
    SelectionInvariantAssetBalanceIncorrectError
        { assetBalanceInputs
            :: TokenMap
        , assetBalanceOutputs
            :: TokenMap
        }
    deriving (Eq, Show)

checkAssetBalance
    :: Selection i s
    -> Maybe SelectionInvariantAssetBalanceIncorrectError
checkAssetBalance Selection {inputs, outputs}
    | assetBalanceInputs == assetBalanceOutputs =
        Nothing
    | otherwise =
        Just SelectionInvariantAssetBalanceIncorrectError
            { assetBalanceInputs
            , assetBalanceOutputs
            }
  where
    assetBalanceInputs = F.foldMap (tokens . snd) inputs
    assetBalanceOutputs = F.foldMap (tokens) outputs

--------------------------------------------------------------------------------
-- Selection invariant: fee excess correctness
--------------------------------------------------------------------------------

data SelectionInvariantFeeExcessIncorrectError =
    SelectionInvariantFeeExcessIncorrectError
        { selectionFeeExcessActual
            :: Coin
        , selectionFeeExcessExpected
            :: Coin
        }
    deriving (Eq, Show)

checkFeeExcess
    :: SelectionParameters s
    -> Selection i s
    -> Maybe SelectionInvariantFeeExcessIncorrectError
checkFeeExcess params selection =
    check =<< eitherToMaybe (computeCurrentFee selection)
  where
    check :: Coin -> Maybe SelectionInvariantFeeExcessIncorrectError
    check currentSelectionFee
        | selectionFeeExcessExpected == selectionFeeExcessActual =
            Nothing
        | otherwise =
            Just SelectionInvariantFeeExcessIncorrectError
                { selectionFeeExcessActual
                , selectionFeeExcessExpected
                }
      where
        selectionFeeExcessActual = feeExcess selection
        selectionFeeExcessExpected = Coin.distance
            (currentSelectionFee)
            (computeMinimumFee params selection)

--------------------------------------------------------------------------------
-- Selection invariant: fee sufficiency
--------------------------------------------------------------------------------

data SelectionInvariantFeeInsufficientError =
    SelectionInvariantFeeInsufficientError
        { selectionFeeActual
            :: Either NegativeCoin Coin
        , selectionFeeMinimum
            :: Coin
        }
    deriving (Eq, Show)

checkFeeSufficient
    :: SelectionParameters s
    -> Selection i s
    -> Maybe SelectionInvariantFeeInsufficientError
checkFeeSufficient params selection =
    case computeCurrentFee selection of
        Left nf ->
            Just SelectionInvariantFeeInsufficientError
                { selectionFeeActual = Left nf
                , selectionFeeMinimum
                }
        Right pf | pf < selectionFeeMinimum ->
            Just SelectionInvariantFeeInsufficientError
                { selectionFeeActual = Right pf
                , selectionFeeMinimum
                }
        Right _ ->
            Nothing
  where
    selectionFeeMinimum = computeMinimumFee params selection

--------------------------------------------------------------------------------
-- Selection invariant: minimum ada quantities
--------------------------------------------------------------------------------

data SelectionInvariantOutputBelowMinimumAdaQuantityError =
    SelectionInvariantOutputBelowMinimumAdaQuantityError
        { outputBundle :: TokenBundle
          -- ^ The output that is below the expected minimum ada quantity.
        , expectedMinimumAdaQuantity :: Coin
          -- ^ The expected minimum ada quantity.
        }
    deriving (Eq, Show)

checkOutputMinimumAdaQuantities
    :: SelectionParameters s
    -> Selection i s
    -> Maybe SelectionInvariantOutputBelowMinimumAdaQuantityError
checkOutputMinimumAdaQuantities params selection =
     maybesToMaybe $ checkOutput <$> outputs selection
  where
    checkOutput
        :: TokenBundle
        -> Maybe SelectionInvariantOutputBelowMinimumAdaQuantityError
    checkOutput outputBundle
        | TokenBundle.getCoin outputBundle >= expectedMinimumAdaQuantity =
            Nothing
        | otherwise =
            Just SelectionInvariantOutputBelowMinimumAdaQuantityError
                { outputBundle
                , expectedMinimumAdaQuantity
                }
      where
        expectedMinimumAdaQuantity =
            minimumAdaQuantityForOutput params (view #tokens outputBundle)

--------------------------------------------------------------------------------
-- Selection invariant: output sizes
--------------------------------------------------------------------------------

data SelectionInvariantOutputSizeExceedsLimitError =
    SelectionInvariantOutputSizeExceedsLimitError
        { selectionOutput :: TokenBundle }
    deriving (Eq, Show)

checkOutputSizes
    :: Size s
    => SelectionParameters s
    -> Selection i s
    -> Maybe SelectionInvariantOutputSizeExceedsLimitError
checkOutputSizes params selection =
     maybesToMaybe $ checkOutput <$> outputs selection
  where
    checkOutput
        :: TokenBundle
        -> Maybe SelectionInvariantOutputSizeExceedsLimitError
    checkOutput selectionOutput
        | outputSizeWithinLimit params selectionOutput =
            Nothing
        | otherwise =
            Just SelectionInvariantOutputSizeExceedsLimitError
                { selectionOutput }

--------------------------------------------------------------------------------
-- Selection invariant: output ordering
--------------------------------------------------------------------------------

data SelectionInvariantOutputOrderIncorrectError =
    SelectionInvariantOutputOrderIncorrectError
    deriving (Eq, Show)

checkOutputOrder
    :: SelectionParameters s
    -> Selection i s
    -> Maybe SelectionInvariantOutputOrderIncorrectError
checkOutputOrder params selection
    | orderActual == orderExpected =
        Nothing
    | otherwise =
        Just SelectionInvariantOutputOrderIncorrectError
  where
    orderActual =
        outputs selection
    orderExpected =
        NE.sortBy (outputOrdering params) (outputs selection)

--------------------------------------------------------------------------------
-- Selection invariant: selection size (in comparison to the stored value)
--------------------------------------------------------------------------------

data SelectionInvariantSizeIncorrectError s =
    SelectionInvariantSizeIncorrectError
        { selectionSizeComputed :: s
        , selectionSizeStored :: s
        }
    deriving (Eq, Show)

checkSizeCorrectness
    :: (Eq s, Monoid s)
    => SelectionParameters s
    -> Selection i s
    -> Maybe (SelectionInvariantSizeIncorrectError s)
checkSizeCorrectness params selection
    | selectionSizeComputed == selectionSizeStored =
        Nothing
    | otherwise = pure SelectionInvariantSizeIncorrectError
        { selectionSizeComputed
        , selectionSizeStored
        }
  where
    selectionSizeComputed = computeCurrentSize params selection
    selectionSizeStored = size selection

--------------------------------------------------------------------------------
-- Selection invariant: selection size (in comparison to the limit)
--------------------------------------------------------------------------------

data SelectionInvariantSizeExceedsLimitError s =
    SelectionInvariantSizeExceedsLimitError
        { selectionSizeComputed :: s
        , selectionSizeMaximum :: s
        }
    deriving (Eq, Show)

checkSizeWithinLimit
    :: (Monoid s, Ord s)
    => SelectionParameters s
    -> Selection i s
    -> Maybe (SelectionInvariantSizeExceedsLimitError s)
checkSizeWithinLimit params selection
    | selectionSizeComputed <= selectionSizeMaximum =
        Nothing
    | otherwise = pure SelectionInvariantSizeExceedsLimitError
        { selectionSizeComputed
        , selectionSizeMaximum
        }
  where
    selectionSizeComputed = computeCurrentSize params selection
    selectionSizeMaximum = maximumSizeOfSelection params

--------------------------------------------------------------------------------
-- Selection query functions
--------------------------------------------------------------------------------

-- | Calculates the current fee for a selection.
--
computeCurrentFee :: Selection i s -> Either NegativeCoin Coin
computeCurrentFee Selection {inputs, outputs, rewardWithdrawal}
    | adaBalanceIn >= adaBalanceOut =
        Right adaDifference
    | otherwise =
        Left (NegativeCoin adaDifference)
  where
    adaBalanceIn =
        F.foldMap (TokenBundle.getCoin . snd) inputs <> rewardWithdrawal
    adaBalanceOut =
        F.foldMap (TokenBundle.getCoin) outputs
    adaDifference =
        Coin.distance adaBalanceIn adaBalanceOut

computeFeeExcess
    :: SelectionParameters s -> Selection i s -> Maybe Coin
computeFeeExcess params selection = case computeCurrentFee selection of
    Right currentFee | currentFee >= minimumFee ->
        Just $ Coin.distance currentFee minimumFee
    _ ->
        Nothing
  where
    minimumFee = computeMinimumFee params selection

-- | Calculates the current size of a selection.
--
computeCurrentSize
    :: Monoid s
    => SelectionParameters s
    -> Selection i s
    -> s
computeCurrentSize params selection = mconcat
    [ sizeOfEmptySelection params
    , F.foldMap (const $ sizeOfInput params) (inputs selection)
    , F.foldMap (sizeOfOutput params) (outputs selection)
    , sizeOfRewardWithdrawal params (rewardWithdrawal selection)
    ]

-- | Calculates the minimum permissible fee for a selection.
--
computeMinimumFee :: SelectionParameters s -> Selection i s -> Coin
computeMinimumFee params selection = mconcat
    [ costOfEmptySelection params
    , F.foldMap (const $ costOfInput params) (inputs selection)
    , F.foldMap (costOfOutput params) (outputs selection)
    , costOfRewardWithdrawal params (rewardWithdrawal selection)
    ]

-- | Defines the correct ordering of outputs in a selection.
--
outputOrdering
    :: SelectionParameters s
    -> TokenBundle
    -> TokenBundle
    -> Ordering
outputOrdering params =
    comparing (minimumAdaQuantityForOutput params . view #tokens)

--------------------------------------------------------------------------------
-- Selection errors
--------------------------------------------------------------------------------

data SelectionError s
    = SelectionAdaInsufficient
    | SelectionFull
     (SelectionFullError s)
    deriving (Eq, Show)

data SelectionFullError s = SelectionFullError
    { selectionSizeMaximum :: s
    , selectionSizeRequired :: s
    }
    deriving (Eq, Show)

--------------------------------------------------------------------------------
-- Creating a selection
--------------------------------------------------------------------------------

create
    :: forall i s. Size s
    => SelectionParameters s
    -> Coin
    -> NonEmpty (i, TokenBundle)
    -> Either (SelectionError s) (Selection i s)
create params rewardWithdrawal inputs = do
    let minimizedOutputs = minimizeOutput params <$> NE.sortBy
            (outputOrdering params)
            (coalesceOutputs params $ snd <$> inputs)
    let unbalancedSelection = Selection
            { inputs
            , outputs = minimizedOutputs
            , feeExcess = Coin 0
            , size = mempty
            , rewardWithdrawal
            }
    currentFeeExcess <- maybeToEither SelectionAdaInsufficient $
        computeFeeExcess params unbalancedSelection
    let (feeExcess, outputs) =
            minimizeFeeExcess params (currentFeeExcess, minimizedOutputs)
    let balancedSelection = unbalancedSelection {feeExcess, outputs}
    size <- guardSize params $ computeCurrentSize params balancedSelection
    pure balancedSelection {size}

--------------------------------------------------------------------------------
-- Extending a selection
--------------------------------------------------------------------------------

type SelectionAddInput s i =
    SelectionParameters s
        -> Selection i s
        -> (i, TokenBundle)
        -> Either (SelectionError s) (Selection i s)

addInput
    :: forall s i. Size s
    => SelectionAddInput s i
addInput = addInputWithFirstSuccessfulStrategy
    [ addInputToExistingOutput
    , addInputToNewOutput
    ]

addInputWithFirstSuccessfulStrategy
    :: NonEmpty (SelectionAddInput s i)
    -> SelectionAddInput s i
addInputWithFirstSuccessfulStrategy strategies params selection input =
    eithersToEither $ strategies <&> (\s -> s params selection input)

addRewardWithdrawal
    :: Selection i s
    -> Coin
    -> Selection i s
addRewardWithdrawal selection withdrawal = selection
    -- TODO: check that the invariant is not violated.
    { rewardWithdrawal = rewardWithdrawal selection <> withdrawal
    , feeExcess = feeExcess selection <> withdrawal
    }

--------------------------------------------------------------------------------
-- Adding bundles to a selection
--------------------------------------------------------------------------------

addInputToExistingOutput
    :: forall s i. Size s
    => SelectionAddInput s i
addInputToExistingOutput params selection (inputId, inputBundle) = do
    (bundleIndex, originalBundle, mergedBundle) <- findFirstValidMergedBundle
    newSize <- computeNewSize originalBundle mergedBundle
    newFeeExcess <- computeNewFeeExcess originalBundle mergedBundle
    let (prefix, suffix) = drop 1 <$> NE.splitAt bundleIndex (outputs selection)
    let remainingOutputs = prefix <> suffix
    case remainingOutputs of
        [] -> pure
            $ selection
                { size = newSize
                , feeExcess = newFeeExcess
                , outputs = mergedBundle :| []
                }
            & unsafeAddInput (inputId, inputBundle)
        o : os -> pure
            $ selection
                { size = newSize
                , feeExcess = newFeeExcess
                , outputs = o :| os
                }
            & unsafeAddInput (inputId, inputBundle)
            & unsafeAddOutput params mergedBundle
  where
    computeNewFeeExcess
        :: TokenBundle -> TokenBundle -> Either (SelectionError s) Coin
    computeNewFeeExcess originalBundle mergedBundle =
        maybeToEither SelectionAdaInsufficient $ coinFromInteger
            $ coinToInteger (feeExcess selection)
            + coinToInteger (TokenBundle.getCoin inputBundle)
            + coinToInteger (TokenBundle.getCoin originalBundle)
            - coinToInteger (TokenBundle.getCoin mergedBundle)
            + coinToInteger (costOfOutput params originalBundle)
            - coinToInteger (costOfOutput params mergedBundle)
            - coinToInteger (costOfInput params)

    computeNewSize
        :: TokenBundle -> TokenBundle -> Either (SelectionError s) s
    computeNewSize originalBundle mergedBundle = guardSize params $ mconcat
        [ size selection
        , sizeOfInput params
        , sizeDistance
            (sizeOfOutput params originalBundle)
            (sizeOfOutput params mergedBundle)
        ]

    findFirstValidMergedBundle
        :: Either (SelectionError s) (Int, TokenBundle, TokenBundle)
    findFirstValidMergedBundle = maybeToEither SelectionAdaInsufficient
        $ outputs selection
        & NE.toList
        & zip [0 ..]
        & mapMaybe (\(i, b) -> (i, b, ) <$> mergeBundle b)
        & listToMaybe
      where
        mergeBundle :: TokenBundle -> Maybe TokenBundle
        mergeBundle outputBundle
            | Just mergedBundle <- computeMergedBundle
            , outputIsValid params mergedBundle =
                Just mergedBundle
            | otherwise =
                Nothing
          where
            computeMergedBundle :: Maybe TokenBundle
            computeMergedBundle = TokenBundle.setCoin mergedUnadjustedBundle
                <$> computeNewCoinValue

            computeNewCoinValue :: Maybe Coin
            computeNewCoinValue = coinFromInteger
                $ coinToInteger (TokenBundle.getCoin mergedUnadjustedBundle)
                - coinToInteger (costOfInput params)
                - coinToInteger (costOfOutput params mergedUnadjustedBundle)
                + coinToInteger (costOfOutput params outputBundle)

            mergedUnadjustedBundle :: TokenBundle
            mergedUnadjustedBundle = mconcat
                [ inputBundle
                , outputBundle
                , TokenBundle.fromCoin (feeExcess selection)
                ]

addInputToNewOutput
    :: forall s i. Size s
    => SelectionAddInput s i
addInputToNewOutput params selection input@(inputId, inputBundle)
    | adaToReclaim == Coin 0 =
        addInputToNewOutputWithoutReclaimingAda
            params selection (inputId, inputBundle)
    | adaToReclaim >= Coin 1 && adaToReclaim <= feeExcess selection = do
        let reducedFeeExcess =
                Coin.distance (feeExcess selection) adaToReclaim
        let inputBundleWithIncreasedAda =
                TokenBundle.adjustCoin inputBundle (<> adaToReclaim)
        updatedSelection <- addInputToNewOutputWithoutReclaimingAda
            (params)
            (selection {feeExcess = reducedFeeExcess})
            (inputId, inputBundleWithIncreasedAda)
        pure updatedSelection
            {inputs = replaceHeadOfList (inputs updatedSelection) input}
    | otherwise = do
        ReclaimAdaResult {reducedOutputs}
            <- maybeToEither SelectionAdaInsufficient $
                reclaimAda
                    (params)
                    (Coin.distance adaToReclaim (feeExcess selection))
                    (outputs selection)
        let inputBundleWithIncreasedAda =
                TokenBundle.adjustCoin inputBundle (<> adaToReclaim)
        updatedSelection <- addInputToNewOutputWithoutReclaimingAda
            (params)
            (selection {feeExcess = Coin 0, outputs = reducedOutputs})
            (inputId, inputBundleWithIncreasedAda)
        pure updatedSelection
            {inputs = replaceHeadOfList (inputs updatedSelection) input}
  where
    adaToReclaim :: Coin
    adaToReclaim = fromMaybe (Coin 0)
        $ coinFromInteger
        $ coinToInteger (costOfInput params)
        + coinToInteger (costOfOutput params inputBundle)
        + coinToInteger (minimumAdaQuantityForOutput params inputMap)
        - coinToInteger inputCoin

    TokenBundle inputCoin inputMap = inputBundle

addInputToNewOutputWithoutReclaimingAda
    :: forall s i. Size s
    => SelectionAddInput s i
addInputToNewOutputWithoutReclaimingAda
    params selection (inputId, inputBundle) = do
          outputCoin <- computeOutputCoin
          let outputBundle = TokenBundle outputCoin inputMap
          newSize <- computeNewSize outputBundle
          let newFeeExcess = feeExcess selection <> Coin.distance
                  (costOfOutput params inputBundle)
                  (costOfOutput params outputBundle)
          pure
              $ selection {feeExcess = newFeeExcess, size = newSize}
              & unsafeAddInput (inputId, inputBundle)
              & unsafeAddOutput params outputBundle
  where
    TokenBundle inputCoin inputMap = inputBundle

    computeOutputCoin :: Either (SelectionError s) Coin
    computeOutputCoin = do
        outputCoin <- maybeToEither SelectionAdaInsufficient
            $ coinFromInteger
            $ coinToInteger inputCoin
            - coinToInteger (costOfInput params)
            - coinToInteger (costOfOutput params inputBundle)
        guardE (outputCoin >= minimumAdaQuantityForOutput params inputMap)
            SelectionAdaInsufficient
        pure outputCoin

    computeNewSize :: TokenBundle -> Either (SelectionError s) s
    computeNewSize outputBundle = guardSize params $ mconcat
        [ size selection
        , sizeOfInput params
        , sizeOfOutput params outputBundle
        ]

unsafeAddInput
    :: (i, TokenBundle)
    -> Selection i s
    -> Selection i s
unsafeAddInput input selection = selection
    { inputs = NE.cons input (inputs selection) }

unsafeAddOutput
    :: SelectionParameters s
    -> TokenBundle
    -> Selection i s
    -> Selection i s
unsafeAddOutput params outputBundle selection = selection
    { outputs = NE.fromList $ L.insertBy
        (outputOrdering params)
        (outputBundle)
        (NE.toList $ outputs selection)
    }

--------------------------------------------------------------------------------
-- Coalescing bundles
--------------------------------------------------------------------------------

coalesceOutputs
    :: Size s
    => SelectionParameters s
    -> NonEmpty TokenBundle
    -> NonEmpty TokenBundle
coalesceOutputs params = splitBundleIfLimitsExceeded params . F.fold

-- TODO: We can do better, by trying to merge each new bundle with each of the
-- already coalesced bundles.
{-
coalesceOutputs2
    :: Size s
    => SelectionParameters s
    -> NonEmpty TokenBundle
    -> NonEmpty TokenBundle
coalesceOutputs2 params bundles = NE.fromList $ coalesce (NE.toList bundles) []
  where
    coalesce [] coalesced =
        coalesced
    coalesce (b1 : remaining) (b2 : coalesced)
        | Just b3 <- safeCoalesceOutputs params b1 b2 =
            coalesce remaining (b3 : coalesced)
    coalesce (b : remaining) coalesced =
        coalesce remaining (b : coalesced)
-}
{-
coalesceOutputs
    :: SelectionParameters s
    -> NonEmpty TokenBundle
    -> NonEmpty TokenBundle
coalesceOutputs params (bundle :| bundles) =
    L.foldl' (\acc b -> insertOutput params b acc) (bundle :| []) bundles

insertOutput
    :: SelectionParameters s
    -> TokenBundle
    -> NonEmpty TokenBundle
    -> NonEmpty TokenBundle
insertOutput params bundle bundles = NE.fromList $ run (NE.toList bundles) []
  where
    run [] processed =
        bundle : processed
    run (b1 : remaining) processed
        | Just b2 <- safeCoalesceOutputs params bundle b1 =
            b2 : (remaining <> processed)
    run (b1 : remaining) processed =
        run remaining (b1 : processed)
-}
{-
safeCoalesceOutputs
    :: Size s
    => SelectionParameters s
    -> TokenBundle
    -> TokenBundle
    -> Maybe TokenBundle
safeCoalesceOutputs params b1 b2
    | outputSizeWithinLimit params coalescedOutputWithMaxAda =
        Just coalescedOutput
    | otherwise =
        Nothing
  where
    coalescedOutput = b1 <> b2
    coalescedOutputWithMaxAda = TokenBundle.setCoin coalescedOutput maxBound
-}
minimizeOutput :: SelectionParameters s -> TokenBundle -> TokenBundle
minimizeOutput params output
    = TokenBundle.setCoin output
    $ minimumAdaQuantityForOutput params (view #tokens output)

--------------------------------------------------------------------------------
-- Reclaiming ada from outputs
--------------------------------------------------------------------------------

data ReclaimAdaResult s = ReclaimAdaResult
    { reducedOutputs :: NonEmpty TokenBundle
    , costReduction :: Coin
    , sizeReduction :: s
    , excessReclaimedAda :: Coin
    }

-- Pre-condition (needs to be checked): all bundles have at least their
-- minimum ada quantities (or else return 'Nothing').
--
-- Pre-condition (not checked): outputs are in order of their minimum ada
-- quantity.
--
reclaimAda
    :: Size s
    => SelectionParameters s
    -> Coin
    -- ^ Quantity of ada to reclaim
    -> NonEmpty TokenBundle
    -- ^ Outputs from which to reclaim ada
    -> Maybe (ReclaimAdaResult s)
reclaimAda params totalAdaToReclaim outputs
    | totalReclaimableAda < totalAdaToReclaim =
        Nothing
    | any (not . outputSatisfiesMinimumAdaQuantity params) outputs =
        Nothing
    | otherwise =
        Just ReclaimAdaResult
            { reducedOutputs
            , costReduction
            , sizeReduction
            , excessReclaimedAda
            }
  where
    (excessReclaimedAda, reducedOutputs) = NE.fromList <$>
        run feeExcessAtStart (NE.toList outputsWithMinimumAda) []

    costReduction = Coin.distance
        (F.foldMap (costOfOutputCoin params . view #coin) outputs)
        (F.foldMap (costOfOutputCoin params . view #coin) reducedOutputs)

    sizeReduction = sizeDistance
        (F.foldMap (sizeOfOutputCoin params . view #coin) outputs)
        (F.foldMap (sizeOfOutputCoin params . view #coin) reducedOutputs)

    run :: Coin -> [TokenBundle] -> [TokenBundle] -> (Coin, [TokenBundle])
    run (Coin 0) remaining processed =
        (Coin 0, insertManyBy (outputOrdering params) remaining processed)
    run feeExcessRemaining [] processed =
        (feeExcessRemaining, L.sortBy (outputOrdering params) processed)
    run feeExcessRemaining (output : remaining) processed =
        run feeExcessRemaining' remaining (output' : processed)
      where
        (feeExcessRemaining', output') =
            minimizeFeeExcessForOutput params (feeExcessRemaining, output)

    feeExcessAtStart :: Coin
    feeExcessAtStart = Coin.distance totalReclaimableAda totalAdaToReclaim

    totalReclaimableAda :: Coin
    totalReclaimableAda = totalCostOfExcessAda <> totalExcessAda

    totalExcessAda :: Coin
    totalExcessAda = F.foldMap (excessAdaForOutput params) outputs

    totalCostOfExcessAda :: Coin
    totalCostOfExcessAda = F.foldMap costOfExcessAdaForOutput outputs

    outputsWithMinimumAda :: NonEmpty TokenBundle
    outputsWithMinimumAda = minimizeAda <$> outputs

    costOfExcessAdaForOutput :: TokenBundle -> Coin
    costOfExcessAdaForOutput output = Coin.distance
        (costOfOutputCoin params (view #coin output))
        (costOfOutputCoin params (view #coin (minimizeAda output)))

    minimizeAda :: TokenBundle -> TokenBundle
    minimizeAda output
        = TokenBundle.setCoin output
        $ minimumAdaQuantityForOutput params (view #tokens output)

--------------------------------------------------------------------------------
-- Minimizing the fee excess
--------------------------------------------------------------------------------

minimizeFeeExcess
    :: SelectionParameters s
    -> (Coin, NonEmpty TokenBundle)
    -- ^ Fee excess and output bundles.
    -> (Coin, NonEmpty TokenBundle)
    -- ^ Fee excess and output bundles after optimization.
minimizeFeeExcess params (currentFeeExcess, outputs) =
    NE.fromList <$> run currentFeeExcess (NE.toList outputs) []
  where
    run :: Coin -> [TokenBundle] -> [TokenBundle] -> (Coin, [TokenBundle])
    run (Coin 0) remaining processed =
        (Coin 0, insertManyBy (outputOrdering params) remaining processed)
    run feeExcessRemaining [] processed =
        (feeExcessRemaining, L.sortBy (outputOrdering params) processed)
    run feeExcessRemaining (output : remaining) processed =
        run feeExcessRemaining' remaining (output' : processed)
      where
        (feeExcessRemaining', output') =
            minimizeFeeExcessForOutput params (feeExcessRemaining, output)

minimizeFeeExcessForOutput
    :: SelectionParameters s
    -> (Coin, TokenBundle)
    -- ^ Fee excess and output bundle.
    -> (Coin, TokenBundle)
    -- ^ Fee excess and output bundle after optimization.
minimizeFeeExcessForOutput params =
    findFixedPoint reduceFeeExcess
  where
    reduceFeeExcess :: (Coin, TokenBundle) -> (Coin, TokenBundle)
    reduceFeeExcess (feeExcess, outputBundle) =
        (feeExcessFinal, TokenBundle.setCoin outputBundle outputCoinFinal)
      where
        outputCoin = view #coin outputBundle
        outputCoinMaxCostIncrease = Coin.distance
            (costOfOutputCoin params outputCoin)
            (costOfOutputCoin params $ outputCoin <> feeExcess)
        outputCoinFinal = Coin
            $ unCoin outputCoin
            + unCoin feeExcess
            - unCoin outputCoinMaxCostIncrease
        outputCoinFinalCostIncrease = Coin.distance
            (costOfOutputCoin params outputCoin)
            (costOfOutputCoin params outputCoinFinal)
        outputCoinFinalIncrease = Coin.distance outputCoin outputCoinFinal
        feeExcessFinal = Coin
            $ unCoin feeExcess
            - unCoin outputCoinFinalIncrease
            - unCoin outputCoinFinalCostIncrease

--------------------------------------------------------------------------------
-- Splitting bundles
--------------------------------------------------------------------------------

splitBundleIfLimitsExceeded
    :: Size s
    => SelectionParameters s
    -> TokenBundle
    -> NonEmpty TokenBundle
splitBundleIfLimitsExceeded params b
    = splitBundlesWithExcessiveTokenQuantities params
    $ splitBundlesWithExcessiveSizes params
    $ b :| []

splitBundlesWithExcessiveSizes
    :: Size s
    => SelectionParameters s
    -> NonEmpty TokenBundle
    -> NonEmpty TokenBundle
splitBundlesWithExcessiveSizes params bs =
    splitBundleIfSizeExceedsLimit params =<< bs

splitBundlesWithExcessiveTokenQuantities
    :: SelectionParameters s
    -> NonEmpty TokenBundle
    -> NonEmpty TokenBundle
splitBundlesWithExcessiveTokenQuantities params bs =
    (`TokenBundle.equipartitionQuantitiesWithUpperBound` maxQuantity) =<< bs
  where
    maxQuantity = maximumTokenQuantity params

splitBundleIfSizeExceedsLimit
    :: Size s
    => SelectionParameters s
    -> TokenBundle
    -> NonEmpty TokenBundle
splitBundleIfSizeExceedsLimit params bundle
    | outputSizeWithinLimit params bundleWithMaxAda =
        pure bundle
    | otherwise =
        splitInHalf bundle >>= splitBundleIfSizeExceedsLimit params
    | otherwise =
        pure bundle
  where
    splitInHalf = flip TokenBundle.equipartitionAssets (() :| [()])
    bundleWithMaxAda = TokenBundle.setCoin bundle maxBound

--------------------------------------------------------------------------------
-- Miscellaneous types and functions
--------------------------------------------------------------------------------

newtype NegativeCoin = NegativeCoin
    { unNegativeCoin :: Coin
    }
    deriving (Eq, Show)

class (Ord a, Monoid a) => Size a where
    sizeDistance :: a -> a -> a

findFixedPoint :: Eq a => (a -> a) -> a -> a
findFixedPoint f = findInner
  where
    findInner a = let fa = f a in if a == fa then a else findInner fa

guardE :: Bool -> e -> Either e ()
guardE condition e = if condition then Right () else Left e

guardSize :: Ord s => SelectionParameters s -> s -> Either (SelectionError s) s
guardSize params selectionSizeRequired
    | selectionSizeRequired <= selectionSizeMaximum =
        pure selectionSizeRequired
    | otherwise =
        Left $ SelectionFull SelectionFullError
            { selectionSizeMaximum
            , selectionSizeRequired
            }
  where
    selectionSizeMaximum = maximumSizeOfSelection params

replaceHeadOfList :: NonEmpty a -> a -> NonEmpty a
replaceHeadOfList (_ :| as) a = a :| as

coinFromInteger :: Integer -> Maybe Coin
coinFromInteger i
    | i < fromIntegral (unCoin $ minBound @Coin) = Nothing
    | i > fromIntegral (unCoin $ maxBound @Coin) = Nothing
    | otherwise = Just $ Coin $ fromIntegral i

coinToInteger :: Coin -> Integer
coinToInteger = fromIntegral . unCoin

insertManyBy :: (a -> a -> Ordering) -> [a] -> [a] -> [a]
insertManyBy = L.foldl' . flip . L.insertBy

eithersToEither :: NonEmpty (Either e a) -> Either e a
eithersToEither eithers
    | Just success <- maybesToMaybe (eitherToMaybe <$> eithers) =
        pure success
    | otherwise =
        NE.head eithers

maybesToMaybe :: NonEmpty (Maybe a) -> Maybe a
maybesToMaybe = listToMaybe . catMaybes . NE.toList
