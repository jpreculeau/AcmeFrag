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

# Un inode, une seule mesure. Un fichier à plusieurs noms (liens physiques :
# cross-seed, hardlinks de sauvegarde) n'est lu qu'une fois, sous le premier
# nom rencontré ; les autres noms sont notés dans $1 ("nom<TAB>premier nom").
# C'est l'inode qui fait foi, pas le chemin : un lien devenu le seul nom restant
# est un fichier comme un autre. Statistiques ajoutées à $2 ("clé<TAB>valeur") :
# multi (inodes à plusieurs noms), shared (leurs octets), links (noms ignorés).
# Enregistrements terminés par NUL, chemin = tout ce qui suit les trois premiers
# champs (il peut contenir des espaces). Un nom à tabulation ou retour à la ligne
# (non représentable au CSV) est écarté ici, avant d'avoir pu devenir le « premier
# nom » d'un inode qui en a un valide. Un inode vu avec nlink > 1 n'est jamais oublié :
# un nom ajouté ensuite (cross-seed pendant le parcours) ne le fait pas re-mesurer.
# Limite connue, comme en 4.1.0 : un fichier vu sous son seul nom puis lié pendant le
# parcours est mesuré deux fois (l'éviter imposerait de retenir tous les inodes).
# Locale C : octets tels quels, pas d'avertissement gawk sur un nom non UTF-8 ; d'où
# le retrait explicite des contrôles C1 codés en UTF-8 (\302\200-\302\237), que
# [[:cntrl:]] ne voit pas en C (printable() les retire en C.UTF-8).
_dedupe_inodes() {
    LINKS="$1" STATS="$2" LC_ALL=C awk -v RS='\0' -v ORS='\0' '
        function clean(s) { gsub(/[[:cntrl:]]/, "?", s); gsub(/\302[\200-\237]/, "?", s); return s }
        {
            path = substr($0, length($1) + length($2) + length($3) + 4)
            if (path ~ /[\t\n]/) next
            if ($2 > 1) {                                  # nlink > 1 seulement
                if ($1 in first) {
                    printf "%s\t%s\n", clean(path), clean(first[$1]) >> ENVIRON["LINKS"]
                    links++; next
                }
                first[$1] = path; multi++; shared += $3
            }
            print path
        }
        END {
            printf "multi\t%d\nshared\t%.0f\nlinks\t%d\n", multi, shared, links >> ENVIRON["STATS"]
        }'
}

# Écrit sur stdout "extents<TAB>chemin" pour chaque fichier à >= 2 extents.
# $2 = fichier des noms ignorés, $3 = fichier des statistiques (voir
# _dedupe_inodes ; « total » = nombre d'inodes analysés y est ajouté).
_scan_extents() {
    local target="$1" links="$2" stats="$3"
    local -a excl=()
    mapfile -d '' -t excl < <(_find_exclude_args)
    # `filefrag` sort en erreur (code != 0) dès qu'un fichier est illisible : ce
    # n'est pas bloquant pour un scan, d'où le `|| true` sur la seule étape xargs.
    find "$target" -xdev -type f -size +0 "${excl[@]}" -printf '%D:%i %n %s %p\0' \
        | _dedupe_inodes "$links" "$stats" \
        | { xargs -0 -r filefrag 2>/dev/null || true; } \
        | parse_filefrag \
        | ST="$stats" awk -F'\t' '{ total++ } $1 >= 2 { print }
                                   END { printf "total\t%d\n", total >> ENVIRON["ST"] }'
}

# Valeur de la statistique $1 du fichier $2 (vide si absente)
scan_stat() { awk -F'\t' -v k="$1" '$1 == k { print $2 }' "$2" 2>/dev/null; }

# "extents<TAB>chemin" (stdin, sortie de _scan_extents) -> lignes CSV sans en-tête.
# $2 = fichier de travail. Écartés, par défense en profondeur (_dedupe_inodes ne
# laisse déjà passer aucun nom à tabulation ou retour à la ligne) : chemin hors de
# la cible $1 ou contenant une tabulation (non représentable). Tailles par lots
# (xargs stat) : pas de processus par fichier.
_scan_rows() {
    local list="$2"
    # Chemins par l'environnement : awk -v interpréterait les « \ » d'un nom
    PRE="${1%/}/" awk -F '\t' 'NF == 2 && index($2, ENVIRON["PRE"]) == 1' > "$list"
    cut -f2- "$list" | tr '\n' '\0' | { xargs -0 -r stat -c $'%s\t%n' -- 2>/dev/null || true; } \
        | LC_ALL=C awk -F '\t' -v OFS='\t' "$AWK_HUMAN"'
            NR == FNR { size[$2] = $1; next }
            ($2 in size) { print size[$2], $1, human(size[$2]), $2 }' - "$list"
}

# Noms ignorés par le dernier scan (autres noms d'un inode déjà mesuré)
SCAN_LINKS_SKIPPED=0

# Scan complet -> CSV. $1 = cible, $2 = fichier CSV
scan_filesystem() {
    local target="$1" csv="$2" tmp stats links list total multi shared
    title "🔍 Analyse de la fragmentation ($(fs_type "$target")) sur : $target"
    log "---   ⏳ Peut prendre plusieurs minutes selon le nombre de fichiers…"

    tmp=$(mktemp "${csv}.XXXXXX")
    stats=$(mktemp "${csv}.stats.XXXXXX")
    links=$(mktemp "${csv}.links.XXXXXX")
    list=$(mktemp "${csv}.list.XXXXXX")       # créés ici : connus de cleanup après un Ctrl+C
    TMP_FILES+=("$tmp" "$stats" "$links" "$list")
    {
        printf '%s\n' "$CSV_HEADER"
        _scan_extents "$target" "$links" "$stats" | _scan_rows "$target" "$list" | sort -t $'\t' -k2,2rn -k1,1rn
    } > "$tmp"
    mv -f -- "$tmp" "$csv"      # écriture atomique : jamais de rapport à moitié écrit

    multi=$(scan_stat multi "$stats"); shared=$(scan_stat shared "$stats")
    SCAN_LINKS_SKIPPED=$(scan_stat links "$stats")
    : "${multi:=0}" "${shared:=0}" "${SCAN_LINKS_SKIPPED:=0}"
    awk -F'\t' '{ printf "   🔗 %s : déjà traité via %s\n", $1, $2 }' "$links"
    total=$(scan_stat total "$stats")
    ok "Scan terminé : $(csv_count "$csv") fichier(s) fragmenté(s) sur ${total:-?} analysé(s)"
    if (( multi > 0 )); then   # inodes à plusieurs noms sur le disque (pas forcément tous dans la cible)
        log "      Fichiers multi-noms : ${multi} ($(human_size "$shared") partagés) · liens ignorés : ${SCAN_LINKS_SKIPPED}"
    fi
    log "      Rapport : $csv"
    rm -f -- "$stats" "$links" "$list"
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
