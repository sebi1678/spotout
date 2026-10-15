// Jedes Skript in index.html muss sich übersetzen lassen.
//
// Anlass (15.10.): Eine neue Hilfe hiess gleich wie eine bestehende
// Funktion (isoTag). "const" und "function" mit demselben Namen im selben
// Skript sind ein Syntaxfehler – dann läuft KEINE Zeile des Skripts, und
// die App bleibt leer. Der Funktionen-Test merkt das nicht.
//
// Ausführen: node --test tests/*.test.js
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const html = fs.readFileSync(process.env.SEITE || path.join(__dirname, '..', 'index.html'), 'utf8');
const skripte = [...html.matchAll(/<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/g)].map((m) => m[1]);

test('jedes eingebettete Skript ist gültiges JavaScript', () => {
  assert.ok(skripte.length > 0);
  skripte.forEach((code, i) => {
    assert.doesNotThrow(() => new vm.Script(code, { filename: 'skript-' + i + '.js' }), 'Skript ' + i);
  });
});

test('keine Namen doppelt zwischen den Skripten (const/let/class)', () => {
  // Zwischen getrennten <script>-Blöcken teilen sich const/let den globalen
  // Bereich: ein doppelter Name wirft beim Laden des zweiten Skripts.
  const ctx = vm.createContext({});
  const namen = new Map();
  const doppelt = [];
  skripte.forEach((code, i) => {
    for (const m of code.matchAll(/^(?:const|let|class)\s+([A-Za-z_$][\w$]*)/gm)) {
      if (namen.has(m[1]) && namen.get(m[1]) !== i) doppelt.push(m[1]);
      namen.set(m[1], i);
    }
  });
  assert.deepStrictEqual(doppelt, []);
  void ctx;
});
