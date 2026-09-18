-- ============================================
-- POST-INIT: Schema Setup & Trigger Creation
-- ============================================

-- Kurz warten damit Datenbank vollständig bereit ist
SELECT pg_sleep(2);

-- Ensure _realtime schema exists (needed by Supabase Realtime)
CREATE SCHEMA IF NOT EXISTS _realtime AUTHORIZATION supabase_admin;

-- Ensure realtime schema exists (needed by Realtime tenant migrations)
CREATE SCHEMA IF NOT EXISTS realtime AUTHORIZATION supabase_admin;

-- Increase max_connections for Supabase Realtime CDC (takes effect after next restart)
ALTER SYSTEM SET max_connections = 200;

-- Ensure supabase_realtime publication exists (needed for postgres_changes)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
    CREATE PUBLICATION supabase_realtime;
  END IF;
END
$$;

-- Ensure supabase_admin password matches expected value (for existing databases
-- where the init SQL didn't run because the data directory already existed).
-- Use the psql :'new_password' variable (supplied at runtime via -v new_password=$DB_PASSWORD)
-- rather than a baked literal, so this is correct for BOTH the internal DB (password known at
-- build time) AND an injected external DB (password is a runtime parameter).
ALTER ROLE supabase_admin WITH PASSWORD :'new_password';

-- NOTE: handle_new_user(), the on_auth_user_created trigger, and the profile/user_roles
-- backfills that used to live here were APPLICATION schema — they reference public.profiles,
-- public.user_roles and public.user_global_permissions and encode the app's role policy.
-- That is NOT generic Supabase and must not live in this (soon-to-be-packaged) generator.
-- The app's own migrations own them and define the correct "first user = admin, everyone
-- else = 'user'" logic. Re-creating them here on every post_init clobbered that version and
-- (via the 'admin' backfill) re-promoted any role-less user, so the whole block was removed.

SELECT 'Post-Init abgeschlossen' as status;