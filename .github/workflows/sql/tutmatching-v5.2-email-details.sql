-- ============================================================
-- TutMatching v5.2: the match email now includes the partner's details
-- (student ID, email, WhatsApp username if they gave one).
-- Run this ENTIRE file ONCE in the Supabase SQL Editor (after v5 / v5.1). Safe to re-run.
-- Then redeploy the email function (index.ts).
-- ============================================================

ALTER TABLE notifications ADD COLUMN IF NOT EXISTS partner_student_id TEXT;
ALTER TABLE notifications ADD COLUMN IF NOT EXISTS partner_email TEXT;
ALTER TABLE notifications ADD COLUMN IF NOT EXISTS partner_whatsapp TEXT;

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
