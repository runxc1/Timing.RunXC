<script setup lang="ts">
import { computed, ref, watch } from "vue";
import QRCode from "qrcode";
import { makeClient } from "../lib/supabase";
import { formatCode, normalizeCode } from "../lib/codes";
import { useSession } from "../stores/session";

const session = useSession();
const adminCodeInput = ref("");
const error = ref("");

const client = computed(() =>
  makeClient({ meetAdminCode: session.meetAdminCode || undefined }),
);

interface MeetInfo {
  id: string;
  name: string;
  admin_code: string;
  /** Public code behind /j/ and /r/ links. */
  code: string | null;
  signup_code: string | null;
  timer_code: string | null;
  registration_locked_at: string | null;
}
const meetInfo = ref<MeetInfo | null>(null);
type Admin = { id: string; email: string; name: string | null; role: string; code: string };
const admins = ref<Admin[]>([]);
const me = ref<Admin | null>(null);
/** The stored credential is the meet's own code (not a delegated one). */
const isOwnerCode = computed(
  () => !!meetInfo.value && meetInfo.value.admin_code === session.meetAdminCode,
);
const locked = computed(() => !!meetInfo.value?.registration_locked_at);
const races = ref<
  Array<{ id: string; name: string; status: string; scheduled_start: string | null }>
>([]);
const schools = ref<Array<{ id: string; name: string }>>([]);

/** Inline, self-dismissing notification. */
const toast = ref("");
let toastTimer: ReturnType<typeof setTimeout> | null = null;
function showToast(msg: string) {
  toast.value = msg;
  if (toastTimer) clearTimeout(toastTimer);
  toastTimer = setTimeout(() => {
    toast.value = "";
  }, 4000);
}

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
  const m = await c
    .from("meets")
    .select("id, name, admin_code, code, signup_code, timer_code, registration_locked_at")
    .eq("id", meetId)
    .maybeSingle();
  if (!m.data) {
    error.value = "Admin code not recognized.";
    return;
  }
  const info = m.data as MeetInfo;
  meetInfo.value = info;
  if (info.code) session.rememberMeet(info.code);
  const [r, s, a] = await Promise.all([
    c.from("races").select("id, name, status, scheduled_start").eq("meet_id", meetId).order("created_at"),
    c.from("schools").select("id, name").eq("meet_id", meetId).order("name"),
    c.from("meet_admins").select("id, email, name, role, code").eq("meet_id", meetId).order("created_at"),
  ]);
  races.value = (r.data ?? []) as typeof races.value;
  schools.value = (s.data ?? []) as typeof schools.value;
  admins.value = (a.data ?? []) as Admin[];
  // The organizer signs in with the meet's own code, which is not their admin row.
  me.value =
    admins.value.find((x) => x.code === code) ??
    (info.admin_code === code ? (admins.value.find((x) => x.role === "owner") ?? null) : null);
}

watch(() => session.meetAdminCode, load, { immediate: true });

// --- unlock with existing code ---
function unlock() {
  session.meetAdminCode = adminCodeInput.value.trim().toUpperCase();
  adminCodeInput.value = "";
}

// --- create / delete race ---
const raceName = ref("");
const raceTime = ref("");
const creatingRace = ref(false);
async function createRace() {
  if (!raceName.value.trim() || creatingRace.value || !meetInfo.value) return;
  creatingRace.value = true;
  error.value = "";
  const { error: err } = await client.value.from("races").insert({
    meet_id: meetInfo.value.id,
    name: raceName.value.trim(),
    scheduled_start: raceTime.value ? new Date(raceTime.value).toISOString() : null,
  });
  creatingRace.value = false;
  if (err) {
    error.value = err.message;
    return;
  }
  raceName.value = "";
  raceTime.value = "";
  await load();
}

async function deleteRace(race: { id: string; name: string }) {
  if (!confirm(`Delete "${race.name}"? Its registrations and times go with it.`)) return;
  const { error: err } = await client.value.from("races").delete().eq("id", race.id);
  if (err) error.value = err.message;
  else showToast(`Deleted ${race.name}`);
  await load();
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

const copiedKey = ref("");
function copyText(text: string, key: string) {
  navigator.clipboard.writeText(text);
  copiedKey.value = key;
  setTimeout(() => {
    if (copiedKey.value === key) copiedKey.value = "";
  }, 1500);
}

// --- codes & links ----------------------------------------------------------

type CodeKind = "signup" | "timer";
type CodeState = "idle" | "checking" | "ok" | "format" | "taken";

/** Mirrors the server rules so we can word errors before saving. */
const SHAPE = /^[A-Z0-9]{6}$/;
const BLOCKED_WORDS = /fuck|shit|cunt/i;

const drafts = ref<Record<CodeKind, string>>({ signup: "", timer: "" });
const codeStates = ref<Record<CodeKind, CodeState>>({ signup: "idle", timer: "idle" });
/** True while the draft holds a word the server blocks. */
const blockedDraft = ref<Record<CodeKind, boolean>>({ signup: false, timer: false });
const busyKind = ref<CodeKind | null>(null);

const codeKinds = ["signup", "timer"] as const;
const kindLabel: Record<CodeKind, string> = { signup: "Signup code", timer: "Timer code" };
const kindBlurb: Record<CodeKind, string> = {
  signup: "Registration fallback for posters, bibs and the sign-in table.",
  timer: "Gives any phone at the finish line a stopwatch for this meet.",
};

function draftOf(kind: CodeKind) {
  return normalizeCode(drafts.value[kind]);
}
function currentCode(kind: CodeKind) {
  const m = meetInfo.value;
  if (!m) return "";
  return ((kind === "signup" ? m.signup_code : m.timer_code) ?? "").toUpperCase();
}
function codeHint(kind: CodeKind): string {
  if (codeStates.value[kind] === "format") return "Must be exactly 6 letters or digits.";
  if (blockedDraft.value[kind]) return "Pick a different word — that code contains blocked words.";
  if (codeStates.value[kind] === "taken") return "Another meet already owns that code.";
  return "";
}

const probeTimers = new Map<CodeKind, ReturnType<typeof setTimeout>>();
const probeSeq = new Map<CodeKind, number>();

async function probeCode(kind: CodeKind) {
  const seq = (probeSeq.get(kind) ?? 0) + 1;
  probeSeq.set(kind, seq);
  const c = draftOf(kind);
  blockedDraft.value[kind] = false;
  if (!c) {
    codeStates.value[kind] = "idle";
    return;
  }
  if (!SHAPE.test(c)) {
    codeStates.value[kind] = "format";
    return;
  }
  if (BLOCKED_WORDS.test(c)) {
    // The server refuses blocked words outright; say so without a round trip.
    blockedDraft.value[kind] = true;
    codeStates.value[kind] = "taken";
    return;
  }
  codeStates.value[kind] = "checking";
  const { data, error: err } = await client.value.rpc("check_code_available", {
    p_kind: kind,
    p_code: c,
  });
  if (probeSeq.get(kind) !== seq) return; // the draft moved on
  if (err) {
    console.warn("code check failed:", err.message);
    codeStates.value[kind] = "idle";
    return;
  }
  codeStates.value[kind] = data ? "ok" : "taken";
}

function onDraftInput(kind: CodeKind) {
  const pending = probeTimers.get(kind);
  if (pending) clearTimeout(pending);
  probeTimers.set(
    kind,
    setTimeout(() => void probeCode(kind), 400),
  );
}

function onDraftBlur(kind: CodeKind) {
  const pending = probeTimers.get(kind);
  if (pending) clearTimeout(pending);
  void probeCode(kind);
}

function canSave(kind: CodeKind) {
  const c = draftOf(kind);
  if (!c || codeStates.value[kind] === "format" || codeStates.value[kind] === "taken") return false;
  return c !== currentCode(kind);
}

function explainCodeError(message: string): string {
  if (message.includes("CODE_TAKEN")) return "Another meet already owns that code.";
  if (message.includes("CODE_PROFANE")) return "Pick a different word — that code contains blocked words.";
  if (message.includes("CODE_FORMAT")) return "Must be exactly 6 letters or digits.";
  if (message.includes("NOT_ALLOWED")) return "Your admin code can't change this meet's codes.";
  return message;
}

async function setCode(kind: CodeKind, newCode: string | null) {
  const m = meetInfo.value;
  if (!m || busyKind.value) return;
  busyKind.value = kind;
  error.value = "";
  const { data, error: err } = await client.value.rpc("set_meet_code", {
    p_meet_id: m.id,
    p_kind: kind,
    p_new_code: newCode,
  });
  busyKind.value = null;
  if (err) {
    error.value = explainCodeError(err.message);
    return;
  }
  const next = (data as Record<string, string> | null)?.[kind];
  drafts.value[kind] = "";
  codeStates.value[kind] = "idle";
  showToast(
    newCode
      ? `${kind === "signup" ? "Signup" : "Timer"} code is now ${next ?? newCode}`
      : `New ${kind === "signup" ? "signup" : "timer"} code: ${next ?? ""}`,
  );
  await load();
}

const saveCode = (kind: CodeKind) => setCode(kind, draftOf(kind));
const regenerateCode = (kind: CodeKind) => setCode(kind, null);

interface ShareLink {
  key: string;
  kind: string;
  url: string;
}
const shareLinks = computed<ShareLink[]>(() => {
  const m = meetInfo.value;
  if (!m) return [];
  const o = window.location.origin;
  const out: ShareLink[] = [];
  if (m.code) {
    out.push({ key: "register", kind: "Registration", url: `${o}/j/${m.code}` });
    out.push({ key: "results", kind: "Results", url: `${o}/r/${m.code}` });
  }
  if (m.timer_code) out.push({ key: "timer", kind: "Timer", url: `${o}/t/${m.timer_code}` });
  return out;
});

const showQr = ref(false);
const qrImages = ref<Record<string, string>>({});
async function toggleQr() {
  showQr.value = !showQr.value;
  if (!showQr.value) return;
  for (const link of shareLinks.value) {
    if (qrImages.value[link.key]) continue;
    qrImages.value[link.key] = await QRCode.toDataURL(link.url, {
      margin: 1,
      width: 200,
      color: { dark: "#070c16", light: "#ffffff" },
    });
  }
}

// --- finalize ---------------------------------------------------------------

const confirmFinalize = ref(false);
const finalizing = ref(false);
async function finalizeAll() {
  const m = meetInfo.value;
  if (!m) return;
  finalizing.value = true;
  error.value = "";
  const { data, error: err } = await client.value.rpc("finalize_meet", { p_meet_id: m.id });
  finalizing.value = false;
  confirmFinalize.value = false;
  if (err) {
    error.value = err.message.includes("NOT_ALLOWED")
      ? "Your admin code can't finalize this meet."
      : err.message;
    return;
  }
  const n = (data as { finalized_races?: number } | null)?.finalized_races ?? 0;
  showToast(`Finalized ${n} ${n === 1 ? "race" : "races"} — registration is now locked.`);
  await load();
}

/** "Starts 9:30 AM", or with a date when the race is on another day. */
function startLabel(iso: string): string {
  const d = new Date(iso);
  const time = d.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
  return d.toDateString() === new Date().toDateString()
    ? `Starts ${time}`
    : `${d.toLocaleDateString([], { month: "short", day: "numeric" })} · ${time}`;
}

const lockedLabel = computed(() => {
  const iso = meetInfo.value?.registration_locked_at;
  return iso
    ? new Date(iso).toLocaleString([], { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" })
    : "";
});

const pendingFinalizations = computed(
  () => races.value.filter((r) => r.status !== "finalized").length,
);

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
        <div class="flex flex-wrap items-center gap-2">
          <h1 class="font-display text-3xl font-black tracking-tight">{{ meetInfo.name }}</h1>
          <span
            v-if="locked"
            class="rounded-full bg-violet-500/15 px-2.5 py-1 text-[10px] font-black uppercase tracking-wider text-violet-300"
            title="Registration is closed and every time is frozen"
          >
            Registration locked
          </span>
        </div>
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

      <!-- Codes & links -->
      <section v-if="meetInfo" class="mt-6 rounded-2xl border border-brand-400/25 bg-ink-900 p-5">
        <div class="flex flex-wrap items-center justify-between gap-2">
          <h2 class="text-sm font-black uppercase tracking-wider text-slate-400">Codes & links</h2>
          <button
            class="rounded-lg bg-ink-800 px-3 py-1.5 text-xs font-bold hover:bg-ink-700"
            @click="toggleQr"
          >
            {{ showQr ? "Hide QR codes" : "Show QR codes" }}
          </button>
        </div>
        <p class="mt-1 text-xs text-slate-500">
          Everything a runner or a timer needs. The admin code above stays with you.
        </p>

        <!-- Public meet code: shared by the registration and results links -->
        <div class="mt-4 rounded-xl border border-ink-800 bg-ink-950 p-4">
          <div class="flex items-center justify-between gap-3">
            <p class="text-[10px] font-black uppercase tracking-wider text-slate-500">Meet code</p>
            <button
              class="rounded-lg bg-ink-800 px-2.5 py-1 text-[11px] font-bold hover:bg-ink-700"
              @click="copyText(meetInfo.code ?? '', 'meet')"
            >
              {{ copiedKey === "meet" ? "Copied ✓" : "Copy" }}
            </button>
          </div>
          <p class="mt-1 font-display text-2xl font-black tracking-[0.28em] text-brand-300">
            {{ meetInfo.code ?? "—" }}
          </p>
          <p class="mt-1 text-xs text-slate-500">
            What runners type on the home page; it opens both registration and results.
          </p>
        </div>

        <!-- Signup / timer codes: editable -->
        <div
          v-for="kind in codeKinds"
          :key="kind"
          class="mt-3 rounded-xl border border-ink-800 bg-ink-950 p-4"
        >
          <div class="flex items-center justify-between gap-3">
            <p class="text-[10px] font-black uppercase tracking-wider text-slate-500">
              {{ kindLabel[kind] }}
            </p>
            <button
              class="rounded-lg bg-ink-800 px-2.5 py-1 text-[11px] font-bold hover:bg-ink-700"
              @click="copyText(currentCode(kind), kind)"
            >
              {{ copiedKey === kind ? "Copied ✓" : "Copy" }}
            </button>
          </div>
          <p class="mt-1 font-display text-2xl font-black tracking-[0.28em] text-brand-300">
            {{ currentCode(kind) || "—" }}
          </p>
          <p class="mt-1 text-xs text-slate-500">{{ kindBlurb[kind] }}</p>
          <div class="mt-3 flex flex-wrap items-center gap-2">
            <input
              v-model="drafts[kind]"
              :aria-label="`New ${kindLabel[kind]}`"
              autocapitalize="characters"
              autocomplete="off"
              spellcheck="false"
              maxlength="6"
              :placeholder="currentCode(kind)"
              class="w-36 rounded-lg border bg-ink-900 px-3 py-2 font-display text-sm font-bold uppercase tracking-[0.2em] text-brand-300 placeholder:text-ink-600 focus:outline-none"
              :class="codeHint(kind) ? 'border-red-500/60' : 'border-ink-700 focus:border-brand-400'"
              @input="onDraftInput(kind)"
              @blur="onDraftBlur(kind)"
            />
            <button
              class="rounded-lg bg-brand-400 px-3.5 py-2 text-xs font-black text-ink-950 hover:bg-brand-300 disabled:opacity-40"
              :disabled="busyKind === kind || !canSave(kind)"
              @click="saveCode(kind)"
            >
              {{ busyKind === kind ? "Saving…" : "Save" }}
            </button>
            <button
              class="rounded-lg border border-ink-700 px-3.5 py-2 text-xs font-bold text-slate-300 hover:bg-ink-800 disabled:opacity-40"
              :disabled="busyKind === kind"
              @click="regenerateCode(kind)"
            >
              Regenerate
            </button>
          </div>
          <p
            v-if="codeHint(kind) || codeStates[kind] === 'checking' || codeStates[kind] === 'ok'"
            class="mt-2 text-xs"
            :class="codeHint(kind) ? 'text-red-300' : 'text-brand-300'"
          >
            <template v-if="codeStates[kind] === 'checking'">Checking that code…</template>
            <template v-else-if="codeStates[kind] === 'ok'">{{ draftOf(kind) }} is available.</template>
            <template v-else>{{ codeHint(kind) }}</template>
          </p>
        </div>

        <!-- Share links -->
        <ul class="mt-4 flex flex-col gap-2">
          <li
            v-for="link in shareLinks"
            :key="link.key"
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
              @click="copyText(link.url, link.key)"
            >
              {{ copiedKey === link.key ? "Copied" : "Copy" }}
            </button>
          </li>
        </ul>

        <!-- QR codes for posters and the sign-in table -->
        <div v-if="showQr" class="mt-4 grid gap-3 sm:grid-cols-3">
          <figure
            v-for="link in shareLinks"
            :key="`qr-${link.key}`"
            class="flex flex-col items-center gap-2 rounded-xl bg-white p-3"
          >
            <img
              v-if="qrImages[link.key]"
              :src="qrImages[link.key]"
              :alt="`${link.kind} link QR code`"
              class="size-32"
            />
            <figcaption class="text-center text-[10px] font-black uppercase tracking-wider text-ink-900">
              {{ link.kind }}
            </figcaption>
          </figure>
        </div>
      </section>

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
              @click="copyText(a.code, `admin-${a.code}`)"
            >
              {{ copiedKey === `admin-${a.code}` ? "Copied" : a.code }}
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
        <p class="mt-1 text-xs text-slate-500">
          Timers open the stopwatch with the meet's timer code — one link times every race.
        </p>
        <ul class="mt-3 flex flex-col gap-2">
          <li
            v-for="r in races"
            :key="r.id"
            class="rounded-xl border border-ink-800 bg-ink-900 p-4"
          >
            <div class="flex items-start justify-between gap-3">
              <div class="min-w-0 flex-1">
                <RouterLink :to="`/m/races/${r.id}`" class="block truncate font-bold hover:text-brand-300">
                  {{ r.name }}
                </RouterLink>
                <p class="mt-0.5 text-xs text-slate-500">
                  {{ r.scheduled_start ? startLabel(r.scheduled_start) : "No start time set" }}
                </p>
              </div>
              <span
                class="shrink-0 rounded-full px-2 py-0.5 text-[10px] font-black uppercase tracking-wide"
                :class="statusColors[r.status] ?? 'bg-slate-500/15 text-slate-300'"
              >{{ r.status.replace('_', ' ') }}</span>
            </div>
            <div class="mt-3 flex flex-wrap items-center gap-2">
              <RouterLink
                :to="`/m/races/${r.id}`"
                class="rounded-lg bg-ink-800 px-3 py-1.5 text-xs font-bold hover:bg-ink-700"
              >
                Setup
              </RouterLink>
              <RouterLink
                :to="`/m/races/${r.id}/stickers`"
                class="rounded-lg bg-ink-800 px-3 py-1.5 text-xs font-bold hover:bg-ink-700"
              >
                Stickers
              </RouterLink>
              <RouterLink
                :to="`/m/races/${r.id}/compare`"
                class="rounded-lg bg-ink-800 px-3 py-1.5 text-xs font-bold hover:bg-ink-700"
              >
                Compare
              </RouterLink>
              <button
                class="ml-auto rounded-lg px-3 py-1.5 text-xs font-bold text-slate-500 hover:bg-red-500/15 hover:text-red-300"
                @click="deleteRace(r)"
              >
                Delete
              </button>
            </div>
          </li>
          <li v-if="races.length === 0" class="text-sm text-slate-500">
            No races yet — add the divisions you'll time, oldest format first.
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

      <!-- Finish the meet -->
      <section class="mt-6 rounded-2xl border border-red-500/25 bg-ink-900 p-5">
        <h2 class="text-sm font-black uppercase tracking-wider text-red-300">Finish the meet</h2>
        <p class="mt-1 text-xs text-slate-400">
          Finalizes every race in one move and closes registration for good. Results stay online.
        </p>
        <p v-if="locked" class="mt-3 text-sm text-violet-300">
          Locked {{ lockedLabel }} — registration is closed and all times are frozen.
        </p>
        <button
          v-else
          class="mt-3 rounded-xl border border-red-500/50 bg-red-500/10 px-4 py-2.5 text-sm font-black text-red-300 hover:bg-red-500/20"
          @click="confirmFinalize = true"
        >
          Finalize all results
        </button>
      </section>
      </template>
    </main>

    <!-- Finalize confirmation -->
    <div
      v-if="confirmFinalize"
      class="fixed inset-0 z-50 grid place-items-center bg-ink-950/85 p-5 backdrop-blur-sm"
      role="dialog"
      aria-modal="true"
      aria-labelledby="finalize-title"
    >
      <div class="w-full max-w-md rounded-2xl border border-red-500/30 bg-ink-900 p-6">
        <h2 id="finalize-title" class="font-display text-lg font-black tracking-tight">
          Finalize all results?
        </h2>
        <p class="mt-2 text-sm text-slate-300">
          This locks registration and freezes all times. Continue?
        </p>
        <ul class="mt-3 list-disc space-y-1 pl-5 text-xs text-slate-500">
          <li>{{ pendingFinalizations }} {{ pendingFinalizations === 1 ? "race" : "races" }} move to finalized</li>
          <li>Signup links stop accepting athletes</li>
          <li>Results stay online, read-only</li>
        </ul>
        <div class="mt-5 flex gap-2">
          <button
            class="flex-1 rounded-xl border border-ink-700 py-2.5 text-sm font-bold text-slate-200 hover:bg-ink-800 disabled:opacity-50"
            :disabled="finalizing"
            @click="confirmFinalize = false"
          >
            Cancel
          </button>
          <button
            class="flex-1 rounded-xl bg-red-500 py-2.5 text-sm font-black text-white hover:bg-red-400 disabled:opacity-50"
            :disabled="finalizing"
            @click="finalizeAll"
          >
            {{ finalizing ? "Finalizing…" : "Yes, finalize & lock" }}
          </button>
        </div>
      </div>
    </div>

    <!-- Toast -->
    <div v-if="toast" class="pointer-events-none fixed inset-x-0 bottom-6 z-50 flex justify-center px-5">
      <p class="rounded-full border border-brand-400/30 bg-ink-800/95 px-4 py-2.5 text-sm font-bold text-brand-200 shadow-xl backdrop-blur">
        {{ toast }}
      </p>
    </div>
</template>
