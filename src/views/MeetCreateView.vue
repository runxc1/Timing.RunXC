<script setup lang="ts">
import { ref } from "vue";
import { useRouter } from "vue-router";
import { makeClient, supabase } from "../lib/supabase";
import { genCode } from "../lib/codes";
import { useSession } from "../stores/session";

const router = useRouter();
const session = useSession();

const name = ref("");
const location = ref("");
const meetDate = ref(new Date().toISOString().slice(0, 10));
const adminName = ref("");
const adminEmail = ref("");
const busy = ref(false);
const error = ref("");

async function create() {
  if (!name.value.trim()) {
    error.value = "Meet name is required.";
    return;
  }
  const email = adminEmail.value.trim().toLowerCase();
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) {
    error.value = "Enter your email — it identifies the organizer of this meet.";
    return;
  }
  busy.value = true;
  error.value = "";
  // Retry in the (astronomically unlikely) event of an admin-code collision.
  for (let attempt = 0; attempt < 5; attempt++) {
    const admin_code = genCode();
    const { data, error: err } = await supabase
      .from("meets")
      .insert({
        name: name.value.trim(),
        location: location.value.trim() || null,
        meet_date: meetDate.value || null,
        admin_code,
      })
      .select("id, name, admin_code")
      .single();
    if (!err) {
      // Register the organizer as this meet's owner. The admin code already
      // grants access, so a failure here is not fatal to meet creation.
      const { error: ownerErr } = await makeClient({ meetAdminCode: data.admin_code }).rpc(
        "add_meet_admin",
        {
          p_meet_id: data.id,
          p_email: email,
          p_name: adminName.value.trim() || null,
          p_role: "owner",
        },
      );
      if (ownerErr) console.warn("organizer registration failed:", ownerErr.message);
      session.meetAdminCode = data.admin_code;
      router.push("/m");
      return;
    }
    if (err.code !== "23505") {
      error.value = err.message;
      break;
    }
  }
  busy.value = false;
}
</script>

<template>
  <main class="mx-auto max-w-md px-5 py-10">
    <h1 class="font-display text-2xl font-black tracking-tight">Register as organizer</h1>
    <p class="mt-1 text-sm text-slate-400">
      Create the meet and you become its admin: you set up races, and runners sign up to them.
      You'll get an admin code — keep it, it's your key to manage this meet.
    </p>

    <form class="mt-6 flex flex-col gap-4" @submit.prevent="create">
      <label class="block">
        <span class="text-xs font-bold uppercase tracking-wider text-slate-400">Meet name</span>
        <input
          v-model="name"
          required
          maxlength="120"
          placeholder="Mid-Season Invitational"
          class="mt-1.5 w-full rounded-xl border border-ink-700 bg-ink-950 px-4 py-3 text-sm focus:border-brand-400 focus:outline-none"
        />
      </label>
      <label class="block">
        <span class="text-xs font-bold uppercase tracking-wider text-slate-400">Location</span>
        <input
          v-model="location"
          maxlength="120"
          placeholder="Riverside Park"
          class="mt-1.5 w-full rounded-xl border border-ink-700 bg-ink-950 px-4 py-3 text-sm focus:border-brand-400 focus:outline-none"
        />
      </label>
      <label class="block">
        <span class="text-xs font-bold uppercase tracking-wider text-slate-400">Date</span>
        <input
          v-model="meetDate"
          type="date"
          class="mt-1.5 w-full rounded-xl border border-ink-700 bg-ink-950 px-4 py-3 text-sm focus:border-brand-400 focus:outline-none"
        />
      </label>

      <div class="rounded-xl border border-ink-800 bg-ink-900 p-4">
        <p class="text-xs font-black uppercase tracking-wider text-slate-500">Organizer</p>
        <label class="mt-3 block">
          <span class="text-xs font-bold uppercase tracking-wider text-slate-400">Your name</span>
          <input
            v-model="adminName"
            maxlength="120"
            autocomplete="name"
            placeholder="Alex Morgan"
            class="mt-1.5 w-full rounded-xl border border-ink-700 bg-ink-950 px-4 py-3 text-sm focus:border-brand-400 focus:outline-none"
          />
        </label>
        <label class="mt-3 block">
          <span class="text-xs font-bold uppercase tracking-wider text-slate-400">Email</span>
          <input
            v-model="adminEmail"
            required
            type="email"
            maxlength="160"
            autocomplete="email"
            placeholder="you@club.org"
            class="mt-1.5 w-full rounded-xl border border-ink-700 bg-ink-950 px-4 py-3 text-sm focus:border-brand-400 focus:outline-none"
          />
        </label>
        <p class="mt-2 text-xs text-slate-500">
          Only people you add as admins can see this — it is never shown to runners.
        </p>
      </div>

      <p v-if="error" class="rounded-lg bg-red-500/10 px-3 py-2 text-sm text-red-300">
        {{ error }}
      </p>

      <button
        type="submit"
        :disabled="busy"
        class="mt-2 rounded-xl bg-brand-400 py-3.5 font-black text-ink-950 transition hover:bg-brand-300 disabled:opacity-50"
      >
        {{ busy ? "Creating…" : "Create meet" }}
      </button>
    </form>
  </main>
</template>
