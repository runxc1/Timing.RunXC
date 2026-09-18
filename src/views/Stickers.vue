<script setup lang="ts">
import { computed, ref, watchEffect } from "vue";
import { useRoute } from "vue-router";
import QRCode from "qrcode";
import { makeClient } from "../lib/supabase";
import { useSession } from "../stores/session";

const route = useRoute();
const session = useSession();
const raceId = computed(() => String(route.params.raceId));

interface Sticker {
  id: string;
  code: string;
  label: string;
}

const raceName = ref("");
const stickers = ref<Sticker[]>([]);
const qrCache = new Map<string, string>();
const error = ref("");
const onlyRegistered = ref(true);

const admin = computed(() => makeClient({ meetAdminCode: session.meetAdminCode || undefined }));

async function qrDataUrl(code: string): Promise<string> {
  const hit = qrCache.get(code);
  if (hit) return hit;
  const url = await QRCode.toDataURL(code, {
    margin: 1,
    width: 160,
    color: { dark: "#000000", light: "#ffffff" },
  });
  qrCache.set(code, url);
  return url;
}

const rendered = ref<Array<Sticker & { qr: string }>>([]);

watchEffect(async () => {
  if (!session.meetAdminCode) return;
  const [r, a] = await Promise.all([
    admin.value.from("races").select("name").eq("id", raceId.value).maybeSingle(),
    admin.value
      .from("athletes")
      .select("id, code, name")
      .eq("race_id", raceId.value)
      .order("code"),
  ]);
  raceName.value = (r.data as { name: string } | null)?.name ?? "";
  const rows = ((a.data ?? []) as Array<{ id: string; code: string; name: string | null }>)
    .filter((x) => (onlyRegistered.value ? x.name !== null : true));
  stickers.value = rows.map((x) => ({
    id: x.id,
    code: x.code,
    label: x.name ?? "(unassigned)",
  }));
  rendered.value = await Promise.all(
    stickers.value.map(async (s) => ({ ...s, qr: await qrDataUrl(s.code) })),
  );
});

function print() {
  window.print();
}
</script>

<template>
  <main class="mx-auto max-w-3xl px-5 py-8">
    <div class="screen-only flex items-center justify-between">
      <div>
        <RouterLink :to="`/m/races/${raceId}`" class="text-xs font-bold text-slate-500 hover:text-slate-300">← Race</RouterLink>
        <h1 class="mt-1 font-display text-2xl font-black tracking-tight">
          Stickers — {{ raceName }}
        </h1>
        <p class="mt-1 text-sm text-slate-400">
          {{ rendered.length }} stickers. Each QR encodes the 6-character code.
        </p>
      </div>
      <div class="flex items-center gap-3">
        <label class="flex items-center gap-2 text-sm text-slate-300">
          <input v-model="onlyRegistered" type="checkbox" class="accent-lime-400" />
          Registered only
        </label>
        <button
          class="rounded-xl bg-brand-400 px-5 py-2.5 text-sm font-black text-ink-950 hover:bg-brand-300"
          @click="print"
        >
          Print
        </button>
      </div>
    </div>
    <p v-if="error" class="mt-3 text-sm text-red-300">{{ error }}</p>

    <div id="print-area" class="mt-6">
      <h2 class="mb-3 hidden text-lg font-black print:block">{{ raceName }} — finish codes</h2>
      <div class="grid grid-cols-2 gap-3 sm:grid-cols-3 print:grid-cols-3 print:gap-1">
        <div
          v-for="s in rendered"
          :key="s.id"
          class="flex items-center gap-3 rounded-xl border border-ink-800 bg-white p-3 print:rounded-none print:border print:border-gray-300 print:p-1.5"
        >
          <img :src="s.qr" :alt="s.code" class="size-16 print:size-12" />
          <div class="min-w-0">
            <p class="font-display text-lg font-black tracking-[0.15em] text-black">{{ s.code }}</p>
            <p class="truncate text-xs text-gray-600">{{ s.label }}</p>
          </div>
        </div>
      </div>
      <p v-if="rendered.length === 0" class="text-sm text-slate-500">
        Nothing to print yet — register athletes or include unassigned codes.
      </p>
    </div>
  </main>
</template>

<style scoped>
@media print {
  .screen-only {
    display: none !important;
  }
}
</style>
