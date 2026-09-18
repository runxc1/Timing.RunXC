import Dexie, { type Table } from "dexie";

/**
 * Local mirror + write queue. The UI reads exclusively from these tables
 * (via liveQuery) so the app behaves identically online and offline.
 * `outbox` holds pending writes replayed to Supabase in order.
 */

export interface OutboxItem {
  id: string;
  race_code: string;
  table: "races" | "athletes" | "finish_slots";
  op: "insert" | "update" | "delete";
  /** Server row id (client-generated UUID for inserts). */
  row_id: string;
  payload: Record<string, unknown>;
  created_at: number;
  attempts: number;
  last_error?: string;
  /** Set when a write can never succeed (bad credentials); skipped, not dropped. */
  parked?: boolean;
}

export interface MirrorRace {
  id: string;
  meet_id?: string;
  race_code?: string;
  name?: string;
  status?: string;
  scheduled_start?: string | null;
  started_at?: string | null;
  finalized_at?: string | null;
  team_size?: number;
  tiebreak_depth?: number;
  raw?: unknown;
}

export interface MirrorAthlete {
  id: string;
  race_id?: string;
  school_id?: string | null;
  code?: string;
  name?: string | null;
  grade?: string | null;
  source?: string;
  raw?: unknown;
}

export interface MirrorSlot {
  id: string;
  race_id?: string;
  seq?: number;
  athlete_id?: string | null;
  t0_offset_ms?: number | null;
  status?: string;
  device_id?: string;
  captured_at?: string;
  place?: number | null;
  raw?: unknown;
}

/** Stable per-device id used to attribute finish slots. */
export function deviceId(): string {
  let id = localStorage.getItem("runxc-device-id");
  if (!id) {
    id = crypto.randomUUID();
    localStorage.setItem("runxc-device-id", id);
  }
  return id;
}

class TimingDB extends Dexie {
  outbox!: Table<OutboxItem, string>;
  races!: Table<MirrorRace, string>;
  athletes!: Table<MirrorAthlete, string>;
  finish_slots!: Table<MirrorSlot, string>;

  constructor() {
    super("runxc-timing");
    this.version(1).stores({
      outbox: "id, race_code, created_at",
      races: "id, race_code",
      athletes: "id, race_id, code",
      finish_slots: "id, race_id, seq, athlete_id",
    });
    this.version(2).stores({
      outbox: "id, race_code, created_at, row_id",
    });
  }
}

export const db = new TimingDB();

export function uuid(): string {
  return crypto.randomUUID();
}

/** Queue a write and optimistically apply it to the mirror. */
export async function enqueueWrite(opts: {
  raceCode: string;
  table: OutboxItem["table"];
  op: OutboxItem["op"];
  rowId: string;
  payload?: Record<string, unknown>;
  mirrorPatch?: Record<string, unknown>;
}): Promise<void> {
  await db.transaction("rw", db.outbox, db[opts.table], async () => {
    await db.outbox.add({
      id: uuid(),
      race_code: opts.raceCode.toUpperCase(),
      table: opts.table,
      op: opts.op,
      row_id: opts.rowId,
      payload: opts.payload ?? {},
      created_at: Date.now(),
      attempts: 0,
    });
    if (opts.op === "delete") {
      await db[opts.table].delete(opts.rowId);
    } else if (opts.mirrorPatch) {
      await db[opts.table].put({
        id: opts.rowId,
        ...opts.mirrorPatch,
      } as never);
    }
  });
}
