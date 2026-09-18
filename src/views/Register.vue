<script setup lang="ts">
import { computed, ref, watchEffect } from "vue";
import { useRoute } from "vue-router";
import QRCode from "qrcode";
import { supabase, makeClient } from "../lib/supabase";
import { isValidCode, normalizeCode, formatCode } from "../lib/codes";

const route = useRoute();
const raceCode = computed(() => normalizeCode(String(route.params.raceCode)));

const race = ref<{ id: string; name: string; status: string } | null>(null);
const schools = ref<Array<{ id: string; name: string }>>([]);
const loadError = ref("");

const name = ref("");
const schoolId = ref("");
const grade = ref("");
const code = ref("");
const hasCode = ref(false);
const busy = ref(false);
const error = ref("");
const done = ref<{ code: string; name: string } | null>(null);
const doneQr = ref("");

const GRADES = ["9", "10", "11", "12", "U8", "U10", "U12", "U14", "Masters"];

/** Registration is over, but a code recorded at the finish line stays claimable. */
const closed = computed(
  () => race.value?.status === "running" || race.value?.status === "finalized",
);
const claiming = computed(() => closed.value && hasCode.value);

watchEffect(async () => {
  race.value = null;
  loadError.value = "";
  if (!isValidCode(raceCode.value)) {
    loadError.value = "That race code doesn't look right.";
    return;
  }
  const { data, error: err } = await supabase
    .from("races")
    .select("id, name, status")
    .eq("race_code", raceCode.value)
    .maybeSingle();
  if (err) {
    loadError.value = err.message;
    return;
  }
  if (!data) {
    loadError.value = "No race found with that code.";
    return;
  }
  race.value = data as { id: string; name: string; status: string };
  const s = await supabase
    .from("schools")
    .select("id, name")
    .eq("meet_id", (await supabase.from("races").select("meet_id").eq("id", data.id).single()).data!.meet_id)
    .order("name");
  schools.value = (s.data ?? []) as typeof schools.value;
});

const errorMessages: Record<string, string> = {
  RACE_NOT_FOUND: "No race found with that code.",
  REGISTRATION_CLOSED: "Registration for this race is closed.",
  NAME_REQUIRED: "Please enter your name.",
  CODE_TAKEN: "That code is already claimed by another runner.",
  CODE_LENGTH: "Codes are exactly 6 characters.",
};

async function submit() {
  if (busy.value) return;
  busy.value = true;
  error.value = "";
  const client = makeClient({ raceCode: raceCode.value });
  const { data, error: err } = await client.rpc("join_race", {
    p_race_code: raceCode.value,
    p_name: name.value.trim(),
    p_school_id: schoolId.value || null,
    p_grade: grade.value || null,
    p_code: hasCode.value ? normalizeCode(code.value) : null,
  });
  busy.value = false;
  if (err) {
    const key = Object.keys(errorMessages).find((k) => err.message.includes(k));
    error.value = key ? errorMessages[key] : err.message;
    return;
  }
  const d = data as { code: string };
  done.value = { code: d.code, name: name.value.trim() };
  doneQr.value = await QRCode.toDataURL(d.code, { margin: 1, width: 240 });
}
</script>

<template>
  <main class="mx-auto flex min-h-screen max-w-md flex-col justify-center px-5 py-10">
    <!-- Success -->
    <div v-if="done" class="text-center">
      <div class="mx-auto grid size-14 place-items-center rounded-full bg-brand-400 text-3xl font-black text-ink-950">✓</div>
      <h1 class="mt-4 font-display text-2xl font-black">
        {{ claiming ? "Result claimed," : "You're in," }} {{ done.name }}!
      </h1>
      <p v-if="claiming" class="mt-2 text-sm text-slate-400">
        Your name, school and grade are now attached to this code in the results and team scores.
      </p>
      <p v-else class="mt-2 text-sm text-slate-400">
        This is your finish-line code. Screenshot it — you'll show it (or type it)
        when you cross the line.
      </p>
      <div class="mx-auto mt-6 w-64 rounded-2xl border border-ink-700 bg-white p-4">
        <img v-if="doneQr" :src="doneQr" alt="Your QR code" class="mx-auto size-48" />
        <p class="mt-2 text-center font-display text-3xl font-black tracking-[0.25em] text-black">
          {{ formatCode(done.code) }}
        </p>
      </div>
      <button
        class="mt-6 rounded-xl bg-ink-800 px-5 py-2.5 text-sm font-bold text-slate-200 hover:bg-ink-700"
        @click="done = null; name = ''; code = ''"
      >
        Register another runner
      </button>
    </div>

    <!-- Form -->
    <template v-else>
      <p v-if="loadError" class="rounded-xl bg-red-500/10 px-4 py-3 text-sm text-red-300">{{ loadError }}</p>
      <template v-else-if="race">
        <h1 class="font-display text-3xl font-black tracking-tight">
          <span class="text-brand-400">Enter</span> {{ race.name }}
        </h1>
        <p class="mt-1 text-sm text-slate-400">
          Race <span class="font-bold text-brand-300">{{ formatCode(raceCode) }}</span>
          <template v-if="race.status === 'draft'"> · registration opens soon</template>
          <template v-else-if="race.status === 'running' || race.status === 'finalized'"> · registration closed</template>
        </p>

        <div
          v-if="closed"
          class="mt-4 rounded-xl border border-amber-400/40 bg-amber-400/10 p-4 text-sm text-amber-200"
        >
          <template v-if="hasCode">
            Enter the code the finish line recorded for you to attach your name, school and grade
            to your result.
          </template>
          <template v-else>
            Registration is closed. If you finished with an unregistered code, tick the box below
            and enter it to claim your result.
          </template>
        </div>

        <form class="mt-6 flex flex-col gap-4" @submit.prevent="submit">
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

          <label class="block">
            <span class="text-xs font-bold uppercase tracking-wider text-slate-400">School</span>
            <select
              v-model="schoolId"
              :required="schools.length > 0"
              class="mt-1.5 w-full rounded-xl border border-ink-700 bg-ink-950 px-4 py-3 text-base focus:border-brand-400 focus:outline-none"
            >
              <option value="" disabled>Select your school…</option>
              <option v-for="s in schools" :key="s.id" :value="s.id">{{ s.name }}</option>
            </select>
          </label>

          <label class="block">
            <span class="text-xs font-bold uppercase tracking-wider text-slate-400">Grade</span>
            <select
              v-model="grade"
              class="mt-1.5 w-full rounded-xl border border-ink-700 bg-ink-950 px-4 py-3 text-base focus:border-brand-400 focus:outline-none"
            >
              <option value="" disabled>Select grade…</option>
              <option v-for="g in GRADES" :key="g" :value="g">{{ g }}</option>
            </select>
          </label>

          <div class="rounded-xl border border-ink-800 bg-ink-900 p-4">
            <label class="flex items-center gap-3 text-sm font-bold text-slate-200">
              <input v-model="hasCode" type="checkbox" class="accent-lime-400" />
              I already have a code (sticker or from my coach)
            </label>
            <input
              v-if="hasCode"
              v-model="code"
              autocapitalize="characters"
              autocomplete="off"
              maxlength="7"
              placeholder="234 567"
              class="mt-3 w-full rounded-xl border border-ink-700 bg-ink-950 px-4 py-3 text-center font-display text-2xl font-bold tracking-[0.3em] text-brand-300 placeholder:text-ink-700 focus:border-brand-400 focus:outline-none"
            />
            <p v-else class="mt-2 text-xs text-slate-500">
              No code? We'll assign you one when you register.
            </p>
          </div>

          <p v-if="error" class="rounded-lg bg-red-500/10 px-3 py-2 text-sm text-red-300">{{ error }}</p>

          <button
            type="submit"
            :disabled="busy || (closed && !hasCode)"
            class="rounded-xl bg-brand-400 py-4 text-lg font-black text-ink-950 transition hover:bg-brand-300 disabled:opacity-50"
          >
            {{ busy ? (claiming ? "Claiming…" : "Registering…") : claiming ? "Claim my result" : "Register" }}
          </button>
        </form>
      </template>
      <p v-else class="text-sm text-slate-400">Loading race…</p>
    </template>
  </main>
</template>
