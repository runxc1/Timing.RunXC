import { createRouter, createWebHistory, type RouteRecordRaw } from "vue-router";

const routes: RouteRecordRaw[] = [
  { path: "/", name: "home", component: () => import("./views/HomeView.vue") },
  {
    path: "/meets/new",
    name: "meet-new",
    component: () => import("./views/MeetCreateView.vue"),
  },

  // --- admin area ----------------------------------------------------------
  // Every meet you administer; pick one to work on.
  { path: "/admin", name: "admin-home", component: () => import("./views/AdminHomeView.vue") },
  // Fixed /admin/races/... routes must be declared before the dynamic
  // /admin/:meetCode so race ids aren't read as meet codes.
  {
    path: "/admin/races/:raceId/stickers",
    name: "stickers",
    component: () => import("./views/Stickers.vue"),
  },
  {
    path: "/admin/races/:raceId/compare",
    name: "compare",
    component: () => import("./views/CompareView.vue"),
    meta: { hideChrome: true },
  },
  {
    path: "/admin/races/:raceId",
    name: "race-setup",
    component: () => import("./views/RaceSetup.vue"),
  },
  {
    path: "/admin/:meetCode",
    name: "meet",
    component: () => import("./views/MeetDashboard.vue"),
  },

  // --- public --------------------------------------------------------------
  {
    path: "/meet/:meetCode/signup",
    name: "register",
    component: () => import("./views/Register.vue"),
    meta: { hideChrome: true },
  },
  {
    path: "/meet/:meetCode",
    name: "results",
    component: () => import("./views/Results.vue"),
    meta: { hideChrome: true },
  },
  {
    path: "/t/:timerCode",
    name: "console",
    component: () => import("./views/TimingConsole.vue"),
    meta: { hideChrome: true },
  },

  // --- legacy links ---------------------------------------------------------
  { path: "/m", redirect: "/admin" },
  {
    path: "/m/races/:raceId/stickers",
    redirect: (to) => `/admin/races/${to.params.raceId}/stickers`,
  },
  {
    path: "/m/races/:raceId/compare",
    redirect: (to) => `/admin/races/${to.params.raceId}/compare`,
  },
  { path: "/m/races/:raceId", redirect: (to) => `/admin/races/${to.params.raceId}` },
  { path: "/signup/:meetCode", redirect: (to) => `/meet/${to.params.meetCode}/signup` },
  {
    // Older printed links used /j/<code>.
    path: "/j/:meetCode",
    redirect: (to) => `/meet/${to.params.meetCode}/signup`,
  },
  { path: "/r/:meetCode", redirect: (to) => `/meet/${to.params.meetCode}` },

  { path: "/:pathMatch(.*)*", redirect: "/" },
];

export const router = createRouter({
  history: createWebHistory(),
  routes,
});
