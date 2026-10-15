// Prüft anfang()/anfangRoh() aus index.html: den Buchstaben im runden Bild,
// wenn jemand kein Foto hat. Früher charAt(0) – halbes Emoji, leerer Kreis.
//
// Ausführen: node --test tests/*.test.js
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const html = fs.readFileSync(process.env.SEITE || path.join(__dirname, '..', 'index.html'), 'utf8');
const a = html.indexOf('function esc(s)');
const b = html.indexOf('function anfang(s)');
assert.ok(a > 0 && b > a, 'esc/anfang nicht gefunden');
const code = html.slice(a, html.indexOf('\n', b));
const F = vm.runInNewContext(code + ';({anfang,anfangRoh})', { Intl });

test('normaler Name: erster Buchstabe, gross', () => {
  assert.strictEqual(F.anfangRoh('lena'), 'L');
  assert.strictEqual(F.anfangRoh('ändu'), 'Ä');
});

test('Emoji am Anfang: ganzes Zeichen, kein halbes', () => {
  assert.strictEqual(F.anfangRoh('🎉 Party'), '🎉');
  assert.strictEqual(F.anfangRoh('👩‍👩‍👧 Familie'), '👩‍👩‍👧');
  assert.strictEqual(F.anfangRoh('🇨🇭 Sebi'), '🇨🇭');
});

test('Leerzeichen, leer, nichts: Fragezeichen statt leerer Kreis', () => {
  assert.strictEqual(F.anfangRoh('  lena'), 'L');
  assert.strictEqual(F.anfangRoh('   '), '?');
  assert.strictEqual(F.anfangRoh(''), '?');
  assert.strictEqual(F.anfangRoh(null), '?');
  assert.strictEqual(F.anfangRoh(undefined), '?');
});

test('anfang escaped fürs HTML', () => {
  assert.strictEqual(F.anfang('<b>'), '&lt;');
  assert.strictEqual(F.anfang('&co'), '&amp;');
});

test('ohne Intl.Segmenter: ganzer Codepoint', () => {
  const G = vm.runInNewContext(code + ';({anfangRoh})', { Intl: {} });
  assert.strictEqual(G.anfangRoh('🎉 Party'), '🎉');
  assert.strictEqual(G.anfangRoh('lena'), 'L');
});

test('index.html: keine charAt(0)-Anfangsbuchstaben mehr', () => {
  assert.strictEqual((html.match(/charAt\(0\)\.toUpperCase\(\)/g) || []).length, 0);
});
