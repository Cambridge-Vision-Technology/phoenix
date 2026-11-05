module Phoenix.LegendSummary (Input, Experiment, Field, Cell, View, Column, project, projectExperiment, columns, visibility, columnLabels) where

import Prelude

import Data.Argonaut.Core as Data.Argonaut.Core
import Data.Array as Data.Array
import Data.Either as Data.Either
import Data.Int as Data.Int
import Data.Maybe as Data.Maybe
import Data.Nullable as Data.Nullable
import Data.Number as Data.Number
import Data.Number.Format as Data.Number.Format
import Data.Traversable as Data.Traversable
import Foreign.Object as Foreign.Object
import Phoenix.LegendSummary.Json as Phoenix.LegendSummary.Json

type Input = { datasetId :: String, metadata :: Data.Argonaut.Core.Json, runCount :: Int, expectedRunCount :: Int }
type Experiment = { id :: String, metadata :: Data.Argonaut.Core.Json, runCount :: Int, expectedRunCount :: Int }
type Field = { label :: String, value :: String }
type Cell = { key :: String, label :: String, value :: Data.Nullable.Nullable Number, text :: String, aggregation :: String, status :: String, details :: Array Field, deltaText :: Data.Nullable.Nullable String }
type View = { eligible :: Boolean, phi :: Cell, preservation :: Cell }
type Column = { id :: String, field :: String, title :: String }
type Supported = { summary :: Phoenix.LegendSummary.Json.Summary, execution :: Phoenix.LegendSummary.Json.Metric, phi :: Phoenix.LegendSummary.Json.Metric, preservation :: Phoenix.LegendSummary.Json.Metric }

phiName :: String
phiName = "PHI handled % v2"

preservationName :: String
preservationName = "Non-PHI spans preserved % v2"

projectExperiment :: { datasetId :: String, experiment :: Experiment, baseline :: Data.Nullable.Nullable Experiment, showDeltas :: Boolean } -> View
projectExperiment input = case Data.Nullable.toMaybe input.baseline of
  Data.Maybe.Nothing ->
    current
  Data.Maybe.Just baseline | not input.showDeltas || baseline.id == input.experiment.id ->
    current
  Data.Maybe.Just baseline ->
    let
      previous = inspect baseline
      compare cell reference = case difference baseline cell reference of
        Data.Either.Left reason -> cell { details = Data.Array.snoc cell.details { label: "Baseline comparison", value: reason } }
        Data.Either.Right delta -> cell { deltaText = Data.Nullable.notNull (deltaLabel delta), details = Data.Array.snoc cell.details { label: "Baseline comparison", value: "Same pinned benchmark, metric and case selection; percentage-point difference" } }
    in
      current { phi = compare current.phi previous.phi, preservation = compare current.preservation previous.preservation }
  where
  inspect experiment = project { datasetId: input.datasetId, metadata: experiment.metadata, runCount: experiment.runCount, expectedRunCount: experiment.expectedRunCount }
  current = inspect input.experiment
  difference baseline cell reference = do
    value <- Data.Either.note "Current pooled score is unavailable" (Data.Nullable.toMaybe cell.value)
    previous <- Data.Either.note "Baseline pooled score is unavailable" (Data.Nullable.toMaybe reference.value)
    here <- Phoenix.LegendSummary.Json.basis input.datasetId cell.key input.experiment.metadata
    there <- Phoenix.LegendSummary.Json.basis input.datasetId cell.key baseline.metadata
    unless (here == there) (Data.Either.Left "Different benchmark definition, metric or case selection")
    pure (value - previous)
  deltaLabel delta =
    if delta /= 0.0 && Data.Number.abs delta < 0.005 then "≈0.00 pp"
    else (if delta > 0.0 then "+" else "") <> Data.Number.Format.toStringWith (Data.Number.Format.fixed 2) delta <> " pp"

columns :: Array View -> Array Column
columns views =
  if Data.Array.any _.eligible views then
    [ { id: "legend-pooled-phi-handled-v2", field: "phi", title: phiName <> " (pooled)" }
    , { id: "legend-pooled-invariant-spans-preserved-v2", field: "preservation", title: preservationName <> " (pooled)" }
    ]
  else []

visibility :: { views :: Array View, stored :: Foreign.Object.Object Boolean, annotationPrefix :: String, annotationNames :: Array String, configuredNames :: Array String } -> Foreign.Object.Object Boolean
visibility input = Data.Array.foldl add input.stored defaults
  where
  pooled = columns input.views
  defaults = map (\column -> { id: column.id, visible: true }) pooled <> map (\name -> { id: input.annotationPrefix <> name, visible: Data.Array.null pooled && (Data.Array.null input.configuredNames || Data.Array.elem name input.configuredNames) }) input.annotationNames
  add stored setting = if Foreign.Object.member setting.id stored then stored else Foreign.Object.insert setting.id setting.visible stored

columnLabels :: { views :: Array View, annotationPrefix :: String, annotationNames :: Array String } -> Foreign.Object.Object String
columnLabels input =
  if Data.Array.null (columns input.views) then Foreign.Object.empty
  else Data.Array.foldl (\labels name -> Foreign.Object.insert (input.annotationPrefix <> name) (name <> " (case mean)") labels) Foreign.Object.empty input.annotationNames

project :: Input -> View
project input = case Phoenix.LegendSummary.Json.decode input.metadata >>= validate of
  Data.Either.Left reason ->
    view (unavailable "phi-handled-v2" phiName reason []) (unavailable "invariant-spans-preserved-v2" preservationName reason [])
  Data.Either.Right supported ->
    let
      summary = supported.summary
      blocked =
        if not summary.complete || summary.completedCases /= summary.expectedCases then Data.Maybe.Just "Incomplete native evaluation"
        else if summary.completedCases /= input.runCount || summary.expectedCases /= input.expectedRunCount then Data.Maybe.Just "Case counts do not match the experiment"
        else if supported.execution.failed /= 0 || supported.execution.unknown /= 0 || supported.execution.missingEvaluations /= 0 then Data.Maybe.Just "Case executions failed or are unassessable"
        else Data.Maybe.Nothing
      cell metric = Data.Maybe.maybe (present metric) (\reason -> unavailable metric.key metric.name reason (counts metric)) blocked
    in
      view (cell supported.phi) (cell supported.preservation)
  where
  view phi preservation = { eligible: Phoenix.LegendSummary.Json.isOutcome input.datasetId input.metadata, phi, preservation }

validate :: Phoenix.LegendSummary.Json.Summary -> Data.Either.Either String Supported
validate summary = do
  unless (summary.schemaVersion == "legend-benchmark-summary-v2" && summary.policy == "legend-policy-v2") (Data.Either.Left "Unsupported pooled summary version or policy")
  unless (summary.expectedCases > 0 && summary.completedCases >= 0 && summary.completedCases <= summary.expectedCases) (Data.Either.Left "Invalid declared case counts")
  unless (Data.Array.sort summary.headlines == Data.Array.sort [ phiName, preservationName ]) (Data.Either.Left "Unsupported pooled headline definitions")
  unless (Data.Array.length (Data.Array.nub (map _.key summary.metrics)) == Data.Array.length summary.metrics && Data.Array.length (Data.Array.nub (map _.name summary.metrics)) == Data.Array.length summary.metrics) (Data.Either.Left "Duplicate pooled metric definitions")
  Data.Traversable.for_ summary.metrics \metric -> do
    unless (metric.numerator >= 0 && metric.failed >= 0 && metric.unknown >= 0 && metric.denominator >= 0 && metric.missingEvaluations >= 0) (Data.Either.Left "Invalid pooled judgment counts")
    unless (Data.Int.toNumber metric.numerator + Data.Int.toNumber metric.failed + Data.Int.toNumber metric.unknown == Data.Int.toNumber metric.denominator) (Data.Either.Left "Inconsistent pooled judgment counts")
  execution <- required "execution-status-v1" "Execution status v1" 1.0
  phi <- required "phi-handled-v2" phiName 100.0
  preservation <- required "invariant-spans-preserved-v2" preservationName 100.0
  unless (execution.denominator == summary.expectedCases) (Data.Either.Left "Execution judgments do not cover the declared cases")
  pure { summary, execution, phi, preservation }
  where
  required key name scale = do
    metric <- Data.Either.note "Required pooled metric not recorded" (Data.Array.find (\metric -> metric.key == key) summary.metrics)
    unless (metric.name == name) (Data.Either.Left "Pooled metric label does not match its versioned meaning")
    let expected = ratio scale metric
    unless (same expected metric.score && Data.Maybe.maybe false (same expected) (Foreign.Object.lookup name summary.scores)) (Data.Either.Left "Stored pooled score does not match its counts and units")
    pure metric

same :: Data.Maybe.Maybe Number -> Data.Maybe.Maybe Number -> Boolean
same (Data.Maybe.Just expected) (Data.Maybe.Just actual) = Data.Number.isFinite actual && Data.Number.abs (expected - actual) <= 0.000000001
same Data.Maybe.Nothing Data.Maybe.Nothing = true
same _ _ = false

ratio :: Number -> Phoenix.LegendSummary.Json.Metric -> Data.Maybe.Maybe Number
ratio scale metric =
  if metric.denominator <= 0 || metric.unknown /= 0 || metric.missingEvaluations /= 0 then Data.Maybe.Nothing
  else Data.Maybe.Just (scale * Data.Int.toNumber metric.numerator / Data.Int.toNumber metric.denominator)

counts :: Phoenix.LegendSummary.Json.Metric -> Array Field
counts metric =
  [ { label: "Passed", value: show metric.numerator }
  , { label: "Failed", value: show metric.failed }
  , { label: "Unknown", value: show metric.unknown }
  , { label: "Required judgments", value: show metric.denominator }
  , { label: "Missing evaluations", value: show metric.missingEvaluations }
  ]

unavailable :: String -> String -> String -> Array Field -> Cell
unavailable key label reason details = { key, label, value: Data.Nullable.null, text: "Unavailable", aggregation: "Pooled native counts", status: reason, details, deltaText: Data.Nullable.null }

present :: Phoenix.LegendSummary.Json.Metric -> Cell
present metric = case ratio 100.0 metric of
  Data.Maybe.Just value ->
    { key: metric.key, label: metric.name, value: Data.Nullable.notNull value, text: Data.Number.Format.toStringWith (Data.Number.Format.fixed 2) value <> "%", aggregation: "Pooled native counts", status: "All required judgments assessed", details: counts metric, deltaText: Data.Nullable.null }
  Data.Maybe.Nothing ->
    if metric.unknown /= 0 then unavailable metric.key metric.name "Unknown judgments remain unassessable" (counts metric)
    else if metric.missingEvaluations /= 0 then unavailable metric.key metric.name "Native evaluations are missing" (counts metric)
    else { key: metric.key, label: metric.name, value: Data.Nullable.null, text: "N/A", aggregation: "Pooled native counts", status: "No applicable judgments", details: counts metric, deltaText: Data.Nullable.null }
