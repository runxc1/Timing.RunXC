<script setup lang="ts">
import { computed, ref, watch } from "vue";
import { useRoute } from "vue-router";
import { makeClient } from "../lib/supabase";
import { useSession } from "../stores/session";
import { formatCode, genCode } from "../lib/codes";

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
} | null>(null);

/** Codes belong to the parent meet: /signup/{code} registers, /t/{timerCode} times. */
const meet = ref<{
  id: string;
  name: string;
  code: string | null;
  signup_code: string | null;
  timer_code: string | null;
  registration_locked_at: string | null;
} | null>(null);
const athletes = ref<
  Array<{ id: string; code: string; name: string | null; grade: string | null; school_id: string | null; source: string }>
>([]);
const schools = ref<Array<{ id: string; name: string }>>([]);
const error = ref("");
const saving = ref(false);
const savedFlash = ref(false);

const admin = computed(() => makeClient({ meetAdminCode: session.meetAdminCode || undefined }));
/** Athlete rows are inserted with the meet's signup credential (that's what RLS accepts). */
const signup = computed(() => makeClient({ signupCode: meet.value?.signup_code ?? undefined }));

async function load() {
  if (!session.meetAdminCode) return;
  const { data, error: err } = await admin.value
    .from("races")
    .select("id, meet_id, name, status, scheduled_start, team_size, tiebreak_depth")
    .eq("id", raceId.value)
    .maybeSingle();
  if (err) {
    error.value = err.message;
    return;
  }
  race.value = data as typeof race.value;
  if (!data) return;

  const m = await admin.value
    .from("meets")
    .select("id, name, code, signup_code, timer_code, registration_locked_at")
    .eq("id", race.value!.meet_id)
    .maybeSingle();
  if (m.error) error.value = m.error.message;
  meet.value = (m.data as typeof meet.value) ?? null;
  if (meet.value?.code) session.rememberMeet(meet.value.code);

  const [a, s] = await Promise.all([
    admin.value
      .from("athletes")
      .select("id, code, name, grade, school_id, source")
      .eq("race_id", raceId.value)
      .order("code"),
    admin.value.from("schools").select("id, name").order("name"),
  ]);
  athletes.value = (a.data ?? []) as typeof athletes.value;
  schools.value = (s.data ?? []) as typeof schools.value;
}

watch([raceId, () => session.meetAdminCode], load, { immediate: true });

const schoolName = (id: string | null) =>
  schools.value.find((s) => s.id === id)?.name ?? "—";

const registered = computed(() => athletes.value.filter((a) => a.name));
const pool = computed(() => athletes.value.filter((a) => !a.name));

async function save() {
  if (!race.value || saving.value) return;
  saving.value = true;
  const { error: err } = await admin.value
    .from("races")
    .update({
      name: race.value.name,
      team_size: race.value.team_size,
      tiebreak_depth: race.value.tiebreak_depth,
      scheduled_start: race.value.scheduled_start,
    })
    .eq("id", race.value.id);
  saving.value = false;
  if (err) error.value = err.message;
  else {
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
    const code = genCode();
    if (existing.has(code)) continue;
    existing.add(code);
    rows.push({ race_id: race.value.id, code, source: "import" });
  }
  const { error: err } = await signup.value.from("athletes").insert(rows);
  if (err) error.value = err.message;
  else await load();
  importing.value = false;
}

// --- share links -------------------------------------------------------------

const regUrl = computed(() =>
  meet.value?.code ? `${window.location.origin}/signup/${meet.value.code}` : "",
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

function scheduledLocal(v: string | null): string {
  if (!v) return "";
  const d = new Date(v);
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}
</script>

<template>
  <main class="mx-auto max-w-3xl px-5 py-8">
    <div v-if="!race" class="text-sm text-slate-400">Loading race…</div>
    <template v-else>
      <div class="flex items-start justify-between gap-4">
        <div>
          <RouterLink to="/m" class="text-xs font-bold text-slate-500 hover:text-slate-300">← Meet</RouterLink>
          <h1 class="mt-1 font-display text-2xl font-black tracking-tight">{{ race.name }}</h1>
          <p class="mt-1 text-sm text-slate-400">
            <template v-if="meet">{{ meet.name }} · </template>meet code
            <span class="font-bold text-brand-300">{{ meet?.code ? formatCode(meet.code) : "—" }}</span>
          </p>
        </div>
        <RouterLink
          :to="meet?.timer_code ? `/t/${meet.timer_code}` : '/m'"
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
          <input
            :value="race.scheduled_start ? scheduledLocal(race.scheduled_start) : ''"
            type="datetime-local"
            class="mt-1.5 w-full rounded-xl border border-ink-700 bg-ink-950 px-4 py-2.5 text-sm focus:border-brand-400 focus:outline-none"
            @input="race.scheduled_start = ($event.target as HTMLInputElement).value ? new Date(($event.target as HTMLInputElement).value).toISOString() : null"
          />
        </label>
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

      <!-- Status -->
      <section class="mt-4 flex flex-wrap items-center gap-2">
        <button
          v-if="race.status === 'draft'"
          class="rounded-xl bg-cyan-500/15 px-4 py-2 text-sm font-bold text-cyan-300 hover:bg-cyan-500/25"
          @click="setStatus('registration_open')"
        >
          Open registration
        </button>
        <button
          v-if="race.status === 'registration_open'"
          class="rounded-xl bg-brand-400/15 px-4 py-2 text-sm font-bold text-brand-300 hover:bg-brand-400/25"
          @click="setStatus('ready')"
        >
          Mark ready
        </button>
        <span
          v-if="meet?.registration_locked_at"
          class="rounded-full bg-violet-500/15 px-2.5 py-1 text-[10px] font-black uppercase tracking-wider text-violet-300"
        >
          Registration locked
        </span>
        <RouterLink
          v-if="canCompare"
          :to="`/m/races/${race.id}/compare`"
          class="ml-auto rounded-xl border border-ink-700 px-4 py-2 text-sm font-bold text-slate-200 hover:bg-ink-800"
        >
          Compare timings →
        </RouterLink>
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
          :to="`/m/races/${race.id}/stickers`"
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
        <h2 class="font-bold">Registered athletes <span class="text-slate-500">({{ registered.length }})</span></h2>
        <ul class="mt-3 divide-y divide-ink-800">
          <li v-for="a in registered" :key="a.id" class="flex items-center gap-3 py-2 text-sm">
            <span class="w-16 font-display font-bold tracking-wider text-brand-300">{{ a.code }}</span>
            <span class="flex-1 truncate">{{ a.name }}</span>
            <span class="text-slate-400">{{ schoolName(a.school_id) }}</span>
            <span class="w-8 text-right text-slate-500">{{ a.grade }}</span>
          </li>
          <li v-if="registered.length === 0" class="py-3 text-sm text-slate-500">
            No athletes yet — share the registration link above.
          </li>
        </ul>
      </section>
    </template>
  </main>
</template>
