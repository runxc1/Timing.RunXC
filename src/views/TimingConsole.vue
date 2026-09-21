<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref, watch } from "vue";
import { useRoute } from "vue-router";
import { useLiveQuery } from "../lib/liveQuery";
import {
  db,
  enqueueWrite,
  uuid,
  deviceId,
  type MirrorSlot,
  type MirrorAthlete,
} from "../lib/db";
import { makeClient } from "../lib/supabase";
import {
  addBackupTap,
  pullMeetRaces,
  pullRace,
  subscribeRace,
  queueFlush,
  pendingCount,
  parkedCount,
  discardParked,
} from "../lib/sync";
import { normalizeCode, isValidCode } from "../lib/codes";
import { formatClock } from "../lib/time";
import { computeTeamStandings, type ScorableRunner } from "../lib/scoring";
import { startCamera } from "../lib/scan";
import { useSession } from "../stores/session";

/**
 * Timer console — opened with the MEET timer code (/t/{timerCode}).
 *
 * The first device to press START on a division becomes its primary clock;
 * every other device times that division as backup. Both roles keep running
 * concurrently while the operator switches between divisions, so one person
 * can run the whole meet from a single phone.
 *
 * This console is stopwatch-only: SPLIT taps are what the timer does. Matching
 * athlete codes at the chute is the separate scanner console (/scan/...).
 */

const route = useRoute();
const session = useSession();
const timerCode = computed(() => normalizeCode(String(route.params.timerCode)));

interface ResolvedMeet {
  id: string;
  name: string;
  location: string | null;
  code: string;
}

const loadError = ref("");
const meet = ref<ResolvedMeet | null>(null);
const roles = ref<Record<string, "primary" | "backup">>({});
const selectedId = ref<string>("");

// --- division list (live mirror of every race row in the meet) ---
const allRaces = useLiveQuery(() => db.races.toArray(), []);
const divisions = computed(() =>
  allRaces.value
    .filter((r) => r.meet_id === meet.value?.id && r.status !== "draft")
    .sort((a, b) => (a.name ?? "").localeCompare(b.name ?? "")),
);

const raceId = computed(() => selectedId.value);
const race = useLiveQuery(
  () => db.races.get(raceId.value),
  null,
  () => raceId.value,
);
const slots = useLiveQuery<MirrorSlot[]>(
  () => db.finish_slots.where("race_id").equals(raceId.value).sortBy("seq"),
  [],
  () => raceId.value,
);
const athletes = useLiveQuery<MirrorAthlete[]>(
  () => db.athletes.where("race_id").equals(raceId.value).toArray(),
  [],
  () => raceId.value,
);
/** This device's own backup taps for the selected division. */
const pendingBackup = useLiveQuery(
  () => db.backup_taps.where("race_id").equals(raceId.value).toArray(),
  [],
  () => raceId.value,
);

const athleteById = computed(() => new Map(athletes.value.map((a) => [a.id, a])));
const athleteByCode = computed(() => {
  const m = new Map<string, MirrorAthlete>();
  // Placeholders (name is null) are matchable too — they were recorded at the
  // finish line and get their identity when the runner registers later.
  for (const a of athletes.value) if (a.code) m.set(a.code, a);
  return m;
});

const role = computed(() => roles.value[raceId.value] ?? null);
const isBackup = computed(() => role.value === "backup");
const running = computed(() => race.value?.status === "running");
const finalized = computed(() => race.value?.status === "finalized");
const t0 = computed(() => (race.value?.started_at ? Date.parse(race.value.started_at) : null));

// --- live clocks (every division ticks; the selected one shows large) ---
const now = ref(Date.now());
let clockTimer: number | undefined;
const elapsed = computed(() =>
  t0.value != null && !finalized.value ? now.value - t0.value : null,
);
function chipClock(r: { started_at?: string | null; status?: string }): number | null {
  if (!r.started_at || r.status === "finalized") return null;
  return now.value - Date.parse(r.started_at);
}
onMounted(() => {
  clockTimer = window.setInterval(() => (now.value = Date.now()), 100);
});
onUnmounted(() => window.clearInterval(clockTimer));

// --- resolve the timer code ---
onMounted(async () => {
  const client = makeClient();
  const { data, error } = await client.rpc("resolve_timer", {
    p_code: timerCode.value,
    p_device_id: deviceId(),
  });
  if (error || !data) {
    loadError.value =
      error?.message === "TIMER_CODE_INVALID"
        ? "That timer code is not valid for any meet. Ask the meet manager for the current one."
        : (error?.message ?? "Could not load the timer console.");
    return;
  }
  meet.value = data.meet as ResolvedMeet;
  const roleMap: Record<string, "primary" | "backup"> = {};
  for (const r of (data.my_roles ?? []) as { race_id: string; role: "primary" | "backup" }[]) {
    roleMap[r.race_id] = r.role;
  }
  roles.value = roleMap;
  await pullMeetRaces(meet.value.id);
  const races = (data.races ?? []) as { id: string }[];
  if (races.length === 0) {
    loadError.value = "No divisions have been opened yet — check back when the meet starts.";
    return;
  }
  selectDivision(races[0]!.id);
});

const unsubscribers = new Map<string, () => void>();
function selectDivision(id: string) {
  selectedId.value = id;
  void pullRace(id, timerCode.value);
  if (!unsubscribers.has(id) && meet.value) {
    unsubscribers.set(id, subscribeRace(id, timerCode.value, meet.value.id));
  }
  codeInput.value = "";
  matchError.value = "";
  pendingWalkOn.value = null;
  selectedSlotId.value = null;
}
onUnmounted(() => {
  for (const unsub of unsubscribers.values()) unsub();
  unsubscribers.clear();
});

// --- start (first device claims the clock; later devices become backup) ---
const starting = ref(false);
async function pressStart() {
  if (!race.value || starting.value) return;
  starting.value = true;
  const client = makeClient({ timerCode: timerCode.value });
  const { data, error } = await client.rpc("start_race", {
    p_race_id: race.value.id,
    p_device_id: deviceId(),
  });
  starting.value = false;
  if (error || !data) {
    loadError.value =
      error?.message ?? "Could not reach the server. Start needs a connection — try again.";
    return;
  }
  roles.value = { ...roles.value, [race.value.id]: data.role as "primary" | "backup" };
  // Optimistic mirror patch; realtime confirms with the authoritative row.
  await db.races.put({
    id: race.value.id,
    started_at: data.started_at ?? new Date().toISOString(),
    status: "running",
  });
  focusInput();
}

// --- finish taps (SPLIT) ---
// Local monotonic counter for the primary clock: slots.value can lag behind
// taps by a microtask, so never derive seq from it directly.
let seqCounter = 0;
watch(
  slots,
  (list) => {
    const max = list.reduce((m, s) => Math.max(m, s.seq ?? 0), 0);
    if (max > seqCounter) seqCounter = max;
  },
  { immediate: true },
);

async function tapSplit() {
  // A device that never pressed START/JOIN has no role and must not write.
  if (!race.value || t0.value == null || finalized.value || !role.value) return;
  const offset = Date.now() - t0.value;
  if (navigator.vibrate) navigator.vibrate(25);
  if (isBackup.value) {
    await addBackupTap(race.value.id, timerCode.value, offset);
    return;
  }
  const id = uuid();
  const seq = ++seqCounter;
  await enqueueWrite({
    timerCode: timerCode.value,
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
  focusInput();
}

// --- code matching (primary clock) ---
const codeInput = ref("");
const inputEl = ref<HTMLInputElement | null>(null);
const selectedSlotId = ref<string | null>(null);
const matchError = ref("");

function focusInput() {
  if (!isBackup.value) inputEl.value?.focus();
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
    matchError.value = "No open finish slot — press SPLIT first.";
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
 * code afterwards (join_meet keeps placeholders claimable) and the name,
 * school and grade flow into results and team scores.
 */
async function recordWalkOn() {
  const code = pendingWalkOn.value;
  if (!code || !race.value) return;
  const slot = targetSlot.value;
  if (!slot) {
    matchError.value = "No open finish slot — press SPLIT first.";
    return;
  }
  const athleteId = uuid();
  // Athlete first, slot second: the outbox replays in order and the slot
  // references this id.
  await enqueueWrite({
    timerCode: timerCode.value,
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
    timerCode: timerCode.value,
    table: "finish_slots",
    op: "update",
    rowId: slot.id,
    payload: { athlete_id: athleteId, status: "matched" },
    mirrorPatch: { athlete_id: athleteId, status: "matched" },
  });
  queueFlush();
}

async function setSlotStatus(slot: MirrorSlot, status: "dnf" | "open") {
  await enqueueWrite({
    timerCode: timerCode.value,
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
    timerCode: timerCode.value,
    table: "finish_slots",
    op: "delete",
    rowId: slot.id,
  });
  queueFlush();
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

// --- finalize (asks first: it closes the division) ---
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
      "Some finishes have not reached the server yet (offline, or a rejected timer code). " +
      "Resolve those first, then finalize.";
    return;
  }
  const client = makeClient({ timerCode: timerCode.value });
  const { error } = await client.rpc("finalize_race", { p_race_id: race.value.id });
  finalizing.value = false;
  showFinalize.value = false;
  if (error) {
    loadError.value = error.message;
    return;
  }
  await pullRace(race.value.id, timerCode.value);
}

// --- live team preview (primary clock only) ---
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

watch(running, (r) => {
  if (r) focusInput();
});

const sortedSlotsDesc = computed(() => [...slots.value].reverse());
const queuedBackupCount = computed(() => pendingBackup.value.filter((t) => !t.sent).length);
</script>

<template>
  <main class="mx-auto flex min-h-screen max-w-lg flex-col">
    <p v-if="loadError" class="m-4 rounded-xl bg-red-500/10 px-4 py-3 text-sm text-red-300">{{ loadError }}</p>
    <div v-else-if="!meet" class="m-6 text-sm text-slate-400">Loading meet…</div>

    <template v-else>
      <!-- Top bar -->
      <div class="flex items-center gap-3 border-b border-ink-800 bg-ink-900 px-4 py-2.5">
        <div class="min-w-0 flex-1">
          <p class="truncate text-sm font-bold">{{ meet.name }}</p>
          <p class="text-[10px] uppercase tracking-widest text-slate-500">
            timer · {{ (race?.status ?? "").replace("_", " ") }}
            <span v-if="role" :class="isBackup ? 'text-amber-300' : 'text-brand-300'">· {{ role }}</span>
            <span v-if="pendingCount > 0" class="text-amber-300">· {{ pendingCount }} queued</span>
          </p>
        </div>
        <RouterLink
          v-if="finalized && meet.code"
          :to="`/meet/${meet.code}`"
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

      <!-- Division tabs: every division, live clocks on running ones -->
      <nav class="flex gap-2 overflow-x-auto border-b border-ink-800 bg-ink-950 px-3 py-2">
        <button
          v-for="d in divisions"
          :key="d.id"
          class="shrink-0 rounded-xl border px-3 py-1.5 text-left"
          :class="d.id === raceId ? 'border-brand-400 bg-brand-400/10' : 'border-ink-700 bg-ink-900 hover:border-ink-600'"
          @click="selectDivision(d.id)"
        >
          <span class="block text-xs font-bold">{{ d.name }}</span>
          <span
            v-if="chipClock(d) != null"
            class="block font-display text-[11px] font-black tabular-nums text-brand-300"
          >{{ formatClock(chipClock(d)) }}</span>
          <span v-else class="block text-[10px] uppercase tracking-wider text-slate-500">
            {{ d.status === "finalized" ? "official" : "not started" }}
          </span>
        </button>
      </nav>

      <!-- Writes that could not be delivered -->
      <div
        v-if="parkedCount > 0"
        class="flex items-center gap-3 bg-red-500/15 px-4 py-2 text-xs text-red-200"
      >
        <span>{{ parkedCount }} change(s) could not be saved — check the timer code and connection.</span>
        <button class="ml-auto shrink-0 font-bold underline" @click="discardParked">Dismiss</button>
      </div>

      <template v-if="!race">
        <p class="m-6 text-sm text-slate-400">Pick a division above.</p>
      </template>
      <template v-else>
        <!-- Clock -->
        <div v-if="t0 != null" class="bg-ink-950 py-3 text-center">
          <span
            class="font-display text-5xl font-black tabular-nums tracking-tight"
            :class="[finalized ? 'text-slate-600' : isBackup ? 'text-amber-300' : 'text-brand-300']"
          >{{ formatClock(elapsed) }}</span>
          <p v-if="isBackup" class="mt-1 text-[10px] uppercase tracking-widest text-amber-200/70">
            backup clock — official times are set on the compare screen
          </p>
        </div>

        <!-- Not started, or running but this device has not claimed a role yet -->
        <div v-if="!finalized && (!running || !role)" class="flex flex-1 flex-col items-center justify-center gap-4 p-8">
          <p class="text-center text-sm text-slate-400">
            {{ running
              ? "This division is already timed. Join to record taps — you will be the backup clock unless you are first."
              : divisions.length > 1
              ? "Divisions can run at the same time — starting one never stops another clock."
              : "Everyone at the line? START captures the clock; every SPLIT tap is timed against it." }}
          </p>
          <button
            class="tap-button size-56 rounded-full bg-brand-400 text-3xl font-black text-ink-950 shadow-[0_0_60px_-10px] shadow-brand-400/50 transition hover:bg-brand-300"
            :disabled="starting"
            @click="pressStart"
          >
            {{ starting ? "…" : running ? "JOIN CLOCK" : "START" }}
          </button>
          <p class="text-center text-xs text-slate-500">
            First device to start becomes the primary clock; any other device times as backup.
          </p>
        </div>

        <!-- Running -->
        <div v-else class="flex flex-1 flex-col">
          <div v-if="!finalized" class="flex flex-col gap-3 p-4">
            <button
              class="tap-button w-full rounded-2xl py-10 text-4xl font-black tracking-widest text-white shadow-[0_0_50px_-12px] transition"
              :class="isBackup
                ? 'bg-amber-500 shadow-amber-500/60 hover:bg-amber-400'
                : 'bg-red-500 shadow-red-500/60 hover:bg-red-400'"
              @click="tapSplit"
            >
              SPLIT
            </button>

            <!-- Primary: match codes to finish slots -->
            <template v-if="!isBackup">
              <div class="flex gap-2">
                <input
                  ref="inputEl"
                  v-model="codeInput"
                  autocapitalize="characters"
                  autocomplete="off"
                  inputmode="text"
                  maxlength="7"
                  placeholder="Code → Enter"
                  class="min-w-0 flex-1 rounded-xl border border-ink-700 bg-ink-900 px-4 py-3.5 text-center font-display text-xl font-bold tracking-[0.25em] text-brand-300 placeholder:text-sm placeholder:font-sans placeholder:tracking-normal placeholder:text-ink-600 focus:border-brand-400 focus:outline-none"
                  @keyup.enter="submitCode()"
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
            </template>

            <!-- Backup: its own tap list, merged later by the manager -->
            <p v-else-if="queuedBackupCount > 0" class="text-xs text-amber-200/80">
              {{ queuedBackupCount }} backup tap(s) waiting to upload — keep this device online.
            </p>
            <p v-else class="text-xs text-slate-500">
              Backup taps are stored against your stopwatch. The meet manager compares them with the
              official clock and merges anything missing.
            </p>
          </div>

          <!-- Slot list (official) or backup tap list -->
          <div class="flex-1 overflow-y-auto px-4 pb-6">
            <div class="mb-2 flex items-center justify-between">
              <h2 class="text-xs font-black uppercase tracking-wider text-slate-500">
                <template v-if="isBackup">Your backup taps</template>
                <template v-else>Finish order ({{ slots.length }})</template>
              </h2>
              <button
                v-if="!isBackup"
                class="text-xs font-bold text-brand-300"
                @click="showTeams = !showTeams"
              >
                {{ showTeams ? "Show finishers" : "Team preview" }}
              </button>
            </div>

            <ol v-if="isBackup" class="flex flex-col gap-1.5">
              <li
                v-for="(t, i) in [...pendingBackup].sort((a, b) => b.captured_at - a.captured_at)"
                :key="t.id"
                class="flex items-center gap-3 rounded-xl border border-ink-800 bg-ink-900 px-3 py-2"
              >
                <span class="w-8 text-center font-display text-lg font-black tabular-nums text-slate-500">
                  {{ pendingBackup.length - i }}
                </span>
                <span class="font-display text-sm font-bold tabular-nums text-amber-200">
                  {{ formatClock(t.t0_offset_ms) }}
                </span>
                <span
                  class="ml-auto text-[10px] uppercase tracking-wider"
                  :class="t.sent ? 'text-slate-500' : 'text-amber-300'"
                >
                  {{ t.sent ? "uploaded" : "queued" }}
                </span>
              </li>
              <li v-if="pendingBackup.length === 0" class="text-sm text-slate-500">
                No taps yet — press SPLIT as runners come through.
              </li>
            </ol>

            <ol v-else-if="!showTeams" class="flex flex-col gap-1.5">
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
                  <button
                    v-if="session.meetAdminCode"
                    class="rounded px-2 py-1 text-xs font-bold text-red-400 hover:bg-red-500/10"
                    @click.stop="deleteSlot(s)"
                  >
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

    <!-- Finalize confirmation -->
    <div
      v-if="showFinalize"
      class="fixed inset-0 z-50 grid place-items-center bg-black/70 p-6"
      @click.self="showFinalize = false"
    >
      <div class="max-w-sm rounded-2xl border border-ink-700 bg-ink-900 p-6">
        <h3 class="font-display text-lg font-black">Finalize {{ race?.name }}?</h3>
        <p class="mt-2 text-sm text-slate-400">
          Are you sure? Places become official and this division closes. The meet manager can still
          adjust results, but timing here ends.
        </p>
        <div class="mt-4 flex gap-2">
          <button
            class="flex-1 rounded-xl bg-red-500 px-4 py-2.5 text-sm font-black text-white hover:bg-red-400"
            :disabled="finalizing"
            @click="finalize"
          >
            {{ finalizing ? "Finalizing…" : "Yes, finalize" }}
          </button>
          <button
            class="flex-1 rounded-xl bg-ink-800 px-4 py-2.5 text-sm font-bold text-slate-300 hover:bg-ink-700"
            @click="showFinalize = false"
          >
            Keep timing
          </button>
        </div>
      </div>
    </div>
  </main>
</template>
