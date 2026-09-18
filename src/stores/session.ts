import { defineStore } from "pinia";
import { ref, watch } from "vue";

const KEY = "runxc-session-v1";

interface Persisted {
  meetAdminCode?: string;
  /** raceId -> race code, remembered for console/results shortcuts. */
  raceCodes?: Record<string, string>;
  lastRaceId?: string;
}

function load(): Persisted {
  try {
    return JSON.parse(localStorage.getItem(KEY) ?? "{}") as Persisted;
  } catch {
    return {};
  }
}

export const useSession = defineStore("session", () => {
  const persisted = load();
  const meetAdminCode = ref(persisted.meetAdminCode ?? "");
  const raceCodes = ref<Record<string, string>>(persisted.raceCodes ?? {});
  const lastRaceId = ref(persisted.lastRaceId ?? "");
  const pendingCount = ref(0);

  watch(
    [meetAdminCode, raceCodes, lastRaceId],
    () => {
      localStorage.setItem(
        KEY,
        JSON.stringify({
          meetAdminCode: meetAdminCode.value,
          raceCodes: raceCodes.value,
          lastRaceId: lastRaceId.value,
        } satisfies Persisted),
      );
    },
    { deep: true },
  );

  function rememberRace(raceId: string, code: string) {
    raceCodes.value[raceId] = code.toUpperCase();
    lastRaceId.value = raceId;
  }

  function forgetMeet() {
    meetAdminCode.value = "";
    raceCodes.value = {};
    lastRaceId.value = "";
  }

  return { meetAdminCode, raceCodes, lastRaceId, pendingCount, rememberRace, forgetMeet };
});
