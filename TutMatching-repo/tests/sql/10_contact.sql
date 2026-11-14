-- contact detail: every request needs a WhatsApp username, a phone number, or both
SET ROLE anon;
SELECT t_assert(submit_request('80-1','c1@student.guc.edu.eg','CS','1','2',NULL,NULL,NULL,false,'1',NULL)->>'status' = 'invalid', 'no WhatsApp and no phone is refused');
SELECT t_assert(submit_request('80-1','c1@student.guc.edu.eg','CS','1','2',NULL,NULL,NULL,false,'1')->>'status' = 'invalid', 'an old page that sends no contact detail is refused');
SELECT t_assert(submit_request('80-1','c1@student.guc.edu.eg','CS','1','2',NULL,NULL,'   ',false,'1','   ')->>'status' = 'invalid', 'blank spaces count as nothing');
SELECT t_assert(submit_request('80-1','c1@student.guc.edu.eg','CS','1','2',NULL,NULL,'@',false,'1',NULL)->>'status' = 'invalid', 'a lone @ counts as nothing');
SELECT t_assert((submit_request('80-1','c1@student.guc.edu.eg','CS','1','2',NULL,NULL,NULL,false,'1',NULL)->>'message') LIKE '%WhatsApp username or your phone number%', 'the error says what to enter');
SELECT t_assert(submit_request('80-1','c1@student.guc.edu.eg','CS','1','2',NULL,NULL,NULL,false,'1','abc')->>'status' = 'invalid', 'letters in the phone number are refused');
SELECT t_assert(submit_request('80-1','c1@student.guc.edu.eg','CS','1','2',NULL,NULL,NULL,false,'1','123456')->>'status' = 'invalid', 'a phone number with 6 digits is too short');
SELECT t_assert(submit_request('80-1','c1@student.guc.edu.eg','CS','1','2',NULL,NULL,NULL,false,'1','1234567890123456')->>'status' = 'invalid', 'a phone number with 16 digits is too long');
SELECT t_assert(submit_request('80-1','c1@student.guc.edu.eg','CS','1','2',NULL,NULL,NULL,false,'1','+')->>'status' = 'invalid', 'a lone + is refused');
SELECT t_assert(submit_request('80-1','c1@student.guc.edu.eg','CS','1','2',NULL,NULL,NULL,false,'1','010+1234567')->>'status' = 'invalid', 'a + in the middle is refused');
SELECT t_assert(submit_request('80-1','c1@student.guc.edu.eg','CS','1','2',NULL,NULL,NULL,false,'1','0100; DROP TABLE submissions')->>'status' = 'invalid', 'an injected phone number is refused');
SELECT t_assert(submit_request('80-1','c1@student.guc.edu.eg','CS','1','2',NULL,NULL,NULL,false,'1','<script>alert(1)</script>')->>'status' = 'invalid', 'a script in the phone field is refused');
SELECT t_assert(submit_request('80-1','c1@student.guc.edu.eg','CS','1','2',NULL,NULL,'bad name',false,'1','01012345678')->>'status' = 'invalid', 'a bad WhatsApp username is still refused when a phone is given');
RESET ROLE;
SELECT t_assert((SELECT count(*) FROM submissions) = 0, 'nothing was saved by any refused request');

-- phone only
SET ROLE anon;
SELECT t_assert(submit_request('80-1','c1@student.guc.edu.eg','CS','1','2',NULL,NULL,NULL,false,'1','+20 101 234-5678')->>'status' = 'queued', 'a phone number alone is accepted');
RESET ROLE;
SELECT t_assert((SELECT phone_number FROM submissions WHERE student_id='80-1') = '+201012345678', 'spaces and dashes are removed, the + is kept');
SELECT t_assert((SELECT whatsapp FROM submissions WHERE student_id='80-1') IS NULL, 'no WhatsApp stored when none was given');

-- WhatsApp only still works, and the matched partners see each other's details
SET ROLE anon;
SELECT t_assert((submit_request('80-2','c2@student.guc.edu.eg','CS','2','1',NULL,NULL,'bob_wa',false,'1',NULL)->>'partner_phone') = '+201012345678', 'the student who just submitted is shown the waiting partner''s phone number');
SELECT t_assert((check_status('80-2','c2@student.guc.edu.eg')->>'partner_phone') = '+201012345678', 'check_status shows the partner''s phone number');
SELECT t_assert((check_status('80-2','c2@student.guc.edu.eg')->>'partner_whatsapp') IS NULL, 'and no WhatsApp when the partner gave none');
SELECT t_assert((check_status('80-1','c1@student.guc.edu.eg')->>'partner_whatsapp') = 'bob_wa', 'the first student sees the partner''s WhatsApp username');
SELECT t_assert((check_status('80-1','c1@student.guc.edu.eg')->>'partner_phone') IS NULL, 'and no phone when the partner gave none');
SELECT t_assert((check_status('80-1','c1@student.guc.edu.eg')->>'phone') = '+201012345678', 'a student sees their own phone number');
RESET ROLE;
SELECT t_assert((SELECT phone_number FROM submissions WHERE student_id='80-2') IS NULL, 'no phone stored when none was given');
SELECT t_assert((SELECT partner_whatsapp FROM notifications WHERE kind='matched') = 'bob_wa', 'the match email carries the WhatsApp username');
SELECT t_assert((SELECT partner_phone FROM notifications WHERE kind='matched') IS NULL, 'and no phone when none was given');

-- both given
DELETE FROM notifications; DELETE FROM matches; DELETE FROM submissions; DELETE FROM rate_events;
SET ROLE anon;
SELECT submit_request('81-1','d1@student.guc.edu.eg','CS','1','2',NULL,NULL,'amy_wa',false,'2','(0100) 111.2222');
SELECT t_assert(submit_request('81-2','d2@student.guc.edu.eg','CS','2','1',NULL,NULL,NULL,false,'2','00201001112223')->>'status' = 'matched', '00-prefixed numbers are accepted');
RESET ROLE;
SELECT t_assert((SELECT phone_number FROM submissions WHERE student_id='81-1') = '01001112222', 'brackets, spaces and dots are removed');
SELECT t_assert((SELECT partner_phone FROM notifications WHERE kind='matched') = '00201001112223', 'the match email carries the newcomer''s phone number');
SELECT t_assert((SELECT partner_whatsapp FROM notifications WHERE kind='matched') IS NULL, 'and no WhatsApp when the newcomer gave none');

-- the match email carries the phone number when the newcomer gave one
DELETE FROM notifications; DELETE FROM matches; DELETE FROM submissions; DELETE FROM rate_events;
SET ROLE anon;
SELECT submit_request('82-1','e1@student.guc.edu.eg','CS','1','2',NULL,NULL,'cat_wa',false,'3','01211112222');
SELECT submit_request('82-2','e2@student.guc.edu.eg','CS','2','1',NULL,NULL,'dan_wa',false,'3','01233334444');
RESET ROLE;
SELECT t_assert((SELECT partner_phone FROM notifications WHERE kind='matched' AND recipient_email='e1@student.guc.edu.eg') = '01233334444', 'the match email carries the newcomer''s phone number');
SELECT t_assert((SELECT partner_whatsapp FROM notifications WHERE kind='matched' AND recipient_email='e1@student.guc.edu.eg') = 'dan_wa', 'and the newcomer''s WhatsApp username');

-- cancel erases the phone number, and a rematch email carries the new partner's phone number
SET ROLE anon;
SELECT submit_request('82-3','e3@student.guc.edu.eg','CS','2','1',NULL,NULL,'eve_wa',false,'3','01255556666');
SELECT cancel_request('82-2','e2@student.guc.edu.eg');
RESET ROLE;
SELECT t_assert((SELECT phone_number FROM submissions WHERE student_id='82-2') IS NULL AND (SELECT status FROM submissions WHERE student_id='82-2') = 'cancelled', 'a cancelled request has its phone number removed');
SELECT t_assert((SELECT partner_phone FROM notifications WHERE kind='cancelled') = '01255556666', 'the rematch email carries the new partner''s phone number');

-- editing: contact detail stays required, and changing it keeps the queue place
DELETE FROM notifications; DELETE FROM matches; DELETE FROM submissions; DELETE FROM rate_events;
SET ROLE anon;
SELECT submit_request('83-1','f1@student.guc.edu.eg','CS','1','2',NULL,NULL,NULL,false,'1','01311112222');
RESET ROLE;
DO $$ BEGIN PERFORM set_config('t.f1', (SELECT created_at::text FROM submissions WHERE student_id='83-1'), false); END $$;
SET ROLE anon;
SELECT t_assert(edit_request('83-1','f1@student.guc.edu.eg','CS','1','2',NULL,NULL,NULL,'1',NULL)->>'status' = 'invalid', 'an edit cannot remove all contact detail');
SELECT t_assert(edit_request('83-1','f1@student.guc.edu.eg','CS','1','2',NULL,NULL,NULL,'1','12ab')->>'status' = 'invalid', 'an edit refuses a bad phone number');
SELECT t_assert(edit_request('83-1','f1@student.guc.edu.eg','CS','1','2',NULL,NULL,NULL,'1','01399998888')->>'status' = 'updated', 'the phone number can be changed');
SELECT t_assert(edit_request('83-1','f1@student.guc.edu.eg','CS','1','2',NULL,NULL,'fay_wa','1',NULL)->>'status' = 'updated', 'switching from a phone number to a WhatsApp username is fine');
RESET ROLE;
SELECT t_assert((SELECT phone_number FROM submissions WHERE student_id='83-1') IS NULL AND (SELECT whatsapp FROM submissions WHERE student_id='83-1') = 'fay_wa', 'the switch was saved');
SELECT t_assert((SELECT created_at::text FROM submissions WHERE student_id='83-1') = current_setting('t.f1'), 'changing only the contact detail keeps the queue place');

-- a request saved before this update has no contact detail: it still matches, and an edit asks for one
INSERT INTO submissions (student_id, email, major, study_year, current_tut, desired_tut, status, created_at)
VALUES ('84-1','g1@student.guc.edu.eg','CS',1,'5','6','waiting', now() - interval '1 hour');
SET ROLE anon;
SELECT t_assert(submit_request('84-2','g2@student.guc.edu.eg','CS','6','5',NULL,NULL,'gus_wa',false,'1',NULL)->>'status' = 'matched', 'an older request without contact detail still matches');
SELECT t_assert((check_status('84-2','g2@student.guc.edu.eg')->>'partner_phone') IS NULL AND (check_status('84-2','g2@student.guc.edu.eg')->>'partner_whatsapp') IS NULL, 'and the partner simply has no phone or WhatsApp to show');
RESET ROLE;
INSERT INTO submissions (student_id, email, major, study_year, current_tut, desired_tut, status)
VALUES ('84-3','g3@student.guc.edu.eg','Law',1,'5','6','waiting');
SET ROLE anon;
SELECT t_assert(edit_request('84-3','g3@student.guc.edu.eg','Law','5','6',NULL,NULL,NULL,'1',NULL)->>'status' = 'invalid', 'editing an older request asks for contact detail');
SELECT t_assert(edit_request('84-3','g3@student.guc.edu.eg','Law','5','6',NULL,NULL,NULL,'1','01411112222')->>'status' = 'updated', 'and accepts one');
RESET ROLE;

-- a matched request still cannot be edited
SET ROLE anon;
SELECT t_assert(edit_request('84-2','g2@student.guc.edu.eg','CS','6','5',NULL,NULL,'gus_wa','1','01499990000')->>'status' = 'matched_locked', 'a matched request cannot be edited, phone number included');
RESET ROLE;
SELECT t_assert((SELECT phone_number FROM submissions WHERE student_id='84-2') IS NULL, 'and nothing changed');

-- the admin page gets the phone number, and nobody else does
INSERT INTO auth.users (id, email) VALUES ('00000000-0000-0000-0000-0000000000a9', 'admin10@example.com');
INSERT INTO admins (user_id) VALUES ('00000000-0000-0000-0000-0000000000a9');
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a9', false);
SET ROLE authenticated;
SELECT t_assert((SELECT bool_or(w->>'phone' = '01411112222') FROM jsonb_array_elements(admin_overview()->'waiting') w), 'the admin sees the phone number of waiting students');
RESET ROLE;
SELECT set_config('request.jwt.claim.sub', '', false);
SET ROLE anon;
SELECT t_denied($$SELECT phone_number FROM submissions$$, 'anon cannot read phone numbers from the table');
SELECT t_denied($$SELECT partner_phone FROM notifications$$, 'anon cannot read phone numbers from the notification table');
RESET ROLE;
