-- Bad input is refused by the database even if the page is bypassed.
SET ROLE anon;
SELECT t_assert(submit_request('abc','x@student.guc.edu.eg','CS','1','2',NULL,NULL,NULL,false)->>'status' = 'invalid', 'bad student id refused');
SELECT t_assert(submit_request('55-1','x@gmail.com','CS','1','2',NULL,NULL,NULL,false)->>'status' = 'invalid', 'non-GUC email refused');
SELECT t_assert(submit_request('55-1','x@student.guc.edu.eg.evil.com','CS','1','2',NULL,NULL,NULL,false)->>'status' = 'invalid', 'look-alike email domain refused');
SELECT t_assert(submit_request('55-1','x@student.guc.edu.eg','','1','2',NULL,NULL,NULL,false)->>'status' = 'invalid', 'empty major refused');
SELECT t_assert(submit_request('55-1','x@student.guc.edu.eg','CS','abc','2',NULL,NULL,NULL,false)->>'status' = 'invalid', 'non-numeric tutorial refused');
SELECT t_assert(submit_request('55-1','x@student.guc.edu.eg','CS','1','1',NULL,NULL,NULL,false)->>'status' = 'invalid', 'desired list containing current tutorial refused');
SELECT t_assert(submit_request('55-1','x@student.guc.edu.eg','CS','1','2,3,4,5,6,7,8,9,10,11,12',NULL,NULL,NULL,false)->>'status' = 'invalid', 'more than 10 desired tutorials refused');
SELECT t_assert(submit_request('55-1','x@student.guc.edu.eg','CS','1','2,x',NULL,NULL,NULL,false)->>'status' = 'invalid', 'non-numeric desired tutorial refused');
SELECT t_assert(submit_request('55-1','x@student.guc.edu.eg','CS','1','2','9',NULL,NULL,false)->>'status' = 'invalid', 'bad German level refused');
SELECT t_assert(submit_request('55-1','x@student.guc.edu.eg','CS','1','2',NULL,'ZZ',NULL,false)->>'status' = 'invalid', 'bad English level refused');
SELECT t_assert(submit_request('55-1','x@student.guc.edu.eg','CS','1','2',NULL,NULL,'bad name<script>',false)->>'status' = 'invalid', 'unsafe WhatsApp text refused');
RESET ROLE;
SELECT t_assert((SELECT count(*) FROM submissions) = 0, 'nothing was saved from refused requests');
SELECT t_assert((SELECT count(*) FROM rate_events) = 0, 'refused requests are not counted against the limit');

SET ROLE anon;
SELECT t_assert(submit_request(' 55-1 ','  Alice@Student.GUC.edu.eg ','CS','1','7, 3,3,4',NULL,NULL,'@alice.wa',false)->>'status' = 'queued', 'messy but valid input accepted');
RESET ROLE;
SELECT t_assert((SELECT email FROM submissions) = 'alice@student.guc.edu.eg', 'email stored in lowercase');
SELECT t_assert((SELECT student_id FROM submissions) = '55-1', 'student id trimmed');
SELECT t_assert((SELECT desired_tut FROM submissions) = '3,4,7', 'desired list cleaned: no spaces, no duplicates, fixed order');
SELECT t_assert((SELECT whatsapp FROM submissions) = 'alice.wa', 'leading @ removed from WhatsApp username');
