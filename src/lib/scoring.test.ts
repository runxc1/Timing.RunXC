import { describe, expect, it } from "vitest";
import { computeTeamStandings, type ScorableRunner } from "./scoring";

function r(
  place: number,
  school: string,
  name = `Runner ${place}`,
): ScorableRunner {
  return {
    athlete_id: `${school}-${place}`,
    athlete_name: name,
    school_id: school,
    school_name: school,
    grade: "11",
    offset_ms: place * 1000,
    place,
  };
}

describe("computeTeamStandings", () => {
  it("scores top 5 and ranks by total", () => {
    // Team A takes places 1,2,10,11,12 = 36; Team B takes 3,4,5,6,7 = 25.
    const runners = [
      r(1, "A"), r(2, "A"), r(10, "A"), r(11, "A"), r(12, "A"),
      r(3, "B"), r(4, "B"), r(5, "B"), r(6, "B"), r(7, "B"),
    ];
    const rows = computeTeamStandings(runners);
    expect(rows[0].school_id).toBe("B");
    expect(rows[0].total).toBe(25);
    expect(rows[1].school_id).toBe("A");
    expect(rows[1].total).toBe(36);
  });

  it("ranks incomplete teams after complete teams regardless of score", () => {
    // Complete team A: 1,2,3,4,5 = 15. Incomplete B: 6,7 = 13. Incomplete C: 9.
    const runners = [
      r(1, "A"), r(2, "A"), r(3, "A"), r(4, "A"), r(5, "A"),
      r(6, "B"), r(7, "B"),
      r(9, "C"),
    ];
    const rows = computeTeamStandings(runners);
    // A complete first; among incomplete teams, lower total wins (C 9 < B 13).
    expect(rows.map((x) => x.school_id)).toEqual(["A", "C", "B"]);
    expect(rows.map((x) => x.rank)).toEqual([1, 2, 3]);
  });

  it("marks only the top 5 as scoring", () => {
    const runners = Array.from({ length: 7 }, (_, i) => r(i + 1, "A"));
    const rows = computeTeamStandings(runners);
    expect(rows[0].runners.filter((x) => x.scoring).length).toBe(5);
  });

  it("breaks ties with 6th-place runner", () => {
    // Team A: 1+4+6+9+10 = 30, 6th runner = 20
    // Team B: 2+3+5+7+13 = 30, 6th runner = 14  → B wins the tiebreak
    const runners = [
      r(1, "A"), r(4, "A"), r(6, "A"), r(9, "A"), r(10, "A"), r(20, "A"),
      r(2, "B"), r(3, "B"), r(5, "B"), r(7, "B"), r(13, "B"), r(14, "B"),
    ];
    const rows = computeTeamStandings(runners);
    expect(rows[0].total).toBe(30);
    expect(rows[1].total).toBe(30);
    // B's tiebreak (14) beats A's (20)
    expect(rows[0].school_id).toBe("B");
    expect(rows[0].tiebreak).toBe(14);
    expect(rows[1].tiebreak).toBe(20);
  });

  it("handles fewer than 5 finishers on a team", () => {
    const runners = [r(1, "A"), r(5, "A"), r(2, "B"), r(3, "B"), r(4, "B")];
    const rows = computeTeamStandings(runners);
    const a = rows.find((x) => x.school_id === "A")!;
    expect(a.total).toBe(6);
    expect(a.tiebreak).toBeNull();
  });

  it("assigns equal ranks on identical score+tiebreak", () => {
    const runners = [
      r(1, "A"), r(4, "A"), r(5, "A"), r(8, "A"), r(12, "A"),
      r(2, "B"), r(3, "B"), r(6, "B"), r(7, "B"), r(11, "B"),
    ];
    // A: 1+4+5+8+12=30 no tiebreak; B: 2+3+6+7+11=29 — not equal; craft equal:
    const equal = [
      r(1, "A"), r(4, "A"), r(5, "A"), r(8, "A"), r(12, "A"), // 30
      r(2, "B"), r(3, "B"), r(6, "B"), r(7, "B"), r(12, "B"), // 30 (dup place ok for test)
    ];
    const rows = computeTeamStandings(equal);
    expect(rows[0].rank).toBe(1);
    expect(rows[1].rank).toBe(1);
    void runners;
  });
});
