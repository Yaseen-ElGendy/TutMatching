SET ROLE anon;
SELECT t_assert(submit_request('55-1','a@student.guc.edu.eg','CS','1','2,3','1','AS','alice_wa',false)->>'status' = 'queued', 'first student is queued');
SELECT t_assert(submit_request('55-1','a@student.guc.edu.eg','CS','1','4','1','AS',NULL,false)->>'status' = 'needs_replace', 'same ID + email asks before replacing');
SELECT t_assert(submit_request('55-1','a@student.guc.edu.eg','CS','1','2','1','AS','alice_wa',true)->>'status' = 'queued', 'replace works when confirmed');
SELECT t_assert(submit_request('55-9','a@student.guc.edu.eg','CS','5','1',NULL,NULL,NULL,false)->>'status' = 'email_taken', 'email already used by another ID is refused');
SELECT t_assert(submit_request('55-1','z@student.guc.edu.eg','CS','5','1',NULL,NULL,NULL,false)->>'status' = 'id_taken', 'ID already used with another email is refused');
SELECT t_assert(submit_request('55-3','c@student.guc.edu.eg','Law','2','1',NULL,NULL,NULL,false)->>'status' = 'queued', 'different major does not match');
SELECT t_assert(submit_request('55-5','e@student.guc.edu.eg','CS','7','1',NULL,NULL,NULL,false)->>'status' = 'queued', 'tutorial wishes must be mutual');
SELECT t_assert(submit_request('55-2','b@student.guc.edu.eg','CS','2','1','2','AS',NULL,false)->>'status' = 'matched', 'mutual request matches');
SELECT t_assert(submit_request('55-2','b@student.guc.edu.eg','CS','2','1',NULL,NULL,NULL,false)->>'status' = 'already_matched', 'matched student cannot submit again');

SELECT t_assert((check_status('55-2','b@student.guc.edu.eg')->>'partner_student_id') = '55-1', 'second student sees partner id');
SELECT t_assert((check_status('55-2','b@student.guc.edu.eg')->>'partner_whatsapp') = 'alice_wa', 'second student sees partner WhatsApp');
SELECT t_assert((check_status('55-1','a@student.guc.edu.eg')->>'partner_email') = 'b@student.guc.edu.eg', 'first student sees partner email');
SELECT t_assert((check_status('55-1','a@student.guc.edu.eg')->>'partner_whatsapp') IS NULL, 'no WhatsApp when partner gave none');
SELECT t_assert((check_status('55-1','wrong@student.guc.edu.eg')->>'found') = 'false', 'wrong email shows nothing');
SELECT t_assert((check_status('55-9','a@student.guc.edu.eg')->>'found') = 'false', 'wrong ID shows nothing');
SELECT t_assert((check_status('55-1','A@STUDENT.GUC.EDU.EG')->>'found') = 'true', 'status check ignores email capitals');
RESET ROLE;

SELECT t_assert((SELECT coordinator_needed FROM matches) = true, 'coordinator flagged when German levels differ');
SELECT t_assert((SELECT count(*) FROM notifications WHERE kind = 'matched') = 1, 'one match notification created');
SELECT t_assert((SELECT recipient_email FROM notifications WHERE kind = 'matched') = 'a@student.guc.edu.eg', 'notification goes to the student who was waiting');
SELECT t_assert((SELECT partner_student_id || partner_email FROM notifications WHERE kind = 'matched') = '55-2b@student.guc.edu.eg', 'notification carries the partner details');
SELECT t_assert((SELECT status FROM submissions WHERE student_id = '55-5') = 'waiting', 'unmatched students keep waiting');

-- oldest waiting request is matched first
DELETE FROM notifications; DELETE FROM matches; DELETE FROM submissions;
SET ROLE anon;
SELECT submit_request('60-1','p1@student.guc.edu.eg','CS','1','2',NULL,NULL,NULL,false);
SELECT submit_request('60-2','p2@student.guc.edu.eg','CS','1','2',NULL,NULL,NULL,false);
SELECT t_assert(submit_request('60-3','p3@student.guc.edu.eg','CS','2','1',NULL,NULL,NULL,false)->>'partner_student_id' = '60-1', 'oldest waiting request is matched first');
SELECT t_assert(submit_request('61-1','q1@student.guc.edu.eg','CS','8','9','1','AS',NULL,false)->>'status' = 'queued', 'queued');
SELECT t_assert((submit_request('61-2','q2@student.guc.edu.eg','CS','9','8','1','AS',NULL,false)->>'coordinator_needed')::boolean = false, 'no coordinator flag when levels are the same');
RESET ROLE;

-- one active request per ID and per email, enforced by the database itself
SELECT t_assert((SELECT count(*) FROM pg_indexes WHERE tablename = 'submissions' AND indexdef ILIKE '%UNIQUE%') >= 2, 'unique rules exist');
DO $$ BEGIN
  INSERT INTO submissions(student_id,email,major,current_tut,desired_tut,status) VALUES ('99-1','dup@student.guc.edu.eg','CS','1','2','waiting');
  INSERT INTO submissions(student_id,email,major,current_tut,desired_tut,status) VALUES ('99-1','dup2@student.guc.edu.eg','CS','1','2','waiting');
  RAISE EXCEPTION 'FAIL: two active requests for one student id were allowed';
EXCEPTION WHEN unique_violation THEN RAISE NOTICE 'PASS: database refuses two active requests for one ID'; END $$;
