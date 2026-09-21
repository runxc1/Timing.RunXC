<script setup lang="ts">
import { computed, ref } from "vue";
import { makeClient } from "../lib/supabase";
import { formatCode } from "../lib/codes";
import { useSession } from "../stores/session";

const session = useSession();
const adminCodeInput = ref("");
const error = ref("");
const loading = ref(false);

const client = computed(() =>
  makeClient({ meetAdminCode: session.meetAdminCode || undefined }),
);

interface MeetRow {
  id: string;
  name: string;
  code: string | null;
  admin_code: string;
  created_at: string;
  /** True when the credential is this meet's own owner code. */
  owner: boolean;
}
const meets = ref<MeetRow[]>([]);

async function load() {
  error.value = "";
  const code = session.meetAdminCode;
  if (!code) {
    meets.value = [];
    return;
  }
  loading.value = true;
  const c = client.value;
  try {
    const [own, delegated] = await Promise.all([
      c
        .from("meets")
        .select("id, name, code, admin_code, created_at")
        .eq("admin_code", code)
        .order("created_at", { ascending: false }),
      c.from("meet_admins").select("meet_id").eq("code", code),
    ]);
    if (own.error) {
      error.value = own.error.message;
      return;
    }
    const rows: MeetRow[] = ((own.data ?? []) as Omit<MeetRow, "owner">[]).map((m) => ({
      ...m,
      owner: true,
    }));
    const have = new Set(rows.map((m) => m.id));
    const delegatedIds = ((delegated.data ?? []) as { meet_id: string }[])
      .map((d) => d.meet_id)
      .filter((id) => !have.has(id));
    if (delegatedIds.length) {
      const more = await c
        .from("meets")
        .select("id, name, code, admin_code, created_at")
        .in("id", delegatedIds)
        .order("created_at", { ascending: false });
      for (const m of ((more.data ?? []) as Omit<MeetRow, "owner">[])) {
        rows.push({ ...m, owner: false });
      }
    }
    meets.value = rows;
  } finally {
    loading.value = false;
  }
}
load();

function unlock() {
  session.meetAdminCode = adminCodeInput.value.trim().toUpperCase();
  adminCodeInput.value = "";
  load();
}

function forget() {
  session.forgetMeet();
  meets.value = [];
}
</script>

<template>
  <div class="mx-auto max-w-lg px-4 py-10">
    <!-- unlock -->
    <div v-if="!session.meetAdminCode" class="text-center">
      <p class="text-xs font-semibold uppercase tracking-[0.2em] text-primary-300">Meet admin</p>
      <h1 class="mt-2 heading text-3xl text-ink-50">Enter your admin code</h1>
      <p class="mt-2 body-muted">
        The code you chose (or were given) when the meet was set up. It unlocks every meet it
        manages so you can pick one to work on.
      </p>
      <form class="mt-6 flex items-stretch gap-2" @submit.prevent="unlock">
        <input
          v-model="adminCodeInput"
          autocapitalize="characters"
          autocomplete="off"
          spellcheck="false"
          maxlength="8"
          placeholder="ADMIN CODE"
          class="input-code flex-1 !text-xl"
        />
        <button class="btn-primary px-5" :disabled="adminCodeInput.trim().length < 4">Unlock</button>
      </form>
      <p v-if="error" class="mt-3 text-sm text-rose-300">{{ error }}</p>
    </div>

    <!-- meet list -->
    <template v-else>
      <div class="flex items-center justify-between gap-3">
        <div>
          <p class="text-xs font-semibold uppercase tracking-[0.2em] text-primary-300">Your meets</p>
          <h1 class="mt-1 heading text-2xl text-ink-50">Admin</h1>
        </div>
        <div class="flex gap-2">
          <RouterLink class="btn-secondary" to="/meets/new">New meet</RouterLink>
          <button class="btn-ghost text-xs" title="Forget this admin code on this device" @click="forget">
            Sign out
          </button>
        </div>
      </div>

      <p v-if="error" class="mt-4 card p-3 text-sm text-rose-300">{{ error }}</p>

      <ul class="mt-5 space-y-3">
        <li v-for="m in meets" :key="m.id">
          <RouterLink
            :to="m.code ? `/admin/${m.code}` : '#'"
            class="card flex items-center justify-between gap-3 p-4 transition hover:border-primary-500/60"
          >
            <div>
              <p class="heading text-lg leading-tight text-ink-50">{{ m.name }}</p>
              <p class="mt-1 text-xs text-ink-400">
                Code {{ m.code ? formatCode(m.code) : "—" }}
                <span v-if="!m.owner" class="ml-1 chip bg-sky-500/10 text-sky-300">delegated</span>
              </p>
            </div>
            <svg viewBox="0 0 24 24" class="h-5 w-5 shrink-0 text-ink-500" fill="none" stroke="currentColor" stroke-width="2">
              <path d="M9 6l6 6-6 6" stroke-linecap="round" stroke-linejoin="round" />
            </svg>
          </RouterLink>
        </li>
      </ul>

      <p v-if="loading" class="mt-6 text-center text-sm text-ink-400">Loading…</p>
      <p v-else-if="!meets.length && !error" class="mt-6 text-center text-sm text-ink-400">
        No meets found for this code. Check the code or create a new meet.
      </p>
    </template>
  </div>
</template>
