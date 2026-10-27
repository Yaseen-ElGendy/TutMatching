// notify-match: sends the "matched" / "cancelled" emails.
// The page only sends a notification id. Recipient and content come from the
// database, so this function cannot be used to email arbitrary people, and
// each notification is sent at most once.
import { SMTPClient } from "https://deno.land/x/denomailer/mod.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const GUC_PORTAL_URL = "https://student.guc.edu.eg/";

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

async function rpc(name: string, args: Record<string, unknown>) {
  const url = Deno.env.get("SUPABASE_URL");
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !key) throw new Error("Server keys not available");
  const res = await fetch(`${url}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: { apikey: key, Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
    body: JSON.stringify(args),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`${name} failed: ${text}`);
  return text ? JSON.parse(text) : null;
}

function buildEmail(n: any, siteUrl: string) {
  const siteLine = siteUrl
    ? `\nNeed to do anything else, like checking your status or cancelling your request? Go to TutMatching: ${siteUrl}\n`
    : "";

  const coordinator = n.coordinator_needed
    ? `\n⚠️ You and your partner have different German/English levels. Please contact the academic coordinator together to approve this swap.\n`
    : "";

  // Older notifications (saved before partner details were added) fall back to "log back in"
  const partner = (heading: string) => n.partner_email
    ? `\n${heading}\n` +
      `  Student ID: ${n.partner_student_id}\n` +
      `  Email: ${n.partner_email}\n` +
      (n.partner_whatsapp ? `  WhatsApp username: ${n.partner_whatsapp}\n` : "")
    : `\nLog back into TutMatching to see your partner's contact details.\n`;

  const steps =
    `\nNext step: log in to your GUC portal to make the swap:\n` +
    `${GUC_PORTAL_URL}\n\n` +
    `1. In the sidebar menu, go to Scheduling → Change Group.\n` +
    `2. Submit your request using your partner's student ID${n.partner_student_id ? `: ${n.partner_student_id}` : ""}.\n` +
    `3. Once you've submitted, contact your partner and ask them to accept your request from their own portal. The swap is only complete when they accept.\n`;

  if (n.kind === "cancelled") {
    const intro = `Your matched partner cancelled their request for the tutorial swap (Tut ${n.your_tut}).\n`;
    if (n.rematched && n.partner_email) {
      return {
        subject: "Your TutMatching partner cancelled, but you have a new match",
        content:
          intro +
          `\nGood news: we've already found you a new match.\n` +
          `\nYour swap: Tut ${n.your_tut} → Tut ${n.partner_tut}\n` +
          partner("Your new partner:") +
          coordinator + steps + siteLine + `\n— TutMatching`,
      };
    }
    const tail = n.rematched
      ? `\nGood news: we've already found you a new match. Log back into TutMatching to see your new partner.\n`
      : `\nYou are back in the queue with your original place, and we'll email you as soon as a new match is found.\n`;
    return {
      subject: "Your TutMatching partner cancelled",
      content: intro + tail + siteLine + `\n— TutMatching`,
    };
  }

  return {
    subject: "You've been matched on TutMatching!",
    content:
      `Good news! A match was found for your tutorial swap request.\n\n` +
      `Your swap: Tut ${n.your_tut} → Tut ${n.partner_tut}\n` +
      partner("Your partner:") +
      coordinator + steps + siteLine + `\n— TutMatching`,
  };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  let id: string | undefined;
  try {
    ({ notification_id: id } = await req.json());
  } catch {
    return json({ error: "Invalid request" }, 400);
  }
  if (!id || typeof id !== "string") return json({ error: "Missing notification_id" }, 400);

  const GMAIL_USER = Deno.env.get("GMAIL_USER");
  const GMAIL_APP_PASSWORD = Deno.env.get("GMAIL_APP_PASSWORD");
  if (!GMAIL_USER || !GMAIL_APP_PASSWORD) return json({ error: "Email credentials not configured" }, 500);

  let claimed = false;
  try {
    const n = await rpc("claim_notification", { p_id: id });
    // Unknown id, already sent, or another request is sending it right now
    if (!n) return json({ success: true, skipped: true });
    claimed = true;

    const mail = buildEmail(n, Deno.env.get("SITE_URL") ?? "");
    const client = new SMTPClient({
      connection: {
        hostname: "smtp.gmail.com",
        port: 465,
        tls: true,
        auth: { username: GMAIL_USER, password: GMAIL_APP_PASSWORD },
      },
    });
    try {
      await client.send({ from: GMAIL_USER, to: n.recipient_email, subject: mail.subject, content: mail.content });
    } finally {
      try { await client.close(); } catch (_) { /* ignore */ }
    }

    await rpc("finish_notification", { p_id: id });
    return json({ success: true });
  } catch (err) {
    if (claimed) {
      try { await rpc("release_notification", { p_id: id }); } catch (_) { /* ignore */ }
    }
    return json({ error: (err as Error).message }, 500);
  }
});
