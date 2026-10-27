-- The public (anon) key must not be able to read or write any table or call internal functions.
SET ROLE anon;
SELECT t_denied('SELECT count(*) FROM submissions',   'anon cannot read submissions');
SELECT t_denied('SELECT count(*) FROM matches',       'anon cannot read matches');
SELECT t_denied('SELECT count(*) FROM notifications', 'anon cannot read notifications');
SELECT t_denied('SELECT count(*) FROM rate_events',   'anon cannot read rate_events');
SELECT t_denied('SELECT count(*) FROM admins',        'anon cannot read admins');
SELECT t_denied($$INSERT INTO submissions(student_id,email,major,current_tut,desired_tut) VALUES('1-1','a@b','m','1','2')$$, 'anon cannot insert submissions');
SELECT t_denied('UPDATE submissions SET status = ''matched''', 'anon cannot update submissions');
SELECT t_denied('DELETE FROM submissions', 'anon cannot delete submissions');
SELECT t_denied('SELECT _find_match(gen_random_uuid())', 'anon cannot call _find_match');
SELECT t_denied($$SELECT _rate_check('1-1','a@b','act',5)$$, 'anon cannot call _rate_check');
SELECT t_denied($$SELECT _clean_request('1-1','a@b','m','1','2',NULL,NULL,NULL)$$, 'anon cannot call _clean_request');
SELECT t_denied('SELECT claim_notification(gen_random_uuid())',   'anon cannot claim notifications');
SELECT t_denied('SELECT finish_notification(gen_random_uuid())',  'anon cannot finish notifications');
SELECT t_denied('SELECT release_notification(gen_random_uuid())', 'anon cannot release notifications');
SELECT t_denied('SELECT send_pending_notifications()', 'anon cannot trigger retries');
SELECT t_denied('SELECT admin_overview()', 'anon cannot read admin data');
SELECT t_denied('SELECT is_admin()',       'anon cannot call is_admin');
RESET ROLE;

SET ROLE authenticated;
SELECT t_denied('SELECT count(*) FROM submissions', 'logged-in users cannot read submissions either');
SELECT t_denied('SELECT claim_notification(gen_random_uuid())', 'logged-in users cannot claim notifications');
RESET ROLE;

SELECT t_assert(NOT EXISTS (SELECT 1 FROM pg_class WHERE relname IN ('submissions','matches','notifications','rate_events','admins') AND relkind = 'r' AND NOT relrowsecurity), 'row level security is on for every table');
SELECT t_assert(NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public'), 'there are no public policies');
SELECT t_assert(to_regclass('public.match_contacts') IS NULL, 'old match_contacts table is gone');
SELECT t_assert(NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'match_submission'), 'old match_submission function is gone');

SET ROLE service_role;
SELECT t_assert(claim_notification(gen_random_uuid()) IS NULL, 'service role can call claim_notification');
RESET ROLE;
