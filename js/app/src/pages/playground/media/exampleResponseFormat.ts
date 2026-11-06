/**
 * The metadata key a dataset example's own response format lives under.
 * Must match `EXAMPLE_RESPONSE_FORMAT_KEY` in `helpers/example_response_format.py`.
 */
export const EXAMPLE_RESPONSE_FORMAT_KEY = "phoenix_response_format";

/**
 * Whether a run of this example will use the example's response format, not the prompt's.
 */
export function hasExampleResponseFormat(metadata: unknown): boolean {
  if (typeof metadata !== "object" || metadata === null) {
    return false;
  }
  const value = (metadata as Record<string, unknown>)[
    EXAMPLE_RESPONSE_FORMAT_KEY
  ];
  return value !== undefined && value !== null;
}
