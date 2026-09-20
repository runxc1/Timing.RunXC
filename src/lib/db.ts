import Dexie, { type Table } from "dexie";

/**
 * Local mirror + write queue. The UI reads exclusively from these tables
 * (via liveQuery) so the app behaves identically online and offline.
 * `outbox` holds pending writes replayed to Supabase in order.
 */

export interface OutboxItem {
  id: string;
  /** Meet timer code that authorizes this write (X-Timer-Code). */
  auth_code: string;
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

/**
 * A backup stopwatch tap held locally until the record_timer_slot RPC can
 * carry it to the server (backup devices never write official finish_slots).
 */
export interface BackupTap {
  id: string;
  race_id: string;
  auth_code: string;
  t0_offset_ms: number;
  captured_at: number;
  /** IndexedDB cannot index booleans: 0 = queued, 1 = uploaded. */
  sent: 0 | 1;
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
  backup_taps!: Table<BackupTap, string>;

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
    // Meet-level timer codes replace per-race codes; queued writes from the
    // old scheme cannot be authorized anymore, so start the queue clean.
    this.version(3)
      .stores({
        outbox: "id, auth_code, created_at, row_id",
        races: "id",
        backup_taps: "id, race_id, captured_at",
      })
      .upgrade((tx) => tx.table("outbox").clear());
    // v3's schema was revised while in development; re-declare it as v4 so any
    // browser that caught the earlier draft upgrades cleanly. Production users
    // (v1/v2) see no-op index changes here.
    this.version(4).stores({
      outbox: "id, auth_code, created_at, row_id",
      races: "id",
      athletes: "id, race_id, code",
      finish_slots: "id, race_id, seq, athlete_id",
      backup_taps: "id, race_id, captured_at",
    });
    // Needed to find queued-but-unsent backup taps during flush.
    this.version(5).stores({
      backup_taps: "id, race_id, captured_at, sent",
    });
  }
}

export const db = new TimingDB();

export function uuid(): string {
  return crypto.randomUUID();
}

/** Queue a write and optimistically apply it to the mirror. */
export async function enqueueWrite(opts: {
  timerCode: string;
  table: OutboxItem["table"];
  op: OutboxItem["op"];
  rowId: string;
  payload?: Record<string, unknown>;
  mirrorPatch?: Record<string, unknown>;
}): Promise<void> {
  await db.transaction("rw", db.outbox, db[opts.table], async () => {
    await db.outbox.add({
      id: uuid(),
      auth_code: opts.timerCode.toUpperCase(),
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
