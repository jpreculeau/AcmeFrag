# shellcheck shell=bash
################################################################################
# SCAN DE FRAGMENTATION - AcmeFrag (XFS + EXT4)
# Un seul scanner pour les deux FS : `filefrag` (ioctl FIEMAP) fonctionne sur XFS
# comme sur EXT4. Les fichiers sont passés par lots (xargs) : quelques dizaines de
# processus au lieu de plusieurs par fichier.
#
# Rapport CSV (séparateur TAB, trié par extents puis taille décroissants) :
#   Octets<TAB>Extents<TAB>Taille<TAB>Chemin
#
# Licence / License: GNU General Public License v3
# Copyright (C) 2026 Jean-Philippe Reculeau — voir LICENSE
################################################################################

readonly CSV_HEADER=$'Octets\tExtents\tTaille\tChemin'

# Arguments `find` d'exclusion construits depuis SCAN_EXCLUDES
_find_exclude_args() {
    local pat
    for pat in "${SCAN_EXCLUDES[@]}"; do
        printf '%s\0' '!' -name "$pat"
    done
}

# Écrit sur stdout "extents<TAB>chemin" pour chaque fichier à >= 2 extents,
# puis une dernière ligne "#TOTAL<TAB>n" (nombre de fichiers analysés).
_scan_extents() {
    local target="$1"
    local -a excl=()
    mapfile -d '' -t excl < <(_find_exclude_args)
    # `filefrag` sort en erreur (code != 0) dès qu'un fichier est illisible : ce
    # n'est pas bloquant pour un scan, d'où le `|| true` sur la seule étape xargs.
    find "$target" -xdev -type f -size +0 "${excl[@]}" -print0 \
        | { xargs -0 -r filefrag 2>/dev/null || true; } \
        | parse_filefrag \
        | awk -F'\t' '{ total++ } $1 >= 2 { print } END { printf "#TOTAL\t%d\n", total }'
}

# Scan complet -> CSV. $1 = cible, $2 = fichier CSV
scan_filesystem() {
    local target="$1" csv="$2" tmp total_file n path size
    title "🔍 Analyse de la fragmentation ($(fs_type "$target")) sur : $target"
    log "---   ⏳ Peut prendre plusieurs minutes selon le nombre de fichiers…"

    tmp=$(mktemp "${csv}.XXXXXX")
    total_file="${tmp}.total"
    {
        printf '%s\n' "$CSV_HEADER"
        while IFS=$'\t' read -r n path; do
            if [[ "$n" == "#TOTAL" ]]; then printf '%s' "$path" > "$total_file"; continue; fi
            # Chemin non représentable dans un CSV TAB (TAB / retour ligne dans le nom)
            [[ "$path" == *$'\t'* || ! -f "$path" ]] && continue
            size=$(stat -c %s -- "$path" 2>/dev/null) || continue
            printf '%s\t%s\t%s\t%s\n' "$size" "$n" "$(human_size "$size")" "$path"
        done < <(_scan_extents "$target") | sort -t $'\t' -k2,2rn -k1,1rn
    } > "$tmp"
    mv -f -- "$tmp" "$csv"      # écriture atomique : jamais de rapport à moitié écrit

    ok "Scan terminé : $(csv_count "$csv") fichier(s) fragmenté(s) sur $(cat "$total_file" 2>/dev/null || echo '?') analysé(s)"
    log "      Rapport : $csv"
    rm -f -- "$total_file"
}

# Nombre de lignes de données du CSV
csv_count() { local n; n=$(wc -l < "$1"); echo $(( n > 0 ? n - 1 : 0 )); }

# Ligne de données n° N (1 = la plus fragmentée), sans en-tête
csv_row() { sed -n "$(( $2 + 1 ))p" "$1"; }

# NB : les lectures du CSV se font directement sur le fichier (pas de `tail | head`) :
# un lecteur qui s'arrête tôt provoquerait un SIGPIPE en amont (code 141).

# Supprime les rapports et journaux plus anciens que REPORT_MAX_AGE_DAYS
clean_old_reports() {
    log "---   🧹 Nettoyage des rapports de plus de ${REPORT_MAX_AGE_DAYS} jours"
    find "$REPORT_DIR" -maxdepth 1 -type f \
        \( -name 'fragmentation_*.csv' -o -name 'acmefrag_*.log' \) \
        -mtime +"$REPORT_MAX_AGE_DAYS" -delete
}
