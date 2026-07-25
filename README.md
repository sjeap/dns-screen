# dns-monitor

Prüft alle 15 Minuten per GitHub Actions, ob ein Satz DNS-Resolver eine feste
Liste von Namen sauber auflöst. Bei einem Ausfall verschickt GitHub seine
native Failure-Mail — ohne SMTP-Action, ohne Secrets.

## Funktionsweise

- **Server-IPs** kommen aus `tool/*.mhtml` (ein dnscheck.tools-Snapshot).
  `extract-servers.py` dekodiert das MHTML, greift **ausschließlich**
  die Sektion `resolver-results` ab und gibt die **IPv4-Adressen (A-Records)**
  der Resolver aus.
- **Ziele** stehen in `targets.txt` (ein Name pro Zeile, `#` = Kommentar).
- **Prüfung**: je Server × Ziel `dig @<ip> <name> A +short` mit 2 Versuchen
  (gegen UDP-Paketverlust). Nur A-Records zählen.
- **Bewertung** je Server:
  - `OFFLINE` — keine Antwort auf **alle** Ziele (`dig`-Exit 9).
  - `AUFLÖSUNG DEFEKT` — Server antwortet, aber für einzelne Ziele kommt kein
    A-Record (SERVFAIL/NXDOMAIN/leer); die betroffenen Namen werden benannt.
  - sonst `OK`.
- Der Gesamtstatus ist `FAIL`, sobald **ein** Server nicht `OK` ist.

## Überwachte Server ändern

Die `tool/*.mhtml` ist die Single Source of Truth. Neuen Snapshot von
<https://dnscheck.tools/> speichern, die Datei im `tool/`-Ordner ersetzen,
committen — der nächste Lauf prüft automatisch die neuen/geänderten IPs.
Am Code oder an der Workflow-Datei ist dafür nichts zu ändern.

## Alarmierung

- Der Job endet **nur beim Zustandswechsel `OK → FAIL`** mit `exit 1`. Dadurch
  wird der Run rot und GitHub schickt **einmalig** seine Failure-Mail.
- Anhaltendes `FAIL` (Folgeläufe) bleibt **grün** — keine Mail-Flut.
- `FAIL → OK` (Recovery) setzt still zurück.
- Der **Detailreport** (Ursache getrennt, betroffene Ziele namentlich, exakter
  Zeitstempel in `Europe/Berlin`, also automatisch CEST/CET) steht im
  **Job-Summary** und als `::error::`-Annotation — einen Klick von der Mail
  entfernt. (Die native Mail selbst ist bauartbedingt generisch.)

## Zustand

`last-status.json` hält den letzten Status. `since` markiert den
Zeitpunkt des letzten Statuswechsels und bleibt über unveränderte Läufe
stabil, damit nur bei echten Wechseln ein Commit entsteht. Der
`State persistieren`-Step committet die Datei mit `if: always()` auch dann,
wenn der Check fehlschlägt.

## Betriebshinweise

- GitHub-Cron ist *best effort*: `*/15` läuft real oft 15–25 min, unter Last
  fallen Läufe aus.
- **Public Repo** empfohlen — Actions sind dort gratis. Privat: ~96 Läufe/Tag
  sprengen das Free-Minutenkontingent.
- Runner haben kein IPv6-Egress — daher ohnehin nur A-Records.
- Der Schedule wird nach 60 Tagen ohne Repo-Aktivität automatisch deaktiviert.

## Layout

```
dns-monitor/
├── extract-servers.py  ← MHTML → IPv4-Resolverliste (A-Records)
├── check.sh            ← dig-Loop, Klassifizierung, State, Transition-Exit
├── targets.txt         ← feste Prüfliste (ein Name pro Zeile)
├── last-status.json    ← persistierter Status (Commit nur bei Zustandswechsel)
├── ACKNOWLEDGMENTS.md  ← Credits/Quellen (wird ins README gespiegelt)
├── README.md
├── tool/
│   └── *.mhtml         ← dnscheck.tools-Snapshot (Single Source of Truth der Server-IPs)
└── .github/workflows/
    └── dns-check.yml   ← Cron (15 min) + manueller Trigger
```

## Acknowledgments

Kanonische Quelle: [`ACKNOWLEDGMENTS.md`](ACKNOWLEDGMENTS.md). Der folgende
Block wird von dort zwischen den Markern gespiegelt.

<!-- ACK:START -->
## Website

- [dnscheck.tools](https://dnscheck.tools/) — deckt die real verwendeten DNS-Resolver hinter dem konfigurierten Frontend auf. Der gespeicherte Snapshot (`tool/*.mhtml`) ist die Single Source of Truth für die überwachten Server-IPs.

## Inspiration / Projekte

- [opennic/ServerTest](https://github.com/opennic/ServerTest) — OpenNIC T1/T2 DNS Server Test Script. Vorbild für die Prüf-Idee (Namen gegen einen Resolver auflösen). Tier-2-Logik: [`t2.php`](https://github.com/opennic/ServerTest/blob/master/t2.php) · Live-Frontend: [report.opennicproject.org/t2log](https://report.opennicproject.org/t2log/).
<!-- ACK:END -->
