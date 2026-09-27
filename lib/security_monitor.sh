# shellcheck shell=bash
################################################################################
# SURVEILLANCE TEMPS RÉEL - AcmeFrag
# Tâche de fond qui relève SMART (secteurs réalloués, température disque) et la
# température système, et demande l'arrêt si un seuil est dépassé.
# Fichiers d'état dans un dossier privé (mktemp) : pas de chemins /tmp prévisibles.
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Jean-Philippe Reculeau — voir LICENSE
################################################################################

MONITOR_DIR=""
MONITOR_PID=""

# Détermine les arguments smartctl qui fonctionnent pour ce disque (USB : -d sat)
_smart_args() {
    local dev="$1" t
    command -v smartctl >/dev/null 2>&1 || return 1
    for t in "" "-d sat" "-d auto"; do
        # shellcheck disable=SC2086
        if smartctl -A $t "$dev" >/dev/null 2>&1; then
            printf '%s\n' "$t"; return 0
        fi
    done
    return 1
}

# Affiche "secteurs_realloues temperature" (NA si indisponible)
_smart_read() {
    local dev="$1" args="$2"
    # shellcheck disable=SC2086
    smartctl -A $args "$dev" 2>/dev/null | awk '
        $1 == 5                   { bad = $10 }
        ($1 == 194 || $1 == 190) && temp == "" { temp = $10 }
        /^Temperature:/           { if (temp == "") temp = $2 }   # NVMe
        END { print (bad == "" ? "NA" : bad), (temp == "" ? "NA" : temp) }'
}

_system_temp() {
    local raw
    raw=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null) || { echo NA; return; }
    is_uint "$raw" && echo $((raw / 1000)) || echo NA
}

# Boucle de surveillance (exécutée en arrière-plan)
_monitor_loop() {
    local dev="$1" args="$2" smart="$3" parent="$4"
    local initial_bad="NA" bad temp sys drift alerts
    # Ne pas hériter du verrou : un `sleep` orphelin le garderait après la fin du script
    if [[ -n "${LOCK_FD:-}" ]]; then exec {LOCK_FD}>&-; fi
    [[ "$smart" == true ]] && read -r initial_bad _ < <(_smart_read "$dev" "$args")
    while kill -0 "$parent" 2>/dev/null; do
        bad=NA temp=NA drift=0 alerts=""
        [[ "$smart" == true ]] && read -r bad temp < <(_smart_read "$dev" "$args")
        sys=$(_system_temp)
        if is_uint "$bad" && is_uint "$initial_bad"; then
            drift=$((bad - initial_bad))
            (( bad >= SMART_BAD_SECTOR_THRESHOLD )) && alerts+="BAD_SECTORS:${bad} "
            (( drift >= SMART_BAD_SECTOR_DRIFT_THRESHOLD )) && alerts+="BAD_DRIFT:+${drift} "
        fi
        is_uint "$temp" && (( temp >= DISK_TEMP_THRESHOLD_C )) && alerts+="DISK_TEMP:${temp}C "
        is_uint "$sys" && (( sys >= SYSTEM_TEMP_THRESHOLD_C )) && alerts+="SYS_TEMP:${sys}C "
        alerts="${alerts% }"
        # Écriture atomique : le lecteur ne voit jamais un fichier à moitié écrit
        printf 'bad_sectors=%s\nbad_drift=%s\ndisk_temp=%s\nsystem_temp=%s\nalerts=%s\n' \
            "$bad" "$drift" "$temp" "$sys" "${alerts:-none}" > "$MONITOR_DIR/status.tmp"
        mv -f "$MONITOR_DIR/status.tmp" "$MONITOR_DIR/status"
        if [[ -n "$alerts" ]] && is_true "$AUTO_STOP_ON_ALERT"; then
            printf '%s\n' "$alerts" > "$MONITOR_DIR/stop"
        fi
        sleep "$MONITOR_INTERVAL_SEC" & wait $! || true
    done
}

start_security_monitor() {
    local target="$1" dev args="" smart=false
    dev="/dev/$(parent_disk "$(fs_source "$target")")"
    if args=$(_smart_args "$dev"); then
        smart=true
    else
        warn "SMART indisponible sur $dev (smartmontools absent ou pont USB non supporté)"
    fi
    MONITOR_DIR=$(mktemp -d "${TMPDIR:-/tmp}/acmefrag.XXXXXX")
    _monitor_loop "$dev" "$args" "$smart" "$$" &
    MONITOR_PID=$!
    ok "Surveillance active sur $dev (relevé toutes les ${MONITOR_INTERVAL_SEC}s)"
}

stop_security_monitor() {
    if [[ -n "$MONITOR_PID" ]]; then
        kill "$MONITOR_PID" 2>/dev/null || true
        wait "$MONITOR_PID" 2>/dev/null || true
        MONITOR_PID=""
    fi
    [[ -n "$MONITOR_DIR" && -d "$MONITOR_DIR" ]] && rm -rf -- "$MONITOR_DIR"
    MONITOR_DIR=""
}

monitor_should_stop() {
    [[ -n "$MONITOR_DIR" && -f "$MONITOR_DIR/stop" ]]
}

monitor_stop_reason() {
    if [[ -n "$MONITOR_DIR" ]]; then cat "$MONITOR_DIR/stop" 2>/dev/null || true; fi
}

# Ligne compacte affichée avant chaque fichier
monitor_status_line() {
    [[ -n "$MONITOR_DIR" && -f "$MONITOR_DIR/status" ]] || return 0
    local k v bad=NA drift=0 dt=NA st=NA alerts=none
    while IFS='=' read -r k v; do
        case "$k" in
            bad_sectors) bad="$v" ;; bad_drift) drift="$v" ;;
            disk_temp) dt="$v" ;; system_temp) st="$v" ;; alerts) alerts="$v" ;;
        esac
    done < "$MONITOR_DIR/status"
    is_uint "$dt" && dt="${dt}°C"
    is_uint "$st" && st="${st}°C"
    local color="$C_GREEN"
    [[ "$alerts" != none ]] && color="$C_RED"
    printf '   🔒 MONITOR: bad_sectors=%s bad_drift=+%s disk_temp=%s system_temp=%s alerts=%s%s%s\n' \
        "$bad" "$drift" "$dt" "$st" "$color" "$alerts" "$C_RESET"
}
