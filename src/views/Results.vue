<script setup lang="ts">
import { computed, ref, watchEffect } from "vue";
import { useRoute } from "vue-router";
import { supabase } from "../lib/supabase";
import { normalizeCode, isValidCode, formatCode } from "../lib/codes";
import { formatClock } from "../lib/time";
import {
  computeIndividualResults,
  computeTeamStandings,
  type ScorableRunner,
} from "../lib/scoring";

const route = useRoute();
const raceCode = computed(() => normalizeCode(String(route.params.raceCode)));

const race = ref<{
  id: string;
  name: string;
  status: string;
  team_size: number;
  tiebreak_depth: number;
  started_at: string | null;
  finalized_at: string | null;
} | null>(null);
const athleteRows = ref<
  Array<{ id: string; code: string; name: string | null; school_id: string | null; grade: string | null }>
>([]);
const schoolNames = ref<Map<string, string>>(new Map());
const slotRows = ref<
  Array<{ id: string; seq: number; status: string; t0_offset_ms: number | null; athlete_id: string | null; place: number | null }>
>([]);
const error = ref("");
const tab = ref<"individual" | "team">("team");

watchEffect(async () => {
  race.value = null;
  error.value = "";
  if (!isValidCode(raceCode.value)) {
    error.value = "Invalid race code.";
    return;
  }
  const { data: r } = await supabase
    .from("races")
    .select("id, name, status, team_size, tiebreak_depth, started_at, finalized_at")
    .eq("race_code", raceCode.value)
    .maybeSingle();
  if (!r) {
    error.value = "No race found with that code.";
    return;
  }
  race.value = r as {
    id: string;
    name: string;
    status: string;
    team_size: number;
    tiebreak_depth: number;
    started_at: string | null;
    finalized_at: string | null;
  };
  const [a, s, meet] = await Promise.all([
    supabase.from("athletes").select("id, code, name, school_id, grade").eq("race_id", r.id),
    supabase.from("finish_slots").select("id, seq, status, t0_offset_ms, athlete_id, place").eq("race_id", r.id),
    supabase.from("races").select("meet_id").eq("id", r.id).single(),
  ]);
  athleteRows.value = (a.data ?? []) as typeof athleteRows.value;
  slotRows.value = (s.data ?? []) as typeof slotRows.value;
  const sc = await supabase.from("schools").select("id, name").eq("meet_id", (meet.data as { meet_id: string }).meet_id);
  schoolNames.value = new Map(((sc.data ?? []) as Array<{ id: string; name: string }>).map((x) => [x.id, x.name]));
  if (race.value && race.value.status !== "finalized") tab.value = "individual";
});

const athletesMap = computed(() => {
  const m = new Map<
    string,
    { name: string; school_name: string | null; grade: string | null; code: string }
  >();
  for (const a of athleteRows.value) {
    if (!a.name) continue;
    m.set(a.id, {
      name: a.name,
      school_name: a.school_id ? schoolNames.value.get(a.school_id) ?? null : null,
      grade: a.grade,
      code: a.code,
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

const standings = computed(() => {
  const matched = slotRows.value
    .filter((s) => s.status === "matched" && s.athlete_id)
    .sort((a, b) => (a.place ?? a.seq) - (b.place ?? b.seq));
  const runners: ScorableRunner[] = matched.map((s, i) => {
    const a = athleteRows.value.find((x) => x.id === s.athlete_id);
    return {
      athlete_id: s.athlete_id!,
      athlete_name: a?.name ?? "?",
      school_id: a?.school_id ?? null,
      school_name: a?.school_id ? schoolNames.value.get(a.school_id) ?? null : null,
      grade: a?.grade ?? null,
      offset_ms: s.t0_offset_ms ?? 0,
      place: i + 1,
    };
  });
  return computeTeamStandings(runners, {
    teamSize: race.value?.team_size ?? 5,
    tiebreakDepth: race.value?.tiebreak_depth ?? 6,
  });
});
</script>

<template>
  <main class="mx-auto max-w-2xl px-5 py-8">
    <p v-if="error" class="rounded-xl bg-red-500/10 px-4 py-3 text-sm text-red-300">{{ error }}</p>
    <div v-else-if="!race" class="text-sm text-slate-400">Loading results…</div>

    <template v-else>
      <header class="text-center">
        <p class="text-xs font-black uppercase tracking-[0.3em] text-brand-400">
          {{ race.status === "finalized" ? "Official results" : "Live results" }}
        </p>
        <h1 class="mt-1 font-display text-3xl font-black tracking-tight">{{ race.name }}</h1>
        <p class="mt-1 text-sm text-slate-500">
          <span class="text-brand-300">{{ formatCode(raceCode) }}</span>
          <template v-if="race.started_at"> · {{ new Date(race.started_at).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' }) }}</template>
        </p>
      </header>

      <div class="mt-6 flex justify-center gap-1 rounded-xl bg-ink-900 p-1 print:hidden">
        <button
          class="flex-1 rounded-lg py-2 text-sm font-bold transition"
          :class="tab === 'team' ? 'bg-brand-400 text-ink-950' : 'text-slate-400 hover:text-slate-200'"
          @click="tab = 'team'"
        >
          Team scores
        </button>
        <button
          class="flex-1 rounded-lg py-2 text-sm font-bold transition"
          :class="tab === 'individual' ? 'bg-brand-400 text-ink-950' : 'text-slate-400 hover:text-slate-200'"
          @click="tab = 'individual'"
        >
          Individual
        </button>
      </div>

      <!-- Team -->
      <section v-if="tab === 'team'" class="mt-6 flex flex-col gap-3">
        <div
          v-for="t in standings"
          :key="t.school_id"
          class="rounded-2xl border border-ink-800 bg-ink-900 p-4"
          :class="t.rank === 1 ? 'border-brand-400/60' : ''"
        >
          <div class="flex items-baseline justify-between">
            <h2 class="font-display text-lg font-black">
              <span class="mr-2 inline-grid size-7 place-items-center rounded-full bg-ink-800 text-sm" :class="t.rank === 1 ? 'bg-brand-400 text-ink-950' : ''">{{ t.rank }}</span>
              {{ t.school_name }}
            </h2>
            <p class="text-right">
              <span class="font-display text-2xl font-black tabular-nums">{{ t.total }}</span>
              <span v-if="t.tiebreak != null" class="ml-2 text-xs text-slate-500">TB {{ t.tiebreak }}</span>
            </p>
          </div>
          <ol class="mt-2 flex flex-wrap gap-x-4 gap-y-1 text-sm">
            <li
              v-for="r in t.runners"
              :key="r.athlete_id"
              :class="r.scoring ? 'text-slate-200' : 'text-slate-500'"
            >
              <span class="font-bold tabular-nums">{{ r.place }}.</span> {{ r.name }}
              <span v-if="r.grade" class="text-xs text-slate-600">({{ r.grade }})</span>
            </li>
          </ol>
        </div>
        <p v-if="standings.length === 0" class="text-sm text-slate-500">No team scores yet.</p>
      </section>

      <!-- Individual -->
      <section v-else class="mt-6">
        <table class="w-full text-sm">
          <thead>
            <tr class="text-left text-xs uppercase tracking-wider text-slate-500">
              <th class="py-2 pr-2">Pl</th>
              <th class="py-2 pr-2">Runner</th>
              <th class="py-2 pr-2">School</th>
              <th class="py-2 text-right">Time</th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="(row, i) in individual" :key="i" class="border-t border-ink-800/60">
              <td class="py-1.5 pr-2 font-display font-bold tabular-nums text-slate-400">
                {{ row.place ?? "—" }}
              </td>
              <td class="py-1.5 pr-2">
                {{ row.athlete_name }}
                <span v-if="row.status !== 'matched'" class="ml-1 rounded bg-ink-800 px-1.5 py-0.5 text-[10px] font-bold uppercase text-slate-400">
                  {{ row.status }}
                </span>
              </td>
              <td class="py-1.5 pr-2 text-slate-400">{{ row.school_name ?? "—" }}</td>
              <td class="py-1.5 text-right font-display font-bold tabular-nums text-slate-200">
                {{ formatClock(row.offset_ms) }}
              </td>
            </tr>
            <tr v-if="individual.length === 0">
              <td colspan="4" class="py-4 text-slate-500">No finishers recorded yet.</td>
            </tr>
          </tbody>
        </table>
      </section>

      <p class="mt-8 text-center text-xs text-slate-600 print:hidden">
        timing.runXC.run · results update live as the race is timed
      </p>
    </template>
  </main>
</template>
