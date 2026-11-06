import {
  EXAMPLE_RESPONSE_FORMAT_KEY,
  hasExampleResponseFormat,
} from "../exampleResponseFormat";

describe("hasExampleResponseFormat", () => {
  it("is true when the example has one", () => {
    expect(
      hasExampleResponseFormat({ [EXAMPLE_RESPONSE_FORMAT_KEY]: { type: "x" } })
    ).toBe(true);
  });

  it.each([
    [null],
    [undefined],
    ["text"],
    [{}],
    [{ response_format: { type: "x" } }],
    [{ [EXAMPLE_RESPONSE_FORMAT_KEY]: null }],
  ])("is false for %j", (metadata) => {
    expect(hasExampleResponseFormat(metadata)).toBe(false);
  });
});
