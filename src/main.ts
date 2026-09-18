import { createApp } from "vue";
import { createPinia } from "pinia";
import App from "./App.vue";
// Side-effect import: restores GitHub Pages 404-fallback deep links. Keep it
// above ./router so the history rewrite happens before the router is created.
import "./lib/spaFallback";
import { router } from "./router";
import { registerSW } from "virtual:pwa-register";
import { startSync } from "./lib/sync";
import "./style.css";

const updateSW = registerSW({
  onNeedRefresh() {
    // Auto-apply updates; the finish console guards against losing the
    // queue because everything lives in IndexedDB.
    updateSW(true);
  },
});

startSync();

createApp(App).use(createPinia()).use(router).mount("#app");
