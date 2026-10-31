-- Run once, AFTER creating your user in Supabase -> Authentication -> Users.
-- Replace the email below with the email of that user.
INSERT INTO admins (user_id)
SELECT id FROM auth.users WHERE email = 'PUT-YOUR-EMAIL-HERE'
ON CONFLICT DO NOTHING;

-- Check: this should return one row with your email. No rows = the email doesn't match a user.
SELECT u.email FROM admins a JOIN auth.users u ON u.id = a.user_id;
