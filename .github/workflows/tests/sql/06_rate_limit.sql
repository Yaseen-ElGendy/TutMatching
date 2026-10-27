-- 5 submit/edit/cancel attempts per hour per student ID and per email; 20 status checks per hour
SET ROLE anon;
SELECT cancel_request('50-1','x@student.guc.edu.eg') FROM generate_series(1,5);
SELECT t_assert((cancel_request('50-1','x@student.guc.edu.eg')->>'rate_limited') = 'true', 'the 6th attempt for one ID within an hour is refused');
SELECT t_assert((cancel_request('50-2','x@student.guc.edu.eg')->>'rate_limited') = 'true', 'the same email is limited even with another ID');
SELECT t_assert((cancel_request('50-1','other@student.guc.edu.eg')->>'rate_limited') = 'true', 'the same ID is limited even with another email');
SELECT t_assert((cancel_request('50-3','fresh@student.guc.edu.eg')->>'rate_limited') IS NULL, 'a different ID and email is not affected');
SELECT t_assert(submit_request('50-1','x@student.guc.edu.eg','CS','1','2',NULL,NULL,NULL,false)->>'status' = 'rate_limited', 'submit is limited too');
SELECT t_assert(edit_request('50-1','x@student.guc.edu.eg','CS','1','2',NULL,NULL,NULL)->>'status' = 'rate_limited', 'edit is limited too');
SELECT t_assert((check_status('50-1','x@student.guc.edu.eg')->>'rate_limited') IS NULL, 'status checks have their own separate counter');
RESET ROLE;
SELECT t_assert((SELECT count(*) FROM submissions) = 0, 'limited requests saved nothing');

-- the window moves: old attempts stop counting after an hour
UPDATE rate_events SET at = now() - interval '2 hours';
SET ROLE anon;
SELECT t_assert((cancel_request('50-1','x@student.guc.edu.eg')->>'rate_limited') IS NULL, 'attempts older than an hour no longer count');

-- status check limit
SELECT check_status('51-1','y@student.guc.edu.eg') FROM generate_series(1,20);
SELECT t_assert((check_status('51-1','y@student.guc.edu.eg')->>'rate_limited') = 'true', 'the 21st status check in an hour is refused');
RESET ROLE;

-- a real student doing normal things stays under the limit
DELETE FROM rate_events;
SET ROLE anon;
SELECT t_assert(submit_request('52-1','n@student.guc.edu.eg','CS','1','2',NULL,NULL,NULL,false)->>'status' = 'queued', 'normal use: submit');
SELECT t_assert(submit_request('52-1','n@student.guc.edu.eg','CS','1','3',NULL,NULL,NULL,false)->>'status' = 'needs_replace', 'normal use: replace prompt');
SELECT t_assert(submit_request('52-1','n@student.guc.edu.eg','CS','1','3',NULL,NULL,NULL,true)->>'status' = 'queued', 'normal use: replace');
SELECT t_assert(edit_request('52-1','n@student.guc.edu.eg','CS','1','3','1',NULL,NULL)->>'status' = 'updated', 'normal use: edit');
SELECT t_assert((cancel_request('52-1','n@student.guc.edu.eg')->>'cancelled') = 'true', 'normal use: cancel (5th action) still works');
RESET ROLE;
