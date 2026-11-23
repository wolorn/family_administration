// ============================================================
// Edge Function : notify-proposal
//
// Notifie les administrateurs par email (SMTP, ex. Proton Mail)
// lorsqu'une proposition de modification/ajout est soumise.
// Appelée depuis Postgres par pg_net via le trigger de la
// migration 12 (le navigateur ne l'appelle plus).
//
// Déploiement via CLI :
//   supabase functions deploy notify-proposal
//   supabase secrets set SMTP_USER="jeton_smtp" \
//     SMTP_PASS="mot_de_passe_du_jeton" \
//     NOTIFY_FROM_EMAIL="famille@exemple.fr" \
//     NOTIFY_TO_EMAILS="admin1@exemple.fr,admin2@exemple.fr" \
//     EDGE_SHARED_SECRET="valeur_longue_aleatoire"
//
// La même valeur EDGE_SHARED_SECRET doit être insérée dans la table
// app_secrets (key = 'edge_shared_secret') par la migration 12 :
// chaque requête doit porter l'en-tête « x-webhook-secret » égal
// à ce secret, sinon la fonction répond 401.
//
// SMTP_HOST et SMTP_PORT sont facultatifs (défauts Proton :
// smtp.protonmail.ch, 587). NOTIFY_FROM_EMAIL doit être une adresse
// de votre compte Proton (ou un de ses alias).
//
// Si la fonction n'est pas déployée ou échoue, la proposition reste
// enregistrée en base (l'erreur de notification est sans effet).
// ============================================================

import nodemailer from 'npm:nodemailer@6.9.13';

interface ProposalChange {
  field: string;
  from: string | null;
  to: string | null;
}

interface NotifyBody {
  member?: string;
  proposed_by?: string;
  changes?: ProposalChange[];
  kind?: string;
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
  // 401, la fonction ne divulgare rien.
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

  let body: NotifyBody;
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: 'Corps invalide' }), {
      status: 400,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }

  const member = body.member ?? '';
  const proposedBy = body.proposed_by ?? '';
  const changes: ProposalChange[] = Array.isArray(body.changes) ? body.changes : [];

  const rows = changes
    .map(
      (c) => `
        <tr>
          <td style="border:1px solid #ddd;padding:6px 10px;font-weight:600;">${escapeHtml(c.field)}</td>
          <td style="border:1px solid #ddd;padding:6px 10px;color:#b91c1c;">${escapeHtml(c.from || '(vide)')}</td>
          <td style="border:1px solid #ddd;padding:6px 10px;color:#15803d;font-weight:600;">${escapeHtml(c.to || '(vide)')}</td>
        </tr>`,
    )
    .join('');

  const html = `
    <div style="font-family:sans-serif;max-width:640px;">
      <h2 style="margin-bottom:4px;">${body.kind === 'creation'
        ? "Proposition d'ajout de membre"
        : 'Proposition de modification'}</h2>
      <p>
        <strong>${escapeHtml(proposedBy)}</strong> a proposé ${
          body.kind === 'creation'
            ? "l'ajout d'un nouveau membre :"
            : 'une modification de la fiche de'
        } <strong>${escapeHtml(member)}</strong>.
      </p>
      ${changes.length > 0
        ? `<table style="border-collapse:collapse;max-width:640px;">
            <thead>
              <tr>
                <th style="border:1px solid #ddd;padding:6px 10px;text-align:left;">Champ</th>
                <th style="border:1px solid #ddd;padding:6px 10px;text-align:left;">Actuel</th>
                <th style="border:1px solid #ddd;padding:6px 10px;text-align:left;">Proposé</th>
              </tr>
            </thead>
            <tbody>${rows}</tbody>
          </table>`
        : '<p>(aucun détail transmis)</p>'}
      <p style="color:#64748b;font-size:13px;">
        Connectez-vous au site avec un compte administrateur,
        bouton « Modifications proposées », pour accepter ou refuser.
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
      subject: `Proposition de modification — ${member}`,
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
