# dns-monitor

Prüft alle 15 Minuten per GitHub Actions, ob ein Satz DNS-Resolver eine feste
Liste von Namen sauber auflöst. Bei einem Ausfall verschickt GitHub seine
native Failure-Mail — ohne SMTP-Action, ohne Secrets.

## Funktionsweise

- **Server-IPs** kommen aus der DoT-Quellconfig unter `tool/` (die WAN-Up-/
  stubby-Datei). `extract-servers.py` liest die **aktiven** `address_data:`-
  Zeilen und gibt deren **IPv4-Adressen (A-Records)** aus. Auskommentierte
  Zeilen (`#`) werden ignoriert — ein dort deaktivierter Server ist auch hier
  deaktiviert.
- **Ziele** stehen in `targets.txt` (ein Name pro Zeile, `#` = Kommentar).
- **Prüfung**: alle Server werden **parallel** geprüft (ein Job pro IP), je
  Server × Ziel `dig @<ip> <name> A +short` mit 2 Versuchen (gegen
  UDP-Paketverlust). Nur A-Records zählen. Ein stummer Server wird per
  Early-Exit sofort als offline gewertet, ein 20-s-Deckel begrenzt jeden
  Server hart — die Gesamtdauer richtet sich nach dem langsamsten Einzelserver.
- **Bewertung** je Server:
  - `OFFLINE` — Server antwortet auf gar nichts (`dig`-Exit 9).
  - `AUFLÖSUNG DEFEKT` — Server antwortet, aber für einzelne Ziele kommt kein
    A-Record (SERVFAIL/NXDOMAIN/leer); die betroffenen Namen werden benannt.
  - sonst `OK`.
- **Proxy-Fallback (optional)**: Server, die direkt scheitern, werden über einen
  Residential-SOCKS5-Proxy erneut geprüft (Secrets `DATAIMPULSE_USER` /
  `DATAIMPULSE_PASS`). Nur wenn sie auch darüber nicht auflösen, zählen sie als
  FAIL. Details unten.
- Der Gesamtstatus ist `FAIL`, sobald **ein** Server nicht `OK` ist.

## Überwachte Server ändern

Die DoT-Quellconfig unter `tool/` ist die Single Source of Truth. Server
hinzufügen/entfernen = die `address_data:`-Zeilen dort bearbeiten bzw. mit `#`
auskommentieren, committen — der nächste Lauf prüft automatisch die aktive
Liste. Am Code oder an der Workflow-Datei ist dafür nichts zu ändern.

## Proxy-Fallback (optional)

Manche Resolver (z. B. Quad9-Egress-Nodes hinter i3d) beantworten nur bestimmte
Netze und antworten den GitHub-Runner-IPs nicht — sie erscheinen dann als
`OFFLINE`, obwohl sie lokal funktionieren. Dagegen prüft der Monitor jeden
direkt gescheiterten Server ein zweites Mal über einen **Residential-SOCKS5-
Proxy** (DataImpulse). Erst wenn ein Server auch darüber nicht auflöst, gilt er
als FAIL.

Konfiguration wie im `web-feed`-Repo — gleicher Account, gleiche Credentials,
nur der Port unterscheidet sich. Zwei Repo-Secrets, **nie im Code** (Settings →
Secrets and variables → Actions):

- `DATAIMPULSE_USER`
- `DATAIMPULSE_PASS`

Getrennt gehalten, weil User und Passwort separat gebraucht werden und der
Username pro Lauf um eine Session ergänzt wird (`…__sessid.<run-id>` → eine
stabile Exit-IP je Lauf). Host/Port stehen im Code (`gw.dataimpulse.com:824`,
per Env `DATAIMPULSE_HOST`/`DATAIMPULSE_PORT` überschreibbar). Port **824** =
SOCKS5 (nicht 823/HTTP), weil die Fallback-Query als **DNS-over-TCP**
(`dig +tcp`) durch den SOCKS5-Tunnel läuft — proxychains kann kein UDP. Damit
ist **keine** UDP-Freischaltung bei DataImpulse nötig.

Fehlen die Secrets, läuft der Check direkt ohne Proxy weiter (`::warning::`,
kein Abbruch). Server, die erst über den Proxy auflösen, werden im Job-Summary
gesondert ausgewiesen.

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
- Geprüft wird aus dem **GitHub-Runner-Netz** (Azure-Datacenter-IPs). Resolver,
  die nur bestimmte Netze bedienen und die Runner-IPs nicht beantworten,
  erscheinen als `OFFLINE` — auch wenn sie lokal erreichbar sind.
- Der Schedule wird nach 60 Tagen ohne Repo-Aktivität automatisch deaktiviert.

## Layout

```
dns-monitor/
├── extract-servers.py  ← aktive address_data-IPs aus der Quellconfig (A-Records)
├── check.sh            ← paralleler dig-Loop, Klassifizierung, State, Proxy-Fallback
├── targets.txt         ← feste Prüfliste (ein Name pro Zeile)
├── last-status.json    ← persistierter Status (Commit nur bei Zustandswechsel)
├── ACKNOWLEDGMENTS.md  ← Credits/Quellen (wird ins README gespiegelt)
├── README.md
├── tool/
│   └── Scripts_WAN-Up-(main).txt  ← DoT-Quellconfig (Single Source of Truth der Server-IPs)
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
