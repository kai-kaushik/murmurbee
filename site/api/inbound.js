// Forwards mail sent to privacy@ / hello@murmurbee.com to Kai's inbox.
// Resend receives the mail (MX on murmurbee.com) and calls this webhook; we verify Resend's signature, fetch the
// message from Resend's Received Emails API, and send it on with Reply-To set to the original sender.
// Needs two Vercel environment variables (set by hand, never committed): RESEND_API_KEY and RESEND_WEBHOOK_SECRET.
import { Webhook } from "svix";

const FORWARD_TO = "kaikaushik1995@gmail.com";
const FROM = "MurmurBee <forward@murmurbee.com>";
const ADDRESSES = new Set(["privacy@murmurbee.com", "hello@murmurbee.com"]);

export async function POST(request) {
  const key = process.env.RESEND_API_KEY;
  const secret = process.env.RESEND_WEBHOOK_SECRET;
  if (!key || !secret) return new Response("not configured", { status: 500 });

  // Verify against the raw body, exactly as received.
  const raw = await request.text();
  let event;
  try {
    // Throws unless the signature and timestamp are valid; only then is the body trusted and parsed.
    new Webhook(secret).verify(raw, {
      "svix-id": request.headers.get("svix-id") ?? "",
      "svix-timestamp": request.headers.get("svix-timestamp") ?? "",
      "svix-signature": request.headers.get("svix-signature") ?? "",
    });
    event = JSON.parse(raw);
  } catch {
    return new Response("invalid signature", { status: 401 });
  }
  if (event.type !== "email.received") return new Response("ignored");

  const to = (event.data?.to ?? []).map((a) => String(a).toLowerCase());
  if (!to.some((a) => ADDRESSES.has(a))) return new Response("not an address we forward");

  const got = await fetch(`https://api.resend.com/emails/receiving/${encodeURIComponent(event.data.email_id)}`, {
    headers: { Authorization: `Bearer ${key}` },
  });
  if (!got.ok) return new Response("could not fetch the message", { status: 502 });
  const email = await got.json();

  // Plain text only. The From address is whatever the email claims, so it's labelled as unverified, used for Reply-To
  // only when it's a single well-formed address, and shown next to the SPF/DKIM/DMARC results Resend reports (if any).
  const claimed = String(email.from || event.data.from || "").trim();
  const wellFormed = /^[^\s@<>",;]+@[^\s@<>",;]+\.[^\s@<>",;]+$/.test(claimed);
  const auth = email.authentication && typeof email.authentication === "object" ? email.authentication : null;
  const checks = auth
    ? ["spf", "dkim", "dmarc"].filter((k) => auth[k] != null).map((k) => `${k.toUpperCase()}: ${String(auth[k])}`).join(", ")
    : "";
  const body = {
    from: FROM,
    to: [FORWARD_TO],
    subject: `[murmurbee.com] ${email.subject || "(no subject)"}`.replace(/[\r\n]+/g, " ").slice(0, 200),
    text: `Forwarded from ${to.join(", ")}\n` +
          `From (as claimed by the email, not verified): ${claimed || "(none)"}\n` +
          (checks ? `Sender authentication reported by Resend: ${checks}\n` : "") +
          `Treat links in this message with care: it came from outside.\n\n` +
          (email.text || "(This message had no plain-text version. Open it in the Resend dashboard to read it.)"),
  };
  if (wellFormed) body.reply_to = [claimed];

  const sent = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${key}`,
      "Content-Type": "application/json",
      "Idempotency-Key": `forward-${event.data.email_id}`, // a retried webhook never sends twice
    },
    body: JSON.stringify(body),
  });
  return new Response(sent.ok ? "forwarded" : "send failed", { status: sent.ok ? 200 : 502 });
}
