import { describe, expect, it } from "vitest";
import { csvCell, csvFilenamePart, toCsv } from "./csv";

describe("CSV export formatting", () => {
  it("escapes commas, quotes, and line breaks", () => {
    expect(csvCell('Doe, "Sam"')).toBe('"Doe, ""Sam"""');
    expect(csvCell("North\r\nMesa")).toBe('"North\r\nMesa"');
  });

  it("writes rows with CRLF separators and empty values", () => {
    expect(toCsv([["Code", "Name", "Grade"], ["AB12", "Sam", null]])).toBe(
      "Code,Name,Grade\r\nAB12,Sam,",
    );
  });

  it("creates safe ASCII filename parts", () => {
    expect(csvFilenamePart("Pine Park Invitational")).toBe("pine-park-invitational");
    expect(csvFilenamePart("")).toBe("results");
    expect(csvFilenamePart("", "meet")).toBe("meet");
  });
});
