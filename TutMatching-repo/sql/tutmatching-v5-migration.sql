-- ============================================================
-- TutMatching v5: private database + cancel + WhatsApp username
-- Run this ENTIRE file ONCE in the Supabase SQL Editor.
-- Safe to re-run. Run it BEFORE you deploy the new index.html.
--
-- After this, the public (anon) key can NOT read or write any table.
-- The website can only call 3 functions, and every one of them
-- needs your Student ID + GUC email together.
-- ============================================================

-- ===== 0. Tidy up anything left over from older versions =====

-- Remove every old policy on our tables (old ones allowed public read)
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT schemaname, tablename, policyname FROM pg_policies
           WHERE schemaname = 'public'
             AND tablename IN ('submissions','matches','match_contacts','notifications')
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON %I.%I', r.policyname, r.schemaname, r.tablename);
  END LOOP;
END $$;

-- Remove old functions (they returned other students' emails to anyone who called them)
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT p.oid, p.proname, pg_get_function_identity_arguments(p.oid) AS args
           FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
           WHERE n.nspname = 'public'
             AND p.proname IN ('match_submission','attempt_match','find_chain_match',
                               'submit_request','check_status','cancel_request',
                               'claim_notification','finish_notification','release_notification',
                               '_find_match')
  LOOP
    EXECUTE format('DROP FUNCTION IF EXISTS public.%I(%s) CASCADE', r.proname, r.args);
  END LOOP;
END $$;

-- match_contacts is no longer needed: partner details are read from submissions
DROP TABLE IF EXISTS match_contacts CASCADE;

-- Columns from the abandoned login / phone attempt
ALTER TABLE submissions DROP COLUMN IF EXISTS user_id CASCADE;
ALTER TABLE submissions DROP COLUMN IF EXISTS phone;

-- ===== 1. submissions: columns, status values, uniqueness =====

ALTER TABLE submissions ADD COLUMN IF NOT EXISTS email TEXT;
ALTER TABLE submissions ADD COLUMN IF NOT EXISTS whatsapp TEXT;

UPDATE submissions SET email = lower(trim(email)) WHERE email IS NOT NULL;

-- If status is an enum, turn it into plain text so 'cancelled' is allowed
DO $$
BEGIN
  IF (SELECT data_type FROM information_schema.columns
      WHERE table_schema='public' AND table_name='submissions' AND column_name='status') = 'USER-DEFINED' THEN
    ALTER TABLE submissions ALTER COLUMN status DROP DEFAULT;
    ALTER TABLE submissions ALTER COLUMN status TYPE text USING status::text;
  END IF;
END $$;
ALTER TABLE submissions ALTER COLUMN status SET DEFAULT 'waiting';
UPDATE submissions SET status = 'waiting' WHERE status IS NULL;

-- Drop any old CHECK on status, then add ours (waiting / matched / cancelled)
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT conname FROM pg_constraint
           WHERE conrelid = 'public.submissions'::regclass AND contype = 'c'
             AND pg_get_constraintdef(oid) ILIKE '%status%'
  LOOP
    EXECUTE format('ALTER TABLE submissions DROP CONSTRAINT %I', r.conname);
  END LOOP;
END $$;
ALTER TABLE submissions
  ADD CONSTRAINT submissions_status_check CHECK (status IN ('waiting','matched','cancelled'));

-- Drop old UNIQUE rules (they would block re-submitting after a cancel)
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT conname FROM pg_constraint
           WHERE conrelid = 'public.submissions'::regclass AND contype = 'u'
  LOOP
    EXECUTE format('ALTER TABLE submissions DROP CONSTRAINT %I', r.conname);
  END LOOP;
  FOR r IN SELECT c.relname FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
           WHERE i.indrelid = 'public.submissions'::regclass
             AND i.indisunique AND NOT i.indisprimary
  LOOP
    EXECUTE format('DROP INDEX IF EXISTS %I', r.relname);
  END LOOP;
END $$;

-- Refuse to continue if leftover test data would break the new rules
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM submissions WHERE status IN ('waiting','matched')
             GROUP BY student_id HAVING count(*) > 1)
  OR EXISTS (SELECT 1 FROM submissions WHERE status IN ('waiting','matched')
             GROUP BY lower(email) HAVING count(*) > 1) THEN
    RAISE EXCEPTION 'Duplicate active requests found. Run clear-test-data.sql first, then run this file again.';
  END IF;
END $$;

-- One ACTIVE request per student ID and per email (cancelled ones don't count)
CREATE UNIQUE INDEX submissions_one_active_per_id
  ON submissions (student_id) WHERE status IN ('waiting','matched');
CREATE UNIQUE INDEX submissions_one_active_per_email
  ON submissions (lower(email)) WHERE status IN ('waiting','matched');
CREATE INDEX IF NOT EXISTS idx_submissions_status ON submissions (status);

-- ===== 2. notifications: private queue of emails to send =====
-- The email function looks the recipient up here, so the website can never
-- tell it "send this to some arbitrary address", and each email goes out once.

CREATE TABLE IF NOT EXISTS notifications (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  kind TEXT NOT NULL CHECK (kind IN ('matched','cancelled')),
  recipient_email TEXT NOT NULL,
  your_tut TEXT,
  partner_tut TEXT,
  partner_student_id TEXT,
  partner_email TEXT,
  partner_whatsapp TEXT,
  coordinator_needed BOOLEAN NOT NULL DEFAULT FALSE,
  rematched BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  claimed_at TIMESTAMPTZ,
  sent_at TIMESTAMPTZ
);

-- (for databases that already have the table from an earlier run)
ALTER TABLE notifications ADD COLUMN IF NOT EXISTS partner_student_id TEXT;
ALTER TABLE notifications ADD COLUMN IF NOT EXISTS partner_email TEXT;
ALTER TABLE notifications ADD COLUMN IF NOT EXISTS partner_whatsapp TEXT;

-- ===== 3. Lock the tables down =====
ALTER TABLE submissions   ENABLE ROW LEVEL SECURITY;
ALTER TABLE matches       ENABLE ROW LEVEL SECURITY;
ALTER TABLE notifications ENABLE ROW LEVEL SECURITY;
-- No policies at all = nobody using the public key can touch these tables.

REVOKE ALL ON submissions, matches, notifications FROM PUBLIC, anon, authenticated;

-- ===== 4. Internal matching (not callable from the website) =====
-- Caller must already hold the advisory lock.
CREATE FUNCTION public._find_match(p_sub UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_new   submissions%ROWTYPE;
  v_cand  submissions%ROWTYPE;
  v_coord BOOLEAN;
  v_mid   UUID;
  v_nid   UUID;
BEGIN
  SELECT * INTO v_new FROM submissions WHERE id = p_sub AND status = 'waiting';
  IF NOT FOUND THEN
    RETURN jsonb_build_object('matched', false);
  END IF;

  -- Oldest waiting request first (first come, first served)
  FOR v_cand IN
    SELECT * FROM submissions
    WHERE status = 'waiting'
      AND id <> v_new.id
      AND trim(split_part(major, '(', 1)) = trim(split_part(v_new.major, '(', 1))
    ORDER BY created_at ASC, id ASC
  LOOP
    IF EXISTS (SELECT 1 FROM unnest(string_to_array(v_new.desired_tut, ',')) t
               WHERE trim(t) = trim(v_cand.current_tut))
       AND EXISTS (SELECT 1 FROM unnest(string_to_array(v_cand.desired_tut, ',')) t
               WHERE trim(t) = trim(v_new.current_tut))
    THEN
      v_coord :=
           (v_cand.german_level  IS NOT NULL AND v_new.german_level  IS NOT NULL AND v_cand.german_level  <> v_new.german_level)
        OR (v_cand.english_level IS NOT NULL AND v_new.english_level IS NOT NULL AND v_cand.english_level <> v_new.english_level);

      INSERT INTO matches (submission_a_id, submission_b_id, coordinator_needed, created_at)
      VALUES (v_cand.id, v_new.id, v_coord, now())
      RETURNING id INTO v_mid;

      UPDATE submissions SET status = 'matched', matched_at = now()
      WHERE id IN (v_cand.id, v_new.id);

      -- The waiting student is told by email; the one who just submitted sees it on screen
      -- The email carries the partner's contact details so nobody has to log back in
      INSERT INTO notifications (kind, recipient_email, your_tut, partner_tut,
                                 partner_student_id, partner_email, partner_whatsapp, coordinator_needed)
      VALUES ('matched', v_cand.email, v_cand.current_tut, v_new.current_tut,
              v_new.student_id, v_new.email, v_new.whatsapp, v_coord)
      RETURNING id INTO v_nid;

      RETURN jsonb_build_object(
        'matched', true,
        'partner_id', v_cand.id,
        'coordinator_needed', v_coord,
        'notification_id', v_nid
      );
    END IF;
  END LOOP;

  RETURN jsonb_build_object('matched', false);
END;
$$;

-- ===== 5. submit_request =====
CREATE FUNCTION public.submit_request(
  p_student_id    TEXT,
  p_email         TEXT,
  p_major         TEXT,
  p_current_tut   TEXT,
  p_desired_tut   TEXT,
  p_german_level  TEXT,
  p_english_level TEXT,
  p_whatsapp      TEXT,
  p_replace       BOOLEAN
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_sid      TEXT := trim(coalesce(p_student_id, ''));
  v_email    TEXT := lower(trim(coalesce(p_email, '')));
  v_major    TEXT := trim(coalesce(p_major, ''));
  v_cur      TEXT := trim(coalesce(p_current_tut, ''));
  v_wa       TEXT := nullif(regexp_replace(trim(coalesce(p_whatsapp, '')), '^@+', ''), '');
  v_desired  TEXT[];
  v_de       TEXT := nullif(trim(coalesce(p_german_level, '')), '');
  v_en       TEXT := nullif(trim(coalesce(p_english_level, '')), '');
  v_bymail   submissions%ROWTYPE;
  v_byid     submissions%ROWTYPE;
  v_existing submissions%ROWTYPE;
  v_id       UUID;
  v_res      JSONB;
  v_partner  submissions%ROWTYPE;
  v_notify   JSONB := '[]'::jsonb;
BEGIN
  -- ----- validation (the page checks too, but never trust the page) -----
  IF v_sid !~ '^[0-9]+-[0-9]+$' OR length(v_sid) > 15 THEN
    RETURN jsonb_build_object('status','invalid','message','Invalid student ID. Use the format 55-1234.');
  END IF;
  IF v_email !~ '^[^@\s]+@student\.guc\.edu\.eg$' OR length(v_email) > 100 THEN
    RETURN jsonb_build_object('status','invalid','message','Please use your GUC email address (ends with @student.guc.edu.eg).');
  END IF;
  IF v_major = '' OR length(v_major) > 100 THEN
    RETURN jsonb_build_object('status','invalid','message','Please choose your major.');
  END IF;
  IF v_cur !~ '^[0-9]{1,4}$' THEN
    RETURN jsonb_build_object('status','invalid','message','Your tutorial must be a number.');
  END IF;

  SELECT array_agg(DISTINCT trim(x)) INTO v_desired
  FROM unnest(string_to_array(coalesce(p_desired_tut, ''), ',')) x
  WHERE trim(x) <> '';
  IF v_desired IS NULL OR cardinality(v_desired) = 0 OR cardinality(v_desired) > 10
     OR EXISTS (SELECT 1 FROM unnest(v_desired) d WHERE d !~ '^[0-9]{1,4}$') THEN
    RETURN jsonb_build_object('status','invalid','message','Desired tutorials must be 1 to 10 numbers separated by commas.');
  END IF;
  IF v_cur = ANY (v_desired) THEN
    RETURN jsonb_build_object('status','invalid','message','Your desired list can''t include your current tutorial.');
  END IF;
  IF v_de IS NOT NULL AND v_de NOT IN ('1','2','3','4') THEN
    RETURN jsonb_build_object('status','invalid','message','Invalid German level.');
  END IF;
  IF v_en IS NOT NULL AND v_en NOT IN ('AS','SM','CPS','RPW') THEN
    RETURN jsonb_build_object('status','invalid','message','Invalid English level.');
  END IF;
  IF v_wa IS NOT NULL AND v_wa !~ '^[A-Za-z0-9._-]{1,40}$' THEN
    RETURN jsonb_build_object('status','invalid','message','WhatsApp username can only contain letters, numbers, dots, underscores and dashes (max 40).');
  END IF;

  -- One request at a time, so two simultaneous requests can never match the same person
  PERFORM pg_advisory_xact_lock(hashtext('tutmatching_match'));

  SELECT * INTO v_bymail FROM submissions
    WHERE lower(email) = v_email AND status IN ('waiting','matched') LIMIT 1;
  SELECT * INTO v_byid FROM submissions
    WHERE student_id = v_sid AND status IN ('waiting','matched') LIMIT 1;

  IF v_bymail.status = 'matched' OR v_byid.status = 'matched' THEN
    RETURN jsonb_build_object('status','already_matched');
  END IF;
  IF v_bymail.id IS NOT NULL AND v_bymail.student_id <> v_sid THEN
    RETURN jsonb_build_object('status','email_taken');
  END IF;
  IF v_byid.id IS NOT NULL AND lower(v_byid.email) <> v_email THEN
    RETURN jsonb_build_object('status','id_taken');
  END IF;

  -- Same ID + same email, still waiting: replace only if the student confirmed
  v_existing := v_bymail;
  IF v_existing.id IS NOT NULL THEN
    IF NOT coalesce(p_replace, false) THEN
      RETURN jsonb_build_object(
        'status','needs_replace',
        'old_current_tut', v_existing.current_tut,
        'old_desired_tut', v_existing.desired_tut);
    END IF;
    UPDATE submissions SET
      major = v_major, current_tut = v_cur, desired_tut = array_to_string(v_desired, ','),
      german_level = v_de, english_level = v_en, whatsapp = v_wa,
      status = 'waiting', created_at = now(), matched_at = NULL
    WHERE id = v_existing.id;
    v_id := v_existing.id;
  ELSE
    INSERT INTO submissions (student_id, email, major, current_tut, desired_tut,
                             german_level, english_level, whatsapp, status, created_at)
    VALUES (v_sid, v_email, v_major, v_cur, array_to_string(v_desired, ','),
            v_de, v_en, v_wa, 'waiting', now())
    RETURNING id INTO v_id;
  END IF;

  v_res := _find_match(v_id);

  IF NOT (v_res->>'matched')::boolean THEN
    RETURN jsonb_build_object('status','queued');
  END IF;

  SELECT * INTO v_partner FROM submissions WHERE id = (v_res->>'partner_id')::uuid;
  v_notify := jsonb_build_array(v_res->>'notification_id');

  RETURN jsonb_build_object(
    'status','matched',
    'my_tut', v_cur,
    'partner_student_id', v_partner.student_id,
    'partner_tut', v_partner.current_tut,
    'partner_email', v_partner.email,
    'partner_whatsapp', v_partner.whatsapp,
    'coordinator_needed', (v_res->>'coordinator_needed')::boolean,
    'notify', v_notify
  );
END;
$$;

-- ===== 6. check_status =====
CREATE FUNCTION public.check_status(p_student_id TEXT, p_email TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_sid     TEXT := trim(coalesce(p_student_id, ''));
  v_email   TEXT := lower(trim(coalesce(p_email, '')));
  v_me      submissions%ROWTYPE;
  v_m       matches%ROWTYPE;
  v_partner submissions%ROWTYPE;
BEGIN
  SELECT * INTO v_me FROM submissions
    WHERE student_id = v_sid AND lower(email) = v_email AND status IN ('waiting','matched')
    LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('found', false);
  END IF;

  IF v_me.status = 'waiting' THEN
    RETURN jsonb_build_object(
      'found', true, 'status', 'waiting',
      'my_tut', v_me.current_tut, 'desired_tut', v_me.desired_tut,
      'email', v_me.email, 'whatsapp', v_me.whatsapp);
  END IF;

  SELECT * INTO v_m FROM matches
    WHERE submission_a_id = v_me.id OR submission_b_id = v_me.id
    ORDER BY created_at DESC LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('found', true, 'status', 'matched', 'details_missing', true);
  END IF;

  SELECT * INTO v_partner FROM submissions
    WHERE id = CASE WHEN v_m.submission_a_id = v_me.id THEN v_m.submission_b_id ELSE v_m.submission_a_id END;

  RETURN jsonb_build_object(
    'found', true, 'status', 'matched',
    'my_tut', v_me.current_tut,
    'partner_student_id', v_partner.student_id,
    'partner_tut', v_partner.current_tut,
    'partner_email', v_partner.email,
    'partner_whatsapp', v_partner.whatsapp,
    'coordinator_needed', coalesce(v_m.coordinator_needed, false),
    'email', v_me.email, 'whatsapp', v_me.whatsapp);
END;
$$;

-- ===== 7. cancel_request =====
-- Waiting: just cancelled. Matched: cancelled, the partner goes back in the queue
-- (keeping their original place), we try to rematch them, and they get an email.
CREATE FUNCTION public.cancel_request(p_student_id TEXT, p_email TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_sid     TEXT := trim(coalesce(p_student_id, ''));
  v_email   TEXT := lower(trim(coalesce(p_email, '')));
  v_me      submissions%ROWTYPE;
  v_m       matches%ROWTYPE;
  v_partner submissions%ROWTYPE;
  v_new     submissions%ROWTYPE;
  v_res     JSONB;
  v_nid     UUID;
  v_notify  JSONB := '[]'::jsonb;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('tutmatching_match'));

  SELECT * INTO v_me FROM submissions
    WHERE student_id = v_sid AND lower(email) = v_email AND status IN ('waiting','matched')
    LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('cancelled', false);
  END IF;

  IF v_me.status = 'waiting' THEN
    UPDATE submissions SET status = 'cancelled', whatsapp = NULL WHERE id = v_me.id;
    RETURN jsonb_build_object('cancelled', true, 'was', 'waiting', 'notify', v_notify);
  END IF;

  -- matched
  SELECT * INTO v_m FROM matches
    WHERE submission_a_id = v_me.id OR submission_b_id = v_me.id
    ORDER BY created_at DESC LIMIT 1;

  UPDATE submissions SET status = 'cancelled', whatsapp = NULL, matched_at = NULL WHERE id = v_me.id;

  IF v_m.id IS NOT NULL THEN
    SELECT * INTO v_partner FROM submissions
      WHERE id = CASE WHEN v_m.submission_a_id = v_me.id THEN v_m.submission_b_id ELSE v_m.submission_a_id END;

    DELETE FROM matches WHERE id = v_m.id;

    IF v_partner.id IS NOT NULL AND v_partner.status = 'matched' THEN
      UPDATE submissions SET status = 'waiting', matched_at = NULL WHERE id = v_partner.id;

      v_res := _find_match(v_partner.id);
      IF (v_res->>'matched')::boolean THEN
        v_notify := v_notify || jsonb_build_array(v_res->>'notification_id');
        SELECT * INTO v_new FROM submissions WHERE id = (v_res->>'partner_id')::uuid;

        -- Rematched: the cancellation email also carries the new partner's details
        INSERT INTO notifications (kind, recipient_email, your_tut, partner_tut,
                                   partner_student_id, partner_email, partner_whatsapp,
                                   coordinator_needed, rematched)
        VALUES ('cancelled', v_partner.email, v_partner.current_tut, v_new.current_tut,
                v_new.student_id, v_new.email, v_new.whatsapp,
                coalesce((v_res->>'coordinator_needed')::boolean, false), true)
        RETURNING id INTO v_nid;
      ELSE
        INSERT INTO notifications (kind, recipient_email, your_tut, rematched)
        VALUES ('cancelled', v_partner.email, v_partner.current_tut, false)
        RETURNING id INTO v_nid;
      END IF;
      v_notify := v_notify || jsonb_build_array(v_nid::text);
    END IF;
  END IF;

  RETURN jsonb_build_object('cancelled', true, 'was', 'matched', 'notify', v_notify);
END;
$$;

-- ===== 8. Email queue helpers (only the email function may call these) =====
CREATE FUNCTION public.claim_notification(p_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE v notifications%ROWTYPE;
BEGIN
  UPDATE notifications SET claimed_at = now()
  WHERE id = p_id AND sent_at IS NULL
    AND (claimed_at IS NULL OR claimed_at < now() - interval '2 minutes')
  RETURNING * INTO v;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  RETURN to_jsonb(v);
END;
$$;

CREATE FUNCTION public.finish_notification(p_id UUID)
RETURNS VOID
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$ UPDATE notifications SET sent_at = now() WHERE id = p_id; $$;

CREATE FUNCTION public.release_notification(p_id UUID)
RETURNS VOID
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$ UPDATE notifications SET claimed_at = NULL WHERE id = p_id AND sent_at IS NULL; $$;

-- ===== 9. Who may call what =====
REVOKE ALL ON FUNCTION public._find_match(UUID) FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.submit_request(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,BOOLEAN) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.check_status(TEXT,TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.cancel_request(TEXT,TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_request(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,BOOLEAN) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.check_status(TEXT,TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_request(TEXT,TEXT) TO anon, authenticated;

REVOKE ALL ON FUNCTION public.claim_notification(UUID)   FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.finish_notification(UUID)  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.release_notification(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_notification(UUID)   TO service_role;
GRANT EXECUTE ON FUNCTION public.finish_notification(UUID)  TO service_role;
GRANT EXECUTE ON FUNCTION public.release_notification(UUID) TO service_role;
