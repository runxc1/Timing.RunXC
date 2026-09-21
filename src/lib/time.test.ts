import { describe, expect, it } from "vitest";
import { defaultStartInput, isoToLocalInput, toIsoOrNull } from "./time";

describe("scheduled-start picker helpers", () => {
  it("turns a full datetime-local value into an ISO timestamp", () => {
    const iso = toIsoOrNull("2026-09-21T17:05");
    expect(iso).toMatch(/^2026-09-2[12]T/);
  });

  it("returns null instead of throwing on empty or time-only values", () => {
    // A bare clock time used to reach `new Date(...).toISOString()` and throw.
    expect(toIsoOrNull("")).toBeNull();
    expect(toIsoOrNull(null)).toBeNull();
    expect(toIsoOrNull("17:05")).toBeNull();
    expect(toIsoOrNull("not a date")).toBeNull();
  });

  it("defaults a race to the meet date at 9 AM", () => {
    expect(defaultStartInput("2026-09-20")).toBe("2026-09-20T09:00");
    expect(defaultStartInput(null)).toBe("");
    expect(defaultStartInput("2026-09-20T00:00:00Z")).toBe("");
  });

  it("renders an ISO timestamp back into the local picker shape", () => {
    expect(isoToLocalInput("2026-09-21T23:05:00.000Z")).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/);
    expect(isoToLocalInput(null)).toBe("");
    expect(isoToLocalInput("nope")).toBe("");
  });
});
