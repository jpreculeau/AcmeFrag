#!/bin/bash
################################################################################
# MODULE DE SURVEILLANCE SÉCURITÉ - AcmeFrag
# - Supervise en temps réel les secteurs réalloués SMART, dérive, températures
# - Génère un fichier de statut et un fichier d'arrêt pour intégration
################################################################################

MONITOR_STATUS_FILE="/tmp/acmefrag_monitor_status.txt"
MONITOR_PID_FILE="/tmp/acmefrag_monitor.pid"
MONITOR_STOP_FILE="/tmp/acmefrag_monitor_stop"

_get_block_device() {
    local target_dir="$1"
    # Renvoie le device complet (ex: /dev/sda1 ou /dev/nvme0n1p1)
    df "$target_dir" 2>/dev/null | tail -1 | awk '{print $1}'
}

start_security_monitor() {
    local target_dir="$1"
    local interval=${MONITOR_INTERVAL_SEC:-5}
    local dev_node
    dev_node=$(_get_block_device "$target_dir")

    # Nettoyer anciens fichiers
    rm -f "$MONITOR_STATUS_FILE" "$MONITOR_STOP_FILE"

    # Valeurs initiales
    local initial_bad=0
    local last_bad=0
    local smart_available="false"

    if command -v smartctl >/dev/null 2>&1; then
        smart_available="true"
        # smartctl veut le device (sans partition numéro parfois) ; on fournira le node entier
        initial_bad=$(smartctl -A "$dev_node" 2>/dev/null | awk '/Reallocated_Sector_Ct|Reallocated_Sector_Count/ {print $10; exit}' || true)
        initial_bad=${initial_bad:-0}
        last_bad=$initial_bad
    fi

    # Démarrer la boucle en arrière-plan
    (
        while true; do
            local current_bad=0
            local drift=0
            local disk_temp="N/A"
            local sys_temp="N/A"
            local alerts=()

            if [ "$smart_available" = "true" ]; then
                current_bad=$(smartctl -A "$dev_node" 2>/dev/null | awk '/Reallocated_Sector_Ct|Reallocated_Sector_Count/ {print $10; exit}' || true)
                current_bad=${current_bad:-0}
                drift=$(( current_bad - initial_bad ))
            fi

            # Température disque via SMART si disponible
            if [ "$smart_available" = "true" ]; then
                disk_temp=$(smartctl -A "$dev_node" 2>/dev/null | awk '/Temperature_Celsius|Temperature_Internal/ {print $10; exit}' || true)
                disk_temp=${disk_temp:-"N/A"}
            fi

            # Température système via sensors si disponible
            if command -v sensors >/dev/null 2>&1; then
                # tenter d'extraire la première valeur en °C
                sys_temp=$(sensors 2>/dev/null | awk '/^temp[0-9]+/ {gsub("+","",$2); gsub("°C","",$2); print int($2); exit}' || true)
                sys_temp=${sys_temp:-"N/A"}
            fi

            # Construire alertes selon les seuils configurés
            if [ "$smart_available" = "true" ]; then
                if [ -n "$current_bad" ] && [ "$current_bad" -ge ${SMART_BAD_SECTOR_THRESHOLD:-100} ] 2>/dev/null; then
                    alerts+=("BAD_SECTORS_HIGH: ${current_bad}")
                fi
                if [ -n "$drift" ] && [ "$drift" -ge ${SMART_BAD_SECTOR_DRIFT_THRESHOLD:-5} ] 2>/dev/null; then
                    alerts+=("BAD_SECTORS_DRIFT: +${drift}")
                fi
            fi

            if [ "$disk_temp" != "N/A" ] && [ "$disk_temp" -ge ${DISK_TEMP_THRESHOLD_C:-60} ] 2>/dev/null; then
                alerts+=("DISK_TEMP:${disk_temp}C")
            fi
            if [ "$sys_temp" != "N/A" ] && [ "$sys_temp" -ge ${SYSTEM_TEMP_THRESHOLD_C:-85} ] 2>/dev/null; then
                alerts+=("SYS_TEMP:${sys_temp}C")
            fi

            # Ecrire le statut dans le fichier
            {
                echo "timestamp: $(date +'%Y-%m-%d %H:%M:%S')"
                echo "device: ${dev_node:-unknown}"
                echo "smart_available: $smart_available"
                echo "bad_sectors: ${current_bad:-0}"
                echo "bad_drift: ${drift:-0}"
                echo "disk_temp: ${disk_temp}"
                echo "system_temp: ${sys_temp}"
                if [ ${#alerts[@]} -gt 0 ]; then
                    echo "alerts: ${alerts[*]}"
                else
                    echo "alerts: none"
                fi
            } > "$MONITOR_STATUS_FILE"

            # Si alerte critique et auto-stop activé, créer fichier d'arrêt
            if [ ${#alerts[@]} -gt 0 ] && [ "${AUTO_STOP_ON_ALERT:-false}" = "true" ]; then
                touch "$MONITOR_STOP_FILE"
            fi

            # Préserver last_bad
            last_bad=$current_bad

            sleep "$interval"
        done
    ) &

    echo $! > "$MONITOR_PID_FILE"
    return 0
}

stop_security_monitor() {
    if [ -f "$MONITOR_PID_FILE" ]; then
        local pid
        pid=$(cat "$MONITOR_PID_FILE" 2>/dev/null || true)
        if [ -n "$pid" ]; then
            kill "$pid" 2>/dev/null || true
        fi
        rm -f "$MONITOR_PID_FILE"
    fi
    rm -f "$MONITOR_STATUS_FILE" "$MONITOR_STOP_FILE"
    return 0
}

read_monitor_status() {
    if [ -f "$MONITOR_STATUS_FILE" ]; then
        cat "$MONITOR_STATUS_FILE"
    else
        echo "timestamp: N/A"
        echo "device: N/A"
        echo "smart_available: false"
        echo "bad_sectors: N/A"
        echo "bad_drift: N/A"
        echo "disk_temp: N/A"
        echo "system_temp: N/A"
        echo "alerts: none"
    fi
}

monitor_should_stop() {
    if [ -f "$MONITOR_STOP_FILE" ]; then
        return 0
    fi
    return 1
}

export -f start_security_monitor stop_security_monitor read_monitor_status monitor_should_stop
