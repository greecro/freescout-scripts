# AGENTS.md — freescout-scripts

FreeScout (Helpdesk) als LXC auf dem Cluster: Setup, Backup, Cloudron-Migration, Update.
Gemeinsame Instruktionsdatei für alle Agenten (Claude, Codex, Gemini);
`CLAUDE.md` ist ein Symlink hierauf. Remote liegt in der `greecro`-Org.

- Schritt-für-Schritt, Backup-Konzept, Script-Übersicht: [README.md](README.md)
- Gast-ID, IP, VLAN: `~/Developer/KI/projects/proxmox-cluster/inventory.md`
- OIDC-Anbindung: Dossier `project_freescout_oidc.md`, Blueprint in `homelab-authentik`

## Projektregeln

1. **Kein `flock` im Cron *und* im Script** auf dasselbe Lockfile — hier real kollidiert
   (Commit `a67e746`). Das Script hält sein Lock selbst.
2. **`backup-verify.sh` brach jahrelang still ab** (`zcat | head` unter `pipefail`, Exit 2) und
   fiel erst auf, als der Dead-Man's-Switch dran hing. Also: kein großer Produzent in `| head`,
   und jeder Job braucht einen healthchecks-Check.
3. **Der Scheduler ist der wichtigste Check.** Laravels minütlicher `schedule:run` pingt
   autonom. Seine Ping-URL liegt **außerhalb** von `/etc/freescout` (das ist `700`, `www-data`
   darf nicht hinein) — real erlebt: URL dort abgelegt → Ping blieb leer, kein Alarm.
4. **`health-check.sh` läuft bewusst nicht im Cron** (Dany-Entscheidung), nur manuell.
5. **Reverse Proxy ist Caddy**, nicht NPM+ — der README-Abschnitt ist historisch.
6. **Queue-Worker nach jedem Update prüfen** (`supervisorctl`); ein stiller Worker sieht wie ein
   funktionierender Helpdesk aus, bis Mails liegen bleiben. `supervisorctl start` allein reicht
   **nicht** — das Setup legt den Worker mit `autostart=false` an, ein bloßes `start` überlebt
   also keinen Reboot (real: stand so von Mai bis August). Immer `autostart=true` setzen,
   `reread`+`update`, dann auf `RUNNING` prüfen. Fällt nicht auf, weil FreeScouts Scheduler
   selbst ein `queue:work` startet und die Queue trotzdem leerläuft.
7. **Migration ist einmalig und destruktiv am Ziel.** `migrate-from-cloudron.sh` /
   `migrate-import.sh` nie gegen die laufende Instanz ohne Danys Ansage.
