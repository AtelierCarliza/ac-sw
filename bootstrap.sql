-- ============================================================================
-- AC Studio — Supabase bootstrap
-- Project: ac-platform  (https://qqkgtjfurjepaaglxohq.supabase.co)
--
-- Run this ONCE in Supabase SQL Editor against a fresh project, top to bottom.
-- Idempotent: uses CREATE TABLE IF NOT EXISTS so safe to re-run.
--
-- Sections:
--   1. Tables  (profiles, requests, app_access, access_requests, activity_log,
--               anthropic_token_costs, user_settings)
--   2. AC-specific columns on requests (handover_html, runtime_kind, etc.)
--   3. Auto-profile trigger on first sign-in
--   4. SECURITY DEFINER helper functions (is_admin, has_app_access)
--   5. RLS policies
--   6. Pricing seed data
--   7. Admin bootstrap reminder (manual step after first sign-in)
-- ============================================================================


-- ─── 1. profiles ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.profiles (
  id            uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email         text,
  full_name     text,
  avatar_url    text,
  provider      text,
  is_admin      boolean NOT NULL DEFAULT false,
  created_at    timestamptz NOT NULL DEFAULT now()
);


-- ─── 2. requests (with AC-specific columns) ─────────────────────────────────
CREATE TABLE IF NOT EXISTS public.requests (
  id                          uuid PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Submission metadata
  title                       text NOT NULL,
  goal                        text,
  users                       text,
  scope                       text,
  constraints                 text,
  mvp                         text,
  mode                        text,
  capabilities                jsonb,
  conversation                jsonb,
  stories                     jsonb,
  domain_brief                jsonb,

  -- Ownership / access
  creator_user_id             uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  submitted_by                text,
  creator_access_revoked      boolean NOT NULL DEFAULT false,

  -- Lifecycle (visibility in Intent)
  lifecycle_status            text NOT NULL DEFAULT 'parked'
                                CHECK (lifecycle_status IN ('active','parked','archived')),

  -- Build / QA pipeline
  status                      text DEFAULT 'pending',
  qa_status                   text,
  qa_notes                    text,
  qa_attachments              jsonb,
  needs_input                 boolean NOT NULL DEFAULT false,
  needs_input_notes           text,

  -- Rejection
  rejected_reason             text,
  rejected_by                 text,
  rejected_at                 timestamptz,

  -- Build artifact
  artifact_html               text,
  artifact_version            integer DEFAULT 0,
  artifacts                   jsonb DEFAULT '[]'::jsonb,

  -- Deployment
  shipped_url                 text,
  shipped_filename            text,
  shipped_at                  timestamptz,

  -- ── AC-specific additions ──
  -- Runtime classification: static (GitHub Pages) vs python_backend (needs ac-launcher)
  runtime_kind                text DEFAULT 'static_html'
                                CHECK (runtime_kind IN ('static_html','python_backend','external')),
  -- ID the local launcher uses to address this tool (e.g. 'layerforge')
  launcher_id                 text,
  -- Expected localhost port when the python backend is running
  expected_port               integer,
  -- Historical AIOps handover content: epic, evolution, HD files, context/history
  -- Migrated from /Software development and bug fixing tracking/
  handover_html               text,
  handover_notes              text,

  created_at                  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_requests_creator_user ON public.requests(creator_user_id);
CREATE INDEX IF NOT EXISTS idx_requests_lifecycle    ON public.requests(lifecycle_status);
CREATE INDEX IF NOT EXISTS idx_requests_status       ON public.requests(status);
CREATE INDEX IF NOT EXISTS idx_requests_runtime      ON public.requests(runtime_kind);
CREATE INDEX IF NOT EXISTS idx_requests_launcher     ON public.requests(launcher_id) WHERE launcher_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_requests_shipped_url  ON public.requests(shipped_url) WHERE shipped_url IS NOT NULL;


-- ─── 3. app_access ──────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.app_access (
  request_id   uuid NOT NULL REFERENCES public.requests(id) ON DELETE CASCADE,
  user_id      uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  granted_by   uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  granted_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (request_id, user_id)
);
CREATE INDEX IF NOT EXISTS idx_app_access_user ON public.app_access(user_id);


-- ─── 4. access_requests ─────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.access_requests (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id    uuid NOT NULL REFERENCES public.requests(id) ON DELETE CASCADE,
  user_id       uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  status        text NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending','approved','denied')),
  notes         text,
  requested_at  timestamptz NOT NULL DEFAULT now(),
  resolved_by   uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  resolved_at   timestamptz,
  UNIQUE (request_id, user_id, status)
);
CREATE INDEX IF NOT EXISTS idx_access_requests_status ON public.access_requests(status);
CREATE INDEX IF NOT EXISTS idx_access_requests_user   ON public.access_requests(user_id);


-- ─── 5. activity_log ────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.activity_log (
  id             bigserial PRIMARY KEY,
  request_id     uuid REFERENCES public.requests(id) ON DELETE CASCADE,
  actor          text,
  actor_name     text,
  action         text NOT NULL,
  description    text,
  metadata       jsonb,
  created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_activity_request ON public.activity_log(request_id);
CREATE INDEX IF NOT EXISTS idx_activity_created ON public.activity_log(created_at DESC);


-- ─── 6. anthropic_token_costs ───────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.anthropic_token_costs (
  model               text PRIMARY KEY,
  input_per_million   numeric NOT NULL,
  output_per_million  numeric NOT NULL,
  updated_at          timestamptz NOT NULL DEFAULT now()
);
INSERT INTO public.anthropic_token_costs (model, input_per_million, output_per_million) VALUES
  ('claude-opus-4-7',           15.00, 75.00),
  ('claude-sonnet-4-6',          3.00, 15.00),
  ('claude-sonnet-4-5-20250929', 3.00, 15.00),
  ('claude-haiku-4-5-20251001',  1.00,  5.00)
ON CONFLICT (model) DO UPDATE SET
  input_per_million = EXCLUDED.input_per_million,
  output_per_million = EXCLUDED.output_per_million,
  updated_at = now();


-- ─── 7. user_settings ───────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.user_settings (
  user_id     uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  settings    jsonb NOT NULL DEFAULT '{}'::jsonb,
  updated_at  timestamptz NOT NULL DEFAULT now()
);


-- ============================================================================
-- Triggers
-- ============================================================================

-- Auto-create a profile row when a new auth.user appears (first sign-in).
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  INSERT INTO public.profiles (id, email, full_name, avatar_url, provider)
  VALUES (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'name'),
    new.raw_user_meta_data->>'avatar_url',
    coalesce(new.raw_app_meta_data->>'provider', 'unknown')
  )
  ON CONFLICT (id) DO UPDATE SET
    email = EXCLUDED.email,
    full_name = coalesce(EXCLUDED.full_name, public.profiles.full_name),
    avatar_url = coalesce(EXCLUDED.avatar_url, public.profiles.avatar_url),
    provider = coalesce(EXCLUDED.provider, public.profiles.provider);
  RETURN new;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT OR UPDATE ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();


-- ============================================================================
-- SECURITY DEFINER helpers (avoid RLS recursion on profiles)
-- ============================================================================

CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public AS $$
  SELECT coalesce(
    (SELECT is_admin FROM public.profiles WHERE id = auth.uid()),
    false
  );
$$;

CREATE OR REPLACE FUNCTION public.has_app_access(req_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public AS $$
  SELECT
    public.is_admin()
    OR EXISTS (
      SELECT 1 FROM public.requests
       WHERE id = req_id
         AND creator_user_id = auth.uid()
         AND coalesce(creator_access_revoked, false) = false
    )
    OR EXISTS (
      SELECT 1 FROM public.app_access
       WHERE request_id = req_id AND user_id = auth.uid()
    );
$$;


-- ============================================================================
-- Row-level security
-- ============================================================================

ALTER TABLE public.profiles              ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.requests              ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.app_access            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.access_requests       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.activity_log          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.anthropic_token_costs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_settings         ENABLE ROW LEVEL SECURITY;

-- profiles
DROP POLICY IF EXISTS profiles_read   ON public.profiles;
DROP POLICY IF EXISTS profiles_update ON public.profiles;
CREATE POLICY profiles_read ON public.profiles
  FOR SELECT TO authenticated USING (true);
CREATE POLICY profiles_update ON public.profiles
  FOR UPDATE TO authenticated
  USING (id = auth.uid() OR public.is_admin())
  WITH CHECK (id = auth.uid() OR public.is_admin());

-- requests
DROP POLICY IF EXISTS requests_read   ON public.requests;
DROP POLICY IF EXISTS requests_insert ON public.requests;
DROP POLICY IF EXISTS requests_update ON public.requests;
DROP POLICY IF EXISTS requests_delete ON public.requests;
CREATE POLICY requests_read ON public.requests
  FOR SELECT TO authenticated USING (true);
CREATE POLICY requests_insert ON public.requests
  FOR INSERT TO authenticated
  WITH CHECK (creator_user_id = auth.uid() OR public.is_admin());
CREATE POLICY requests_update ON public.requests
  FOR UPDATE TO authenticated
  USING (public.is_admin())
  WITH CHECK (public.is_admin());
CREATE POLICY requests_delete ON public.requests
  FOR DELETE TO authenticated
  USING (public.is_admin());

-- app_access
DROP POLICY IF EXISTS app_access_read    ON public.app_access;
DROP POLICY IF EXISTS app_access_write   ON public.app_access;
DROP POLICY IF EXISTS app_access_update  ON public.app_access;
DROP POLICY IF EXISTS app_access_delete  ON public.app_access;
CREATE POLICY app_access_read ON public.app_access
  FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR public.is_admin());
CREATE POLICY app_access_write ON public.app_access
  FOR INSERT TO authenticated WITH CHECK (public.is_admin());
CREATE POLICY app_access_update ON public.app_access
  FOR UPDATE TO authenticated
  USING (public.is_admin()) WITH CHECK (public.is_admin());
CREATE POLICY app_access_delete ON public.app_access
  FOR DELETE TO authenticated USING (public.is_admin());

-- access_requests
DROP POLICY IF EXISTS access_req_insert ON public.access_requests;
DROP POLICY IF EXISTS access_req_read   ON public.access_requests;
DROP POLICY IF EXISTS access_req_update ON public.access_requests;
DROP POLICY IF EXISTS access_req_delete ON public.access_requests;
CREATE POLICY access_req_insert ON public.access_requests
  FOR INSERT TO authenticated
  WITH CHECK (user_id = auth.uid() AND status = 'pending');
CREATE POLICY access_req_read ON public.access_requests
  FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR public.is_admin());
CREATE POLICY access_req_update ON public.access_requests
  FOR UPDATE TO authenticated
  USING (public.is_admin()) WITH CHECK (public.is_admin());
CREATE POLICY access_req_delete ON public.access_requests
  FOR DELETE TO authenticated USING (public.is_admin());

-- activity_log
DROP POLICY IF EXISTS activity_read   ON public.activity_log;
DROP POLICY IF EXISTS activity_insert ON public.activity_log;
CREATE POLICY activity_read ON public.activity_log
  FOR SELECT TO authenticated
  USING (
    public.is_admin()
    OR (request_id IS NOT NULL AND public.has_app_access(request_id))
  );
CREATE POLICY activity_insert ON public.activity_log
  FOR INSERT TO authenticated WITH CHECK (true);

-- anthropic_token_costs
DROP POLICY IF EXISTS costs_read   ON public.anthropic_token_costs;
DROP POLICY IF EXISTS costs_write  ON public.anthropic_token_costs;
CREATE POLICY costs_read ON public.anthropic_token_costs
  FOR SELECT TO authenticated USING (true);
CREATE POLICY costs_write ON public.anthropic_token_costs
  FOR ALL TO authenticated
  USING (public.is_admin()) WITH CHECK (public.is_admin());

-- user_settings
DROP POLICY IF EXISTS user_settings_self ON public.user_settings;
CREATE POLICY user_settings_self ON public.user_settings
  FOR ALL TO authenticated
  USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());


-- ============================================================================
-- POST-BOOTSTRAP MANUAL STEP (after first sign-in via AC_Intent)
-- ============================================================================
-- Sign in to AC_Intent.html with your @ateliercarliza.com Google account first.
-- That creates your profile row via the trigger above. THEN run this in SQL Editor:
--
--     UPDATE public.profiles
--     SET is_admin = true
--     WHERE email = 'philip@ateliercarliza.com';   -- replace with your actual email
--
-- After that, reload AC_Intent — the gate reveals and you have full admin access.
-- ============================================================================
