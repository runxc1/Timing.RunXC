<script setup lang="ts">
import { computed, nextTick, onMounted, onUnmounted, ref, watch } from "vue";
import { useRoute } from "vue-router";
import { useLiveQuery } from "../lib/liveQuery";
import { db, type MirrorAthlete, type MirrorSlot } from "../lib/db";
import { makeClient } from "../lib/supabase";
import { pullMeetRaces, pullRace, subscribeRace } from "../lib/sync";
import { formatCode, normalizeCode, isValidCode } from "../lib/codes";
import { formatClock } from "../lib/time";
import { startCamera } from "../lib/scan";

/**
 * Scanner console — the finish-line chute crew's screen (/scan/{scannerCode}).
 *
 * The stopwatch timer only taps splits; here a dedicated crew member (or two)
 * scans or types each athlete code in the order runners come through the
 * chute. Positions are assigned server-side, so multiple scanners can work
 * the same division without ever colliding. A scan attaches the runner to the
 * timer's oldest open split when one exists; unknown codes are recorded as
 * unclaimed placeholders (keeping their true place) with a shortcut to open
 * registration for that exact code.
 */

const route = useRoute();
const scannerCode = computed(() => normalizeCode(String(route.params.scannerCode)));

interface ResolvedMeet {
  id: string;
  name: string;
  location: string | null;
  code: string;
}

const loadError = ref("");
const meet = ref<ResolvedMeet | null>(null);
const selectedId = ref<string>("");

// --- division list (live mirror of every race row in the meet) ---
const allRaces = useLiveQuery(() => db.races.toArray(), []);
const divisions = computed(() =>
  allRaces.value
    .filter((r) => r.meet_id === meet.value?.id && r.status !== "draft")
    .sort((a, b) => (a.name ?? "").localeCompare(b.name ?? "")),
);

const raceId = computed(() => selectedId.value);
const race = useLiveQuery(() => db.races.get(raceId.value), null, () => raceId.value);
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
const athleteById = computed(() => new Map(athletes.value.map((a) => [a.id, a])));

const running = computed(() => race.value?.status === "running");
const finalized = computed(() => race.value?.status === "finalized");
const t0 = computed(() => (race.value?.started_at ? Date.parse(race.value.started_at) : null));

// --- live clocks per division ---
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

// --- resolve the scanner code ---
onMounted(async () => {
  const client = makeClient();
  const { data, error } = await client.rpc("resolve_scanner", { p_code: scannerCode.value });
  if (error || !data) {
    loadError.value =
      error?.message === "SCANNER_CODE_INVALID"
        ? "That scanner code is not valid for any meet. Ask the meet manager for the current one."
        : (error?.message ?? "Could not load the scanner console.");
    return;
  }
  meet.value = data.meet as ResolvedMeet;
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
  void pullRace(id, "");
  if (!unsubscribers.has(id) && meet.value) {
    unsubscribers.set(id, subscribeRace(id, "", meet.value.id));
  }
  clearResult();
}
onUnmounted(() => {
  for (const unsub of unsubscribers.values()) unsub();
  unsubscribers.clear();
});

// --- scanning ---
interface ScanOutcome {
  kind: "matched" | "placeholder" | "already_in" | "error" | "undone";
  seq?: number;
  slotId?: string;
  code?: string;
  name?: string | null;
  school?: string | null;
  message?: string;
}
const outcome = ref<ScanOutcome | null>(null);
const scanningNow = ref(false);
const codeInput = ref("");
const inputEl = ref<HTMLInputElement | null>(null);

function focusInput() {
  if (running.value) inputEl.value?.focus();
}
watch(running, (r) => {
  if (r) void nextTick(focusInput);
});

async function doScan(raw: string) {
  const code = normalizeCode(raw);
  outcome.value = null;
  if (!code || scanningNow.value || !race.value) return;
  if (!isValidCode(code)) {
    outcome.value = { kind: "error", message: "Codes are 6 letters or digits — check the sticker." };
    return;
  }
  scanningNow.value = true;
  const client = makeClient();
  const { data, error } = await client.rpc("record_scan", {
    p_scanner_code: scannerCode.value,
    p_race_id: race.value.id,
    p_code: code,
  });
  scanningNow.value = false;
  if (error) {
    outcome.value = {
      kind: "error",
      message:
        error.message === "NOT_RUNNING"
          ? "This division is not being timed yet — the timer needs to press START first."
          : error.message === "FINALIZED"
            ? "This division is finalized."
            : "Could not reach the server. Check the connection and scan again.",
    };
    return;
  }
  const res = data as {
    status: string;
    seq: number;
    slot_id: string;
    code: string;
    athlete?: { name: string | null; school: string | null };
  };
  if (navigator.vibrate) navigator.vibrate(30);
  if (res.status === "already_in") {
    outcome.value = {
      kind: "already_in",
      seq: res.seq,
      code: res.code,
      message: `${formatCode(res.code)} is already in at #${res.seq}.`,
    };
  } else {
    outcome.value = {
      kind: res.status === "placeholder" ? "placeholder" : "matched",
      seq: res.seq,
      slotId: res.slot_id,
      code: res.code,
      name: res.athlete?.name ?? null,
      school: res.athlete?.school ?? null,
    };
  }
  codeInput.value = "";
  void nextTick(focusInput);
}

async function undoLast() {
  const last = outcome.value;
  if (!last?.slotId || scanningNow.value) return;
  scanningNow.value = true;
  const client = makeClient();
  const { error } = await client.rpc("undo_scan", {
    p_scanner_code: scannerCode.value,
    p_slot_id: last.slotId,
  });
  scanningNow.value = false;
  if (error) {
    outcome.value = { ...last, kind: "error", message: "Could not undo — check the connection." };
    return;
  }
  outcome.value = { kind: "undone", seq: last.seq, code: last.code };
}

/** Deep link into registration with this exact code pre-claimed. */
function openSignupFor(code: string) {
  if (!meet.value) return;
  window.open(`${window.location.origin}/meet/${meet.value.code}/signup?code=${code}`, "_blank");
}

function clearResult() {
  outcome.value = null;
  codeInput.value = "";
}

// --- camera overlay ---
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
      void doScan(code);
      void closeScanner();
      return true;
    });
  } catch {
    outcome.value = { kind: "error", message: "Camera unavailable — type the code instead." };
    void closeScanner();
  }
}
async function closeScanner() {
  stopCam?.();
  stopCam = null;
  scanning.value = false;
}
onUnmounted(() => stopCam?.());

// --- recent scans (newest first) ---
const recentSlots = computed(() =>
  [...slots.value]
    .filter((s) => s.status !== "dnf")
    .reverse()
    .slice(0, 12),
);
function slotName(s: MirrorSlot): string {
  const a = s.athlete_id ? athleteById.value.get(s.athlete_id) : undefined;
  return a?.name ?? "Unregistered";
}
</script>

<template>
  <div class="flex min-h-dvh flex-col bg-ink-950 text-slate-100">
    <!-- Error / not resolved -->
    <div v-if="loadError" class="flex flex-1 flex-col items-center justify-center gap-3 p-8 text-center">
      <p class="text-lg font-bold text-red-300">Scanner console</p>
      <p class="max-w-sm text-sm text-slate-400">{{ loadError }}</p>
      <router-link to="/" class="mt-2 text-sm font-bold text-brand-300">Back to start</router-link>
    </div>

    <template v-else-if="meet">
      <!-- Header -->
      <header class="flex items-center gap-3 border-b border-ink-800 px-4 py-3">
        <span class="text-lg">📷</span>
        <div class="min-w-0">
          <h1 class="truncate text-sm font-black uppercase tracking-wider">{{ meet.name }}</h1>
          <p class="text-[10px] uppercase tracking-widest text-slate-500">
            finish line scanner{{ meet.location ? ` · ${meet.location}` : "" }}
          </p>
        </div>
      </header>

      <!-- Divisions -->
      <nav class="flex gap-2 overflow-x-auto border-b border-ink-800 px-4 py-2">
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

      <!-- Clock -->
      <div v-if="t0 != null" class="bg-ink-950 py-2 text-center">
        <span
          class="font-display text-4xl font-black tabular-nums tracking-tight"
          :class="finalized ? 'text-slate-600' : 'text-brand-300'"
        >{{ formatClock(elapsed) }}</span>
      </div>

      <!-- Scan bar -->
      <div class="flex flex-col gap-3 p-4">
        <template v-if="running">
          <div class="flex gap-2">
            <input
              ref="inputEl"
              v-model="codeInput"
              autocapitalize="characters"
              autocomplete="off"
              inputmode="text"
              maxlength="7"
              placeholder="Scan / type code ↵"
              class="min-w-0 flex-1 rounded-xl border border-ink-700 bg-ink-900 px-4 py-4 text-center font-display text-2xl font-bold tracking-[0.3em] text-brand-300 placeholder:text-sm placeholder:font-sans placeholder:tracking-normal placeholder:text-ink-600 focus:border-brand-400 focus:outline-none"
              @keyup.enter="doScan(codeInput)"
            />
            <button
              class="rounded-xl bg-ink-800 px-4 text-2xl hover:bg-ink-700"
              title="Scan QR"
              @click="openScanner"
            >
              ⌛
            </button>
          </div>

          <!-- Outcome banner -->
          <div
            v-if="outcome"
            class="rounded-2xl border p-4 text-center"
            :class="{
              'border-emerald-400/50 bg-emerald-400/10': outcome.kind === 'matched',
              'border-amber-400/50 bg-amber-400/10': outcome.kind === 'placeholder',
              'border-red-400/50 bg-red-400/10': outcome.kind === 'already_in' || outcome.kind === 'error',
              'border-ink-700 bg-ink-900': outcome.kind === 'undone',
            }"
          >
            <template v-if="outcome.kind === 'matched'">
              <p class="font-display text-5xl font-black tabular-nums text-emerald-300">#{{ outcome.seq }}</p>
              <p class="mt-1 text-lg font-bold">{{ outcome.name || formatCode(outcome.code ?? "") }}</p>
              <p v-if="outcome.school" class="text-xs text-slate-400">{{ outcome.school }}</p>
            </template>
            <template v-else-if="outcome.kind === 'placeholder'">
              <p class="font-display text-5xl font-black tabular-nums text-amber-300">#{{ outcome.seq }}</p>
              <p class="mt-1 text-sm text-amber-200">
                <span class="font-mono font-black">{{ formatCode(outcome.code ?? "") }}</span>
                hasn't registered — their place is saved.
              </p>
              <button
                class="mt-3 w-full rounded-xl bg-amber-400 px-4 py-3 text-sm font-black text-ink-950"
                @click="openSignupFor(outcome.code ?? '')"
              >
                Register this runner now
              </button>
            </template>
            <template v-else-if="outcome.kind === 'already_in' || outcome.kind === 'error'">
              <p class="text-sm font-bold text-red-200">{{ outcome.message }}</p>
            </template>
            <template v-else>
              <p class="text-sm font-bold text-slate-300">Removed #{{ outcome.seq }} — scan again.</p>
            </template>
            <button
              v-if="outcome.slotId"
              class="mt-3 text-xs font-bold text-slate-400 underline"
              @click="undoLast"
            >
              Undo this scan
            </button>
          </div>
          <p v-else class="text-center text-xs text-slate-500">
            Scan stickers in the order runners come through the chute.
          </p>
        </template>
        <p v-else-if="finalized" class="text-sm text-slate-400">
          This division is finalized — results are official.
        </p>
        <p v-else class="text-sm text-slate-400">
          Waiting on the timer: press START on this division in the timer console, then scan here.
        </p>
      </div>

      <!-- Recent scans -->
      <div class="flex-1 overflow-y-auto px-4 pb-6">
        <h2 class="mb-2 text-xs font-black uppercase tracking-wider text-slate-500">
          Finish order ({{ slots.length }})
        </h2>
        <ol class="flex flex-col gap-1.5">
          <li
            v-for="s in recentSlots"
            :key="s.id"
            class="flex items-center gap-3 rounded-xl border border-ink-800 bg-ink-900 px-3 py-2"
          >
            <span class="w-8 text-center font-display text-lg font-black tabular-nums text-brand-300">
              {{ s.seq }}
            </span>
            <span class="min-w-0 flex-1">
              <span class="block truncate text-sm font-bold">{{ slotName(s) }}</span>
              <span v-if="s.athlete_id && athleteById.get(s.athlete_id)?.code" class="block font-mono text-[11px] text-slate-500">
                {{ formatCode(athleteById.get(s.athlete_id)!.code!) }}
              </span>
            </span>
            <span v-if="s.status === 'matched'" class="font-display text-sm tabular-nums text-slate-400">
              {{ formatClock(s.t0_offset_ms) }}
            </span>
            <span v-else class="text-[10px] uppercase tracking-wider text-slate-600">no time</span>
          </li>
        </ol>
      </div>

      <!-- Camera overlay -->
      <div v-if="scanning" class="fixed inset-0 z-50 flex flex-col bg-black/95">
        <video ref="videoEl" class="min-h-0 w-full flex-1 object-cover" playsinline muted />
        <div class="flex items-center justify-between p-4">
          <p class="text-xs text-slate-400">Point at the QR sticker</p>
          <button class="rounded-xl bg-ink-800 px-4 py-2 text-sm font-bold" @click="closeScanner">
            Close
          </button>
        </div>
      </div>
    </template>

    <div v-else class="flex flex-1 items-center justify-center text-sm text-slate-500">Loading…</div>
  </div>
</template>
