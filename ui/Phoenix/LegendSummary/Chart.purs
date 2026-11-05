module Phoenix.LegendSummary.Chart (Source, LabelFraction, Annotation, ChartExperiment, Point, AnnotationChart, CombinedChart, annotationChart, combinedChart) where

import Prelude

import Data.Argonaut.Core as Data.Argonaut.Core
import Data.Array as Data.Array
import Data.Maybe as Data.Maybe
import Data.Nullable as Data.Nullable
import Foreign.Object as Foreign.Object
import Phoenix.LegendSummary as Phoenix.LegendSummary

type Source = { metadata :: Data.Argonaut.Core.Json, runCount :: Int, expectedRunCount :: Int }
type LabelFraction = { label :: String, fraction :: Number }
type Annotation = { annotationName :: String, meanScore :: Data.Nullable.Nullable Number, labelFractions :: Data.Nullable.Nullable (Array LabelFraction) }
type ChartExperiment = { id :: String, name :: String, sequenceNumber :: Int, isBaseline :: Boolean, pooledSource :: Data.Nullable.Nullable Source, annotationSummaries :: Array Annotation }
type Point = { x :: Int, metadata :: { experimentName :: String, experimentId :: String, isBaseline :: Boolean }, summaries :: Array { name :: String, meanScore :: Data.Nullable.Nullable Number, labelFractions :: Array LabelFraction } }
type AnnotationChart = { points :: Array Point, referencePoint :: Data.Nullable.Nullable Point, pooled :: Boolean, scoreLabel :: String, domain :: Data.Nullable.Nullable (Array Number), description :: Data.Nullable.Nullable String, emptyMessage :: Data.Nullable.Nullable String }
type CombinedChart = { rows :: Array { id :: String, scores :: Foreign.Object.Object (Data.Nullable.Nullable Number) }, keys :: Array String, domain :: Data.Nullable.Nullable (Array Number), hasData :: Boolean }

source :: ChartExperiment -> Source
source experiment = Data.Maybe.fromMaybe { metadata: Data.Argonaut.Core.jsonNull, runCount: -1, expectedRunCount: -1 } (Data.Nullable.toMaybe experiment.pooledSource)

model :: String -> ChartExperiment -> Phoenix.LegendSummary.View
model datasetId experiment =
  let
    raw = source experiment
  in
    Phoenix.LegendSummary.project { datasetId, metadata: raw.metadata, runCount: raw.runCount, expectedRunCount: raw.expectedRunCount }

cell :: String -> Phoenix.LegendSummary.View -> Data.Maybe.Maybe Phoenix.LegendSummary.Cell
cell "PHI handled % v2" view = Data.Maybe.Just view.phi
cell "Non-PHI spans preserved % v2" view = Data.Maybe.Just view.preservation
cell _ _ = Data.Maybe.Nothing

native :: ChartExperiment -> String -> Data.Nullable.Nullable Number
native experiment name = Data.Maybe.maybe Data.Nullable.null _.meanScore (Data.Array.find (\summary -> summary.annotationName == name) experiment.annotationSummaries)

annotationChart :: { datasetId :: String, annotationName :: String, experiments :: Array ChartExperiment, baseline :: Data.Nullable.Nullable ChartExperiment } -> AnnotationChart
annotationChart input =
  { points: if pooled && not (Data.Array.any valid input.experiments) then [] else map point input.experiments
  , referencePoint: Data.Nullable.toNullable reference
  , pooled
  , scoreLabel: if pooled then "pooled native percentage" else "mean score"
  , domain: if pooled then Data.Nullable.notNull [ 0.0, 100.0 ] else Data.Nullable.null
  , description: if pooled then Data.Nullable.notNull "Pooled native counts. Historical case means remain in the table's detailed columns; baselines require matching benchmark provenance." else Data.Nullable.null
  , emptyMessage: if pooled then Data.Nullable.notNull (Data.Maybe.maybe "Pooled scores unavailable" (\value -> "Unavailable — " <> value.status) (Data.Array.head selectedCells)) else Data.Nullable.null
  }
  where
  views = map (model input.datasetId) input.experiments
  baselineView = model input.datasetId <$> Data.Nullable.toMaybe input.baseline
  pooled = Data.Array.elem input.annotationName [ "PHI handled % v2", "Non-PHI spans preserved % v2" ] && (Data.Array.any _.eligible views || Data.Maybe.maybe false _.eligible baselineView)
  selectedCells = Data.Array.mapMaybe (cell input.annotationName) views
  reference = do
    baseline <- Data.Nullable.toMaybe input.baseline
    if comparable baseline then Data.Maybe.Just (point baseline) else Data.Maybe.Nothing
  valid experiment = Data.Maybe.isJust (cell input.annotationName (model input.datasetId experiment) >>= Data.Nullable.toMaybe <<< _.value)
  toExperiment experiment = { id: experiment.id, metadata: (source experiment).metadata, runCount: (source experiment).runCount, expectedRunCount: (source experiment).expectedRunCount }
  comparable baseline =
    if not pooled then true
    else valid baseline && Data.Array.any valid input.experiments && Data.Array.all
      ( \experiment ->
          if not (valid experiment) || experiment.id == baseline.id then true
          else
            let
              compared = Phoenix.LegendSummary.projectExperiment { datasetId: input.datasetId, experiment: toExperiment experiment, baseline: Data.Nullable.notNull (toExperiment baseline), showDeltas: true }
            in
              Data.Maybe.isJust (cell input.annotationName compared >>= Data.Nullable.toMaybe <<< _.deltaText)
      )
      input.experiments
  point experiment =
    { x: experiment.sequenceNumber
    , metadata: { experimentName: experiment.name, experimentId: experiment.id, isBaseline: experiment.isBaseline }
    , summaries:
        if pooled then [ { name: input.annotationName, meanScore: Data.Maybe.maybe Data.Nullable.null _.value (cell input.annotationName (model input.datasetId experiment)), labelFractions: [] } ]
        else map (\summary -> { name: summary.annotationName, meanScore: summary.meanScore, labelFractions: Data.Maybe.fromMaybe [] (Data.Nullable.toMaybe summary.labelFractions) }) experiment.annotationSummaries
    }

combinedChart :: { datasetId :: String, experiments :: Array ChartExperiment, hiddenDataKeys :: Array String } -> CombinedChart
combinedChart input = { rows, keys, domain, hasData: not (Data.Array.null allValues) }
  where
  views = map (model input.datasetId) input.experiments
  pooled = Data.Array.any _.eligible views
  names = Data.Array.nub ((if pooled then [ "PHI handled % v2", "Non-PHI spans preserved % v2" ] else []) <> Data.Array.concatMap (map _.annotationName <<< _.annotationSummaries) input.experiments)
  label name = if not pooled then name else name <> if Data.Maybe.isJust (Data.Array.head views >>= cell name) then " (pooled)" else " (case mean)"
  keys = map label names
  value experiment name = if pooled then Data.Maybe.maybe (native experiment name) _.value (cell name (model input.datasetId experiment)) else native experiment name
  rows = map (\experiment -> { id: experiment.id, scores: Data.Array.foldl (\scores name -> Foreign.Object.insert (label name) (value experiment name) scores) Foreign.Object.empty names }) input.experiments
  values namesToRead = Data.Array.concatMap (\row -> Data.Array.mapMaybe (\key -> Foreign.Object.lookup key row.scores >>= Data.Nullable.toMaybe) namesToRead) rows
  allValues = values keys
  visibleKeys = Data.Array.filter (\key -> not (Data.Array.elem key input.hiddenDataKeys)) keys
  visibleValues = values visibleKeys
  hasPooledPercentage = pooled && Data.Array.any (\name -> Data.Array.elem (label name) visibleKeys && not (Data.Array.null (values [ label name ]))) [ "PHI handled % v2", "Non-PHI spans preserved % v2" ]
  domain =
    if hasPooledPercentage && Data.Array.all (\number -> number >= 0.0 && number <= 100.0) visibleValues then Data.Nullable.notNull [ 0.0, 100.0 ]
    else if not (Data.Array.null visibleValues) && Data.Array.all (\number -> number >= 0.0 && number <= 1.0) visibleValues then Data.Nullable.notNull [ 0.0, 1.0 ]
    else Data.Nullable.null
