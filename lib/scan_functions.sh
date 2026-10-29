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
# SPDX-License-Identifier: GPL-3.0-or-later
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

# "extents<TAB>chemin" (stdin, sortie de _scan_extents) -> lignes CSV sans en-tête.
# Le total « #TOTAL » est écrit dans le fichier $2 ; $3 = fichier de travail. Écartés : chemin hors de la
# cible $1 (morceau d'un nom à retour à la ligne, relatif au dossier courant) ou
# contenant une tabulation (non représentable). Tailles par lots (xargs stat) :
# pas de processus par fichier.
_scan_rows() {
    local list="$3"
    # Chemins par l'environnement : awk -v interpréterait les « \ » d'un nom
    PRE="${1%/}/" TF="$2" awk -F '\t' '
        $1 == "#TOTAL" { print $2 > ENVIRON["TF"]; next }
        NF == 2 && index($2, ENVIRON["PRE"]) == 1' > "$list"
    cut -f2- "$list" | tr '\n' '\0' | { xargs -0 -r stat -c $'%s\t%n' -- 2>/dev/null || true; } \
        | LC_ALL=C awk -F '\t' -v OFS='\t' "$AWK_HUMAN"'
            NR == FNR { size[$2] = $1; next }
            ($2 in size) { print size[$2], $1, human(size[$2]), $2 }' - "$list"
}

# Scan complet -> CSV. $1 = cible, $2 = fichier CSV
scan_filesystem() {
    local target="$1" csv="$2" tmp total_file list
    title "🔍 Analyse de la fragmentation ($(fs_type "$target")) sur : $target"
    log "---   ⏳ Peut prendre plusieurs minutes selon le nombre de fichiers…"

    tmp=$(mktemp "${csv}.XXXXXX")
    total_file=$(mktemp "${csv}.total.XXXXXX")
    list=$(mktemp "${csv}.list.XXXXXX")       # créé ici : connu de cleanup après un Ctrl+C
    TMP_FILES+=("$tmp" "$total_file" "$list")
    {
        printf '%s\n' "$CSV_HEADER"
        _scan_extents "$target" | _scan_rows "$target" "$total_file" "$list" | sort -t $'\t' -k2,2rn -k1,1rn
    } > "$tmp"
    mv -f -- "$tmp" "$csv"      # écriture atomique : jamais de rapport à moitié écrit

    ok "Scan terminé : $(csv_count "$csv") fichier(s) fragmenté(s) sur $(cat "$total_file" 2>/dev/null || echo '?') analysé(s)"
    log "      Rapport : $csv"
    rm -f -- "$total_file" "$list"
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
