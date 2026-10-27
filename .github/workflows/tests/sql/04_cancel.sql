SET ROLE anon;
SELECT submit_request('55-1','a@student.guc.edu.eg','CS','1','2',NULL,NULL,'alice_wa',false);
SELECT t_assert((cancel_request('55-1','wrong@student.guc.edu.eg')->>'cancelled') = 'false', 'cancel with the wrong email does nothing');
SELECT t_assert((cancel_request('55-1','a@student.guc.edu.eg')->>'was') = 'waiting', 'waiting request can be cancelled');
SELECT t_assert((cancel_request('55-1','a@student.guc.edu.eg')->>'cancelled') = 'false', 'cancelling twice does nothing');
SELECT t_assert(submit_request('55-1','a@student.guc.edu.eg','CS','1','2',NULL,NULL,'alice_wa',false)->>'status' = 'queued', 'cancelled student can submit again');
RESET ROLE;
SELECT t_assert((SELECT count(*) FROM submissions WHERE student_id = '55-1' AND status = 'cancelled' AND whatsapp IS NULL) = 1, 'cancelled request has its WhatsApp removed');

-- matched cancel with a waiting rematch available
DELETE FROM notifications; DELETE FROM matches; DELETE FROM submissions; DELETE FROM rate_events;
SET ROLE anon;
SELECT submit_request('55-1','a@student.guc.edu.eg','CS','1','2',NULL,NULL,'alice_wa',false);
SELECT submit_request('55-2','b@student.guc.edu.eg','CS','2','1',NULL,NULL,NULL,false);
SELECT submit_request('55-4','d@student.guc.edu.eg','CS','2','1','2','AS','dave.w',false);
RESET ROLE;
DO $$ DECLARE t0 TIMESTAMP; BEGIN
  SELECT created_at INTO t0 FROM submissions WHERE student_id = '55-1';
  PERFORM set_config('t.alice_created', t0::text, false);
END $$;
SET ROLE anon;
SELECT t_assert((cancel_request('55-2','b@student.guc.edu.eg')->>'was') = 'matched', 'matched request can be cancelled');
SELECT t_assert((check_status('55-1','a@student.guc.edu.eg')->>'partner_student_id') = '55-4', 'cancelled partner is rematched with the waiting student');
SELECT t_assert((check_status('55-4','d@student.guc.edu.eg')->>'partner_whatsapp') = 'alice_wa', 'rematched student sees partner details');
RESET ROLE;
SELECT t_assert((SELECT created_at::text FROM submissions WHERE student_id = '55-1') = current_setting('t.alice_created'), 'requeued partner keeps their original place');
SELECT t_assert((SELECT rematched FROM notifications WHERE kind = 'cancelled') = true, 'cancellation notice says rematched');
SELECT t_assert((SELECT partner_student_id || partner_email || partner_whatsapp FROM notifications WHERE kind = 'cancelled') = '55-4d@student.guc.edu.egdave.w', 'cancellation notice carries the new partner details');
SELECT t_assert((SELECT recipient_email FROM notifications WHERE kind = 'cancelled') = 'a@student.guc.edu.eg', 'cancellation notice goes to the partner');
SELECT t_assert((SELECT count(*) FROM matches) = 1, 'old match removed, new match created');

-- matched cancel, nobody to rematch with
DELETE FROM notifications; DELETE FROM matches; DELETE FROM submissions; DELETE FROM rate_events;
SET ROLE anon;
SELECT submit_request('70-1','g@student.guc.edu.eg','CS','9','8',NULL,NULL,NULL,false);
SELECT submit_request('70-2','h@student.guc.edu.eg','CS','8','9',NULL,NULL,NULL,false);
SELECT cancel_request('70-2','h@student.guc.edu.eg');
SELECT t_assert((check_status('70-1','g@student.guc.edu.eg')->>'status') = 'waiting', 'partner goes back to waiting when nobody fits');
RESET ROLE;
SELECT t_assert((SELECT rematched FROM notifications WHERE kind = 'cancelled') = false, 'cancellation notice says back in the queue');
SELECT t_assert((SELECT partner_email FROM notifications WHERE kind = 'cancelled') IS NULL, 'no partner details when not rematched');
