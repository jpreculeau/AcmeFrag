# shellcheck shell=bash
################################################################################
# DÉFRAGMENTATION - AcmeFrag (XFS : xfs_fsr, EXT4 : e4defrag)
# Le résultat est mesuré (extents avant/après via filefrag) plutôt que déduit du
# texte des outils : même logique et même affichage pour les deux FS.
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Jean-Philippe Reculeau — voir LICENSE
################################################################################

# Compteurs de session
STAT_OK=0 STAT_ALREADY=0 STAT_SKIPPED=0 STAT_FAILED=0 STAT_SIMULATED=0
STOPPED_BY_MONITOR=false

# Éligibilité au filtre intelligent. $1 = octets, $2 = extents.
# Éligible si taille moyenne d'un extent < INTEL_THRESHOLD_MO (0 = toujours).
is_eligible() {
    local bytes="$1" extents="$2"
    (( INTEL_THRESHOLD_MO == 0 )) && return 0
    (( extents < 1 )) && return 0
    (( bytes / extents / MIB < INTEL_THRESHOLD_MO ))
}

# Commande de défragmentation d'un fichier pour ce FS (tableau via stdout NUL)
_defrag_cmd() {
    case "$1" in
        xfs)  printf '%s\0' xfs_fsr -v "$2" ;;
        ext4) printf '%s\0' e4defrag "$2" ;;
        *)    return 1 ;;
    esac
}

# Défragmente un fichier. $1 = chemin, $2 = extents (scan), $3 = octets, $4 = FS
# Retour : 0 (traité ou ignoré), 130 (interruption Ctrl+C)
defrag_file() {
    local path="$1" extents="$2" bytes="$3" fs="$4"
    local name age avail after rc output reason
    local -a cmd=()
    name=$(basename -- "$path")
    (( ${#name} > 45 )) && name="${name:0:42}..."
    printf '⏳ [%s] (%6s) %-45s : ' "$(date +%H:%M:%S)" "$(human_size "$bytes")" "$name"

    if [[ ! -f "$path" ]]; then
        printf '%sDisparu depuis le scan ⏭️%s\n' "$C_YELLOW" "$C_RESET"
        STAT_SKIPPED=$((STAT_SKIPPED + 1)); return 0
    fi
    age=$(file_age_min "$path" || echo 0)
    if (( age < MIN_FILE_AGE_MIN )); then
        printf '%sModifié il y a %s min (écriture en cours ?) ⏭️%s\n' "$C_YELLOW" "$age" "$C_RESET"
        STAT_SKIPPED=$((STAT_SKIPPED + 1)); return 0
    fi
    avail=$(fs_avail_bytes "$path")
    if is_uint "$avail" && (( avail < bytes )); then
        printf '%sEspace libre insuffisant (%s requis) ❌%s\n' "$C_RED" "$(human_size "$bytes")" "$C_RESET"
        STAT_FAILED=$((STAT_FAILED + 1)); return 0
    fi

    mapfile -d '' -t cmd < <(_defrag_cmd "$fs" "$path")
    if is_true "$DRY_RUN"; then
        printf '%s[DRY-RUN] %s (%s extents)%s\n' "$C_BLUE" "${cmd[*]}" "$extents" "$C_RESET"
        STAT_SIMULATED=$((STAT_SIMULATED + 1)); return 0
    fi

    rc=0
    output=$("${cmd[@]}" 2>&1) || rc=$?
    (( rc > 128 )) && { echo "interrompu"; return "$EXIT_INTERRUPTED"; }

    after=$(file_extents "$path")
    if is_uint "$after" && (( after < extents )); then
        printf '%s%s → %s extents (-%s) ✅%s\n' "$C_GREEN" "$extents" "$after" "$((extents - after))" "$C_RESET"
        STAT_OK=$((STAT_OK + 1))
    elif (( rc == 0 )); then
        printf '%sAucun gain possible (%s extents) ✅%s\n' "$C_BLUE" "${after:-$extents}" "$C_RESET"
        STAT_ALREADY=$((STAT_ALREADY + 1))
    else
        reason=$(printf '%s' "$output" | tr '\n' ' ' | tr -s ' ' | cut -c1-70)
        printf '%sÉchec (code %s) : %s ❌%s\n' "$C_RED" "$rc" "${reason:-sans message}" "$C_RESET"
        STAT_FAILED=$((STAT_FAILED + 1))
    fi
    return 0
}

# Traite les lignes du CSV. $1 = limite de fichiers éligibles (0 = tous),
# $2 = extents minimum, $3 = CSV, $4 = cible
process_csv_rows() {
    local limit="$1" min_extents="$2" csv="$3" target="$4"
    local fs bytes extents _h path count=0 rc
    fs=$(fs_type "$target")
    exec 3< "$csv"
    read -r -u 3 _h || true                            # en-tête
    while IFS=$'\t' read -r -u 3 bytes extents _h path; do
        (( limit > 0 && count >= limit )) && break
        (( extents < min_extents )) && break          # CSV trié : les suivants sont plus petits
        if ! is_eligible "$bytes" "$extents"; then
            STAT_SKIPPED=$((STAT_SKIPPED + 1)); continue
        fi
        if monitor_should_stop; then
            STOPPED_BY_MONITOR=true
            err "Arrêt demandé par la surveillance : $(monitor_stop_reason)"
            break
        fi
        monitor_status_line
        rc=0
        defrag_file "$path" "$extents" "$bytes" "$fs" || rc=$?
        (( rc == EXIT_INTERRUPTED )) && exit "$EXIT_INTERRUPTED"
        count=$((count + 1))
    done
    exec 3<&-
    if (( count == 0 )) && ! is_true "$STOPPED_BY_MONITOR"; then
        log "ℹ️  Aucun fichier éligible à la défragmentation."
    fi
    return 0
}

# Défragmente une sélection de lignes du CSV (numéros 1..N du classement)
process_selected_rows() {
    local csv="$1" target="$2"; shift 2
    local fs num line bytes extents _h path
    fs=$(fs_type "$target")
    for num in "$@"; do
        if ! is_uint "$num" || (( num < 1 )); then warn "Numéro ignoré : $num"; continue; fi
        line=$(csv_row "$csv" "$num")
        [[ -n "$line" ]] || { warn "Numéro hors classement : $num"; continue; }
        IFS=$'\t' read -r bytes extents _h path <<< "$line"
        monitor_should_stop && { STOPPED_BY_MONITOR=true; err "Arrêt demandé par la surveillance"; break; }
        defrag_file "$path" "$extents" "$bytes" "$fs" || exit "$EXIT_INTERRUPTED"
    done
}

# Défragmentation globale XFS (xfs_fsr sur le périphérique, bornée dans le temps)
defrag_global_xfs() {
    local target="$1" dev
    dev=$(fs_source "$target")
    if is_true "$DRY_RUN"; then
        log "[DRY-RUN] xfs_fsr -t $GLOBAL_FSR_TIMEOUT_SEC -v $dev"; return 0
    fi
    log "---   xfs_fsr global sur $dev (durée max ${GLOBAL_FSR_TIMEOUT_SEC}s, Ctrl+C pour arrêter)"
    xfs_fsr -t "$GLOBAL_FSR_TIMEOUT_SEC" -v "$dev" 2>&1 \
        | awk '/extents before/ { ok++ } /already fully/ { skip++ }
               END { printf "\n   [xfs_fsr global] Défragmentés : %d | Déjà optimaux : %d\n", ok, skip }'
}
