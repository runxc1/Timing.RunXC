<script setup lang="ts">
import { computed, ref } from "vue";
import { useRouter } from "vue-router";
import { makeClient, supabase } from "../lib/supabase";
import { genCode, normalizeCode } from "../lib/codes";
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

// --- public meet code ------------------------------------------------------
// The database generates all three codes on insert. We only send `code`, and
// only when the organizer overrides the suggestion.

/** Suggestion shown until the organizer types their own. */
const suggestion = ref(genCode());
const customCode = ref("");

type CodeState = "idle" | "checking" | "ok" | "taken" | "format" | "profane";
const codeState = ref<CodeState>("idle");

/** Mirrors the database profanity block so we can word the error precisely. */
const BLOCKED_WORDS = /fuck|shit|cunt/i;
/** Matches the server-side shape check: exactly six letters or digits. */
const SHAPE = /^[A-Z0-9]{6}$/;

const typedCode = computed(() => normalizeCode(customCode.value));
const meetCode = computed(() => typedCode.value || suggestion.value);
const usingCustom = computed(() => typedCode.value.length > 0);

const codeHint = computed(() => {
  switch (codeState.value) {
    case "format":
      return "Must be exactly 6 letters or digits.";
    case "profane":
      return "Pick a different word — that code contains blocked words.";
    case "taken":
      return "That code is already taken.";
    default:
      return "";
  }
});

let probeTimer: ReturnType<typeof setTimeout> | null = null;
let probeSeq = 0;

async function probe() {
  const seq = ++probeSeq;
  const c = typedCode.value;
  if (!c) {
    codeState.value = "idle";
    return;
  }
  if (!SHAPE.test(c)) {
    codeState.value = "format";
    return;
  }
  if (BLOCKED_WORDS.test(c)) {
    codeState.value = "profane";
    return;
  }
  codeState.value = "checking";
  const { data, error: err } = await supabase.rpc("check_code_available", {
    p_kind: "meet",
    p_code: c,
  });
  if (seq !== probeSeq) return; // input moved on while we were asking
  if (err) {
    console.warn("code check failed:", err.message);
    codeState.value = "idle";
    return;
  }
  codeState.value = data ? "ok" : "taken";
}

function onCodeInput() {
  if (probeTimer) clearTimeout(probeTimer);
  probeTimer = setTimeout(probe, 400);
}

function onCodeBlur() {
  if (probeTimer) clearTimeout(probeTimer);
  void probe();
}

function rerollSuggestion() {
  suggestion.value = genCode();
  customCode.value = "";
  codeState.value = "idle";
}

// --- success screen --------------------------------------------------------

interface CreatedMeet {
  name: string;
  code: string;
  signupCode: string;
  timerCode: string;
}
const created = ref<CreatedMeet | null>(null);

const links = computed(() => {
  const c = created.value;
  if (!c) return null;
  const o = window.location.origin;
  return {
    register: `${o}/signup/${c.code}`,
    results: `${o}/r/${c.code}`,
    timer: `${o}/t/${c.timerCode}`,
  };
});

const codeCards = computed(() => {
  const c = created.value;
  const l = links.value;
  if (!c || !l) return [];
  return [
    {
      key: "meet",
      label: "Meet code",
      code: c.code,
      blurb: "What runners type on the home page. Drives registration and results.",
      links: [
        { kind: "Registration", url: l.register },
        { kind: "Results", url: l.results },
      ],
    },
    {
      key: "signup",
      label: "Signup code",
      code: c.signupCode,
      blurb: "Poster / sign-in-table fallback for registrations.",
      links: [] as Array<{ kind: string; url: string }>,
    },
    {
      key: "timer",
      label: "Timer code",
      code: c.timerCode,
      blurb: "Give this to whoever holds a phone at the finish line.",
      links: [{ kind: "Timer", url: l.timer }],
    },
  ];
});

const copiedKey = ref("");
const copiedAll = ref(false);

function copy(text: string, key: string) {
  navigator.clipboard.writeText(text);
  copiedKey.value = key;
  setTimeout(() => {
    if (copiedKey.value === key) copiedKey.value = "";
  }, 1500);
}

function copyEverything() {
  const c = created.value;
  const l = links.value;
  if (!c || !l) return;
  navigator.clipboard.writeText(
    [
      `${c.name}`,
      `Meet code ${c.code}`,
      `Register ${l.register}`,
      `Results ${l.results}`,
      `Signup code ${c.signupCode}`,
      `Timer code ${c.timerCode} — ${l.timer}`,
    ].join("\n"),
  );
  copiedAll.value = true;
  setTimeout(() => {
    copiedAll.value = false;
  }, 1500);
}

// --- create ----------------------------------------------------------------

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

  // Block on a final availability probe for a hand-picked code.
  if (usingCustom.value) {
    if (probeTimer) clearTimeout(probeTimer);
    await probe();
    if (codeState.value === "format" || codeState.value === "profane" || codeState.value === "taken") {
      error.value = codeHint.value;
      busy.value = false;
      return;
    }
  }

  const wantedCode = usingCustom.value ? meetCode.value : null;
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
        ...(wantedCode ? { code: wantedCode } : {}),
      })
      .select("id, admin_code")
      .single();
    if (!err) {
      // Signup / timer codes are generated by the database — read them back.
      const codes = await supabase
        .from("meets")
        .select("code, signup_code, timer_code")
        .eq("id", data.id)
        .single();
      if (codes.error) {
        error.value = codes.error.message;
        break;
      }

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
      session.rememberMeet(codes.data.code as string);
      created.value = {
        name: name.value.trim(),
        code: codes.data.code as string,
        signupCode: codes.data.signup_code as string,
        timerCode: codes.data.timer_code as string,
      };
      window.scrollTo({ top: 0 });
      return;
    }
    if (err.code !== "23505") {
      error.value = err.message;
      break;
    }
    if (wantedCode) {
      codeState.value = "taken";
      error.value = "That code was claimed a moment ago — pick another.";
      break;
    }
  }
  busy.value = false;
}
</script>

<template>
  <!-- Success: hand out the three codes -->
  <main v-if="created" class="mx-auto max-w-lg px-5 py-10">
    <div class="flex items-start gap-3">
      <span class="grid size-9 shrink-0 place-items-center rounded-full bg-brand-400 text-lg font-black text-ink-950">
        ✓
      </span>
      <div>
        <h1 class="font-display text-2xl font-black leading-tight tracking-tight">
          {{ created.name }} is live
        </h1>
        <p class="mt-1 text-sm text-slate-400">
          Three codes, three jobs. Save them somewhere you can reach at the meet — everything below
          works offline once it's on a phone.
        </p>
      </div>
    </div>

    <section class="mt-6 flex flex-col gap-3">
      <article
        v-for="card in codeCards"
        :key="card.key"
        class="rounded-2xl border border-ink-800 bg-ink-900 p-5"
      >
        <div class="flex items-center justify-between gap-3">
          <p class="text-xs font-black uppercase tracking-wider text-slate-400">{{ card.label }}</p>
          <button
            class="rounded-lg bg-ink-800 px-3 py-1.5 text-xs font-bold hover:bg-ink-700"
            @click="copy(card.code, card.key)"
          >
            {{ copiedKey === card.key ? "Copied ✓" : "Copy code" }}
          </button>
        </div>
        <p class="mt-2 font-display text-3xl font-black tracking-[0.28em] text-brand-300">
          {{ card.code }}
        </p>
        <p class="mt-1 text-xs text-slate-500">{{ card.blurb }}</p>
        <ul v-if="card.links.length" class="mt-3 flex flex-col gap-2">
          <li
            v-for="link in card.links"
            :key="link.url"
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
              @click="copy(link.url, link.url)"
            >
              {{ copiedKey === link.url ? "Copied" : "Copy" }}
            </button>
          </li>
        </ul>
      </article>
    </section>

    <div class="mt-5 flex flex-col gap-2 sm:flex-row">
      <button
        class="flex-1 rounded-xl border border-ink-700 bg-ink-900 py-3 text-sm font-bold text-slate-200 hover:bg-ink-800"
        @click="copyEverything"
      >
        {{ copiedAll ? "Copied everything ✓" : "Copy all codes & links" }}
      </button>
      <button
        class="flex-1 rounded-xl bg-brand-400 py-3 text-sm font-black text-ink-950 hover:bg-brand-300"
        @click="router.push('/m')"
      >
        Go to dashboard →
      </button>
    </div>
  </main>

  <main v-else class="mx-auto max-w-md px-5 py-10">
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
        <div class="flex items-center justify-between gap-2">
          <span class="text-xs font-black uppercase tracking-wider text-slate-500">Meet code</span>
          <button
            type="button"
            class="rounded-lg px-2 py-1 text-[11px] font-bold text-slate-400 hover:bg-ink-800 hover:text-slate-200"
            @click="rerollSuggestion"
          >
            ↻ New suggestion
          </button>
        </div>
        <input
          v-model="customCode"
          autocapitalize="characters"
          autocomplete="off"
          spellcheck="false"
          maxlength="6"
          :placeholder="suggestion"
          class="mt-2 w-full rounded-xl border bg-ink-950 px-4 py-3 text-center font-display text-xl font-bold uppercase tracking-[0.3em] text-brand-300 placeholder:text-ink-600 focus:outline-none"
          :class="codeHint ? 'border-red-500/60' : 'border-ink-700 focus:border-brand-400'"
          @input="onCodeInput"
          @blur="onCodeBlur"
        />
        <p class="mt-2 text-xs" :class="codeHint ? 'text-red-300' : 'text-slate-500'">
          <template v-if="codeState === 'checking'">Checking that code…</template>
          <template v-else-if="codeState === 'ok'">
            {{ meetCode }} is free — runners will use it for registration and results.
          </template>
          <template v-else-if="codeHint">{{ codeHint }}</template>
          <template v-else>
            Left blank we use <span class="font-bold text-slate-400">{{ suggestion }}</span>. Type your own
            (6 letters or digits) for a nicer link.
          </template>
        </p>
      </div>

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
