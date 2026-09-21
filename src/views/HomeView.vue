<script setup lang="ts">
import { computed, ref } from "vue";
import { useRouter } from "vue-router";
import { normalizeCode } from "../lib/codes";
import { useSession } from "../stores/session";

const router = useRouter();
const session = useSession();

/** Same shape the server accepts: exactly six letters or digits. */
const SHAPE = /^[A-Z0-9]{6}$/;

const meetInput = ref("");
const timerInput = ref("");

const meetCode = computed(() => normalizeCode(meetInput.value));
const timerCode = computed(() => normalizeCode(timerInput.value));
const meetReady = computed(() => SHAPE.test(meetCode.value));
const timerReady = computed(() => SHAPE.test(timerCode.value));

/** The last meet this device administered or opened, for one-tap returns. */
const lastMeet = computed(() => session.lastMeetCode);

function go(path: string) {
  router.push(path);
}

function openRegister() {
  if (meetReady.value) go(`/meet/${meetCode.value}/signup`);
}
function openResults() {
  if (meetReady.value) go(`/meet/${meetCode.value}`);
}
function openTimer() {
  if (timerReady.value) go(`/t/${timerCode.value}`);
}

function useLastMeet(target: "register" | "results") {
  const c = normalizeCode(lastMeet.value ?? "");
  if (!SHAPE.test(c)) return;
  go(target === "register" ? `/meet/${c}/signup` : `/meet/${c}`);
}
</script>

<template>
  <main class="mx-auto flex min-h-[calc(100vh-3.5rem)] max-w-md flex-col justify-center gap-6 px-5 py-10">
    <div>
      <h1 class="font-display text-4xl font-black tracking-tight">
        <span class="text-brand-400">timing</span><span class="text-slate-500">.run</span>XC<span class="text-slate-500">.run</span>
      </h1>
      <p class="mt-2 text-sm text-slate-400">
        Cross-country timing from a phone at the finish line. No laptops, no
        cables, works when the cell signal doesn't.
      </p>
    </div>

    <div class="rounded-2xl border border-ink-800 bg-ink-900 p-5">
      <label class="text-xs font-bold uppercase tracking-wider text-slate-400" for="meet-code">
        Meet code
      </label>
      <input
        id="meet-code"
        v-model="meetInput"
        autocapitalize="characters"
        autocomplete="off"
        spellcheck="false"
        maxlength="7"
        placeholder="ABC123"
        class="mt-2 w-full rounded-xl border border-ink-700 bg-ink-950 px-4 py-3 text-center font-display text-2xl font-bold tracking-[0.3em] text-brand-300 placeholder:text-ink-700 focus:border-brand-400 focus:outline-none"
        @keyup.enter="openRegister"
      />
      <p class="mt-2 text-xs text-slate-500">
        Six letters or digits from the organizer. One code, two jobs: signing up and reading results.
      </p>
      <div class="mt-4 grid grid-cols-2 gap-2">
        <button
          class="rounded-xl bg-ink-800 py-3 text-sm font-bold text-slate-200 transition hover:bg-ink-700 disabled:opacity-40"
          :disabled="!meetReady"
          @click="openRegister"
        >
          Sign up
        </button>
        <button
          class="rounded-xl bg-ink-800 py-3 text-sm font-bold text-slate-200 transition hover:bg-ink-700 disabled:opacity-40"
          :disabled="!meetReady"
          @click="openResults"
        >
          Results
        </button>
      </div>
      <div
        v-if="lastMeet"
        class="mt-4 flex items-center justify-between gap-2 rounded-xl border border-ink-800 bg-ink-950 px-3 py-2"
      >
        <p class="min-w-0 truncate text-xs text-slate-500">
          Last meet
          <span class="font-display font-bold tracking-[0.2em] text-brand-300">{{ lastMeet }}</span>
        </p>
        <div class="flex shrink-0 gap-1.5">
          <button
            class="rounded-lg bg-ink-800 px-2.5 py-1 text-[11px] font-bold hover:bg-ink-700"
            @click="useLastMeet('register')"
          >
            Sign up
          </button>
          <button
            class="rounded-lg bg-ink-800 px-2.5 py-1 text-[11px] font-bold hover:bg-ink-700"
            @click="useLastMeet('results')"
          >
            Results
          </button>
        </div>
      </div>
    </div>

    <div class="rounded-2xl border border-ink-800 bg-ink-900 p-5">
      <label class="text-xs font-bold uppercase tracking-wider text-slate-400" for="timer-code">
        Timer code
      </label>
      <div class="mt-2 flex gap-2">
        <input
          id="timer-code"
          v-model="timerInput"
          autocapitalize="characters"
          autocomplete="off"
          spellcheck="false"
          maxlength="7"
          placeholder="XYZ789"
          class="w-full rounded-xl border border-ink-700 bg-ink-950 px-4 py-3 text-center font-display text-xl font-bold tracking-[0.3em] text-brand-300 placeholder:text-ink-700 focus:border-brand-400 focus:outline-none"
          @keyup.enter="openTimer"
        />
        <button
          class="shrink-0 rounded-xl bg-brand-400 px-5 text-sm font-black text-ink-950 transition hover:bg-brand-300 disabled:opacity-40"
          :disabled="!timerReady"
          @click="openTimer"
        >
          Time races
        </button>
      </div>
      <p class="mt-2 text-xs text-slate-500">
        For whoever holds a phone at the finish line — one timer code covers every race in the meet.
      </p>
    </div>

    <div class="flex flex-col gap-2 text-center text-sm">
      <RouterLink to="/meets/new" class="font-bold text-brand-300 hover:underline">
        Set up a new meet →
      </RouterLink>
      <RouterLink to="/admin" class="text-slate-400 hover:text-slate-200">
        Open my meet dashboard
      </RouterLink>
    </div>
  </main>
</template>
