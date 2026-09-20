import { createRouter, createWebHistory } from "vue-router";

export const router = createRouter({
  history: createWebHistory(),
  routes: [
    { path: "/", name: "home", component: () => import("./views/HomeView.vue") },
    {
      path: "/meets/new",
      name: "meet-new",
      component: () => import("./views/MeetCreateView.vue"),
    },
    {
      path: "/m",
      name: "meet",
      component: () => import("./views/MeetDashboard.vue"),
    },
    {
      path: "/m/races/:raceId",
      name: "race-setup",
      component: () => import("./views/RaceSetup.vue"),
    },
    {
      path: "/m/races/:raceId/stickers",
      name: "stickers",
      component: () => import("./views/Stickers.vue"),
    },
    {
      path: "/signup/:meetCode",
      name: "register",
      component: () => import("./views/Register.vue"),
      meta: { hideChrome: true },
    },
    {
      // Older printed links used /j/<code>.
      path: "/j/:meetCode",
      redirect: (to) => `/signup/${to.params.meetCode}`,
    },
    {
      path: "/t/:timerCode",
      name: "console",
      component: () => import("./views/TimingConsole.vue"),
      meta: { hideChrome: true },
    },
    {
      path: "/r/:meetCode",
      name: "results",
      component: () => import("./views/Results.vue"),
      meta: { hideChrome: true },
    },
    {
      path: "/m/races/:raceId/compare",
      name: "compare",
      component: () => import("./views/CompareView.vue"),
      meta: { hideChrome: true },
    },
    { path: "/:pathMatch(.*)*", redirect: "/" },
  ],
});
