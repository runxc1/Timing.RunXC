import { createClient, type SupabaseClient } from "@supabase/supabase-js";

/**
 * Env injected by the Aspire AppHost (WithSupabaseVite) in dev, or by the
 * hosting platform in production. Falls back to the local Docker stack.
 */
const url =
  import.meta.env.VITE_SUPABASE_URL ??
  (import.meta.env.DEV ? "http://localhost:8000" : "");

const anonKey =
  import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY ??
  import.meta.env.VITE_SUPABASE_ANON_KEY ??
  // Well-known anon key of the official `supabase start` CLI stack. With
  // `aspire run` this fallback is never used - Aspire injects its own signed
  // key via VITE_SUPABASE_PUBLISHABLE_KEY (see .env.example for how to read it).
  "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoiYW5vbiIsImlzcyI6InN1cGFiYXNlLWRlbW8iLCJpYXQiOjE2NDE3NjkyMDAsImV4cCI6MTc5OTUzNTYwMH0.dc_X5iR_VP_qT0zsiyj_I_OZ2T9FtRU2BBNWN8Bu4GE";

if (!url) {
  console.error(
    "timing.runXC.run: missing VITE_SUPABASE_URL. Run via `aspire run` or set env vars.",
  );
}

export interface AuthHeaders {
  raceCode?: string;
  meetAdminCode?: string;
}

// One client per header set — creating many clients spawns duplicate auth
// instances and warns in the console.
const cache = new Map<string, SupabaseClient>();

export function makeClient(headers: AuthHeaders = {}): SupabaseClient {
  const h: Record<string, string> = {};
  if (headers.raceCode) h["X-Race-Code"] = headers.raceCode;
  if (headers.meetAdminCode) h["X-Meet-Admin-Code"] = headers.meetAdminCode;
  const key = JSON.stringify(h);
  let c = cache.get(key);
  if (!c) {
    c = createClient(url, anonKey, {
      global: { headers: h },
      // Distinct storageKey per client: supabase-js warns (and can thrash
      // storage) when several clients share one auth storage key.
      auth: {
        persistSession: false,
        autoRefreshToken: false,
        storageKey: `runxc-auth-${cache.size}`,
      },
    });
    cache.set(key, c);
  }
  return c;
}

/** Client with no special headers (public reads, race lookup by code). */
export const supabase = makeClient();
