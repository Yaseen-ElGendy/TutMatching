-- ============================================================
-- TutMatching v5.3: when a cancelled student's partner is rematched at once,
-- the cancellation email carries the NEW partner's details.
-- Run this ENTIRE file ONCE in the Supabase SQL Editor (after v5, v5.1, v5.2). Safe to re-run.
-- Then redeploy the email function (index.ts).
-- ============================================================

CREATE OR REPLACE FUNCTION public.cancel_request(p_student_id TEXT, p_email TEXT)
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
