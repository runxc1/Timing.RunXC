<script setup lang="ts">
import { useOnline } from "@vueuse/core";
import { pendingCount, syncing } from "./lib/sync";

const online = useOnline();
</script>

<template>
  <div class="min-h-screen bg-ink-950 text-slate-100 antialiased">
    <header
      v-if="!$route.meta.hideChrome"
      class="sticky top-0 z-40 border-b border-ink-800 bg-ink-950/90 backdrop-blur"
    >
      <div class="mx-auto flex max-w-3xl items-center gap-3 px-4 py-2.5">
        <RouterLink to="/" class="flex items-center gap-2">
          <span class="grid size-7 place-items-center rounded-lg bg-brand-400 font-black text-ink-950">
            XC
          </span>
          <span class="font-display text-sm font-bold tracking-tight text-brand-300">
            timing.runXC.run
          </span>
        </RouterLink>
        <span
          v-if="!online"
          class="ml-auto rounded-full bg-amber-500/15 px-2.5 py-0.5 text-[11px] font-bold uppercase tracking-wide text-amber-300"
        >
          offline — queued
        </span>
        <span
          v-else-if="syncing || pendingCount > 0"
          class="ml-auto rounded-full bg-brand-400/15 px-2.5 py-0.5 text-[11px] font-bold uppercase tracking-wide text-brand-300"
        >
          syncing…
        </span>
      </div>
    </header>
    <RouterView />
  </div>
</template>
