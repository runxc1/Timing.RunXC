-- ============================================
-- SUPABASE INITIALIZATION SCRIPT
-- ============================================

-- 1. Rollen erstellen
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'supabase_admin') THEN
    CREATE ROLE supabase_admin LOGIN PASSWORD 'local-dev-password-123' SUPERUSER CREATEDB CREATEROLE REPLICATION BYPASSRLS;
  ELSE
    ALTER ROLE supabase_admin WITH PASSWORD 'local-dev-password-123';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon NOLOGIN NOINHERIT;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    CREATE ROLE authenticated NOLOGIN NOINHERIT;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    CREATE ROLE service_role NOLOGIN NOINHERIT BYPASSRLS;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticator') THEN
    CREATE ROLE authenticator LOGIN PASSWORD 'local-dev-password-123' NOINHERIT;
  ELSE
    ALTER ROLE authenticator WITH PASSWORD 'local-dev-password-123';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'supabase_auth_admin') THEN
    CREATE ROLE supabase_auth_admin LOGIN PASSWORD 'local-dev-password-123' NOINHERIT CREATEROLE;
  ELSE
    ALTER ROLE supabase_auth_admin WITH PASSWORD 'local-dev-password-123';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'supabase_storage_admin') THEN
    CREATE ROLE supabase_storage_admin LOGIN PASSWORD 'local-dev-password-123' NOINHERIT BYPASSRLS;
  ELSE
    ALTER ROLE supabase_storage_admin WITH PASSWORD 'local-dev-password-123' BYPASSRLS;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dashboard_user') THEN
    CREATE ROLE dashboard_user NOLOGIN;
  END IF;
END
$$;

-- 2. Rollen-Mitgliedschaften
GRANT anon, authenticated, service_role TO authenticator;
GRANT anon, authenticated, service_role TO supabase_storage_admin;
GRANT supabase_auth_admin TO supabase_admin;
GRANT supabase_storage_admin TO supabase_admin;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'postgres') THEN
    EXECUTE 'GRANT supabase_auth_admin TO postgres';
  END IF;
END $$;
GRANT ALL ON DATABASE postgres TO supabase_admin;

-- 3. Schemata erstellen
CREATE SCHEMA IF NOT EXISTS auth AUTHORIZATION supabase_auth_admin;
CREATE SCHEMA IF NOT EXISTS storage AUTHORIZATION supabase_storage_admin;
CREATE SCHEMA IF NOT EXISTS extensions AUTHORIZATION supabase_admin;
CREATE SCHEMA IF NOT EXISTS _realtime AUTHORIZATION supabase_admin;
CREATE SCHEMA IF NOT EXISTS graphql_public;

-- 4. PostgreSQL Konfiguration anpassen
-- Supabase Realtime benötigt viele DB-Verbindungen für CDC (Change Data Capture).
-- Default max_connections=100 ist zu wenig. ALTER SYSTEM wirkt nach dem nächsten Restart.
ALTER SYSTEM SET max_connections = 200;

-- 5. Realtime Publication erstellen (benötigt für postgres_changes)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
    CREATE PUBLICATION supabase_realtime;
  END IF;
END
$$;

-- 6. Extensions installieren
CREATE EXTENSION IF NOT EXISTS "uuid-ossp" SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pgcrypto SCHEMA extensions;

-- 6. Grants für public Schema
GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
GRANT ALL ON SCHEMA public TO supabase_admin, supabase_auth_admin, supabase_storage_admin;
GRANT CREATE ON SCHEMA public TO supabase_auth_admin, supabase_storage_admin;
GRANT ALL ON ALL TABLES IN SCHEMA public TO anon, authenticated, service_role, supabase_auth_admin, supabase_storage_admin;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO anon, authenticated, service_role, supabase_auth_admin, supabase_storage_admin;
GRANT ALL ON ALL FUNCTIONS IN SCHEMA public TO anon, authenticated, service_role;

ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon, authenticated, service_role;

-- 7. Grants für extensions Schema
GRANT USAGE ON SCHEMA extensions TO anon, authenticated, service_role, supabase_admin;
GRANT ALL ON ALL FUNCTIONS IN SCHEMA extensions TO anon, authenticated, service_role;

-- 8. Auth Enums erstellen
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace WHERE n.nspname='auth' AND t.typname='factor_type') THEN
    CREATE TYPE auth.factor_type AS ENUM ('totp', 'webauthn');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace WHERE n.nspname='auth' AND t.typname='factor_status') THEN
    CREATE TYPE auth.factor_status AS ENUM ('unverified', 'verified');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace WHERE n.nspname='auth' AND t.typname='aal_level') THEN
    CREATE TYPE auth.aal_level AS ENUM ('aal1', 'aal2', 'aal3');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace WHERE n.nspname='auth' AND t.typname='code_challenge_method') THEN
    CREATE TYPE auth.code_challenge_method AS ENUM ('s256', 'plain');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace WHERE n.nspname='auth' AND t.typname='one_time_token_type') THEN
    CREATE TYPE auth.one_time_token_type AS ENUM ('confirmation_token', 'reauthentication_token', 'recovery_token', 'email_change_token_new', 'email_change_token_current', 'phone_change_token');
  END IF;
END
$$;

ALTER TYPE auth.factor_type OWNER TO supabase_auth_admin;
ALTER TYPE auth.factor_status OWNER TO supabase_auth_admin;
ALTER TYPE auth.aal_level OWNER TO supabase_auth_admin;
ALTER TYPE auth.code_challenge_method OWNER TO supabase_auth_admin;
ALTER TYPE auth.one_time_token_type OWNER TO supabase_auth_admin;

-- 8. Grants für auth Schema (GoTrue erstellt Tabellen selbst via Migrationen)
GRANT USAGE ON SCHEMA auth TO supabase_auth_admin, supabase_admin, service_role;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'postgres') THEN
    EXECUTE 'GRANT USAGE ON SCHEMA auth TO postgres';
  END IF;
END $$;
GRANT ALL ON ALL TABLES IN SCHEMA auth TO supabase_auth_admin, supabase_admin;
GRANT ALL ON ALL SEQUENCES IN SCHEMA auth TO supabase_auth_admin, supabase_admin;

-- 9. Grants für storage Schema
GRANT USAGE ON SCHEMA storage TO supabase_storage_admin, supabase_admin, authenticated, anon, service_role;
GRANT ALL ON ALL TABLES IN SCHEMA storage TO supabase_storage_admin, supabase_admin, service_role;
GRANT SELECT ON ALL TABLES IN SCHEMA storage TO authenticated, anon;
GRANT ALL ON ALL SEQUENCES IN SCHEMA storage TO supabase_storage_admin, supabase_admin, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA storage GRANT ALL ON TABLES TO service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA storage GRANT ALL ON SEQUENCES TO service_role;

-- 10. Storage Tabellen
-- NOTE: Storage tables are NOT created here. The storage-api container runs its own
-- migrations at startup which create and update the tables with the correct schema.
-- Creating tables here would cause schema mismatches with newer storage-api versions.

-- 11. RLS für Storage aktivieren
ALTER TABLE storage.buckets ENABLE ROW LEVEL SECURITY;
ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Public buckets are viewable by everyone" ON storage.buckets;
CREATE POLICY "Public buckets are viewable by everyone"
    ON storage.buckets FOR SELECT USING (public = true);

DROP POLICY IF EXISTS "Objects in public buckets are viewable by everyone" ON storage.objects;
CREATE POLICY "Objects in public buckets are viewable by everyone"
    ON storage.objects FOR SELECT
    USING (bucket_id IN (SELECT id FROM storage.buckets WHERE public = true));

DROP POLICY IF EXISTS "Service role has full access to buckets" ON storage.buckets;
CREATE POLICY "Service role has full access to buckets"
    ON storage.buckets FOR ALL TO service_role
    USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "Service role has full access to objects" ON storage.objects;
CREATE POLICY "Service role has full access to objects"
    ON storage.objects FOR ALL TO service_role
    USING (true) WITH CHECK (true);

-- Dev-Mode: Allow all für Storage (anon und authenticated)
DROP POLICY IF EXISTS "Allow all for development" ON storage.buckets;
CREATE POLICY "Allow all for development"
    ON storage.buckets FOR ALL
    USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "Allow all for development" ON storage.objects;
CREATE POLICY "Allow all for development"
    ON storage.objects FOR ALL
    USING (true) WITH CHECK (true);

GRANT ALL ON storage.buckets TO anon, authenticated;
GRANT ALL ON storage.objects TO anon, authenticated;

-- 12. Search Path für PostgREST
ALTER DATABASE postgres SET search_path TO public, extensions;

-- 13. Schema Reload Trigger
CREATE OR REPLACE FUNCTION extensions.notify_api_restart()
RETURNS event_trigger LANGUAGE plpgsql AS $$
BEGIN
    NOTIFY pgrst, 'reload schema';
END;
$$;

DROP EVENT TRIGGER IF EXISTS api_restart;
CREATE EVENT TRIGGER api_restart ON ddl_command_end
    EXECUTE FUNCTION extensions.notify_api_restart();

-- 14. (removed) handle_new_user() + on_auth_user_created trigger.
-- These were APPLICATION schema (public.profiles / public.user_roles / role policy), not
-- generic Supabase, so they were moved out of this generator. The app's migrations own the
-- profiles table, the handle_new_user trigger function and the on_auth_user_created trigger,
-- with the correct "first user = admin, everyone else = 'user'" logic.