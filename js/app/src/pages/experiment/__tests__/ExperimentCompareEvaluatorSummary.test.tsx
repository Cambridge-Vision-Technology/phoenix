import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it } from "vitest";

import { installTestMatchMedia } from "@phoenix/__tests__/installTestMatchMedia";
import { installTestStorage } from "@phoenix/__tests__/installTestStorage";
import { ThemeProvider } from "@phoenix/contexts";

import {
  ExperimentCompareEvaluatorSummary,
  useExperimentCompareEvaluatorSummaryStore,
} from "../ExperimentCompareEvaluatorSummary";

installTestMatchMedia();
installTestStorage();

let container: HTMLDivElement;
let root: Root;

beforeEach(() => {
  useExperimentCompareEvaluatorSummaryStore.setState({ isExpanded: true });
  container = document.createElement("div");
  document.body.appendChild(container);
  root = createRoot(container);
});

afterEach(() => {
  act(() => root.unmount());
  container.remove();
});

function renderSummaries(columns: number, evaluatorCount = 3) {
  act(() => {
    root.render(
      <ThemeProvider>
        {Array.from({ length: columns }, (_, index) => (
          <ExperimentCompareEvaluatorSummary
            key={index}
            evaluatorCount={evaluatorCount}
          >
            <div>scores</div>
          </ExperimentCompareEvaluatorSummary>
        ))}
      </ThemeProvider>
    );
  });
}

function press(label: string) {
  const button = container.querySelector<HTMLButtonElement>(
    `button[aria-label="${label}"]`
  );
  expect(button).not.toBeNull();
  act(() => button?.click());
}

function count(text: string) {
  return (container.textContent ?? "").split(text).length - 1;
}

describe("ExperimentCompareEvaluatorSummary", () => {
  it("shows the summary and its evaluator count by default", () => {
    renderSummaries(1);
    expect(count("scores")).toBe(1);
    expect(count("Evaluators (3)")).toBe(1);
  });

  it("collapses and expands, keeping the count visible", () => {
    renderSummaries(1);
    press("Hide evaluator summary");
    expect(count("scores")).toBe(0);
    expect(count("Evaluators (3)")).toBe(1);
    press("Show evaluator summary");
    expect(count("scores")).toBe(1);
  });

  it("collapses every column together, keeping them aligned", () => {
    renderSummaries(3);
    expect(count("scores")).toBe(3);
    press("Hide evaluator summary");
    expect(count("scores")).toBe(0);
  });

  it("has no toggle when there are no evaluators", () => {
    renderSummaries(1, 0);
    expect(container.querySelector("button")).toBeNull();
    expect(count("scores")).toBe(1);
  });
});
