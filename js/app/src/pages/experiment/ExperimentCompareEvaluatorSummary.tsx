import type { ReactNode } from "react";
import { create } from "zustand";
import { persist } from "zustand/middleware";

import { DisclosureArrow, Flex, IconButton, Text } from "@phoenix/components";

type ExperimentCompareEvaluatorSummaryState = {
  isExpanded: boolean;
  setIsExpanded: (isExpanded: boolean) => void;
};

/**
 * Whether the compare grid's headers show their evaluator summaries.
 *
 * One value for every column, because the grid's columns have to stay aligned. Remembered
 * across visits, since someone with many evaluators wants it the same way each time.
 */
export const useExperimentCompareEvaluatorSummaryStore =
  create<ExperimentCompareEvaluatorSummaryState>()(
    persist(
      (set) => ({
        isExpanded: true,
        setIsExpanded: (isExpanded) => set({ isExpanded }),
      }),
      { name: "arize-phoenix-experiment-compare-evaluator-summary" }
    )
  );

/**
 * The evaluator summary in a compare grid column header, which can be collapsed.
 *
 * With many evaluators the summary fills the sticky header, leaving little room for the rows
 * beneath it. Collapsing rather than dragging to resize, because a resizable area inside a
 * sticky table header competes with column sizing and scrolling, and a part-hidden list of
 * scores is less useful than a clear choice between the whole list and the rows.
 */
export function ExperimentCompareEvaluatorSummary({
  evaluatorCount,
  children,
}: {
  evaluatorCount: number;
  children: ReactNode;
}) {
  const isExpanded = useExperimentCompareEvaluatorSummaryStore(
    (state) => state.isExpanded
  );
  const setIsExpanded = useExperimentCompareEvaluatorSummaryStore(
    (state) => state.setIsExpanded
  );
  if (evaluatorCount === 0) {
    return <>{children}</>;
  }
  return (
    <>
      <Flex direction="row" gap="size-50" alignItems="center">
        <IconButton
          size="S"
          aria-label={
            isExpanded ? "Hide evaluator summary" : "Show evaluator summary"
          }
          aria-expanded={isExpanded}
          onPress={() => setIsExpanded(!isExpanded)}
        >
          <DisclosureArrow isExpanded={isExpanded} />
        </IconButton>
        <Text size="XS" color="text-500">
          {`Evaluators (${evaluatorCount})`}
        </Text>
      </Flex>
      {isExpanded ? children : null}
    </>
  );
}
