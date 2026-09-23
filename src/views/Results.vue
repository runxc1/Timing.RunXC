<script setup lang="ts">
import { computed, onBeforeUnmount, ref, watch, watchEffect } from "vue";
import { useRoute } from "vue-router";
import { makeClient, supabase } from "../lib/supabase";
import { useSession } from "../stores/session";
import { formatCode, normalizeCode } from "../lib/codes";
import { formatClock } from "../lib/time";
import { computeIndividualResults } from "../lib/scoring";

interface Division {
  id: string;
  name: string;
  status: string;
  starts_at: string | null;
}

interface Meet {
  id: string;
  name: string;
  location: string | null;
  meet_date: string | null;
  registration_locked: boolean;
  divisions: Division[];
}

interface RaceDetail {
  id: string;
  name: string;
  status: string;
  team_size: number;
  tiebreak_depth: number;
  started_at: string | null;
  finalized_at: string | null;
}

interface AthleteRow {
  id: string;
  code: string;
  name: string | null;
  school_id: string | null;
  grade: string | null;
  gender: string | null;
}

interface SlotRow {
  id: string;
  seq: number;
  status: string;
  t0_offset_ms: number | null;
  athlete_id: string | null;
  place: number | null;
}

/** One row of get_team_standings(). */
interface StandingRow {
  school_id: string;
  school_name: string;
  score: number | null;
  tiebreak: number | null;
  finishers: number;
  rank: number;
}

const route = useRoute();
const session = useSession();
const meetCode = computed(() => normalizeCode(String(route.params.meetCode ?? "")));

/** Verified meet admin for THIS meet — only admins see unclaimed codes. */
const isAdmin = ref(false);
async function checkAdmin(meetId: string) {
  const code = session.meetAdminCode;
  if (!code) {
    isAdmin.value = false;
    return;
  }
  const c = makeClient({ meetAdminCode: code });
  const [own, delegated] = await Promise.all([
    c.from("meets").select("id").eq("id", meetId).eq("admin_code", code).maybeSingle(),
    c.from("meet_admins").select("meet_id").eq("meet_id", meetId).eq("code", code).maybeSingle(),
  ]);
  isAdmin.value = !!own.data || !!delegated.data;
}

/** Boys/girls split for mixed divisions. */
const genderFilter = ref<"ALL" | "M" | "F">("ALL");
const registerPath = computed(() => `/meet/${meetCode.value}/signup`);
const registerUrl = computed(() => `${window.location.origin}${registerPath.value}`);

const meet = ref<Meet | null>(null);
const loadError = ref("");
const divisionError = ref("");

const activeId = ref("");
const race = ref<RaceDetail | null>(null);
const athleteRows = ref<AthleteRow[]>([]);
const slotRows = ref<SlotRow[]>([]);
const standings = ref<StandingRow[]>([]);
const schoolNames = ref<Map<string, string>>(new Map());
const copied = ref(false);

/** A meet in progress keeps scoring itself; keep the page in step with it. */
const REFRESH_MS = 5000;
let timer: number | undefined;

async function loadMeet() {
  const code = meetCode.value;
  if (!code) {
    loadError.value = "This link is missing its meet code.";
    return;
  }
  const { data, error: err } = await supabase.rpc("get_meet", { p_code: code });
  if (err || !data) {
    meet.value = null;
    loadError.value = (err?.message ?? "").includes("MEET_NOT_FOUND") || !data
      ? "We couldn't find that meet. Check the link from your meet organizer."
      : "We couldn't load that meet right now. Check your connection.";
    return;
  }
  const m = data as Meet;
  meet.value = m;
  loadError.value = "";

  // Respect an open tab, otherwise land on the division in play.
  if (!m.divisions.some((d) => d.id === activeId.value)) {
    activeId.value =
      m.divisions.find((d) => d.status === "running")?.id ??
      m.divisions.find((d) => d.status === "finalized")?.id ??
      (m.divisions[0]?.id ?? "");
  }

  const s = await supabase.from("schools").select("id, name").eq("meet_id", m.id);
  schoolNames.value = new Map(
    ((s.data ?? []) as Array<{ id: string; name: string }>).map((x) => [x.id, x.name]),
  );
  void checkAdmin(m.id);
}

async function loadDivision(id: string) {
  divisionError.value = "";
  race.value = null;
  standings.value = [];
  athleteRows.value = [];
  slotRows.value = [];
  if (!id) return;

  const [r, a, sl] = await Promise.all([
    supabase
      .from("races")
      .select("id, name, status, team_size, tiebreak_depth, started_at, finalized_at")
      .eq("id", id)
      .maybeSingle(),
    supabase.from("athletes").select("id, code, name, school_id, grade, gender").eq("race_id", id),
    supabase
      .from("finish_slots")
      .select("id, seq, status, t0_offset_ms, athlete_id, place")
      .eq("race_id", id)
      .order("seq"),
  ]);
  if (!r.data) {
    divisionError.value = "This division isn't posted yet.";
    return;
  }
  race.value = r.data as RaceDetail;
  athleteRows.value = (a.data ?? []) as AthleteRow[];
  slotRows.value = (sl.data ?? []) as SlotRow[];

  if (race.value.status === "finalized") {
    const st = await supabase.rpc("get_team_standings", {
      p_race_id: id,
      p_gender: genderFilter.value === "ALL" ? null : genderFilter.value,
    });
    standings.value = (st.data ?? []) as unknown as StandingRow[];
  }
}

watch(genderFilter, () => void loadDivision(activeId.value));

watchEffect(loadMeet);
watch(activeId, (id) => void loadDivision(id));

async function refresh() {
  if (document.hidden) return;
  await loadMeet();
  await loadDivision(activeId.value);
}

function armTimer() {
  window.clearInterval(timer);
  const live = meet.value?.divisions.some((d) => d.status !== "finalized") ?? false;
  timer = live ? window.setInterval(() => void refresh(), REFRESH_MS) : undefined;
}

watch(() => meet.value?.divisions.map((d) => d.status).join(","), armTimer, { immediate: true });
onBeforeUnmount(() => window.clearInterval(timer));

const activeDivision = computed(
  () => meet.value?.divisions.find((d) => d.id === activeId.value) ?? null,
);

const athleteById = computed(() => new Map(athleteRows.value.map((a) => [a.id, a])));

const athletesMap = computed(() => {
  const m = new Map<
    string,
    { name: string; code: string; school_name: string | null; grade: string | null }
  >();
  for (const a of athleteRows.value) {
    m.set(a.id, {
      name: a.name?.trim() || "Unclaimed",
      code: a.code,
      school_name: a.school_id ? schoolNames.value.get(a.school_id) ?? null : null,
      grade: a.grade,
    });
  }
  return m;
});

const individual = computed(() =>
  computeIndividualResults(
    slotRows.value.map((s) => ({ ...s, athlete_id: s.athlete_id ?? null })),
    athletesMap.value,
  ),
);

const genderByCode = computed(() => new Map(athleteRows.value.map((a) => [a.code, a.gender])));

/** Boys/girls selection narrows the board; unlinked codes have no gender to match. */
const visibleIndividual = computed(() => {
  if (genderFilter.value === "ALL") return individual.value;
  const g = genderByCode.value;
  return individual.value.filter((r) => r.code && g.get(r.code) === genderFilter.value);
});

function genderLabel(code: string): string {
  const g = genderByCode.value.get(code);
  return g === "M" ? "B" : g === "F" ? "G" : "—";
}

/** Registrations that already carry a name; everything else is still a bare sticker code. */
const namedIds = computed(() => new Set(athleteRows.value.filter((a) => a.name).map((a) => a.id)));
const namedCodes = computed(() => new Set(athleteRows.value.filter((a) => a.name).map((a) => a.code)));

/** Finishers whose code nobody has claimed yet — they still need to register. */
const unclaimed = computed(() => {
  const named = namedIds.value;
  return slotRows.value.filter(
    (s) => s.status === "matched" && s.athlete_id && !named.has(s.athlete_id),
  );
});

const unclaimedNote = computed(() =>
  unclaimed.value.length === 1
    ? "One finisher still has an unclaimed code."
    : `${unclaimed.value.length} finishers still have unclaimed codes.`,
);

/** The actual pending codes — admins only, so they can hunt them down. */
const unclaimedCodes = computed(() =>
  unclaimed.value
    .map((s) => athleteById.value.get(s.athlete_id as string)?.code)
    .filter((c): c is string => !!c),
);

/** Runners per school in finish order, for the scoring detail under each team. */
const runnersBySchool = computed(() => {
  const out = new Map<
    string,
    Array<{ athlete_id: string; name: string; grade: string | null; place: number }>
  >();
  const matched = slotRows.value
    .filter((s) => s.status === "matched" && s.athlete_id)
    .slice()
    .sort((a, b) => (a.place ?? a.seq) - (b.place ?? b.seq));
  matched.forEach((s, i) => {
    const a = athleteById.value.get(s.athlete_id as string);
    if (!a?.name || !a.school_id) return;
    if (genderFilter.value !== "ALL" && a.gender !== genderFilter.value) return;
    const list = out.get(a.school_id) ?? [];
    list.push({ athlete_id: a.id, name: a.name, grade: a.grade, place: s.place ?? i + 1 });
    out.set(a.school_id, list);
  });
  return out;
});

function runnersFor(schoolId: string) {
  return runnersBySchool.value.get(schoolId) ?? [];
}

const meetDateLabel = computed(() => {
  const raw = meet.value?.meet_date;
  if (!raw) return "";
  const [y, mo, d] = String(raw).split("-").map(Number);
  if (!y || !mo || !d) return String(raw);
  return new Date(y, mo - 1, d).toLocaleDateString("en-US", {
    weekday: "short",
    month: "short",
    day: "numeric",
  });
});

function statusBadge(status: string): { label: string; cls: string } {
  if (status === "running") return { label: "Live", cls: "bg-amber-400/15 text-amber-300" };
  if (status === "finalized") return { label: "Final", cls: "bg-brand-400/15 text-brand-300" };
  return { label: "Ready", cls: "bg-sky-400/15 text-sky-300" };
}

function startedLabel(iso: string | null): string {
  if (!iso) return "";
  return new Date(iso).toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit" });
}

async function copyRegisterLink() {
  try {
    await navigator.clipboard.writeText(`${window.location.origin}${registerPath.value}`);
    copied.value = true;
    setTimeout(() => (copied.value = false), 2000);
  } catch {
    /* clipboard blocked — the link is on screen to select */
  }
}

function csvCell(v: string | number | null | undefined): string {
  const s = v == null ? "" : String(v);
  return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
}

function download(filename: string, rows: Array<Array<string | number | null>>) {
  const csv = rows.map((r) => r.map(csvCell).join(",")).join("\r\n");
  const url = URL.createObjectURL(new Blob([csv], { type: "text/csv;charset=utf-8" }));
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  a.click();
  URL.revokeObjectURL(url);
}

function slug(s: string): string {
  return s.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "") || "results";
}

function baseName(kind: string): string {
  return `${slug(meet.value?.name ?? "meet")}-${slug(race.value?.name ?? "division")}-${kind}.csv`;
}

function exportIndividual() {
  download(baseName("individual"), [
    ["Place", "Runner", "School", "Grade", "Code", "Time", "Status"],
    ...individual.value.map((r) => [
      r.place,
      r.athlete_name,
      r.school_name,
      r.grade,
      r.code,
      formatClock(r.offset_ms),
      r.status,
    ]),
  ]);
}

function exportStandings() {
  download(baseName("team"), [
    ["Rank", "School", "Score", "Tiebreak", "Finishers"],
    ...standings.value.map((t) => [t.rank, t.school_name, t.score, t.tiebreak, t.finishers]),
  ]);
}
</script>

<template>
  <main class="mx-auto max-w-3xl px-4 py-6">
    <p v-if="loadError" class="rounded-2xl border border-ink-800 bg-ink-900 px-4 py-4 text-sm text-slate-300">
      {{ loadError }}
      <RouterLink to="/" class="mt-3 block text-sm font-bold text-brand-300 hover:text-brand-400">
        ← Back to timing.runXC.run
      </RouterLink>
    </p>

    <div v-else-if="!meet" class="text-sm text-slate-400">Loading results…</div>

    <template v-else>
      <!-- Meet header -->
      <header class="flex flex-wrap items-end justify-between gap-3">
        <div>
          <p class="text-xs font-black uppercase tracking-[0.3em] text-brand-400">
            {{ activeDivision?.status === "finalized" ? "Official results" : "Live results" }}
          </p>
          <h1 class="mt-1 font-display text-2xl font-black leading-tight tracking-tight">
            {{ meet.name }}
          </h1>
          <p class="mt-0.5 text-xs text-slate-500">
            <span v-if="meet.location">{{ meet.location }}</span>
            <span v-if="meet.location && meetDateLabel"> · </span>
            <span>{{ meetDateLabel }}</span>
          </p>
        </div>

        <div class="flex items-center gap-2 print:hidden">
          <RouterLink
            :to="registerPath"
            class="rounded-xl border border-ink-700 px-3 py-2 text-xs font-bold text-slate-300 transition hover:border-brand-400/60 hover:text-brand-300"
          >
            Register a runner
          </RouterLink>
          <button
            class="rounded-xl bg-ink-800 px-3 py-2 text-xs font-bold text-slate-200 transition hover:bg-ink-700"
            @click="copyRegisterLink"
          >
            {{ copied ? "Link copied" : "Share link" }}
          </button>
        </div>
      </header>

      <p v-if="meet.divisions.length > 0" class="mt-2 truncate text-xs text-slate-600 print:hidden">
        Runners join at <span class="font-mono font-bold text-brand-300">{{ registerUrl }}</span>
      </p>

      <!-- Division tabs -->
      <nav
        v-if="meet.divisions.length > 0"
        role="tablist"
        aria-label="Divisions"
        class="-mx-4 mt-5 overflow-x-auto px-4 print:hidden"
      >
        <div class="flex min-w-max gap-2">
          <button
            v-for="d in meet.divisions"
            :key="d.id"
            role="tab"
            :aria-selected="d.id === activeId"
            class="flex items-center gap-2 rounded-xl border px-3.5 py-2 text-sm font-bold transition"
            :class="
              d.id === activeId
                ? 'border-brand-400/60 bg-brand-400/10 text-brand-300'
                : 'border-ink-800 bg-ink-900 text-slate-400 hover:text-slate-200'
            "
            @click="activeId = d.id"
          >
            {{ d.name }}
            <span
              class="rounded-full px-2 py-0.5 text-[10px] font-black uppercase tracking-wide"
              :class="statusBadge(d.status).cls"
            >
              {{ statusBadge(d.status).label }}
            </span>
          </button>
        </div>
      </nav>

      <p
        v-else
        class="mt-5 rounded-2xl border border-ink-800 bg-ink-900 p-5 text-sm text-slate-400"
      >
        No divisions have opened yet. Results appear here as each race is timed.
      </p>

      <!-- Selected division -->
      <section v-if="activeDivision" class="mt-6">
        <p v-if="divisionError" class="rounded-xl bg-red-500/10 px-4 py-3 text-sm text-red-300">
          {{ divisionError }}
        </p>

        <template v-else>
          <div class="flex flex-wrap items-center justify-between gap-3">
            <div>
              <h2 class="font-display text-xl font-black tracking-tight">{{ activeDivision.name }}</h2>
              <p class="text-xs text-slate-500">
                <span
                  class="mr-2 rounded-full px-2 py-0.5 text-[10px] font-black uppercase tracking-wide"
                  :class="statusBadge(activeDivision.status).cls"
                >
                  {{ statusBadge(activeDivision.status).label }}
                </span>
                <template v-if="startedLabel(race?.started_at ?? null)">
                  Started {{ startedLabel(race?.started_at ?? null) }}
                </template>
                <template v-else-if="activeDivision.starts_at">
                  Scheduled {{ startedLabel(activeDivision.starts_at) }}
                </template>
              </p>
            </div>

            <button
              v-if="individual.length > 0"
              class="rounded-xl border border-ink-700 px-3 py-2 text-xs font-bold text-slate-300 transition hover:bg-ink-800 print:hidden"
              @click="exportIndividual"
            >
              Export results CSV
            </button>
          </div>

          <!-- Boys / girls split (matters when a division mixes them) -->
          <div class="mt-4 flex gap-2 print:hidden">
            <button
              v-for="g in [
                { v: 'ALL', label: 'All runners' },
                { v: 'F', label: 'Girls' },
                { v: 'M', label: 'Boys' },
              ]"
              :key="g.v"
              class="rounded-full border px-3.5 py-1.5 text-xs font-bold transition"
              :class="
                genderFilter === g.v
                  ? 'border-brand-400/60 bg-brand-400/10 text-brand-300'
                  : 'border-ink-700 bg-ink-900 text-slate-400 hover:text-slate-200'
              "
              @click="genderFilter = g.v as typeof genderFilter"
            >
              {{ g.label }}
            </button>
          </div>

          <!-- Finish order -->
          <table class="mt-4 w-full text-sm">
            <thead>
              <tr class="text-left text-xs uppercase tracking-wider text-slate-500">
                <th class="py-2 pr-2">Pl</th>
                <th class="py-2 pr-2">Runner</th>
                <th class="py-2 pr-2">School</th>
                <th class="py-2 pr-2 text-center">Sx</th>
                <th class="py-2 pr-2 text-center">Gr</th>
                <th class="py-2 text-right">Time</th>
              </tr>
            </thead>
            <tbody>
              <tr v-for="(row, i) in visibleIndividual" :key="`${row.code}-${i}`" class="border-t border-ink-800/60">
                <td class="py-1.5 pr-2 font-display font-bold tabular-nums text-slate-400">
                  {{ row.place ?? "—" }}
                </td>
                <td class="py-1.5 pr-2">
                  {{ row.athlete_name }}
                  <span
                    v-if="row.status !== 'matched'"
                    class="ml-1 rounded bg-ink-800 px-1.5 py-0.5 text-[10px] font-bold uppercase text-slate-400"
                  >
                    {{ row.status }}
                  </span>
                  <span
                    v-else-if="!namedCodes.has(row.code)"
                    class="ml-1 rounded border border-amber-400/40 bg-amber-400/10 px-1.5 py-0.5 align-middle font-mono text-[10px] tracking-[0.08em] text-amber-200"
                    :title="isAdmin ? 'Finisher with no registration yet — they can register with this code.' : 'Finisher with no registration yet.'"
                  >{{ isAdmin ? formatCode(row.code) : "Unclaimed" }}</span>
                </td>
                <td class="py-1.5 pr-2 text-slate-400">{{ row.school_name ?? "—" }}</td>
                <td class="py-1.5 pr-2 text-center text-slate-400">{{ genderLabel(row.code) }}</td>
                <td class="py-1.5 pr-2 text-center tabular-nums text-slate-400">{{ row.grade ?? "—" }}</td>
                <td class="py-1.5 text-right font-display font-bold tabular-nums text-slate-200">
                  {{ formatClock(row.offset_ms) }}
                </td>
              </tr>
              <tr v-if="visibleIndividual.length === 0">
                <td colspan="6" class="py-4 text-slate-500">No finishers recorded yet.</td>
              </tr>
            </tbody>
          </table>

          <!-- Unclaimed codes -->
          <div
            v-if="unclaimed.length > 0"
            class="mt-4 rounded-2xl border border-amber-400/40 bg-amber-400/10 p-4 text-sm text-amber-100"
          >
            {{ unclaimedNote }}
            <RouterLink :to="registerPath" class="font-bold underline decoration-amber-300/60">
              Register with that code
            </RouterLink>
            to attach the runner's name and school.
            <div v-if="isAdmin && unclaimedCodes.length" class="mt-2 flex flex-wrap gap-1.5">
              <span
                v-for="c in unclaimedCodes"
                :key="c"
                class="rounded bg-ink-950/60 px-2 py-0.5 font-mono text-xs font-bold tracking-[0.15em] text-amber-200"
                >{{ formatCode(c) }}</span
              >
            </div>
          </div>

          <!-- Team standings -->
          <div v-if="activeDivision.status === 'finalized'" class="mt-8">
            <div class="flex flex-wrap items-center justify-between gap-2">
              <h3 class="font-display text-lg font-black tracking-tight">Team scores</h3>
              <button
                v-if="standings.length > 0"
                class="rounded-xl border border-ink-700 px-3 py-2 text-xs font-bold text-slate-300 transition hover:bg-ink-800 print:hidden"
                @click="exportStandings"
              >
                Export team CSV
              </button>
            </div>

            <div class="mt-3 flex flex-col gap-3">
              <div
                v-for="t in standings"
                :key="t.school_id"
                class="rounded-2xl border border-ink-800 bg-ink-900 p-4"
                :class="t.rank === 1 ? 'border-brand-400/60' : ''"
              >
                <div class="flex items-baseline justify-between gap-3">
                  <h4 class="font-display text-lg font-black">
                    <span
                      class="mr-2 inline-grid size-7 place-items-center rounded-full bg-ink-800 text-sm"
                      :class="t.rank === 1 ? 'bg-brand-400 text-ink-950' : ''"
                      >{{ t.rank }}</span
                    >
                    {{ t.school_name }}
                  </h4>
                  <p class="text-right">
                    <span class="font-display text-2xl font-black tabular-nums">{{ t.score ?? "—" }}</span>
                    <span v-if="t.tiebreak != null" class="ml-2 text-xs text-slate-500">
                      TB {{ t.tiebreak }}
                    </span>
                  </p>
                </div>
                <p class="mt-0.5 text-xs text-slate-500">{{ t.finishers }} finisher{{ t.finishers === 1 ? "" : "s" }}</p>
                <ol class="mt-2 flex flex-wrap gap-x-4 gap-y-1 text-sm">
                  <li
                    v-for="(r, idx) in runnersFor(t.school_id)"
                    :key="r.athlete_id"
                    :class="idx < (race?.team_size ?? 5) ? 'text-slate-200' : 'text-slate-500'"
                  >
                    <span class="font-bold tabular-nums">{{ r.place }}.</span> {{ r.name }}
                    <span v-if="r.grade" class="text-xs text-slate-600">({{ r.grade }})</span>
                  </li>
                </ol>
              </div>
              <p v-if="standings.length === 0" class="text-sm text-slate-500">No team scores yet.</p>
            </div>
          </div>
        </template>
      </section>

      <p class="mt-10 text-center text-xs text-slate-600 print:hidden">
        timing.runXC.run · results update live as the race is timed
      </p>
    </template>
  </main>
</template>
