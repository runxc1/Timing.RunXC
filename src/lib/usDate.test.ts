import { describe, expect, it } from "vitest";
import {
  formatUsDate,
  formatUsTime,
  maskUsDate,
  parseUsDate,
  parseUsTime,
} from "./usDate";

describe("maskUsDate", () => {
  it("puts the month first whether or not the user types separators", () => {
    expect(maskUsDate("9")).toBe("9");
    expect(maskUsDate("923")).toBe("9/23");
    expect(maskUsDate("9232026")).toBe("9/23/2026");
    expect(maskUsDate("11302026")).toBe("11/30/2026");
  });

  it("keeps separators the user typed", () => {
    expect(maskUsDate("9/")).toBe("9/");
    expect(maskUsDate("9/23/2026")).toBe("9/23/2026");
    expect(maskUsDate("1/2/2026")).toBe("1/2/2026");
  });

  it("rolls digits past a full segment into the next one", () => {
    expect(maskUsDate("11/302")).toBe("11/30/2");
    expect(maskUsDate("11/302026")).toBe("11/30/2026");
  });

  it("ignores stray characters and extra digits", () => {
    expect(maskUsDate("")).toBe("");
    expect(maskUsDate("abc")).toBe("");
    expect(maskUsDate("92320267788")).toBe("9/23/2026");
  });
});

describe("parseUsDate", () => {
  it("reads month/day/year", () => {
    expect(parseUsDate("9/23/2026")).toBe("2026-09-23");
    expect(parseUsDate("12/1/2026")).toBe("2026-12-01");
  });

  it("rejects incomplete, impossible and out-of-range input", () => {
    expect(parseUsDate("")).toBeNull();
    expect(parseUsDate("9/23")).toBeNull();
    expect(parseUsDate("2/30/2026")).toBeNull();
    expect(parseUsDate("13/01/2026")).toBeNull();
    expect(parseUsDate("2026-09-23")).toBeNull();
  });
});

describe("parseUsTime", () => {
  it("understands meridiem, 24-hour and typed digits", () => {
    expect(parseUsTime("5:05 pm")).toBe("17:05");
    expect(parseUsTime("5:05PM")).toBe("17:05");
    expect(parseUsTime("5 p.m.")).toBe("17:00");
    expect(parseUsTime("12:30 AM")).toBe("00:30");
    expect(parseUsTime("12 PM")).toBe("12:00");
    expect(parseUsTime("17:05")).toBe("17:05");
    expect(parseUsTime("505")).toBe("05:05");
    expect(parseUsTime("1705")).toBe("17:05");
    expect(parseUsTime("505p")).toBe("17:05");
    expect(parseUsTime("9:30a")).toBe("09:30");
  });

  it("rejects nonsense", () => {
    expect(parseUsTime("")).toBeNull();
    expect(parseUsTime("13:00 pm")).toBeNull();
    expect(parseUsTime("25:00")).toBeNull();
    expect(parseUsTime("9:75")).toBeNull();
  });
});

describe("formatters", () => {
  it("render the values back in US order for display", () => {
    expect(formatUsDate("2026-09-23")).toBe("09/23/2026");
    expect(formatUsDate(null)).toBe("");
    expect(formatUsTime("17:05")).toBe("5:05 PM");
    expect(formatUsTime("00:30")).toBe("12:30 AM");
    expect(formatUsTime("09:00")).toBe("9:00 AM");
  });
});
