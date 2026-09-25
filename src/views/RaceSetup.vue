<script setup lang="ts">
import { computed, ref, watch } from "vue";
import { useRoute } from "vue-router";
import { makeClient } from "../lib/supabase";
import { useSession } from "../stores/session";
import { formatCode, genAthleteCode, normalizeCode } from "../lib/codes";
import { isoToLocalInput, toIsoOrNull } from "../lib/time";
import { csvFilenamePart, downloadCsv } from "../lib/csv";
import DateTimeField from "../components/DateTimeField.vue";

const route = useRoute();
const session = useSession();
const raceId = computed(() => String(route.params.raceId));

const race = ref<{
  id: string;
  meet_id: string;
  name: string;
  status: string;
  scheduled_start: string | null;
  team_size: number;
  tiebreak_depth: number;
  registration_closed_at: string | null;
  allowed_grades: number[] | null;
} | null>(null);

/** Codes belong to the parent meet: /meet/{code}/signup registers, /t/{timerCode} times. */
const meet = ref<{
  id: string;
  name: string;
  code: string | null;
  signup_code: string | null;
  timer_code: string | null;
  registration_locked_at: string | null;
} | null>(null);
const athletes = ref<
  Array<{
    id: string;
    code: string;
    name: string | null;
    grade: string | null;
    gender: string | null;
    school_id: string | null;
    source: string;
  }>
>([]);
const schools = ref<Array<{ id: string; name: string }>>([]);
type Division = { id: string; name: string; status: string; allowed_grades: number[] };
const divisions = ref<Division[]>([]);
const error = ref("");
const saving = ref(false);
const savedFlash = ref(false);

const admin = computed(() => makeClient({ meetAdminCode: session.meetAdminCode || undefined }));
/** Athlete rows are inserted with the meet's signup credential (that's what RLS accepts). */
const signup = computed(() => makeClient({ signupCode: meet.value?.signup_code ?? undefined }));

async function load() {
  if (!session.meetAdminCode) return;
  error.value = "";
  const { data, error: err } = await admin.value
    .from("races")
    .select("id, meet_id, name, status, scheduled_start, team_size, tiebreak_depth, registration_closed_at, allowed_grades")
    .eq("id", raceId.value)
    .maybeSingle();
  if (err) {
    error.value = err.message;
    return;
  }
  race.value = data as typeof race.value;
  if (!data) return;
  if (!race.value?.allowed_grades?.length) race.value!.allowed_grades = [...DEFAULT_GRADES];

  const m = await admin.value
    .from("meets")
    .select("id, name, code, signup_code, timer_code, registration_locked_at")
    .eq("id", race.value!.meet_id)
    .maybeSingle();
  if (m.error) error.value = m.error.message;
  meet.value = (m.data as typeof meet.value) ?? null;
  if (meet.value?.code) session.rememberMeet(meet.value.code);

  const [a, s, d] = await Promise.all([
    admin.value
      .from("athletes")
      .select("id, code, name, grade, gender, school_id, source")
      .eq("race_id", raceId.value)
      .order("code"),
    // Only this meet's schools — otherwise the dropdown is every meet on the server.
    admin.value.from("schools").select("id, name").eq("meet_id", data.meet_id).order("name"),
    admin.value
      .from("races")
      .select("id, name, status, allowed_grades")
      .eq("meet_id", data.meet_id)
      .order("name"),
  ]);
  if (a.error || s.error || d.error) {
    error.value = a.error?.message ?? s.error?.message ?? d.error?.message ?? "Couldn't load this race.";
    return;
  }
  athletes.value = (a.data ?? []) as typeof athletes.value;
  schools.value = (s.data ?? []) as typeof schools.value;
  divisions.value = d.data ?? [];
}

watch([raceId, () => session.meetAdminCode], load, { immediate: true });

const schoolName = (id: string | null) =>
  schools.value.find((s) => s.id === id)?.name ?? "—";

const registered = computed(() => athletes.value.filter((a) => a.name));
const pool = computed(() => athletes.value.filter((a) => !a.name));

function exportRegistered() {
  if (!race.value || registered.value.length === 0) return;
  const filename = `${csvFilenamePart(meet.value?.name ?? "meet", "meet")}-${csvFilenamePart(race.value.name, "race")}-registered-athletes.csv`;
  downloadCsv(filename, [
    ["Athlete Code", "Name", "School", "Grade", "Gender"],
    ...registered.value.map((athlete) => [
      athlete.code,
      athlete.name,
      athlete.school_id ? schools.value.find((s) => s.id === athlete.school_id)?.name ?? "" : "",
      athlete.grade,
      athlete.gender,
    ]),
  ]);
}

/** Grades 1–16 are legal; a division picks which of them its registrants may use. */
const GRADE_RANGE = Array.from({ length: 16 }, (_, i) => i + 1);
const DEFAULT_GRADES = [9, 10, 11, 12];
const GRADE_PRESETS: Array<{ label: string; grades: number[] }> = [
  { label: "9–12 (varsity)", grades: DEFAULT_GRADES },
  { label: "1–8 (middle school)", grades: [1, 2, 3, 4, 5, 6, 7, 8] },
  { label: "K–12", grades: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12] },
  { label: "All 1–16", grades: GRADE_RANGE },
];

function gradeOn(grade: number) {
  return race.value?.allowed_grades?.includes(grade) ?? false;
}

function toggleGrade(grade: number) {
  if (!race.value) return;
  const current = race.value.allowed_grades ?? [];
  if (current.includes(grade)) {
    // The CHECK constraint needs at least one grade, so the last chip won't budge.
    if (current.length === 1) {
      error.value = "Keep at least one grade selected.";
      return;
    }
    race.value.allowed_grades = current.filter((g) => g !== grade);
  } else {
    race.value.allowed_grades = [...current, grade].sort((a, b) => a - b);
  }
  error.value = "";
}

function setGradePreset(grades: number[]) {
  if (!race.value) return;
  race.value.allowed_grades = [...grades].sort((a, b) => a - b);
  error.value = "";
}

const gradeSummary = computed(() => {
  const grades = [...(race.value?.allowed_grades ?? [])].sort((a, b) => a - b);
  return grades.length ? grades.join(", ") : "—";
});

async function save() {
  if (!race.value || saving.value) return;
  const currentRace = race.value;
  const savedGrades = [...(currentRace.allowed_grades ?? DEFAULT_GRADES)].sort((a, b) => a - b);
  saving.value = true;
  const { data, error: err } = await admin.value
    .from("races")
    .update({
      name: currentRace.name,
      team_size: currentRace.team_size,
      tiebreak_depth: currentRace.tiebreak_depth,
      scheduled_start: currentRace.scheduled_start,
      allowed_grades: savedGrades,
    })
    .eq("id", currentRace.id)
    .select("id");
  saving.value = false;
  if (err) error.value = err.message;
  else if (!data?.length) {
    // RLS silently skips rows this browser's admin code can't touch.
    error.value = "Nothing was saved — the admin code in this browser isn't for this meet. Re-enter it from the meet page.";
  } else {
    const division = divisions.value.find((d) => d.id === currentRace.id);
    if (division) division.allowed_grades = savedGrades;
    savedFlash.value = true;
    setTimeout(() => (savedFlash.value = false), 1500);
  }
}

async function setStatus(status: string) {
  if (!race.value) return;
  const { error: err } = await admin.value
    .from("races")
    .update({ status })
    .eq("id", race.value.id);
  if (err) error.value = err.message;
  else race.value.status = status;
}

/** Every division is open the moment it's created; this switch is per-division. */
const registrationOpen = computed(() => race.value?.registration_closed_at == null);
const switchingReg = ref(false);
async function setRegistration(open: boolean) {
  if (!race.value || switchingReg.value) return;
  switchingReg.value = true;
  error.value = "";
  const { data, error: err } = await admin.value.rpc("set_race_registration", {
    p_race_id: race.value.id,
    p_open: open,
  });
  switchingReg.value = false;
  if (err) {
    error.value = err.message;
    return;
  }
  race.value.registration_closed_at = open ? null : new Date().toISOString();
  const status = (data as { status?: string } | null)?.status;
  if (status) race.value.status = status;
}

const importCount = ref(10);
const importing = ref(false);
async function importPool() {
  if (!race.value || importing.value) return;
  if (meet.value?.registration_locked_at) {
    error.value = "Registration is locked for this meet, so new codes can't be created.";
    return;
  }
  importing.value = true;
  error.value = "";
  const rows: Array<{ race_id: string; code: string; source: string }> = [];
  const existing = new Set(athletes.value.map((a) => a.code));
  while (rows.length < importCount.value) {
    const code = genAthleteCode();
    if (existing.has(code)) continue;
    existing.add(code);
    rows.push({ race_id: race.value.id, code, source: "import" });
  }
  const { error: err } = await signup.value.from("athletes").insert(rows);
  if (err) error.value = err.message;
  else await load();
  importing.value = false;
}

// --- correcting a registration ----------------------------------------------

/** Runners mistype their name, pick the wrong school/grade/gender or copy a code badly. */
const edit = ref<{
  id: string;
  name: string;
  code: string;
  startCode: string;
  raceId: string;
  startRaceId: string;
  schoolId: string;
  grade: string;
  gender: "" | "M" | "F";
} | null>(null);
const editError = ref("");
const editBusy = ref(false);
const editNote = ref("");

const editDivision = computed(() => divisions.value.find((d) => d.id === edit.value?.raceId));
const gradeChoices = computed(() =>
  [...(editDivision.value?.allowed_grades ?? [])].sort((a, b) => a - b).map(String),
);
const gradeNotOffered = computed(
  () => !!edit.value?.grade && !!editDivision.value && !gradeChoices.value.includes(edit.value.grade),
);

const EDIT_ERRORS: Record<string, string> = {
  ATHLETE_NOT_FOUND: "That registration is gone — reload the page.",
  NOT_ALLOWED: "The admin code in this browser isn't for this meet, so nothing was changed.",
  DESTINATION_RACE_INVALID: "Choose another race from this meet.",
  RACE_CHANGED: "Another admin already moved this runner. Reload this page before editing again.",
  FINISH_ALREADY_RECORDED:
    "This runner already has a finish in the original race. Correct that finish before moving the registration.",
  NAME_REQUIRED: "Enter the runner's name.",
  CODE_INVALID: "Athlete codes use letters and numbers only.",
  CODE_LENGTH: "Athlete codes are up to 8 characters.",
  CODE_TAKEN: "Another runner in this meet already has that code.",
  GRADE_NOT_ALLOWED: "That grade isn't one this division offers — pick from the list.",
  GRADE_INVALID: "Grade should be a number like 8 or 11.",
  GENDER_INVALID: "Pick Boys or Girls.",
  SCHOOL_NOT_FOUND: "Pick one of this meet's schools.",
};

function editMessageFor(msg: string): string {
  const key = Object.keys(EDIT_ERRORS).find((k) => msg.includes(k));
  return key ? EDIT_ERRORS[key] : msg;
}

type RosterRow = typeof athletes.value[number];

function startEdit(a: RosterRow) {
  const currentRace = race.value;
  if (!currentRace || !divisions.value.some((d) => d.id === currentRace.id)) {
    error.value = "Couldn't load this meet's races. Reload the page before editing.";
    return;
  }
  edit.value = {
    id: a.id,
    name: a.name ?? "",
    code: a.code,
    startCode: a.code,
    raceId: currentRace.id,
    startRaceId: currentRace.id,
    schoolId: a.school_id ?? "",
    grade: a.grade ?? "",
    gender: (a.gender === "M" || a.gender === "F" ? a.gender : "") as "" | "M" | "F",
  };
  editError.value = "";
}

function closeEdit() {
  edit.value = null;
  editError.value = "";
}

async function saveEdit() {
  const form = edit.value;
  if (!form || editBusy.value) return;
  editError.value = "";
  if (!editDivision.value) {
    editError.value = EDIT_ERRORS.DESTINATION_RACE_INVALID;
    return;
  }
  if (gradeNotOffered.value) {
    editError.value = "Choose a grade offered by this race, or clear the grade using —.";
    return;
  }
  const code = normalizeCode(form.code);
  if (!form.name.trim()) {
    editError.value = EDIT_ERRORS.NAME_REQUIRED;
    return;
  }
  if (!code) {
    editError.value = "Every runner needs a code — that's what the finish line scans.";
    return;
  }
  if (code.length > 8) {
    editError.value = EDIT_ERRORS.CODE_LENGTH;
    return;
  }

  editBusy.value = true;
  const { data, error: err } = await admin.value.rpc("admin_update_athlete", {
    p_athlete_id: form.id,
    p_race_id: form.raceId,
    p_expected_race_id: form.startRaceId,
    p_name: form.name.trim(),
    p_school_id: form.schoolId || null,
    p_clear_school: !form.schoolId,
    p_grade: form.grade,
    p_gender: form.gender,
    p_code: code,
  });
  editBusy.value = false;
  if (err) {
    editError.value = editMessageFor(err.message);
    return;
  }

  const row = data as { finish_count: number; race_id: string; race_name: string } | null;
  if (!row?.race_id || !row.race_name) {
    editError.value = "Couldn't confirm the change. Reload the page before trying again.";
    return;
  }
  const moved = row.race_id !== form.startRaceId;
  const renamed = code !== form.startCode;
  const slots = row.finish_count;
  editNote.value =
    moved
      ? `Moved ${form.name.trim()} to ${row.race_name}.`
      : renamed && slots > 0
        ? `Saved. ${slots} finish ${slots === 1 ? "record now sits" : "records now sit"} under ${code}.`
        : "Saved.";
  edit.value = null;
  await load();
}

// --- share links -------------------------------------------------------------

const regUrl = computed(() =>
  meet.value?.code ? `${window.location.origin}/meet/${meet.value.code}/signup` : "",
);
const timerUrl = computed(() =>
  meet.value?.timer_code ? `${window.location.origin}/t/${meet.value.timer_code}` : "",
);
/** Only worth opening once two stopwatches can disagree. */
const canCompare = computed(
  () => race.value?.status === "running" || race.value?.status === "finalized",
);

const shareLinks = computed(() => [
  { key: "reg", kind: "Registration", url: regUrl.value },
  { key: "timer", kind: "Timer", url: timerUrl.value },
]);

const copiedKey = ref("");
function copyLink(text: string, key: string) {
  if (!text) return;
  navigator.clipboard.writeText(text);
  copiedKey.value = key;
  setTimeout(() => {
    if (copiedKey.value === key) copiedKey.value = "";
  }, 1500);
}

</script>

<template>
  <main class="mx-auto max-w-3xl px-5 py-8">
    <div v-if="!race" class="text-sm text-slate-400">Loading race…</div>
    <template v-else>
      <div class="flex items-start justify-between gap-4">
        <div>
          <RouterLink :to="meet?.code ? `/admin/${meet.code}` : '/admin'" class="text-xs font-bold text-slate-500 hover:text-slate-300">← Meet</RouterLink>
          <h1 class="mt-1 font-display text-2xl font-black tracking-tight">{{ race.name }}</h1>
          <p class="mt-1 text-sm text-slate-400">
            <template v-if="meet">{{ meet.name }} · </template>meet code
            <span class="font-bold text-brand-300">{{ meet?.code ? formatCode(meet.code) : "—" }}</span>
          </p>
        </div>
        <RouterLink
          :to="meet?.timer_code ? `/t/${meet.timer_code}` : '/admin'"
          class="shrink-0 rounded-xl bg-brand-400 px-4 py-2.5 text-sm font-black text-ink-950 hover:bg-brand-300"
        >
          Open console
        </RouterLink>
      </div>

      <p v-if="error" class="mt-4 rounded-lg bg-red-500/10 px-3 py-2 text-sm text-red-300">{{ error }}</p>

      <!-- Settings -->
      <section class="mt-6 grid gap-4 rounded-2xl border border-ink-800 bg-ink-900 p-5 sm:grid-cols-2">
        <label class="block sm:col-span-2">
          <span class="text-xs font-bold uppercase tracking-wider text-slate-400">Race name</span>
          <input v-model="race.name" class="mt-1.5 w-full rounded-xl border border-ink-700 bg-ink-950 px-4 py-2.5 text-sm focus:border-brand-400 focus:outline-none" />
        </label>
        <label class="block">
          <span class="text-xs font-bold uppercase tracking-wider text-slate-400">Scheduled start</span>
          <DateTimeField
            :model-value="isoToLocalInput(race.scheduled_start)"
            class="mt-1.5 flex w-full"
            input-class="min-w-[7.5rem] flex-1 rounded-xl border border-ink-700 bg-ink-950 px-4 py-2.5 text-sm focus:border-brand-400 focus:outline-none"
            @update:model-value="race.scheduled_start = toIsoOrNull($event)"
          />
        </label>

        <!-- Which grades this division offers at signup -->
        <div class="sm:col-span-2">
          <span class="text-xs font-bold uppercase tracking-wider text-slate-400">Grades accepted</span>
          <p class="mt-1 text-[11px] leading-snug text-slate-500">
            Grade choices offered on this division's signup page. Default is 9–12.
          </p>
          <div class="mt-2 flex flex-wrap gap-1.5">
            <button
              v-for="g in GRADE_RANGE"
              :key="g"
              type="button"
              class="h-9 w-9 rounded-lg border text-sm font-bold transition"
              :class="gradeOn(g)
                ? 'border-brand-400/60 bg-brand-400/20 text-brand-200'
                : 'border-ink-700 bg-ink-950 text-slate-500 hover:border-ink-600 hover:text-slate-300'"
              :aria-pressed="gradeOn(g)"
              @click="toggleGrade(g)"
            >
              {{ g }}
            </button>
          </div>
          <div class="mt-2 flex flex-wrap items-center gap-1.5">
            <button
              v-for="preset in GRADE_PRESETS"
              :key="preset.label"
              type="button"
              class="rounded-lg border border-ink-700 px-2.5 py-1 text-[11px] font-bold text-slate-400 hover:bg-ink-800 hover:text-slate-200"
              @click="setGradePreset(preset.grades)"
            >
              {{ preset.label }}
            </button>
            <span class="ml-1 text-[11px] text-slate-500">Offering: <span class="font-semibold text-slate-300">{{ gradeSummary }}</span></span>
          </div>
        </div>

        <div class="grid grid-cols-2 gap-3">
          <label class="block">
            <span class="text-xs font-bold uppercase tracking-wider text-slate-400">Scoring (top)</span>
            <input v-model.number="race.team_size" type="number" min="1" max="10" class="mt-1.5 w-full rounded-xl border border-ink-700 bg-ink-950 px-4 py-2.5 text-sm focus:border-brand-400 focus:outline-none" />
          </label>
          <label class="block">
            <span class="text-xs font-bold uppercase tracking-wider text-slate-400">Tiebreak thru</span>
            <input v-model.number="race.tiebreak_depth" type="number" min="1" max="12" class="mt-1.5 w-full rounded-xl border border-ink-700 bg-ink-950 px-4 py-2.5 text-sm focus:border-brand-400 focus:outline-none" />
          </label>
        </div>
        <div class="flex items-center gap-3 sm:col-span-2">
          <button
            class="rounded-xl bg-ink-800 px-5 py-2.5 text-sm font-bold hover:bg-ink-700 disabled:opacity-50"
            :disabled="saving"
            @click="save"
          >
            {{ saving ? "Saving…" : savedFlash ? "Saved ✓" : "Save" }}
          </button>
          <span class="text-xs text-slate-500">
            Standard XC: top {{ race.team_size }} score, {{ race.tiebreak_depth === 6 ? "6th" : `places ${race.team_size + 1}–${race.tiebreak_depth}` }} tiebreak
          </span>
        </div>
      </section>

      <!-- Registration for this division only -->
      <section class="mt-4 rounded-2xl border border-ink-800 bg-ink-900 p-5">
        <div class="flex items-start justify-between gap-3">
          <div class="min-w-0">
            <h2 class="font-bold">Registration</h2>
            <p class="mt-1 text-sm text-slate-400">
              <template v-if="registrationOpen">
                Open — runners can sign up for this division on the meet's signup page. New divisions
                start out open.
              </template>
              <template v-else>
                Closed for this division only. Runners can still register for every other division, and
                timing keeps working here.
              </template>
            </p>
          </div>
          <span
            class="shrink-0 rounded-full px-2.5 py-1 text-[10px] font-black uppercase tracking-wider"
            :class="registrationOpen ? 'bg-cyan-500/15 text-cyan-300' : 'bg-red-500/15 text-red-300'"
          >{{ registrationOpen ? "Open" : "Closed" }}</span>
        </div>

        <div class="mt-4 flex flex-wrap items-center gap-2">
          <button
            class="rounded-xl px-4 py-2 text-sm font-bold disabled:opacity-50"
            :class="registrationOpen
              ? 'bg-ink-800 text-slate-200 hover:bg-ink-700'
              : 'bg-cyan-500/15 text-cyan-300 hover:bg-cyan-500/25'"
            :disabled="switchingReg"
            @click="setRegistration(!registrationOpen)"
          >
            {{ switchingReg ? "Saving…" : registrationOpen ? "Close registration" : "Re-open registration" }}
          </button>
          <button
            v-if="race.status === 'registration_open'"
            class="rounded-xl bg-brand-400/15 px-4 py-2 text-sm font-bold text-brand-300 hover:bg-brand-400/25"
            @click="setStatus('ready')"
          >
            Mark ready
          </button>
          <span class="rounded-full bg-ink-800 px-2.5 py-1 text-[10px] font-black uppercase tracking-wider text-slate-400">
            {{ race.status.replace("_", " ") }}
          </span>
          <span
            v-if="meet?.registration_locked_at"
            class="rounded-full bg-violet-500/15 px-2.5 py-1 text-[10px] font-black uppercase tracking-wider text-violet-300"
          >
            Meet lock on
          </span>
          <RouterLink
            v-if="canCompare"
            :to="`/admin/races/${race.id}/compare`"
            class="ml-auto rounded-xl border border-ink-700 px-4 py-2 text-sm font-bold text-slate-200 hover:bg-ink-800"
          >
            Compare timings →
          </RouterLink>
        </div>
      </section>

      <!-- Sharing: every link is a meet-level link -->
      <section v-if="race.status !== 'draft'" class="mt-4 rounded-2xl border border-ink-800 bg-ink-900 p-5">
        <h2 class="font-bold">Share</h2>
        <p class="text-sm text-slate-400">
          Runners and timers both use meet-wide links — this division is picked on the next screen.
        </p>
        <div class="mt-3 flex flex-col gap-2">
          <div v-for="link in shareLinks" :key="link.key"
            class="flex items-center gap-2 rounded-xl border border-ink-800 bg-ink-950 px-3 py-2"
          >
            <span class="w-20 shrink-0 text-[10px] font-black uppercase tracking-wider text-slate-500">
              {{ link.kind }}
            </span>
            <input
              :value="link.url"
              readonly
              class="min-w-0 flex-1 bg-transparent text-xs text-slate-300 focus:outline-none"
              @focus="($event.target as HTMLInputElement).select()"
            />
            <button
              class="shrink-0 rounded-lg bg-ink-800 px-2.5 py-1 text-[11px] font-bold hover:bg-ink-700"
              @click="copyLink(link.url, link.key)"
            >
              {{ copiedKey === link.key ? "Copied ✓" : "Copy" }}
            </button>
          </div>
        </div>
      </section>

      <!-- Stickers -->
      <section class="mt-4 flex items-center justify-between rounded-2xl border border-ink-800 bg-ink-900 p-5">
        <div>
          <h2 class="font-bold">QR stickers</h2>
          <p class="text-sm text-slate-400">Print code + QR stickers for bibs or wristbands.</p>
        </div>
        <RouterLink
          :to="`/admin/races/${race.id}/stickers`"
          class="rounded-xl bg-ink-800 px-4 py-2 text-sm font-bold hover:bg-ink-700"
        >
          Print sheet →
        </RouterLink>
      </section>

      <!-- Pool codes -->
      <section class="mt-4 rounded-2xl border border-ink-800 bg-ink-900 p-5">
        <div class="flex items-center justify-between">
          <div>
            <h2 class="font-bold">Pre-assigned codes</h2>
            <p class="text-sm text-slate-400">
              {{ pool.length }} unused {{ pool.length === 1 ? "code" : "codes" }} available for walk-up registration.
            </p>
          </div>
          <div class="flex items-center gap-2">
            <input v-model.number="importCount" type="number" min="1" max="500" class="w-20 rounded-lg border border-ink-700 bg-ink-950 px-3 py-2 text-sm focus:border-brand-400 focus:outline-none" />
            <button
              class="rounded-lg bg-ink-800 px-3 py-2 text-sm font-bold hover:bg-ink-700 disabled:opacity-50"
              :disabled="importing"
              @click="importPool"
            >
              {{ importing ? "…" : "Generate" }}
            </button>
          </div>
        </div>
        <div v-if="pool.length" class="mt-3 flex flex-wrap gap-1.5">
          <span
            v-for="a in pool.slice(0, 60)"
            :key="a.id"
            class="rounded bg-ink-800 px-2 py-0.5 font-display text-xs font-bold tracking-wider text-slate-400"
          >{{ a.code }}</span>
          <span v-if="pool.length > 60" class="text-xs text-slate-500">+{{ pool.length - 60 }} more</span>
        </div>
      </section>

      <!-- Roster -->
      <section class="mt-4 rounded-2xl border border-ink-800 bg-ink-900 p-5">
        <div class="flex flex-wrap items-center justify-between gap-3">
          <h2 class="font-bold">Registered athletes <span class="text-slate-500">({{ registered.length }})</span></h2>
          <button
            type="button"
            class="rounded-xl border border-ink-700 px-3 py-2 text-xs font-bold text-slate-200 hover:bg-ink-800 disabled:cursor-not-allowed disabled:opacity-40"
            :disabled="registered.length === 0"
            @click="exportRegistered"
          >
            Export CSV
          </button>
        </div>
        <p v-if="editNote" class="mt-1 text-xs text-emerald-300">{{ editNote }}</p>
        <ul class="mt-3 divide-y divide-ink-800">
          <li v-for="a in registered" :key="a.id" class="flex items-center gap-3 py-2 text-sm">
            <span class="w-16 font-display font-bold tracking-wider text-brand-300">{{ a.code }}</span>
            <span class="flex-1 truncate">{{ a.name }}</span>
            <span class="text-slate-400">{{ schoolName(a.school_id) }}</span>
            <span class="w-8 text-right text-slate-500">{{ a.grade }}</span>
            <span v-if="a.gender" class="w-12 text-right text-[10px] font-black uppercase tracking-wider text-slate-500">
              {{ a.gender === "M" ? "Boys" : "Girls" }}
            </span>
            <button
              class="shrink-0 rounded-lg border border-ink-700 px-2.5 py-1 text-[11px] font-bold text-slate-300 hover:bg-ink-800"
              @click="startEdit(a)"
            >
              Edit
            </button>
          </li>
          <li v-if="registered.length === 0" class="py-3 text-sm text-slate-500">
            No athletes yet — share the registration link above.
          </li>
        </ul>
      </section>
      <!-- Correct a runner's own entry -->
      <div v-if="edit" class="fixed inset-0 z-50 grid place-items-center bg-ink-950/85 p-5 backdrop-blur-sm" role="dialog" aria-modal="true" @click.self="closeEdit()">
        <div class="w-full max-w-md rounded-2xl border border-ink-700 bg-ink-900 p-6">
          <div class="flex items-start justify-between gap-3">
            <h3 class="font-display text-lg font-black">Edit registration</h3>
            <button class="rounded px-2 py-1 text-sm font-bold text-slate-400 hover:bg-ink-700" @click="closeEdit()">×</button>
          </div>
          <p class="mt-1 text-sm text-slate-400">
            Fix a name, code, school, grade, gender or race. A recorded finish keeps
            the runner in their original race until that finish is corrected.
          </p>

          <label for="athlete-edit-race" class="mt-4 block text-xs font-bold uppercase tracking-wider text-slate-500">Race</label>
          <select
            id="athlete-edit-race"
            v-model="edit.raceId"
            class="mt-1 w-full rounded-xl border border-ink-700 bg-ink-950 px-4 py-2.5 text-sm focus:border-brand-400 focus:outline-none"
          >
            <option v-for="d in divisions" :key="d.id" :value="d.id">
              {{ d.name }} ({{ d.status.replace("_", " ") }})
            </option>
          </select>

          <label class="mt-4 block text-xs font-bold uppercase tracking-wider text-slate-500">Name</label>
          <input
            v-model="edit.name"
            class="mt-1 w-full rounded-xl border border-ink-700 bg-ink-950 px-4 py-2.5 text-sm focus:border-brand-400 focus:outline-none"
          />

          <label class="mt-3 block text-xs font-bold uppercase tracking-wider text-slate-500">Athlete code</label>
          <input
            v-model="edit.code"
            autocapitalize="characters"
            maxlength="8"
            class="mt-1 w-full rounded-xl border border-ink-700 bg-ink-950 px-4 py-2.5 font-display text-lg font-bold tracking-[0.25em] text-brand-300 focus:border-brand-400 focus:outline-none"
            @blur="edit.code = normalizeCode(edit.code)"
          />

          <label class="mt-3 block text-xs font-bold uppercase tracking-wider text-slate-500">School</label>
          <select v-model="edit.schoolId" class="mt-1 w-full rounded-xl border border-ink-700 bg-ink-950 px-4 py-2.5 text-sm focus:border-brand-400 focus:outline-none">
            <option value="">—</option>
            <option v-for="s in schools" :key="s.id" :value="s.id">{{ s.name }}</option>
          </select>

          <div class="mt-3 grid grid-cols-2 gap-3">
            <div>
              <label class="block text-xs font-bold uppercase tracking-wider text-slate-500">Grade</label>
              <select v-model="edit.grade" class="mt-1 w-full rounded-xl border border-ink-700 bg-ink-950 px-4 py-2.5 text-sm focus:border-brand-400 focus:outline-none">
                <option value="">—</option>
                <option v-if="gradeNotOffered" :value="edit.grade" disabled>
                  {{ edit.grade }} (not offered here)
                </option>
                <option v-for="g in gradeChoices" :key="g" :value="g">{{ g }}</option>
              </select>
              <p v-if="gradeNotOffered" class="mt-1 text-xs text-amber-300">
                Choose an offered grade or explicitly clear it.
              </p>
            </div>
            <div>
              <span class="block text-xs font-bold uppercase tracking-wider text-slate-500">Gender</span>
              <div class="mt-1 grid grid-cols-2 gap-2">
                <button
                  v-for="opt in ([['M', 'Boys'], ['F', 'Girls']] as const)"
                  :key="opt[0]"
                  type="button"
                  class="rounded-xl border px-3 py-2.5 text-sm font-bold transition"
                  :class="edit.gender === opt[0]
                    ? 'border-brand-400 bg-brand-400/15 text-brand-300'
                    : 'border-ink-700 bg-ink-950 text-slate-400 hover:border-ink-600'"
                  @click="edit.gender = edit.gender === opt[0] ? '' : opt[0]"
                >
                  {{ opt[1] }}
                </button>
              </div>
            </div>
          </div>

          <p v-if="editError" class="mt-3 text-sm text-amber-300">{{ editError }}</p>

          <div class="mt-5 flex gap-2">
            <button
              class="flex-1 rounded-xl bg-brand-400 px-4 py-2.5 text-sm font-black text-ink-950 disabled:opacity-50"
              :disabled="editBusy"
              @click="saveEdit"
            >
              {{ editBusy ? "Saving…" : "Save changes" }}
            </button>
            <button class="rounded-xl border border-ink-700 px-4 py-2.5 text-sm font-bold text-slate-300 hover:bg-ink-800" @click="closeEdit()">
              Cancel
            </button>
          </div>
        </div>
      </div>
    </template>
  </main>
</template>
