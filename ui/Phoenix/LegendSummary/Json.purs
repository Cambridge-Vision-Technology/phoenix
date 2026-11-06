module Phoenix.LegendSummary.Json (Metric, Summary, Basis, field, decode, isOutcome, basis) where

import Prelude

import Data.Argonaut.Core as Data.Argonaut.Core
import Data.Argonaut.Decode as Data.Argonaut.Decode
import Data.Array as Data.Array
import Data.Either as Data.Either
import Data.Int as Data.Int
import Data.Maybe as Data.Maybe
import Data.String as Data.String
import Data.String.CodeUnits as Data.String.CodeUnits
import Foreign.Object as Foreign.Object

type Metric = { key :: String, name :: String, numerator :: Int, denominator :: Int, failed :: Int, unknown :: Int, missingEvaluations :: Int, score :: Data.Maybe.Maybe Number }
type Summary = { schemaVersion :: String, policy :: String, complete :: Boolean, expectedCases :: Int, completedCases :: Int, headlines :: Array String, metrics :: Array Metric, scores :: Foreign.Object.Object (Data.Maybe.Maybe Number) }

type Provenance = { release :: { schemaVersion :: String, contractFingerprint :: String, taskVersion :: String, resultVersion :: String, datasets :: Array { id :: String, name :: String, versionId :: String, contentSha256 :: String }, evaluators :: Array { key :: String, sourceSha256 :: String, inputMapping :: Data.Argonaut.Core.Json } }, selectedExamples :: Array String, repetitions :: Int }
newtype Basis = Basis { contract :: String, task :: String, result :: String, dataset :: String, version :: String, gold :: String, evaluator :: String, mapping :: Data.Argonaut.Core.Json, cases :: Array String, repetitions :: Int }

derive newtype instance Eq Basis

basis :: String -> String -> Data.Argonaut.Core.Json -> Data.Either.Either String Basis
basis datasetId metricKey metadata = do
  proof <- Data.Either.either (const (Data.Either.Left "Benchmark provenance is missing or invalid")) pure (Data.Argonaut.Decode.decodeJson metadata) :: Data.Either.Either String Provenance
  summary <- decode metadata
  unless (proof.release.schemaVersion == "deid-benchmark-release-set-v2" && digest proof.release.contractFingerprint && proof.release.taskVersion /= "" && proof.release.resultVersion /= "") (Data.Either.Left "Benchmark contract provenance is unsupported")
  dataset <- unique "Benchmark dataset provenance is ambiguous" (Data.Array.filter (\item -> item.id == datasetId) proof.release.datasets)
  evaluator <- unique "Metric provenance is ambiguous" (Data.Array.filter (\item -> item.key == metricKey) proof.release.evaluators)
  unless (dataset.versionId /= "" && digest dataset.contentSha256 && digest evaluator.sourceSha256) (Data.Either.Left "Benchmark version provenance is incomplete")
  unless (proof.repetitions > 0 && proof.repetitions <= 100 && not (Data.Array.null proof.selectedExamples) && Data.Array.length (Data.Array.nub proof.selectedExamples) == Data.Array.length proof.selectedExamples && Data.Array.all (Data.String.trim >>> (_ /= "")) proof.selectedExamples && Data.Int.toNumber (Data.Array.length proof.selectedExamples) * Data.Int.toNumber proof.repetitions == Data.Int.toNumber summary.expectedCases) (Data.Either.Left "Benchmark case selection is missing or invalid")
  pure (Basis { contract: proof.release.contractFingerprint, task: proof.release.taskVersion, result: proof.release.resultVersion, dataset: dataset.id, version: dataset.versionId, gold: dataset.contentSha256, evaluator: evaluator.sourceSha256, mapping: evaluator.inputMapping, cases: Data.Array.sort proof.selectedExamples, repetitions: proof.repetitions })
  where
  digest value = Data.String.CodeUnits.length value == 64 && Data.Array.all (\character -> character >= '0' && character <= '9' || character >= 'a' && character <= 'f') (Data.String.CodeUnits.toCharArray value)

  unique :: forall a. String -> Array a -> Data.Either.Either String a
  unique message values = case values of
    [ value ] -> pure value
    _ -> Data.Either.Left message

field :: String -> Data.Argonaut.Core.Json -> Data.Maybe.Maybe Data.Argonaut.Core.Json
field key json = Data.Argonaut.Core.toObject json >>= Foreign.Object.lookup key

decode :: Data.Argonaut.Core.Json -> Data.Either.Either String Summary
decode metadata = do
  summary <- Data.Either.note "Pooled summary not recorded" (field "legendBenchmarkSummary" metadata)
  Data.Either.either (const (Data.Either.Left "Invalid pooled summary")) pure (Data.Argonaut.Decode.decodeJson summary)

isOutcome :: String -> Data.Argonaut.Core.Json -> Boolean
isOutcome datasetId metadata = claimed || released
  where
  summary = field "legendBenchmarkSummary" metadata
  headlines = Data.Maybe.fromMaybe [] (summary >>= field "headlines" >>= Data.Argonaut.Core.toArray)
  metrics = Data.Maybe.fromMaybe [] (summary >>= field "metrics" >>= Data.Argonaut.Core.toArray)
  claimed = Data.Array.any (\item -> Data.Array.elem (Data.Argonaut.Core.toString item) [ Data.Maybe.Just "PHI handled % v2", Data.Maybe.Just "Non-PHI spans preserved % v2" ]) headlines
    || Data.Array.any (\item -> Data.Array.elem (field "key" item >>= Data.Argonaut.Core.toString) [ Data.Maybe.Just "phi-handled-v2", Data.Maybe.Just "invariant-spans-preserved-v2" ]) metrics
  release = field "release" metadata
  datasets = Data.Maybe.fromMaybe [] (release >>= field "datasets" >>= Data.Argonaut.Core.toArray)
  released = (release >>= field "schemaVersion" >>= Data.Argonaut.Core.toString) == Data.Maybe.Just "deid-benchmark-release-set-v2"
    && Data.Array.any (\item -> (field "id" item >>= Data.Argonaut.Core.toString) == Data.Maybe.Just datasetId && Data.Array.elem (field "name" item >>= Data.Argonaut.Core.toString) [ Data.Maybe.Just "legend", Data.Maybe.Just "legend-substitute" ]) datasets
