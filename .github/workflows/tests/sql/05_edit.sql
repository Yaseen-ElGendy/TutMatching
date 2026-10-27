-- waiting students can edit; matched students cannot edit at all
SET ROLE anon;
SELECT submit_request('55-1','a@student.guc.edu.eg','CS','1','2',NULL,NULL,NULL,false);
SELECT submit_request('55-3','c@student.guc.edu.eg','CS','5','6',NULL,NULL,NULL,false);
RESET ROLE;
DO $$ BEGIN PERFORM set_config('t.c1', (SELECT created_at::text FROM submissions WHERE student_id='55-1'), false); END $$;

SET ROLE anon;
SELECT t_assert(edit_request('55-1','wrong@student.guc.edu.eg','CS','1','2',NULL,NULL,NULL)->>'status' = 'not_found', 'edit with the wrong email finds nothing');
SELECT t_assert(edit_request('55-1','a@student.guc.edu.eg','CS','1','1',NULL,NULL,NULL)->>'status' = 'invalid', 'edit is validated like a new request');
SELECT t_assert(edit_request('55-1','a@student.guc.edu.eg','CS','1','2','1','AS','new_wa')->>'status' = 'updated', 'levels and WhatsApp can be changed');
RESET ROLE;
SELECT t_assert((SELECT created_at::text FROM submissions WHERE student_id='55-1') = current_setting('t.c1'), 'changing only levels / WhatsApp keeps the queue place');
SELECT t_assert((SELECT german_level || english_level || whatsapp FROM submissions WHERE student_id='55-1') = '1ASnew_wa', 'the changes were saved');
SELECT pg_sleep(0.05);

SET ROLE anon;
SELECT t_assert(edit_request('55-1','a@student.guc.edu.eg','CS','1','2,3','1','AS','new_wa')->>'status' = 'queued', 'changing tutorials re-queues');
RESET ROLE;
SELECT t_assert((SELECT created_at::text FROM submissions WHERE student_id='55-1') <> current_setting('t.c1'), 'changing tutorials moves the student to the back of the queue');
SELECT t_assert((SELECT desired_tut FROM submissions WHERE student_id='55-1') = '2,3', 'new tutorials saved');

-- an edit that creates a match (the 5-per-hour counter is reset so this test isn't limited)
DELETE FROM rate_events;
SET ROLE anon;
SELECT submit_request('55-2','b@student.guc.edu.eg','CS','3','9',NULL,NULL,NULL,false);
SELECT t_assert(edit_request('55-2','b@student.guc.edu.eg','CS','3','1',NULL,NULL,NULL)->>'status' = 'matched', 'an edit can create a match');
RESET ROLE;
DELETE FROM rate_events;
SET ROLE anon;
SELECT t_assert((edit_request('55-1','a@student.guc.edu.eg','CS','1','2,3','1','AS','a_new')->>'status') = 'matched_locked', 'matched student cannot even change WhatsApp');
SELECT t_assert(coalesce((check_status('55-2','b@student.guc.edu.eg')->>'partner_whatsapp'),'') <> 'a_new', 'partner does not see a refused change');
SELECT t_assert(edit_request('55-1','a@student.guc.edu.eg','CS','1','2','1','AS','a_new')->>'status' = 'matched_locked', 'matched student cannot change tutorials');
SELECT t_assert(edit_request('55-1','a@student.guc.edu.eg','Law','1','2,3','1','AS','a_new')->>'status' = 'matched_locked', 'matched student cannot change major');
SELECT t_assert(edit_request('55-1','a@student.guc.edu.eg','CS','1','2,3','2','AS','a_new')->>'status' = 'matched_locked', 'matched student cannot change levels');
RESET ROLE;
SELECT t_assert((SELECT status FROM submissions WHERE student_id='55-1') = 'matched', 'a refused edit leaves the match intact');
SELECT t_assert((SELECT count(*) FROM notifications WHERE kind = 'cancelled') = 0, 'edits never send cancellation emails');

-- rows saved in a different order still compare equal (older data)
DELETE FROM notifications; DELETE FROM matches; DELETE FROM submissions; DELETE FROM rate_events;
INSERT INTO submissions (student_id,email,major,current_tut,desired_tut,status) VALUES ('80-1','l1@student.guc.edu.eg','CS','1','7,3,4','waiting');
SET ROLE anon;
SELECT t_assert(edit_request('80-1','l1@student.guc.edu.eg','CS','1','3,4,7',NULL,NULL,'leg')->>'status' = 'updated', 'same tutorials in a different order count as unchanged');
RESET ROLE;
SELECT t_assert((SELECT desired_tut FROM submissions WHERE student_id='80-1') = '7,3,4', 'unchanged tutorials are left as they were');
