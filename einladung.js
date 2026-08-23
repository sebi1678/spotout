/* SPOTOUT — Einladungsseite
   ------------------------------------------------------------------
   Wozu das hier gut ist: WhatsApp, iMessage und Signal holen sich die
   Vorschaukarte, indem sie den Link einmal aufrufen und in die Antwort
   schauen. Sie führen kein JavaScript aus. Bisher bekamen sie darum
   immer dieselbe allgemeine Karte von index.html – egal, zu welcher
   Party eingeladen wurde.

   Diese Datei beantwortet genau die Adressen mit ?join=CODE. Sie holt
   die Party zum Code und schreibt Name, Datum, Ort und Bild in die
   Vorschau. Menschen leitet sie sofort weiter auf /?j=CODE, wo die App
   die Einladung öffnet wie bisher.

   Wenn diese Datei fehlt, funktioniert alles wie vorher – nur ohne die
   schöne Karte. Sie kann also nichts kaputt machen.
*/

const SB_URL = 'https://tuxyyrlxjkxabhvremqu.supabase.co';
const SB_KEY = 'sb_publishable_dldlgp40jFNPHVV8o7lF4A_UmGSxEFZ';

const esc = (t) => String(t == null ? '' : t)
  .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
  .replace(/"/g, '&quot;').replace(/'/g, '&#39;');

const WOCHENTAG = ['Sonntag','Montag','Dienstag','Mittwoch','Donnerstag','Freitag','Samstag'];
const MONAT = ['Januar','Februar','März','April','Mai','Juni','Juli','August','September','Oktober','November','Dezember'];

function wann(datum, zeit) {
  if (!datum) return '';
  const d = new Date(datum + 'T12:00:00');
  if (isNaN(d)) return '';
  const t = String(zeit || '').slice(0, 5);
  return WOCHENTAG[d.getDay()] + ', ' + d.getDate() + '. ' + MONAT[d.getMonth()]
       + (t ? (' · ' + t + ' Uhr') : '');
}

async function partyZumCode(code) {
  try {
    const r = await fetch(SB_URL + '/rest/v1/rpc/get_event_by_invite', {
      method: 'POST',
      headers: { apikey: SB_KEY, Authorization: 'Bearer ' + SB_KEY, 'Content-Type': 'application/json' },
      body: JSON.stringify({ p_code: code }),
    });
    if (!r.ok) return null;
    const j = await r.json();
    return Array.isArray(j) ? (j[0] || null) : (j || null);
  } catch (_) { return null; }
}

export default async function handler(req, res) {
  const u = new URL(req.url, 'https://spotoutapp.ch');
  const code = (u.searchParams.get('join') || '').trim();

  // Ohne Code hat die Seite nichts zu suchen – zurück auf die Startseite.
  if (!code || code.length > 64) {
    res.writeHead(302, { Location: '/' });
    return res.end();
  }

  const e = await partyZumCode(code);
  const ziel = '/?j=' + encodeURIComponent(code);

  const name  = (e && e.name) ? e.name : 'Du bist eingeladen';
  const titel = (e && e.name) ? ('Du bist eingeladen: ' + e.name) : 'Du bist eingeladen';
  // In der Vorschau steht nie die genaue Strasse. Eine Vorschaukarte
  // reist weiter als der Link selbst – der Ort genuegt, die Adresse
  // sieht man in der App, wenn man drin ist.
  const ort = (e && e.address) ? String(e.address).split(',').pop().trim() : '';
  const zeile = e ? [wann(e.ev_date || e.date, e.ev_time || e.time), ort].filter(Boolean).join(' · ') : '';
  const text  = (zeile ? zeile + ' — ' : '')
    + 'Link öffnen, kurz anmelden, und du stehst auf der Gästeliste. SPOTOUT ist gratis.';
  const bild  = (e && e.image_url) ? e.image_url : 'https://spotoutapp.ch/og.png';

  res.setHeader('Content-Type', 'text/html; charset=utf-8');
  // Kurz zwischenspeichern: eine Einladung wird oft in derselben Minute
  // von mehreren Diensten abgeholt.
  res.setHeader('Cache-Control', 'public, max-age=60, s-maxage=300');
  res.statusCode = 200;
  res.end(`<!doctype html>
<html lang="de">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>${esc(titel)}</title>
<meta name="description" content="${esc(text)}"/>
<meta property="og:type" content="website"/>
<meta property="og:site_name" content="SPOTOUT"/>
<meta property="og:title" content="${esc(titel)}"/>
<meta property="og:description" content="${esc(text)}"/>
<meta property="og:image" content="${esc(bild)}"/>
<meta property="og:url" content="https://spotoutapp.ch/?join=${encodeURIComponent(code)}"/>
<meta name="twitter:card" content="summary_large_image"/>
<meta name="twitter:title" content="${esc(titel)}"/>
<meta name="twitter:description" content="${esc(text)}"/>
<meta name="twitter:image" content="${esc(bild)}"/>
<link rel="canonical" href="https://spotoutapp.ch/?join=${encodeURIComponent(code)}"/>
<meta http-equiv="refresh" content="0;url=${esc(ziel)}"/>
<style>
  :root{color-scheme:dark}
  body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;
       background:#080b1e;color:#fff;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;
       padding:24px;text-align:center}
  .k{max-width:420px}
  h1{font-size:1.5rem;margin:0 0 8px;letter-spacing:-.02em}
  p{color:rgba(255,255,255,.62);font-size:.95rem;line-height:1.5;margin:0 0 22px}
  a{display:inline-block;background:linear-gradient(135deg,#FF2D76,#FF5A45);color:#fff;
    text-decoration:none;font-weight:800;padding:14px 26px;border-radius:14px}
</style>
</head>
<body>
  <div class="k">
    <h1>${esc(name)}</h1>
    <p>${esc(zeile || 'Private Party auf SPOTOUT')}</p>
    <a href="${esc(ziel)}">Einladung öffnen</a>
  </div>
  <script>location.replace(${JSON.stringify(ziel)});</script>
</body>
</html>`);
}
