import { defineStore } from "pinia";
import { ref, watch } from "vue";

const KEY = "runxc-session-v2";

interface Persisted {
  meetAdminCode?: string;
  /** Public meet code (results/registration links), remembered for shortcuts. */
  lastMeetCode?: string;
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
  const lastMeetCode = ref(persisted.lastMeetCode ?? "");
  const pendingCount = ref(0);

  watch(
    [meetAdminCode, lastMeetCode],
    () => {
      localStorage.setItem(
        KEY,
        JSON.stringify({
          meetAdminCode: meetAdminCode.value,
          lastMeetCode: lastMeetCode.value,
        } satisfies Persisted),
      );
    },
    { deep: true },
  );

  function rememberMeet(meetCode: string) {
    lastMeetCode.value = meetCode.toUpperCase();
  }

  function forgetMeet() {
    meetAdminCode.value = "";
    lastMeetCode.value = "";
  }

  return { meetAdminCode, lastMeetCode, pendingCount, rememberMeet, forgetMeet };
});
