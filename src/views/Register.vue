<script setup lang="ts">
import { computed, ref, watchEffect } from "vue";
import { useRoute } from "vue-router";
import QRCode from "qrcode";
import { supabase, makeClient } from "../lib/supabase";
import { normalizeCode, formatCode } from "../lib/codes";

interface Division {
  id: string;
  name: string;
  status: string;
  starts_at: string | null;
}

interface Meet {
  id: string;
  /** The meet's own public code (the URL may carry the signup code instead). */
  code: string;
  name: string;
  location: string | null;
  meet_date: string | null;
  registration_locked: boolean;
  signup_required: boolean;
  divisions: Division[];
}

const route = useRoute();
const meetCode = computed(() => normalizeCode(String(route.params.meetCode ?? "")));
/** Last signup code this device used for this meet. */
const storageKey = computed(() => `runxc-signup-${meetCode.value}`);

const meet = ref<Meet | null>(null);
const loadError = ref("");
const schools = ref<Array<{ id: string; name: string }>>([]);

const raceId = ref("");
const name = ref("");
const schoolId = ref("");
const grade = ref("");
const gender = ref<"" | "M" | "F">("");
const signupCode = ref("");
const athleteCode = ref("");

const busy = ref(false);
const error = ref("");
const done = ref<{ code: string; name: string; raceName: string } | null>(null);
const doneQr = ref("");
const copied = ref(false);

const GRADES = ["9", "10", "11", "12"];

/** Backend error codes -> human copy, shown inline next to the form. */
const ERROR_MESSAGES: Record<string, string> = {
  MEET_NOT_FOUND: "We couldn't find that meet. Check the link from your meet organizer.",
  SIGNUP_CODE_INVALID:
    "That signup code doesn't match this meet. It's printed on the meet flyer — ask your coach or the timing tent.",
  REGISTRATION_LOCKED:
    "This meet has been finalized, so registration is closed. Results are posted on the results page.",
  DIVISION_NOT_FOUND: "Pick the division you're racing in.",
  DIVISION_NOT_OPEN:
    "That division isn't open yet — it will appear on the timing tent screen when the race is up.",
  NAME_REQUIRED: "Please enter your name.",
  CODE_TAKEN:
    "That athlete code already belongs to another runner. Leave it blank and we'll assign you a new one.",
  CODE_LENGTH: "Athlete codes are exactly 6 characters — or leave it blank and we'll assign one.",
  SIGNUP_CODE_REQUIRED:
    "This meet needs a signup code. It's printed on the flyer — ask your coach or the timing tent.",
  GENDER_INVALID: "Pick Boys or Girls so we can score you in the right competition.",
};

function messageFor(raw: string | undefined, fallback: string): string {
  const msg = raw ?? "";
  const key = Object.keys(ERROR_MESSAGES).find((k) => msg.includes(k));
  return key ? ERROR_MESSAGES[key] : msg || fallback;
}

function readStoredSignupCode(): string {
  try {
    return localStorage.getItem(storageKey.value) ?? "";
  } catch {
    return "";
  }
}

function rememberSignupCode(code: string) {
  try {
    localStorage.setItem(storageKey.value, code);
  } catch {
    /* private mode / storage disabled — prefill is a nicety, not a requirement */
  }
}

watchEffect(async () => {
  const code = meetCode.value;
  meet.value = null;
  loadError.value = "";
  error.value = "";
  if (!code) {
    loadError.value = ERROR_MESSAGES.MEET_NOT_FOUND;
    return;
  }
  const { data, error: err } = await supabase.rpc("get_meet", { p_code: code });
  if (err) {
    loadError.value = messageFor(err.message, "We couldn't load that meet right now. Check your connection.");
    return;
  }
  const m = data as Meet | null;
  if (!m) {
    loadError.value = ERROR_MESSAGES.MEET_NOT_FOUND;
    return;
  }
  meet.value = m;
  // Keep the runner's pick when it survives a reload; otherwise land on a division
  // they can actually still join (in progress first, then one that hasn't started).
  if (!m.divisions.some((d) => d.id === raceId.value)) {
    raceId.value =
      m.divisions.find((d) => d.status === "running")?.id ??
      m.divisions.find((d) => d.status === "ready")?.id ??
      (m.divisions[0]?.id ?? "");
  }
  if (!signupCode.value) signupCode.value = readStoredSignupCode();

  const s = await supabase
    .from("schools")
    .select("id, name")
    .eq("meet_id", m.id)
    .order("name");
  schools.value = (s.data ?? []) as Array<{ id: string; name: string }>;
});

const selectedDivision = computed(
  () => meet.value?.divisions.find((d) => d.id === raceId.value) ?? null,
);

function divisionLabel(d: Division): string {
  if (d.status === "running") return `${d.name} — race in progress (you can still register)`;
  const when = startTimeLabel(d.starts_at);
  return when ? `${d.name} · ${when}` : d.name;
}

function startTimeLabel(iso: string | null): string {
  if (!iso) return "";
  return new Date(iso).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
}

const meetDateLabel = computed(() => {
  const raw = meet.value?.meet_date;
  if (!raw) return "";
  const [y, mo, d] = String(raw).split("-").map(Number);
  if (!y || !mo || !d) return String(raw);
  return new Date(y, mo - 1, d).toLocaleDateString([], {
    weekday: "short",
    month: "short",
    day: "numeric",
  });
});

/** Whether this meet insists on a signup code (default true for older meets). */
const codeRequired = computed(() => meet.value?.signup_required !== false);

async function submit() {
  if (busy.value) return;
  error.value = "";
  const code = normalizeCode(signupCode.value);
  const claimedCode = normalizeCode(athleteCode.value);
  if (!raceId.value) {
    error.value = ERROR_MESSAGES.DIVISION_NOT_FOUND;
    return;
  }
  if (!gender.value) {
    error.value = ERROR_MESSAGES.GENDER_INVALID;
    return;
  }
  if (codeRequired.value && !code) {
    error.value = ERROR_MESSAGES.SIGNUP_CODE_INVALID;
    return;
  }
  signupCode.value = code;

  busy.value = true;
  const client = makeClient(code ? { signupCode: code } : {});
  const { data, error: err } = await client.rpc("join_meet", {
    p_signup_code: code || null,
    p_meet_code: meet.value?.code ?? meetCode.value,
    p_race_id: raceId.value,
    p_name: name.value.trim(),
    p_school_id: schoolId.value || null,
    p_grade: grade.value || null,
    p_code: claimedCode || null,
    p_gender: gender.value,
  });
  busy.value = false;

  if (err) {
    error.value = messageFor(err.message, "Something went wrong. Try again.");
    return;
  }
  const d = data as { code: string; race_name: string };
  if (code) rememberSignupCode(code);
  doneQr.value = await QRCode.toDataURL(d.code, { margin: 1, width: 240 }).catch(() => "");
  done.value = { code: d.code, name: name.value.trim(), raceName: d.race_name };
}

function resetForNextRunner() {
  done.value = null;
  doneQr.value = "";
  copied.value = false;
  name.value = "";
  grade.value = "";
  gender.value = "";
  athleteCode.value = "";
}

async function copyCode() {
  if (!done.value) return;
  try {
    await navigator.clipboard.writeText(done.value.code);
    copied.value = true;
    setTimeout(() => (copied.value = false), 2000);
  } catch {
    /* clipboard blocked — the code is on screen anyway */
  }
}
</script>

<template>
  <main class="mx-auto flex min-h-screen max-w-md flex-col justify-center px-5 py-10">
    <!-- Success -->
    <div v-if="done" class="text-center">
      <div
        class="mx-auto grid size-14 place-items-center rounded-full bg-brand-400 text-3xl font-black text-ink-950"
      >
        ✓
      </div>
      <h1 class="mt-4 font-display text-2xl font-black">You're in, {{ done.name }}!</h1>
      <p class="mt-1 text-sm font-bold uppercase tracking-wider text-brand-300">{{ done.raceName }}</p>

      <div class="mt-6 rounded-2xl border border-ink-700 bg-ink-950 px-4 py-6">
        <p class="text-[11px] font-bold uppercase tracking-[0.2em] text-slate-500">Your athlete code</p>
        <p class="mt-2 font-mono text-5xl font-black tracking-widest text-brand-300">
          {{ formatCode(done.code) }}
        </p>
        <img v-if="doneQr" :src="doneQr" alt="Your QR code" class="mx-auto mt-4 size-40 rounded-lg" />
      </div>

      <p class="mt-4 text-sm font-semibold text-slate-300">Show this code at the finish line.</p>
      <p class="mt-1 text-xs text-slate-500">
        Screenshot it. The timer scans or types it as you cross — that's what puts your name in the results.
      </p>

      <div class="mt-6 flex flex-col gap-2">
        <button
          class="rounded-xl bg-brand-400 py-3 text-sm font-black text-ink-950 transition hover:bg-brand-300"
          @click="resetForNextRunner"
        >
          Register another runner
        </button>
        <button
          class="rounded-xl border border-ink-700 px-5 py-2.5 text-sm font-bold text-slate-300 transition hover:bg-ink-800"
          @click="copyCode"
        >
          {{ copied ? "Copied!" : "Copy code" }}
        </button>
      </div>
    </div>

    <!-- Load error -->
    <p v-else-if="loadError" class="rounded-2xl border border-ink-800 bg-ink-900 px-4 py-4 text-sm text-slate-300">
      {{ loadError }}
      <RouterLink to="/" class="mt-3 block text-sm font-bold text-brand-300 hover:text-brand-400">
        ← Back to timing.runXC.run
      </RouterLink>
    </p>

    <div v-else-if="!meet" class="text-sm text-slate-400">Loading meet…</div>

    <!-- Meet found -->
    <template v-else>
      <header>
        <p class="text-xs font-black uppercase tracking-[0.3em] text-brand-400">Athlete registration</p>
        <h1 class="mt-1 font-display text-3xl font-black leading-tight tracking-tight">{{ meet.name }}</h1>
        <p class="mt-1 text-sm text-slate-400">
          <span v-if="meet.location">{{ meet.location }}</span>
          <span v-if="meet.location && meetDateLabel"> · </span>
          <span>{{ meetDateLabel }}</span>
        </p>
      </header>

      <!-- Meet finalized -->
      <div
        v-if="meet.registration_locked"
        class="mt-6 rounded-2xl border border-amber-400/40 bg-amber-400/10 p-5"
      >
        <p class="font-display text-lg font-black text-amber-200">Registration is closed</p>
        <p class="mt-1 text-sm text-amber-100/80">
          This meet has been finalized, so no more runners can be added or claimed.
        </p>
        <RouterLink
          :to="`/meet/${meetCode}`"
          class="mt-4 inline-block rounded-xl bg-brand-400 px-5 py-2.5 text-sm font-black text-ink-950 transition hover:bg-brand-300"
        >
          See results
        </RouterLink>
      </div>

      <div
        v-else-if="meet.divisions.length === 0"
        class="mt-6 rounded-2xl border border-ink-800 bg-ink-900 p-5 text-sm text-slate-400"
      >
        No divisions are open yet. Check back at the meet — the timing tent posts the link as soon as the
        first division is ready.
      </div>

      <!-- Form -->
      <form v-else class="mt-6 flex flex-col gap-4" @submit.prevent="submit">
        <label class="block">
          <span class="text-xs font-bold uppercase tracking-wider text-slate-400">Division</span>
          <select
            v-model="raceId"
            required
            class="mt-1.5 w-full rounded-xl border border-ink-700 bg-ink-950 px-4 py-3 text-base focus:border-brand-400 focus:outline-none"
          >
            <option v-for="d in meet.divisions" :key="d.id" :value="d.id">{{ divisionLabel(d) }}</option>
          </select>
          <span
            v-if="selectedDivision?.status === 'running'"
            class="mt-1.5 block text-xs text-amber-300"
          >
            This race is being timed right now — register anyway, then show your code at the line.
          </span>
        </label>

        <label class="block">
          <span class="text-xs font-bold uppercase tracking-wider text-slate-400">Full name</span>
          <input
            v-model="name"
            required
            maxlength="120"
            autocomplete="name"
            placeholder="Jordan Alvarez"
            class="mt-1.5 w-full rounded-xl border border-ink-700 bg-ink-950 px-4 py-3 text-base focus:border-brand-400 focus:outline-none"
          />
        </label>

        <div>
          <span class="text-xs font-bold uppercase tracking-wider text-slate-400">Competing as</span>
          <div class="mt-1.5 grid grid-cols-2 gap-2">
            <button
              v-for="g in [
                { v: 'F', label: 'Girls' },
                { v: 'M', label: 'Boys' },
              ]"
              :key="g.v"
              type="button"
              class="rounded-xl border px-4 py-3 text-base font-bold transition"
              :class="
                gender === g.v
                  ? 'border-brand-400 bg-brand-400/15 text-brand-300'
                  : 'border-ink-700 bg-ink-950 text-slate-400 hover:border-ink-600'
              "
              @click="gender = g.v as 'M' | 'F'"
            >
              {{ g.label }}
            </button>
          </div>
        </div>

        <div class="grid grid-cols-[1fr_7.5rem] gap-3">
          <label class="block">
            <span class="text-xs font-bold uppercase tracking-wider text-slate-400">
              School <span class="normal-case text-slate-600">(optional)</span>
            </span>
            <select
              v-model="schoolId"
              class="mt-1.5 w-full rounded-xl border border-ink-700 bg-ink-950 px-4 py-3 text-base focus:border-brand-400 focus:outline-none"
            >
              <option value="">—</option>
              <option v-for="s in schools" :key="s.id" :value="s.id">{{ s.name }}</option>
            </select>
          </label>

          <label class="block">
            <span class="text-xs font-bold uppercase tracking-wider text-slate-400">
              Grade <span class="normal-case text-slate-600">(opt)</span>
            </span>
            <select
              v-model="grade"
              class="mt-1.5 w-full rounded-xl border border-ink-700 bg-ink-950 px-4 py-3 text-base focus:border-brand-400 focus:outline-none"
            >
              <option value="">—</option>
              <option v-for="g in GRADES" :key="g" :value="g">{{ g }}</option>
            </select>
          </label>
        </div>

        <label v-if="codeRequired" class="block">
          <span class="text-xs font-bold uppercase tracking-wider text-slate-400">Meet signup code</span>
          <input
            v-model="signupCode"
            required
            @blur="signupCode = normalizeCode(signupCode)"
            autocapitalize="characters"
            autocomplete="off"
            spellcheck="false"
            maxlength="10"
            placeholder="XXXXXX"
            class="mt-1.5 w-full rounded-xl border border-ink-700 bg-ink-950 px-4 py-3 font-mono text-lg font-bold uppercase tracking-[0.3em] text-brand-300 placeholder:text-ink-600 focus:border-brand-400 focus:outline-none"
          />
          <span class="mt-1.5 block text-xs text-slate-500">
            The code your meet organizer shares so only your runners can enter.
          </span>
        </label>

        <label class="block">
          <span class="text-xs font-bold uppercase tracking-wider text-slate-400">Athlete code</span>
          <input
            v-model="athleteCode"
            @blur="athleteCode = normalizeCode(athleteCode)"
            autocapitalize="characters"
            autocomplete="off"
            spellcheck="false"
            maxlength="7"
            placeholder="··· ···"
            class="mt-1.5 w-full rounded-xl border border-ink-700 bg-ink-950 px-4 py-3 text-center font-mono text-2xl font-bold uppercase tracking-[0.3em] text-brand-300 placeholder:text-ink-600 focus:border-brand-400 focus:outline-none"
          />
          <span class="mt-1.5 block text-xs text-slate-500">
            Leave blank to be assigned a new code. Type the code from your card or QR if you have one — that
            claims the finish already recorded for it.
          </span>
        </label>

        <p v-if="error" class="rounded-xl bg-red-500/10 px-4 py-3 text-sm text-red-300">{{ error }}</p>

        <button
          type="submit"
          :disabled="busy"
          class="rounded-xl bg-brand-400 py-4 text-lg font-black text-ink-950 transition hover:bg-brand-300 disabled:opacity-50"
        >
          {{ busy ? "Registering…" : "Register" }}
        </button>

        <p class="text-center text-xs text-slate-600">
          Live results:
          <RouterLink :to="`/meet/${meetCode}`" class="font-bold text-brand-300 hover:text-brand-400">
            /meet/{{ meetCode }}
          </RouterLink>
        </p>
      </form>
    </template>
  </main>
</template>
