# shellcheck shell=bash
################################################################################
# SANTÉ DU DISQUE (SMART) - AcmeFrag
# Lecture SMART strictement passive (jamais d'auto-test), historique par numéro
# de série, alertes sur dégradation (--sante) et garde-fou avant défragmentation.
# Toute sortie de smartctl est traitée comme hostile : seuls des entiers et des
# mots alphabétiques en sont retenus.
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Jean-Philippe Reculeau — voir LICENSE
################################################################################

# Attributs SMART suivis, dans l'ordre des colonnes de l'historique
readonly HEALTH_ATTRS=(1 5 9 187 188 194 196 197 198 199)
# Colonnes d'un état : bilan global, attributs, nombre d'erreurs ATA journalisées
readonly HEALTH_COLS=(bilan "${HEALTH_ATTRS[@]}" ata)
# Toute hausse de ces colonnes est une alerte
readonly HEALTH_RISE_ALERT=(5 196 197 198 199 ata)
declare -grA HEALTH_LABELS=(   # -g : fichier sourcé depuis une fonction
    [1]="Erreurs de lecture brutes (1)"     [5]="Secteurs réalloués (5)"
    [9]="Heures de fonctionnement (9)"      [187]="Erreurs non corrigées (187)"
    [188]="Commandes expirées (188)"        [194]="Température °C (194, à défaut 190)"
    [196]="Événements de réallocation (196)" [197]="Secteurs en attente (197)"
    [198]="Secteurs non corrigibles (198)"  [199]="Erreurs CRC, câble ou boîtier (199)"
    [ata]="Erreurs ATA journalisées"
)

HEALTH_ALERTS=()

# Position de la colonne $1 (ex: 5, 197, ata) dans un état
_col() {
    local i
    for i in "${!HEALTH_COLS[@]}"; do [[ "${HEALTH_COLS[$i]}" == "$1" ]] && { echo "$i"; return 0; }; done
    return 1
}

# Type d'accès qui fait répondre le disque : "" (détection automatique) ou
# "-d sat" (pont USB non reconnu). $1 = disque, puis options smartctl en plus
# (ex: -n standby pour ne pas réveiller un disque en veille).
# Retour : 0 (arguments sur stdout), 1 SMART indisponible, 2 disque en veille.
smart_args() {
    local dev="$1" t out rc; shift
    command -v smartctl >/dev/null 2>&1 || return 1
    for t in "" "-d sat"; do
        rc=0
        # shellcheck disable=SC2086
        out=$(smartctl "$@" -i $t "$dev" 2>&1) || rc=$?
        [[ "$out" == *" in STANDBY"* || "$out" == *" in SLEEP"* ]] && return 2
        # Bits 0-1 du code de smartctl : ligne de commande ou ouverture en échec.
        # Les autres décrivent l'état du disque (8 = bilan FAILED), pas l'accès.
        (( (rc & 3) == 0 )) && { printf '%s\n' "$t"; return 0; }
    done
    return 1
}

# Texte smartctl (stdin) -> "série<TAB>bilan<TAB>attributs…<TAB>erreurs ATA"
# NA pour toute valeur absente ou non numérique ; série réduite à [A-Za-z0-9._-]
# (une tabulation ou une séquence de terminal ne doit ni décaler les colonnes ni
# atteindre l'affichage). Température : attribut 194, à défaut 190, à défaut NVMe.
_health_parse() {
    LC_ALL=C awk -v ids="${HEALTH_ATTRS[*]}" '
        BEGIN { n = split(ids, id, " ") }
        /^Serial [Nn]umber:/ { s = $0; sub(/^Serial [Nn]umber:[ \t]*/, "", s); serial = substr(s, 1, 64) }
        /self-assessment test result:/ { health = $NF }
        /^SMART Health Status:/ { health = ($4 == "OK") ? "PASSED" : $4 }
        /^ATA Error Count:/ { ata = $4 }
        /^Temperature:/ { nvme_temp = $2 }                      # NVMe : « Temperature: 45 Celsius »
        /^No Errors Logged/ { ata = 0 }
        /^ID# +ATTRIBUTE_NAME/ { inattr = 1; next }
        inattr && NF == 0 { inattr = 0 }
        # RAW_VALUE : premier nombre ("40 (Min/Max 15/50)", "12345h+12m")
        inattr && $1 ~ /^[0-9]+$/ && NF >= 10 { v = $10; sub(/[^0-9].*/, "", v); if (v != "") raw[$1 + 0] = v }
        END {
            gsub(/[^A-Za-z0-9._-]/, "_", serial)
            gsub(/[^A-Za-z]/, "", health); health = substr(health, 1, 32)
            if (!(194 in raw) && (190 in raw)) raw[194] = raw[190]
            if (!(194 in raw) && nvme_temp ~ /^[0-9]+$/) raw[194] = nvme_temp
            if (ata !~ /^[0-9]+$/) ata = ""
            printf "%s\t%s", (serial == "" ? "NA" : serial), (health == "" ? "NA" : health)
            for (i = 1; i <= n; i++) printf "\t%s", (((id[i] + 0) in raw) ? raw[id[i] + 0] : "NA")
            printf "\t%s\n", (ata == "" ? "NA" : ata)
        }'
}

# Relevé SMART du disque $1 (options smartctl en plus) au format de _health_parse.
# Lectures seules : -H bilan, -i identité, -A attributs, -l error journal d'erreurs.
# Retour : 0, 1 (indisponible ou réponse inexploitable), 2 (veille).
_health_read() {
    local dev="$1" args rec; shift
    args=$(smart_args "$dev" "$@") || return $?
    # shellcheck disable=SC2086
    rec=$( { smartctl "$@" -H -i -A -l error $args "$dev" 2>/dev/null || true; } | _health_parse)
    # Ni bilan ni attribut (SMART désactivé, pont SCSI muet) : mesure impossible
    local tab=$'\t'
    [[ "${rec#*"$tab"}" =~ ^NA(${tab}NA)*$ ]] && return 1
    printf '%s\n' "$rec"
}

# Historique du disque de numéro de série $1 (déjà assaini ; redit par défense)
_health_file() { printf '%s/sante/%s.tsv\n' "$REPORT_DIR" "${1//[^A-Za-z0-9._-]/_}"; }

# Le script tourne en root dans un dossier de l'utilisateur : refuser tout lien
# symbolique sur le chemin de l'historique (dossier de rapports, sante/, fichier).
_health_path_safe() {
    [[ ! -L "$REPORT_DIR" && ! -L "${1%/*}" && ! -L "$1" ]]
}

# Dernier état enregistré (sans la date), vide s'il n'y en a pas
_health_last() {
    local line
    [[ -f "$1" && ! -L "$1" ]] || return 0
    line=$(tail -n 1 -- "$1")
    [[ "$line" == date$'\t'* ]] || printf '%s\n' "${line#*$'\t'}"
}

# État de référence du garde-fou : la plus ancienne mesure des SMART_GUARD_DAYS
# derniers jours, à défaut la dernière. Une hausse reste ainsi bloquante même
# quand un --sante quotidien l'a déjà enregistrée.
_health_baseline() {
    local since
    [[ -f "$1" ]] && _health_path_safe "$1" || return 0
    since=$(date -d "-${SMART_GUARD_DAYS} days" '+%Y-%m-%dT%H:%M:%S')
    awk -F '\t' -v since="$since" '
        NR == 1 { next }
        $1 >= since { found = $0; exit }
        { last = $0 }
        END { r = (found != "") ? found : last; if (r != "") { sub(/^[^\t]*\t/, "", r); print r } }' "$1"
}

# Ajoute l'état $2 à l'historique $1 (en-tête à la création)
_health_record() {
    local file="$1" state="$2" fd
    _health_path_safe "$file" && mkdir -p -- "${file%/*}" && _health_path_safe "$file" || return 1
    exec {fd}>>"$file" || return 1
    flock -w 10 "$fd" || { exec {fd}>&-; return 1; }
    if [[ ! -s "$file" ]]; then
        (IFS=$'\t'; printf 'date\t%s\n' "${HEALTH_COLS[*]}") >&"$fd"
    fi
    printf '%s\t%s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$state" >&"$fd"
    exec {fd}>&-
}

_health_alert() { HEALTH_ALERTS+=("$1"); warn "ALERTE : $1"; }

# Affiche l'évolution entre l'état précédent $1 (vide : première mesure) et
# l'état actuel $2 ; remplit HEALTH_ALERTS.
_health_compare() {
    local -a p=() c=()
    local i key a b rise
    HEALTH_ALERTS=()
    IFS=$'\t' read -ra c <<< "$2"
    [[ -n "$1" ]] && IFS=$'\t' read -ra p <<< "$1"
    case "${c[0]}" in
        PASSED) ok "Bilan SMART : PASSED${p[0]:+ (précédent : ${p[0]})}" ;;
        NA)     warn "Bilan SMART indisponible" ;;
        *)  if [[ "${p[0]:-}" == "${c[0]}" ]]; then
                warn "Bilan SMART : ${c[0]} (connu, déjà signalé)"
            else
                _health_alert "Bilan SMART : ${p[0]:-première mesure} → ${c[0]}"
            fi ;;
    esac
    for (( i = 1; i < ${#HEALTH_COLS[@]}; i++ )); do
        key="${HEALTH_COLS[$i]}" a="${p[$i]:-NA}" b="${c[$i]:-NA}"
        rise=false
        if is_uint "$a" && is_uint "$b" && (( 10#$b > 10#$a )) && [[ " ${HEALTH_RISE_ALERT[*]} " == *" $key "* ]]; then
            rise=true
        fi
        if $rise; then
            _health_alert "${HEALTH_LABELS[$key]} : $a → $b"
        elif [[ "$a" != NA && "$a" != "$b" ]]; then
            log "   ${HEALTH_LABELS[$key]} : $a → $b"
        else
            log "   ${HEALTH_LABELS[$key]} : $b"
        fi
    done
    i=$(_col 194)
    if is_uint "${c[$i]:-}" && (( 10#${c[$i]} > SMART_TEMP_ALERT_C )); then
        _health_alert "Température ${c[$i]} °C au-dessus du seuil (${SMART_TEMP_ALERT_C} °C)"
    fi
    return 0
}

_health_unavailable() {
    warn "$1"
    log "BILAN SANTÉ : mesure impossible : $1"
    return "$EXIT_HEALTH_UNAVAILABLE"
}

# --sante : relève le disque qui porte $1 sans le réveiller, compare à la mesure
# précédente et l'ajoute à l'historique. Termine par une ligne « BILAN SANTÉ : ».
# Retour : 0, EXIT_HEALTH_ALERT ou EXIT_HEALTH_UNAVAILABLE.
run_health_check() {
    local dev rec rc=0 serial state file written=true
    dev=$(disk_device "$1")
    title "🩺 SANTÉ DU DISQUE ${dev} (SMART, lecture seule)"
    rec=$(_health_read "$dev" -n standby) || rc=$?
    case "$rc" in
        0) ;;
        2) _health_unavailable "$dev en veille : mesure reportée (disque non réveillé)"; return ;;
        *) _health_unavailable "SMART indisponible sur $dev (smartmontools absent ou pont USB non supporté)"; return ;;
    esac
    serial="${rec%%$'\t'*}" state="${rec#*$'\t'}"
    if [[ "$serial" == NA ]]; then
        # Sans numéro de série, deux disques partageraient un historique : pas de comparaison
        warn "Numéro de série illisible : mesure sans historique"
        _health_compare "" "$state"
    else
        file=$(_health_file "$serial")
        _health_path_safe "$file" || { _health_unavailable "Historique refusé (lien symbolique) : $file"; return; }
        log "   N° de série : $serial · historique : $file"
        _health_compare "$(_health_last "$file")" "$state"
        _health_record "$file" "$state" || written=false
    fi
    if (( ${#HEALTH_ALERTS[@]} > 0 )); then
        $written || warn "Historique non écrit : $file"
        local msg; printf -v msg '%s ; ' "${HEALTH_ALERTS[@]}"
        log "BILAN SANTÉ : ${msg% ; }"
        return "$EXIT_HEALTH_ALERT"
    fi
    $written || { _health_unavailable "historique non inscriptible : $file"; return; }
    log "BILAN SANTÉ : aucune nouvelle dégradation (bilan ${state%%$'\t'*})"
}

# Raison d'un refus de défragmenter (vide : rien de bloquant).
# $1 = état de référence (vide si aucun), $2 = état actuel.
_health_refusal() {
    local -a p=() c=() r=()
    local re pe
    re=$(_col 5) pe=$(_col 197)
    IFS=$'\t' read -ra c <<< "$2"
    [[ -n "$1" ]] && IFS=$'\t' read -ra p <<< "$1"
    # Tout bilan autre que PASSED (FAILED, « IMPENDING FAILURE » en SAS…) bloque
    [[ "${c[0]}" != PASSED && "${c[0]}" != NA ]] && r+=("bilan SMART ${c[0]}")
    is_uint "${c[$pe]:-}" && (( 10#${c[$pe]} > 0 )) && r+=("${c[$pe]} secteur(s) en attente")
    is_uint "${p[$re]:-}" && is_uint "${c[$re]:-}" && (( 10#${c[$re]} > 10#${p[$re]} )) \
        && r+=("secteurs réalloués ${p[$re]} → ${c[$re]} (${SMART_GUARD_DAYS} derniers jours)")
    (( ${#r[@]} > 0 )) || return 0
    local msg; printf -v msg '%s, ' "${r[@]}"
    printf '%s\n' "${msg%, }"
}

# Garde-fou : pas d'écritures massives sur un disque qui se dégrade. Compare à
# l'historique de --sante (_health_baseline) sans l'écrire : c'est --sante qui le tient.
check_disk_health() {
    local dev rec reason rc=0
    local -a opts=()
    dev=$(disk_device "$1")
    # Simulation : rien ne sera écrit, inutile de réveiller un disque en veille
    is_true "$DRY_RUN" && opts=(-n standby)
    rec=$(_health_read "$dev" "${opts[@]}") || rc=$?
    if (( rc == 2 )); then
        warn "$dev en veille : santé non vérifiée (simulation, disque non réveillé)"
        return 0
    elif (( rc != 0 )); then
        warn "Santé SMART de $dev non vérifiable : poursuite"
        return 0
    fi
    local serial="${rec%%$'\t'*}" ref=""
    # Sans numéro de série, pas d'historique propre à ce disque (comme --sante)
    [[ "$serial" == NA ]] || ref=$(_health_baseline "$(_health_file "$serial")")
    reason=$(_health_refusal "$ref" "${rec#*$'\t'}")
    if [[ -z "$reason" ]]; then
        ok "Santé SMART de $dev : aucune dégradation bloquante"
    elif is_true "$DRY_RUN"; then
        warn "Disque en mauvaise santé ($reason) : simulation seulement, poursuite"
    elif is_true "$FORCE_HEALTH"; then
        warn "Disque en mauvaise santé ($reason) : forcé par --force-sante"
    else
        err "Défragmentation refusée : $reason. Sauvegardez ce disque plutôt que d'y écrire massivement (--force-sante pour passer outre)."
        return 1
    fi
    return 0
}
