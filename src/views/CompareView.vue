<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref } from "vue";
import { useRoute } from "vue-router";
import { makeClient } from "../lib/supabase";
import { subscribeTimerEvents } from "../lib/sync";
import { formatClock } from "../lib/time";
import { normalizeCode, isValidAthleteCode } from "../lib/codes";
import { useSession } from "../stores/session";

/**
 * Compare screen (meet admins only): the official finish order next to the
 * backup stopwatch taps, so a manager can spot a missed finisher and merge
 * them in, or correct an official time. Backup taps are compared by offset —
 * one with no official slot within a few seconds is flagged as likely missing.
 */

const route = useRoute();
const session = useSession();
const raceId = String(route.params.raceId);

interface Slot {
  id: string;
  seq: number;
  t0_offset_ms: number | null;
  athlete_id: string | null;
  status: string;
}
interface Athlete {
  id: string;
  code: string;
  name: string | null;
  grade: string | null;
}
interface TimerRow {
  id: string;
  device_id: string;
  role: "primary" | "backup";
  started_at: string;
}
interface TimerTap {
  id: string;
  race_timer_id: string;
  seq: number;
  t0_offset_ms: number;
  device_id: string;
}

const admin = computed(() => makeClient({ meetAdminCode: session.meetAdminCode || undefined }));

const loading = ref(true);
const error = ref("");
const raceInfo = ref<{ name: string; status: string; meet_id: string } | null>(null);
const slots = ref<Slot[]>([]);
const athletes = ref<Map<string, Athlete>>(new Map());
const timers = ref<TimerRow[]>([]);
const taps = ref<TimerTap[]>([]);

/** Admin code must belong to this race's meet before anything is shown. */
async function load() {
  if (!session.meetAdminCode) return;
  const c = admin.value;
  const r = await c.from("races").select("id, name, status, meet_id").eq("id", raceId).maybeSingle();
  if (r.error || !r.data) {
    error.value = r.error?.message ?? "Race not found.";
    loading.value = false;
    return;
  }
  const own = await c.from("meets").select("id").eq("id", r.data.meet_id).eq("admin_code", session.meetAdminCode).maybeSingle();
  let isAuth = !!own.data;
  if (!isAuth) {
    const delegated = await c
      .from("meet_admins")
      .select("id")
      .eq("meet_id", r.data.meet_id)
      .eq("code", session.meetAdminCode)
      .maybeSingle();
    isAuth = !!delegated.data;
  }
  if (!isAuth) {
    error.value = "That admin code is not valid for this meet.";
    loading.value = false;
    return;
  }
  error.value = "";
  raceInfo.value = r.data;

  const [sl, at, tm] = await Promise.all([
    c.from("finish_slots").select("*").eq("race_id", raceId).order("seq", { ascending: true }),
    c.from("athletes").select("id, code, name, grade").eq("race_id", raceId),
    c.from("race_timers").select("*").eq("race_id", raceId).order("started_at"),
  ]);
  slots.value = (sl.data ?? []) as Slot[];
  athletes.value = new Map(((at.data ?? []) as Athlete[]).map((a) => [a.id, a]));
  timers.value = (tm.data ?? []) as TimerRow[];
  const timerIds = timers.value.map((t) => t.id);
  if (timerIds.length === 0) {
    taps.value = [];
  } else {
    const ts = await c.from("timer_slots").select("*").in("race_timer_id", timerIds).order("seq");
    taps.value = (ts.data ?? []) as TimerTap[];
  }
  loading.value = false;
}

// --- realtime refresh ---
let unsub: (() => void) | null = null;
onMounted(() => {
  if (session.meetAdminCode) {
    void load();
    unsub = subscribeTimerEvents(raceId, session.meetAdminCode, () => void load());
  } else {
    loading.value = false;
  }
});
onUnmounted(() => unsub?.());

// --- admin code unlock (when arriving without a stored code) ---
const unlockInput = ref("");
function unlock() {
  session.meetAdminCode = normalizeCode(unlockInput.value);
  unlockInput.value = "";
  void load();
}

// --- comparison: flag backup taps with no official slot nearby ---
const MATCH_WINDOW_MS = 2500;
const roleOfTap = computed(() => new Map(timers.value.map((t) => [t.id, t.role])));
const backupTaps = computed(() =>
  taps.value.filter((t) => roleOfTap.value.get(t.race_timer_id) === "backup"),
);
function officialNear(offset: number): Slot | undefined {
  return slots.value.find(
    (s) => s.t0_offset_ms != null && Math.abs(s.t0_offset_ms - offset) <= MATCH_WINDOW_MS,
  );
}

// --- merge a backup tap into the official order ---
const busy = ref("");
async function mergeTap(tap: TimerTap) {
  if (busy.value) return;
  busy.value = tap.id;
  // Anchor after the last official finisher who beat this time.
  const before = slots.value.filter((s) => s.t0_offset_ms != null && s.t0_offset_ms < tap.t0_offset_ms);
  const anchor = before.length ? before[before.length - 1] : null;
  const { error: err } = await admin.value.rpc("insert_slot_relative", {
    p_race_id: raceId,
    p_anchor_slot_id: anchor?.id ?? null,
    p_side: "after",
    p_code: null,
    p_device_id: `backup-${tap.device_id.slice(0, 8)}`,
    // The backup watch's exact time, not an interpolated guess.
    p_t0_offset_ms: tap.t0_offset_ms,
  });
  if (err) error.value = err.message ?? "Could not insert the finisher.";
  busy.value = "";
  await load();
}

// --- edit an official time ---
const editingId = ref<string | null>(null);
const editValue = ref("");
const editError = ref("");
function startEdit(slot: Slot) {
  editingId.value = slot.id;
  editValue.value = slot.t0_offset_ms == null ? "" : formatClock(slot.t0_offset_ms);
  editError.value = "";
}
async function saveEdit() {
  if (!editingId.value) return;
  const ms = parseClock(editValue.value);
  if (ms == null) {
    editError.value = "Use 12:34.5 or 1:02:03.4";
    return;
  }
  const { error: err } = await admin.value
    .from("finish_slots")
    .update({ t0_offset_ms: ms })
    .eq("id", editingId.value);
  if (err) editError.value = err.message;
  else {
    editingId.value = null;
    await load();
  }
}

/** "12:34.5", "1:02:03.4" or "45.2" → milliseconds. */
function parseClock(raw: string): number | null {
  const m = raw.trim().match(/^(?:(\d+):)?(\d{1,2}):(\d{1,2}(?:\.\d{1,3})?)$/);
  if (!m) return null;
  const parts = raw.includes(":") ? [Number(m[1] ?? 0), Number(m[2]), Number(m[3])] : [0, 0, Number(raw)];
  const ms = ((parts[0] * 60 + parts[1]) * 60 + parts[2]) * 1000;
  return Number.isFinite(ms) && ms >= 0 ? Math.round(ms) : null;
}

// --- add a runner who never got a slot at all ---
// Every official row carries a "+" that opens this dialog anchored to that
// record and asks whether the new finisher belongs above or below it, so a
// finish the timer missed lands in exactly the right place. The header button
// opens the same dialog with no anchor, which appends at the end.
const showAdd = ref(false);
const addCode = ref("");
const addTime = ref("");
const addAnchorId = ref<string>("");
const addSide = ref<"before" | "after">("after");
const addError = ref("");

const addAnchor = computed(() => slots.value.find((s) => s.id === addAnchorId.value) ?? null);

/** Who the dialog is talking about, for the "next to place 7 …" caption. */
const addAnchorLabel = computed(() => {
  const a = addAnchor.value;
  if (!a) return "";
  const who = a.athlete_id ? athletes.value.get(a.athlete_id)?.name || athletes.value.get(a.athlete_id)?.code : "open slot";
  return `${who} · ${formatClock(a.t0_offset_ms)}`;
});

/** Place the new runner would take if inserted on this side of the anchor. */
function sidePlace(side: "before" | "after"): number | null {
  const a = addAnchor.value;
  if (!a) return slots.value.length + 1;
  return side === "before" ? a.seq : a.seq + 1;
}

function openAddAt(slot: Slot, side: "before" | "after") {
  addAnchorId.value = slot.id;
  addSide.value = side;
  addError.value = "";
  showAdd.value = true;
}

/** Header button: no anchor means "add as the last place". */
function openAddAtEnd() {
  addAnchorId.value = "";
  addSide.value = "after";
  addError.value = "";
  showAdd.value = true;
}

async function addRunner() {
  addError.value = "";
  const code = normalizeCode(addCode.value);
  if (code && !isValidAthleteCode(code)) {
    addError.value = "Codes are up to 8 letters/digits — or leave blank for an open slot.";
    return;
  }
  const ms = addTime.value ? parseClock(addTime.value) : null;
  if (addTime.value && ms == null) {
    addError.value = "Time must look like 12:34.5";
    return;
  }
  const { error: err } = await admin.value.rpc("insert_slot_relative", {
    p_race_id: raceId,
    p_anchor_slot_id: addAnchor.value?.id ?? null,
    p_side: addSide.value,
    p_code: code || null,
    p_device_id: "admin-edit",
    p_t0_offset_ms: ms,
  });
  if (err) {
    addError.value = err.message.includes("CODE_OTHER_DIVISION")
      ? "That code belongs to another division in this meet."
      : (err.message ?? "Could not add the runner.");
    return;
  }
  closeAdd();
  await load();
}

function closeAdd() {
  showAdd.value = false;
  addCode.value = "";
  addTime.value = "";
  addAnchorId.value = "";
  addSide.value = "after";
  addError.value = "";
}

// --- remove a stray open slot ---
async function deleteSlot(slot: Slot) {
  if (slot.status !== "open" || busy.value) return;
  busy.value = slot.id;
  const { error: err } = await admin.value.from("finish_slots").delete().eq("id", slot.id);
  if (err) error.value = err.message;
  busy.value = "";
  await load();
}

const timerLabel = (deviceId: string) => deviceId.slice(0, 4).toUpperCase();
</script>

<template>
  <main class="mx-auto min-h-screen max-w-5xl px-4 py-6">
    <!-- Unlock -->
    <div v-if="!session.meetAdminCode" class="mx-auto max-w-md pt-16">
      <h1 class="font-display text-2xl font-black">Compare clocks</h1>
      <p class="mt-1 text-sm text-slate-400">Enter your meet admin code to compare the primary and backup times.</p>
      <div class="mt-4 flex gap-2">
        <input
          v-model="unlockInput"
          autocapitalize="characters"
          maxlength="7"
          placeholder="Admin code"
          class="min-w-0 flex-1 rounded-xl border border-ink-700 bg-ink-900 px-4 py-3 text-center font-display text-lg font-bold tracking-[0.25em] text-brand-300 focus:border-brand-400 focus:outline-none"
          @keyup.enter="unlock"
        />
        <button class="rounded-xl bg-brand-400 px-5 font-black text-ink-950" @click="unlock">Unlock</button>
      </div>
    </div>

    <template v-else>
      <p v-if="error" class="mb-4 rounded-xl bg-red-500/10 px-4 py-3 text-sm text-red-300">{{ error }}</p>
      <div v-if="loading && !raceInfo" class="text-sm text-slate-400">Loading…</div>

      <template v-else-if="raceInfo">
        <!-- Header -->
        <div class="flex flex-wrap items-center gap-3">
          <RouterLink to="/admin" class="text-xs font-bold text-slate-500 hover:text-slate-300">← Dashboard</RouterLink>
          <h1 class="font-display text-xl font-black">{{ raceInfo.name }}</h1>
          <span
            class="rounded-full px-2.5 py-0.5 text-[10px] font-black uppercase tracking-wider"
            :class="raceInfo.status === 'finalized' ? 'bg-brand-400/20 text-brand-300' : 'bg-amber-400/15 text-amber-300'"
          >{{ raceInfo.status.replace('_', ' ') }}</span>
          <button
            class="ml-auto rounded-lg bg-brand-400 px-4 py-2 text-xs font-black text-ink-950"
            @click="openAddAtEnd"
          >
            + Add runner
          </button>
        </div>

        <!-- Timers legend -->
        <p v-if="timers.length === 0" class="mt-3 text-sm text-slate-500">
          No stopwatch has started this division yet.
        </p>
        <p v-else class="mt-3 text-xs text-slate-500">
          Devices:
          <span v-for="t in timers" :key="t.id" class="ml-2 rounded bg-ink-800 px-2 py-0.5 font-bold"
            :class="t.role === 'primary' ? 'text-brand-300' : 'text-amber-300'">
            {{ timerLabel(t.device_id) }} · {{ t.role }}
          </span>
        </p>

        <div class="mt-4 grid gap-6 lg:grid-cols-2">
          <!-- Official order -->
          <section>
            <h2 class="text-xs font-black uppercase tracking-wider text-slate-400">
              Official times ({{ slots.length }})
            </h2>
            <ol class="mt-2 flex flex-col gap-1.5">
              <li
                v-for="s in slots"
                :key="s.id"
                class="flex items-center gap-3 rounded-xl border border-ink-800 bg-ink-900 px-3 py-2"
                :class="s.status === 'dq' || s.status === 'dnf' ? 'opacity-50' : ''"
              >
                <span class="w-7 text-center font-display text-lg font-black tabular-nums text-slate-500">{{ s.seq }}</span>
                <!-- editable time -->
                <template v-if="editingId === s.id">
                  <input
                    v-model="editValue"
                    class="w-28 rounded-lg border border-brand-400 bg-ink-950 px-2 py-1 text-center font-display text-sm font-bold tabular-nums text-brand-300 focus:outline-none"
                    @keyup.enter="saveEdit"
                    @keyup.esc="editingId = null"
                  />
                  <button class="rounded bg-brand-400 px-2 py-1 text-xs font-black text-ink-950" @click="saveEdit">Save</button>
                  <button class="rounded px-2 py-1 text-xs font-bold text-slate-400 hover:bg-ink-700" @click="editingId = null">×</button>
                </template>
                <button
                  v-else
                  class="w-24 font-display text-sm font-bold tabular-nums text-slate-200 hover:text-brand-300"
                  title="Edit official time"
                  @click="startEdit(s)"
                >{{ formatClock(s.t0_offset_ms) }}</button>
                <span class="min-w-0 flex-1 truncate text-sm">
                  <template v-if="s.status === 'matched' && s.athlete_id">
                    <span v-if="!athletes.get(s.athlete_id)?.name" class="italic text-amber-300">Unregistered</span>
                    <template v-else>{{ athletes.get(s.athlete_id)?.name }}</template>
                    <span class="ml-1 text-xs text-slate-500">{{ athletes.get(s.athlete_id)?.code }}</span>
                  </template>
                  <template v-else-if="s.status === 'open'"><span class="italic text-slate-500">awaiting code…</span></template>
                  <template v-else>{{ (s.status ?? '').toUpperCase() }}</template>
                </span>
                <button
                  class="grid size-7 shrink-0 place-items-center rounded-lg border border-ink-700 text-base font-black leading-none text-brand-300 hover:border-brand-400 hover:bg-brand-400/10"
                  :title="`Add a runner next to place ${s.seq}`"
                  :aria-label="`Add a runner next to place ${s.seq}`"
                  @click="openAddAt(s, 'after')"
                >+</button>
                <button
                  v-if="s.status === 'open'"
                  class="rounded px-2 py-1 text-xs font-bold text-red-400 hover:bg-red-500/10"
                  :disabled="busy === s.id"
                  @click="deleteSlot(s)"
                >✕</button>
              </li>
              <p v-if="editError" class="text-xs text-amber-300">{{ editError }}</p>
              <li v-if="slots.length === 0" class="text-sm text-slate-500">Nothing recorded yet.</li>
            </ol>
          </section>

          <!-- Backup taps -->
          <section>
            <h2 class="text-xs font-black uppercase tracking-wider text-slate-400">
              Backup stopwatch taps ({{ backupTaps.length }})
            </h2>
            <p class="mt-1 text-xs text-slate-500">
              Flagged taps have no official finish within ~2.5s — likely a missed runner. Merge adds them
              with the backup time and opens an unclaimed code slot.
            </p>
            <ol class="mt-2 flex flex-col gap-1.5">
              <li
                v-for="t in [...backupTaps].reverse()"
                :key="t.id"
                class="flex items-center gap-3 rounded-xl border px-3 py-2"
                :class="officialNear(t.t0_offset_ms) ? 'border-ink-800 bg-ink-900' : 'border-amber-400/40 bg-amber-400/5'"
              >
                <span class="w-7 text-center font-display text-lg font-black tabular-nums text-slate-500">{{ t.seq }}</span>
                <span class="w-24 font-display text-sm font-bold tabular-nums text-amber-200">{{ formatClock(t.t0_offset_ms) }}</span>
                <span class="min-w-0 flex-1 truncate text-xs">
                  <template v-if="officialNear(t.t0_offset_ms)">
                    <span class="text-slate-500">matches place {{ officialNear(t.t0_offset_ms)?.seq }}</span>
                  </template>
                  <template v-else><span class="font-bold text-amber-300">no official finish nearby</span></template>
                </span>
                <button
                  v-if="!officialNear(t.t0_offset_ms)"
                  class="rounded-lg bg-amber-400 px-3 py-1 text-xs font-black text-ink-950 disabled:opacity-50"
                  :disabled="busy === t.id"
                  @click="mergeTap(t)"
                >Merge</button>
              </li>
              <li v-if="backupTaps.length === 0" class="text-sm text-slate-500">
                No backup device has recorded taps for this division.
              </li>
            </ol>
          </section>
        </div>
      </template>
    </template>

    <!-- Add runner dialog -->
    <div v-if="showAdd" class="fixed inset-0 z-50 grid place-items-center bg-black/70 p-6" @click.self="closeAdd()">
      <div class="w-full max-w-sm rounded-2xl border border-ink-700 bg-ink-900 p-6">
        <div class="flex items-start justify-between gap-3">
          <h3 class="font-display text-lg font-black">Add a runner</h3>
          <button class="rounded px-2 py-1 text-sm font-bold text-slate-400 hover:bg-ink-700" @click="closeAdd()">×</button>
        </div>
        <p class="mt-1 text-sm text-slate-400">
          <template v-if="addAnchor">
            Next to place {{ addAnchor.seq }} — {{ addAnchorLabel }}
          </template>
          <template v-else>For someone who finished but has no slot at all.</template>
        </p>

        <!-- Above or below the record this dialog was opened from -->
        <div v-if="addAnchor" class="mt-4">
          <span class="text-xs font-bold uppercase tracking-wider text-slate-500">Position</span>
          <div class="mt-1.5 grid grid-cols-2 gap-2">
            <button
              v-for="opt in (['before', 'after'] as const)"
              :key="opt"
              type="button"
              class="rounded-xl border px-3 py-2.5 text-sm font-bold transition"
              :class="
                addSide === opt
                  ? 'border-brand-400 bg-brand-400/15 text-brand-300'
                  : 'border-ink-700 bg-ink-950 text-slate-400 hover:border-ink-600'
              "
              @click="addSide = opt"
            >
              {{ opt === "before" ? "Above" : "Below" }}
              <span class="block text-[10px] font-bold uppercase tracking-wider opacity-70">
                place {{ sidePlace(opt) }}
              </span>
            </button>
          </div>
        </div>

        <label class="mt-4 block text-xs font-bold uppercase tracking-wider text-slate-500">Athlete code (optional)</label>
        <input
          v-model="addCode"
          autocapitalize="characters"
          maxlength="10"
          placeholder="AB12"
          class="mt-1 w-full rounded-xl border border-ink-700 bg-ink-950 px-4 py-2.5 font-display text-lg font-bold tracking-[0.25em] text-brand-300 focus:border-brand-400 focus:outline-none"
        />
        <label class="mt-3 block text-xs font-bold uppercase tracking-wider text-slate-500">
          Time
          <span class="normal-case font-normal text-slate-600">
            {{ addAnchor ? "(blank = halfway between the neighbours)" : "(blank = just after the last finisher)" }}
          </span>
        </label>
        <input
          v-model="addTime"
          placeholder="12:34.5"
          class="mt-1 w-full rounded-xl border border-ink-700 bg-ink-950 px-4 py-2.5 font-display text-lg font-bold tabular-nums text-slate-200 focus:border-brand-400 focus:outline-none"
        />
        <p v-if="addError" class="mt-2 text-sm text-amber-300">{{ addError }}</p>
        <div class="mt-4 flex gap-2">
          <button class="flex-1 rounded-xl bg-brand-400 px-4 py-2.5 text-sm font-black text-ink-950" @click="addRunner">Add</button>
          <button class="flex-1 rounded-xl bg-ink-800 px-4 py-2.5 text-sm font-bold text-slate-300 hover:bg-ink-700"           @click="closeAdd()">Cancel</button>
        </div>
      </div>
    </div>
  </main>
</template>
