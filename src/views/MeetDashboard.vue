<script setup lang="ts">
import { computed, ref, watchEffect } from "vue";
import { makeClient } from "../lib/supabase";
import { genCode, formatCode } from "../lib/codes";
import { useSession } from "../stores/session";

const session = useSession();
const adminCodeInput = ref("");
const error = ref("");

const client = computed(() =>
  makeClient({ meetAdminCode: session.meetAdminCode || undefined }),
);

const meetInfo = ref<{ id: string; name: string; admin_code: string } | null>(null);
type Admin = { id: string; email: string; name: string | null; role: string; code: string };
const admins = ref<Admin[]>([]);
const me = ref<Admin | null>(null);
/** The stored credential is the meet's own code (not a delegated one). */
const isOwnerCode = computed(
  () => !!meetInfo.value && meetInfo.value.admin_code === session.meetAdminCode,
);
const races = ref<
  Array<{
    id: string;
    name: string;
    race_code: string;
    status: string;
    scheduled_start: string | null;
  }>
>([]);
const schools = ref<Array<{ id: string; name: string }>>([]);

async function load() {
  error.value = "";
  const code = session.meetAdminCode;
  if (!code) return;
  const c = client.value;
  // The credential is either the meet's own admin code or a delegated admin code.
  let meetId = "";
  const own = await c.from("meets").select("id").eq("admin_code", code).maybeSingle();
  if (own.error) {
    error.value = own.error.message;
    return;
  }
  if (own.data) {
    meetId = own.data.id;
  } else {
    const delegated = await c.from("meet_admins").select("meet_id").eq("code", code).maybeSingle();
    if (delegated.error) {
      error.value = delegated.error.message;
      return;
    }
    meetId = delegated.data?.meet_id ?? "";
  }
  if (!meetId) {
    error.value = "Admin code not recognized.";
    return;
  }
  const m = await c.from("meets").select("id, name, admin_code").eq("id", meetId).maybeSingle();
  if (!m.data) {
    error.value = "Admin code not recognized.";
    return;
  }
  meetInfo.value = m.data;
  const [r, s, a] = await Promise.all([
    c.from("races").select("id, name, race_code, status, scheduled_start").eq("meet_id", meetId).order("created_at"),
    c.from("schools").select("id, name").eq("meet_id", meetId).order("name"),
    c.from("meet_admins").select("id, email, name, role, code").eq("meet_id", meetId).order("created_at"),
  ]);
  races.value = (r.data ?? []) as typeof races.value;
  schools.value = (s.data ?? []) as typeof schools.value;
  admins.value = (a.data ?? []) as Admin[];
  // The organizer signs in with the meet's own code, which is not their admin row.
  me.value =
    admins.value.find((x) => x.code === code) ??
    (meetInfo.value.admin_code === code ? (admins.value.find((x) => x.role === "owner") ?? null) : null);
}
watchEffect(load);

// --- unlock with existing code ---
function unlock() {
  session.meetAdminCode = adminCodeInput.value.trim().toUpperCase();
  adminCodeInput.value = "";
}

// --- create race ---
const raceName = ref("");
const raceTime = ref("");
const creatingRace = ref(false);
async function createRace() {
  if (!raceName.value.trim() || creatingRace.value) return;
  creatingRace.value = true;
  for (let i = 0; i < 5; i++) {
    const race_code = genCode();
    const { error: err } = await client.value.from("races").insert({
      meet_id: meetInfo.value!.id,
      name: raceName.value.trim(),
      race_code,
      scheduled_start: raceTime.value ? new Date(raceTime.value).toISOString() : null,
    });
    if (!err) {
      raceName.value = "";
      raceTime.value = "";
      await load();
      break;
    }
    if (err.code !== "23505") error.value = err.message;
  }
  creatingRace.value = false;
}

// --- schools ---
const schoolName = ref("");
async function addSchool() {
  const n = schoolName.value.trim();
  if (!n) return;
  const { error: err } = await client.value.from("schools").insert({
    meet_id: meetInfo.value!.id,
    name: n,
  });
  if (err && err.code !== "23505") error.value = err.message;
  schoolName.value = "";
  await load();
}
async function removeSchool(id: string) {
  if (!confirm("Remove this school? Registered athletes keep their times but lose team scoring.")) return;
  await client.value.from("schools").delete().eq("id", id);
  await load();
}

// --- admins ---
const adminName = ref("");
const adminEmail = ref("");
const addingAdmin = ref(false);
const newAdmin = ref<{ email: string; code: string } | null>(null);
const copiedCode = ref("");

async function addAdmin() {
  if (!meetInfo.value || addingAdmin.value) return;
  const email = adminEmail.value.trim().toLowerCase();
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) {
    error.value = "Enter a valid email for the person you're making an admin.";
    return;
  }
  addingAdmin.value = true;
  error.value = "";
  const { data, error: err } = await client.value.rpc("add_meet_admin", {
    p_meet_id: meetInfo.value.id,
    p_email: email,
    p_name: adminName.value.trim() || null,
  });
  addingAdmin.value = false;
  if (err) {
    error.value = err.message.includes("ADMIN_EXISTS")
      ? "That email already administers this meet."
      : err.message;
    return;
  }
  newAdmin.value = { email, code: (data as { code: string }).code };
  adminName.value = "";
  adminEmail.value = "";
  await load();
}

async function removeAdmin(id: string) {
  if (!confirm("Remove this admin? Their code stops working immediately.")) return;
  const { error: err } = await client.value.rpc("remove_meet_admin", { p_id: id });
  if (err) error.value = err.message;
  await load();
}

function copyCode(code: string) {
  navigator.clipboard.writeText(code);
  copiedCode.value = code;
  setTimeout(() => (copiedCode.value = ""), 1500);
}

const statusColors: Record<string, string> = {
  draft: "bg-slate-500/15 text-slate-300",
  registration_open: "bg-cyan-500/15 text-cyan-300",
  ready: "bg-brand-400/15 text-brand-300",
  running: "bg-amber-500/15 text-amber-300",
  finalized: "bg-violet-500/15 text-violet-300",
};
</script>

<template>
  <main class="mx-auto max-w-3xl px-5 py-8">
    <!-- Unlock -->
    <div v-if="!session.meetAdminCode" class="mx-auto max-w-md pt-16">
      <h1 class="font-display text-2xl font-black">Meet dashboard</h1>
      <p class="mt-1 text-sm text-slate-400">Enter the admin code for your meet.</p>
      <div class="mt-4 flex gap-2">
        <input
          v-model="adminCodeInput"
          autocapitalize="characters"
          maxlength="6"
          placeholder="ADMIN CODE"
          class="w-full rounded-xl border border-ink-700 bg-ink-950 px-4 py-3 text-center font-display text-xl font-bold tracking-[0.25em] text-brand-300 focus:border-brand-400 focus:outline-none"
          @keyup.enter="unlock"
        />
        <button
          class="rounded-xl bg-brand-400 px-5 font-black text-ink-950 hover:bg-brand-300"
          @click="unlock"
        >
          Open
        </button>
      </div>
      <p v-if="error" class="mt-3 text-sm text-red-300">{{ error }}</p>
    </div>

    <template v-else>
      <p v-if="error" class="mb-4 rounded-lg bg-red-500/10 px-3 py-2 text-sm text-red-300">{{ error }}</p>

      <div v-if="meetInfo">
        <h1 class="font-display text-3xl font-black tracking-tight">{{ meetInfo.name }}</h1>
        <p class="mt-1 text-sm text-slate-400">
          <template v-if="me">
            Signed in as {{ me.name || me.email }}
            <span class="uppercase tracking-wide text-slate-500">· {{ me.role }}</span>
          </template>
          <template v-if="isOwnerCode">
            · Admin code
            <span class="font-bold text-brand-300">{{ formatCode(meetInfo.admin_code) }}</span>
          </template>
        </p>
      </div>
      <div v-else class="text-sm text-slate-400">Loading meet…</div>

      <!-- Schools -->
      <section class="mt-8 rounded-2xl border border-ink-800 bg-ink-900 p-5">
        <h2 class="text-sm font-black uppercase tracking-wider text-slate-400">Schools</h2>
        <div class="mt-3 flex flex-wrap gap-2">
          <span
            v-for="s in schools"
            :key="s.id"
            class="group flex items-center gap-1.5 rounded-full bg-ink-800 py-1 pl-3 pr-1.5 text-sm"
          >
            {{ s.name }}
            <button
              class="grid size-5 place-items-center rounded-full text-slate-500 hover:bg-red-500/20 hover:text-red-300"
              title="Remove"
              @click="removeSchool(s.id)"
            >
              ×
            </button>
          </span>
          <span v-if="schools.length === 0" class="text-sm text-slate-500">
            No schools yet — add each team that will compete.
          </span>
        </div>
        <div class="mt-3 flex gap-2">
          <input
            v-model="schoolName"
            placeholder="Add school…"
            class="w-full max-w-xs rounded-lg border border-ink-700 bg-ink-950 px-3 py-2 text-sm focus:border-brand-400 focus:outline-none"
            @keyup.enter="addSchool"
          />
          <button class="rounded-lg bg-ink-800 px-4 text-sm font-bold hover:bg-ink-700" @click="addSchool">
            Add
          </button>
        </div>
      </section>

      <!-- Admins -->
      <section class="mt-6 rounded-2xl border border-ink-800 bg-ink-900 p-5">
        <h2 class="text-sm font-black uppercase tracking-wider text-slate-400">Admins</h2>
        <p class="mt-1 text-xs text-slate-500">
          Anyone here can create races, manage schools and edit results. Share a code with the
          person and they open the dashboard with it.
        </p>
        <ul class="mt-3 flex flex-col gap-2">
          <li
            v-for="a in admins"
            :key="a.id"
            class="flex items-center gap-3 rounded-xl border border-ink-800 bg-ink-950 px-3 py-2"
          >
            <div class="min-w-0 flex-1">
              <p class="truncate text-sm font-bold">
                {{ a.name || a.email }}
                <span v-if="a.code === session.meetAdminCode" class="text-xs font-normal text-slate-500">(you)</span>
              </p>
              <p class="truncate text-xs text-slate-500">{{ a.name ? a.email : "" }}</p>
            </div>
            <span
              class="rounded-full px-2 py-0.5 text-[10px] font-black uppercase tracking-wide"
              :class="a.role === 'owner' ? 'bg-brand-400/15 text-brand-300' : 'bg-slate-500/15 text-slate-300'"
            >{{ a.role }}</span>
            <button
              class="rounded-lg bg-ink-800 px-2.5 py-1 font-display text-sm font-bold tracking-[0.2em] text-brand-300 hover:bg-ink-700"
              title="Copy admin code"
              @click="copyCode(a.code)"
            >
              {{ copiedCode === a.code ? "Copied" : a.code }}
            </button>
            <button
              v-if="a.role !== 'owner'"
              class="grid size-6 place-items-center rounded-full text-slate-500 hover:bg-red-500/20 hover:text-red-300"
              title="Remove admin"
              @click="removeAdmin(a.id)"
            >
              ×
            </button>
          </li>
        </ul>
        <div v-if="newAdmin" class="mt-3 rounded-xl border border-brand-400/40 bg-brand-400/10 p-3 text-sm text-brand-200">
          {{ newAdmin.email }} is now an admin with code
          <span class="font-display font-black tracking-[0.2em]">{{ newAdmin.code }}</span> — send it to them.
        </div>
        <div class="mt-3 flex flex-col gap-2 sm:flex-row">
          <input
            v-model="adminName"
            placeholder="Name"
            class="rounded-lg border border-ink-700 bg-ink-950 px-3 py-2 text-sm focus:border-brand-400 focus:outline-none sm:w-40"
          />
          <input
            v-model="adminEmail"
            type="email"
            placeholder="email@school.edu"
            class="w-full rounded-lg border border-ink-700 bg-ink-950 px-3 py-2 text-sm focus:border-brand-400 focus:outline-none sm:flex-1"
            @keyup.enter="addAdmin"
          />
          <button
            class="rounded-lg bg-brand-400 px-4 py-2 text-sm font-black text-ink-950 hover:bg-brand-300 disabled:opacity-50"
            :disabled="addingAdmin"
            @click="addAdmin"
          >
            {{ addingAdmin ? "Adding…" : "Make admin" }}
          </button>
        </div>
      </section>

      <!-- Races -->
      <section class="mt-6">
        <h2 class="text-sm font-black uppercase tracking-wider text-slate-400">Races</h2>
        <ul class="mt-3 flex flex-col gap-2">
          <li
            v-for="r in races"
            :key="r.id"
            class="flex items-center gap-3 rounded-xl border border-ink-800 bg-ink-900 p-4"
          >
            <div class="min-w-0 flex-1">
              <RouterLink :to="`/m/races/${r.id}`" class="block truncate font-bold hover:text-brand-300">
                {{ r.name }}
              </RouterLink>
              <p class="text-xs text-slate-500">
                {{ r.race_code }}
                <template v-if="r.scheduled_start"> · {{ new Date(r.scheduled_start).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' }) }}</template>
              </p>
            </div>
            <span
              class="rounded-full px-2 py-0.5 text-[10px] font-black uppercase tracking-wide"
              :class="statusColors[r.status] ?? 'bg-slate-500/15 text-slate-300'"
            >{{ r.status.replace('_', ' ') }}</span>
            <RouterLink
              :to="`/t/${r.race_code}`"
              class="rounded-lg bg-brand-400 px-3 py-1.5 text-xs font-black text-ink-950 hover:bg-brand-300"
            >
              Time
            </RouterLink>
          </li>
        </ul>

        <div class="mt-4 flex flex-col gap-2 rounded-xl border border-dashed border-ink-700 p-4 sm:flex-row">
          <input
            v-model="raceName"
            placeholder="Race name (e.g. Boys Varsity 5K)"
            class="flex-1 rounded-lg border border-ink-700 bg-ink-950 px-3 py-2.5 text-sm focus:border-brand-400 focus:outline-none"
            @keyup.enter="createRace"
          />
          <input v-model="raceTime" type="time" class="rounded-lg border border-ink-700 bg-ink-950 px-3 py-2.5 text-sm focus:border-brand-400 focus:outline-none" />
          <button
            class="rounded-lg bg-brand-400 px-5 py-2.5 text-sm font-black text-ink-950 hover:bg-brand-300 disabled:opacity-50"
            :disabled="creatingRace || !meetInfo"
            @click="createRace"
          >
            Add race
          </button>
        </div>
      </section>
    </template>
  </main>
</template>
