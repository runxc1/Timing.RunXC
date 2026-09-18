<script setup lang="ts">
import { ref } from "vue";
import { useRouter } from "vue-router";
import { isValidCode, normalizeCode } from "../lib/codes";

const router = useRouter();
const code = ref("");

function go(target: "register" | "console" | "results") {
  const c = normalizeCode(code.value);
  if (!isValidCode(c)) return;
  const paths = { register: `/j/${c}`, console: `/t/${c}`, results: `/r/${c}` };
  router.push(paths[target]);
}
</script>

<template>
  <main class="mx-auto flex min-h-[calc(100vh-3.5rem)] max-w-md flex-col justify-center gap-8 px-5 py-10">
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
      <label class="text-xs font-bold uppercase tracking-wider text-slate-400" for="race-code">
        Race code
      </label>
      <input
        id="race-code"
        v-model="code"
        autocapitalize="characters"
        autocomplete="off"
        spellcheck="false"
        maxlength="7"
        placeholder="ABC123"
        class="mt-2 w-full rounded-xl border border-ink-700 bg-ink-950 px-4 py-3 text-center font-display text-2xl font-bold tracking-[0.3em] text-brand-300 placeholder:text-ink-700 focus:border-brand-400 focus:outline-none"
        @keyup.enter="go('register')"
      />
      <div class="mt-4 grid grid-cols-3 gap-2">
        <button
          class="rounded-xl bg-ink-800 py-3 text-sm font-bold text-slate-200 transition hover:bg-ink-700 disabled:opacity-40"
          :disabled="!isValidCode(code)"
          @click="go('register')"
        >
          Register
        </button>
        <button
          class="rounded-xl bg-brand-400 py-3 text-sm font-black text-ink-950 transition hover:bg-brand-300 disabled:opacity-40"
          :disabled="!isValidCode(code)"
          @click="go('console')"
        >
          Time race
        </button>
        <button
          class="rounded-xl bg-ink-800 py-3 text-sm font-bold text-slate-200 transition hover:bg-ink-700 disabled:opacity-40"
          :disabled="!isValidCode(code)"
          @click="go('results')"
        >
          Results
        </button>
      </div>
    </div>

    <div class="flex flex-col gap-2 text-center text-sm">
      <RouterLink to="/meets/new" class="font-bold text-brand-300 hover:underline">
        Set up a new meet →
      </RouterLink>
      <RouterLink to="/m" class="text-slate-400 hover:text-slate-200">
        Open my meet dashboard
      </RouterLink>
    </div>
  </main>
</template>
