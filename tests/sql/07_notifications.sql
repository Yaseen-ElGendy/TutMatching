-- emails: queued by the database, pushed by a trigger, retried, and sent only once
SET ROLE anon;
SELECT submit_request('55-1','a@student.guc.edu.eg','CS','1','2',NULL,NULL,NULL,false);
SELECT submit_request('55-2','b@student.guc.edu.eg','CS','2','1',NULL,NULL,NULL,false);
RESET ROLE;
SELECT t_assert((SELECT count(*) FROM net.calls) = 1, 'a new notification immediately calls the email function');
SELECT t_assert((SELECT body->>'notification_id' FROM net.calls) = (SELECT id::text FROM notifications), 'the call carries only the notification id');
SELECT t_assert((SELECT url FROM net.calls) LIKE '%/notify-match', 'the call goes to notify-match');

-- a web-request failure must never block matching
SET app.net_fail = '1';
SET ROLE anon;
SELECT submit_request('56-1','c@student.guc.edu.eg','CS','3','4',NULL,NULL,NULL,false);
SELECT t_assert(submit_request('56-2','d@student.guc.edu.eg','CS','4','3',NULL,NULL,NULL,false)->>'status' = 'matched', 'matching still works when the web request fails');
RESET ROLE;
SET app.net_fail = '0';
SELECT t_assert((SELECT count(*) FROM notifications) = 2, 'the notification is still saved for retry');

-- retry job
SELECT t_assert(send_pending_notifications() = 0, 'recent notifications are left alone for 2 minutes');
UPDATE notifications SET created_at = now() - interval '5 minutes' WHERE sent_at IS NULL;
DELETE FROM net.calls;
SELECT t_assert(send_pending_notifications() = 2, 'old unsent notifications are retried');
SELECT t_assert((SELECT count(*) FROM net.calls) = 2, 'a retry calls the email function');
SELECT t_assert((SELECT min(attempts) FROM notifications) = 1, 'attempts are counted');
UPDATE notifications SET sent_at = now() WHERE recipient_email = 'a@student.guc.edu.eg';
UPDATE notifications SET attempts = 5 WHERE recipient_email = 'c@student.guc.edu.eg';
DELETE FROM net.calls;
SELECT t_assert(send_pending_notifications() = 0, 'sent notifications and ones tried 5 times are not retried');

-- claim / finish / release, as the email function uses them
SET ROLE service_role;
SELECT t_assert((SELECT claim_notification(id)->>'kind' FROM notifications WHERE recipient_email = 'c@student.guc.edu.eg') = 'matched', 'first claim returns the notification');
SELECT t_assert((SELECT claim_notification(id) IS NULL FROM notifications WHERE recipient_email = 'c@student.guc.edu.eg'), 'second claim returns nothing (no double send)');
SELECT (SELECT release_notification(id) FROM notifications WHERE recipient_email = 'c@student.guc.edu.eg');
SELECT t_assert((SELECT claim_notification(id)->>'kind' FROM notifications WHERE recipient_email = 'c@student.guc.edu.eg') = 'matched', 'a released notification can be claimed again');
SELECT (SELECT finish_notification(id) FROM notifications WHERE recipient_email = 'c@student.guc.edu.eg');
SELECT t_assert((SELECT claim_notification(id) IS NULL FROM notifications WHERE recipient_email = 'c@student.guc.edu.eg'), 'a finished notification can never be claimed again');
RESET ROLE;
