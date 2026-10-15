// Prüft die Bewegungs-Hilfe aus index.html (Feder, Projektion, Gummiband,
// Tempo-Messer) mit den Werten aus Apples "Designing Fluid Interfaces".
//
// Ausführen: node --test tests/*.test.js
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const html = fs.readFileSync(process.env.SEITE || path.join(__dirname, '..', 'index.html'), 'utf8');
const a = html.indexOf('BEWEGUNG-START');
const b = html.indexOf('/* BEWEGUNG-ENDE */');
assert.ok(a > 0 && b > a, 'Markierungen BEWEGUNG-START/-ENDE fehlen');
const code = html.slice(html.indexOf('*/', a) + 2, b);
const B = vm.runInNewContext(code + ';Bewegung', {});

test('Projektion: Apples Formel', () => {
  // 1000 px/s, d = 0.998 → 0.998/0.002 = 499 px
  assert.ok(Math.abs(B.projiziere(1000) - 499) < 1e-9);
  assert.ok(Math.abs(B.projiziere(1000, 0.99) - 99) < 1e-9);
  assert.strictEqual(B.projiziere(0), 0);
  assert.ok(B.projiziere(-500) < 0);
});

test('Gummiband: gibt nach, aber nie mehr als der Weg', () => {
  assert.strictEqual(B.gummiband(0, 800), 0);
  const w1 = B.gummiband(100, 800), w2 = B.gummiband(200, 800);
  assert.ok(w1 > 0 && w1 < 100);
  assert.ok(w2 > w1 && w2 - w1 < w1, 'je weiter, desto zäher');
  assert.ok(B.gummiband(-100, 800) === -w1, 'symmetrisch');
});

test('Feder Dämpfung 1.0: kommt an, ohne überzuschwingen', () => {
  let x = 100, v = 0, min = x;
  for (let i = 0; i < 120; i++) { [x, v] = B.federSchritt(x, v, 1 / 60, 1, 0.35); min = Math.min(min, x); }
  assert.ok(Math.abs(x) < 0.5, 'nach 2 s am Ziel, war ' + x);
  assert.ok(min > -0.5, 'kein Überschwingen, min ' + min);
});

test('Feder Dämpfung 0.8 mit Schwung: schwingt sichtbar über', () => {
  let x = 100, v = -2000, min = x;
  for (let i = 0; i < 120; i++) { [x, v] = B.federSchritt(x, v, 1 / 60, 0.8, 0.3); min = Math.min(min, x); }
  assert.ok(min < -1, 'überschwingt, min ' + min);
  assert.ok(Math.abs(x) < 0.5);
});

test('Tempo-Messer: px/s aus den letzten Punkten, still = 0', () => {
  const m = B.messer();
  m.add(0, 0); m.add(10, 16); m.add(20, 32);
  assert.ok(Math.abs(m.v(32) - 625) < 1);
  assert.strictEqual(m.v(200), 0, 'Finger stand still');
});
