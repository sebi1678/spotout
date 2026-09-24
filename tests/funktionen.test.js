// Findet Funktionen, die aufgerufen werden, aber nirgends definiert sind.
//
// Anlass: Am 22.09. wurde renderChatPro() gelöscht, der Aufruf in
// loadChats() blieb stehen – und im neuen Pro-Hinweis ein "box" ohne
// Definition. Beides warf einen ReferenceError, loadChats brach ab, und
// jede Chatliste blieb leer (in der App wie im Browser).
//
// Ausführen: node --test tests/*.test.js
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const html = fs.readFileSync(process.env.SEITE || path.join(__dirname, '..', 'index.html'), 'utf8');
const roh = [...html.matchAll(/<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/g)].map((m) => m[1]).join('\n');

/* Kommentare und Texte weg, sonst gilt "Datenbank (…)" in einem Kommentar
   als Aufruf. Ein kleiner Zustandsautomat statt Regex – Strings können
   // enthalten (Adressen), Kommentare Anführungszeichen. */
function ohneTexte(code) {
  let aus = '', i = 0;
  while (i < code.length) {
    const c = code[i], n = code[i + 1];
    if (c === '/' && n === '*') { const e = code.indexOf('*/', i + 2); i = e < 0 ? code.length : e + 2; continue; }
    if (c === '/' && n === '/') { const e = code.indexOf('\n', i); i = e < 0 ? code.length : e; continue; }
    /* Regex-Literal: "/" dort, wo ein Wert beginnt (nach ( , = : [ ! & | ? { } ; oder return).
       Sonst hielte /["']/ den Automaten für den Anfang eines Strings. */
    if (c === '/' && /(^|[(,=:\[!&|?{};]|\breturn)\s*$/.test(aus.slice(-20))) {
      let j = i + 1, klasse = false;
      while (j < code.length && (klasse || code[j] !== '/')) {
        if (code[j] === '\\') j++;
        else if (code[j] === '[') klasse = true;
        else if (code[j] === ']') klasse = false;
        else if (code[j] === '\n') break;
        j++;
      }
      aus += '/r/'; i = j + 1; continue;
    }
    if (c === "'" || c === '"' || c === '`') {
      let j = i + 1;
      while (j < code.length && code[j] !== c) { if (code[j] === '\\') j++; j++; }
      aus += c + c; i = j + 1; continue;
    }
    aus += c; i++;
  }
  return aus;
}
const skripte = ohneTexte(roh);
// Attribute wie onclick="…", oninput="…"
const attribute = [...html.matchAll(/\son[a-z]+="([^"]*)"/g)].map((m) => m[1]).join('\n');
// Auch in Skripten erzeugtes Markup: onclick="…" steht dort in Strings
const imSkript = [...roh.matchAll(/on[a-z]+=\\?["']([^"'\\]*)/g)].map((m) => m[1]).join('\n');

function definiert() {
  const namen = new Set();
  for (const m of skripte.matchAll(/(?:async\s+)?function\s*\*?\s*([A-Za-z_$][\w$]*)\s*\(/g)) namen.add(m[1]);
  for (const m of skripte.matchAll(/(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=/g)) namen.add(m[1]);
  for (const m of skripte.matchAll(/window\.([A-Za-z_$][\w$]*)\s*=/g)) namen.add(m[1]);
  // Parameter und Destrukturierung: (a, b) => …, function x(a, b), const { a, b } =
  for (const m of skripte.matchAll(/\(([^()]*)\)\s*(?:=>|\{)/g)) m[1].split(/[,\s{}=]+/).forEach((n) => n && namen.add(n));
  for (const m of skripte.matchAll(/(?:const|let|var)\s*\{([^}]*)\}\s*=/g)) m[1].split(/[,\s:]+/).forEach((n) => n && namen.add(n));
  for (const m of skripte.matchAll(/([A-Za-z_$][\w$]*)\s*=>/g)) namen.add(m[1]);
  for (const m of skripte.matchAll(/[{,]\s*([A-Za-z_$][\w$]*)\s*\([^()]*\)\s*\{/g)) namen.add(m[1]);
  return namen;
}

const EINGEBAUT = new Set([
  'if', 'for', 'while', 'switch', 'catch', 'return', 'typeof', 'function', 'await', 'new', 'import',
  'setTimeout', 'setInterval', 'clearTimeout', 'clearInterval', 'requestAnimationFrame', 'cancelAnimationFrame',
  'fetch', 'alert', 'confirm', 'prompt', 'parseInt', 'parseFloat', 'isNaN', 'isFinite', 'encodeURIComponent',
  'decodeURIComponent', 'encodeURI', 'decodeURI', 'String', 'Number', 'Boolean', 'Array', 'Object', 'Date',
  'Promise', 'Set', 'Map', 'WeakMap', 'Error', 'RegExp', 'Symbol', 'JSON', 'Math', 'URL', 'URLSearchParams',
  'Image', 'Blob', 'File', 'FileReader', 'FormData', 'Intl', 'atob', 'btoa', 'escape', 'queueMicrotask',
  'structuredClone', 'getComputedStyle', 'matchMedia', 'IntersectionObserver', 'MutationObserver',
  'ResizeObserver', 'AbortController', 'TextEncoder', 'TextDecoder', 'Event', 'CustomEvent', 'Notification',
  'createClient', 'L', 'google', 'supabase', 'event', 'this', 'super',
]);

/* Nur Aufrufe am Anfang einer Anweisung (so war es bei renderChatPro)
   und in on…-Attributen – dort gibt es keine lokalen Namen, die man
   fälschlich melden könnte. */
function aufgerufen() {
  const namen = new Map();
  const merken = (n, wo) => { if (!EINGEBAUT.has(n) && !namen.has(n)) namen.set(n, wo); };
  for (const m of skripte.matchAll(/(?:^|[;{}]|\bawait|\btry\s*\{)\s*([A-Za-z_$][\w$]*)\s*\(/gm)) merken(m[1], 'Skript');
  for (const text of [attribute, imSkript]) {
    for (const m of text.matchAll(/(?:^|[;\s(!&|])([A-Za-z_$][\w$]*)\s*\(/g)) merken(m[1], 'on…-Attribut');
  }
  return namen;
}

test('jede aufgerufene Funktion ist definiert', () => {
  const da = definiert();
  const fehlen = [...aufgerufen()].filter(([n]) => !da.has(n)).map(([n, wo]) => `${n}() (${wo})`);
  assert.deepStrictEqual(fehlen, [], 'aufgerufen, aber nirgends definiert:\n  ' + fehlen.join('\n  '));
});

test('der Anlass: renderChatPro ist weder aufgerufen noch nötig', () => {
  assert.ok(!/\brenderChatPro\s*\(/.test(skripte));
});

test('chatSperreZeigen benutzt nur, was es selbst definiert', () => {
  const m = /function chatSperreZeigen\(\)\{([\s\S]*?)\n\}/.exec(skripte);
  assert.ok(m, 'chatSperreZeigen fehlt');
  if (/\bbox\./.test(m[1])) assert.match(m[1], /const box\s*=/, '"box" wird benutzt, aber nicht definiert');
});

test('loadChats: der Pro-Hinweis kann die Liste nicht mehr leer lassen', () => {
  const m = /async function loadChats\(\)\{([\s\S]*?)\n\}/.exec(skripte);
  assert.ok(m, 'loadChats fehlt');
  assert.match(m[1], /try\{\s*chatSperreZeigen\(\);\s*\}catch/, 'chatSperreZeigen muss abgefangen sein');
  assert.match(m[1], /catch\(e\)\{[\s\S]*list\.innerHTML=/, 'bei einem Fehler muss die Liste einen Text bekommen');
});
