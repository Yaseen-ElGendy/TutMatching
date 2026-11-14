-- ============================================================
-- TutMatching v5.1: emails are sent by the database, not the browser
-- Run this ENTIRE file ONCE in the Supabase SQL Editor (after v5). Safe to re-run.
--
-- Before: the web page asked the email function to send each email, so a
-- student closing the tab at the wrong moment could stop an email going out.
-- Now: the moment a notification is saved, the database itself calls the email
-- function. A retry job covers failures. Each email still sends only once.
-- ============================================================

ALTER TABLE notifications ADD COLUMN IF NOT EXISTS attempts INT NOT NULL DEFAULT 0;

-- pg_net lets the database make web requests (it may already be enabled)
DO $$
BEGIN
  CREATE EXTENSION IF NOT EXISTS pg_net;
EXCEPTION WHEN others THEN
  RAISE NOTICE 'Could not enable pg_net automatically (%). Enable it in Database > Extensions, then run this file again.', SQLERRM;
END $$;

-- Calls the email function for one notification. Never blocks matching if it fails.
CREATE OR REPLACE FUNCTION public._push_notification(p_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM net.http_post(
    url := 'https://pyegfqoxnofszjbpcyil.functions.supabase.co/notify-match',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      -- the public anon key (same one that is already in index.html)
      'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InB5ZWdmcW94bm9mc3pqYnBjeWlsIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODk3NjEzOTgsImV4cCI6MjEwNTMzNzM5OH0.4pO-72hxkb2zMyDK3rRmNYB4wen-ibEq6B7X9RBKW38'
    ),
    body := jsonb_build_object('notification_id', p_id)
  );
EXCEPTION WHEN others THEN
  RAISE WARNING 'push notification % failed: %', p_id, SQLERRM;
END;
$$;

CREATE OR REPLACE FUNCTION public._trg_push_notification()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM _push_notification(NEW.id);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS push_notification_after_insert ON notifications;
CREATE TRIGGER push_notification_after_insert
  AFTER INSERT ON notifications
  FOR EACH ROW EXECUTE FUNCTION public._trg_push_notification();

-- Retry: re-sends emails that did not go out (at most 5 tries, only for 2 days)
CREATE OR REPLACE FUNCTION public.send_pending_notifications()
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE r RECORD; n INT := 0;
BEGIN
  FOR r IN
    SELECT id FROM notifications
    WHERE sent_at IS NULL AND attempts < 5
      AND created_at < now() - interval '2 minutes'
      AND created_at > now() - interval '2 days'
    ORDER BY created_at
    LIMIT 20
  LOOP
    UPDATE notifications SET attempts = attempts + 1 WHERE id = r.id;
    PERFORM _push_notification(r.id);
    n := n + 1;
  END LOOP;
  RETURN n;
END;
$$;

REVOKE ALL ON FUNCTION public._push_notification(UUID)       FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._trg_push_notification()        FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.send_pending_notifications()    FROM PUBLIC, anon, authenticated;

-- Run the retry every 5 minutes (needs pg_cron; skipped with a notice if unavailable)
DO $$
BEGIN
  CREATE EXTENSION IF NOT EXISTS pg_cron;
  PERFORM cron.schedule('tutmatching-retry-emails', '*/5 * * * *', 'SELECT public.send_pending_notifications()');
EXCEPTION WHEN others THEN
  RAISE NOTICE 'pg_cron not enabled (%). Emails still send instantly; only the retry job is missing. Enable pg_cron in Database > Extensions and run this file again.', SQLERRM;
END $$;
