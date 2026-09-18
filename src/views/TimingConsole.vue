<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref, watch } from "vue";
import { useRoute } from "vue-router";
import { useLiveQuery } from "../lib/liveQuery";
import { db, enqueueWrite, uuid, deviceId, type MirrorSlot, type MirrorAthlete } from "../lib/db";
import { makeClient, supabase } from "../lib/supabase";
import { pullRace, subscribeRace, queueFlush, pendingCount, parkedCount, discardParked } from "../lib/sync";
import { normalizeCode, isValidCode } from "../lib/codes";
import { formatClock } from "../lib/time";
import { computeTeamStandings, type ScorableRunner } from "../lib/scoring";
import { startCamera } from "../lib/scan";
import { useSession } from "../stores/session";

const route = useRoute();
const session = useSession();
const raceCode = computed(() => normalizeCode(String(route.params.raceCode)));

const loadError = ref("");
const race = useLiveQuery(
  () => db.races.where("race_code").equals(raceCode.value).first(),
  null,
  () => raceCode.value,
);
const slots = useLiveQuery<MirrorSlot[]>(
  () => db.finish_slots.where("race_id").equals(race.value?.id ?? "").sortBy("seq"),
  [],
  () => race.value?.id,
);
const athletes = useLiveQuery<MirrorAthlete[]>(
  () => db.athletes.where("race_id").equals(race.value?.id ?? "").toArray(),
  [],
  () => race.value?.id,
);

const athleteById = computed(() => new Map(athletes.value.map((a) => [a.id, a])));
const athleteByCode = computed(() => {
  const m = new Map<string, MirrorAthlete>();
  // Placeholders (name is null) are matchable too — they were recorded at the
  // finish line and get their identity when the runner registers later.
  for (const a of athletes.value) if (a.code) m.set(a.code, a);
  return m;
});

const running = computed(() => race.value?.status === "running");
const finalized = computed(() => race.value?.status === "finalized");
const t0 = computed(() => (race.value?.started_at ? Date.parse(race.value.started_at) : null));

// --- live clock ---
const now = ref(Date.now());
let clockTimer: number | undefined;
const elapsed = computed(() => (t0.value != null && !finalized.value ? now.value - t0.value : null));

onMounted(() => {
  clockTimer = window.setInterval(() => (now.value = Date.now()), 100);
});
onUnmounted(() => window.clearInterval(clockTimer));

// --- load race ---
onMounted(async () => {
  if (!isValidCode(raceCode.value)) {
    loadError.value = "Invalid race code.";
    return;
  }
  const { data, error } = await supabase
    .from("races")
    .select("id, race_code")
    .eq("race_code", raceCode.value)
    .maybeSingle();
  if (error || !data) {
    loadError.value = error?.message ?? "No race found with that code.";
    return;
  }
  session.rememberRace(data.id, raceCode.value);
  await pullRace(data.id, raceCode.value);
  subscribeRace(data.id, raceCode.value);
});

// --- start ---
const starting = ref(false);
async function startRace() {
  if (!race.value || starting.value) return;
  starting.value = true;
  // A second device pressing JOIN must never move the clock: keep the t0 that
  // every other device is already timing against.
  const started_at = race.value.started_at ?? new Date().toISOString();
  await enqueueWrite({
    raceCode: raceCode.value,
    table: "races",
    op: "update",
    rowId: race.value.id,
    payload: { started_at, status: "running", start_device_id: deviceId() },
    mirrorPatch: { started_at, status: "running" },
  });
  queueFlush();
  starting.value = false;
  codeInput.value = "";
  focusInput();
}

// --- finish taps ---
// Local monotonic counter: slots.value can lag behind taps by a microtask,
// so never derive seq from it directly. Raised whenever the mirror shows a
// higher seq (e.g. slots created by another device via realtime).
let seqCounter = 0;
watch(
  slots,
  (list) => {
    const max = list.reduce((m, s) => Math.max(m, s.seq ?? 0), 0);
    if (max > seqCounter) seqCounter = max;
  },
  { immediate: true },
);

async function tapFinish() {
  if (!race.value || t0.value == null || finalized.value) return;
  const id = uuid();
  const offset = Date.now() - t0.value;
  const seq = ++seqCounter;
  await enqueueWrite({
    raceCode: raceCode.value,
    table: "finish_slots",
    op: "insert",
    rowId: id,
    payload: {
      race_id: race.value.id,
      seq,
      t0_offset_ms: offset,
      device_id: deviceId(),
      status: "open",
    },
    mirrorPatch: {
      id,
      race_id: race.value.id,
      seq,
      t0_offset_ms: offset,
      device_id: deviceId(),
      status: "open",
      captured_at: new Date().toISOString(),
    },
  });
  queueFlush();
  if (navigator.vibrate) navigator.vibrate(25);
  focusInput();
}

// --- code matching ---
const codeInput = ref("");
const inputEl = ref<HTMLInputElement | null>(null);
const selectedSlotId = ref<string | null>(null);
const matchError = ref("");

function focusInput() {
  inputEl.value?.focus();
}

const openSlots = computed(() => slots.value.filter((s) => s.status === "open"));

/** Slot being assigned: explicit selection, else oldest open slot. */
const targetSlot = computed(
  () =>
    slots.value.find((s) => s.id === selectedSlotId.value && s.status === "open") ??
    openSlots.value[0] ??
    null,
);

/** Code entered that nobody registered with — offered as a walk-on finisher. */
const pendingWalkOn = ref<string | null>(null);

async function submitCode() {
  const code = normalizeCode(codeInput.value);
  matchError.value = "";
  pendingWalkOn.value = null;
  if (!code) return;
  if (!isValidCode(code)) {
    matchError.value = "Codes are 6 characters.";
    return;
  }
  const slot = targetSlot.value;
  if (!slot) {
    matchError.value = "No open finish slot — tap FINISH first.";
    return;
  }
  const athlete = athleteByCode.value.get(code);
  if (!athlete) {
    pendingWalkOn.value = code;
    return;
  }
  await assignSlot(slot, athlete.id);
  codeInput.value = "";
  selectedSlotId.value = null;
  focusInput();
}

/**
 * Record someone who raced without registering: create an unclaimed athlete
 * row for the code and match it to the slot. They can register with that same
 * code afterwards (join_race keeps placeholders claimable) and the name,
 * school and grade flow into results and team scores.
 */
async function recordWalkOn() {
  const code = pendingWalkOn.value;
  const slot = targetSlot.value;
  if (!code || !race.value) return;
  if (!slot) {
    matchError.value = "No open finish slot — tap FINISH first.";
    return;
  }
  const athleteId = uuid();
  // Athlete first, slot second: the outbox replays in order and the slot
  // references this id.
  await enqueueWrite({
    raceCode: raceCode.value,
    table: "athletes",
    op: "insert",
    rowId: athleteId,
    payload: { race_id: race.value.id, code, source: "placeholder" },
    mirrorPatch: { race_id: race.value.id, code, name: null, source: "placeholder" },
  });
  await assignSlot(slot, athleteId);
  pendingWalkOn.value = null;
  codeInput.value = "";
  selectedSlotId.value = null;
  focusInput();
}

function cancelWalkOn() {
  pendingWalkOn.value = null;
  codeInput.value = "";
  focusInput();
}

async function assignSlot(slot: MirrorSlot, athleteId: string) {
  await enqueueWrite({
    raceCode: raceCode.value,
    table: "finish_slots",
    op: "update",
    rowId: slot.id,
    payload: { athlete_id: athleteId, status: "matched" },
    mirrorPatch: { athlete_id: athleteId, status: "matched" },
  });
  queueFlush();
}

async function setSlotStatus(slot: MirrorSlot, status: "dq" | "dnf" | "open") {
  await enqueueWrite({
    raceCode: raceCode.value,
    table: "finish_slots",
    op: "update",
    rowId: slot.id,
    payload: { status, athlete_id: null },
    mirrorPatch: { status, athlete_id: null },
  });
  queueFlush();
}

async function deleteSlot(slot: MirrorSlot) {
  if (slot.status !== "open") return;
  const queued = await db.outbox.where("row_id").equals(slot.id).toArray();
  const notSentYet = queued.some((i) => i.table === "finish_slots" && i.op === "insert");
  if (notSentYet) {
    // The server never saw it — drop the queue entries and the mirror row.
    for (const it of queued) await db.outbox.delete(it.id);
    await db.finish_slots.delete(slot.id);
    return;
  }
  // Already on the server: queue a real delete so the slot cannot come back.
  await enqueueWrite({
    raceCode: raceCode.value,
    table: "finish_slots",
    op: "delete",
    rowId: slot.id,
  });
  queueFlush();
}

// --- admin: insert a finisher above/below another result ---
interface InsertTarget {
  slot: MirrorSlot | null;
  side: "before" | "after";
}
const insertTarget = ref<InsertTarget | null>(null);
const insertCode = ref("");
const insertError = ref("");
const inserting = ref(false);

/** Place the new runner would take. */
const insertPlace = computed(() => {
  const t = insertTarget.value;
  if (!t) return 0;
  if (!t.slot) return slots.value.reduce((m, s) => Math.max(m, s.seq ?? 0), 0) + 1;
  return (t.slot.seq ?? 0) + (t.side === "after" ? 1 : 0);
});

function setInsertSide(side: "before" | "after") {
  if (insertTarget.value) insertTarget.value = { ...insertTarget.value, side };
}

function openInsert(slot: MirrorSlot | null, side: "before" | "after") {
  insertTarget.value = { slot, side };
  insertCode.value = "";
  insertError.value = "";
}

async function insertRunner() {
  if (!race.value || !insertTarget.value || inserting.value) return;
  inserting.value = true;
  insertError.value = "";
  const code = normalizeCode(insertCode.value);
  const client = makeClient({ raceCode: raceCode.value });
  const { error } = await client.rpc("insert_slot_relative", {
    p_race_id: race.value.id,
    p_anchor_slot_id: insertTarget.value.slot?.id ?? null,
    p_side: insertTarget.value.side,
    p_code: code || null,
    p_device_id: deviceId(),
  });
  if (error) {
    insertError.value = error.message;
    inserting.value = false;
    return;
  }
  // Server renumbered seq (and places when finalized) — resync the mirror.
  await pullRace(race.value.id, raceCode.value);
  inserting.value = false;
  insertTarget.value = null;
}

// --- scanner overlay ---
const scanning = ref(false);
const videoEl = ref<HTMLVideoElement | null>(null);
let stopCam: (() => void) | null = null;

async function openScanner() {
  scanning.value = true;
  await new Promise((r) => setTimeout(r, 50));
  if (!videoEl.value) return;
  try {
    stopCam = await startCamera(videoEl.value, (found) => {
      const code = normalizeCode(found.text).slice(0, 6);
      if (!isValidCode(code)) return false;
      // Unknown codes fall through to the walk-on prompt.
      codeInput.value = code;
      void submitCode();
      void closeScanner();
      return true;
    });
  } catch {
    matchError.value = "Camera unavailable — type the code instead.";
    void closeScanner();
  }
}
async function closeScanner() {
  stopCam?.();
  stopCam = null;
  scanning.value = false;
}
onUnmounted(() => stopCam?.());

// --- finalize ---
const showFinalize = ref(false);
const finalizing = ref(false);
async function finalize() {
  if (!race.value || finalizing.value) return;
  finalizing.value = true;
  // Places are derived from server state, so every queued tap must land first.
  queueFlush();
  const deadline = Date.now() + 10_000;
  while (pendingCount.value > 0 && Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, 150));
  }
  if (pendingCount.value > 0 || parkedCount.value > 0) {
    finalizing.value = false;
    showFinalize.value = false;
    loadError.value =
      "Some finishes have not reached the server yet (offline, or a rejected race code). " +
      "Resolve those first, then finalize.";
    return;
  }
  const client = makeClient({ raceCode: raceCode.value });
  const { error } = await client.rpc("finalize_race", { p_race_id: race.value.id });
  finalizing.value = false;
  showFinalize.value = false;
  if (error) {
    loadError.value = error.message;
    return;
  }
  await pullRace(race.value.id, raceCode.value);
}

// --- live team preview ---
const standings = computed(() => {
  const matched = slots.value.filter((s) => s.status === "matched" && s.athlete_id);
  const runners: ScorableRunner[] = matched.map((s, i) => {
    const a = athleteById.value.get(s.athlete_id!)!;
    return {
      athlete_id: a.id,
      athlete_name: a.name ?? "?",
      school_id: a.school_id ?? null,
      school_name: null,
      grade: a.grade ?? null,
      offset_ms: s.t0_offset_ms ?? 0,
      place: i + 1,
    };
  });
  return computeTeamStandings(runners, {
    teamSize: race.value?.team_size ?? 5,
    tiebreakDepth: race.value?.tiebreak_depth ?? 6,
  });
});
const showTeams = ref(false);

// Keep input focused while running for rapid typing.
watch(running, (r) => {
  if (r) focusInput();
});

const sortedSlotsDesc = computed(() => [...slots.value].reverse());
</script>

<template>
  <main class="mx-auto flex min-h-screen max-w-lg flex-col">
    <p v-if="loadError" class="m-4 rounded-xl bg-red-500/10 px-4 py-3 text-sm text-red-300">{{ loadError }}</p>
    <div v-else-if="!race" class="m-6 text-sm text-slate-400">Loading race…</div>

    <template v-else>
      <!-- Top bar -->
      <div class="flex items-center gap-3 border-b border-ink-800 bg-ink-900 px-4 py-2.5">
        <RouterLink to="/m" class="text-xs font-bold text-slate-500 hover:text-slate-300">←</RouterLink>
        <div class="min-w-0 flex-1">
          <p class="truncate text-sm font-bold">{{ race.name }}</p>
          <p class="text-[10px] uppercase tracking-widest text-slate-500">
            {{ race.race_code }} · {{ (race.status ?? "").replace("_", " ") }}
            <span v-if="pendingCount > 0" class="text-amber-300">· {{ pendingCount }} queued</span>
          </p>
        </div>
        <RouterLink
          v-if="finalized"
          :to="`/r/${race.race_code}`"
          class="rounded-lg bg-brand-400 px-3 py-1.5 text-xs font-black text-ink-950"
        >Results</RouterLink>
        <button
          v-else-if="running"
          class="rounded-lg bg-ink-800 px-3 py-1.5 text-xs font-bold text-slate-300 hover:bg-ink-700"
          @click="showFinalize = true"
        >
          Finalize
        </button>
      </div>

      <!-- Writes that could not be delivered -->
      <div
        v-if="parkedCount > 0"
        class="flex items-center gap-3 bg-red-500/15 px-4 py-2 text-xs text-red-200"
      >
        <span>{{ parkedCount }} change(s) could not be saved — check the race code and connection.</span>
        <button class="ml-auto shrink-0 font-bold underline" @click="discardParked">Dismiss</button>
      </div>

      <!-- Clock -->
      <div v-if="t0 != null" class="bg-ink-950 py-3 text-center">
        <span
          class="font-display text-5xl font-black tabular-nums tracking-tight"
          :class="finalized ? 'text-slate-600' : 'text-brand-300'"
        >{{ formatClock(elapsed) }}</span>
      </div>

      <!-- Start -->
      <div v-if="!running && !finalized" class="flex flex-1 flex-col items-center justify-center gap-4 p-8">
        <p class="text-center text-sm text-slate-400">
          {{ slots.length > 0
            ? "Race in progress on another device — tap JOIN to follow along."
            : "Everyone at the line? Start captures the clock; every FINISH tap is timed against it." }}
        </p>
        <button
          v-if="slots.length === 0"
          class="tap-button size-56 rounded-full bg-brand-400 text-3xl font-black text-ink-950 shadow-[0_0_60px_-10px] shadow-brand-400/50 transition hover:bg-brand-300"
          :disabled="starting"
          @click="startRace"
        >
          START
        </button>
        <button
          v-else
          class="tap-button rounded-xl bg-brand-400 px-8 py-4 text-xl font-black text-ink-950"
          @click="startRace"
        >
          JOIN RACE
        </button>
      </div>

      <!-- Running -->
      <div v-else class="flex flex-1 flex-col">
        <div v-if="!finalized" class="flex flex-col gap-3 p-4">
          <button
            class="tap-button w-full rounded-2xl bg-red-500 py-10 text-4xl font-black tracking-widest text-white shadow-[0_0_50px_-12px] shadow-red-500/60 transition hover:bg-red-400"
            @click="tapFinish"
          >
            FINISH
          </button>

          <div class="flex gap-2">
            <input
              ref="inputEl"
              v-model="codeInput"
              :disabled="finalized"
              autocapitalize="characters"
              autocomplete="off"
              inputmode="text"
              maxlength="7"
              placeholder="Code → Enter"
              class="min-w-0 flex-1 rounded-xl border border-ink-700 bg-ink-900 px-4 py-3.5 text-center font-display text-xl font-bold tracking-[0.25em] text-brand-300 placeholder:text-sm placeholder:font-sans placeholder:tracking-normal placeholder:text-ink-600 focus:border-brand-400 focus:outline-none"
              @keyup.enter="submitCode"
            />
            <button
              class="rounded-xl bg-ink-800 px-4 text-2xl hover:bg-ink-700"
              title="Scan QR"
              @click="openScanner"
            >
              ⌛
            </button>
          </div>
          <p v-if="matchError" class="text-sm text-amber-300">{{ matchError }}</p>
          <div
            v-else-if="pendingWalkOn"
            class="rounded-xl border border-amber-400/40 bg-amber-400/10 p-3"
          >
            <p class="text-sm text-amber-200">
              Nobody registered with code <span class="font-black">{{ pendingWalkOn }}</span>.
            </p>
            <p class="mt-1 text-xs text-amber-200/70">
              Record them as an unregistered finisher. They can register with that code later to add
              their name, school and grade.
            </p>
            <div class="mt-2 flex gap-2">
              <button
                class="rounded-lg bg-amber-400 px-3 py-1.5 text-xs font-black text-ink-950"
                @click="recordWalkOn"
              >
                Add as unregistered finisher
              </button>
              <button
                class="rounded-lg bg-ink-800 px-3 py-1.5 text-xs font-bold text-slate-300 hover:bg-ink-700"
                @click="cancelWalkOn"
              >
                Cancel
              </button>
            </div>
          </div>
          <p v-else-if="targetSlot" class="text-xs text-slate-500">
            Next code fills place {{ (targetSlot.seq ?? 0) }} —
            <span class="text-slate-300">{{ formatClock(targetSlot.t0_offset_ms) }}</span>
          </p>
        </div>

        <!-- Slot list -->
        <div class="flex-1 overflow-y-auto px-4 pb-6">
          <div class="mb-2 flex items-center justify-between">
            <h2 class="text-xs font-black uppercase tracking-wider text-slate-500">
              Finish order ({{ slots.length }})
            </h2>
            <div class="flex items-center gap-3">
              <button
                class="text-xs font-bold text-brand-300"
                title="Add a missed finisher at the end"
                @click="openInsert(null, 'after')"
              >
                + Add runner
              </button>
              <button class="text-xs font-bold text-brand-300" @click="showTeams = !showTeams">
                {{ showTeams ? "Show finishers" : "Team preview" }}
              </button>
            </div>
          </div>

          <ol v-if="!showTeams" class="flex flex-col gap-1.5">
            <li
              v-for="s in sortedSlotsDesc"
              :key="s.id"
              class="flex items-center gap-3 rounded-xl border px-3 py-2"
              :class="[
                s.id === selectedSlotId ? 'border-brand-400 bg-brand-400/10' : 'border-ink-800 bg-ink-900',
                s.status === 'dq' || s.status === 'dnf' ? 'opacity-50' : '',
              ]"
              @click="s.status === 'open' ? (selectedSlotId = s.id === selectedSlotId ? null : s.id) : undefined"
            >
              <span class="w-8 text-center font-display text-lg font-black tabular-nums text-slate-500">
                {{ s.seq }}
              </span>
              <span class="w-20 font-display text-sm font-bold tabular-nums text-slate-300">
                {{ formatClock(s.t0_offset_ms) }}
              </span>
              <span class="min-w-0 flex-1 truncate text-sm">
                <template v-if="s.status === 'matched' && s.athlete_id">
                  <span v-if="!athleteById.get(s.athlete_id)?.name" class="italic text-amber-300">
                    Unregistered
                  </span>
                  <template v-else>{{ athleteById.get(s.athlete_id)?.name }}</template>
                  <span class="text-xs text-slate-500">{{ athleteById.get(s.athlete_id)?.code }}</span>
                </template>
                <template v-else-if="s.status === 'open'">
                  <span class="italic text-slate-500">awaiting code…</span>
                </template>
                <template v-else>{{ (s.status ?? "").toUpperCase() }}</template>
              </span>
              <template v-if="s.status === 'open'">
                <button class="rounded px-2 py-1 text-xs font-bold text-slate-400 hover:bg-ink-700" @click.stop="setSlotStatus(s, 'dnf')">
                  DNF
                </button>
                <button class="rounded px-2 py-1 text-xs font-bold text-red-400 hover:bg-red-500/10" @click.stop="deleteSlot(s)">
                  ✕
                </button>
              </template>
              <button
                v-else-if="s.status === 'matched'"
                class="rounded px-2 py-1 text-xs font-bold text-slate-500 hover:bg-ink-700"
                title="Unmatch"
                @click.stop="setSlotStatus(s, 'open')"
              >
                ↺
              </button>
              <button
                class="rounded px-2 py-1 text-sm font-bold text-brand-300/70 hover:bg-ink-700"
                title="Insert a runner above or below this one"
                @click.stop="openInsert(s, 'before')"
              >
                +
              </button>
            </li>
          </ol>

          <!-- Team preview -->
          <table v-else class="w-full text-sm">
            <thead>
              <tr class="text-left text-xs uppercase tracking-wider text-slate-500">
                <th class="py-1">Team</th>
                <th class="py-1 text-right">Score</th>
                <th class="py-1 text-right">TB</th>
              </tr>
            </thead>
            <tbody>
              <tr v-for="t in standings" :key="t.school_id" class="border-t border-ink-800">
                <td class="py-1.5">
                  <span class="font-bold">{{ t.rank }}.</span> {{ t.school_name }}
                  <span class="text-xs text-slate-500">({{ t.runners.filter(r => r.scoring).map(r => r.place).join(", ") }})</span>
                </td>
                <td class="py-1.5 text-right font-display font-bold tabular-nums">{{ t.total }}</td>
                <td class="py-1.5 text-right tabular-nums text-slate-500">{{ t.tiebreak ?? "—" }}</td>
              </tr>
              <tr v-if="standings.length === 0">
                <td colspan="3" class="py-3 text-sm text-slate-500">Match some codes to see team scores.</td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </template>

    <!-- Scanner overlay -->
    <div v-if="scanning" class="fixed inset-0 z-50 flex flex-col bg-black">
      <video ref="videoEl" class="min-h-0 w-full flex-1 object-cover" muted playsinline />
      <button
        class="absolute left-1/2 top-4 -translate-x-1/2 rounded-full bg-black/60 px-5 py-2 text-sm font-bold text-white backdrop-blur"
        @click="closeScanner"
      >
        Close
      </button>
      <p class="py-3 text-center text-xs text-slate-400">Point at the runner's QR sticker</p>
    </div>

    <!-- Insert runner dialog -->
    <div
      v-if="insertTarget"
      class="fixed inset-0 z-50 grid place-items-center bg-black/70 p-6"
      @click.self="insertTarget = null"
    >
      <div class="max-w-sm rounded-2xl border border-ink-700 bg-ink-900 p-6">
        <h3 class="font-display text-lg font-black">Add runner at place {{ insertPlace }}</h3>
        <p class="mt-2 text-sm text-slate-400">
          For someone who finished but was missed. Their time is interpolated between the runners
          around them, and everyone behind moves back one place.
        </p>
        <div class="mt-4 flex overflow-hidden rounded-xl border border-ink-700 text-xs font-bold">
          <button
            class="flex-1 py-2"
            :class="insertTarget.side === 'before' ? 'bg-brand-400 text-ink-950' : 'text-slate-400 hover:bg-ink-800'"
            @click="setInsertSide('before')"
          >
            Above place {{ insertTarget.slot?.seq }}
          </button>
          <button
            class="flex-1 py-2"
            :class="insertTarget.side === 'after' ? 'bg-brand-400 text-ink-950' : 'text-slate-400 hover:bg-ink-800'"
            @click="setInsertSide('after')"
          >
            Below place {{ (insertTarget.slot?.seq ?? 0) + 1 }}
          </button>
        </div>
        <input
          v-model="insertCode"
          autocapitalize="characters"
          autocomplete="off"
          maxlength="7"
          placeholder="Runner code (optional)"
          class="mt-3 w-full rounded-xl border border-ink-700 bg-ink-950 px-4 py-3 text-center font-display text-lg font-bold tracking-[0.2em] text-brand-300 placeholder:font-sans placeholder:text-sm placeholder:tracking-normal placeholder:text-ink-600 focus:border-brand-400 focus:outline-none"
        />
        <p class="mt-1.5 text-xs text-slate-500">
          Leave blank to create an open slot, or type a new code to record an unregistered runner.
        </p>
        <p v-if="insertError" class="mt-2 text-xs text-red-300">{{ insertError }}</p>
        <div class="mt-5 flex gap-2">
          <button
            class="flex-1 rounded-xl bg-ink-800 py-2.5 text-sm font-bold hover:bg-ink-700"
            @click="insertTarget = null"
          >
            Cancel
          </button>
          <button
            class="flex-1 rounded-xl bg-brand-400 py-2.5 text-sm font-black text-ink-950 disabled:opacity-50"
            :disabled="inserting"
            @click="insertRunner"
          >
            {{ inserting ? "Adding…" : "Add runner" }}
          </button>
        </div>
      </div>
    </div>

    <!-- Finalize dialog -->
    <div v-if="showFinalize" class="fixed inset-0 z-50 grid place-items-center bg-black/70 p-6" @click.self="showFinalize = false">
      <div class="max-w-sm rounded-2xl border border-ink-700 bg-ink-900 p-6">
        <h3 class="font-display text-lg font-black">Finalize race?</h3>
        <p class="mt-2 text-sm text-slate-400">
          Places are locked in finish order and team scores are computed.
          {{ openSlots.length > 0 ? `${openSlots.length} unmatched slot(s) will not score.` : "" }}
        </p>
        <div class="mt-5 flex gap-2">
          <button class="flex-1 rounded-xl bg-ink-800 py-2.5 text-sm font-bold hover:bg-ink-700" @click="showFinalize = false">
            Cancel
          </button>
          <button
            class="flex-1 rounded-xl bg-brand-400 py-2.5 text-sm font-black text-ink-950 disabled:opacity-50"
            :disabled="finalizing"
            @click="finalize"
          >
            {{ finalizing ? "Finalizing…" : "Finalize" }}
          </button>
        </div>
      </div>
    </div>
  </main>
</template>
