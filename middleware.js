/* Einladungslinks (/?join=CODE) brauchen eine eigene Vorschaukarte.
   Eine Rewrite-Regel in vercel.json greift auf "/" nie – Vercel liefert
   dort zuerst index.html aus. Die Middleware läuft davor und reicht
   genau diese Adressen an api/einladung weiter. Menschen leitet die
   Seite sofort auf /?j=CODE, wo die App die Einladung öffnet. */
export const config = { matcher: '/' };

export default async function middleware(req) {
  const u = new URL(req.url);
  if (!u.searchParams.get('join')) return;          // alles andere wie bisher
  const ziel = new URL('/api/einladung' + u.search, u.origin);
  try {
    const r = await fetch(ziel, { headers: { 'user-agent': req.headers.get('user-agent') || '' } });
    if (r.ok) return new Response(r.body, { status: 200, headers: r.headers });
  } catch (e) {
    console.warn('[einladung] middleware', e);
  }
  // Klappt die Karte nicht: Menschen kommen trotzdem an.
  return Response.redirect(new URL('/?j=' + encodeURIComponent(u.searchParams.get('join')), u.origin), 302);
}
