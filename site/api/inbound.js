// Forwards mail sent to privacy@ / hello@murmurbee.com to Kai's inbox.
// Resend receives the mail (MX on murmurbee.com) and calls this webhook; we verify Resend's signature, fetch the
// message from Resend's Received Emails API, and send it on with Reply-To set to the original sender.
// Needs two Vercel environment variables (set by hand, never committed): RESEND_API_KEY and RESEND_WEBHOOK_SECRET.
import { Webhook } from "svix";

const FORWARD_TO = "kaikaushik1995@gmail.com";
const FROM = "MurmurBee <forward@murmurbee.com>";
const ADDRESSES = new Set(["privacy@murmurbee.com", "hello@murmurbee.com"]);

const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);

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

  const sender = email.headers?.from || email.from || "unknown sender";
  const note = `Sent to ${to.join(", ")} by ${sender}`;
  const body = {
    from: FROM,
    to: [FORWARD_TO],
    reply_to: [email.from],
    subject: `[murmurbee.com] ${email.subject || "(no subject)"}`,
    text: `${note}\n\n${email.text || "(no plain-text body)"}`,
  };
  if (email.html) body.html = `<p style="color:#6A5B45;font-size:13px">${esc(note)}</p><hr>${email.html}`;

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
