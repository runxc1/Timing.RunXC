import { ref } from "vue";
import { db, type OutboxItem } from "./db";
import { makeClient } from "./supabase";

/**
 * Outbox flusher + realtime mirror.
 *
 * Writes: UI -> enqueueWrite (mirror + outbox) -> flushOutbox pushes to
 * Supabase in creation order. Row ids are client-generated UUIDs, so a
 * retried insert conflicts (23505) and is treated as already-applied.
 *
 * Reads: realtime changes are merged into the mirror; rows with pending
 * outbox writes are never clobbered (local edits win until flushed).
 */

export const pendingCount = ref(0);
export const parkedCount = ref(0);
export const syncing = ref(false);

let flushing = false;
let flushQueued = false;

const raceSubs = new Map<string, () => void>();

export function startSync(): void {
  void refreshPendingCount();
  window.addEventListener("online", () => queueFlush());
  queueFlush();
}

/** Drop writes that can never succeed (operator acknowledged them). */
export async function discardParked(): Promise<void> {
  const stuck = await db.outbox.filter((i) => !!i.parked).toArray();
  await db.outbox.bulkDelete(stuck.map((i) => i.id));
  await refreshPendingCount();
}

export function queueFlush(): void {
  if (flushing) {
    flushQueued = true;
    return;
  }
  void flush();
}

async function refreshPendingCount(): Promise<void> {
  const all = await db.outbox.toArray();
  pendingCount.value = all.filter((i) => !i.parked).length;
  parkedCount.value = all.filter((i) => !!i.parked).length;
}

async function flush(): Promise<void> {
  flushing = true;
  syncing.value = true;
  try {
    // Sequential pass; newest-wins ordering matters within a race. Parked
    // items are skipped so one bad write cannot block the queue.
    let item: OutboxItem | undefined;
    while ((item = await db.outbox.orderBy("created_at").filter((i) => !i.parked).first())) {
      const ok = await pushItem(item);
      if (!ok) break; // offline or hard failure — retry on next queue
    }
  } finally {
    flushing = false;
    syncing.value = false;
    await refreshPendingCount();
    if (flushQueued) {
      flushQueued = false;
      queueFlush();
    }
  }
}

async function pushItem(item: OutboxItem): Promise<boolean> {
  if (!navigator.onLine) return false;
  const client = makeClient({ raceCode: item.race_code });
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let res: { error: { code?: string; message?: string } | null };
  try {
    if (item.op === "insert") {
      res = await client.from(item.table).insert({ id: item.row_id, ...item.payload });
    } else if (item.op === "delete") {
      res = await client.from(item.table).delete().eq("id", item.row_id);
    } else {
      res = await client.from(item.table).update(item.payload).eq("id", item.row_id);
    }
  } catch (e) {
    // Network down mid-flight; leave queued.
    console.warn("sync push threw", e);
    return false;
  }
  if (res.error) {
    if (res.error.code === "23505" || res.error.code === "409") {
      const details = (res as { error: { details?: string } }).error.details ?? "";
      if (details.includes("_pkey")) {
        // Only a conflict on the row's own primary key means "already applied".
        await db.outbox.delete(item.id);
        await refreshPendingCount();
        return true;
      }
      // Other unique conflicts (e.g. finish_slots (race_id, seq)) mean our
      // seq was stale — renumber from server truth and retry.
      if (await tryRenumberSeq(item)) return true;
    }
    const attempts = item.attempts + 1;
    const message = res.error.message ?? res.error.code ?? "sync failed";
    // Auth/RLS rejections and exhausted retries cannot succeed on their own.
    // Park them (surfaced in the console) rather than silently dropping a
    // finish the operator already recorded.
    const fatal = res.error.code === "401" || res.error.code === "403" || attempts > 20;
    await db.outbox.update(item.id, {
      attempts,
      last_error: message,
      ...(fatal ? { parked: true } : {}),
    });
    if (fatal) {
      console.error("sync parked:", item.table, item.op, message);
      return true;
    }
    return false;
  }
  await db.outbox.delete(item.id);
  await refreshPendingCount();
  return true;
}

/**
 * finish_slots insert hit a (race_id, seq) unique conflict: our seq was stale.
 * Pull the server's max seq, bump the queued payload and mirror row, and let
 * the flush loop retry. Returns false if not renumberable (park the item).
 */
async function tryRenumberSeq(item: OutboxItem): Promise<boolean> {
  if (item.table !== "finish_slots" || item.op !== "insert" || item.attempts >= 5) {
    return false;
  }
  const raceId = (item.payload as { race_id?: string }).race_id;
  if (!raceId) return false;
  const client = makeClient({ raceCode: item.race_code });
  const { data, error } = await client
    .from("finish_slots")
    .select("seq")
    .eq("race_id", raceId);
  if (error) return false;
  const max = (data ?? []).reduce((m: number, r: { seq: number }) => Math.max(m, r.seq), 0);
  const seq = max + 1;
  await db.outbox.update(item.id, {
    payload: { ...item.payload, seq },
    attempts: item.attempts + 1,
    last_error: `renumbered to seq ${seq}`,
  });
  await db.finish_slots.update(item.row_id, { seq });
  return true;
}

/** Subscribe realtime for a race; merges server rows into the local mirror. */
export function subscribeRace(raceId: string, raceCode: string): () => void {
  const key = raceId;
  if (raceSubs.has(key)) return raceSubs.get(key)!;

  const client = makeClient({ raceCode });
  const channel = client
    .channel(`race-${raceId}`)
    .on(
      "postgres_changes",
      { event: "*", schema: "public", table: "finish_slots", filter: `race_id=eq.${raceId}` },
      (msg) => void mergeChange("finish_slots", msg.eventType, msg.new, msg.old),
    )
    .on(
      "postgres_changes",
      { event: "*", schema: "public", table: "athletes", filter: `race_id=eq.${raceId}` },
      (msg) => void mergeChange("athletes", msg.eventType, msg.new, msg.old),
    )
    .on(
      "postgres_changes",
      { event: "*", schema: "public", table: "races", filter: `id=eq.${raceId}` },
      (msg) => void mergeChange("races", msg.eventType, msg.new, msg.old),
    )
    .subscribe();

  const unsub = () => {
    void client.removeChannel(channel);
    raceSubs.delete(key);
  };
  raceSubs.set(key, unsub);
  return unsub;
}

type MirrorTable = "races" | "athletes" | "finish_slots";

/** Apply one realtime change; DELETE removes the mirror row, else upsert it. */
async function mergeChange(
  table: MirrorTable,
  eventType: string,
  next: Record<string, unknown> | undefined,
  prev: Record<string, unknown> | undefined,
): Promise<void> {
  if (eventType === "DELETE") {
    const id = (prev?.id ?? next?.id) as string | undefined;
    if (!id) return;
    if ((await db.outbox.where("row_id").equals(id).count()) > 0) return;
    await db[table].delete(id);
    return;
  }
  await mergeRow(table, next);
}

async function mergeRow(
  table: MirrorTable,
  row: Record<string, unknown> | undefined,
): Promise<void> {
  if (!row || typeof row.id !== "string") return;
  const hasPending = await db.outbox
    .where("row_id")
    .equals(row.id as string)
    .count();
  if (hasPending > 0) return; // local edits win until flushed
  await db[table].put({ ...row, raw: row } as never);
}

/** Pull current server state for a race into the mirror (on console load). */
export async function pullRace(
  raceId: string,
  raceCode: string,
): Promise<void> {
  const client = makeClient({ raceCode });
  const [races, athletes, slots] = await Promise.all([
    client.from("races").select("*").eq("id", raceId).maybeSingle(),
    client.from("athletes").select("*").eq("race_id", raceId),
    client.from("finish_slots").select("*").eq("race_id", raceId),
  ]);
  if (races.data) await mergeRow("races", races.data as Record<string, unknown>);
  for (const a of athletes.data ?? []) {
    await mergeRow("athletes", a as Record<string, unknown>);
  }
  for (const s of slots.data ?? []) {
    await mergeRow("finish_slots", s as Record<string, unknown>);
  }
}
