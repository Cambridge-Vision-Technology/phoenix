module Phoenix.LegendSummaryTest (main) where

import Prelude

import Data.Argonaut.Core as Data.Argonaut.Core
import Data.Argonaut.Encode as Data.Argonaut.Encode
import Data.Array as Data.Array
import Data.Maybe as Data.Maybe
import Data.Nullable as Data.Nullable
import Data.String as Data.String
import Data.Tuple as Data.Tuple
import Effect as Effect
import Foreign.Object as Foreign.Object
import Phoenix.LegendSummary as Phoenix.LegendSummary
import Phoenix.LegendSummary.Chart as Phoenix.LegendSummary.Chart
import Phoenix.LegendSummary.Json as Phoenix.LegendSummary.Json
import Test.Assert as Test.Assert

metric :: String -> String -> Int -> Int -> Int -> Int -> Data.Maybe.Maybe Number -> Phoenix.LegendSummary.Json.Metric
metric key name numerator failed unknown denominator score = { key, name, numerator, failed, unknown, denominator, score, missingEvaluations: 0 }

fixture :: Array Phoenix.LegendSummary.Json.Metric -> Boolean -> Data.Argonaut.Core.Json
fixture metrics complete = Data.Argonaut.Encode.encodeJson
  { legendBenchmarkSummary:
      { schemaVersion: "legend-benchmark-summary-v2"
      , policy: "legend-policy-v2"
      , complete
      , expectedCases: 2
      , completedCases: 2
      , headlines: [ "PHI handled % v2", "Non-PHI spans preserved % v2" ]
      , metrics
      , scores: Foreign.Object.fromFoldable (map (\item -> Data.Tuple.Tuple item.name item.score) metrics)
      }
  }

provenance :: String -> String -> Data.Argonaut.Core.Json -> Data.Argonaut.Core.Json
provenance hash revision metadata = Data.Argonaut.Core.fromObject (Foreign.Object.union additions (Data.Maybe.fromMaybe Foreign.Object.empty (Data.Argonaut.Core.toObject metadata)))
  where
  digest value = Data.String.joinWith "" (Data.Array.replicate 64 value)
  additions = Foreign.Object.fromFoldable
    [ Data.Tuple.Tuple "applicationRevision" (Data.Argonaut.Core.fromString revision)
    , Data.Tuple.Tuple "selectedExamples" (Data.Argonaut.Encode.encodeJson [ "small-case", "large-case" ])
    , Data.Tuple.Tuple "repetitions" (Data.Argonaut.Core.fromNumber 1.0)
    , Data.Tuple.Tuple "release"
        ( Data.Argonaut.Encode.encodeJson
            { schemaVersion: "deid-benchmark-release-set-v2"
            , contractFingerprint: digest "a"
            , taskVersion: "task-v1"
            , resultVersion: "result-v1"
            , datasets: [ { id: "dataset", name: "legend", versionId: "version-a", contentSha256: digest hash } ]
            , evaluators: map (\key -> { key, sourceSha256: digest "b", inputMapping: Data.Argonaut.Encode.encodeJson {} }) [ "phi-handled-v2", "invariant-spans-preserved-v2" ]
            }
        )
    ]

main :: Effect.Effect Unit
main = do
  let
    execution = metric "execution-status-v1" "Execution status v1" 2 0 0 2 (Data.Maybe.Just 1.0)
    phi = metric "phi-handled-v2" "PHI handled % v2" 1 99 0 100 (Data.Maybe.Just 1.0)
    preservation = metric "invariant-spans-preserved-v2" "Non-PHI spans preserved % v2" 90 10 0 100 (Data.Maybe.Just 90.0)
    rows = [ execution, phi, preservation ]
    project metadata = Phoenix.LegendSummary.project { datasetId: "dataset", metadata, runCount: 2, expectedRunCount: 2 }
    valid = project (fixture rows true)
    unknown = project (fixture [ execution, phi { failed = 98, unknown = 1, score = Data.Maybe.Nothing }, preservation ] true)
    incomplete = project (fixture rows false)
    invalidCounts = project (fixture [ execution, phi { numerator = 2 }, preservation ] true)
    wrongUnits = project (fixture [ execution, phi { score = Data.Maybe.Just 0.01 }, preservation ] true)
    duplicate = project (fixture (Data.Array.snoc rows phi) true)
    noJudgments = project (fixture [ execution, phi { numerator = 0, failed = 0, denominator = 0, score = Data.Maybe.Nothing }, preservation ] true)
    failedExecution = project (fixture [ execution { numerator = 1, failed = 1, score = Data.Maybe.Just 0.5 }, phi, preservation ] true)
    generic = project (Data.Argonaut.Encode.encodeJson {})
    baselineRows = [ execution, phi { numerator = 2, failed = 98, score = Data.Maybe.Just 2.0 }, preservation { numerator = 80, failed = 20, score = Data.Maybe.Just 80.0 } ]
    experiment = { id: "candidate", metadata: provenance "a" "candidate-app" (fixture rows true), runCount: 2, expectedRunCount: 2 }
    baseline metadata = Data.Nullable.notNull { id: "baseline", metadata, runCount: 2, expectedRunCount: 2 }
    compared reference = Phoenix.LegendSummary.projectExperiment { datasetId: "dataset", experiment, baseline: reference, showDeltas: true }
    compatible = compared (baseline (provenance "a" "different-app" (fixture baselineRows true)))
    incompatible = compared (baseline (provenance "c" "different-app" (fixture baselineRows true)))
    missingProof = compared (baseline (fixture baselineRows true))
    stored = Foreign.Object.fromFoldable [ Data.Tuple.Tuple "legend-pooled-phi-handled-v2" false, Data.Tuple.Tuple "annotation-PHI handled % v2" true, Data.Tuple.Tuple "metadata" false ]
    visible = Phoenix.LegendSummary.visibility { views: [ valid ], stored, annotationPrefix: "annotation-", annotationNames: [ "PHI handled % v2", "Non-PHI spans preserved % v2" ], configuredNames: [ "PHI handled % v2", "Non-PHI spans preserved % v2" ] }
    legacyVisible = Phoenix.LegendSummary.visibility { views: [ generic ], stored: Foreign.Object.empty, annotationPrefix: "annotation-", annotationNames: [ "legacy score" ], configuredNames: [] }
    chartExperiment item = { id: item.id, name: item.id, sequenceNumber: 2, isBaseline: false, pooledSource: Data.Nullable.notNull { metadata: item.metadata, runCount: item.runCount, expectedRunCount: item.expectedRunCount }, annotationSummaries: [ { annotationName: "PHI handled % v2", meanScore: Data.Nullable.notNull 50.0, labelFractions: Data.Nullable.notNull [ { label: "pass", fraction: 0.5 }, { label: "fail", fraction: 0.5 } ] } ] }
    chartRow = chartExperiment experiment
    chart reference = Phoenix.LegendSummary.Chart.annotationChart { datasetId: "dataset", annotationName: "PHI handled % v2", experiments: [ chartRow ], baseline: reference }
    pooledChart = chart Data.Nullable.null
    compatibleChart = chart (Data.Nullable.notNull (chartExperiment { id: "baseline", metadata: provenance "a" "different-app" (fixture baselineRows true), runCount: 2, expectedRunCount: 2 }))
    incompatibleChart = chart (Data.Nullable.notNull (chartExperiment { id: "baseline", metadata: provenance "c" "different-app" (fixture baselineRows true), runCount: 2, expectedRunCount: 2 }))
    legacyChartRow = chartRow { pooledSource = Data.Nullable.null }
    legacyChart = Phoenix.LegendSummary.Chart.annotationChart { datasetId: "dataset", annotationName: "PHI handled % v2", experiments: [ legacyChartRow ], baseline: Data.Nullable.null }
    chartScore value = Data.Array.head value.points >>= _.summaries >>> Data.Array.head >>= Data.Nullable.toMaybe <<< _.meanScore
    combined = Phoenix.LegendSummary.Chart.combinedChart { datasetId: "dataset", experiments: [ chartRow ], hiddenDataKeys: [] }
    genericCombined = Phoenix.LegendSummary.Chart.combinedChart { datasetId: "dataset", experiments: [ legacyChartRow { annotationSummaries = [ { annotationName: "score", meanScore: Data.Nullable.notNull 0.5, labelFractions: Data.Nullable.null } ] } ], hiddenDataKeys: [] }
    mixedUnits = Phoenix.LegendSummary.Chart.combinedChart { datasetId: "dataset", experiments: [ chartRow { annotationSummaries = Data.Array.snoc chartRow.annotationSummaries { annotationName: "token count", meanScore: Data.Nullable.notNull 250.0, labelFractions: Data.Nullable.null } } ], hiddenDataKeys: [] }
    unavailableChart = Phoenix.LegendSummary.Chart.annotationChart { datasetId: "dataset", annotationName: "PHI handled % v2", experiments: [ chartRow { pooledSource = Data.Nullable.notNull { metadata: fixture [ execution, phi { failed = 98, unknown = 1, score = Data.Maybe.Nothing }, preservation ] true, runCount: 2, expectedRunCount: 2 } } ], baseline: Data.Nullable.null }
  Test.Assert.assert' "Unequal case denominators yield 1% pooled, never their 50% case average" (valid.eligible && valid.phi.text == "1.00%" && Data.Nullable.toMaybe valid.phi.value == Data.Maybe.Just 1.0 && valid.preservation.text == "90.00%")
  Test.Assert.assert' "Unknown judgments cannot become 0%, 100%, or an average of known cases" (unknown.phi.text == "Unavailable" && Data.Nullable.toMaybe unknown.phi.value == Data.Maybe.Nothing && unknown.preservation.text == "90.00%")
  Test.Assert.assert' "Incomplete native evidence and failed executions make headlines unavailable" (incomplete.phi.text == "Unavailable" && failedExecution.phi.text == "Unavailable")
  Test.Assert.assert' "Contradictory counts, wrong score units and duplicate metric keys are rejected" (invalidCounts.phi.text == "Unavailable" && wrongUnits.phi.text == "Unavailable" && duplicate.phi.text == "Unavailable")
  Test.Assert.assert' "No required judgments is N/A rather than perfect quality" (noJudgments.phi.text == "N/A" && Data.Nullable.toMaybe noJudgments.phi.value == Data.Maybe.Nothing)
  Test.Assert.assert' "Generic data is not opted into Legend-specific presentation" (not generic.eligible)
  Test.Assert.assert' "Pooled percentage-point deltas allow different applications on the same pinned benchmark" (Data.Nullable.toMaybe compatible.phi.deltaText == Data.Maybe.Just "-1.00 pp" && Data.Nullable.toMaybe compatible.preservation.deltaText == Data.Maybe.Just "+10.00 pp")
  Test.Assert.assert' "Incompatible or missing benchmark provenance never produces a misleading baseline delta" (Data.Nullable.toMaybe incompatible.phi.deltaText == Data.Maybe.Nothing && Data.Nullable.toMaybe missingProof.phi.deltaText == Data.Maybe.Nothing)
  Test.Assert.assert' "Two pooled defaults never overwrite explicit native or headline visibility preferences" (Data.Array.length (Phoenix.LegendSummary.columns [ valid ]) == 2 && Foreign.Object.lookup "legend-pooled-phi-handled-v2" visible == Data.Maybe.Just false && Foreign.Object.lookup "legend-pooled-invariant-spans-preserved-v2" visible == Data.Maybe.Just true && Foreign.Object.lookup "annotation-PHI handled % v2" visible == Data.Maybe.Just true && Foreign.Object.lookup "annotation-Non-PHI spans preserved % v2" visible == Data.Maybe.Just false && Foreign.Object.lookup "metadata" stored == Data.Maybe.Just false)
  Test.Assert.assert' "Historical and generic defaults retain native annotation columns" (Data.Array.null (Phoenix.LegendSummary.columns [ generic ]) && Foreign.Object.lookup "annotation-legacy score" legacyVisible == Data.Maybe.Just true)
  Test.Assert.assert' "Individual charts use pooled 1%, a percent axis and no per-case distribution disguised as pooled" (pooledChart.pooled && chartScore pooledChart == Data.Maybe.Just 1.0 && Data.Nullable.toMaybe pooledChart.domain == Data.Maybe.Just [ 0.0, 100.0 ] && pooledChart.scoreLabel == "pooled native percentage")
  Test.Assert.assert' "Chart reference lines require the same provenance as pooled table deltas" (Data.Maybe.isJust (Data.Nullable.toMaybe compatibleChart.referencePoint) && Data.Maybe.isNothing (Data.Nullable.toMaybe incompatibleChart.referencePoint))
  Test.Assert.assert' "Legacy charts retain their original case means and label distributions" (not legacyChart.pooled && chartScore legacyChart == Data.Maybe.Just 50.0 && legacyChart.scoreLabel == "mean score")
  Test.Assert.assert' "Combined chart labels distinguish pooled percentages from case means without rescaling generic scores" (Data.Array.elem "PHI handled % v2 (pooled)" combined.keys && Data.Nullable.toMaybe combined.domain == Data.Maybe.Just [ 0.0, 100.0 ] && genericCombined.keys == [ "score" ] && Data.Nullable.toMaybe genericCombined.domain == Data.Maybe.Just [ 0.0, 1.0 ])
  Test.Assert.assert' "A combined pooled chart never clips native metrics outside percentage units" (Data.Maybe.isNothing (Data.Nullable.toMaybe mixedUnits.domain))
  Test.Assert.assert' "An entirely unavailable pooled series activates the honest empty-state message, not a 100% other-label bar" (unavailableChart.pooled && Data.Array.null unavailableChart.points && Data.Nullable.toMaybe unavailableChart.emptyMessage == Data.Maybe.Just "Unavailable — Unknown judgments remain unassessable")
