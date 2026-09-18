/**
 * Pure team scoring — mirrors get_team_standings() in the migration so the
 * console can score instantly offline. Keep in sync with SQL.
 */
export interface ScorableRunner {
  athlete_id: string;
  athlete_name: string;
  school_id: string | null;
  school_name: string | null;
  grade: string | null;
  /** Raw clock offset in ms when the runner crossed. */
  offset_ms: number;
  /** Finish position (1-based), assigned by finish order. */
  place: number;
}

export interface TeamStandingOptions {
  teamSize?: number; // default 5 scoring
  tiebreakDepth?: number; // default 6 (the 6th finisher is the tiebreaker)
}

export interface TeamRow {
  school_id: string;
  school_name: string;
  total: number;
  tiebreak: number | null;
  rank: number;
  runners: Array<{
    athlete_id: string;
    name: string;
    grade: string | null;
    place: number;
    offset_ms: number;
    scoring: boolean;
  }>;
}

export function computeTeamStandings(
  runners: ScorableRunner[],
  opts: TeamStandingOptions = {},
): TeamRow[] {
  const teamSize = opts.teamSize ?? 5;
  const tiebreakDepth = opts.tiebreakDepth ?? 7;

  const bySchool = new Map<string, ScorableRunner[]>();
  for (const r of runners) {
    if (!r.school_id) continue;
    const list = bySchool.get(r.school_id) ?? [];
    list.push(r);
    bySchool.set(r.school_id, list);
  }

  const rows: Array<Omit<TeamRow, "rank">> = [];
  for (const [schoolId, members] of bySchool) {
    const sorted = [...members].sort((a, b) => a.place - b.place);
    const scorers = sorted.slice(0, teamSize);
    const tiebreakers = sorted.slice(teamSize, tiebreakDepth);
    const total = scorers.reduce((s, r) => s + r.place, 0);
    const tiebreak =
      tiebreakers.length > 0
        ? tiebreakers.reduce((s, r) => s + r.place, 0)
        : null;
    const schoolName = sorted[0]?.school_name ?? "Unknown";
    rows.push({
      school_id: schoolId,
      school_name: schoolName,
      total,
      tiebreak,
      runners: sorted.map((r) => ({
        athlete_id: r.athlete_id,
        name: r.athlete_name,
        grade: r.grade,
        place: r.place,
        offset_ms: r.offset_ms,
        scoring: r.place <= teamSize,
      })),
    });
  }

  // Standard XC: complete teams (teamSize finishers) rank ahead of
  // incomplete teams; within a tier, low score wins, then tiebreak.
  const complete = (r: Omit<TeamRow, "rank">) => (r.runners.length >= teamSize ? 0 : 1);
  rows.sort(
    (a, b) =>
      complete(a) - complete(b) ||
      a.total - b.total ||
      (a.tiebreak ?? Number.MAX_SAFE_INTEGER) -
        (b.tiebreak ?? Number.MAX_SAFE_INTEGER),
  );

  let rank = 0;
  let prevKey = "";
  return rows.map((row, i) => {
    const key = `${complete(row)}|${row.total}|${row.tiebreak ?? "none"}`;
    if (key !== prevKey) {
      rank = i + 1;
      prevKey = key;
    }
    return { ...row, rank };
  });
}

/** Full individual results: matched slots by place, then DNFs. */
export interface IndividualRow {
  place: number | null;
  athlete_name: string;
  school_name: string | null;
  grade: string | null;
  code: string;
  offset_ms: number | null;
  status: string;
}

export function computeIndividualResults(
  slots: Array<{
    status: string;
    seq: number;
    t0_offset_ms: number | null;
    athlete_id: string | null;
  }>,
  athletes: Map<string, { name: string; code: string; school_name: string | null; grade: string | null }>,
): IndividualRow[] {
  const matched = slots
    .filter((s) => s.status === "matched" && s.athlete_id)
    .sort((a, b) => a.seq - b.seq);
  const rows: IndividualRow[] = matched.map((s, i) => {
    const a = athletes.get(s.athlete_id!);
    return {
      place: i + 1,
      athlete_name: a?.name ?? "Unknown",
      school_name: a?.school_name ?? null,
      grade: a?.grade ?? null,
      code: a?.code ?? "",
      offset_ms: s.t0_offset_ms,
      status: "matched",
    };
  });
  const dq = slots.filter((s) => s.status === "dq");
  const dnf = slots.filter((s) => s.status === "dnf");
  for (const s of [...dq, ...dnf]) {
    const a = s.athlete_id ? athletes.get(s.athlete_id) : undefined;
    rows.push({
      place: null,
      athlete_name: a?.name ?? "—",
      school_name: a?.school_name ?? null,
      grade: a?.grade ?? null,
      code: a?.code ?? "",
      offset_ms: s.t0_offset_ms,
      status: s.status,
    });
  }
  return rows;
}
