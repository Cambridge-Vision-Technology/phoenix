export type Field = { label: string; value: string };
export type Cell = {
  key: string;
  label: string;
  value: number | null;
  text: string;
  aggregation: string;
  status: string;
  details: readonly Field[];
  deltaText: string | null;
};
export type View = { eligible: boolean; phi: Cell; preservation: Cell };
export type Experiment = {
  id: string;
  metadata: unknown;
  runCount: number;
  expectedRunCount: number;
};
export type Column = {
  id: string;
  field: "phi" | "preservation";
  title: string;
};
export function project(input: {
  datasetId: string;
  metadata: unknown;
  runCount: number;
  expectedRunCount: number;
}): View;
export function projectExperiment(input: {
  datasetId: string;
  experiment: Experiment;
  baseline: Experiment | null;
  showDeltas: boolean;
}): View;
export function columns(views: readonly View[]): Column[];
export function visibility(input: {
  views: readonly View[];
  stored: Readonly<Record<string, boolean>>;
  annotationPrefix: string;
  annotationNames: readonly string[];
  configuredNames: readonly string[];
}): Record<string, boolean>;
export function columnLabels(input: {
  views: readonly View[];
  annotationPrefix: string;
  annotationNames: readonly string[];
}): Record<string, string | undefined>;
export type ChartExperiment = {
  id: string;
  name: string;
  sequenceNumber: number;
  isBaseline: boolean;
  pooledSource?: {
    metadata: unknown;
    runCount: number;
    expectedRunCount: number;
  } | null;
  annotationSummaries: readonly {
    annotationName: string;
    meanScore: number | null;
    labelFractions?: readonly { label: string; fraction: number }[] | null;
  }[];
};
export type ChartPoint = {
  x: number;
  metadata: {
    experimentName: string;
    experimentId: string;
    isBaseline: boolean;
  };
  summaries: {
    name: string;
    meanScore: number | null;
    labelFractions: { label: string; fraction: number }[];
  }[];
};
export function annotationChart(input: {
  datasetId: string;
  annotationName: string;
  experiments: readonly ChartExperiment[];
  baseline: ChartExperiment | null;
}): {
  points: ChartPoint[];
  referencePoint: ChartPoint | null;
  pooled: boolean;
  scoreLabel: string;
  domain: [number, number] | null;
  description: string | null;
  emptyMessage: string | null;
};
export function combinedChart(input: {
  datasetId: string;
  experiments: readonly ChartExperiment[];
  hiddenDataKeys: readonly string[];
}): {
  rows: { id: string; scores: Record<string, number | null | undefined> }[];
  keys: string[];
  domain: [number, number] | null;
  hasData: boolean;
};
