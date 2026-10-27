# TutMatching

A web app that matches GUC students who want to swap tutorial slots. Students enter their current and desired tutorials, and the app pairs them with a compatible student, or queues them and emails them when a match appears. It replaces the usual approach of posting swap requests in a WhatsApp group where messages get buried.

**Live site:** _add your Vercel link here_

## What it does

- Matches students in the **same major** whose tutorial wishes are **mutual**; the oldest waiting request is matched first.
- Accepts a **list** of acceptable tutorials (for example `3,4,5`), so flexible students match faster.
- Flags swaps where German or English levels differ and tells both students to contact the academic coordinator.
- Emails a waiting student the moment a match is found, with a link to the GUC portal to make the swap.
- Lets a student **check their status** and **cancel** their request. Cancelling a match puts the partner back in the queue, tries to rematch them straight away, and emails them.
- Lets a student **edit** a waiting request (changing major or tutorials sends them to the back of the queue; changing only levels or WhatsApp keeps their place). A matched request can't be edited; the student cancels and resubmits.
- **Rate limit:** 5 submit/edit/cancel actions per hour per student ID and per email (status checks: 20 per hour).
- Private **admin page** (`admin.html`, login required) showing counts, waiting requests, matches and email delivery.
- Optional WhatsApp username, shown to the matched partner only, as an easier way to connect.
- Accepts only `@student.guc.edu.eg` addresses, one active request per student ID and per email.

## How it works

```
Browser (single index.html, hosted on Vercel)
   |  supabase.rpc(...)  only a few functions are reachable
   v
Supabase Postgres  --  submit_request / check_status / cancel_request / edit_request
   |  tables are private (no public read or write)
   |  new row in `notifications`  ->  trigger (pg_net)
   v
Supabase Edge Function `notify-match` (Deno)  ->  Gmail SMTP  ->  student's inbox
```

## Design decisions

- **Matching runs inside the database, one request at a time.** A Postgres advisory lock serialises matching, so two students submitting at the same moment can never be matched to the same partner. Tested with 60 simultaneous requests: 30 matches, nobody matched twice.
- **Private database.** The public API key has no access to any table. The website can only call three functions, and each one needs the student ID and email together. Other students' emails are never exposed, and a partner's contact details are only returned to the matched pair.
- **The email function can't be abused.** The page never tells the function who to email. The function receives a notification id and looks up the recipient and message in the database, and a claim step guarantees each email is sent at most once.
- **Emails are sent by the database, not the browser,** so closing the tab can't lose an email. Failed sends are retried every 5 minutes (up to 5 times).
- **Input is validated twice**: in the page for quick feedback and again in the database functions, which don't trust the page.
- **Automated tests** (`tests/`, run by GitHub Actions on every push): privacy (the public key can't read any table), validation, matching, cancel and rematch, edit rules, rate limits, email queue, admin access, 60 simultaneous requests, and the email function with a fake mailer.
- **Admin page uses real login.** Only accounts listed in the `admins` table get data from `admin_overview()`; sign-ups are disabled in Supabase.
- **Free to run:** Supabase free tier, Vercel hobby plan, and a dedicated Gmail account with an app password for email.

## Known limitations

- There is no email verification. A student ID plus email acts as a weak password, so anyone who knows both can view or cancel that request.
- Rate limits are per student ID and email, so someone who knows both could use up another student's hourly allowance.
- Gmail's daily sending limit applies.

## Project structure

```
index.html                       the whole front end
admin.html                       private admin page
tests/                           database + email-function tests
.github/workflows/tests.yml      runs the tests on every push
supabase/functions/notify-match/ email-sending Edge Function (index.ts)
sql/tutmatching-v5-migration.sql tables, private access, matching, cancel, status
sql/tutmatching-v5.1-emails.sql  database-triggered emails and retry job
sql/tutmatching-v5.2-email-details.sql  match email includes partner details
sql/tutmatching-v5.3-cancel-details.sql  cancellation email carries the new partner after a rematch
sql/tutmatching-v6-edit-limits-admin.sql  edit request, rate limits, admin data
sql/admin-setup.sql              makes your account an admin
sql/clear-test-data.sql          wipes test data
```

## Setup

1. Create a Supabase project and run the SQL files in the SQL Editor, in order (v5, v5.1, v5.2, v5.3, v6). If you ever re-run an earlier file, re-run v5.1 and v6 after it.
2. Create a Gmail account for sending, turn on 2-step verification, and create an app password.
3. Deploy the function:
   ```
   npx supabase login
   npx supabase link --project-ref <your-project-ref>
   npx supabase secrets set GMAIL_USER=<gmail address>
   npx supabase secrets set GMAIL_APP_PASSWORD=<app password>
   npx supabase functions deploy notify-match
   ```
4. Put your Supabase URL and anon key at the top of the script in `index.html`, and update the project URLs inside the v5.1 SQL file.
5. Admin page: in Supabase → Authentication → Users add your own user, turn off "Allow new users to sign up" (Authentication → Sign In / Providers), then run `admin-setup.sql` with your email. Open `/admin.html` on your site.
6. Push to GitHub and import the repo in Vercel.

## Running the tests

```
cd tests && npm install && npm test        # email function
PGHOST=... PGUSER=... SQL_DIR=../sql bash run.sh   # database (needs a throwaway Postgres)
```

## Tech

HTML, CSS and vanilla JavaScript · Supabase (Postgres, Row Level Security, SQL functions, Edge Functions with Deno, pg_net, pg_cron) · Gmail SMTP · Vercel
