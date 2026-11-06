/**
 * @generated SignedSource<<7e6dd6243aa9a552b5f3c12d2035840d>>
 * @lightSyntaxTransform
 */

/* tslint:disable */
/* eslint-disable */
// @ts-nocheck

import { ReaderInlineDataFragment } from 'relay-runtime';
import { FragmentRefs } from "relay-runtime";
export type ExperimentAnnotationMetric_experiment$data = {
  readonly annotationSummaries: ReadonlyArray<{
    readonly annotationName: string;
    readonly labelFractions: ReadonlyArray<{
      readonly fraction: number;
      readonly label: string;
    }>;
    readonly meanScore: number | null;
  }>;
  readonly expectedRunCount: number;
  readonly id: string;
  readonly isBaseline: boolean;
  readonly metadata: any;
  readonly name: string;
  readonly runCount: number;
  readonly sequenceNumber: number;
  readonly " $fragmentType": "ExperimentAnnotationMetric_experiment";
};
export type ExperimentAnnotationMetric_experiment$key = {
  readonly " $data"?: ExperimentAnnotationMetric_experiment$data;
  readonly " $fragmentSpreads": FragmentRefs<"ExperimentAnnotationMetric_experiment">;
};

const node: ReaderInlineDataFragment = {
  "kind": "InlineDataFragment",
  "name": "ExperimentAnnotationMetric_experiment"
};

(node as any).hash = "19529202793f86cb4bf6cfbc679bd212";

export default node;
