# Datenbank-Änderungen

Die Datenbank ist die Quelle der Wahrheit: Jede Änderung wird als Supabase-Migration
angewendet und ist im Dashboard unter *Database → Migrations* mit Namen und vollständigem
SQL einsehbar. Die Dateien hier im Ordner decken die grösseren Umbauten ab; einige spätere
Korrekturen liegen nur in der Datenbank.

## Angewendet am 16. September 2026 (grosser Schlusscheck)

| Name | Was |
|---|---|
| `beitritt_und_moderation` | Beitritt zu privaten Partys nur mit Bestätigung; automatische Moderation (Verwarnung → 7 Tage → dauerhaft) |
| `24h_archiv_abzeichen` | Partys und Fotos 24 h nach Beginn weg; Archiv „Besucht“; neun Abzeichen |
| `push_einstellungen` | `profiles.push_aus`, `push_gruppe`, `sende_push` respektiert die Auswahl |
| `moderation_stufen_fix` | Stufen 2 und 3 zählen offene Meldungen korrekt |
| `kleine_logikfehler_server` | Austragen räumt auf; Blockieren trennt Folgen; Einladungsseite zählt Begleitungen |
| `follower_listen_privat` | `folge_liste`, Follows-Tabelle nur noch für Beteiligte |
| `profilbesuche` | Profilbesuche für Pro (30 Tage), abschaltbar; Anfrage-Rückzug räumt Meldung auf |
| `anfrage_meldung_umwandeln` | Angenommene Folge-Anfrage wird zu „folgt dir jetzt“ |
| `finalcheck_server_1` | Private Partys nur für Eingeladene; `get_follow_stats` ohne fremde Betrachter-ID; Texte 24 h / „Neu dabei“ |
| `finalcheck_a_partys` | Party nur im eigenen Namen; geschützte Spalten; Gebührenstufe fest; Gästelisten geschützt; Host entfernt Gäste; Warteliste meldet freie Plätze; Einladungslinks prüfen Zustand |
| `finalcheck_b_sozial_konten` | Push-Token eindeutig; Nachrichten-Anfragen nur Status + Benachrichtigung; Blockieren räumt auf; Mindestalter 16; gesperrte E-Mail-Adressen; `mein_profil`; Filter für Chat-Nachrichten; jede Meldung erreicht den Betreiber |
| `finalcheck_c_sperren_aufraeumen` | Gesperrte schreiben nirgends mehr; alte Tabellen zu; Dateilisten privat; Indizes; Aufräumjobs (Suche, Meldungen 12 Monate, Profilbesuche 30 Tage) |
| `meldung_mail` | Jede Meldung löst eine E-Mail an support@spotoutapp.ch aus (Edge Function `meldung-mail`) |
| `profilspalten_einschraenken` | Fremde Profile geben nur noch öffentliche Spalten heraus |
| `regeln_ohne_profilspalten` | Zeilenregeln lesen über Funktionen statt direkt in `profiles` |
| `ist_admin_auch_fuer_gaeste` | `ist_admin()` auch im Gastmodus aufrufbar (liefert „nein“) |

## Edge Functions

`stripe-webhook`, `revenuecat-webhook`, `create-event-fee-checkout`, `ics`,
`verein-pruefen`, `fotos-aufraeumen`, **neu** `meldung-mail` und `konto-loeschen`.

Offen: zwei Verbesserungen an den Zahlungs-Webhooks (Zahlungen bei Fehlern nicht als
erledigt vermerken, Kündigung als „gekündigt“ anzeigen) sind vorbereitet, aber noch
nicht hochgeladen.
