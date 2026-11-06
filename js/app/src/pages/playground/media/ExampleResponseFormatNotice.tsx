import { Token } from "@phoenix/components";

import { hasExampleResponseFormat } from "./exampleResponseFormat";

/**
 * Says that a dataset example brings its own response format.
 *
 * Such an example ignores the format set on the prompt, so an edit to that format in the
 * playground would not reach its runs. Without this there is nothing on screen to explain why.
 */
export function ExampleResponseFormatNotice({
  metadata,
}: {
  metadata: unknown;
}) {
  if (!hasExampleResponseFormat(metadata)) {
    return null;
  }
  return (
    <Token size="S" color="var(--global-color-blue-1000)">
      Uses its own response format
    </Token>
  );
}
