import { liveQuery } from "dexie";
import { onScopeDispose, ref, watchEffect, type Ref } from "vue";

/**
 * Vue binding for Dexie liveQuery (dexie-react-hooks equivalent).
 *
 * Dexie runs `querier` asynchronously, so Vue refs read *inside* it are not
 * tracked by the surrounding watchEffect. Pass those deps via `deps` (read
 * synchronously here) so the subscription is re-created when they change.
 */
export function useLiveQuery<T>(
  querier: () => Promise<T> | T,
  defaultValue = null as unknown as T,
  deps?: () => unknown,
): Ref<T> {
  const value = ref(defaultValue) as Ref<T>;
  let sub: { unsubscribe: () => void } | null = null;

  watchEffect(() => {
    sub?.unsubscribe();
    if (deps) deps();
    sub = liveQuery<T>(querier).subscribe({
      next: (v) => (value.value = v),
      error: (e) => console.error("liveQuery", e),
    });
  });

  onScopeDispose(() => sub?.unsubscribe());
  return value;
}
