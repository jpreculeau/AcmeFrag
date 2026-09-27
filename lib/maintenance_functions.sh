# shellcheck shell=bash
################################################################################
# MENU INTERACTIF - AcmeFrag (XFS + EXT4)
#
# Licence / License: GNU General Public License v3
# Copyright (C) 2026 Jean-Philippe Reculeau — voir LICENSE
################################################################################

# Demande un entier >= $2 (défaut $3). Affiche la valeur sur stdout.
_ask_uint() {
    local prompt="$1" min="$2" default="$3" value
    read -rp "   $prompt [$default] : " value
    value="${value:-$default}"
    if ! is_uint "$value" || (( value < min )); then
        err "Valeur invalide (entier >= $min attendu)"; return 1
    fi
    printf '%s\n' "$value"
}

run_maintenance() {
    local target="$1" csv="$2" choice n selection fs
    local -a nums=()
    fs=$(fs_type "$target")
    while true; do
        monitor_should_stop && { STOPPED_BY_MONITOR=true; err "Surveillance : $(monitor_stop_reason)"; return 0; }
        title "🔧 MENU DE MAINTENANCE — dry-run : $(is_true "$DRY_RUN" && echo ACTIVÉ || echo désactivé)"
        log "   1) Défragmenter les ${DEFAULT_TOP_LIMIT} premiers fichiers éligibles"
        log "   2) Défragmenter tous les fichiers au-delà d'un seuil d'extents"
        log "   3) Choisir des fichiers dans le classement"
        log "   4) Afficher le classement (TOP 20)"
        log "   5) Relancer le scan"
        log "   6) État de l'espace libre"
        [[ "$fs" == xfs ]] && log "   7) Défragmentation globale du disque (xfs_fsr, max ${GLOBAL_FSR_TIMEOUT_SEC}s)"
        log "   d) Basculer le mode dry-run"
        log "   q) Quitter"
        read -rp "   Votre choix : " choice || return 0     # EOF (Ctrl+D) = quitter
        case "$choice" in
            1) process_csv_rows "$DEFAULT_TOP_LIMIT" "$DEFAULT_MIN_EXTENTS" "$csv" "$target" ;;
            2) n=$(_ask_uint "Nombre minimum d'extents" 2 5) &&
                   process_csv_rows 0 "$n" "$csv" "$target" ;;
            3) display_top "$csv" 20
               read -rp "   Numéros séparés par des espaces (ex: 1 3 5) : " selection
               read -ra nums <<< "$selection"
               (( ${#nums[@]} > 0 )) && process_selected_rows "$csv" "$target" "${nums[@]}" ;;
            4) display_top "$csv" 20 ;;
            5) scan_filesystem "$target" "$csv" && display_top "$csv" "$DEFAULT_TOP_LIMIT" ;;
            6) display_free_space_status "$target" ;;
            7) if [[ "$fs" == xfs ]]; then
                   read -rp "   Confirmer la défragmentation globale ? (o/N) : " n
                   [[ "$n" == [oO] ]] && defrag_global_xfs "$target"
               else
                   err "Choix invalide"
               fi ;;
            d|D) if is_true "$DRY_RUN"; then DRY_RUN=false; warn "Dry-run DÉSACTIVÉ : les fichiers seront modifiés"
                 else DRY_RUN=true; ok "Dry-run ACTIVÉ : opérations simulées"; fi ;;
            q|Q|'') log "✋ Au revoir !"; return 0 ;;
            *) err "Choix invalide" ;;
        esac || true
    done
}
