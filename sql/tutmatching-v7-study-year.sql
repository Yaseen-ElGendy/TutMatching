-- ============================================================
-- TutMatching v7: study year (1 to 6).
-- Students now choose their study year, and two students only match when they
-- have the SAME MAJOR and the SAME YEAR.
-- Run this ENTIRE file ONCE in the Supabase SQL Editor, after v5 / v5.1 / v5.2 / v5.3 / v6.
-- Safe to re-run. Run it BEFORE uploading the new index.html / admin.html.
-- Requests already waiting from before this update have no year; they can only
-- match each other until their owners edit them (an edit asks for the year).
-- ============================================================

ALTER TABLE submissions ADD COLUMN IF NOT EXISTS study_year SMALLINT;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'submissions_study_year_check') THEN
    ALTER TABLE submissions ADD CONSTRAINT submissions_study_year_check CHECK (study_year BETWEEN 1 AND 6);
  END IF;
END $$;

-- The old versions take one argument fewer. Remove them so only one version exists.
DROP FUNCTION IF EXISTS public.submit_request(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,BOOLEAN);
DROP FUNCTION IF EXISTS public.edit_request(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT);
DROP FUNCTION IF EXISTS public._clean_request(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT);

-- ----- _clean_request -----
CREATE OR REPLACE FUNCTION public._clean_request(
  p_student_id TEXT, p_email TEXT, p_major TEXT, p_current_tut TEXT, p_desired_tut TEXT,
  p_german_level TEXT, p_english_level TEXT, p_whatsapp TEXT,
  p_study_year TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_sid     TEXT := trim(coalesce(p_student_id, ''));
  v_email   TEXT := lower(trim(coalesce(p_email, '')));
  v_major   TEXT := trim(coalesce(p_major, ''));
  v_cur     TEXT := trim(coalesce(p_current_tut, ''));
  v_wa      TEXT := nullif(regexp_replace(trim(coalesce(p_whatsapp, '')), '^@+', ''), '');
  v_de      TEXT := nullif(trim(coalesce(p_german_level, '')), '');
  v_en      TEXT := nullif(trim(coalesce(p_english_level, '')), '');
  v_year    TEXT := nullif(trim(coalesce(p_study_year, '')), '');
  v_desired TEXT[];
BEGIN
  IF v_sid !~ '^[0-9]+-[0-9]+$' OR length(v_sid) > 15 THEN
    RETURN jsonb_build_object('error', 'Invalid student ID. Use the format 55-1234.');
  END IF;
  IF v_email !~ '^[^@\s]+@student\.guc\.edu\.eg$' OR length(v_email) > 100 THEN
    RETURN jsonb_build_object('error', 'Please use your GUC email address (ends with @student.guc.edu.eg).');
  END IF;
  IF v_major = '' OR length(v_major) > 100 THEN
    RETURN jsonb_build_object('error', 'Please choose your major.');
  END IF;
  IF v_year IS NULL OR v_year !~ '^[1-6]$' THEN
    RETURN jsonb_build_object('error', 'Please choose your study year (1 to 6).');
  END IF;
  IF v_cur !~ '^[0-9]{1,4}$' THEN
    RETURN jsonb_build_object('error', 'Your tutorial must be a number.');
  END IF;

  SELECT array_agg(DISTINCT trim(x)) INTO v_desired
  FROM unnest(string_to_array(coalesce(p_desired_tut, ''), ',')) x
  WHERE trim(x) <> '';
  IF v_desired IS NULL OR cardinality(v_desired) = 0 OR cardinality(v_desired) > 10
     OR EXISTS (SELECT 1 FROM unnest(v_desired) d WHERE d !~ '^[0-9]{1,4}$') THEN
    RETURN jsonb_build_object('error', 'Desired tutorials must be 1 to 10 numbers separated by commas.');
  END IF;
  IF v_cur = ANY (v_desired) THEN
    RETURN jsonb_build_object('error', 'Your desired list can''t include your current tutorial.');
  END IF;
  IF v_de IS NOT NULL AND v_de NOT IN ('1','2','3','4') THEN
    RETURN jsonb_build_object('error', 'Invalid German level.');
  END IF;
  IF v_en IS NOT NULL AND v_en NOT IN ('AS','SM','CPS','RPW') THEN
    RETURN jsonb_build_object('error', 'Invalid English level.');
  END IF;
  IF v_wa IS NOT NULL AND v_wa !~ '^[A-Za-z0-9._-]{1,40}$' THEN
    RETURN jsonb_build_object('error', 'WhatsApp username can only contain letters, numbers, dots, underscores and dashes (max 40).');
  END IF;

  RETURN jsonb_build_object(
    'sid', v_sid, 'email', v_email, 'major', v_major, 'year', v_year, 'cur', v_cur,
    'desired', array_to_string(ARRAY(SELECT unnest(v_desired) ORDER BY 1), ','),
    'de', v_de, 'en', v_en, 'wa', v_wa);
END;
$$;

-- ----- _find_match -----
CREATE OR REPLACE FUNCTION public._find_match(p_sub UUID)
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
      AND study_year IS NOT DISTINCT FROM v_new.study_year
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

-- ----- submit_request -----
CREATE OR REPLACE FUNCTION public.submit_request(
  p_student_id    TEXT,
  p_email         TEXT,
  p_major         TEXT,
  p_current_tut   TEXT,
  p_desired_tut   TEXT,
  p_german_level  TEXT,
  p_english_level TEXT,
  p_whatsapp      TEXT,
  p_replace       BOOLEAN,
  p_study_year    TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  c          JSONB := _clean_request(p_student_id, p_email, p_major, p_current_tut, p_desired_tut,
                                     p_german_level, p_english_level, p_whatsapp, p_study_year);
  v_bymail   submissions%ROWTYPE;
  v_byid     submissions%ROWTYPE;
  v_id       UUID;
  v_res      JSONB;
  v_partner  submissions%ROWTYPE;
BEGIN
  IF c->>'error' IS NOT NULL THEN
    RETURN jsonb_build_object('status', 'invalid', 'message', c->>'error');
  END IF;

  -- One request at a time, so two simultaneous requests can never match the same person
  PERFORM pg_advisory_xact_lock(hashtext('tutmatching_match'));

  IF NOT _rate_check(c->>'sid', c->>'email', 'act', 5) THEN
    RETURN jsonb_build_object('status', 'rate_limited');
  END IF;

  SELECT * INTO v_bymail FROM submissions
    WHERE lower(email) = c->>'email' AND status IN ('waiting','matched') LIMIT 1;
  SELECT * INTO v_byid FROM submissions
    WHERE student_id = c->>'sid' AND status IN ('waiting','matched') LIMIT 1;

  IF v_bymail.status = 'matched' OR v_byid.status = 'matched' THEN
    RETURN jsonb_build_object('status', 'already_matched');
  END IF;
  IF v_bymail.id IS NOT NULL AND v_bymail.student_id <> c->>'sid' THEN
    RETURN jsonb_build_object('status', 'email_taken');
  END IF;
  IF v_byid.id IS NOT NULL AND lower(v_byid.email) <> c->>'email' THEN
    RETURN jsonb_build_object('status', 'id_taken');
  END IF;

  -- Same ID + same email, still waiting: replace only if the student confirmed
  IF v_bymail.id IS NOT NULL THEN
    IF NOT coalesce(p_replace, false) THEN
      RETURN jsonb_build_object(
        'status', 'needs_replace',
        'old_current_tut', v_bymail.current_tut,
        'old_desired_tut', v_bymail.desired_tut);
    END IF;
    UPDATE submissions SET
      major = c->>'major', study_year = (c->>'year')::smallint,
      current_tut = c->>'cur', desired_tut = c->>'desired',
      german_level = c->>'de', english_level = c->>'en', whatsapp = c->>'wa',
      status = 'waiting', created_at = now(), matched_at = NULL
    WHERE id = v_bymail.id;
    v_id := v_bymail.id;
  ELSE
    INSERT INTO submissions (student_id, email, major, study_year, current_tut, desired_tut,
                             german_level, english_level, whatsapp, status, created_at)
    VALUES (c->>'sid', c->>'email', c->>'major', (c->>'year')::smallint, c->>'cur', c->>'desired',
            c->>'de', c->>'en', c->>'wa', 'waiting', now())
    RETURNING id INTO v_id;
  END IF;

  v_res := _find_match(v_id);

  IF NOT (v_res->>'matched')::boolean THEN
    RETURN jsonb_build_object('status', 'queued');
  END IF;

  SELECT * INTO v_partner FROM submissions WHERE id = (v_res->>'partner_id')::uuid;

  RETURN jsonb_build_object(
    'status', 'matched',
    'my_tut', c->>'cur',
    'partner_student_id', v_partner.student_id,
    'partner_tut', v_partner.current_tut,
    'partner_email', v_partner.email,
    'partner_whatsapp', v_partner.whatsapp,
    'coordinator_needed', (v_res->>'coordinator_needed')::boolean,
    'notify', jsonb_build_array(v_res->>'notification_id')
  );
END;
$$;

-- ----- edit_request -----
CREATE OR REPLACE FUNCTION public.edit_request(
  p_student_id    TEXT,
  p_email         TEXT,
  p_major         TEXT,
  p_current_tut   TEXT,
  p_desired_tut   TEXT,
  p_german_level  TEXT,
  p_english_level TEXT,
  p_whatsapp      TEXT,
  p_study_year    TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  c            JSONB := _clean_request(p_student_id, p_email, p_major, p_current_tut, p_desired_tut,
                                       p_german_level, p_english_level, p_whatsapp, p_study_year);
  v_me         submissions%ROWTYPE;
  v_matching_changed BOOLEAN;
  v_levels_changed   BOOLEAN;
  v_res        JSONB;
  v_partner    submissions%ROWTYPE;
BEGIN
  IF c->>'error' IS NOT NULL THEN
    RETURN jsonb_build_object('status', 'invalid', 'message', c->>'error');
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('tutmatching_match'));

  IF NOT _rate_check(c->>'sid', c->>'email', 'act', 5) THEN
    RETURN jsonb_build_object('status', 'rate_limited');
  END IF;

  SELECT * INTO v_me FROM submissions
    WHERE student_id = c->>'sid' AND lower(email) = c->>'email' AND status IN ('waiting','matched')
    LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'not_found');
  END IF;

  v_matching_changed :=
       v_me.major <> c->>'major'
    OR v_me.study_year IS DISTINCT FROM (c->>'year')::smallint
    OR v_me.current_tut <> c->>'cur'
    OR _norm_tuts(v_me.desired_tut) <> c->>'desired';
  v_levels_changed :=
       v_me.german_level  IS DISTINCT FROM (c->>'de')
    OR v_me.english_level IS DISTINCT FROM (c->>'en');

  IF v_me.status = 'matched' THEN
    RETURN jsonb_build_object('status', 'matched_locked');
  END IF;

  -- waiting
  IF NOT v_matching_changed THEN
    UPDATE submissions SET
      german_level = c->>'de', english_level = c->>'en', whatsapp = c->>'wa'
    WHERE id = v_me.id;
    RETURN jsonb_build_object('status', 'updated');
  END IF;

  UPDATE submissions SET
    major = c->>'major', study_year = (c->>'year')::smallint,
    current_tut = c->>'cur', desired_tut = c->>'desired',
    german_level = c->>'de', english_level = c->>'en', whatsapp = c->>'wa',
    created_at = now()
  WHERE id = v_me.id;

  v_res := _find_match(v_me.id);
  IF NOT (v_res->>'matched')::boolean THEN
    RETURN jsonb_build_object('status', 'queued');
  END IF;

  SELECT * INTO v_partner FROM submissions WHERE id = (v_res->>'partner_id')::uuid;

  RETURN jsonb_build_object(
    'status', 'matched',
    'my_tut', c->>'cur',
    'partner_student_id', v_partner.student_id,
    'partner_tut', v_partner.current_tut,
    'partner_email', v_partner.email,
    'partner_whatsapp', v_partner.whatsapp,
    'coordinator_needed', (v_res->>'coordinator_needed')::boolean,
    'notify', jsonb_build_array(v_res->>'notification_id')
  );
END;
$$;

-- ----- check_status -----
CREATE OR REPLACE FUNCTION public.check_status(p_student_id TEXT, p_email TEXT)
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
  IF NOT _rate_check(v_sid, v_email, 'chk', 20) THEN
    RETURN jsonb_build_object('found', false, 'rate_limited', true);
  END IF;

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
      'major', v_me.major, 'study_year', v_me.study_year, 'german_level', v_me.german_level, 'english_level', v_me.english_level,
      'email', v_me.email, 'whatsapp', v_me.whatsapp);
  END IF;

  SELECT * INTO v_m FROM matches
    WHERE submission_a_id = v_me.id OR submission_b_id = v_me.id
    ORDER BY created_at DESC LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'found', true, 'status', 'matched', 'details_missing', true,
      'my_tut', v_me.current_tut, 'desired_tut', v_me.desired_tut,
      'major', v_me.major, 'study_year', v_me.study_year, 'german_level', v_me.german_level, 'english_level', v_me.english_level,
      'email', v_me.email, 'whatsapp', v_me.whatsapp);
  END IF;

  SELECT * INTO v_partner FROM submissions
    WHERE id = CASE WHEN v_m.submission_a_id = v_me.id THEN v_m.submission_b_id ELSE v_m.submission_a_id END;

  RETURN jsonb_build_object(
    'found', true, 'status', 'matched',
    'my_tut', v_me.current_tut, 'desired_tut', v_me.desired_tut,
    'major', v_me.major, 'study_year', v_me.study_year, 'german_level', v_me.german_level, 'english_level', v_me.english_level,
    'partner_student_id', v_partner.student_id,
    'partner_tut', v_partner.current_tut,
    'partner_email', v_partner.email,
    'partner_whatsapp', v_partner.whatsapp,
    'coordinator_needed', coalesce(v_m.coordinator_needed, false),
    'email', v_me.email, 'whatsapp', v_me.whatsapp);
END;
$$;

-- ----- admin_overview -----
CREATE OR REPLACE FUNCTION public.admin_overview()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'not allowed';
  END IF;

  RETURN jsonb_build_object(
    'counts', jsonb_build_object(
      'waiting',        (SELECT count(*) FROM submissions WHERE status = 'waiting'),
      'matched',        (SELECT count(*) FROM submissions WHERE status = 'matched'),
      'cancelled',      (SELECT count(*) FROM submissions WHERE status = 'cancelled'),
      'matches',        (SELECT count(*) FROM matches),
      'emails_sent',    (SELECT count(*) FROM notifications WHERE sent_at IS NOT NULL),
      'emails_pending', (SELECT count(*) FROM notifications WHERE sent_at IS NULL AND attempts < 5),
      'emails_failed',  (SELECT count(*) FROM notifications WHERE sent_at IS NULL AND attempts >= 5)
    ),
    'by_major', (
      SELECT coalesce(jsonb_agg(to_jsonb(r)), '[]'::jsonb) FROM (
        SELECT major, study_year,
               count(*) FILTER (WHERE status = 'waiting') AS waiting,
               count(*) FILTER (WHERE status = 'matched') AS matched
        FROM submissions WHERE status <> 'cancelled'
        GROUP BY major, study_year ORDER BY count(*) DESC, major, study_year) r),
    'waiting_swaps', (
      SELECT coalesce(jsonb_agg(to_jsonb(r)), '[]'::jsonb) FROM (
        SELECT study_year, current_tut, desired_tut, count(*) AS n
        FROM submissions WHERE status = 'waiting'
        GROUP BY study_year, current_tut, desired_tut ORDER BY count(*) DESC, current_tut LIMIT 15) r),
    'waiting', (
      SELECT coalesce(jsonb_agg(to_jsonb(r)), '[]'::jsonb) FROM (
        SELECT student_id, email, major, study_year, current_tut, desired_tut, whatsapp, created_at
        FROM submissions WHERE status = 'waiting' ORDER BY created_at LIMIT 100) r),
    'matches', (
      SELECT coalesce(jsonb_agg(to_jsonb(r)), '[]'::jsonb) FROM (
        SELECT m.created_at, a.study_year AS year, a.student_id AS a_id, a.current_tut AS a_tut,
               b.student_id AS b_id, b.current_tut AS b_tut, m.coordinator_needed
        FROM matches m
        JOIN submissions a ON a.id = m.submission_a_id
        JOIN submissions b ON b.id = m.submission_b_id
        ORDER BY m.created_at DESC LIMIT 100) r),
    'notifications', (
      SELECT coalesce(jsonb_agg(to_jsonb(r)), '[]'::jsonb) FROM (
        SELECT kind, recipient_email, created_at, sent_at, attempts
        FROM notifications ORDER BY created_at DESC LIMIT 50) r)
  );
END;
$$;

-- ===== Who may call what =====
REVOKE ALL ON FUNCTION public._clean_request(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._find_match(UUID) FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.submit_request(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,BOOLEAN,TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_request(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,BOOLEAN,TEXT) TO anon, authenticated;

REVOKE ALL ON FUNCTION public.edit_request(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.edit_request(TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT,TEXT) TO anon, authenticated;
