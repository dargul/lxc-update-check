#!/usr/bin/env bash
#
# lxc-update-check.sh – checks all LXC containers of a Proxmox host for updates
# and writes the result as an HTML report. VMs are not looked at.
#
# Checked per container:
#   1. Apps installed via community-scripts (ProxmoxVE helper scripts):
#      installed version against the project's latest release
#   2. Docker containers inside the LXC: running image against the current
#      image in the registry (Docker Hub, ghcr.io, lscr.io, quay.io …)
#   3. System packages (apt, apk, dnf, pacman)
#
#   ./lxc-update-check.sh --install      once: set up cron job (schedule configurable) + web server
#   ./lxc-update-check.sh                run a scan now
#   ./lxc-update-check.sh --refresh 104  re-check container 104 only
#   ./lxc-update-check.sh --snapshot 104 pre_update   snapshot of container 104, then re-check it
#   ./lxc-update-check.sh --uninstall    remove cron job + web server again
#   ./lxc-update-check.sh --help         list all options
#
# Apps that run neither via a community-script nor via Docker can be declared
# with a small file inside the container:
#   /etc/lxc-update-check.conf
#       name=Gitea
#       repo=go-gitea/gitea
#       version_cmd=gitea --version | awk '{print $3}'
#   (instead of version_cmd a fixed version=1.2.3 works too; for a community-scripts
#    app without /usr/bin/update the line script=<script name> is enough)
#
# Files after installation:
#   /etc/lxc-update-check/config         settings (port, language, exclusions …)
#   /etc/lxc-update-check/lang/*.lang    language files with all texts of the report
#
# In the report: "Check now" re-checks everything, the arrow button (↑) re-checks a
# single container, "Settings" shows and changes the configuration (with the
# password from /etc/lxc-update-check/web-password) and links to a help page.
# The script installs no updates. The only changes it can make are snapshots that you
# start yourself: take one (camera button), roll back to one or delete one (snapshot
# list) – each with a confirmation and the password. Inside the containers a scan
# merely refreshes the package lists (apt-get update etc.).
# The help page lists the commands to snapshot and update a container by hand.

set -u

# ---------------------------------------------------------------- Settings
# After installation change these in /etc/lxc-update-check/config.
ETC="${ETC:-/etc/lxc-update-check}"
CONFIG="${CONFIG:-$ETC/config}"
[ -f "$CONFIG" ] && . "$CONFIG"

OUT_DIR="${OUT_DIR:-/var/www/lxc-updates}"   # where the report is written
PORT="${PORT:-8090}"                         # port of the web server
INCLUDE_HOST="${INCLUDE_HOST:-1}"            # 1 = also check the Proxmox host itself
TIMEOUT="${TIMEOUT:-300}"                    # max. seconds per container
EXCLUDE="${EXCLUDE:-}"                       # CT IDs to skip, e.g. "105 112"
LANG_FILE="${LANG_FILE:-$ETC/lang/de.lang}"   # language file
GITHUB_TOKEN="${GITHUB_TOKEN:-}"             # optional, raises the GitHub rate limit
CRON_ENABLED="${CRON_ENABLED:-1}"            # 1 = automatic check via cron job
# Schedule as a cron expression: minute hour day month weekday
#   daily 02:00:  0 2 * * *     Sundays 03:00:  0 3 * * 0     Mon + Thu 02:30:  30 2 * * 1,4
CRON_RE='^([0-9A-Za-z*/,-]{1,30} ){4}[0-9A-Za-z*/,-]{1,30}$'
if [ -z "${CRON_SCHEDULE:-}" ]; then
    # Earlier versions only knew a daily time (CRON_TIME="HH:MM")
    if [[ ${CRON_TIME:-} =~ ^([01][0-9]|2[0-3]):([0-5][0-9])$ ]]; then
        CRON_SCHEDULE="$((10#${BASH_REMATCH[2]})) $((10#${BASH_REMATCH[1]})) * * *"
    else
        CRON_SCHEDULE="0 2 * * *"
    fi
fi
# ------------------------------------------------------------------------------

CS_RAW=https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main
SHARE=/usr/local/share/lxc-update-check
BIN=/usr/local/bin/lxc-update-check
CRON="${CRON:-/etc/cron.d/lxc-update-check}"
UNIT_WEB=/etc/systemd/system/lxc-update-web.service
UNIT_SCAN=/etc/systemd/system/lxc-update-scan.service
UNIT_PATH=/etc/systemd/system/lxc-update-scan.path
REQUEST=/run/lxc-update-check/request      # job from the web server (check, update, settings)
STATE="${STATE:-/var/lib/lxc-update-check}"   # raw results and lookups of the last check
UNIT_PWPATH=/etc/systemd/system/lxc-update-pw.path
UNIT_PWSVC=/etc/systemd/system/lxc-update-pw.service
PWFILE="$ETC/web-password"                 # password for updates and settings in the browser
LOG=/var/log/lxc-update-check.log

# ------------------------------------------------------------------- Language files
# All texts of the report. Placeholders in {curly braces} are replaced and may
# be moved freely within the sentence. For another language copy one of the
# files in /etc/lxc-update-check/lang/, translate it and set LANG_FILE in the
# config. Missing entries fall back to German.
lang_de() { cat <<'LANG'
# Sprachdatei für lxc-update-check – Deutsch
L[lang_code]="de"
L[app_title]="LXC Update Check"
L[date_format]="%d.%m.%Y, %H:%M Uhr"

# Kopfbereich
L[headline_none]="Alle Apps sind aktuell"
L[headline_one]="1 App-Update verfügbar"
L[headline_many]="{n} App-Updates in {c} Containern"
L[summary_pkg_none]="Auch bei den Systempaketen steht nichts aus."
L[summary_pkg_sec]="Dazu {n} Systempakete auf {s} von {t} Systemen, davon {x} Security-Updates."
L[summary_pkg_nosec]="Dazu {n} Systempakete auf {s} von {t} Systemen, keine Security-Updates darunter."
L[summary_err]="{n} Systeme konnten nicht geprüft werden."
L[meta_checked]="Geprüft am {date} auf {host}, Dauer {sec} s."
L[meta_next]="Nächste automatische Prüfung täglich um {time} Uhr."
L[meta_sched]="Automatische Prüfung nach Zeitplan „{cron}“."
L[meta_off]="Die automatische Prüfung ist ausgeschaltet."

# Knopf „Jetzt prüfen“
L[btn_scan]="Jetzt prüfen"
L[btn_scanning]="Prüfung läuft …"

# Spaltenköpfe
L[col_id]="ID"
L[col_container]="Container"
L[col_app]="App"
L[col_installed]="Installiert"
L[col_latest]="Neueste Version"
L[col_status]="Status"
L[col_packages]="Systempakete"

# Paketliste
L[btn_show]="Pakete anzeigen"
L[btn_details]="Details ein- oder ausblenden"
L[col_system]="System"
L[btn_hide]="Pakete ausblenden"
L[pk_package]="Paket"
L[pk_installed]="Installiert"
L[pk_available]="Verfügbar"
L[pkg_new]="neu"
L[tag_security]="Security"
L[tag_n_security]="{n} Security"

# Status
L[st_ok]="Aktuell"
L[st_appupdate]="App-Update"
L[st_security]="Security-Updates"
L[st_sysupdates]="Systemupdates"
L[st_manual]="Manuell prüfen"
L[st_unknown]="Version unbekannt"
L[st_uncheckable]="Nicht prüfbar"
L[st_noanswer]="Keine Antwort"
L[st_stopped]="Gestoppt"

# Hinweise
L[note_stopped]="Container läuft nicht und wurde nicht geprüft"
L[note_timeout]="Keine Antwort innerhalb von {sec} s"
L[warn_apt]="Eine Paketquelle ließ sich nicht aktualisieren, Systempakete evtl. unvollständig geprüft"
L[warn_apk]="apk update fehlgeschlagen, Paketlisten evtl. veraltet"
L[warn_checkupdates]="checkupdates fehlt – im Container pacman-contrib installieren"
L[warn_nopm]="Kein unterstützter Paketmanager gefunden"
L[hint_script_pinned]="vom Script vorgegebene Version"
L[hint_docker]="Docker"
L[hint_package]="Systempaket"

# Erklärtexte, wenn keine Versionsnummer angezeigt werden kann
L[txt_no_file]="nicht hinterlegt"
L[txt_no_release]="Abfrage beim Projekt fehlgeschlagen"
L[txt_no_check]="Script ohne Versionsprüfung"
L[txt_own_updater]="Update über Paketquelle oder eigenen Updater"
L[txt_script_missing]="Update-Script der App nicht abrufbar"
L[txt_no_app]="keine App erkannt"
L[txt_no_manual_version]="keine Version angegeben"
# Tooltip zu „keine App erkannt“; \n steht für einen Zeilenumbruch
L[tip_no_app]="So wird eine App in diesem Container erkannt:\n1. Per community-script installiert: Die Datei /usr/bin/update im Container muss das Script der App nennen (ct/<name>.sh oder UPDATE_SCRIPT_NAME=…).\n2. Als Docker-Container: Der Docker-Container muss laufen.\n3. Alles andere: Im Container die Datei /etc/lxc-update-check.conf anlegen mit den Zeilen\n   name=Anzeigename\n   repo=besitzer/projekt   (GitHub-Projekt der App)\n   version_cmd=Befehl, der die installierte Version ausgibt   (oder fest: version=1.2.3)\n   Für eine community-scripts-App ohne /usr/bin/update genügt die Zeile script=name-des-scripts."
L[txt_not_checked]="nicht geprüft"
L[txt_docker_pinned]="per Digest fest eingestellt"
L[txt_docker_local]="lokal gebautes Image, kein Abgleich"
L[txt_docker_noregistry]="Registry nicht abfragbar"
L[new_image]="neues Image"
L[os_unknown]="unbekannt"
L[host_label]="Host"

# Vorabversionen (Beta, RC …)
L[tag_beta]="Beta"
L[hint_stable]="stabil: {v}"
L[note_beta_default]="Achtung: „update“ würde bei {app} die Vorabversion {v} installieren, nicht die stabile Version."

# Seite „Einstellungen“
L[btn_config]="Einstellungen"
L[btn_back]="Zurück"
L[cfg_title]="Einstellungen"
L[cfg_intro]="Alle Einstellungen und Sprachdateien liegen auf dem Proxmox-Host im Verzeichnis {dir}. Diese Seite zeigt den Stand der letzten Prüfung."
L[cfg_settings_title]="Aktuelle Einstellungen"
L[cfg_col_setting]="Einstellung"
L[cfg_col_value]="Wert"
L[cfg_col_desc]="Bedeutung"
L[cfg_OUT_DIR]="Ordner, in dem der Report abgelegt wird."
L[cfg_PORT]="Port, unter dem der Report im Browser erreichbar ist."
L[cfg_INCLUDE_HOST]="1 = der Proxmox-Host selbst wird mitgeprüft, 0 = nur die Container."
L[cfg_TIMEOUT]="Maximale Wartezeit pro Container in Sekunden."
L[cfg_EXCLUDE]="Container-IDs, die nicht geprüft werden, durch Leerzeichen getrennt."
L[cfg_LANG_FILE]="Sprachdatei, aus der alle Texte des Reports kommen."
L[cfg_GITHUB_TOKEN]="Optionaler GitHub-Token. Ohne Token erlaubt GitHub nur 60 Versionsabfragen pro Stunde."
L[cfg_token_set]="gesetzt"
L[cfg_token_unset]="nicht gesetzt"
L[cfg_empty]="(leer)"
L[cfg_files_title]="Dateien im Verzeichnis"
L[cfg_col_file]="Datei"
L[cfg_file_config]="Einstellungen des Scripts, siehe Tabelle oben."
L[cfg_file_lang]="Sprachdatei mit {n} Texten."
L[cfg_file_lang_active]="Sprachdatei mit {n} Texten, zurzeit aktiv."
L[cfg_howto]="Zum Ändern die Datei auf dem Proxmox-Host bearbeiten, zum Beispiel mit: nano {file}. Änderungen gelten ab der nächsten Prüfung. Nach einer Änderung von PORT oder OUT_DIR zusätzlich „lxc-update-check --install“ ausführen."

# Tooltips mit Erklärung, wenn statt einer Versionsnummer ein Text steht (\n = Zeilenumbruch)
L[tip_no_file]="Im Container fehlt die Versionsdatei, in der das community-script die installierte Version festhält. Das kommt bei älteren Installationen vor.\nLösung: Im Container einmal „update“ ausführen, danach mit dem Pfeil-Knopf neu prüfen."
L[tip_no_release]="GitHub oder Codeberg hat auf die Versionsabfrage nicht geantwortet.\nLösung: Internetzugang des Proxmox-Hosts prüfen und später erneut prüfen. Tritt es häufig auf, in den Einstellungen einen GitHub-Token eintragen."
L[tip_no_check]="Das community-script dieser App enthält keinen Versionsvergleich, deshalb lässt sich keine installierte Version auslesen.\nUpdates kommen bei solchen Apps meist über die Systempakete (Spalte „Systempakete“) oder über einen eigenen Updater."
L[tip_own_updater]="Das Script nennt keine Quelle, bei der sich die neueste Version abfragen lässt.\nLösung: Im Container „update“ ausführen. Für eine Versionsanzeige im Container /etc/lxc-update-check.conf mit name=, repo= und version_cmd= anlegen."
L[tip_script_missing]="Das Update-Script dieser App wurde im community-scripts-Repository nicht gefunden. Die App wurde dort entfernt oder umbenannt, oder GitHub war nicht erreichbar.\nLösung: Später erneut prüfen. Bleibt es dabei, im Container /etc/lxc-update-check.conf mit name=, repo= und version_cmd= anlegen."
L[tip_not_checked]="Der Container war gestoppt oder hat nicht rechtzeitig geantwortet.\nLösung: Container starten und erneut prüfen. Bei langsamen Containern TIMEOUT in den Einstellungen erhöhen."
L[tip_docker_pinned]="Das Image ist in der Compose-Datei mit festem Digest (@sha256:…) eingetragen. Es ändert sich nur mit der Compose-Datei, deshalb gibt es nichts zu vergleichen."
L[tip_docker_local]="Das Image wurde lokal gebaut und stammt aus keiner Registry, deshalb gibt es keine Quelle zum Vergleichen."
L[tip_docker_noregistry]="Die Registry des Images konnte nicht abgefragt werden (nicht erreichbar, privat oder Anmeldung nötig).\nLösung: Internetzugang des Proxmox-Hosts prüfen. Private Registries werden nicht unterstützt."
L[tip_no_manual_version]="In /etc/lxc-update-check.conf im Container fehlt die installierte Version.\nLösung: Dort version_cmd=Befehl eintragen, der die Version ausgibt, oder fest version=1.2.3."
L[tip_docker_tag]="Dieses Docker-Image bringt keine Versionsnummer mit, angezeigt wird der Tag aus der Compose-Datei. Ob ein Update vorliegt, wird trotzdem über die Prüfsumme des Images erkannt."
L[tip_new_image]="In der Registry liegt unter demselben Tag ein neueres Image. Eine Versionsnummer gibt das Image nicht an."

# Einzelnen Container neu prüfen (Pfeil-Knopf)
L[btn_refresh_tip]="Container {id} Info aktualisieren"
L[btn_snap_tip]="Snapshot von Container {id} anlegen"
L[snap_prompt]="Snapshot von Container {id} ({name}) anlegen.\n\nName des Snapshots (Buchstaben, Ziffern, _ und -, am Anfang ein Buchstabe):"
L[snap_badname]="Ungültiger Name. Erlaubt sind Buchstaben, Ziffern, _ und -, am Anfang ein Buchstabe, höchstens 40 Zeichen."
L[snap_running]="Snapshot von Container {id} wird angelegt …"
L[snap_ok]="Snapshot „{snap}“ von Container {id} wurde angelegt."
L[snap_fail]="Snapshot von Container {id} konnte nicht angelegt werden: {msg}"
L[note_last_snap]="Letzter Snapshot: {snap} ({date})"
L[btn_snaplist_tip]="Snapshots von Container {id} anzeigen ({n})"
L[btn_snapinfo_tip]="Anleitung: Snapshot von Container {id} zurückspielen oder löschen"
L[col_snapshots]="Snapshots"
L[snaplist_title]="Snapshots von Container {id} ({name})"
L[snaplist_empty]="Für diesen Container gibt es noch keine Snapshots."
L[snaplist_name]="Name"
L[snaplist_date]="Angelegt"
L[snaplist_note]="Stand der letzten Prüfung. Zurückspielen und Löschen fragen vorher nach und verlangen das Passwort. Die Befehle für den Proxmox-Host zeigt der Info-Knopf (i)."
L[snapinfo_title]="Snapshot von Container {id} ({name}) zurückspielen oder löschen"
L[snapinfo_intro]="Beides geht direkt in der Snapshot-Liste (☰). Auf dem Proxmox-Host geht es auch mit den Befehlen unten oder in der Proxmox-Oberfläche unter Container → Snapshots."
L[snapinfo_pick]="Snapshot:"
L[snapinfo_none]="Für diesen Container gibt es noch keine Snapshots; die Befehle zeigen deshalb den Platzhalter <Name>."
L[snapinfo_rb_title]="Zurückspielen"
L[snapinfo_rb_expl]="Setzt den Container auf den Stand des Snapshots zurück. Alle Änderungen seit dem Snapshot gehen verloren, auch neue Daten der App. Auf ZFS geht das nur zum neuesten Snapshot; neuere müssen vorher gelöscht werden. Läuft der Container danach nicht, startet ihn der zweite Befehl."
L[snapinfo_del_title]="Löschen"
L[snapinfo_del_expl]="Entfernt den Snapshot und gibt seinen Speicherplatz frei. Der Container selbst bleibt unverändert, nur zu diesem Stand kann er danach nicht mehr zurück."
L[snapinfo_list_title]="Alle Snapshots auf dem Host anzeigen"
L[btn_close]="Schließen"
L[snap_btn_rollback]="Zurückspielen"
L[snap_btn_delete]="Löschen"
L[confirm_delete]="Snapshot „{snap}“ von Container {id} ({name}) löschen?\n\nDer Snapshot wird endgültig entfernt; zu diesem Stand kann der Container danach nicht mehr zurück. Der Container selbst bleibt unverändert."
L[confirm_rollback]="Container {id} ({name}) auf den Snapshot „{snap}“ vom {date} zurücksetzen?\n\nAlle Änderungen seit diesem Snapshot gehen verloren, auch neue Daten der App. Läuft der Container, wird er dafür heruntergefahren und danach wieder gestartet."
L[confirm_rollback_newer]="\n\nAchtung: Es gibt neuere Snapshots ({list}). Auf ZFS schlägt das Zurückspielen dann fehl; sie müssten vorher gelöscht werden."
L[confirm_rollback_type]="Zur Bestätigung den Namen des Snapshots eingeben:\n\n{snap}"
L[confirm_mismatch]="Der eingegebene Name stimmt nicht überein. Es wurde nichts geändert."
L[del_running]="Snapshot von Container {id} wird gelöscht …"
L[rb_running]="Container {id} wird auf den Snapshot zurückgesetzt …"
L[del_ok]="Snapshot „{snap}“ von Container {id} wurde gelöscht."
L[del_fail]="Snapshot „{snap}“ von Container {id} konnte nicht gelöscht werden: {msg}"
L[rb_ok]="Container {id} wurde auf den Snapshot „{snap}“ zurückgesetzt."
L[rb_fail]="Container {id} konnte nicht auf den Snapshot „{snap}“ zurückgesetzt werden: {msg}"

# Statusfenster während der Prüfung
L[prog_title]="Prüfung läuft"
L[prog_title_snap]="Snapshot wird angelegt …"
L[prog_title_del]="Snapshot wird gelöscht …"
L[prog_title_rb]="Snapshot wird zurückgespielt …"
L[prog_starting]="Prüfung wird gestartet …"
L[prog_step]="{n} von {t}: {name}"
L[prog_finishing]="Report wird geschrieben …"
L[prog_close]="Schließen (läuft im Hintergrund weiter)"
L[pw_prompt]="Passwort für Änderungen (steht auf dem Proxmox-Host in {pwfile}):"

# Einstellungen im Browser ändern
L[cfg_readonly]="nur in der Datei änderbar"
L[cfg_CRON_ENABLED]="Automatische Prüfung (Cronjob) ein- oder ausschalten. „Jetzt prüfen“ funktioniert immer."
L[cfg_CRON_SCHEDULE]="Zeitplan der automatischen Prüfung als Cron-Ausdruck mit fünf Feldern: Minute, Stunde, Tag, Monat, Wochentag (0 = Sonntag)."
L[cron_examples]="Beispiele"
L[tip_cron_examples]="Täglich um 02:00 Uhr:\n   0 2 * * *\nWöchentlich, sonntags um 03:00 Uhr:\n   0 3 * * 0\nZweimal wöchentlich, montags und donnerstags um 02:30 Uhr:\n   30 2 * * 1,4"
L[cron_guru]="Ausdruck auf crontab.guru prüfen"
L[cfg_save]="Speichern"
L[cfg_saving]="Wird übernommen …"
L[cfg_saved]="Die Einstellungen wurden gespeichert und sind aktiv."
L[cfg_applying]="Die Einstellungen werden übernommen. Die Seite lädt in wenigen Sekunden von selbst neu."
L[cfg_busy]="Gerade läuft eine Prüfung. Solange lassen sich die Einstellungen nicht ändern; die Seite gibt sie danach von selbst wieder frei."


# Hilfeseite: Befehle für ein Systemupdate
L[btn_help]="Hilfe"
L[help_title]="Hilfe: System aktualisieren"
L[help_intro]="Die Befehle für ein Update des Betriebssystems in einem Container, Schritt für Schritt. Den Platzhalter <ID> durch die Nummer des Containers ersetzen. Alle Befehle laufen als root."
L[help_filter_label]="Betriebssystem:"
L[help_filter_all]="Alle anzeigen"
L[help_os_all]="Alle Systeme"
L[help_where_host]="auf dem Proxmox-Host"
L[help_where_ct]="im Container"
L[help_copy]="Kopieren"
L[help_copied]="Kopiert"
L[help_copy_failed]="Markiert – mit Strg+C kopieren"
L[help_step_enter]="In den Container wechseln"
L[help_expl_enter]="Öffnet eine root-Shell im Container. Die Befehle der Schritte 2 bis 6 werden dort eingegeben."
L[help_step_refresh]="Paketlisten auffrischen"
L[help_expl_refresh]="Lädt die aktuelle Liste der verfügbaren Pakete von den Paketquellen. Es wird noch nichts installiert."
L[help_step_list]="Anstehende Updates anzeigen"
L[help_expl_list]="Zeigt, welche Pakete aktualisiert würden. Der Schritt ändert nichts und kann übersprungen werden."
L[help_step_install]="Updates installieren"
L[help_expl_install]="Installiert alle verfügbaren Updates. Der Befehl zeigt vorher, was er tun wird, und fragt nach einer Bestätigung."
L[help_step_autoremove]="Nicht mehr benötigte Pakete entfernen"
L[help_expl_autoremove]="Entfernt Pakete, die nur als Abhängigkeit installiert wurden und von nichts mehr gebraucht werden."
L[help_step_clean]="Paket-Cache leeren"
L[help_expl_clean]="Löscht die heruntergeladenen Paketdateien und gibt Speicherplatz frei. Installierte Programme sind davon nicht betroffen."
L[help_step_reboot]="Container neu starten"
L[help_expl_reboot]="Vorher den Container mit „exit“ verlassen. Der Neustart sorgt dafür, dass alle Dienste die neuen Programmversionen verwenden. Der Kernel kommt vom Proxmox-Host und wird dabei nicht aktualisiert."
L[help_note_arch_refresh]="Entfällt. Bei Arch gehören Auffrischen und Installieren zusammen (Schritt 4); getrennt ausgeführt kann das System unbrauchbar werden."
L[help_note_alpine_autoremove]="Entfällt. apk entfernt nicht mehr benötigte Pakete von selbst."
L[help_note_suse_autoremove]="Kein eigener Befehl. „zypper packages --unneeded“ listet die Kandidaten auf."
L[help_label_arch_list]="Arch Linux (braucht das Paket pacman-contrib)"
L[help_step_snap]="Vor dem Update: Snapshot anlegen"
L[help_expl_snap]="Hält den aktuellen Stand des Containers fest, damit er sich nach einem misslungenen Update wiederherstellen lässt. „pre_update“ ist der frei wählbare Name des Snapshots. Der Storage des Containers muss Snapshots unterstützen, zum Beispiel ZFS, LVM-Thin oder Btrfs."
L[help_label_snap_create]="Snapshot anlegen"
L[help_label_snap_list]="Vorhandene Snapshots anzeigen"
L[help_step_rollback]="Falls etwas nicht mehr funktioniert: zurück zum Snapshot"
L[help_expl_rollback]="Setzt den Container auf den Stand des Snapshots zurück. Alle Änderungen seit dem Snapshot gehen dabei verloren, auch neue Daten der App."
L[help_step_delsnap]="Wenn alles läuft: Snapshot löschen"
L[help_expl_delsnap]="Entfernt den Snapshot und gibt den belegten Speicherplatz frei. Danach ist kein Zurückrollen mehr möglich."
L[help_scope]="Nicht enthalten ist der Wechsel auf eine neue Hauptversion des Betriebssystems, zum Beispiel von Debian 12 auf 13."
L[cfg_token_keep]="leer lassen = unverändert"
L[cfg_token_remove]="Token entfernen"
L[cfg_howto2]="Änderungen hier speichern oder die Datei auf dem Proxmox-Host bearbeiten: nano {file}. PORT, OUT_DIR und die Sprachdateien lassen sich nur dort ändern; nach PORT oder OUT_DIR zusätzlich „lxc-update-check --install“ ausführen."

# Fehlermeldungen mit Lösungsvorschlag
L[err_server]="Der Webdienst antwortet nicht.\nLösung: Auf dem Proxmox-Host „systemctl status lxc-update-web“ prüfen und bei Bedarf „systemctl restart lxc-update-web“ ausführen. Die Seite muss über http://host:port geöffnet sein, nicht als Datei.\nAlternative: Die Datei direkt bearbeiten mit „nano {file}“."
L[err_oldserver]="Der Webdienst kennt diese Funktion nicht.\nLösung: Auf dem Proxmox-Host „lxc-update-check --install“ erneut ausführen."
L[err_password]="Das Passwort ist falsch.\nLösung: Es steht auf dem Proxmox-Host in der Datei {pwfile} (anzeigen mit „cat {pwfile}“)."
L[err_nopassword]="Es ist kein Passwort eingerichtet, deshalb sind Änderungen über den Browser gesperrt.\nLösung: Auf dem Proxmox-Host „lxc-update-check --install“ ausführen; dabei wird {pwfile} angelegt.\nAlternative: Die Datei direkt bearbeiten mit „nano {file}“."
L[err_pwneeded]="Ohne Passwort geht es nicht.\nEs steht auf dem Proxmox-Host in der Datei {pwfile}."
L[err_busy]="Es läuft gerade eine Prüfung oder ein Update.\nLösung: Warten, bis die Seite neu geladen wurde, und es dann erneut versuchen."
L[err_invalid]="Der Wert für {field} ist ungültig.\nLösung: Format prüfen, siehe Erklärung neben dem Feld. Bei EXCLUDE sind nur Zahlen und Leerzeichen erlaubt, bei TIMEOUT nur eine Zahl."
L[err_nostart]="Der Auftrag wurde angenommen, aber nicht ausgeführt.\nLösung: Auf dem Proxmox-Host „systemctl status lxc-update-scan.path“ und „journalctl -u lxc-update-scan -n 30“ prüfen, danach „lxc-update-check --install“ erneut ausführen.\nAlternative: Die Datei direkt bearbeiten mit „nano {file}“."
LANG
}

lang_en() { cat <<'LANG'
# Language file for lxc-update-check – English
L[lang_code]="en"
L[app_title]="LXC Update Check"
L[date_format]="%Y-%m-%d, %H:%M"

# Header
L[headline_none]="All apps are up to date"
L[headline_one]="1 app update available"
L[headline_many]="{n} app updates in {c} containers"
L[summary_pkg_none]="No system packages are pending either."
L[summary_pkg_sec]="Plus {n} system packages on {s} of {t} systems, {x} of them security updates."
L[summary_pkg_nosec]="Plus {n} system packages on {s} of {t} systems, none of them security updates."
L[summary_err]="{n} systems could not be checked."
L[meta_checked]="Checked on {date} on {host}, took {sec} s."
L[meta_next]="Next automatic check daily at {time}."
L[meta_sched]="Automatic check on schedule \"{cron}\"."
L[meta_off]="The automatic check is switched off."

# "Check now" button
L[btn_scan]="Check now"
L[btn_scanning]="Checking …"

# Column headers
L[col_id]="ID"
L[col_container]="Container"
L[col_app]="App"
L[col_installed]="Installed"
L[col_latest]="Latest version"
L[col_status]="Status"
L[col_packages]="System packages"

# Package list
L[btn_show]="Show packages"
L[btn_details]="Show or hide details"
L[col_system]="System"
L[btn_hide]="Hide packages"
L[pk_package]="Package"
L[pk_installed]="Installed"
L[pk_available]="Available"
L[pkg_new]="new"
L[tag_security]="Security"
L[tag_n_security]="{n} security"

# Status
L[st_ok]="Up to date"
L[st_appupdate]="App update"
L[st_security]="Security updates"
L[st_sysupdates]="System updates"
L[st_manual]="Check manually"
L[st_unknown]="Version unknown"
L[st_uncheckable]="Cannot check"
L[st_noanswer]="No response"
L[st_stopped]="Stopped"

# Notes
L[note_stopped]="Container is not running and was not checked"
L[note_timeout]="No response within {sec} s"
L[warn_apt]="A package source could not be refreshed, system packages may be checked incompletely"
L[warn_apk]="apk update failed, package lists may be outdated"
L[warn_checkupdates]="checkupdates is missing – install pacman-contrib in the container"
L[warn_nopm]="No supported package manager found"
L[hint_script_pinned]="version set by the script"
L[hint_docker]="Docker"
L[hint_package]="system package"

# Explanations shown when no version number is available
L[txt_no_file]="not recorded"
L[txt_no_release]="lookup at the project failed"
L[txt_no_check]="script has no version check"
L[txt_own_updater]="updated through package source or its own updater"
L[txt_script_missing]="update script of the app not available"
L[txt_no_app]="no app detected"
L[txt_no_manual_version]="no version given"
# Tooltip for "no app detected"; \n stands for a line break
L[tip_no_app]="How an app in this container is detected:\n1. Installed via community-script: the file /usr/bin/update in the container must point to the app's script.\n2. As a Docker container: the Docker container must be running.\n3. Anything else: create the file /etc/lxc-update-check.conf in the container with the lines\n   name=display name\n   repo=owner/project   (the app's GitHub project)\n   version_cmd=command that prints the installed version   (or fixed: version=1.2.3)\n   For a community-scripts app without /usr/bin/update the line script=name-of-script is enough."
L[txt_not_checked]="not checked"
L[txt_docker_pinned]="pinned by digest"
L[txt_docker_local]="locally built image, no comparison"
L[txt_docker_noregistry]="registry not reachable"
L[new_image]="new image"
L[os_unknown]="unknown"
L[host_label]="Host"

# Pre-releases (beta, RC …)
L[tag_beta]="Beta"
L[hint_stable]="stable: {v}"
L[note_beta_default]="Caution: \"update\" would install the pre-release {v} of {app}, not the stable version."

# "Settings" page
L[btn_config]="Settings"
L[btn_back]="Back"
L[cfg_title]="Settings"
L[cfg_intro]="All settings and language files are stored on the Proxmox host in {dir}. This page shows the state as of the last check."
L[cfg_settings_title]="Current settings"
L[cfg_col_setting]="Setting"
L[cfg_col_value]="Value"
L[cfg_col_desc]="Meaning"
L[cfg_OUT_DIR]="Folder the report is written to."
L[cfg_PORT]="Port the report is served on."
L[cfg_INCLUDE_HOST]="1 = the Proxmox host itself is checked as well, 0 = containers only."
L[cfg_TIMEOUT]="Maximum wait per container in seconds."
L[cfg_EXCLUDE]="Container IDs that are skipped, separated by spaces."
L[cfg_LANG_FILE]="Language file all report texts are taken from."
L[cfg_GITHUB_TOKEN]="Optional GitHub token. Without one GitHub allows only 60 version lookups per hour."
L[cfg_token_set]="set"
L[cfg_token_unset]="not set"
L[cfg_empty]="(empty)"
L[cfg_files_title]="Files in the directory"
L[cfg_col_file]="File"
L[cfg_file_config]="Settings of the script, see the table above."
L[cfg_file_lang]="Language file with {n} texts."
L[cfg_file_lang_active]="Language file with {n} texts, currently active."
L[cfg_howto]="To change something, edit the file on the Proxmox host, for example with: nano {file}. Changes apply from the next check. After changing PORT or OUT_DIR also run \"lxc-update-check --install\"."

# Tooltips explaining why a text is shown instead of a version number (\n = line break)
L[tip_no_file]="The container lacks the version file in which the community-script records the installed version. This happens with older installations.\nFix: run \"update\" once in the container, then re-check with the arrow button."
L[tip_no_release]="GitHub or Codeberg did not answer the version lookup.\nFix: check the Proxmox host's internet access and check again later. If it happens often, add a GitHub token in the settings."
L[tip_no_check]="The community-script of this app contains no version comparison, so no installed version can be read.\nSuch apps are usually updated through system packages (column \"System packages\") or their own updater."
L[tip_own_updater]="The script names no source where the latest version could be looked up.\nFix: run \"update\" in the container. To see versions, create /etc/lxc-update-check.conf in the container with name=, repo= and version_cmd=."
L[tip_script_missing]="The update script of this app was not found in the community-scripts repository. The app was removed or renamed there, or GitHub was unreachable.\nFix: check again later. If it persists, create /etc/lxc-update-check.conf in the container with name=, repo= and version_cmd=."
L[tip_not_checked]="The container was stopped or did not answer in time.\nFix: start the container and check again. For slow containers raise TIMEOUT in the settings."
L[tip_docker_pinned]="The image is pinned by digest (@sha256:…) in the compose file. It only changes with the compose file, so there is nothing to compare."
L[tip_docker_local]="The image was built locally and comes from no registry, so there is no source to compare with."
L[tip_docker_noregistry]="The image's registry could not be queried (unreachable, private or login required).\nFix: check the Proxmox host's internet access. Private registries are not supported."
L[tip_no_manual_version]="/etc/lxc-update-check.conf in the container does not give the installed version.\nFix: add version_cmd=command that prints the version, or a fixed version=1.2.3."
L[tip_docker_tag]="This Docker image carries no version number, so the tag from the compose file is shown. Updates are still detected through the image checksum."
L[tip_new_image]="The registry holds a newer image under the same tag. The image does not state a version number."

# Updating a single container
L[btn_refresh_tip]="Refresh info for container {id}"
L[btn_snap_tip]="Take a snapshot of container {id}"
L[snap_prompt]="Take a snapshot of container {id} ({name}).\n\nName of the snapshot (letters, digits, _ and -, starting with a letter):"
L[snap_badname]="Invalid name. Allowed are letters, digits, _ and -, starting with a letter, at most 40 characters."
L[snap_running]="Taking a snapshot of container {id} …"
L[snap_ok]="Snapshot \"{snap}\" of container {id} was taken."
L[snap_fail]="The snapshot of container {id} could not be taken: {msg}"
L[note_last_snap]="Latest snapshot: {snap} ({date})"
L[btn_snaplist_tip]="Show snapshots of container {id} ({n})"
L[btn_snapinfo_tip]="How to roll back or delete a snapshot of container {id}"
L[col_snapshots]="Snapshots"
L[snaplist_title]="Snapshots of container {id} ({name})"
L[snaplist_empty]="This container has no snapshots yet."
L[snaplist_name]="Name"
L[snaplist_date]="Taken"
L[snaplist_note]="As of the last check. Roll back and delete ask for confirmation and require the password. The info button (i) shows the commands for the Proxmox host."
L[snapinfo_title]="Roll back or delete a snapshot of container {id} ({name})"
L[snapinfo_intro]="Both can be done right in the snapshot list (☰). On the Proxmox host they also work with the commands below or in the Proxmox web interface under container → Snapshots."
L[snapinfo_pick]="Snapshot:"
L[snapinfo_none]="This container has no snapshots yet, so the commands show the placeholder <Name>."
L[snapinfo_rb_title]="Roll back"
L[snapinfo_rb_expl]="Resets the container to the state of the snapshot. All changes since the snapshot are lost, including new data of the app. On ZFS this only works for the most recent snapshot; newer ones must be deleted first. If the container is not running afterwards, the second command starts it."
L[snapinfo_del_title]="Delete"
L[snapinfo_del_expl]="Removes the snapshot and frees its space. The container itself stays as it is; it just cannot return to that state afterwards."
L[snapinfo_list_title]="List all snapshots on the host"
L[btn_close]="Close"
L[snap_btn_rollback]="Roll back"
L[snap_btn_delete]="Delete"
L[confirm_delete]="Delete snapshot \"{snap}\" of container {id} ({name})?\n\nThe snapshot is removed for good; the container cannot return to that state afterwards. The container itself stays as it is."
L[confirm_rollback]="Reset container {id} ({name}) to snapshot \"{snap}\" from {date}?\n\nAll changes since this snapshot are lost, including new data of the app. If the container is running, it is shut down for this and started again afterwards."
L[confirm_rollback_newer]="\n\nCaution: there are newer snapshots ({list}). On ZFS the rollback then fails; they would have to be deleted first."
L[confirm_rollback_type]="To confirm, type the name of the snapshot:\n\n{snap}"
L[confirm_mismatch]="The name you typed does not match. Nothing was changed."
L[del_running]="Deleting a snapshot of container {id} …"
L[rb_running]="Resetting container {id} to the snapshot …"
L[del_ok]="Snapshot \"{snap}\" of container {id} was deleted."
L[del_fail]="Snapshot \"{snap}\" of container {id} could not be deleted: {msg}"
L[rb_ok]="Container {id} was reset to snapshot \"{snap}\"."
L[rb_fail]="Container {id} could not be reset to snapshot \"{snap}\": {msg}"

# Status window during a check
L[prog_title]="Check in progress"
L[prog_title_snap]="Creating snapshot …"
L[prog_title_del]="Deleting snapshot …"
L[prog_title_rb]="Rolling back snapshot …"
L[prog_starting]="Starting the check …"
L[prog_step]="{n} of {t}: {name}"
L[prog_finishing]="Writing the report …"
L[prog_close]="Close (keeps running in the background)"
L[pw_prompt]="Password for changes (stored on the Proxmox host in {pwfile}):"

# Changing settings in the browser
L[cfg_readonly]="can only be changed in the file"
L[cfg_CRON_ENABLED]="Switch the automatic check (cron job) on or off. \"Check now\" always works."
L[cfg_CRON_SCHEDULE]="Schedule of the automatic check as a cron expression with five fields: minute, hour, day, month, weekday (0 = Sunday)."
L[cron_examples]="Examples"
L[tip_cron_examples]="Daily at 02:00:\n   0 2 * * *\nWeekly, Sundays at 03:00:\n   0 3 * * 0\nTwice a week, Mondays and Thursdays at 02:30:\n   30 2 * * 1,4"
L[cron_guru]="Check the expression on crontab.guru"
L[cfg_save]="Save"
L[cfg_saving]="Applying …"
L[cfg_saved]="The settings were saved and are active."
L[cfg_applying]="Applying the settings. The page reloads by itself in a few seconds."
L[cfg_busy]="A check is running right now. Until it has finished the settings cannot be changed; the page unlocks them by itself afterwards."


# Help page: commands for a system update
L[btn_help]="Help"
L[help_title]="Help: updating the system"
L[help_intro]="The commands for updating the operating system in a container, step by step. Replace the placeholder <ID> with the container number. All commands run as root."
L[help_filter_label]="Operating system:"
L[help_filter_all]="Show all"
L[help_os_all]="All systems"
L[help_where_host]="on the Proxmox host"
L[help_where_ct]="in the container"
L[help_copy]="Copy"
L[help_copied]="Copied"
L[help_copy_failed]="Selected – copy with Ctrl+C"
L[help_step_enter]="Enter the container"
L[help_expl_enter]="Opens a root shell in the container. The commands of steps 2 to 6 are entered there."
L[help_step_refresh]="Refresh the package lists"
L[help_expl_refresh]="Downloads the current list of available packages from the package sources. Nothing is installed yet."
L[help_step_list]="Show pending updates"
L[help_expl_list]="Shows which packages would be updated. This step changes nothing and can be skipped."
L[help_step_install]="Install the updates"
L[help_expl_install]="Installs all available updates. The command first shows what it will do and asks for confirmation."
L[help_step_autoremove]="Remove packages no longer needed"
L[help_expl_autoremove]="Removes packages that were installed only as a dependency and are no longer needed by anything."
L[help_step_clean]="Empty the package cache"
L[help_expl_clean]="Deletes the downloaded package files and frees disk space. Installed programs are not affected."
L[help_step_reboot]="Restart the container"
L[help_expl_reboot]="Leave the container with \"exit\" first. The restart makes all services use the new program versions. The kernel comes from the Proxmox host and is not updated by this."
L[help_note_arch_refresh]="Not applicable. On Arch, refreshing and installing belong together (step 4); done separately the system can become unusable."
L[help_note_alpine_autoremove]="Not applicable. apk removes packages that are no longer needed by itself."
L[help_note_suse_autoremove]="No dedicated command. \"zypper packages --unneeded\" lists the candidates."
L[help_label_arch_list]="Arch Linux (needs the package pacman-contrib)"
L[help_step_snap]="Before the update: take a snapshot"
L[help_expl_snap]="Records the current state of the container so it can be restored after a failed update. \"pre_update\" is the freely chosen name of the snapshot. The container's storage must support snapshots, for example ZFS, LVM-thin or Btrfs."
L[help_label_snap_create]="Take a snapshot"
L[help_label_snap_list]="List existing snapshots"
L[help_step_rollback]="If something stopped working: back to the snapshot"
L[help_expl_rollback]="Resets the container to the state of the snapshot. All changes since the snapshot are lost, including new data of the app."
L[help_step_delsnap]="When everything works: delete the snapshot"
L[help_expl_delsnap]="Removes the snapshot and frees the space it uses. Rolling back is no longer possible afterwards."
L[help_scope]="Not covered is the move to a new major release of the operating system, for example from Debian 12 to 13."
L[cfg_token_keep]="leave empty = unchanged"
L[cfg_token_remove]="Remove token"
L[cfg_howto2]="Save changes here or edit the file on the Proxmox host: nano {file}. PORT, OUT_DIR and the language files can only be changed there; after PORT or OUT_DIR also run \"lxc-update-check --install\"."

# Error messages with suggested fixes
L[err_server]="The web service does not respond.\nFix: on the Proxmox host check \"systemctl status lxc-update-web\" and run \"systemctl restart lxc-update-web\" if needed. The page must be opened via http://host:port, not as a file.\nAlternative: edit the file directly with \"nano {file}\"."
L[err_oldserver]="The web service does not know this function.\nFix: run \"lxc-update-check --install\" again on the Proxmox host."
L[err_password]="The password is wrong.\nFix: it is stored on the Proxmox host in {pwfile} (show it with \"cat {pwfile}\")."
L[err_nopassword]="No password is set up, so changes from the browser are disabled.\nFix: run \"lxc-update-check --install\" on the Proxmox host; this creates {pwfile}.\nAlternative: edit the file directly with \"nano {file}\"."
L[err_pwneeded]="A password is required.\nIt is stored on the Proxmox host in {pwfile}."
L[err_busy]="A check or an update is currently running.\nFix: wait until the page has reloaded, then try again."
L[err_invalid]="The value for {field} is invalid.\nFix: check the format, see the explanation next to the field. EXCLUDE accepts only numbers and spaces, TIMEOUT only a number."
L[err_nostart]="The request was accepted but not carried out.\nFix: on the Proxmox host check \"systemctl status lxc-update-scan.path\" and \"journalctl -u lxc-update-scan -n 30\", then run \"lxc-update-check --install\" again.\nAlternative: edit the file directly with \"nano {file}\"."
LANG
}

declare -A L=()
source <(lang_de)
[ -f "$LANG_FILE" ] && . "$LANG_FILE"

# lang_sync <file> <function> – brings an existing language file up to date: adds
# texts that are new and replaces texts that changed, unless you edited them. A
# hidden copy of the shipped texts (.<name>.shipped) tells the two cases apart.
lang_sync() {
    local f=$1 src=$2 shipped="${1%/*}/.${1##*/}.shipped" line key cur old added=0 changed=0
    while IFS= read -r line; do
        [[ $line =~ ^L\[([A-Za-z0-9_]+)\]= ]] || continue
        key=${BASH_REMATCH[1]}
        cur=$(grep -m1 "^L\[$key\]=" "$f")
        if [ -z "$cur" ]; then
            [ "$added" -eq 0 ] && printf '\n# Neu hinzugekommen / newly added\n' >> "$f"
            printf '%s\n' "$line" >> "$f"
            added=$((added + 1))
        elif [ "$cur" != "$line" ] && [ -f "$shipped" ]; then
            # A text that changed in this version replaces the old one only if the
            # file still holds the text as shipped, i.e. you did not edit it yourself
            old=$(grep -m1 "^L\[$key\]=" "$shipped")
            if [ "$cur" = "$old" ]; then
                KEY="L[$key]=" NEW="$line" awk 'index($0, ENVIRON["KEY"]) == 1 && !done { print ENVIRON["NEW"]; done = 1; next } { print }' \
                    "$f" > "$f.tmp" && cat "$f.tmp" > "$f"
                rm -f "$f.tmp"
                changed=$((changed + 1))
            fi
        fi
    done < <("$src")
    "$src" > "$shipped"
    [ "$added" -gt 0 ] && echo "  $f: $added new texts added"
    [ "$changed" -gt 0 ] && echo "  $f: $changed changed texts updated"
    return 0
}

# T <key> [name=value …] – text from the language file with placeholders replaced
T() {
    local s=${L[$1]-$1}; shift
    while [ $# -gt 0 ]; do s=${s//"{${1%%=*}}"/"${1#*=}"}; shift; done
    s=${s//'\n'/$'\n'}
    printf '%s' "$s"
}

# Favicon: white arrow in a teal circle, drawn like the arrow button and the title mark.
# --install writes it as favicon.svg and favicon.ico next to the report.
favicon_svg() { cat <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
  <circle cx="32" cy="32" r="30" fill="#0f6e8c"/>
  <path d="M32 50V18M17.5 32.5 32 18l14.5 14.5" fill="none" stroke="#fff" stroke-width="6.5" stroke-linecap="round" stroke-linejoin="round"/>
</svg>
SVG
}
favicon_ico() { base64 -d <<'ICO'
AAABAAEAICAAAAAAIADpBgAAFgAAAIlQTkcNChoKAAAADUlIRFIAAAAgAAAAIAgGAAAAc3p69AAABrBJREFUeJzFl12IlOcVx3/n
eZ93Put+kd6kS4u66EU+SgMJFKEgvYkJ/dDULW3I1WpSrLW1VrwoYWYJLbZbtcYgQsxFCa11F2lJIF4FQUhDKaltjJIarVTd1l2j
u7OzOzvzvs/znF7Mzjruh5E0oediGIY55/8/n885wl1FheERQ3+/b/2y4se/WmN89CAaVmLkswAEvYGYyyHy71X3/+TCvPrwcET/
5gCiyyHIstibN0eMjHiA7h2//nyI9DuobkT1IYlsAWPa1BVCQL2rIXIWkT8YL8cmXvzRlYW27o1AqWQZHHQdA6UeVnT+VJCtksmt
wKeoSyFoQPROr1QEI0ZsDFGMJvWqoi9Trfxs6pXBWy2bH01g83DESL/v/MEv1kucPYrNrtJGDYI6wCAIIAJExgDgVdEmH0VRIGDE
SrYArvFPTRtbKof2nGrZboczizwf6fedO4YGsJk3QVbp7LRDVREsggFERAiq3JyucXO6hvMeI9J0SDAIFlXV2WkHsgqbebNzx9AA
I/2eUskuTWAuRJ3bhwYkVzyKD6ppEhCx7ZEyIqTeY43hl9/6Ki9993G6C3lmEzcfkfnoilhNk4APKrni0c7tQwMMDrp2Ek3Dc0Xy
mW1DX4mymVMEpwSVOY9pB/chUE89I9/byNe/uAaAP1/+NxsO/p6G8+TiCB8WFL0SMKIYK76RrJ8+vPt0C1NQFcpl6Zzs6lD8WRPZ
Xk3TgMiS4A3n+d3Wb7LpS2tJfDOdmSjirYvX+NpLw3choUHi2ATvrgnRQ5WuySnKZTWUyxGDg0HVPW9yxV5NU7cUuGuBb2mCuxDI
RBGZKMKFwLq+Xl7f3k/WRtRTT2QW1LeI0TR1JlfsVXXPMzgYKJcjAejZue9zPnABJIcGac95ZITEBZwP/HbLN9j0SNPz2ETNVgBU
IQ3+XiKhiFHQemRYc+vArlED4Lw+I7lCgRDCQvB66slYwxs//DabHllL6ptA0uagSDMNqfcfFQkhhCC5QsF5fQaYayvVp3BOEW0D
N9RTT9ZGvPb9ftav/QIN54mjiKl6g2sT1XmrH4zf4urEFHEU0XBLkWjLqKjgnIrqU4CYjm37ViM8oC4RaObeiFBLUrI24vXt/azr
66XhmmRuVGtsOHCMs6Pj8zYvjk+w4cAxblRrZO1iErUkbc0JQIy6RBAe6Ni2b7UREx7GZvKoBuaGTOI8XfnsIvDx6gxPHjrOn97/
F5357DyBznyWc1fHePLQccarM4tIdOWzJM4jrWGlGrCZvJjwsAHtmyt65fYnw89tZF1fL/XUzYM/cfA4Z66MkV9RwIUwT8CFQL6Y
48yVMZ44eJtEPXWs6+tl+LmNtNsGtImpfUaNua9ZUYqIkAZPdzHHYyvvByAXW8an5sCvjtFTzOH84ofN+UBPMceZq3MkpmbIxc2B
99jK++ku5khDKwoKIqgx993R76pKJooYq8yw9+TbJN4zOlFl05ETvHPlOj3FHKkPi8Bbks6ReOfKdTYdOcHoRJXEe/aefJuxygyZ
KGo9WvNiJYQPUaXVfUGVQjbm52+8xYm/vs9krcHY1Aw9xTypD23FdDcSef5y+T98ee9v6Cpk+cf1mxSyMWEeXEAVCeFDC3KxWX93
Ps3FbIYPxiewRihmY3xY3vOF4kOgmI2ZqM1yY7pGMZtpA28ymKv5i1aDeVdcMouY/Fx8pBWJfGxRdKHyPUlQxUaGOJKF+oqIwSWz
Gsy7Zurwrkso58RmFDQsNPIxsG8jKUuQ1yA2oyjnpg7vumQAVZETWCvo8svjJyYqirWiIicANQA2kle1XqthjKG9Wz8FeIwxWq/V
bCSvAhhKJXvrwK5R1XBEcnmD6pLb6ycDr15yeaMajtw6sGuUUslaymUPGJm0L4T6TL+J4yUXksW2dMnvd1EIEsc21GeuidgXKJUM
5bI3iCjnz0vl4M7JkOrTqhIwRlGW7TtVyFpLUMUHpbe7g1xsl+8WJWCMqkoIqT5dObhzkvPnBZFmDTAy4imV7PTh3adJk2clm28+
+KqLSDQ34sAf/3YBI0JkhJPvXWI2SYmWGlKqAREkm49Ik2enD+8+3dy+m4fKnRqtzXjH0ACRfVnEiKaJQyRa+N/EeR5/cDX52PLa
35tkjEh7BSuqXuKMVQ2Kd1srL+5+ZeGB8vEPExGmZhuoKh23n+b/8TABWsdD5dCeU6Ey8WhIZvcjpir5opVMxiAizeEYfFc+67uL
OQ94lICISCZjJF+0iKmGZHZ/qEw8Wjm051Tr6FmU0sVJa0Xi/3mczsunf57/Fzm+9ybU61ZuAAAAAElFTkSuQmCC
ICO
}

# Small web server: serves the report and accepts jobs:
#   POST /scan            check now (no password)
#   POST /refresh?id=<n>  re-check one container only (no password)
#   POST /config          save settings, JSON (password)
#   POST /snapshot?id=<n>&name=<s>  take a snapshot of a container (password)
#   POST /snapdel?id=<n>&name=<s>   delete a snapshot (password)
#   POST /rollback?id=<n>&name=<s>  roll a container back to a snapshot (password)
# It runs unprivileged, validates password and input and only drops a job file.
# The job itself is executed by systemd via "lxc-update-check --dispatch".
web_py() { cat <<'WEBPY'
#!/usr/bin/env python3
import sys, os, re, json, time, hmac, functools
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler

PORT, DIR, REQUEST, LANG_DIR = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]

# Allowed settings and their format; everything else is rejected
RULES = {
    "INCLUDE_HOST": r"[01]",
    "CRON_ENABLED": r"[01]",
    "CRON_SCHEDULE": r"([0-9A-Za-z*/,-]{1,30} ){4}[0-9A-Za-z*/,-]{1,30}",
    "TIMEOUT": r"[1-9][0-9]{0,4}",
    "EXCLUDE": r"[0-9 ]{0,200}",
    "LANG_FILE": re.escape(LANG_DIR) + r"/[A-Za-z0-9._-]+\.lang",
    "GITHUB_TOKEN": r"[A-Za-z0-9_]{0,255}",
}


def password():
    try:
        with open(os.path.join(os.environ.get("CREDENTIALS_DIRECTORY", ""), "webpass")) as f:
            return f.read().strip()
    except OSError:
        return ""


def busy():
    try:
        with open(os.path.join(DIR, "status.json")) as f:
            return bool(json.load(f).get("running"))
    except (OSError, ValueError):
        return False


class Handler(SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def guess_type(self, path):
        # Show the log in the browser instead of downloading it, with correct umlauts
        if str(path).endswith(".txt"):
            return "text/plain; charset=utf-8"
        return super().guess_type(path)

    def reply(self, code, **data):
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(min(n, 65536)) if n else b""
        path, _, query = self.path.partition("?")
        if path not in ("/scan", "/refresh", "/config", "/snapshot", "/snapdel", "/rollback"):
            return self.reply(404, error="notfound")
        lines = ["action=" + path[1:]]
        if path in ("/config", "/snapshot", "/snapdel", "/rollback"):
            pw = password()
            if not pw:
                return self.reply(403, error="nopassword")
            if not hmac.compare_digest(self.headers.get("X-Password", "").encode(), pw.encode()):
                time.sleep(1)
                return self.reply(401, error="password")
        if path == "/refresh":
            m = re.fullmatch(r"id=([0-9]{1,9})", query)
            if not m:
                return self.reply(400, error="invalid", field="id")
            lines.append("id=" + m.group(1))
        if path in ("/snapshot", "/snapdel", "/rollback"):
            m = re.fullmatch(r"id=([0-9]{1,9})&name=([A-Za-z][A-Za-z0-9_-]{0,39})", query)
            if not m:
                return self.reply(400, error="invalid", field="name")
            lines += ["id=" + m.group(1), "name=" + m.group(2)]
        if path == "/config":
            try:
                data = json.loads(raw.decode() or "{}")
            except ValueError:
                data = None
            if not isinstance(data, dict):
                return self.reply(400, error="invalid", field="")
            for k, v in data.items():
                ok = k in RULES and isinstance(v, str) and re.fullmatch(RULES[k], v)
                if ok and k == "LANG_FILE":
                    ok = os.path.isfile(v)
                if not ok:
                    return self.reply(400, error="invalid", field=str(k)[:40])
                lines.append("%s=%s" % (k, v))
        if busy():
            return self.reply(409, error="busy")
        try:
            with open(REQUEST + ".tmp", "w") as f:
                f.write("\n".join(lines) + "\n")
            os.replace(REQUEST + ".tmp", REQUEST)
        except OSError:
            return self.reply(500, error="write")
        self.reply(202, ok=True)

    def log_message(self, *args):
        pass


ThreadingHTTPServer(("", PORT), functools.partial(Handler, directory=DIR)).serve_forever()
WEBPY
}

case "${1:-}" in --help|-h) ;; *) [ "$(id -u)" -eq 0 ] || { echo "Please run as root." >&2; exit 1; } ;; esac

# ------------------------------------------------------------------ Installation
# write_cron – creates or removes the cron job according to CRON_ENABLED and CRON_SCHEDULE
write_cron() {
    if [ "$CRON_ENABLED" = 1 ] && [[ $CRON_SCHEDULE =~ $CRON_RE ]]; then
        cat > "$CRON" <<EOF
# LXC update check – automatic check
# This file is written by the script; change schedule and on/off in $ETC/config.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
$CRON_SCHEDULE root $BIN > $LOG 2>&1
EOF
        chmod 644 "$CRON"
    else
        rm -f "$CRON"
    fi
}

do_install() {
    local self; self=$(readlink -f "$0")
    [ "$self" = "$BIN" ] || install -m 755 "$self" "$BIN"
    mkdir -p "$OUT_DIR" "$ETC/lang" "$SHARE"; chmod 755 "$OUT_DIR"

    # Create settings and language files only if missing, never overwrite them
    if [ ! -f "$ETC/config" ]; then
        cat > "$ETC/config" <<EOF
# Settings for lxc-update-check
# After changing PORT or OUT_DIR run "lxc-update-check --install" again.

OUT_DIR="$OUT_DIR"        # where the report is written
PORT="$PORT"              # port of the web server
INCLUDE_HOST="$INCLUDE_HOST"   # 1 = also check the Proxmox host itself
TIMEOUT="$TIMEOUT"        # max. seconds per container
EXCLUDE="$EXCLUDE"        # CT IDs to skip, e.g. "105 112"

# Language of the report: a file from $ETC/lang/
LANG_FILE="$LANG_FILE"
EOF
    fi
    if ! grep -q '^#\? *CRON_ENABLED=' "$ETC/config"; then
        cat >> "$ETC/config" <<EOF

# Automatic check: 1 = on, 0 = off
CRON_ENABLED="$CRON_ENABLED"
EOF
    fi
    if ! grep -q '^#\? *CRON_SCHEDULE=' "$ETC/config"; then
        cat >> "$ETC/config" <<EOF

# Schedule as a cron expression: minute hour day month weekday (https://crontab.guru/)
#   daily 02:00:  0 2 * * *     Sundays 03:00:  0 3 * * 0     Mon + Thu 02:30:  30 2 * * 1,4
CRON_SCHEDULE="$CRON_SCHEDULE"
EOF
    fi
    # Leftovers of the removed update function (earlier versions)
    sed -i '/^# 1 = .*[Ss]napshot/d; /^UPDATE_SNAPSHOT=/d' "$ETC/config"
    rm -f "$OUT_DIR/last-update" "$OUT_DIR/update-log.txt"
    if ! grep -q '^#\? *GITHUB_TOKEN=' "$ETC/config"; then
        cat >> "$ETC/config" <<'EOF'

# Optional GitHub token (lifts the limit of 60 version lookups per hour)
GITHUB_TOKEN=""
EOF
    fi
    chmod 600 "$ETC/config"
    # Password for updates and settings in the browser (generated once)
    if [ ! -s "$PWFILE" ]; then
        head -c 18 /dev/urandom | base64 | tr -d '/+=' | cut -c1-16 > "$PWFILE"
    fi
    chmod 600 "$PWFILE"
    [ -f "$ETC/lang/de.lang" ] || lang_de > "$ETC/lang/de.lang"
    [ -f "$ETC/lang/en.lang" ] || lang_en > "$ETC/lang/en.lang"
    # Add new texts to existing language files (German as the template for your own files)
    local lf
    for lf in "$ETC"/lang/*.lang; do
        case $lf in */en.lang) lang_sync "$lf" lang_en ;; *) lang_sync "$lf" lang_de ;; esac
    done
    web_py > "$SHARE/web.py"
    favicon_svg > "$OUT_DIR/favicon.svg"
    favicon_ico > "$OUT_DIR/favicon.ico"
    chmod 644 "$OUT_DIR/favicon.svg" "$OUT_DIR/favicon.ico"

    write_cron

    cat > "$UNIT_WEB" <<EOF
[Unit]
Description=Web server of the LXC update report
After=network-online.target

[Service]
ExecStart=/usr/bin/python3 $SHARE/web.py $PORT $OUT_DIR $REQUEST $ETC/lang
LoadCredential=webpass:$PWFILE
User=nobody
Group=nogroup
RuntimeDirectory=lxc-update-check
RuntimeDirectoryMode=0700
RuntimeDirectoryPreserve=yes
ProtectSystem=strict
ProtectHome=yes
NoNewPrivileges=yes
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

    cat > "$UNIT_PATH" <<EOF
[Unit]
Description=Runs jobs from the LXC update report (check, snapshot, settings)

[Path]
PathExists=$REQUEST
Unit=lxc-update-scan.service

[Install]
WantedBy=multi-user.target
EOF

    # When the password changes the web service restarts and knows it immediately
    cat > "$UNIT_PWPATH" <<EOF
[Unit]
Description=Picks up a changed password for the LXC update report

[Path]
PathChanged=$PWFILE
Unit=lxc-update-pw.service

[Install]
WantedBy=multi-user.target
EOF

    cat > "$UNIT_PWSVC" <<EOF
[Unit]
Description=Restart the web service of the LXC update report with the new password

[Service]
Type=oneshot
ExecStart=/usr/bin/systemctl try-restart lxc-update-web.service
EOF

    cat > "$UNIT_SCAN" <<EOF
[Unit]
Description=LXC update check (started from the report)

[Service]
Type=oneshot
ExecStart=$BIN --dispatch
EOF

    systemctl daemon-reload
    systemctl enable --now lxc-update-web.service lxc-update-scan.path lxc-update-pw.path >/dev/null
    systemctl restart lxc-update-web.service lxc-update-scan.path lxc-update-pw.path

    echo "Installed. Running the first scan …"
    "$BIN"
    echo
    echo "Report:        http://$(hostname -I | awk '{print $1}'):$PORT/"
    if [ "$CRON_ENABLED" = 1 ]; then
        echo "Schedule:       $CRON_SCHEDULE ($CRON), log: $LOG"
    else
        echo "Schedule:       automatic check switched off (CRON_ENABLED in $ETC/config)"
    fi
    echo "Settings:       $ETC/config"
    echo "Language files: $ETC/lang/"
    echo "Password for settings and snapshots in the browser: $(cat "$PWFILE")   (file: $PWFILE)"
}

do_uninstall() {
    systemctl disable --now lxc-update-web.service lxc-update-scan.path lxc-update-pw.path 2>/dev/null
    rm -f "$UNIT_WEB" "$UNIT_PATH" "$UNIT_SCAN" "$UNIT_PWPATH" "$UNIT_PWSVC" "$CRON" "$BIN"
    rm -rf "$STATE"
    rm -rf "$SHARE"
    systemctl daemon-reload
    echo "Removed. Report ($OUT_DIR) and settings ($ETC) were kept."
}

# do_dispatch – executes the job the web server dropped
do_dispatch() {
    local action="" id="" sname="" line k v
    local -A cfg=()
    [ -f "$REQUEST" ] || exit 0
    mapfile -t lines < "$REQUEST"
    rm -f "$REQUEST"
    for line in "${lines[@]}"; do
        k=${line%%=*}; v=${line#*=}
        case $k in action) action=$v ;; id) id=$v ;; name) sname=$v ;; ?*) cfg[$k]=$v ;; esac
    done
    case $action in
        refresh)
            [[ $id =~ ^[0-9]+$ ]] || exit 1
            exec bash "$0" --refresh "$id" ;;
        snapshot)
            [[ $id =~ ^[0-9]+$ ]] && [[ $sname =~ ^[A-Za-z][A-Za-z0-9_-]{0,39}$ ]] || exit 1
            exec bash "$0" --snapshot "$id" "$sname" ;;
        snapdel|rollback)
            [[ $id =~ ^[0-9]+$ ]] && [[ $sname =~ ^[A-Za-z][A-Za-z0-9_-]{0,39}$ ]] || exit 1
            exec bash "$0" "--$action" "$id" "$sname" ;;
        config)
            # Every setting is validated again here before it goes into the file
            [ -f "$CONFIG" ] || : > "$CONFIG"
            for k in "${!cfg[@]}"; do
                v=${cfg[$k]}
                case $k in
                    INCLUDE_HOST|CRON_ENABLED) [[ $v =~ ^[01]$ ]] || continue ;;
                    CRON_SCHEDULE) [[ $v =~ $CRON_RE ]] || continue ;;
                    TIMEOUT)      [[ $v =~ ^[1-9][0-9]{0,4}$ ]] || continue ;;
                    EXCLUDE)      [[ $v =~ ^[0-9\ ]*$ ]] || continue ;;
                    GITHUB_TOKEN) [[ $v =~ ^[A-Za-z0-9_]*$ ]] || continue ;;
                    LANG_FILE)    [[ ${v##*/} =~ ^[A-Za-z0-9._-]+\.lang$ ]] && [ "${v%/*}" = "$ETC/lang" ] && [ -f "$v" ] || continue ;;
                    *) continue ;;
                esac
                if grep -q "^$k=" "$CONFIG"; then
                    sed -i "s|^$k=.*|$k=\"$v\"|" "$CONFIG"
                else
                    printf '%s="%s"\n' "$k" "$v" >> "$CONFIG"
                fi
            done
            # Rebuild the pages from the stored results (feedback within seconds);
            # nothing is checked again, not even after a language change
            bash "$0" --cron       # write the cron job according to the new settings
            exec bash "$0" --render ;;
        *)  exec bash "$0" ;;
    esac
}

usage() { cat <<EOF
Usage: lxc-update-check [option]

  (no option)                    check all containers now and write the report
  --install                      set up cron job, web server and settings, then run a check
  --uninstall                    remove cron job and web server (report and settings are kept)
  --refresh <CT-ID>              check a single container again
  --snapshot <CT-ID> <name>      take a snapshot of a container, then check it again
                                 (name: letters, digits, _ and -, starting with a letter)
  --rollback <CT-ID> <name>      reset a container to a snapshot (a running container is
                                 shut down and started again), then check it again
  --snapdel <CT-ID> <name>       delete a snapshot, then check the container again
  --help                         show this help

Settings: $ETC/config    Report: $OUT_DIR/index.html    Log of the cron job: $LOG
EOF
}

REFRESH_ID=""; RENDER=""; SNAP_ID=""; SNAP_NAME=""; SNAP_OK=""; SNAP_MSG=""; SNAP_OP=create
case "${1:-}" in
    --help|-h)   usage; exit 0 ;;
    --install)   do_install;   exit 0 ;;
    --uninstall) do_uninstall; exit 0 ;;
    --dispatch)  do_dispatch ;;
    --cron)   write_cron; exit 0 ;;
    --render) RENDER=1 ;;      # only rewrite the pages from the remembered rows
    --refresh)
        [[ ${2:-} =~ ^[0-9]+$ ]] || { echo "Usage: $0 --refresh <CT-ID>" >&2; exit 1; }
        REFRESH_ID=$2 ;;
    --snapshot)
        { [[ ${2:-} =~ ^[0-9]+$ ]] && [[ ${3:-} =~ ^[A-Za-z][A-Za-z0-9_-]{0,39}$ ]]; } \
            || { echo "Usage: $0 --snapshot <CT-ID> <name>   (name: letters, digits, _ and -, starting with a letter)" >&2; exit 1; }
        SNAP_ID=$2; SNAP_NAME=$3; REFRESH_ID=$2 ;;      # afterwards the container is re-checked
    --snapdel|--rollback)
        { [[ ${2:-} =~ ^[0-9]+$ ]] && [[ ${3:-} =~ ^[A-Za-z][A-Za-z0-9_-]{0,39}$ ]]; } \
            || { echo "Usage: $0 $1 <CT-ID> <snapshot name>" >&2; exit 1; }
        SNAP_ID=$2; SNAP_NAME=$3; REFRESH_ID=$2
        [ "$1" = --snapdel ] && SNAP_OP=delete || SNAP_OP=rollback ;;
    "") ;;
    *) usage >&2; exit 1 ;;
esac

# ------------------------------------------- Check snippet (runs inside the container)
# Output format, one line per entry:
#   OS|<name>                 WARN|<code, the text is in the language file>|<detail>
#   CS|<community-script>|<base url>   from /usr/bin/update, e.g. "vaultwarden"
#   VER|<file>|<version>      version files of the community-scripts (~/.<app>)
#   LEG|<app>|<version>       older location (/opt/<App>_version.txt)
#   APP|<name>|<installed>|<latest>       apps that report their versions themselves
#   APT|<package>|<installed>|<available> app installed as a system package
#   DOCK|<container>|<image>|<digests>|<version>    running Docker containers
#   MAN|<name>|<owner/repo>|<version>     declared in /etc/lxc-update-check.conf
#   PKG|<package>|<installed>|<new>|<security 0/1>
# cs_detect runs inside the container and reads from /usr/bin/update which
# community-script belongs to the app. Output: <script name>|<base url or empty>. Two formats:
#   old:  bash -c "$(curl -fsSL https://…/ct/<name>.sh)"
#   new:  export UPDATE_SCRIPT_NAME="<name>" (plus SCRIPT_SLUG and COMMUNITY_SCRIPTS_URL);
#         the actual call there reads ct/${UPDATE_SCRIPT_NAME}.sh
CS_FUNC=$(cat <<'EOS'
cs_detect() {
    f=/usr/bin/update
    [ -f "$f" ] || return 0
    cs_var() { sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}$1=[\"']\{0,1\}\([^\"']*\)[\"']\{0,1\}[[:space:]]*\$/\2/p" "$f" | head -n1; }
    n=$(cs_var UPDATE_SCRIPT_NAME)
    [ -n "$n" ] || n=$(cs_var SCRIPT_SLUG)
    if [ -z "$n" ]; then
        n=$(grep -o 'ct/[A-Za-z0-9._-]*\.sh' "$f" 2>/dev/null | head -n1)
        n=${n#ct/}; n=${n%.sh}
    fi
    case $n in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
    echo "$n|$(cs_var COMMUNITY_SCRIPTS_URL)"
}
EOS
)

SNIPPET=$CS_FUNC$'\n'$(cat <<'EOS'
. /etc/os-release 2>/dev/null
echo "OS|${PRETTY_NAME:-?}"

s=$(cs_detect)
if [ -n "$s" ]; then echo "CS|$s"; fi
# Manual declaration for apps that are not detected otherwise
mf=/etc/lxc-update-check.conf
if [ -f "$mf" ]; then
    mget() { sed -n "s/^$1=//p" "$mf" | head -n1 | tr -d '\r'; }
    m_script=$(mget script); m_name=$(mget name); m_repo=$(mget repo)
    m_ver=$(mget version); m_cmd=$(mget version_cmd)
    if [ -z "$m_ver" ] && [ -n "$m_cmd" ]; then
        m_ver=$(sh -c "$m_cmd" 2>/dev/null | head -n1 | tr -d '\r|')
    fi
    if [ -z "$s" ] && [ -n "$m_script" ]; then echo "CS|$m_script|"; fi
    if [ -n "$m_repo" ]; then echo "MAN|${m_name:-$m_repo}|$m_repo|$m_ver"; fi
fi
for f in /root/.[a-z0-9]*; do
    [ -f "$f" ] || continue
    [ "$(wc -c < "$f")" -le 64 ] || continue
    v=$(head -n1 "$f" | tr -d '\r')
    case $v in ''|*[!A-Za-z0-9._+-]*) continue ;; esac
    case $v in *[0-9]*) echo "VER|${f#/root/.}|$v" ;; esac
done
for f in /opt/*_version.txt /var/cache/app-versions/*_version.txt; do
    [ -f "$f" ] || continue
    n=${f##*/}
    echo "LEG|${n%_version.txt}|$(head -n1 "$f" | tr -d '\r')"
done
# Pi-hole keeps installed and latest versions itself in /etc/pihole/versions
# (refreshed by Pi-hole once a day)
pv=/etc/pihole/versions
if [ -f "$pv" ]; then
    pget() { v=$(sed -n "s/^$1=//p" "$pv" | head -n1 | tr -d '\r"'); [ "$v" = null ] && v=""; echo "$v"; }
    for c in CORE WEB FTL; do
        pi=$(pget "${c}_VERSION"); pl=$(pget "GITHUB_${c}_VERSION")
        case $c in CORE) pn="Pi-hole Core" ;; WEB) pn="Pi-hole Web" ;; *) pn="Pi-hole FTL" ;; esac
        [ -n "$pi" ] && echo "APP|$pn|$pi|$pl"
    done
fi
if command -v docker >/dev/null 2>&1; then
    for c in $(docker ps -q 2>/dev/null); do
        line=$(docker inspect "$c" --format '{{.Name}}|{{.Config.Image}}|{{.Image}}' 2>/dev/null) || continue
        n=${line%%|*}; rest=${line#*|}; ref=${rest%%|*}; iid=${rest#*|}
        info=$(docker image inspect "$iid" \
            --format '{{join .RepoDigests ","}}|{{index .Config.Labels "org.opencontainers.image.version"}}' 2>/dev/null)
        echo "DOCK|${n#/}|$ref|${info:-|}"
    done
fi

if command -v apt-get >/dev/null 2>&1; then
    # apt-get update already reports an error when a single package source fails.
    # The actual message is passed along so the report can show the cause.
    if ! au=$(apt-get update -qq 2>&1); then
        ae=$(printf '%s\n' "$au" | grep -m1 -E '^(E:|Err)')        # errors before warnings
        [ -n "$ae" ] || ae=$(printf '%s\n' "$au" | grep -m1 '^W:')
        echo "WARN|apt|$(printf '%s' "$ae" | tr -d '|\r' | cut -c1-300)"
    fi
    # Many community-scripts install the app as a package from its own source
    # (e.g. ntfy). The package version then is the app version.
    if [ -n "$s" ]; then
        n=${s%%|*}; n=${n#alpine-}
        for p in "$n" "$n-server" "$n-ce" "$n-core" "${n}d" "${n}mediaserver" "$n-connector"; do
            pi=$(dpkg-query -W -f='${db:Status-Abbrev}|${Version}' "$p" 2>/dev/null)
            case $pi in ii*) ;; *) continue ;; esac
            pc=$(LC_ALL=C apt-cache policy "$p" 2>/dev/null | awk '/Candidate:/ { print $2 }')
            echo "APT|$p|${pi#*|}|$pc"
            break
        done
    fi
    apt-get -s dist-upgrade 2>/dev/null | awk '
        /^Inst / {
            name = $2; old = "NEW"
            if ($3 ~ /^\[/) { old = $3; gsub(/[][]/, "", old); new = $4 } else { new = $3 }
            gsub(/[()]/, "", new)
            sec = (tolower($0) ~ /security/) ? 1 : 0
            print "PKG|" name "|" old "|" new "|" sec
        }'
elif command -v apk >/dev/null 2>&1; then
    apk update -q >/dev/null 2>&1 || echo "WARN|apk"
    apk version -l '<' 2>/dev/null | grep ' < ' \
        | sed -E 's/^(.+)-([0-9][^ -]*-r[0-9]+) +< +(.+)$/PKG|\1|\2|\3|0/'
elif command -v dnf >/dev/null 2>&1; then
    dnf -q check-update 2>/dev/null | awk '
        /^Obsoleting/ { exit }
        NF == 3 && $1 ~ /\./ { print "PKG|" $1 "|–|" $2 "|0" }'
elif command -v pacman >/dev/null 2>&1; then
    if command -v checkupdates >/dev/null 2>&1; then
        checkupdates 2>/dev/null | awk '{ print "PKG|" $1 "|" $2 "|" $4 "|0" }'
    else
        echo "WARN|checkupdates"
    fi
else
    echo "WARN|nopm"
fi
EOS
)

# ------------------------------------------------------------------- Helper functions
esc() {
    local s=$1
    # Quoted replacements: otherwise "&" stands for the matched text from bash 5.2 on
    s=${s//&/"&amp;"}; s=${s//</"&lt;"}; s=${s//>/"&gt;"}; s=${s//\"/"&quot;"}
    printf '%s' "$s"
}

# Only one scan at a time (cron job and the button in the report can overlap)
LOCKDIR=/run/lock; [ -d "$LOCKDIR" ] || LOCKDIR=/tmp
exec 9> "$LOCKDIR/lxc-update-check.lock"
flock -n 9 || { echo "A scan is already running."; exit 0; }

# status.json tells the report whether a check is running and how old the report is
mkdir -p "$OUT_DIR"
# While a run is in progress status.json keeps the time of the last finished report.
# A reset to 0 would hide the quick re-render after saving settings from the browser.
GEN=$(sed -n 's/.*"generated":\([0-9]*\).*/\1/p' "$OUT_DIR/status.json" 2>/dev/null)
GEN=${GEN:-0}
ACTION=scan
[ -n "$REFRESH_ID" ] && ACTION=refresh
[ -n "$RENDER" ] && ACTION=render
[ -n "$SNAP_ID" ] && ACTION=snapshot
[ "$SNAP_OP" = delete ] && ACTION=snapdel
[ "$SNAP_OP" = rollback ] && ACTION=rollback
# Progress for the status window: phase, step x of y, current container, results
P_PHASE=start; P_STEP=0; P_TOTAL=0; P_ID=""; P_NAME=""; P_LOG=""
jesc() {
    local s=$1
    s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/ }; s=${s//$'\t'/ }
    printf '%s' "$s"
}
write_status() {
    local snap=null
    [ -n "$SNAP_OK" ] && snap="{\"op\":\"$SNAP_OP\",\"id\":\"$SNAP_ID\",\"name\":\"$SNAP_NAME\",\"ok\":$([ "$SNAP_OK" = 1 ] && echo true || echo false),\"msg\":\"$(jesc "$SNAP_MSG")\"}"
    printf '{"running":%s,"generated":%s,"action":"%s","id":"%s","phase":"%s","step":%s,"total":%s,"cur_id":"%s","cur_name":"%s","log":[%s],"snap":%s}\n' \
        "$1" "$2" "$ACTION" "$REFRESH_ID" "$P_PHASE" "$P_STEP" "$P_TOTAL" \
        "$(jesc "$P_ID")" "$(jesc "$P_NAME")" "$P_LOG" "$snap" > "$OUT_DIR/.status.tmp" \
        && chmod 644 "$OUT_DIR/.status.tmp" && mv -f "$OUT_DIR/.status.tmp" "$OUT_DIR/status.json"
}
# progress <id> <name> – the next container is being checked
progress() {
    P_PHASE=scan; P_STEP=$((P_STEP + 1)); P_ID=$1; P_NAME=$2
    write_status true "$GEN"
}

CACHE=$(mktemp -d)
trap 'rm -rf "$CACHE"; write_status false "$GEN"' EXIT
write_status true "$GEN"
declare -A LATEST=()

# Results of the last check are kept in $STATE so that the pages can be rebuilt in
# another language (or after a settings change) without asking the containers,
# GitHub or the registries again:
#   <id>.raw          what a container reported (first line: id|name|state)
#   lookups/<hash>    release and registry lookups      scripts/<name>.sh  update scripts
# REPLAY=1 while such a row is rebuilt: lookups then come from the store.
REPLAY=""
lk_file() { printf '%s/lookups/%s' "$STATE" "$(printf '%s' "$1" | md5sum | cut -c1-32)"; }
lk_get() { local f; f=$(lk_file "$1"); [ -f "$f" ] || return 1; REPLY=$(<"$f"); }
lk_put() { mkdir -p "$STATE/lookups" && printf '%s' "$2" > "$(lk_file "$1")"; }

# cs_script <name> [base url] – downloads the app's update script (once per run),
# path in $REPLY. The base url comes from the container's /usr/bin/update and is only
# accepted if it points to GitHub. Renamed scripts are resolved like the community-scripts
# update helper does (alpine-<x> → <x>, <x>-v2 → <x>, pbs → proxmox-backup-server).
cs_script() {
    local n=$1 base=${2%/} c cand
    REPLY="$CACHE/$n.sh"
    [ -f "$REPLY" ] && return
    if [ -n "$REPLAY" ] && [ -f "$STATE/scripts/$n.sh" ]; then cp "$STATE/scripts/$n.sh" "$REPLY"; return; fi
    case $base in
        *//git.community-scripts.org/*)
            base=${base#*//git.community-scripts.org/}
            base=${base/\/raw\/branch\//\/}; base=${base/\/raw\/tag\//\/}; base=${base/\/raw\/commit\//\/}
            base="https://raw.githubusercontent.com/$base" ;;
    esac
    [[ $base =~ ^https://raw\.githubusercontent\.com/[A-Za-z0-9._/-]+$ ]] || base=$CS_RAW
    cand=("$n" "${n#alpine-}" "$(sed -E 's/-v[0-9]+$//' <<< "$n")")
    [ "$n" = pbs ] && cand+=(proxmox-backup-server)
    for c in "${cand[@]}"; do
        if curl -fsSL --max-time 20 "$base/ct/$c.sh" -o "$REPLY" 2>/dev/null && [ -s "$REPLY" ]; then
            mkdir -p "$STATE/scripts" && cp "$REPLY" "$STATE/scripts/$n.sh"
            return
        fi
    done
    : > "$REPLY"
}

# cs_checks <file> – the script's version checks as  source|name|repo|pin
cs_checks() {
    grep -oE 'check_for_(gh_release|codeberg_release|gh_tag)[[:space:]]+"[^"]+"[[:space:]]+"[^"]+"([[:space:]]+"[^"]*")?' "$1" \
        | sed -E 's/^check_for_(gh_release|codeberg_release|gh_tag)[[:space:]]+"([^"]+)"[[:space:]]+"([^"]+)"([[:space:]]+"([^"]*)")?$/\1|\2|\3|\5/' \
        | awk -F'|' '!seen[$2]++'
}

# Release lookup: latest stable release and, if newer still, the pre-release.
# A pre-release is what GitHub marks as one OR what looks like one by its name
# (e.g. Wiki.js 3.0.0-beta.628, which GitHub lists as a normal release).
# Output: <stable>|<pre-release or empty>|<1 = GitHub lists it as a normal release>
PRE_RE='(alpha|beta|preview|nightly|canary|snapshot|unstable|[-._](rc|pre|dev)[-._0-9]*$|[0-9]rc[0-9]*$)'
REL_PY="$CACHE/releases.py"
cat > "$REL_PY" <<'PY'
import os, re, sys, json, urllib.request

kind, repo, pre_re = sys.argv[1], sys.argv[2], re.compile(sys.argv[3], re.I)
hdr = {"User-Agent": "lxc-update-check"}
if kind == "codeberg":
    url = "https://codeberg.org/api/v1/repos/%s/releases?limit=50&page=%%d" % repo
else:
    url = "https://api.github.com/repos/%s/releases?per_page=100&page=%%d" % repo
    hdr["Accept"] = "application/vnd.github+json"
    if os.environ.get("GITHUB_TOKEN"):
        hdr["Authorization"] = "Bearer " + os.environ["GITHUB_TOKEN"]


def is_pre(x):
    return bool(x.get("prerelease")) or bool(pre_re.search(x.get("tag_name", "")))


stable = beta = flag = ""
for page in (1, 2, 3):
    with urllib.request.urlopen(urllib.request.Request(url % page, headers=hdr), timeout=20) as r:
        rels = [x for x in json.load(r) if not x.get("draft")]
    if not rels:
        break
    if page == 1 and is_pre(rels[0]):
        beta = rels[0]["tag_name"]
        flag = "" if rels[0].get("prerelease") else "1"
    stable = next((x["tag_name"] for x in rels if not is_pre(x)), "")
    if stable:
        break
print("%s|%s|%s" % (stable, beta, flag))
PY

# stable_from_tags <owner/repo> – highest stable version from the tag list (no API)
stable_from_tags() {
    curl -fsSL --max-time 20 "https://github.com/$1.git/info/refs?service=git-upload-pack" 2>/dev/null \
        | grep -ao 'refs/tags/[^^[:space:]]*' | sed 's|^refs/tags/||' \
        | grep -E '^v?[0-9]' | grep -viE "$PRE_RE" | sed 's/^v//' | sort -uV | tail -n1
}

# latest_release <gh|codeberg> <owner/repo> – stable release in $REPLY, newer
# pre-release (or empty) in $REPLY2, $REPLY3=1 if "update" would install that one
latest_release() {
    local key="$1:$2" out stable="" beta="" flag="" rest
    if [ -n "$REPLAY" ] && lk_get "rel|$key"; then
        rest=$REPLY; REPLY=${rest%%|*}; rest=${rest#*|}; REPLY2=${rest%%|*}; REPLY3=${rest#*|}
        return
    fi
    if [ -z "${LATEST[$key]+x}" ] && [ "$1" = ghtag ]; then
        LATEST[$key]="$(stable_from_tags "$2")||"      # app is versioned by tags instead of releases
    fi
    if [ -z "${LATEST[$key]+x}" ]; then
        out=$(GITHUB_TOKEN="$GITHUB_TOKEN" timeout 60 python3 "$REL_PY" "$1" "$2" "$PRE_RE" 2>/dev/null | head -n1)
        if [[ $out == *"|"*"|"* ]]; then
            stable=${out%%|*}; rest=${out#*|}; beta=${rest%%|*}; flag=${rest#*|}
        fi
        if [ -z "$stable" ] && [ "$1" = gh ]; then
            # Fallback without the API (no rate limit)
            stable=$(curl -s --max-time 20 -o /dev/null -w '%{redirect_url}' "https://github.com/$2/releases/latest" 2>/dev/null)
            case $stable in */releases/tag/*) stable=${stable##*/releases/tag/} ;; *) stable="" ;; esac
            if [ -n "$stable" ] && grep -qiE "$PRE_RE" <<< "$stable"; then
                beta=$stable; flag=1; stable=$(stable_from_tags "$2")
            fi
        fi
        LATEST[$key]="$stable|$beta|$flag"
    fi
    lk_put "rel|$key" "${LATEST[$key]}"
    rest=${LATEST[$key]}
    REPLY=${rest%%|*}; rest=${rest#*|}; REPLY2=${rest%%|*}; REPLY3=${rest#*|}
}

# Registry lookup for Docker images (runs on the host, needs only python3).
# Call: registry.py <image> <local digests, comma separated> <arch>
# Output: ok|   or   upd|<version of the new image, if stated>   or   err|<reason>
REG_PY="$CACHE/registry.py"
cat > "$REG_PY" <<'PY'
import sys, json, re, hashlib, urllib.request, urllib.parse, urllib.error

ACCEPT = ", ".join([
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
])
UA = "lxc-update-check"


class NoAuthRedirect(urllib.request.HTTPRedirectHandler):
    # Blobs often live on a CDN; the token must not be sent there
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        new = super().redirect_request(req, fp, code, msg, headers, newurl)
        if new is not None:
            new.headers.pop("Authorization", None)
        return new


opener = urllib.request.build_opener(NoAuthRedirect)
tokens = {}


def parse(ref):
    ref = ref.split("@")[0]
    first, _, rest = ref.partition("/")
    if rest and ("." in first or ":" in first or first == "localhost"):
        reg, path = first, rest
    else:
        reg, path = "registry-1.docker.io", ref
    if ":" in path.rsplit("/", 1)[-1]:
        repo, tag = path.rsplit(":", 1)
    else:
        repo, tag = path, "latest"
    if reg in ("docker.io", "index.docker.io"):
        reg = "registry-1.docker.io"
    if reg == "registry-1.docker.io" and "/" not in repo:
        repo = "library/" + repo
    return reg, repo, tag


def call(reg, repo, path, method="GET", accept=ACCEPT):
    key = (reg, repo)
    hdr = {"Accept": accept, "User-Agent": UA}
    if key in tokens:
        hdr["Authorization"] = "Bearer " + tokens[key]
    req = urllib.request.Request("https://%s/v2/%s/%s" % (reg, repo, path), headers=hdr, method=method)
    try:
        return opener.open(req, timeout=20)
    except urllib.error.HTTPError as e:
        if e.code != 401 or key in tokens:
            raise
        p = dict(re.findall(r'(\w+)="([^"]*)"', e.headers.get("WWW-Authenticate", "")))
        if "realm" not in p:
            raise
        q = urllib.parse.urlencode({k: p[k] for k in ("service", "scope") if k in p})
        treq = urllib.request.Request(p["realm"] + "?" + q, headers={"User-Agent": UA})
        with urllib.request.urlopen(treq, timeout=20) as r:
            t = json.load(r)
        tokens[key] = t.get("token") or t.get("access_token") or ""
        return call(reg, repo, path, method, accept)


def remote_digest(reg, repo, tag):
    with call(reg, repo, "manifests/" + tag, "HEAD") as r:
        d = r.headers.get("Docker-Content-Digest")
    if d:
        return d
    with call(reg, repo, "manifests/" + tag) as r:
        return "sha256:" + hashlib.sha256(r.read()).hexdigest()


def remote_version(reg, repo, digest, arch):
    with call(reg, repo, "manifests/" + digest) as r:
        m = json.load(r)
    if "manifests" in m:
        c = [x for x in m["manifests"]
             if x.get("platform", {}).get("os") == "linux"
             and x.get("platform", {}).get("architecture") == arch]
        if not c:
            return ""
        with call(reg, repo, "manifests/" + c[0]["digest"]) as r:
            m = json.load(r)
    with call(reg, repo, "blobs/" + m["config"]["digest"], accept="*/*") as r:
        cfg = json.load(r)
    labels = (cfg.get("config") or {}).get("Labels") or {}
    return labels.get("org.opencontainers.image.version", "")


def main():
    ref, local, arch = sys.argv[1], sys.argv[2], sys.argv[3]
    have = set(re.findall(r"sha256:[0-9a-f]{64}", local))
    try:
        reg, repo, tag = parse(ref)
        d = remote_digest(reg, repo, tag)
    except Exception as e:
        print("err|%s" % type(e).__name__)
        return
    if d in have:
        print("ok|")
        return
    try:
        v = remote_version(reg, repo, d, arch)
    except Exception:
        v = ""
    print("upd|%s" % v.replace("|", " ").strip())


if __name__ == "__main__":
    main()
PY

case $(uname -m) in aarch64|arm64) ARCH=arm64 ;; *) ARCH=amd64 ;; esac
declare -A DOCKC=()

# docker_check <image> <local digests> – result "status|version" in $REPLY
docker_check() {
    local key="$1|$2"
    if [ -n "$REPLAY" ] && lk_get "dock|$key"; then return; fi
    if [ -z "${DOCKC[$key]+x}" ]; then
        DOCKC[$key]=$(timeout 90 python3 "$REG_PY" "$1" "$2" "$ARCH" 2>/dev/null | head -n1)
    fi
    REPLY=${DOCKC[$key]:-err|}
    lk_put "dock|$key" "$REPLY"
}

# tip_attr <key> – data-tip attribute with the tooltip tip_<key> (empty without a key)
tip_attr() {
    [ -n "$1" ] || return 0
    local t; t=$(esc "$(T "tip_$1")"); t=${t//$'\n'/"&#10;"}
    printf ' data-tip="%s"' "$t"
}
# why_div <key> – explanation txt_<key> with the tooltip tip_<key>
why_div() {
    printf '<div class="why"%s>%s</div>' "$(tip_attr "$1")" "$(esc "$(T "txt_$1")")"
}

ROWS=""
N_TOTAL=0; N_APPUPD=0; N_APPSYS=0; N_PKG=0; N_PKGSYS=0; N_SEC=0; N_ERR=0

# count_row <app updates> <packages> <security> <error 0/1> – add a row to the totals
count_row() {
    N_TOTAL=$((N_TOTAL + 1))
    if [ "$1" -gt 0 ]; then N_APPUPD=$((N_APPUPD + $1)); N_APPSYS=$((N_APPSYS + 1)); fi
    if [ "$2" -gt 0 ]; then N_PKG=$((N_PKG + $2)); N_PKGSYS=$((N_PKGSYS + 1)); N_SEC=$((N_SEC + $3)); fi
    N_ERR=$((N_ERR + $4))
}
# ------------------------------------------------------------------- Snapshots
# Containers whose volumes all lie on snapshot-capable storage get a snapshot button.
# Capable for containers: ZFS, LVM-thin, Ceph RBD and Btrfs. Bind mounts (mpX: /path)
# are not part of a snapshot and are ignored.
PVE_DIR="${PVE_DIR:-/etc/pve}"
SNAP_TYPES=" zfspool lvmthin rbd btrfs "
declare -A STORE_TYPE=()
if [ -r "$PVE_DIR/storage.cfg" ]; then
    while read -r st sn; do STORE_TYPE[$sn]=${st%:}; done \
        < <(grep -E '^[a-z]+:[[:space:]]+[A-Za-z0-9._-]+[[:space:]]*$' "$PVE_DIR/storage.cfg")
fi
# snap_info <id> – prints  1|<latest snapshot>|<its time>|<name:time,name:time,…>
#   or  0||  (not capable)
snap_info() {
    local conf="$PVE_DIR/lxc/$1.conf" line vol store ok=1 any=0 sec="" stime=0 best="" btime=0 all=""
    [ -r "$conf" ] || { echo "0||"; return; }
    while IFS= read -r line; do
        if [[ $line =~ ^\[([A-Za-z0-9_-]+)\]$ ]]; then sec=${BASH_REMATCH[1]}; continue; fi
        if [ -z "$sec" ] && [[ $line =~ ^(rootfs|mp[0-9]+):[[:space:]]*([^,]+) ]]; then
            vol=${BASH_REMATCH[2]}
            [[ $vol == /* ]] && continue          # bind mount
            store=${vol%%:*}; any=1
            [[ $SNAP_TYPES == *" ${STORE_TYPE[$store]:-none} "* ]] || ok=0
        elif [ -n "$sec" ] && [[ $line =~ ^snaptime:[[:space:]]*([0-9]+) ]]; then
            stime=${BASH_REMATCH[1]}; all+="${all:+,}$sec:$stime"
            [ "$stime" -gt "$btime" ] && { btime=$stime; best=$sec; }
        fi
    done < "$conf"
    [ "$any" = 1 ] && [ "$ok" = 1 ] || { echo "0||"; return; }
    echo "1|$best|$btime|$all"
}
SNAPI="0||"     # snapshot info of the row being built (set before add_row)

# do_snapop <delete|rollback> <id> <name> – deletes a snapshot or rolls the container
# back to it; result in SNAP_OK / SNAP_MSG. A running container is shut down for the
# rollback and started again afterwards (also when the rollback fails).
do_snapop() {
    local op=$1 id=$2 name=$3 out="" running=0
    P_PHASE=snapshot; P_ID=$id; write_status true "$GEN"
    echo "[$(date '+%F %T')] ${op^} of snapshot $name of container $id"
    if ! grep -qx "\[$name\]" "$PVE_DIR/lxc/$id.conf" 2>/dev/null; then
        SNAP_OK=0; SNAP_MSG="snapshot not found"
    elif [ "$op" = delete ]; then
        if out=$(timeout 600 pct delsnapshot "$id" "$name" 2>&1); then SNAP_OK=1; else SNAP_OK=0; fi
    else
        pct status "$id" 2>/dev/null | grep -q running && running=1
        if [ "$running" = 1 ]; then
            echo "  shutting down container $id"
            timeout 150 pct shutdown "$id" --timeout 120 >/dev/null 2>&1 || timeout 60 pct stop "$id" >/dev/null 2>&1
        fi
        if out=$(timeout 900 pct rollback "$id" "$name" 2>&1); then SNAP_OK=1; else SNAP_OK=0; fi
        if [ "$running" = 1 ]; then
            echo "  starting container $id"
            timeout 120 pct start "$id" >/dev/null 2>&1 || echo "  container $id could not be started"
        fi
    fi
    if [ "$SNAP_OK" = 0 ] && [ -z "$SNAP_MSG" ]; then
        SNAP_MSG=$(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -n1 | cut -c1-300)
        [ -n "$SNAP_MSG" ] || SNAP_MSG="pct $op failed"
    fi
    if [ "$SNAP_OK" = 1 ]; then echo "  done"; else echo "  failed: $SNAP_MSG"; fi
}

# do_snapshot <id> <name> – takes the snapshot; result in SNAP_OK / SNAP_MSG
do_snapshot() {
    local out
    P_PHASE=snapshot; P_ID=$1; write_status true "$GEN"
    echo "[$(date '+%F %T')] Snapshot $2 of container $1"
    if [ "$(snap_info "$1" | cut -d'|' -f1)" != 1 ]; then
        SNAP_OK=0; SNAP_MSG="storage does not support snapshots"
    elif out=$(timeout 600 pct snapshot "$1" "$2" --description "created by lxc-update-check" 2>&1); then
        SNAP_OK=1; SNAP_MSG=""
    else
        SNAP_OK=0; SNAP_MSG=$(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -n1 | cut -c1-300)
        [ -n "$SNAP_MSG" ] || SNAP_MSG="pct snapshot failed"
    fi
    if [ "$SNAP_OK" = 1 ]; then echo "  snapshot taken"; else echo "  snapshot failed: $SNAP_MSG"; fi
}

# cached_row <id> – rebuilds a row from the stored raw result, in the current
# language: for every row when only the pages are rewritten (--render), and for the
# other rows when a single container is re-checked (host = 0)
cached_row() {
    local f="$STATE/$1.raw" cid cname cstate
    [ -s "$f" ] || return 1
    [ -n "$RENDER" ] || { [ -n "$REFRESH_ID" ] && [ "$1" != "$REFRESH_ID" ]; } || return 1
    IFS='|' read -r cid cname cstate < "$f"
    [ "$cid" = "@host" ] && cid=$(T host_label)
    # Snapshot info is always read fresh: it is local and quick
    if [[ $1 =~ ^[1-9][0-9]*$ ]]; then SNAPI=$(snap_info "$1"); else SNAPI="0||"; fi
    REPLAY=1
    add_row "$cid" "$cname" "$cstate" "$(tail -n +2 "$f")"
    REPLAY=""
}

# add_row <id> <name> <running|stopped> <snippet output>
add_row() {
    local id=$1 name=$2 state=$3 out=$4
    local os="–" warn="" warndetail="" cs="" csbase="" aptapp="" pkgs=0 sec=0 list="" tag a b c d
    local -A ver=()
    local -a leg=() apps=() docks=() mans=()
    local rerr=0

    while IFS='|' read -r tag a b c d; do
        case $tag in
            OS)   os=$a; [ "$os" = "?" ] && os=$(T os_unknown) ;;
            WARN) warn=$(T "warn_$a"); warndetail=$b ;;
            CS)   cs=$a; csbase=$b ;;
            VER)  ver[$a]=$b ;;
            LEG)
                if [ -n "$b" ]; then
                    leg+=("$b"); a=$(printf '%s' "${a,,}" | tr -d ' ')
                    [ -n "${ver[$a]:-}" ] || ver[$a]=$b
                fi ;;
            APP)  apps+=("$a|$b|$c||") ;;
            DOCK) docks+=("$a|$b|$c|$d") ;;
            MAN)  mans+=("$a|$b|$c") ;;
            APT)  aptapp="$a|$b|${c:-$b}" ;;
            PKG)
                pkgs=$((pkgs + 1))
                local mark=""
                [ "$b" = NEW ] && b=$(T pkg_new)
                if [ "$d" = 1 ]; then sec=$((sec + 1)); mark="<span class=\"tag bad\">$(esc "$(T tag_security)")</span>"; fi
                list+="<tr><td>$(esc "$a")</td><td>$(esc "$b")</td><td>$(esc "$c")</td><td>$mark</td></tr>"
                ;;
        esac
    done <<< "$out"

    # --- community-scripts: read the version checks from the app's update script
    if [ -n "$cs" ]; then
        local script kind app repo pin key inst latest pinned var beta bflag
        cs_script "$cs" "$csbase"; script=$REPLY
        while IFS='|' read -r kind app repo pin; do
            [ -n "$app" ] || continue
            case $kind in
                gh_release) kind=gh ;;
                codeberg_release) kind=codeberg ;;
                gh_tag) kind=ghtag; pin="" ;;      # the third argument is a tag prefix here
            esac
            key=$(printf '%s' "${app,,}" | tr -d ' ')
            inst=${ver[$key]:-}
            if [ -z "$inst" ] && [ "${#leg[@]}" -eq 1 ]; then inst=${leg[0]}; fi

            # Some scripts pin a fixed, tested version (e.g. Immich)
            pinned=""; beta=""; bflag=""
            if [[ $pin =~ ^\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?$ ]]; then
                var=${BASH_REMATCH[1]}
                pin=$(grep -m1 -oE "^[[:space:]]*(local[[:space:]]+)?${var}=\"?[A-Za-z0-9._+-]+\"?[[:space:]]*$" "$script" \
                    | sed -E 's/^[^=]*=//; s/[" ]//g')
            fi
            if [ -n "$pin" ] && [[ $pin != *'$'* ]]; then
                latest=$pin; pinned=1
            else
                latest_release "$kind" "$repo"; latest=$REPLY; beta=$REPLY2; bflag=$REPLY3
            fi
            apps+=("$app|$inst|$latest|${pinned:+$(T hint_script_pinned)}||$beta|$bflag")
        done < <(cs_checks "$script")
    fi

    # --- Script without a version check, but the app is a system package: show the package version
    if [ -n "$cs" ] && [ "${#apps[@]}" -eq 0 ] && [ -n "$aptapp" ]; then
        apps+=("$aptapp|$(T hint_package)||")
    fi

    # --- App declared manually inside the container (/etc/lxc-update-check.conf)
    local entry mname mrepo mver
    for entry in "${mans[@]}"; do
        IFS='|' read -r mname mrepo mver <<< "$entry"
        latest_release gh "$mrepo"
        apps+=("$mname|${mver:-~no_manual_version}|$REPLY|||$REPLY2|$REPLY3")
    done

    # --- Docker containers inside the LXC: compare the image digest with the registry
    local dname dref ddig dver dtag shown st rver
    for entry in "${docks[@]}"; do
        IFS='|' read -r dname dref ddig dver <<< "$entry"
        [ "$dver" = "<no value>" ] && dver=""
        dtag=${dref%%@*}; dtag=${dtag##*/}
        if [[ $dtag == *:* ]]; then dtag=${dtag##*:}; else dtag=latest; fi
        # Without a version in the image the tag is shown ("#" = tag instead of version)
        if [ -n "$dver" ]; then shown=$dver; else shown="#$dtag"; fi
        if [[ $dref == *@sha256:* ]]; then
            apps+=("$dname|$shown|~docker_pinned|$(T hint_docker)|pin")
        elif [ -z "$ddig" ]; then
            apps+=("$dname|$shown|~docker_local|$(T hint_docker)|pin")
        else
            docker_check "$dref" "$ddig"
            IFS='|' read -r st rver <<< "$REPLY"
            case $st in
                ok)  apps+=("$dname|$shown|$shown|$(T hint_docker)|ok") ;;
                upd)
                    if [ -z "$rver" ] || [ "${rver#v}" = "${dver#v}" ]; then rver="+$(T new_image)"; fi
                    apps+=("$dname|$shown|$rver|$(T hint_docker)|upd") ;;
                *)   apps+=("$dname|$shown|~docker_noregistry|$(T hint_docker)|unk") ;;
            esac
        fi
    done

    # --- Build the app cells
    local c_app="" c_inst="" c_new="" app_upd=0 app_unk=0 aname ainst anew ahint astate abeta aflag newhtml betanote=""
    # Markers at the start of a value: "~key" = explanation instead of a version (txt_/tip_<key>),
    # "#" = Docker tag instead of a version, "+" = new image without a version
    local ikey nkey itip ntip icls snapver=""
    for entry in "${apps[@]}"; do
        IFS='|' read -r aname ainst anew ahint astate abeta aflag <<< "$entry"
        ikey=""; nkey=""; itip=""; ntip=""
        case $ainst in "~"*) ikey=${ainst:1}; ainst="" ;; "#"*) ainst=${ainst:1}; itip=docker_tag ;; esac
        case $anew  in "~"*) nkey=${anew:1};  anew=""  ;; "#"*) anew=${anew:1};  ntip=docker_tag ;; "+"*) anew=${anew:1}; ntip=new_image ;; esac
        [[ $ainst =~ ^v[0-9] ]] && ainst=${ainst:1}
        [[ $anew  =~ ^v[0-9] ]] && anew=${anew:1}
        [[ $abeta =~ ^v[0-9] ]] && abeta=${abeta:1}
        [ "$abeta" = "$anew" ] && abeta=""
        if [ -n "$abeta" ] && [ "$aflag" = 1 ] && [ "$ainst" != "$abeta" ]; then
            betanote=$(T note_beta_default app="$aname" v="$abeta")
        fi
        if [ -n "$abeta" ] && [ -n "$anew" ]; then
            # The latest version is a pre-release: also name the last stable one
            newhtml="$(esc "$abeta") <span class=\"tag upd mini\">$(esc "$(T tag_beta)")</span> <span class=\"hint\">$(esc "$(T hint_stable v="$anew")")</span>"
        else
            newhtml=$(esc "$anew")
        fi
        if [ -z "$astate" ]; then
            if [ -z "$ainst" ] || [ -z "$anew" ]; then astate=unk
            elif [ "$ainst" != "$anew" ] && [ "$ainst" != "$abeta" ]; then astate=upd
            else astate=ok; fi
        fi
        case $astate in
            ok)  icls=cur ;;
            upd) icls=old; app_upd=$((app_upd + 1)) ;;
            unk) icls=""; app_unk=$((app_unk + 1)) ;;
            *)   icls="" ;;
        esac
        c_app+="<div>$(esc "$aname")${ahint:+ <span class=\"hint\">$(esc "$ahint")</span>}</div>"
        # Both columns always hold a version or a short reason with a tooltip
        if [ -n "$ainst" ]; then
            # The first real version (not a Docker tag) names the proposed snapshot
            [ -z "$snapver" ] && [ -z "$itip" ] && snapver=$ainst
            c_inst+="<div${icls:+ class=\"$icls\"}$(tip_attr "$itip")>$(esc "$ainst")</div>"
        else
            c_inst+=$(why_div "${ikey:-no_file}")
        fi
        if [ -n "$anew" ]; then
            c_new+="<div class=\"new\"$(tip_attr "$ntip")>$newhtml</div>"
        else
            c_new+=$(why_div "${nkey:-no_release}")
        fi
    done
    if [ "${#apps[@]}" -eq 0 ]; then
        c_app="<div class=\"mute\">–</div>"
        if [ "$state" != running ] || [ -z "$out" ]; then
            ikey=not_checked; nkey=not_checked
        elif [ -n "$cs" ]; then
            c_app="<div>$(esc "$cs")</div>"
            if [ -s "$CACHE/$cs.sh" ]; then ikey=no_check; nkey=own_updater; else ikey=script_missing; nkey=script_missing; fi
        else
            ikey=no_app; nkey=no_app
        fi
        c_inst=$(why_div "$ikey"); c_new=$(why_div "$nkey")
    fi

    # --- Status of the row
    local cls label
    if [ "$state" != running ]; then
        cls=off;  label=$(T st_stopped); warn=$(T note_stopped)
    elif [ -z "$out" ]; then
        cls=warn; label=$(T st_noanswer); warn=$(T note_timeout sec="$TIMEOUT"); rerr=1
    elif [ "$app_upd" -gt 0 ]; then
        cls=upd;  label=$(T st_appupdate)
    elif [ -n "$cs" ] && [ "${#apps[@]}" -eq 0 ]; then
        cls=warn; label=$(T st_manual)
    elif [ "$app_unk" -gt 0 ]; then
        cls=warn; label=$(T st_unknown)
    elif [ "$sec" -gt 0 ]; then
        cls=bad;  label=$(T st_security)
    elif [ "$pkgs" -gt 0 ]; then
        cls=sys;  label=$(T st_sysupdates)
    elif [ -n "$warn" ] && [ "${#apps[@]}" -eq 0 ]; then
        # Neither apps nor packages could be checked. If apps were checked the status stays
        # "up to date"; the note about the package lists then sits below the container name.
        cls=warn; label=$(T st_uncheckable); rerr=1
    else
        cls=ok;   label=$(T st_ok)
    fi


    local c_pkg="<span class=\"mute\">–</span>" action="" note=""
    if [ "$state" = running ] && [ -n "$out" ]; then
        c_pkg=$pkgs
        [ "$sec" -gt 0 ] && c_pkg+=" <span class=\"tag bad\">$(esc "$(T tag_n_security n="$sec")")</span>"
    fi
    [ "$pkgs" -gt 0 ] && action="<button class=\"tgl\" aria-expanded=\"false\">$(esc "$(T btn_show)")</button>"
    # Arrow button: re-check this container only (running containers only, not the host)
    if [[ $id =~ ^[0-9]+$ ]] && [ "$state" = running ] && [ -n "$out" ]; then
        local hot=""; { [ "$app_upd" -gt 0 ] || [ "$pkgs" -gt 0 ]; } && hot=" hot"
        tag=$(esc "$(T btn_refresh_tip id="$id")")
        action+=" <button class=\"up$hot\" data-id=\"$id\" data-name=\"$(esc "$name")\" title=\"$tag\" aria-label=\"$tag\"><svg viewBox=\"0 0 24 24\" aria-hidden=\"true\"><path d=\"M12 19.5V5M5.5 11.5 12 5l6.5 6.5\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2.8\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/></svg></button>"
    fi
    # Camera button: take a snapshot (only if all volumes lie on snapshot-capable storage)
    local s_ok s_name s_time s_all snapbtns=""
    IFS='|' read -r s_ok s_name s_time s_all <<< "$SNAPI"
    if [[ $id =~ ^[0-9]+$ ]] && [ "$s_ok" = 1 ]; then
        tag=$(esc "$(T btn_snap_tip id="$id")")
        action+=" <button class=\"snap\" data-id=\"$id\" data-name=\"$(esc "$name")\" data-ver=\"$(esc "$snapver")\" data-snaps=\"$(esc "$s_all")\" title=\"$tag\" aria-label=\"$tag\"><svg viewBox=\"0 0 24 24\" aria-hidden=\"true\"><path d=\"M4 8h3l2-3h6l2 3h3v11H4z\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linejoin=\"round\"/><circle cx=\"12\" cy=\"13\" r=\"3.2\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\"/></svg></button>"
        local t2 t3 scount=0 badge=""
        # Number of existing snapshots as a small red badge on the list button
        [ -n "$s_all" ] && scount=$(( $(tr -cd ',' <<< "$s_all" | wc -c) + 1 ))
        [ "$scount" -gt 0 ] && badge="<span class=\"badge\" aria-hidden=\"true\">$scount</span>"
        t2=$(esc "$(T btn_snaplist_tip id="$id" n="$scount")"); t3=$(esc "$(T btn_snapinfo_tip id="$id")")
        action+=" <button class=\"snaplist\" data-id=\"$id\" data-name=\"$(esc "$name")\" data-snaps=\"$(esc "$s_all")\" title=\"$t2\" aria-label=\"$t2\"><svg viewBox=\"0 0 24 24\" aria-hidden=\"true\"><path d=\"M5 6h14M5 12h14M5 18h14\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\"/></svg>$badge</button>"
        action+=" <button class=\"snapinfo\" data-id=\"$id\" data-name=\"$(esc "$name")\" data-snaps=\"$(esc "$s_all")\" title=\"$t3\" aria-label=\"$t3\">i</button>"
        snapbtns=${action#*<button class=\"snap\"}; snapbtns="<button class=\"snap\"$snapbtns"
    fi
    if [ -n "$warn" ]; then
        # The original message (e.g. from apt) appears as a tooltip
        local wtip=""
        [ -n "$warndetail" ] && wtip=" data-tip=\"$(esc "$warndetail")\""
        note="<div class=\"note\"$wtip>$(esc "$warn")</div>"
    fi
    [ -n "$betanote" ] && note+="<div class=\"note\">$(esc "$betanote")</div>"
    if [ "$s_ok" = 1 ] && [ -n "$s_name" ]; then
        note+="<div class=\"note\">$(esc "$(T note_last_snap snap="$s_name" date="$(date -d "@$s_time" "+${L[date_format]}" 2>/dev/null)")")</div>"
    fi

    local sid=0; [[ $id =~ ^[0-9]+$ ]] && sid=$id
    # Classes and data-label drive the phone layout (compact list with details to open)
    local more="<button class=\"more\" aria-expanded=\"false\" aria-label=\"$(esc "$(T btn_details)")\" title=\"$(esc "$(T btn_details)")\">▾</button>"
    local rowhtml="<tr class=\"ct $cls\" data-id=\"$sid\" data-name=\"$(esc "$name")\"><td class=\"num c-id\" data-label=\"$(esc "$(T col_id)")\">$(esc "$id")</td><td class=\"c-name\"><strong>$(esc "$name")</strong><div class=\"note\">$(esc "$os")</div>$note</td><td class=\"c-app\" data-label=\"$(esc "$(T col_app)")\">$c_app</td><td class=\"v c-inst\">$c_inst</td><td class=\"v c-new\">$c_new</td><td class=\"c-status\" data-label=\"$(esc "$(T col_status)")\"><span class=\"tag $cls\">$(esc "$label")</span></td><td class=\"num c-pkg\" data-label=\"$(esc "$(T col_packages)")\">$c_pkg</td><td class=\"c-info\" data-label=\"$(esc "$(T col_system)")\"><div>$(esc "$os")</div>$note</td><td class=\"c-snaps\" data-label=\"$(esc "$(T col_snapshots)")\">${snapbtns:+<div>$snapbtns</div>}</td><td class=\"act c-act\"><div class=\"acts\">$more$action</div></td></tr>"
    if [ "$pkgs" -gt 0 ]; then
        rowhtml+="<tr class=\"detail\" hidden><td></td><td colspan=\"7\"><table class=\"pk\"><thead><tr><th>$(esc "$(T pk_package)")</th><th>$(esc "$(T pk_installed)")</th><th>$(esc "$(T pk_available)")</th><th></th></tr></thead><tbody>$list</tbody></table></td></tr>"
    fi
    count_row "$app_upd" "$pkgs" "$sec" "$rerr"
    ROWS+=$rowhtml
    # Keep the raw result (to rebuild the row later) and report it to the status window
    if [ -z "$REPLAY" ]; then
        local rid=$id; [ "$sid" = 0 ] && rid="@host"
        mkdir -p "$STATE" && printf '%s|%s|%s\n%s\n' "$rid" "$name" "$state" "$out" > "$STATE/$sid.raw"
        rm -f "$STATE/$sid.row"
        # Only containers that were actually checked appear in the status window;
        # rows rebuilt from stored results (other containers, --render) stay out of it
        P_LOG+="${P_LOG:+,}{\"name\":\"$(jesc "$name")\",\"id\":\"$(jesc "$id")\",\"label\":\"$(jesc "$label")\",\"cls\":\"$cls\"}"
    fi
}

# ------------------------------------------------------------------------- Scan
START=$(date +%s)
echo "[$(date '+%F %T')] Scan started"

if [ -n "$SNAP_ID" ]; then
    if [ "$SNAP_OP" = create ]; then do_snapshot "$SNAP_ID" "$SNAP_NAME"; else do_snapop "$SNAP_OP" "$SNAP_ID" "$SNAP_NAME"; fi
fi

mapfile -t CTS < <(pct list 2>/dev/null | awk 'NR > 1 { print $1 "|" $2 "|" $NF }')

# Number of steps for the progress display
if [ -n "$RENDER" ]; then
    P_TOTAL=0
elif [ -n "$REFRESH_ID" ]; then
    P_TOTAL=1
else
    [ "$INCLUDE_HOST" = 1 ] && P_TOTAL=1
    for line in "${CTS[@]}"; do
        case " $EXCLUDE " in *" ${line%%|*} "*) ;; *) P_TOTAL=$((P_TOTAL + 1)) ;; esac
    done
fi

if [ "$INCLUDE_HOST" = 1 ] && ! cached_row 0; then
    echo "  Host $(hostname)"
    progress "$(T host_label)" "$(hostname)"
    out=$(timeout "$TIMEOUT" sh -c "$SNIPPET" </dev/null 2>/dev/null)
    # There is no community-scripts app on the host itself
    out=$(grep -vE '^(CS|VER|LEG|APP|APT|DOCK|MAN)\|' <<< "$out")
    pv=$(dpkg-query -W -f='${Version}' pve-manager 2>/dev/null)
    pc=$(LC_ALL=C apt-cache policy pve-manager 2>/dev/null | awk '/Candidate:/ { print $2 }')
    [ -n "$pv" ] && out+=$'\n'"APP|Proxmox VE|$pv|${pc:-$pv}"
    SNAPI="0||"
    add_row "$(T host_label)" "$(hostname)" running "$out"
fi

for line in "${CTS[@]}"; do
    IFS='|' read -r id state name <<< "$line"
    case " $EXCLUDE " in *" $id "*) continue ;; esac
    cached_row "$id" && continue
    echo "  CT $id ($name): $state"
    progress "$id" "$name"
    out=""
    if [ "$state" = running ]; then
        out=$(timeout "$TIMEOUT" pct exec "$id" -- sh -c "$SNIPPET" </dev/null 2>/dev/null)
    fi
    SNAPI=$(snap_info "$id")
    add_row "$id" "$name" "$state" "$out"
done
P_PHASE=write; write_status true "$GEN"

DURATION=$(( $(date +%s) - START ))
GEN=$(date +%s)
if [ -n "$RENDER" ] && [ -f "$STATE/last-check" ]; then
    # Only the pages were rebuilt: show when the data was actually collected
    IFS='|' read -r lc_start lc_dur < "$STATE/last-check"
    STAMP=$(date -d "@$lc_start" "+${L[date_format]}"); DURATION=$lc_dur
else
    STAMP=$(date "+${L[date_format]}")
    [ -n "$RENDER" ] || { mkdir -p "$STATE" && printf '%s|%s\n' "$START" "$DURATION" > "$STATE/last-check"; }
fi

if [ "$N_APPUPD" -eq 0 ]; then
    HEADLINE=$(T headline_none)
elif [ "$N_APPUPD" -eq 1 ]; then
    HEADLINE=$(T headline_one)
else
    HEADLINE=$(T headline_many n="$N_APPUPD" c="$N_APPSYS")
fi
if [ "$N_PKG" -eq 0 ]; then
    SUMMARY=$(T summary_pkg_none)
elif [ "$N_SEC" -gt 0 ]; then
    SUMMARY=$(T summary_pkg_sec n="$N_PKG" s="$N_PKGSYS" t="$N_TOTAL" x="$N_SEC")
else
    SUMMARY=$(T summary_pkg_nosec n="$N_PKG" s="$N_PKGSYS" t="$N_TOTAL")
fi
[ "$N_ERR" -gt 0 ] && SUMMARY+=" $(T summary_err n="$N_ERR")"
META=$(T meta_checked date="$STAMP" host="$(hostname)" sec="$DURATION")
if [ "$CRON_ENABLED" != 1 ]; then
    META+=" $(T meta_off)"
elif [[ $CRON_SCHEDULE =~ ^([0-9]{1,2})\ ([0-9]{1,2})\ \*\ \*\ \*$ ]]; then
    META+=" $(T meta_next time="$(printf '%02d:%02d' "$((10#${BASH_REMATCH[2]}))" "$((10#${BASH_REMATCH[1]}))")")"
else
    META+=" $(T meta_sched cron="$CRON_SCHEDULE")"
fi

page_css() { cat <<'CSS'
:root {
  --bg: #edf0f3; --panel: #ffffff; --ink: #18222d; --mute: #5d6b7a; --line: #dde2e8;
  --accent: #0f6e8c;
  --ok: #1b7a43;  --ok-bg: #dff3e6;
  --upd: #0f6e8c; --upd-bg: #dcedf3;
  --warn: #99580a; --warn-bg: #fbecd0;
  --bad: #b3261e; --bad-bg: #fbe1df;
  --hover: #e6f1f5;
  --off: #5d6b7a; --off-bg: #e6e9ed;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #10161c; --panel: #18212a; --ink: #e4e9ee; --mute: #93a1b0; --line: #283440;
    --accent: #5cc0de;
    --ok: #6fd596;  --ok-bg: #173524;
    --upd: #5cc0de; --upd-bg: #12333f;
    --warn: #f0b860; --warn-bg: #3d2c0f;
    --bad: #ff8f87; --bad-bg: #45191a;
    --hover: #1f2d38;
    --off: #93a1b0; --off-bg: #232d37;
  }
}
* { box-sizing: border-box; }
body {
  margin: 0; padding: 2.5rem 1.25rem 3rem; background: var(--bg); color: var(--ink);
  font: 15px/1.5 "Inter", "Segoe UI", system-ui, -apple-system, "Helvetica Neue", sans-serif;
}
main { max-width: none; margin: 0; }
header { display: flex; gap: 1rem 2rem; align-items: flex-start; justify-content: space-between; margin-bottom: 1.75rem; }
/* The header of the report stays on one line; it only wraps on narrow screens */
header.top h1, header.top p { white-space: nowrap; }
@media (max-width: 800px) {
  header { flex-wrap: wrap; }
  header.top h1, header.top p { white-space: normal; }
}
.scanbox { display: flex; flex-direction: column; align-items: stretch; gap: .5rem; flex: none; }
.btn {
  display: block; font: inherit; font-weight: 600; text-align: center; text-decoration: none;
  color: var(--panel); background: var(--accent); border: 1px solid var(--accent);
  border-radius: 8px; padding: .6rem 1.2rem; cursor: pointer; white-space: nowrap;
}
.btn.ghost { color: var(--accent); background: none; border-color: var(--line); }
.btn:hover { filter: brightness(1.1); }
.btn.ghost:hover { border-color: var(--accent); filter: none; }
.btn:focus-visible { outline: 2px solid var(--accent); outline-offset: 3px; }
.btn:disabled { opacity: .6; cursor: progress; }
#scanmsg { font-size: .85rem; color: var(--bad); white-space: pre-line; max-width: 24rem; }
h1 { display: flex; align-items: center; gap: .65rem; margin: 0 0 1rem; font-size: clamp(1.6rem, 3.5vw, 2.1rem); line-height: 1.1; font-weight: 750; letter-spacing: -.025em; }
h1 .mark svg { width: 66%; height: 66%; }
h1 .mark {
  display: inline-flex; align-items: center; justify-content: center; flex: none;
  width: 1.25em; height: 1.25em; font-size: 1em; letter-spacing: 0;
  color: var(--panel); background: var(--accent); border-radius: 50%;
}
header p.headline { margin: 0 0 .2rem; font-size: 1.25rem; font-weight: 650; color: var(--ink); }
header p { margin: 0; color: var(--mute); }
header .meta { margin-top: .6rem; font-size: .87rem; }
.wrap { background: var(--panel); border: 1px solid var(--line); border-radius: 10px; overflow-x: auto; }
table { width: 100%; border-collapse: collapse; }
th, td { padding: .7rem 1rem; text-align: left; vertical-align: top; }
thead th { font-size: 1rem; font-weight: 650; color: var(--ink); border-bottom: 2px solid var(--line); white-space: nowrap; }
button.sort { font: inherit; color: inherit; background: none; border: 0; padding: 0; cursor: pointer; }
button.sort::after { content: "↕"; margin-left: .35rem; color: var(--mute); font-weight: 400; }
th[aria-sort="ascending"] button.sort::after { content: "↑"; color: var(--accent); }
th[aria-sort="descending"] button.sort::after { content: "↓"; color: var(--accent); }
button.sort:hover { color: var(--accent); }
button.sort:focus-visible { outline: 2px solid var(--accent); outline-offset: 3px; border-radius: 3px; }
table.pk thead th { font-size: .85rem; font-weight: 600; color: var(--mute); border-bottom-width: 1px; }
tr.ct > td { border-top: 1px solid var(--line); }
tr.ct:hover > td, tr.ct:hover + tr.detail > td { background: var(--hover); }
tbody tr.ct:first-child > td { border-top: 0; }
tr.ct > td:first-child { box-shadow: inset 4px 0 0 var(--stripe, transparent); }
tr.ok   { --stripe: var(--ok); }
tr.upd  { --stripe: var(--upd); }
tr.warn { --stripe: var(--warn); }
tr.bad  { --stripe: var(--bad); }
tr.sys  { --stripe: var(--off); }
tr.off  { --stripe: var(--line); color: var(--mute); }
.num { font-variant-numeric: tabular-nums; white-space: nowrap; }
td.num, th.num { text-align: right; }
tr.ct > td.num:first-child, thead th.num:first-child { text-align: left; }
td.v { font-variant-numeric: tabular-nums; white-space: nowrap; }
td.v .old { color: var(--bad); }
td.v .cur { color: var(--ok); }
td.v .new { color: var(--ok); font-weight: 700; }
.hint { font-weight: 400; font-size: .8rem; color: var(--mute); }
.mute { color: var(--mute); }
.why { color: var(--mute); font-size: .85rem; font-style: italic; }
[data-tip] { cursor: help; text-decoration: underline dotted; text-underline-offset: 3px; }
.tt {
  position: fixed; z-index: 1000; max-width: min(28rem, calc(100vw - 16px)); padding: .45rem .65rem;
  font-size: .82rem; line-height: 1.45; white-space: pre-line; overflow-wrap: anywhere; pointer-events: none;
  color: var(--panel); background: var(--ink); border-radius: 6px; box-shadow: 0 4px 14px rgba(0, 0, 0, .2);
}
.tt[hidden] { display: none; }
button.up {
  font: inherit; font-size: 1.35rem; font-weight: 700; line-height: 1; width: 2.2rem; height: 2.2rem; margin-left: .35rem; padding: 0;
  color: var(--accent); background: none; border: 1px solid var(--line); border-radius: 50%; cursor: pointer;
}
button.up.hot { color: var(--panel); background: var(--accent); border-color: var(--accent); }
/* Drawn arrow instead of the text character: same size and weight in every font */
button.up { display: inline-flex; align-items: center; justify-content: center; vertical-align: top; }
button.up svg { width: 1.45rem; height: 1.45rem; }
button.up:hover { border-color: var(--accent); }
button.up:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
button.up:disabled { opacity: .45; cursor: progress; }
button.snap {
  display: inline-flex; align-items: center; justify-content: center; vertical-align: top;
  width: 2.2rem; height: 2.2rem; margin-left: .35rem; padding: 0;
  color: var(--accent); background: none; border: 1px solid var(--line); border-radius: 50%; cursor: pointer;
}
button.snaplist, button.snapinfo {
  display: inline-flex; align-items: center; justify-content: center; vertical-align: top;
  width: 2.2rem; height: 2.2rem; margin-left: .35rem; padding: 0;
  font: inherit; font-weight: 700; font-family: Georgia, serif; font-size: 1.1rem;
  color: var(--accent); background: none; border: 1px solid var(--line); border-radius: 50%; cursor: pointer;
}
button.snaplist:hover, button.snapinfo:hover { border-color: var(--accent); }
button.snaplist:focus-visible, button.snapinfo:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
button.snap svg, button.snaplist svg { width: 1.15rem; height: 1.15rem; }
button.snaplist { position: relative; }
/* the badge sticks out of the button; the cell must not cut it off */
tr.ct > td > div.acts, tr.ct > td.c-snaps > div { overflow: visible; }
button.snaplist .badge {
  position: absolute; top: -.35rem; right: -.4rem; min-width: 1.05rem; height: 1.05rem; padding: 0 .25rem;
  font: 700 .66rem/1.05rem "Inter", "Segoe UI", system-ui, sans-serif; text-align: center;
  color: #fff; background: #c62828; border: 2px solid var(--panel); border-radius: 99px; box-sizing: content-box;
}
td.c-snaps { display: none; }
/* Buttons of the last column: every kind has its own slot, so they line up from row
   to row and a missing button leaves its space empty */
.acts { display: grid; grid-template-columns: minmax(auto, 1fr) repeat(4, 2.2rem); column-gap: .35rem; align-items: center; justify-items: center; }
tr.ct > td.c-act { max-width: none; }
.acts > button { margin-left: 0; grid-row: 1; }
.acts > button.tgl { grid-column: 1; justify-self: end; white-space: nowrap; }
.acts > button.up { grid-column: 2; }
.acts > button.snap { grid-column: 3; }
.acts > button.snaplist { grid-column: 4; }
.acts > button.snapinfo { grid-column: 5; }
dialog#snapdlg {
  width: min(42rem, calc(100vw - 2rem)); max-height: calc(100vh - 2rem); padding: 1.5rem; color: var(--ink); background: var(--panel);
  border: 1px solid var(--line); border-radius: 12px;
}
dialog#snapdlg::backdrop { background: rgba(10, 16, 22, .55); }
dialog#snapdlg h2 { margin: 0 0 1rem; font-size: 1.15rem; }
dialog#snapdlg h3 { margin: 1.1rem 0 .3rem; font-size: 1rem; }
dialog#snapdlg p { margin: 0 0 .6rem; }
dialog#snapdlg .small { font-size: .85rem; margin-top: .8rem; }
dialog#snapdlg table.snaps { width: 100%; }
dialog#snapdlg td.snapacts { text-align: right; white-space: nowrap; font-family: inherit; }
dialog#snapdlg td.snapacts button { margin-left: .35rem; }
button.tgl.danger { color: var(--bad); }
button.tgl.danger:hover { border-color: var(--bad); }
dialog#snapdlg label.pick { display: flex; gap: .5rem; align-items: center; flex-wrap: wrap; margin: .3rem 0 .4rem; font-weight: 600; }
dialog#snapdlg select { font: inherit; color: var(--ink); background: var(--bg); border: 1px solid var(--line); border-radius: 6px; padding: .3rem .5rem; max-width: 100%; }
.cmd1 { display: flex; gap: .6rem; align-items: center; margin: .35rem 0; }
.cmd1 code {
  flex: 1 1 auto; min-width: 0; padding: .4rem .7rem; overflow-x: auto; white-space: nowrap; background: var(--bg); border-radius: 6px;
  font-family: ui-monospace, "SF Mono", "Cascadia Mono", Menlo, Consolas, monospace; font-size: .9rem;
}
.cmd1 button.copy { flex: none; min-width: 6.5rem; }
.dlgfoot { margin-top: 1.2rem; display: flex; justify-content: flex-end; }
/* The buttons stay visible at the right edge even when the table is wider than the window */
@media (min-width: 701px) {
  #ct td.c-act, #ct thead th:last-child { position: sticky; right: 0; background: var(--panel); box-shadow: -8px 0 8px -8px rgba(0, 0, 0, .25); }
  #ct tr.ct:hover > td.c-act { background: var(--hover); }
}
button.snap:hover { border-color: var(--accent); }
button.snap:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
button.snap:disabled { opacity: .45; cursor: progress; }
table.cfg input[type="text"], table.cfg input[type="number"], table.cfg input[type="password"], table.cfg input[type="time"], table.cfg select {
  font: inherit; width: 100%; color: var(--ink); background: var(--bg);
  border: 1px solid var(--line); border-radius: 6px; padding: .4rem .6rem;
}
table.cfg input:focus-visible, table.cfg select:focus-visible { outline: 2px solid var(--accent); outline-offset: 1px; }
table.cfg input[type="checkbox"] { width: 1.15rem; height: 1.15rem; accent-color: var(--accent); }
table.cfg label.sub { display: flex; align-items: center; gap: .45rem; margin-top: .45rem; font-size: .85rem; color: var(--mute); }
table.cfg div.sub { display: flex; flex-wrap: wrap; gap: .2rem 1.2rem; margin-top: .45rem; font-size: .85rem; color: var(--mute); }
table.cfg div.sub a { color: var(--accent); }
table.cfg input.mono { font-family: ui-monospace, "SF Mono", "Cascadia Mono", Menlo, Consolas, monospace; }
.savebar { margin-top: 1rem; display: flex; }
.waitbox {
  display: flex; gap: .9rem; align-items: flex-start; margin: 1rem 0 0; padding: .8rem 1rem; max-width: 90ch;
  background: var(--upd-bg); border-left: 4px solid var(--accent); border-radius: 6px;
}
.waitbox[hidden] { display: none; }
.waitbox.top, .okbox.top, .errbox.top { margin: 0 0 1.25rem; }
.waitbox p { margin: 0; }
#cfgwaitprog { margin-top: .3rem; font-weight: 600; }
.spin {
  flex: none; width: 1.1rem; height: 1.1rem; margin-top: .15rem;
  border: 2px solid var(--line); border-top-color: var(--accent); border-radius: 50%;
  animation: spin 1s linear infinite;
}
@keyframes spin { to { transform: rotate(360deg); } }
@media (prefers-reduced-motion: reduce) { .spin { animation-duration: 3s; } }
table.cfg input:disabled, table.cfg select:disabled { opacity: .55; }
.okbox {
  margin: 1rem 0 0; padding: .8rem 1rem; max-width: 90ch;
  color: var(--ink); background: var(--ok-bg); border-left: 4px solid var(--ok); border-radius: 6px;
}
#scan[aria-busy="true"]::after { content: " ▸"; }
.errbox {
  margin: 1rem 0 0; padding: .8rem 1rem; white-space: pre-line; max-width: 90ch;
  color: var(--ink); background: var(--bad-bg); border-left: 4px solid var(--bad); border-radius: 6px;
}
.act { text-align: right; white-space: nowrap; }
.note { font-size: .85rem; color: var(--mute); }
/* Columns at most 250 px wide; longer text is cut and shown in a tooltip */
tr.ct > td { max-width: 250px; }
tr.ct > td > div, tr.ct > td > strong, table.pk td {
  overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
}
tr.ct > td > strong { display: block; }
table.pk td { max-width: 250px; }
.tag { display: inline-block; padding: .1rem .6rem; border-radius: 99px; font-size: .82rem; font-weight: 600; white-space: nowrap; }
.tag.ok   { color: var(--ok);   background: var(--ok-bg); }
.tag.upd  { color: var(--upd);  background: var(--upd-bg); }
.tag.warn { color: var(--warn); background: var(--warn-bg); }
.tag.bad  { color: var(--bad);  background: var(--bad-bg); }
.tag.sys, .tag.off { color: var(--off); background: var(--off-bg); }
button.tgl {
  font: inherit; font-size: .85rem; color: var(--accent); background: none;
  border: 1px solid var(--line); border-radius: 6px; padding: .2rem .65rem; cursor: pointer;
}
button.tgl:hover { border-color: var(--accent); }
button.tgl:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
tr.detail > td { padding-top: 0; padding-bottom: 1rem; }
table.pk { font-size: .87rem; background: var(--bg); border-radius: 8px; }
table.pk th, table.pk td { padding: .35rem .8rem; }
table.pk thead th { border-bottom: 1px solid var(--line); }
table.pk td { font-family: ui-monospace, "SF Mono", "Cascadia Mono", Menlo, Consolas, monospace; font-size: .82rem; }
table.pk td:last-child { text-align: right; font-family: inherit; }
.tag.mini { font-size: .72rem; padding: 0 .45rem; }
dialog#prog {
  width: min(34rem, calc(100vw - 2rem)); padding: 1.5rem; color: var(--ink); background: var(--panel);
  border: 1px solid var(--line); border-radius: 12px;
}
dialog#prog::backdrop { background: rgba(10, 16, 22, .55); }
dialog#prog h2 { margin: 0 0 1rem; }
.bar { height: .6rem; background: var(--bg); border-radius: 99px; overflow: hidden; }
.bar > div { height: 100%; width: 0; background: var(--accent); border-radius: 99px; transition: width .4s; }
@media (prefers-reduced-motion: reduce) { .bar > div { transition: none; } }
#progcur { margin: .7rem 0; font-weight: 600; }
#proglog { list-style: none; margin: 0 0 1rem; padding: 0; max-height: 15rem; overflow-y: auto; font-size: .9rem; }
#proglog li { display: flex; justify-content: space-between; align-items: center; gap: 1rem; padding: .3rem 0; border-top: 1px solid var(--line); }
dialog#prog .errbox { margin: 0 0 1rem; }
h2 { margin: 2rem 0 .75rem; font-size: 1.2rem; font-weight: 650; }
/* Fixed column widths so that both tables of the settings page line up:
   column 2 of the file table starts where column 3 of the settings table starts */
table.cfg { table-layout: fixed; min-width: 62rem; }
table.cfg col.c1 { width: 12rem; }
table.cfg col.c2 { width: 26rem; }
table.cfg col.c12 { width: 38rem; }
table.cfg td { border-top: 1px solid var(--line); }
table.cfg tbody tr:first-child td { border-top: 0; }
table.cfg code { font-family: ui-monospace, "SF Mono", "Cascadia Mono", Menlo, Consolas, monospace; font-size: .88rem; word-break: break-all; }
table.cfg td:first-child { white-space: nowrap; }
p.howto { margin: 1rem 0 0; color: var(--mute); white-space: nowrap; overflow-x: auto; }
/* Help page */
.oschoice { display: flex; flex-wrap: wrap; gap: .4rem; align-items: center; margin-bottom: 1.25rem; }
.oschoice span { margin-right: .35rem; color: var(--mute); }
.oschoice button[aria-pressed="true"] { color: var(--panel); background: var(--accent); border-color: var(--accent); }
.step { background: var(--panel); border: 1px solid var(--line); border-radius: 10px; padding: 1rem 1.25rem .6rem; margin-bottom: 1rem; }
.step h2 { display: flex; flex-wrap: wrap; align-items: center; gap: .6rem; margin: 0 0 .35rem; }
.step > p { margin: 0 0 .8rem; color: var(--mute); }
.cmd { display: grid; grid-template-columns: 17rem minmax(0, 1fr) auto; gap: .75rem; align-items: center; padding: .45rem 0; border-top: 1px solid var(--line); }
.cmd[hidden] { display: none; }
.cmd .os { font-weight: 600; }
.cmd code {
  padding: .4rem .7rem; overflow-x: auto; white-space: nowrap; background: var(--bg); border-radius: 6px;
  font-family: ui-monospace, "SF Mono", "Cascadia Mono", Menlo, Consolas, monospace; font-size: .9rem;
}
.cmd .nocmd { grid-column: 2 / 4; color: var(--mute); font-size: .9rem; }
button.copy { min-width: 6.5rem; }
p.scope { color: var(--mute); }
@media (max-width: 700px) {
  .cmd { grid-template-columns: minmax(0, 1fr) auto; }
  .cmd .os, .cmd .nocmd { grid-column: 1 / 3; }
}
@media (max-width: 800px) { p.howto { white-space: normal; } }
/* Phones: a compact list with container, installed and latest version and the
   arrow button; everything else opens with the details button (▾) */
.mhead, button.more, td.c-info { display: none; }
@media (max-width: 700px) {
  body { font-size: 13.5px; padding: 1.25rem .75rem 2rem; }
  header { gap: .75rem; margin-bottom: 1.25rem; }
  header > div:first-child { flex: 1 1 100%; min-width: 0; }
  header p, .note, .why { overflow-wrap: anywhere; }
  .scanbox { flex: 1 1 100%; flex-direction: row; flex-wrap: wrap; }
  .scanbox .btn { flex: 1 1 auto; padding: .5rem .8rem; }
  #scanmsg { flex-basis: 100%; max-width: none; }
  .wrap { overflow: hidden; }
  #ct, #ct > tbody { display: block; width: 100%; }
  #ct > thead { display: none; }
  .mhead, tr.ct {
    display: grid; grid-template-columns: minmax(0, 1.4fr) minmax(0, 1fr) minmax(0, 1fr) auto;
    gap: .15rem .6rem; align-items: start;
  }
  .mhead { padding: .5rem .7rem .5rem .85rem; font-size: .8rem; font-weight: 600; color: var(--mute); border-bottom: 3px solid var(--line); }
  tr.ct { padding: .55rem .7rem .55rem .85rem; border-top: 1px solid var(--line); box-shadow: inset 4px 0 0 var(--stripe, transparent); }
  tbody tr.ct:first-child { border-top: 0; }
  tr.ct:hover > td, tr.ct:hover + tr.detail > td { background: none; }
  tr.ct > td { display: none; padding: 0; border: 0; max-width: none; box-shadow: none !important; order: 10; }
  tr.ct > td.c-name { display: block; order: 1; }
  tr.ct > td.c-inst { display: block; order: 2; }
  tr.ct > td.c-new { display: block; order: 3; }
  tr.ct > td.c-act { display: flex; gap: .3rem; align-items: center; order: 4; }
  tr.ct > td > div, tr.ct > td > strong { white-space: normal; overflow-wrap: anywhere; }
  tr.ct > td.c-name .note { display: none; }
  /* closed rows keep each version on one line; the full text shows when opened */
  tr.ct:not(.open) > td.v > div { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  /* opened: the remaining cells as label/value lines across the full width */
  tr.ct.open > td.c-id, tr.ct.open > td.c-app, tr.ct.open > td.c-status, tr.ct.open > td.c-pkg, tr.ct.open > td.c-info {
    display: grid; grid-template-columns: 7.5rem minmax(0, 1fr); column-gap: .6rem;
    grid-column: 1 / -1; padding-top: .3rem; text-align: left;
  }
  tr.ct.open > td[data-label]::before { content: attr(data-label); grid-row: 1 / span 20; color: var(--mute); font-weight: 600; }
  tr.ct.open > td[data-label] > * { justify-self: start; }
  tr.ct.open > td.c-info .note { display: block; }
  tr.ct > td.c-act button.tgl, tr.ct > td.c-act button.snap, tr.ct > td.c-act button.snaplist, tr.ct > td.c-act button.snapinfo { display: none; }
  tr.ct.open > td.c-snaps:not(:empty) { display: grid; grid-template-columns: 7.5rem minmax(0, 1fr); column-gap: .6rem; grid-column: 1 / -1; padding-top: .3rem; }
  tr.ct.open > td.c-snaps button:first-child { margin-left: 0; }
  .acts { grid-template-columns: repeat(2, 2rem); column-gap: .3rem; }
  .acts > button.more { grid-column: 1; grid-row: 1; }
  .acts > button.up { grid-column: 2; }
  dialog#snapdlg { padding: 1.1rem; }
  .cmd1 { gap: .4rem; }
  .cmd1 code { font-size: .8rem; padding: .4rem .5rem; }
  .cmd1 button.copy { min-width: 0; padding: .2rem .5rem; }
  button.more {
    display: inline-flex; align-items: center; justify-content: center; padding: 0;
    width: 2rem; height: 2rem; font: inherit; font-size: 1rem; line-height: 1;
    color: var(--accent); background: none; border: 1px solid var(--line); border-radius: 50%; cursor: pointer;
  }
  button.more:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
  tr.ct.open button.more { transform: rotate(180deg); }
  button.up, button.snap { margin-left: 0; width: 2rem; height: 2rem; font-size: 1.15rem; }
  button.up svg { width: 1.3rem; height: 1.3rem; }
  tr.detail { display: none; }
  tr.ct.open + tr.detail { display: block; }
  tr.detail > td { display: none; }
  tr.detail > td:last-child { display: block; padding: 0 .7rem .7rem .85rem; }
  table.pk { width: 100%; table-layout: fixed; }
  table.pk th, table.pk td { max-width: none; white-space: normal; overflow-wrap: anywhere; padding: .3rem .5rem; }
  table.pk th:last-child, table.pk td:last-child { width: 6.5rem; padding-left: 0; }
  /* settings page: one block per setting instead of three columns */
  table.cfg { min-width: 0; table-layout: auto; }
  table.cfg colgroup, table.cfg thead { display: none; }
  table.cfg, table.cfg tbody, table.cfg tr, table.cfg td { display: block; width: auto; }
  table.cfg tr { padding: .6rem .8rem; border-top: 1px solid var(--line); }
  table.cfg tbody tr:first-child { border-top: 0; }
  table.cfg td, table.cfg tbody tr:first-child td { border: 0; padding: .15rem 0; }
  table.cfg td:last-child { color: var(--mute); }
  table.cfg code { word-break: break-all; }
  .doc pre, .cmd code { max-width: 100%; }
}
/* Report: the part above the table stays in place; only the table scrolls, and its
   column headings stay visible at the top of it */
body.report { display: flex; flex-direction: column; height: 100vh; height: 100dvh; overflow: hidden; box-sizing: border-box; }
body.report > main { flex: 1 1 auto; min-height: 0; display: flex; flex-direction: column; }
body.report header, body.report #snapres { flex: none; }
body.report .wrap { flex: 1 1 auto; min-height: 0; overflow: auto; overscroll-behavior: contain; }
body.report #ct thead th { position: sticky; top: 0; z-index: 2; background: var(--panel); border-bottom: 0; box-shadow: inset 0 -3px 0 var(--line); }
body.report #ct thead th:last-child { box-shadow: inset 0 -3px 0 var(--line), -8px 0 8px -8px rgba(0, 0, 0, .25); }
body.report #ct thead th:last-child { z-index: 3; }
body.report .mhead { position: sticky; top: 0; z-index: 2; background: var(--panel); }
/* Very low windows (e.g. a phone held sideways): normal page scrolling instead */
@media (max-height: 520px) {
  body.report { display: block; height: auto; overflow: visible; }
  body.report > main { display: block; }
  body.report .wrap { overflow: visible; overflow-x: auto; }
}
CSS
}

# page_head <title> – shared page head for report, settings and help page
page_head() {
cat <<HTML
<!DOCTYPE html>
<html lang="$(esc "${L[lang_code]}")">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>$(esc "$1")</title>
<link rel="icon" type="image/svg+xml" href="favicon.svg">
<link rel="alternate icon" href="favicon.ico">
<style>
HTML
page_css
cat <<'HTML'
</style>
</head>
HTML
}

# dattr <name> <key> [placeholder=value …] – text as a data attribute for the JavaScript
dattr() {
    local n=$1 k=$2 t; shift 2
    t=$(esc "$(T "$k" "$@")"); t=${t//$'\n'/"&#10;"}
    printf ' data-%s="%s"' "$n" "$t"
}
# Attributes both pages need for jobs sent to the web server
body_attrs() {
    printf ' data-gen="%s" data-lang="%s"' "$GEN" "$(esc "${L[lang_code]}")"
    dattr pw-prompt      pw_prompt      pwfile="$PWFILE"
    dattr err-server     err_server     file="$CONFIG"
    dattr err-oldserver  err_oldserver
    dattr err-password   err_password   pwfile="$PWFILE"
    dattr err-nopassword err_nopassword pwfile="$PWFILE" file="$CONFIG"
    dattr err-pwneeded   err_pwneeded   pwfile="$PWFILE"
    dattr err-busy       err_busy
    dattr err-invalid    err_invalid
    dattr err-nostart    err_nostart    file="$CONFIG"
}

# Own tooltips instead of the browser's: placed beside the mouse pointer so that the
# pointer never covers them, and flipped to the other side when they would leave the
# window. Sources: title attributes, data-tip, and text cut off in a table cell.
tt_js() { cat <<'JS'
(function () {
  var TRUNC = 'tr.ct > td > div, tr.ct > td > strong, table.pk td';
  var GAP_X = 16, GAP_Y = 24, EDGE = 8, DELAY = 250;
  var tip = document.createElement('div'), cur = null, timer = null, mx = 0, my = 0;
  tip.className = 'tt'; tip.setAttribute('role', 'tooltip'); tip.hidden = true;
  document.body.appendChild(tip);
  // Browser tooltips would appear in addition, so their text moves to data-tt
  function adopt(root) {
    (root || document).querySelectorAll('[title]').forEach(function (e) {
      if (!e.dataset.tt) { e.dataset.tt = e.getAttribute('title'); }
      e.removeAttribute('title');
    });
  }
  adopt();
  new MutationObserver(function (ms) {
    ms.forEach(function (m) { m.addedNodes.forEach(function (n) { if (n.nodeType === 1) { if (n.hasAttribute('title')) { adopt(n.parentNode); } else { adopt(n); } } }); });
  }).observe(document.body, { childList: true, subtree: true });
  function textFor(t) {
    var e = t.closest('[data-tt]');
    if (e) { return [e, e.dataset.tt]; }
    e = t.closest('[data-tip]');
    if (e && e.dataset.tip) { return [e, e.dataset.tip]; }
    e = t.closest(TRUNC);
    if (e && e.scrollWidth > e.clientWidth + 1) { return [e, e.textContent.trim()]; }
    return [null, ''];
  }
  function place() {
    var w = tip.offsetWidth, h = tip.offsetHeight, vw = document.documentElement.clientWidth, vh = window.innerHeight;
    var x = mx + GAP_X, y = my + GAP_Y;                 // below right of the pointer tip
    if (x + w > vw - EDGE) { x = mx - GAP_X - w; }      // no room on the right: to the left
    if (y + h > vh - EDGE) { y = my - GAP_Y / 2 - h; }  // no room below: above
    tip.style.left = Math.max(EDGE, x) + 'px';
    tip.style.top = Math.max(EDGE, y) + 'px';
  }
  function hide() { clearTimeout(timer); cur = null; tip.hidden = true; }
  function show(el, text) {
    var host = el.closest('dialog[open]') || document.body;   // dialogs lie above the page
    if (tip.parentNode !== host) { host.appendChild(tip); }
    tip.textContent = text; tip.hidden = false; place();
  }
  document.addEventListener('mouseover', function (e) {
    if (!e.target.closest) { return; }
    var r = textFor(e.target);
    if (r[0] === cur) { return; }
    hide();
    if (!r[0] || !r[1]) { return; }
    cur = r[0];
    timer = setTimeout(function () { if (cur === r[0]) { show(r[0], r[1]); } }, DELAY);
  });
  document.addEventListener('mousemove', function (e) { mx = e.clientX; my = e.clientY; if (!tip.hidden) { place(); } });
  document.addEventListener('mouseout', function (e) { if (cur && !cur.contains(e.relatedTarget)) { hide(); } });
  ['mousedown', 'scroll', 'keydown'].forEach(function (ev) { document.addEventListener(ev, hide, true); });
  // Keyboard: show the tooltip of the focused element beside it
  document.addEventListener('focusin', function (e) {
    var r = textFor(e.target);
    if (!r[0] || !r[1] || !e.target.matches(':focus-visible')) { return; }
    var b = r[0].getBoundingClientRect(); mx = b.left; my = b.bottom - GAP_Y + 6; cur = r[0]; show(r[0], r[1]);
  });
  document.addEventListener('focusout', hide);
})();
JS
}

# Shared JavaScript: send a job to the web server and wait for the result
page_js() { cat <<'JS'
var B = document.body.dataset;
var pageGen = parseInt(B.gen, 10) || 0, timer = null, since = 0, onWaitFail = function () {}, onProgress = null;
function storedPw() { try { return sessionStorage.getItem('lxc-pw') || ''; } catch (e) { return ''; } }
function keepPw(p) { try { sessionStorage.setItem('lxc-pw', p); } catch (e) {} }
function forgetPw() { try { sessionStorage.removeItem('lxc-pw'); } catch (e) {} }
// Waits until a newer report exists, then reloads the page
function poll() {
  fetch('status.json?' + Date.now(), { cache: 'no-store' })
    .then(function (r) { return r.json(); })
    .then(function (s) {
      if (s.generated > pageGen) { location.reload(); return; }
      if (s.running && onProgress) { onProgress(s); }
      if (!s.running && Date.now() - since > 20000) { stopWait(B.errNostart); }
    })
    .catch(function () { if (Date.now() - since > 20000) { stopWait(B.errNostart); } });
}
function startWait(fail) { onWaitFail = fail; since = Date.now(); if (!timer) { timer = setInterval(poll, 1000); } }
function stopWait(text) { clearInterval(timer); timer = null; onWaitFail(text); }
// Sends a job; if it fails the promise yields the explanation with a suggested fix
function send(url, body, needPw) {
  var headers = {}, p = '';
  if (needPw) {
    p = storedPw() || window.prompt(B.pwPrompt) || '';
    if (!p) { return Promise.reject(B.errPwneeded); }
    headers['X-Password'] = p;
  }
  return fetch(url, { method: 'POST', headers: headers, body: body }).then(function (r) {
    return r.json().catch(function () { return {}; }).then(function (d) {
      if (r.status === 202) { if (needPw) { keepPw(p); } return; }
      if (r.status === 401) { forgetPw(); throw B.errPassword; }
      if (r.status === 403) { throw B.errNopassword; }
      if (r.status === 409) { throw B.errBusy; }
      if (r.status === 400) { throw B.errInvalid.replace('{field}', d.field || '?'); }
      throw B.errOldserver;
    });
  }, function () { throw B.errServer; });
}
JS
}

# cfg_row <name> <value> <explanation> – setting that can only be changed in the file
cfg_row() {
    printf '<tr><td><code>%s</code></td><td><code>%s</code> <span class="hint">%s</span></td><td>%s</td></tr>\n' \
        "$(esc "$1")" "$(esc "${2:-$(T cfg_empty)}")" "$(esc "$(T cfg_readonly)")" "$(esc "$3")"
}
# cfg_input <name> <html of the input field> <explanation>
cfg_input() {
    printf '<tr><td><code>%s</code></td><td>%s</td><td>%s</td></tr>\n' "$(esc "$1")" "$2" "$(esc "$3")"
}
checked() { [ "$1" = 1 ] && printf ' checked'; return 0; }

# ---------------------------------------------------- Write the "Settings" page
mkdir -p "$OUT_DIR"
TMP=$(mktemp "$OUT_DIR/.config.XXXXXX")
{
page_head "$(T cfg_title) – $(T app_title)"
cat <<HTML
<body$(body_attrs)$(dattr save cfg_save)$(dattr saving cfg_saving)$(dattr saved cfg_saved)$(dattr applying cfg_applying)$(dattr busy cfg_busy)$(dattr prog-starting prog_starting)$(dattr prog-step prog_step)$(dattr prog-finishing prog_finishing)>
<main>
<header>
  <div>
    <h1><span class="mark" aria-hidden="true"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 19.5V5M5.5 11.5 12 5l6.5 6.5" fill="none" stroke="currentColor" stroke-width="2.8" stroke-linecap="round" stroke-linejoin="round"/></svg></span>$(esc "$(T app_title)")</h1>
    <p class="headline">$(esc "$(T cfg_title)")</p>
    <p>$(esc "$(T cfg_intro dir="$ETC")")</p>
  </div>
  <div class="scanbox">
    <a class="btn" href="./">$(esc "$(T btn_back)")</a>
    <a class="btn ghost" href="help.html">$(esc "$(T btn_help)")</a>
  </div>
</header>
<div id="cfgwait" class="waitbox top" role="status" hidden><span class="spin" aria-hidden="true"></span><div><p id="cfgwaittext"></p><p id="cfgwaitprog"></p></div></div>
<p id="cfgok" class="okbox top" role="status" hidden></p>
<h2>$(esc "$(T cfg_settings_title)")</h2>
<div class="wrap">
<table class="cfg">
<colgroup><col class="c1"><col class="c2"><col></colgroup>
<thead><tr><th>$(esc "$(T cfg_col_setting)")</th><th>$(esc "$(T cfg_col_value)")</th><th>$(esc "$(T cfg_col_desc)")</th></tr></thead>
<tbody>
HTML
cfg_row OUT_DIR "$OUT_DIR" "$(T cfg_OUT_DIR)"
cfg_row PORT    "$PORT"    "$(T cfg_PORT)"
cfg_input INCLUDE_HOST "<input id=\"f_INCLUDE_HOST\" type=\"checkbox\"$(checked "$INCLUDE_HOST")>" "$(T cfg_INCLUDE_HOST)"
cfg_input TIMEOUT "<input id=\"f_TIMEOUT\" type=\"number\" min=\"1\" max=\"99999\" value=\"$(esc "$TIMEOUT")\">" "$(T cfg_TIMEOUT)"
cfg_input EXCLUDE "<input id=\"f_EXCLUDE\" type=\"text\" inputmode=\"numeric\" value=\"$(esc "$EXCLUDE")\">" "$(T cfg_EXCLUDE)"
opts=""
for lf in "$ETC"/lang/*.lang; do
    [ -f "$lf" ] || continue
    sel=""; [ "$lf" = "$LANG_FILE" ] && sel=" selected"
    opts+="<option value=\"$(esc "$lf")\"$sel>$(esc "${lf##*/}")</option>"
done
[ -n "$opts" ] || opts="<option value=\"$(esc "$LANG_FILE")\" selected>$(esc "${LANG_FILE##*/}")</option>"
cfg_input LANG_FILE "<select id=\"f_LANG_FILE\">$opts</select>" "$(T cfg_LANG_FILE)"
# The token itself is never shown
if [ -n "$GITHUB_TOKEN" ]; then tok=$(T cfg_token_set); else tok=$(T cfg_token_unset); fi
cfg_input GITHUB_TOKEN "<input id=\"f_GITHUB_TOKEN\" type=\"password\" autocomplete=\"off\" placeholder=\"$(esc "$tok, $(T cfg_token_keep)")\"><label class=\"sub\"><input id=\"f_TOKEN_REMOVE\" type=\"checkbox\">$(esc "$(T cfg_token_remove)")</label>" "$(T cfg_GITHUB_TOKEN)"
cfg_input CRON_ENABLED "<input id=\"f_CRON_ENABLED\" type=\"checkbox\"$(checked "$CRON_ENABLED")>" "$(T cfg_CRON_ENABLED)"
crontip=$(esc "$(T tip_cron_examples)"); crontip=${crontip//$'\n'/"&#10;"}
cfg_input CRON_SCHEDULE "<input id=\"f_CRON_SCHEDULE\" type=\"text\" class=\"mono\" spellcheck=\"false\" autocomplete=\"off\" title=\"$crontip\" value=\"$(esc "$CRON_SCHEDULE")\"><div class=\"sub\"><span data-tip tabindex=\"0\" title=\"$crontip\">$(esc "$(T cron_examples)")</span><a id=\"cronguru\" href=\"https://crontab.guru/\" target=\"_blank\" rel=\"noopener\">$(esc "$(T cron_guru)")</a></div>" "$(T cfg_CRON_SCHEDULE)"
cat <<HTML
</tbody>
</table>
</div>
<div class="savebar"><button id="save" class="btn">$(esc "$(T cfg_save)")</button></div>
<p id="cfgmsg" class="errbox" role="alert" hidden></p>
<h2>$(esc "$(T cfg_files_title)")</h2>
<div class="wrap">
<table class="cfg">
<colgroup><col class="c12"><col></colgroup>
<thead><tr><th>$(esc "$(T cfg_col_file)")</th><th>$(esc "$(T cfg_col_desc)")</th></tr></thead>
<tbody>
HTML
[ -f "$ETC/config" ] && printf '<tr><td><code>%s</code></td><td>%s</td></tr>\n' "$(esc "$ETC/config")" "$(esc "$(T cfg_file_config)")"
for lf in "$ETC"/lang/*.lang; do
    [ -f "$lf" ] || continue
    n=$(grep -c '^L\[' "$lf")
    if [ "$lf" = "$LANG_FILE" ]; then d=$(T cfg_file_lang_active n="$n"); else d=$(T cfg_file_lang n="$n"); fi
    printf '<tr><td><code>%s</code></td><td>%s</td></tr>\n' "$(esc "$lf")" "$(esc "$d")"
done
cat <<HTML
</tbody>
</table>
</div>
<p class="howto">$(esc "$(T cfg_howto2 file="$CONFIG")")</p>
</main>
<script>
HTML
page_js
tt_js
cat <<'HTML'
// Save the settings; if that fails the reason appears with a suggested fix
var saveBtn = document.getElementById('save'), box = document.getElementById('cfgmsg');
var okBox = document.getElementById('cfgok'), waitBox = document.getElementById('cfgwait');
var waitText = document.getElementById('cfgwaittext'), waitProg = document.getElementById('cfgwaitprog');
var controls = document.querySelectorAll('table.cfg input, table.cfg select');
function field(name) { return document.getElementById('f_' + name); }
// While a check runs (or settings are being applied) nothing can be changed
function lock(on, text) {
  controls.forEach(function (c) { c.disabled = on; });
  saveBtn.disabled = on;
  waitBox.hidden = !on;
  if (on && text) { waitText.textContent = text; }
  if (!on) { saveBtn.textContent = B.save; waitProg.textContent = ''; }
}
function progText(s) {
  if (!s || !s.running) { return ''; }
  if (s.phase === 'write') { return B.progFinishing; }
  if (s.total > 0 && s.step > 0) {
    return B.progStep.replace('{n}', s.step).replace('{t}', s.total)
      .replace('{name}', s.cur_name + (/^[0-9]+$/.test(s.cur_id) ? ' (' + s.cur_id + ')' : ''));
  }
  return B.progStarting;
}
onProgress = function (s) { waitProg.textContent = progText(s); };
function fail(text) {
  lock(false);
  box.textContent = text || ''; box.hidden = !text;
  if (text) { box.scrollIntoView({ block: 'nearest' }); }
}
saveBtn.addEventListener('click', function () {
  var data = {
    INCLUDE_HOST: field('INCLUDE_HOST').checked ? '1' : '0',
    CRON_ENABLED: field('CRON_ENABLED').checked ? '1' : '0',
    CRON_SCHEDULE: field('CRON_SCHEDULE').value.trim().replace(/\s+/g, ' '),
    TIMEOUT: field('TIMEOUT').value.trim(),
    EXCLUDE: field('EXCLUDE').value.trim().replace(/\s+/g, ' '),
    LANG_FILE: field('LANG_FILE').value
  };
  var token = field('GITHUB_TOKEN').value.trim();
  if (token) { data.GITHUB_TOKEN = token; } else if (field('TOKEN_REMOVE').checked) { data.GITHUB_TOKEN = ''; }
  box.hidden = true;
  okBox.hidden = true;
  send('config', JSON.stringify(data), true).then(function () {
    lock(true, B.applying);
    saveBtn.textContent = B.saving;
    // Show the confirmation after the page has reloaded
    try { sessionStorage.setItem('lxc-saved', '1'); } catch (e) {}
    startWait(function (text) { try { sessionStorage.removeItem('lxc-saved'); } catch (e) {} fail(text); });
  }, fail);
});
// Confirmation after a successful save (the page was reloaded for it)
try {
  var saved = sessionStorage.getItem('lxc-saved');
  if (saved) {
    sessionStorage.removeItem('lxc-saved');
    okBox.textContent = B.saved; okBox.hidden = false;
  }
} catch (e) {}
// The link to crontab.guru opens the entered expression right away
document.getElementById('cronguru').addEventListener('click', function () {
  var v = field('CRON_SCHEDULE').value.trim().replace(/\s+/g, '_');
  this.href = 'https://crontab.guru/' + (v ? '#' + v : '');
});
if (location.protocol === 'file:') {
  fail(B.errServer);
} else {
  // A check that is already running (e.g. started on the main page) locks the form; the page reloads by itself once the check has finished
  fetch('status.json?' + Date.now(), { cache: 'no-store' })
    .then(function (r) { return r.json(); })
    .then(function (s) {
      if (s.running) { lock(true, B.busy); onProgress(s); startWait(fail); }
    })
    .catch(function () {});
}
</script>
</body>
</html>
HTML
} > "$TMP"
chmod 644 "$TMP"
mv -f "$TMP" "$OUT_DIR/config.html"

# ------------------------------------------------------------ Write the "Help" page
# Commands for a system update per operating system. One line per command:
#   step :: os :: command [:: key help_label_<…> for a different label, or =literal label]
#   step :: os :: ~key        no command, the note help_note_<key> instead
# os: deb, arch, alpine, fedora, suse or all (applies to every system)
help_cmds() { cat <<'CMDS'
snap :: all :: pct snapshot <ID> pre_update :: snap_create
snap :: all :: pct listsnapshot <ID> :: snap_list
enter :: all :: pct enter <ID>
refresh :: deb :: apt update
refresh :: arch :: ~arch_refresh
refresh :: alpine :: apk update
refresh :: fedora :: dnf makecache --refresh
refresh :: suse :: zypper refresh
list :: deb :: apt list --upgradable
list :: arch :: checkupdates :: arch_list
list :: alpine :: apk version -l '<'
list :: fedora :: dnf check-update
list :: suse :: zypper list-updates
install :: deb :: apt full-upgrade
install :: arch :: pacman -Syu
install :: alpine :: apk upgrade
install :: fedora :: dnf upgrade
install :: suse :: zypper update :: =openSUSE Leap
install :: suse :: zypper dup :: =openSUSE Tumbleweed
autoremove :: deb :: apt autoremove
autoremove :: arch :: pacman -Qdtq | pacman -Rns -
autoremove :: alpine :: ~alpine_autoremove
autoremove :: fedora :: dnf autoremove
autoremove :: suse :: ~suse_autoremove
clean :: deb :: apt clean
clean :: arch :: pacman -Sc
clean :: alpine :: rm -rf /var/cache/apk/*
clean :: fedora :: dnf clean all
clean :: suse :: zypper clean
reboot :: all :: pct reboot <ID>
rollback :: all :: pct rollback <ID> pre_update
delsnap :: all :: pct delsnapshot <ID> pre_update
CMDS
}

write_help() {
    local -A osname=([deb]="Debian / Ubuntu" [arch]="Arch Linux" [alpine]="Alpine Linux" [fedora]="Fedora / Rocky / AlmaLinux" [suse]="openSUSE")
    local n=0 num st where line rest os cmd label o
    page_head "$(T help_title) – $(T app_title)"
    cat <<HTML
<body data-lang="$(esc "${L[lang_code]}")"$(dattr copy help_copy)$(dattr copied help_copied)$(dattr copy-failed help_copy_failed)>
<main>
<header>
  <div>
    <h1><span class="mark" aria-hidden="true"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 19.5V5M5.5 11.5 12 5l6.5 6.5" fill="none" stroke="currentColor" stroke-width="2.8" stroke-linecap="round" stroke-linejoin="round"/></svg></span>$(esc "$(T app_title)")</h1>
    <p class="headline">$(esc "$(T help_title)")</p>
    <p>$(esc "$(T help_intro)")</p>
  </div>
  <div class="scanbox">
    <a class="btn" href="config.html">$(esc "$(T btn_back)")</a>
  </div>
</header>
<div class="oschoice">
  <span>$(esc "$(T help_filter_label)")</span>
  <button class="tgl" data-os="" aria-pressed="true">$(esc "$(T help_filter_all)")</button>
HTML
    for o in deb arch alpine fedora suse; do
        printf '  <button class="tgl" data-os="%s" aria-pressed="false">%s</button>\n' "$o" "$(esc "${osname[$o]}")"
    done
    printf '</div>\n'
    # The seven update steps are numbered; the snapshot sections around them are not
    for st in snap enter refresh list install autoremove clean reboot rollback delsnap; do
        case $st in snap|rollback|delsnap) num="" ;; *) n=$((n + 1)); num="$n. " ;; esac
        case $st in refresh|list|install|autoremove|clean) where=$(T help_where_ct) ;; *) where=$(T help_where_host) ;; esac
        printf '<section class="step">\n<h2>%s%s <span class="tag sys">%s</span></h2>\n<p>%s</p>\n' \
            "$num" "$(esc "$(T "help_step_$st")")" "$(esc "$where")" "$(esc "$(T "help_expl_$st")")"
        while IFS= read -r line; do
            [[ $line == "$st :: "* ]] || continue
            rest=${line#* :: }; os=${rest%% :: *}; rest=${rest#* :: }
            if [[ $rest == *" :: "* ]]; then cmd=${rest%% :: *}; label=${rest#* :: }; else cmd=$rest; label=""; fi
            case $label in
                "")   if [ "$os" = all ]; then label=$(T help_os_all); else label=${osname[$os]}; fi ;;
                "="*) label=${label:1} ;;
                *)    label=$(T "help_label_$label") ;;
            esac
            if [[ $cmd == "~"* ]]; then
                printf '<div class="cmd" data-os="%s"><span class="os">%s</span><span class="nocmd">%s</span></div>\n' \
                    "$os" "$(esc "$label")" "$(esc "$(T "help_note_${cmd:1}")")"
            else
                printf '<div class="cmd" data-os="%s"><span class="os">%s</span><code>%s</code><button class="tgl copy">%s</button></div>\n' \
                    "$os" "$(esc "$label")" "$(esc "$cmd")" "$(esc "$(T help_copy)")"
            fi
        done < <(help_cmds)
        printf '</section>\n'
    done
    cat <<HTML
<p class="scope">$(esc "$(T help_scope)")</p>
</main>
<script>
HTML
    tt_js
    cat <<'HTML'
var B = document.body.dataset;
// Copying: over http (without https) the browser blocks the modern clipboard,
// so there is a fallback via an invisible text field.
function copyText(text) {
  if (navigator.clipboard && window.isSecureContext) { return navigator.clipboard.writeText(text); }
  return new Promise(function (resolve, reject) {
    var ta = document.createElement('textarea'), ok = false;
    ta.value = text; ta.setAttribute('readonly', '');
    ta.style.position = 'fixed'; ta.style.top = '0'; ta.style.opacity = '0';
    document.body.appendChild(ta); ta.select();
    try { ok = document.execCommand('copy'); } catch (e) {}
    document.body.removeChild(ta);
    if (ok) { resolve(); } else { reject(); }
  });
}
document.querySelectorAll('button.copy').forEach(function (b) {
  b.addEventListener('click', function () {
    var code = b.parentNode.querySelector('code');
    function reset() { setTimeout(function () { b.textContent = B.copy; }, 2000); }
    copyText(code.textContent).then(function () {
      b.textContent = B.copied; reset();
    }, function () {
      // If nothing works, select the command so that Ctrl+C is enough
      var r = document.createRange(); r.selectNodeContents(code);
      var sel = window.getSelection(); sel.removeAllRanges(); sel.addRange(r);
      b.textContent = B.copyFailed; reset();
    });
  });
});
// Choice of operating system: hides the commands of the other systems
var osBtns = document.querySelectorAll('.oschoice button');
function showOs(os) {
  osBtns.forEach(function (b) { b.setAttribute('aria-pressed', String(b.dataset.os === os)); });
  document.querySelectorAll('.cmd').forEach(function (c) {
    c.hidden = !!os && c.dataset.os !== os && c.dataset.os !== 'all';
  });
  try { localStorage.setItem('lxc-help-os', os); } catch (e) {}
}
osBtns.forEach(function (b) { b.addEventListener('click', function () { showOs(b.dataset.os); }); });
try {
  var saved = localStorage.getItem('lxc-help-os');
  if (saved && document.querySelector('.oschoice button[data-os="' + saved + '"]')) { showOs(saved); }
} catch (e) {}
</script>
</body>
</html>
HTML
}
TMP=$(mktemp "$OUT_DIR/.help.XXXXXX")
write_help > "$TMP"
chmod 644 "$TMP"
mv -f "$TMP" "$OUT_DIR/help.html"

# ------------------------------------------------------------------ Write the report
TMP=$(mktemp "$OUT_DIR/.index.XXXXXX")
{
page_head "$(T app_title)"
cat <<HTML
<body class="report"$(body_attrs)$(dattr show btn_show)$(dattr hide btn_hide)$(dattr scan btn_scan)$(dattr scanning btn_scanning)$(dattr prog-starting prog_starting)$(dattr prog-step prog_step)$(dattr prog-finishing prog_finishing)$(dattr snap-prompt snap_prompt)$(dattr snap-badname snap_badname)$(dattr snap-running snap_running)$(dattr snap-ok snap_ok)$(dattr prog-title prog_title)$(dattr prog-title-snap prog_title_snap)$(dattr prog-title-del prog_title_del)$(dattr prog-title-rb prog_title_rb)$(dattr snap-btn-rollback snap_btn_rollback)$(dattr snap-btn-delete snap_btn_delete)$(dattr confirm-delete confirm_delete)$(dattr confirm-rollback confirm_rollback)$(dattr confirm-rollback-newer confirm_rollback_newer)$(dattr confirm-rollback-type confirm_rollback_type)$(dattr confirm-mismatch confirm_mismatch)$(dattr del-running del_running)$(dattr rb-running rb_running)$(dattr del-ok del_ok)$(dattr del-fail del_fail)$(dattr rb-ok rb_ok)$(dattr rb-fail rb_fail)$(dattr snap-fail snap_fail)$(dattr snaplist-title snaplist_title)$(dattr snaplist-empty snaplist_empty)$(dattr snaplist-name snaplist_name)$(dattr snaplist-date snaplist_date)$(dattr snaplist-note snaplist_note)$(dattr snapinfo-title snapinfo_title)$(dattr snapinfo-intro snapinfo_intro)$(dattr snapinfo-pick snapinfo_pick)$(dattr snapinfo-none snapinfo_none)$(dattr snapinfo-rb-title snapinfo_rb_title)$(dattr snapinfo-rb-expl snapinfo_rb_expl)$(dattr snapinfo-del-title snapinfo_del_title)$(dattr snapinfo-del-expl snapinfo_del_expl)$(dattr snapinfo-list-title snapinfo_list_title)$(dattr copy help_copy)$(dattr copied help_copied)$(dattr copy-failed help_copy_failed)>
<main>
<header class="top">
  <div>
    <h1><span class="mark" aria-hidden="true"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 19.5V5M5.5 11.5 12 5l6.5 6.5" fill="none" stroke="currentColor" stroke-width="2.8" stroke-linecap="round" stroke-linejoin="round"/></svg></span>$(esc "$(T app_title)")</h1>
    <p class="headline">$(esc "$HEADLINE")</p>
    <p>$(esc "$SUMMARY")</p>
    <p class="meta">$(esc "$META")</p>
  </div>
  <div class="scanbox">
    <button id="scan" class="btn">$(esc "$(T btn_scan)")</button>
    <a class="btn ghost" href="config.html">$(esc "$(T btn_config)")</a>
    <span id="scanmsg" role="status"></span>
  </div>
</header>
<p id="snapres" class="okbox top" role="status" hidden></p>
<div class="wrap">
<div class="mhead" aria-hidden="true"><span>$(esc "$(T col_container)")</span><span>$(esc "$(T col_installed)")</span><span>$(esc "$(T col_latest)")</span><span></span></div>
<table id="ct">
<thead><tr><th class="num" aria-sort="ascending"><button class="sort" data-key="id">$(esc "$(T col_id)")</button></th><th><button class="sort" data-key="name">$(esc "$(T col_container)")</button></th><th>$(esc "$(T col_app)")</th><th>$(esc "$(T col_installed)")</th><th>$(esc "$(T col_latest)")</th><th>$(esc "$(T col_status)")</th><th class="num">$(esc "$(T col_packages)")</th><th></th></tr></thead>
<tbody>
$ROWS
</tbody>
</table>
</div>
<dialog id="snapdlg" aria-labelledby="snapdlgtitle">
  <h2 id="snapdlgtitle"></h2>
  <div id="snapdlgbody"></div>
  <div class="dlgfoot"><button id="snapdlgclose" class="btn ghost">$(esc "$(T btn_close)")</button></div>
</dialog>
<dialog id="prog" aria-labelledby="progtitle">
  <h2 id="progtitle">$(esc "$(T prog_title)")</h2>
  <div class="bar"><div id="progbar"></div></div>
  <p id="progcur" role="status"></p>
  <ul id="proglog"></ul>
  <p id="progerr" class="errbox" role="alert" hidden></p>
  <button id="progclose" class="btn ghost">$(esc "$(T prog_close)")</button>
</dialog>
</main>
<script>
HTML
page_js
tt_js
cat <<'HTML'
// "Check now" and arrow buttons: send the job, lock the buttons, wait for the new report
var scanBtn = document.getElementById('scan'), scanMsg = document.getElementById('scanmsg');
var upBtns = document.querySelectorAll('button.up, button.snap'), busy = false;
// During a check the big button stays clickable: it reopens the status window
function setBusy(on, text) {
  busy = on;
  upBtns.forEach(function (b) { b.disabled = on; });
  scanBtn.textContent = on ? text : B.scan;
  scanBtn.setAttribute('aria-busy', on ? 'true' : 'false');
}
// Status window: progress bar, current container, results so far
var dlg = document.getElementById('prog'), progBar = document.getElementById('progbar');
var progCur = document.getElementById('progcur'), progLog = document.getElementById('proglog');
var progErr = document.getElementById('progerr');
// Title of the status window: what is going on (check, or which snapshot action)
var progTitle = document.getElementById('progtitle'), pendingAction = 'scan', pendingText = '';
function setProgTitle(action) {
  progTitle.textContent = { snapshot: B.progTitleSnap, snapdel: B.progTitleDel, rollback: B.progTitleRb }[action] || B.progTitle;
}
function showProgress(s) {
  setProgTitle(s ? s.action : pendingAction);
  var pct = 0, cur = (!s && pendingAction !== 'scan' && pendingAction !== 'refresh' && pendingText) || B.progStarting;
  if (s && s.phase === 'snapshot') {
    cur = (s.action === 'snapdel' ? B.delRunning : s.action === 'rollback' ? B.rbRunning : B.snapRunning).replace('{id}', s.cur_id);
  } else if (s && s.phase === 'write') {
    pct = 100; cur = B.progFinishing;
  } else if (s && s.total > 0 && s.step > 0) {
    pct = Math.round((s.step - 1) / s.total * 100);
    cur = B.progStep.replace('{n}', s.step).replace('{t}', s.total)
      .replace('{name}', s.cur_name + (/^[0-9]+$/.test(s.cur_id) ? ' (' + s.cur_id + ')' : ''));
  }
  progBar.style.width = pct + '%';
  progCur.textContent = cur;
  var log = (s && s.log) || [];
  if (log.length !== progLog.children.length) {
    progLog.textContent = '';
    log.forEach(function (e) {
      var li = document.createElement('li'), name = document.createElement('span'), tag = document.createElement('span');
      name.textContent = e.name + (/^[0-9]+$/.test(e.id) ? ' (' + e.id + ')' : '');
      tag.className = 'tag ' + e.cls; tag.textContent = e.label;
      li.appendChild(name); li.appendChild(tag); progLog.appendChild(li);
    });
    progLog.scrollTop = progLog.scrollHeight;
  }
}
onProgress = showProgress;
document.getElementById('progclose').addEventListener('click', function () { dlg.close(); });
function fail(text) {
  setBusy(false); scanMsg.textContent = text || '';
  progErr.textContent = text || ''; progErr.hidden = !text; progCur.textContent = '';
}
function openProgress() { if (dlg.showModal && !dlg.open) { dlg.showModal(); } }
function begin(text, quiet) {
  scanMsg.textContent = ''; progErr.hidden = true;
  setBusy(true, text); showProgress(null);
  if (!quiet) { openProgress(); }
  startWait(fail);
}
function run(url, needPw, text) {
  scanMsg.textContent = '';
  pendingAction = url.split('?')[0]; pendingText = text;
  send(url, null, needPw).then(function () { begin(text); }, fail);
}
scanBtn.addEventListener('click', function () {
  if (busy) { openProgress(); return; }
  run('scan', false, B.scanning);
});
// Arrow button: re-check this container only
document.querySelectorAll('button.up').forEach(function (b) {
  b.addEventListener('click', function () { run('refresh?id=' + b.dataset.id, false, B.scanning); });
});
// Snapshot list (☰) and instructions for rolling back or deleting (i) in one dialog
var sdlg = document.getElementById('snapdlg'), sbody = document.getElementById('snapdlgbody');
function el(tag, cls, text) { var e = document.createElement(tag); if (cls) { e.className = cls; } if (text != null) { e.textContent = text; } return e; }
function snapList(b) {
  // data-snaps: name:unixtime,… (newest first after sorting)
  return (b.dataset.snaps || '').split(',').filter(Boolean).map(function (x) {
    var i = x.lastIndexOf(':'); return { name: x.slice(0, i), time: parseInt(x.slice(i + 1), 10) || 0 };
  }).sort(function (a, c) { return c.time - a.time; });
}
function fmtTime(t) {
  return t ? new Date(t * 1000).toLocaleString(B.lang, { dateStyle: 'medium', timeStyle: 'short' }) : '–';
}
function copyText(text) {
  if (navigator.clipboard && window.isSecureContext) { return navigator.clipboard.writeText(text); }
  return new Promise(function (resolve, reject) {
    var ta = document.createElement('textarea'), ok = false;
    ta.value = text; ta.setAttribute('readonly', ''); ta.style.position = 'fixed'; ta.style.opacity = '0';
    sdlg.appendChild(ta); ta.select();
    try { ok = document.execCommand('copy'); } catch (e) {}
    sdlg.removeChild(ta);
    if (ok) { resolve(); } else { reject(); }
  });
}
function cmdLine(text) {
  var row = el('div', 'cmd1'), code = el('code', '', text), btn = el('button', 'tgl copy', B.copy);
  btn.addEventListener('click', function () {
    copyText(code.textContent).then(function () { btn.textContent = B.copied; }, function () {
      var r = document.createRange(); r.selectNodeContents(code);
      var s = window.getSelection(); s.removeAllRanges(); s.addRange(r); btn.textContent = B.copyFailed;
    });
    setTimeout(function () { btn.textContent = B.copy; }, 2000);
  });
  row.appendChild(code); row.appendChild(btn); return row;
}
function openSnapDlg(title) {
  document.getElementById('snapdlgtitle').textContent = title;
  sbody.textContent = '';
  if (sdlg.showModal && !sdlg.open) { sdlg.showModal(); }
}
document.querySelectorAll('button.snaplist').forEach(function (b) {
  b.addEventListener('click', function () {
    var list = snapList(b), id = b.dataset.id, cname = b.dataset.name;
    openSnapDlg(B.snaplistTitle.replace('{id}', id).replace('{name}', cname));
    if (!list.length) { sbody.appendChild(el('p', 'mute', B.snaplistEmpty)); }
    else {
      var t = el('table', 'pk snaps'), h = el('tr');
      h.appendChild(el('th', '', B.snaplistName)); h.appendChild(el('th', '', B.snaplistDate)); h.appendChild(el('th'));
      var th = el('thead'); th.appendChild(h); t.appendChild(th);
      var tb = el('tbody');
      list.forEach(function (s, i) {
        var r = el('tr'), act = el('td', 'snapacts');
        r.appendChild(el('td', '', s.name)); r.appendChild(el('td', '', fmtTime(s.time)));
        var rb = el('button', 'tgl', B.snapBtnRollback), del = el('button', 'tgl danger', B.snapBtnDelete);
        rb.addEventListener('click', function () { snapOp('rollback', id, cname, s, list.slice(0, i)); });
        del.addEventListener('click', function () { snapOp('delete', id, cname, s, []); });
        act.appendChild(rb); act.appendChild(del); r.appendChild(act); tb.appendChild(r);
      });
      t.appendChild(tb); sbody.appendChild(t);
    }
    sbody.appendChild(el('p', 'mute small', B.snaplistNote));
  });
});
// Delete / roll back: always ask first; a rollback also wants the snapshot name typed in
function snapOp(op, id, cname, s, newer) {
  var fill = function (t) { return t.replace('{id}', id).replace('{name}', cname).replace('{snap}', s.name).replace('{date}', fmtTime(s.time)); };
  if (op === 'delete') {
    if (!window.confirm(fill(B.confirmDelete))) { return; }
  } else {
    var text = fill(B.confirmRollback);
    if (newer.length) { text += B.confirmRollbackNewer.replace('{list}', newer.map(function (n) { return n.name; }).join(', ')); }
    if (!window.confirm(text)) { return; }
    var typed = window.prompt(fill(B.confirmRollbackType), '');
    if (typed === null) { return; }
    if (typed.trim() !== s.name) { window.alert(B.confirmMismatch); return; }
  }
  sdlg.close();
  snapBox.hidden = true;
  try { sessionStorage.setItem('lxc-snap', id); } catch (e) {}
  var url = (op === 'delete' ? 'snapdel' : 'rollback') + '?id=' + id + '&name=' + encodeURIComponent(s.name);
  run(url, true, (op === 'delete' ? B.delRunning : B.rbRunning).replace('{id}', id));
}
document.querySelectorAll('button.snapinfo').forEach(function (b) {
  b.addEventListener('click', function () {
    var id = b.dataset.id, list = snapList(b);
    openSnapDlg(B.snapinfoTitle.replace('{id}', id).replace('{name}', b.dataset.name));
    sbody.appendChild(el('p', '', B.snapinfoIntro));
    var pick = null;
    if (list.length) {
      var lab = el('label', 'pick', B.snapinfoPick + ' ');
      pick = el('select');
      list.forEach(function (s) { var o = el('option', '', s.name + '  (' + fmtTime(s.time) + ')'); o.value = s.name; pick.appendChild(o); });
      lab.appendChild(pick); sbody.appendChild(lab);
    } else {
      sbody.appendChild(el('p', 'mute', B.snapinfoNone));
    }
    var parts = [
      ['h3', B.snapinfoRbTitle], ['p', B.snapinfoRbExpl], ['cmd', 'pct rollback ' + id + ' {snap}'], ['cmd', 'pct start ' + id],
      ['h3', B.snapinfoDelTitle], ['p', B.snapinfoDelExpl], ['cmd', 'pct delsnapshot ' + id + ' {snap}'],
      ['h3', B.snapinfoListTitle], ['cmd', 'pct listsnapshot ' + id]
    ];
    var codes = [];
    parts.forEach(function (x) {
      if (x[0] === 'cmd') { var line = cmdLine(''); line.dataset.tpl = x[1]; codes.push(line); sbody.appendChild(line); }
      else { sbody.appendChild(el(x[0], '', x[1])); }
    });
    function fill() {
      var name = pick ? pick.value : '<Name>';
      codes.forEach(function (c) { c.querySelector('code').textContent = c.dataset.tpl.replace('{snap}', name); });
    }
    if (pick) { pick.addEventListener('change', fill); }
    fill();
  });
});
document.getElementById('snapdlgclose').addEventListener('click', function () { sdlg.close(); });
// Camera button: ask for a name, then take the snapshot (password required)
var snapBox = document.getElementById('snapres');
document.querySelectorAll('button.snap').forEach(function (b) {
  b.addEventListener('click', function () {
    var d = new Date(), p = function (n) { return (n < 10 ? '0' : '') + n; };
    // Proposal: pre_update_<installed app version>; snapshot names allow no dots, so
    // 3.2.4 becomes 3-2-4. Without a known version the date stands in for it.
    var ver = (b.dataset.ver || '').replace(/[^A-Za-z0-9_-]+/g, '-').replace(/^-+|-+$/g, '');
    if (!ver) { ver = d.getFullYear() + p(d.getMonth() + 1) + p(d.getDate()) + '_' + p(d.getHours()) + p(d.getMinutes()); }
    var def = ('pre_update_' + ver).slice(0, 40), used = (b.dataset.snaps || '').split(',').map(function (x) { return x.replace(/:[0-9]*$/, ''); }), n = 2;
    while (used.indexOf(def) !== -1) { def = ('pre_update_' + ver).slice(0, 37) + '_' + n++; }
    var name = window.prompt(B.snapPrompt.replace('{id}', b.dataset.id).replace('{name}', b.dataset.name), def);
    if (name === null) { return; }
    name = name.trim();
    if (!/^[A-Za-z][A-Za-z0-9_-]{0,39}$/.test(name)) { snapBox.className = 'errbox top'; snapBox.textContent = B.snapBadname; snapBox.hidden = false; return; }
    snapBox.hidden = true;
    try { sessionStorage.setItem('lxc-snap', b.dataset.id); } catch (e) {}
    run('snapshot?id=' + b.dataset.id + '&name=' + encodeURIComponent(name), true, B.snapRunning.replace('{id}', b.dataset.id));
  });
});
// After the reload: show the result of the snapshot that was started from this page
(function () {
  var want = null;
  try { want = sessionStorage.getItem('lxc-snap'); } catch (e) {}
  if (!want) { return; }
  fetch('status.json?' + Date.now(), { cache: 'no-store' })
    .then(function (r) { return r.json(); })
    .then(function (s) {
      if (s.running || !s.snap || s.snap.id !== want) { return; }
      try { sessionStorage.removeItem('lxc-snap'); } catch (e) {}
      snapBox.className = (s.snap.ok ? 'okbox' : 'errbox') + ' top';
      var msgs = { create: [B.snapOk, B.snapFail], 'delete': [B.delOk, B.delFail], rollback: [B.rbOk, B.rbFail] }[s.snap.op || 'create'];
      snapBox.textContent = (s.snap.ok ? msgs[0] : msgs[1]).replace('{id}', s.snap.id)
        .replace('{snap}', s.snap.name).replace('{msg}', s.snap.msg);
      snapBox.hidden = false;
    })
    .catch(function () {});
})();
// If something is already running when the page opens (e.g. the nightly check), wait as well
fetch('status.json?' + Date.now(), { cache: 'no-store' })
  .then(function (r) { return r.json(); })
  .then(function (s) {
    // without forcing the window open; a click on the button shows it
    if (s.running) { begin(B.scanning, true); }
  })
  .catch(function () {});

// Phones: the ▾ button (or a tap on the container name) opens the details of a row
var phone = window.matchMedia('(max-width: 700px)');
document.addEventListener('click', function (e) {
  var t = e.target, b = t.closest ? t.closest('button.more') : null;
  if (!b && phone.matches && t.closest && t.closest('tr.ct > td.c-name')) { b = t.closest('tr.ct').querySelector('button.more'); }
  if (!b) { return; }
  var tr = b.closest('tr.ct'), open = !tr.classList.contains('open');
  tr.classList.toggle('open', open);
  b.setAttribute('aria-expanded', String(open));
});
document.querySelectorAll('button.tgl').forEach(function (b) {
  b.addEventListener('click', function () {
    var row = b.closest('tr').nextElementSibling;
    var open = row.hidden;
    row.hidden = !open;
    b.setAttribute('aria-expanded', String(open));
    b.textContent = open ? B.hide : B.show;
  });
});
var tbody = document.querySelector('#ct > tbody');
document.querySelectorAll('button.sort').forEach(function (btn) {
  btn.addEventListener('click', function () {
    var key = btn.dataset.key, th = btn.parentNode;
    var dir = th.getAttribute('aria-sort') === 'ascending' ? -1 : 1;
    var groups = [];
    Array.prototype.forEach.call(tbody.children, function (tr) {
      if (tr.classList.contains('ct')) { groups.push([tr]); } else { groups[groups.length - 1].push(tr); }
    });
    groups.sort(function (a, b) {
      var x = a[0].dataset[key], y = b[0].dataset[key];
      if (key === 'id') { return (parseInt(x, 10) - parseInt(y, 10)) * dir; }
      return x.localeCompare(y, B.lang, { sensitivity: 'base' }) * dir;
    });
    groups.forEach(function (g) { g.forEach(function (tr) { tbody.appendChild(tr); }); });
    document.querySelectorAll('#ct th[aria-sort]').forEach(function (t) { t.removeAttribute('aria-sort'); });
    th.setAttribute('aria-sort', dir === 1 ? 'ascending' : 'descending');
  });
});
</script>
</body>
</html>
HTML
} > "$TMP"

chmod 644 "$TMP"
mv -f "$TMP" "$OUT_DIR/index.html"

echo "[$(date '+%F %T')] Done: $N_APPUPD app updates, $N_PKG system packages ($N_SEC security) on $N_TOTAL systems -> $OUT_DIR/index.html"
