-- the admin data is only for logins listed in `admins`
INSERT INTO auth.users (id, email) VALUES ('00000000-0000-0000-0000-0000000000a1', 'admin@example.com'), ('00000000-0000-0000-0000-0000000000b2', 'student@example.com');
SET ROLE anon;
SELECT submit_request('55-1','a@student.guc.edu.eg','CS','1','2',NULL,NULL,'alice_wa',false);
SELECT submit_request('55-2','b@student.guc.edu.eg','CS','2','1',NULL,NULL,NULL,false);
SELECT submit_request('55-3','c@student.guc.edu.eg','Law','4','5',NULL,NULL,NULL,false);
SELECT submit_request('55-4','d@student.guc.edu.eg','Law','7','8',NULL,NULL,NULL,false);
SELECT cancel_request('55-4','d@student.guc.edu.eg');
RESET ROLE;

-- logged in but not an admin
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000b2', false);
SET ROLE authenticated;
SELECT t_assert(is_admin() = false, 'a normal logged-in user is not an admin');
DO $$ BEGIN
  PERFORM admin_overview();
  RAISE EXCEPTION 'FAIL: non-admin could read admin data';
EXCEPTION WHEN raise_exception THEN
  IF SQLERRM LIKE 'FAIL%' THEN RAISE; END IF;
  RAISE NOTICE 'PASS: non-admin is refused admin data';
END $$;
RESET ROLE;

-- admin
INSERT INTO admins (user_id) VALUES ('00000000-0000-0000-0000-0000000000a1');
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000a1', false);
SET ROLE authenticated;
SELECT t_assert(is_admin() = true, 'the admin is recognised');
SELECT t_assert((admin_overview()->'counts'->>'waiting')::int = 1, 'admin sees waiting count');
SELECT t_assert((admin_overview()->'counts'->>'matched')::int = 2, 'admin sees matched count');
SELECT t_assert((admin_overview()->'counts'->>'cancelled')::int = 1, 'admin sees cancelled count');
SELECT t_assert((admin_overview()->'counts'->>'matches')::int = 1, 'admin sees match count');
SELECT t_assert(jsonb_array_length(admin_overview()->'waiting') = 1, 'admin sees the waiting list');
SELECT t_assert(admin_overview()->'waiting'->0->>'email' = 'c@student.guc.edu.eg', 'waiting list includes emails');
SELECT t_assert(jsonb_array_length(admin_overview()->'matches') = 1, 'admin sees the matches list');
SELECT t_assert(jsonb_array_length(admin_overview()->'notifications') >= 1, 'admin sees the notification log');
SELECT t_assert(jsonb_array_length(admin_overview()->'by_major') = 2, 'admin sees counts per major');
SELECT t_assert(admin_overview()->'counts' ? 'emails_failed', 'admin sees email failures count');
RESET ROLE;
SELECT set_config('request.jwt.claim.sub', '', false);
