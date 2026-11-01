-- study year: 1 to 6 is required, and students only match within the same major AND year
SET ROLE anon;
SELECT t_assert(submit_request('90-1','y1@student.guc.edu.eg','CS','1','2',NULL,NULL,NULL,false,NULL)->>'status' = 'invalid', 'a missing year is refused');
SELECT t_assert(submit_request('90-1','y1@student.guc.edu.eg','CS','1','2',NULL,NULL,NULL,false)->>'status' = 'invalid', 'an old page that sends no year gets a clear error');
SELECT t_assert(submit_request('90-1','y1@student.guc.edu.eg','CS','1','2',NULL,NULL,NULL,false,'0')->>'status' = 'invalid', 'year 0 is refused');
SELECT t_assert(submit_request('90-1','y1@student.guc.edu.eg','CS','1','2',NULL,NULL,NULL,false,'7')->>'status' = 'invalid', 'year 7 is refused');
SELECT t_assert(submit_request('90-1','y1@student.guc.edu.eg','CS','1','2',NULL,NULL,NULL,false,'abc')->>'status' = 'invalid', 'a non-number year is refused');
SELECT t_assert(submit_request('90-1','y1@student.guc.edu.eg','CS','1','2',NULL,NULL,NULL,false,'1; DROP TABLE submissions')->>'status' = 'invalid', 'an injected year is refused');
SELECT t_assert(submit_request('90-1','y1@student.guc.edu.eg','CS','1','2',NULL,NULL,NULL,false,'6')->>'status' = 'queued', 'year 6 is accepted');
SELECT t_assert(submit_request('90-2','y2@student.guc.edu.eg','CS','2','1',NULL,NULL,NULL,false,'3')->>'status' = 'queued', 'a mirror swap in a DIFFERENT year does not match');
SELECT t_assert(check_status('90-2','y2@student.guc.edu.eg')->>'status' = 'waiting', 'the different-year student is still waiting');
SELECT t_assert((check_status('90-2','y2@student.guc.edu.eg')->>'study_year') = '3', 'status shows the study year');
SELECT t_assert(submit_request('90-3','y3@student.guc.edu.eg','CS','2','1',NULL,NULL,NULL,false,'6')->>'status' = 'matched', 'the same major and year matches');
RESET ROLE;
SELECT t_assert((SELECT status FROM submissions WHERE student_id='90-2') = 'waiting', 'the year-3 student was not touched by the match');
SELECT t_assert((SELECT study_year FROM submissions WHERE student_id='90-1') = 6, 'the year is stored');
-- changing the year via edit moves the student back in the queue, and can create a match
SET ROLE anon;
SELECT t_assert(edit_request('90-2','y2@student.guc.edu.eg','CS','2','1',NULL,NULL,NULL,'3')->>'status' = 'updated', 'editing with the same year only keeps the place');
SELECT t_assert(edit_request('90-2','y2@student.guc.edu.eg','CS','2','1',NULL,NULL,NULL,'x')->>'status' = 'invalid', 'edit refuses an invalid year');
SELECT submit_request('90-4','y4@student.guc.edu.eg','CS','1','2',NULL,NULL,NULL,false,'4');
SELECT t_assert(edit_request('90-2','y2@student.guc.edu.eg','CS','2','1',NULL,NULL,NULL,'4')->>'status' = 'matched', 'changing the year to match a waiting student matches them');
RESET ROLE;
SELECT t_assert((SELECT study_year FROM submissions WHERE student_id='90-2') = 4, 'edit stored the new year');
-- different majors with the same year still do not match
SET ROLE anon;
SELECT submit_request('91-1','m1@student.guc.edu.eg','Law','1','2',NULL,NULL,NULL,false,'2');
SELECT t_assert(submit_request('91-2','m2@student.guc.edu.eg','CS','2','1',NULL,NULL,NULL,false,'2')->>'status' = 'queued', 'same year but different major does not match');
-- cancel + rematch respects the year
SELECT submit_request('92-1','r1@student.guc.edu.eg','Eng','1','2',NULL,NULL,NULL,false,'1');
SELECT submit_request('92-2','r2@student.guc.edu.eg','Eng','2','1',NULL,NULL,NULL,false,'1');
SELECT submit_request('92-3','r3@student.guc.edu.eg','Eng','2','1',NULL,NULL,NULL,false,'5');
SELECT t_assert(cancel_request('92-2','r2@student.guc.edu.eg')->>'was' = 'matched', 'cancelled a matched request');
SELECT t_assert(check_status('92-1','r1@student.guc.edu.eg')->>'status' = 'waiting', 'partner is not rematched with a student from another year');
RESET ROLE;
-- requests from before the update have no year and only match each other
INSERT INTO submissions (student_id, email, major, current_tut, desired_tut, status) VALUES
  ('93-1','o1@student.guc.edu.eg','Old','1','2','waiting'), ('93-2','o2@student.guc.edu.eg','Old','2','1','waiting');
SELECT t_assert((SELECT _find_match((SELECT id FROM submissions WHERE student_id='93-2'))->>'matched')::boolean = true, 'old requests without a year can still match each other');
-- privacy: the old signatures are gone and helpers stay private
SELECT t_assert((SELECT count(*) FROM pg_proc WHERE proname='submit_request') = 1, 'only one submit_request exists');
SELECT t_assert((SELECT count(*) FROM pg_proc WHERE proname='edit_request') = 1, 'only one edit_request exists');
SET ROLE anon;
SELECT t_denied($$SELECT _clean_request('1-1','a@b','m','1','2',NULL,NULL,NULL,'1')$$, 'anon cannot call _clean_request');
SELECT t_denied($$SELECT _find_match(gen_random_uuid())$$, 'anon cannot call _find_match');
RESET ROLE;
