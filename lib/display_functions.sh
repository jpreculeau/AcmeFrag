# shellcheck shell=bash
################################################################################
# AFFICHAGE ET RAPPORTS - AcmeFrag (XFS + EXT4)
#
# Licence / License: GNU General Public License v3
# Copyright (C) 2026 Jean-Philippe Reculeau — voir LICENSE
################################################################################

# Classement des N fichiers les plus fragmentés (N = $2, 10 par défaut)
display_top() {
    local csv="$1" limit="${2:-10}" bytes extents human path flag rank=0
    title "🏆 TOP ${limit} DES FICHIERS LES PLUS FRAGMENTÉS (extents, puis taille)"
    if (( INTEL_THRESHOLD_MO > 0 )); then
        log "---   NON* = extent moyen >= ${INTEL_THRESHOLD_MO} Mo : ignoré (-s 0 pour tout traiter)"
    fi
    printf '%-4s| %-8s | %-7s | %-9s | %s\n' "N°" "EXTENTS" "TAILLE" "TRAITABLE" "NOM DU FICHIER"
    printf '%s\n' "${RULE//=/-}"
    while IFS=$'\t' read -r bytes extents human path; do
        rank=$((rank + 1))
        if is_eligible "$bytes" "$extents"; then flag="OUI"; else flag="NON*"; fi
        printf '%-3s | %-8s | %-7s | %-9s | %s\n' "$rank" "$extents" "$human" "$flag" "$(basename -- "$path")"
    done < <(csv_rows "$csv" | head -n "$limit")
    (( rank == 0 )) && log "   Aucun fichier fragmenté 🎉"
    printf '%s\n' "${RULE//=/-}"
}

# Résumé d'éligibilité : évite la surprise de « 60 ignorés » après traitement
display_eligibility_summary() {
    local csv="$1" bytes extents _h _p total=0 eligible=0
    while IFS=$'\t' read -r bytes extents _h _p; do
        total=$((total + 1))
        is_eligible "$bytes" "$extents" && eligible=$((eligible + 1))
    done < <(csv_rows "$csv")
    log ""
    if (( INTEL_THRESHOLD_MO == 0 )); then
        log "   Fichiers éligibles : $eligible / $total (filtre intelligent désactivé)"
    else
        log "   Fichiers éligibles : $eligible / $total (seuil ${INTEL_THRESHOLD_MO} Mo/extent)"
        (( total > eligible )) && log "   Les $((total - eligible)) autres sont déjà assez contigus pour une lecture fluide."
    fi
    return 0
}

# Taille moyenne des zones libres en Mo (vide si indisponible)
_avg_free_extent_mo() {
    local target="$1" dev bs blocks kb
    dev=$(fs_source "$target")
    case "$(fs_type "$target")" in
        xfs)
            command -v xfs_db >/dev/null 2>&1 || return 1
            bs=$(stat -f -c %S "$target")
            # "average free extent size 83137.6" (point ou virgule selon la locale)
            blocks=$(LC_ALL=C xfs_db -r -c "freesp -s" "$dev" 2>/dev/null \
                | awk '/average free extent size/ { v = $NF; sub(/[.,].*/, "", v); print v }')
            is_uint "$blocks" && is_uint "$bs" || return 1
            echo $(( blocks * bs / MIB )) ;;
        ext4)
            command -v e2freefrag >/dev/null 2>&1 || return 1
            # "Avg. free extent: 52432 KB"
            kb=$(LC_ALL=C e2freefrag "$dev" 2>/dev/null | awk -F': *' '/^Avg\. free extent/ { print $2+0 }')
            is_uint "$kb" || return 1
            echo $(( kb / 1024 )) ;;
        *) return 1 ;;
    esac
}

# État de santé de l'espace libre (même critère pour XFS et EXT4)
display_free_space_status() {
    local target="$1" avg pct
    title "📊 ÉTAT DE SANTÉ DE L'ESPACE LIBRE ($(fs_type "$target"))"
    pct=$(df --output=pcent "$target" | tail -n1 | tr -dc '0-9')
    log "   Occupation : ${pct}% sur $(fs_source "$target")"
    if avg=$(_avg_free_extent_mo "$target"); then
        log "   Taille moyenne des zones libres : ~ ${avg} Mo"
        if   (( avg > 500 )); then ok "Excellent (espace libre sain et continu)"
        elif (( avg > 100 )); then warn "Correct (espace libre légèrement morcelé)"
        else                       err "Critique (espace libre très haché : la défragmentation échouera souvent)"
        fi
    else
        warn "Analyse de l'espace libre indisponible (xfs_db / e2freefrag absent ou illisible)"
    fi
    if is_uint "$pct" && (( pct > 90 )); then
        warn "Disque rempli à plus de 90 % : xfs_fsr/e4defrag manqueront de place contiguë."
    fi
    return 0
}

display_session_summary() {
    title "📋 RÉSUMÉ DE LA SESSION"
    log "   [OK]       Défragmentés          : $STAT_OK"
    log "   [DÉJÀ-OK]  Sans gain possible    : $STAT_ALREADY"
    log "   [IGNORÉ]   Filtre / récent / etc. : $STAT_SKIPPED"
    log "   [ÉCHEC]    Échecs                : $STAT_FAILED"
    is_true "$DRY_RUN" && log "   [SIMULÉ]   Dry-run               : $STAT_SIMULATED"
    return 0
}
