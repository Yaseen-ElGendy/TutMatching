-- Stand-ins for the pieces Supabase provides, so the tests run on plain Postgres.
DO $$ BEGIN
 IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon NOLOGIN; END IF;
 IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated NOLOGIN; END IF;
 IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role') THEN CREATE ROLE service_role NOLOGIN BYPASSRLS; END IF;
END $$;
GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
-- Supabase default: new tables/functions in public are open to these roles (the migrations must close them)
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO anon, authenticated, service_role;

-- auth.users / auth.uid() like Supabase Auth
CREATE SCHEMA IF NOT EXISTS auth;
CREATE TABLE IF NOT EXISTS auth.users (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), email TEXT);
CREATE OR REPLACE FUNCTION auth.uid() RETURNS UUID LANGUAGE sql STABLE AS
  $$ SELECT nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
GRANT USAGE ON SCHEMA auth TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION auth.uid() TO anon, authenticated, service_role;

-- pg_net stand-in: records the calls the notification trigger makes
CREATE SCHEMA IF NOT EXISTS net;
CREATE TABLE IF NOT EXISTS net.calls (url TEXT, body JSONB, at TIMESTAMPTZ DEFAULT now());
CREATE OR REPLACE FUNCTION net.http_post(url TEXT, body JSONB, headers JSONB) RETURNS BIGINT
LANGUAGE plpgsql AS $$
BEGIN
  IF current_setting('app.net_fail', true) = '1' THEN RAISE EXCEPTION 'net down'; END IF;
  INSERT INTO net.calls (url, body) VALUES (url, body);
  RETURN 1;
END $$;

-- assertion helper used by every test file
CREATE OR REPLACE FUNCTION public.t_assert(ok BOOLEAN, msg TEXT) RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  IF ok IS NOT TRUE THEN RAISE EXCEPTION 'FAIL: %', msg; END IF;
  RAISE NOTICE 'PASS: %', msg;
END $$;
GRANT EXECUTE ON FUNCTION public.t_assert(BOOLEAN, TEXT) TO PUBLIC;

-- expects the statement to be refused for lack of permission
CREATE OR REPLACE FUNCTION public.t_denied(q TEXT, msg TEXT) RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE q;
  RAISE EXCEPTION 'FAIL: % (it was allowed)', msg;
EXCEPTION WHEN insufficient_privilege THEN
  RAISE NOTICE 'PASS: %', msg;
END $$;
GRANT EXECUTE ON FUNCTION public.t_denied(TEXT, TEXT) TO PUBLIC;
