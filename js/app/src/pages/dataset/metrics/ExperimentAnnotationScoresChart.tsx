import type { TooltipContentProps } from "recharts";
import {
  Bar,
  CartesianGrid,
  ComposedChart,
  Line,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";

import {
  ChartEmptyStateOverlay,
  ChartResponsiveContainer,
  ChartTooltip,
  ChartTooltipItem,
  COMPACT_CHART_ANIMATION_DURATION_MS,
  compactChartMargin,
  compactLegendProps,
  defaultCartesianGridProps,
  defaultTooltipProps,
  InteractiveLegend,
  useInteractiveLegend,
} from "@phoenix/components/chart";
import { useTheme } from "@phoenix/contexts";
import { getWordColor } from "@phoenix/utils/colorUtils";
import { formatFloat } from "@phoenix/utils/numberFormatUtils";

import { combinedChart } from "../../../legend/summary.generated.js";
import type { ExperimentMetricsTooltipDatum } from "./ExperimentMetricsTooltipContent";
import { ExperimentMetricsTooltipHeader } from "./ExperimentMetricsTooltipHeader";
import { useExperimentChartDatum } from "./experimentSelection";
import {
  experimentMetricsYAxisProps,
  getExperimentXAxisProps,
} from "./experimentXAxisProps";
import type { ExperimentMetricViewProps } from "./types";
import { EXPERIMENT_METRICS_CHART_SYNC_ID } from "./types";
import { useExperimentMetricsData } from "./useExperimentMetricsData";

function TooltipContent({
  active,
  payload,
  label,
  shape,
}: TooltipContentProps & { shape: "line" | "square" }) {
  const { theme } = useTheme();
  if (!active || !payload || payload.length === 0) {
    return null;
  }
  const datum = payload[0]?.payload as ExperimentMetricsTooltipDatum;
  const annotationEntries = payload.filter(
    (entry) => typeof entry.value === "number"
  );
  return (
    <ChartTooltip>
      <ExperimentMetricsTooltipHeader
        sequenceNumber={Number(label)}
        name={datum?.experimentName}
        isBaseline={datum?.isBaseline}
        color={datum?.experimentColor}
        referenceLabel={datum?.referenceLabel}
      />
      {annotationEntries.map((entry) => (
        <ChartTooltipItem
          key={String(entry.dataKey)}
          color={getWordColor({ word: String(entry.dataKey), theme })}
          shape={shape}
          name={String(entry.dataKey)}
          value={
            typeof entry.value === "number" ? formatFloat(entry.value) : "--"
          }
        />
      ))}
    </ChartTooltip>
  );
}

/**
 * Versioned pooled headlines and detailed native case means per experiment.
 */
export function ExperimentAnnotationScoresChart({
  datasetId,
  experimentSelection,
}: ExperimentMetricViewProps) {
  const { theme } = useTheme();
  const { experiments, baselineExperiment } = useExperimentMetricsData({
    datasetId,
    experimentSelection,
  });
  const { toExperimentChartDatum } =
    useExperimentChartDatum(experimentSelection);
  const isComparedSelection = experimentSelection.type === "compared";

  const { hiddenDataKeys, isDataKeyHidden, toggleDataKey } =
    useInteractiveLegend();
  const projection = combinedChart({
    datasetId,
    experiments,
    hiddenDataKeys: Array.from(hiddenDataKeys, String),
  });
  const chartData = experiments.map((experiment, index) => ({
    ...projection.rows[index].scores,
    ...toExperimentChartDatum(experiment),
  }));
  const scoreKeys = projection.keys;
  const yDomain = projection.domain ?? undefined;
  const hasData = projection.hasData;

  return (
    <ChartEmptyStateOverlay
      isEmpty={!hasData}
      message="No annotation data"
      chartType={isComparedSelection ? "bar" : "line"}
    >
      <ChartResponsiveContainer>
        <ComposedChart
          data={chartData}
          barSize={isComparedSelection ? 6 : undefined}
          margin={compactChartMargin}
          syncId={EXPERIMENT_METRICS_CHART_SYNC_ID}
          syncMethod="value"
        >
          <CartesianGrid {...defaultCartesianGridProps} />
          <XAxis
            {...getExperimentXAxisProps({
              baselineSequenceNumber: baselineExperiment?.sequenceNumber,
              experiments: chartData,
            })}
          />
          <YAxis {...experimentMetricsYAxisProps} domain={yDomain} />
          {scoreKeys.map((key) => {
            const color = getWordColor({ word: key, theme });
            const markProps = {
              dataKey: key,
              hide: isDataKeyHidden(key),
              yAxisId: 0,
              animationDuration: COMPACT_CHART_ANIMATION_DURATION_MS,
            };
            // Compared experiments have no inherent order, so a line between
            // them would imply a trend
            return isComparedSelection ? (
              <Bar
                key={key}
                {...markProps}
                fill={color}
                radius={[2, 2, 0, 0]}
              />
            ) : (
              <Line
                key={key}
                {...markProps}
                type="monotone"
                stroke={color}
                strokeWidth={2}
                dot={{ r: 3 }}
                activeDot={{ r: 5 }}
              />
            );
          })}
          <InteractiveLegend
            {...compactLegendProps}
            hiddenDataKeys={hiddenDataKeys}
            iconSize={8}
            onToggleDataKey={toggleDataKey}
          />
          <Tooltip
            {...defaultTooltipProps}
            content={(props) => (
              <TooltipContent
                {...props}
                shape={isComparedSelection ? "square" : "line"}
              />
            )}
          />
        </ComposedChart>
      </ChartResponsiveContainer>
    </ChartEmptyStateOverlay>
  );
}
