// ============================================================
// Edge Function : notify-lockout
//
// Alerte email aux administrateurs lorsqu'un blocage anti
// brute-force se déclenche (verrou par IP ou verrou global).
// Appelée depuis Postgres via pg_net (migration 08).
//
// Mêmes secrets SMTP que notify-proposal :
//   SMTP_USER, SMTP_PASS, NOTIFY_FROM_EMAIL, NOTIFY_TO_EMAILS
//   (SMTP_HOST / SMTP_PORT facultatifs, défauts Proton)
// plus EDGE_SHARED_SECRET : chaque requête doit porter l'en-tête
// « x-webhook-secret » égal à ce secret, sinon la fonction
// répond 401. La même valeur vit dans app_secrets (migration 12).
// ============================================================

import nodemailer from 'npm:nodemailer@6.9.13';

interface LockoutBody {
  source?: 'ip' | 'global' | string;
  ip?: string;
  failures?: number;
  at?: string;
}

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers':
    'authorization, x-client-info, apikey, content-type',
};

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }
  if (req.method !== 'POST') {
    return new Response(JSON.stringify({ error: 'Method not allowed' }), {
      status: 405,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }

  // Secret partagé : seul Postgres (pg_net) connaît cette valeur,
  // envoyée dans l'en-tête x-webhook-secret. Sans correspondance :
  // 401, la fonction ne divulgue rien.
  const edgeSecret = Deno.env.get('EDGE_SHARED_SECRET');
  const providedSecret = req.headers.get('x-webhook-secret');
  if (!edgeSecret || providedSecret !== edgeSecret) {
    return new Response(JSON.stringify({ error: 'Non autorisé' }), {
      status: 401,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }

  const smtpUser = Deno.env.get('SMTP_USER');
  const smtpPass = Deno.env.get('SMTP_PASS');
  const fromEmail = Deno.env.get('NOTIFY_FROM_EMAIL');
  const toEmails = (Deno.env.get('NOTIFY_TO_EMAILS') ?? '')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);

  if (!smtpUser || !smtpPass || !fromEmail || toEmails.length === 0) {
    return new Response(
      JSON.stringify({ error: 'Notification non configurée (secrets manquants)' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
    );
  }

  let body: LockoutBody;
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: 'Corps invalide' }), {
      status: 400,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }

  const source = body.source === 'global'
    ? 'verrou global (toutes IP)'
    : body.source === 'code'
      ? 'verrou anti tentatives de connexion (codes)'
      : 'verrou par IP';
  const ip = body.ip ?? '?';
  const failures = Number.isFinite(body.failures) ? Number(body.failures) : 0;
  const at = body.at ?? '';

  const html = `
    <div style="font-family:sans-serif;max-width:640px;">
      <h2 style="margin-bottom:4px;color:#b91c1c;">Blocage anti brute-force déclenché</h2>
      <p>Un <strong>${escapeHtml(source)}</strong> vient d'être activé sur le site
      d'administration familiale.</p>
      <ul>
        <li>IP à l'origine du seuil : <strong>${escapeHtml(ip)}</strong></li>
        <li>Échecs enregistrés sur la fenêtre : <strong>${failures}</strong></li>
        <li>Horodatage (UTC) : ${escapeHtml(at)}</li>
      </ul>
      <p style="color:#64748b;font-size:13px;">
        Fenêtre glissante de 15 minutes : pendant le blocage, même un mot de passe
        correct est refusé. Le compteur est remis à zéro par un succès.
      </p>
    </div>`;

  const port = Number(Deno.env.get('SMTP_PORT') ?? '587');
  const transporter = nodemailer.createTransport({
    host: Deno.env.get('SMTP_HOST') ?? 'smtp.protonmail.ch',
    port,
    secure: port === 465,
    auth: { user: smtpUser, pass: smtpPass },
  });

  try {
    await transporter.sendMail({
      from: fromEmail,
      to: toEmails,
      subject: 'Sécurité — blocage anti brute-force déclenché',
      html,
    });
  } catch (err) {
    return new Response(
      JSON.stringify({ error: `Envoi impossible : ${String(err)}` }),
      { status: 502, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
    );
  }

  return new Response(JSON.stringify({ ok: true }), {
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
});

function escapeHtml(text: string | null): string {
  if (!text) return '';
  return text
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}
