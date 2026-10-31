#!/usr/bin/env bash
################################################################################
# ACMEFRAG - Défragmenteur intelligent XFS + EXT4
# Analyse la fragmentation fichier par fichier, ne traite que ce qui gêne vraiment
# la lecture, protège les SSD et surveille le disque (SMART / températures).
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Jean-Philippe Reculeau — voir LICENSE
################################################################################

set -Eeuo pipefail

# Locale fixe : tri, nombres et troncature des noms (par caractère, pas par octet)
# identiques sous cron, en terminal ou par sudo. C.UTF-8 si le système l'a.
_locales=$(locale -a 2>/dev/null || true)
if grep -qixE 'c\.utf-?8' <<< "$_locales"; then export LC_ALL=C.UTF-8; fi
unset _locales

readonly ACMEFRAG_VERSION="4.1.0"
# readlink -f : fonctionne aussi via un lien symbolique (/usr/local/bin/acmefrag)
ACMEFRAG_HOME="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
readonly ACMEFRAG_HOME
readonly ACMEFRAG_SELF="${ACMEFRAG_HOME}/AcmeFrag.sh"

# ==============================================================================
# CONFIANCE (le script tourne en root) — définie ici, avant tout chargement : un
# module modifiable par un autre compte ne doit jamais être exécuté, et c'est ce
# fichier qui en décide. Le contrôle de AcmeFrag.sh lui-même est forcément après
# coup : au lanceur (sudoers, cron) de garantir le point d'entrée.
# ==============================================================================
# Chemin $1 sûr pour root : lui et chacun de ses parents jusqu'à / ne sont pas
# des liens symboliques, appartiennent à root ou à l'uid $2, ne sont inscriptibles
# par le groupe que si ce groupe est root ou le gid $3, et par les autres que s'il
# s'agit d'un parent « sticky » de root (/tmp), jamais du chemin lui-même (sauf
# $4 = parent : $1 est l'ancêtre d'un dossier à créer). Sinon un autre compte
# pourrait y substituer un fichier.
path_trusted() {
    local p="$1" uid_ok="${2:-0}" gid_ok="${3:-0}" uid gid mode final=true
    [[ "${4:-}" == parent ]] && final=false
    [[ "$p" == /* ]] || return 1
    while :; do
        [[ -L "$p" ]] && return 1
        read -r uid gid mode < <(stat -c '%u %g %a' -- "$p" 2>/dev/null) || return 1
        [[ "$uid" == 0 || "$uid" == "$uid_ok" ]] || return 1
        if (( 8#$mode & 8#020 )) && [[ "$gid" != 0 && "$gid" != "$gid_ok" ]]; then return 1; fi
        if (( 8#$mode & 8#002 )) && { $final || ! (( 8#$mode & 8#1000 )) || [[ "$uid" != 0 ]]; }; then
            return 1
        fi
        [[ "$p" == / ]] && return 0
        p="${p%/*}"; p="${p:-/}"; final=false
    done
}

# Groupe $1 privé au compte $2 : aucun membre déclaré, et aucun autre compte
# ne l'a pour groupe principal (un groupe partagé comme « users » ne l'est pas).
# Sans getent, ou si la liste des comptes est illisible : groupe refusé.
_private_group() {
    local members others
    command -v getent >/dev/null 2>&1 || return 1
    members=$(getent group "$1" 2>/dev/null | cut -d: -f4)
    others=$(getent passwd 2>/dev/null | awk -F: -v g="$1" -v u="$2" '$4 == g && $3 != u { n++ } END { print n + 0 }') \
        || return 1                                        # pipefail : échec de getent
    [[ -z "$members" && "$others" == 0 ]]
}

# Comptes de confiance en root, "uid gid" : l'utilisateur sudo, et son groupe
# s'il lui est privé, seulement si AcmeFrag lui appartient (clone personnel
# lancé par sudo : il pourrait de toute façon tout faire en root) ; sinon root
# seul (installation root, cron, règle sudoers limitée à AcmeFrag).
trusted_owner() {
    local gid
    if [[ "${SUDO_UID:-}" =~ ^[0-9]+$ && "$(stat -c %u -- "$ACMEFRAG_SELF" 2>/dev/null)" == "$SUDO_UID" ]]; then
        gid="${SUDO_GID:-}"; [[ "$gid" =~ ^[0-9]+$ ]] && _private_group "$gid" "$SUDO_UID" || gid=0
        printf '%s %s\n' "$SUDO_UID" "$gid"
    else
        printf '0 0\n'
    fi
}

# Root peut-il charger, lire ou écrire $1 sans risque ($2 = parent : voir
# path_trusted) ? Hors root : toujours.
root_may_use() {
    (( EUID == 0 )) || return 0
    local uid gid
    read -r uid gid < <(trusted_owner)
    path_trusted "$1" "$uid" "$gid" "${2:-}"
}

# Raison d'un refus de confiance, pour les messages
readonly UNTRUSTED_WHY="n'appartient pas à un compte de confiance (root, ou l'utilisateur sudo si AcmeFrag lui appartient), est un lien symbolique ou est modifiable par un autre compte"

for _f in "$ACMEFRAG_SELF" "${ACMEFRAG_HOME}/lib/common.sh"; do
    root_may_use "$_f" || {
        printf '   ❌ Refus : %s %s (voir README, « Sécurité »).\n' "$_f" "$UNTRUSTED_WHY" >&2
        exit 8   # EXIT_UNTRUSTED (lib/common.sh, pas encore chargé)
    }
done
unset _f

# shellcheck source=lib/common.sh
source "${ACMEFRAG_HOME}/lib/common.sh"

# ==============================================================================
# AIDE
# ==============================================================================
print_help() {
    cat <<EOF
ACMEFRAG v${ACMEFRAG_VERSION} — Défragmenteur intelligent XFS + EXT4

UTILISATION
    acmefrag [DOSSIER] [OPTIONS]

    DOSSIER                 Dossier à traiter (dans un montage XFS/EXT4).
                            Sans argument : DEFAULT_TARGET (local.conf ou
                            /etc/acmefrag.conf) ; à défaut, choix interactif.

MODES
    --auto                  Scan + défragmentation des N premiers fichiers
                            éligibles, sans question (défaut hors terminal : cron)
    --interactive           Menu interactif (défaut dans un terminal)
    --sante                 Santé du disque qui porte DOSSIER (SMART, lecture
                            seule, sans réveiller un disque en veille) : évolution
                            depuis la dernière mesure et alertes. Pas de défragmentation.

OPTIONS
    -s, --seuil N           Seuil intelligent en Mo par extent (défaut 4096,
                            0 = tout traiter)
    -n, --top N             Nb de fichiers éligibles traités en mode auto (défaut 10)
    -e, --min-extents N     Nb minimum d'extents pour traiter un fichier (défaut 2)
        --dry-run           Simule : aucune modification
        --force-ssd         Autorise un SSD (déconseillé)
        --force-sante       Défragmente malgré une mauvaise santé SMART (déconseillé)
        --no-monitor        Désactive la surveillance SMART / température
        --no-qos            Ne pas brider CPU/E-S (déconseillé pendant une lecture vidéo)
    -h, --help, --aide      Cette aide
    -V, --version           Version

EXEMPLES
    acmefrag /mnt/data --dry-run           # voir ce qui serait fait
    acmefrag /mnt/data/Films --auto        # cron : TOP 10 éligible
    acmefrag /mnt/data -s 0 --auto -n 50   # 50 fichiers, sans filtre
    acmefrag /mnt/data --sante             # santé du disque (cron, orchestrateur)

CONFIGURATION
    config.sh (défauts documentés), surchargés par /etc/acmefrag.conf puis
    local.conf à côté du script. Rapports et journaux : REPORT_DIR
    (défaut : ${ACMEFRAG_HOME}/reports). Les variables d'environnement ne
    servent que si AcmeFrag est lancé directement en root (sudo les efface).

SÉCURITÉS
    Refus si : cible sur le FS racine (bind mount compris), FS non XFS/EXT4,
    montage en lecture seule, SSD ou type de disque indéterminé (sauf
    --force-ssd), autre instance en cours, disque en mauvaise santé : bilan
    SMART autre que PASSED (ou déjà enregistré par --sante), secteurs en
    attente, réalloués au-delà de SMART_BAD_SECTOR_THRESHOLD ou en hausse sur
    SMART_GUARD_DAYS jours d'historique --sante (sauf --force-sante ;
    avertissement seul en --dry-run). En root : refus du code, de la
    configuration ou du dossier de rapports qui n'appartiennent pas à un compte
    de confiance (root, ou l'utilisateur sudo si AcmeFrag lui appartient) ou
    qu'un autre compte peut modifier (code 8). Fichiers modifiés depuis moins de
    MIN_FILE_AGE_MIN minutes, liens symboliques et chemins hors de la cible
    ignorés. Surveillance : arrêt de l'outil en cours sur seuil critique.
    Tâche bridée par défaut : nice 19 + E/S « idle » (effectif avec BFQ).

CODES DE SORTIE
    0 OK · 1 erreur · 2 usage · 3 refus sécurité · 4 déjà en cours ·
    5 arrêt par la surveillance · 8 installation non sûre (code, configuration
    ou rapports modifiables par un autre compte) · 130 interruption (Ctrl+C) ·
    143 arrêt (SIGTERM)
    --sante : 0 pas de nouvelle dégradation · 6 alerte · 7 mesure impossible
    (SMART indisponible, disque en veille ou non monté) · 8 installation non
    sûre. Dernière ligne, sauf refus : « BILAN SANTÉ : … »
EOF
}

# ==============================================================================
# ARGUMENTS
# ==============================================================================
CLI_TARGET="" CLI_MODE="" CLI_SEUIL="" CLI_TOP="" CLI_MIN_EXT=""
CLI_DRY_RUN="" CLI_FORCE_SSD="" CLI_NO_MONITOR="" CLI_NO_QOS=""
CLI_HEALTH="" CLI_FORCE_HEALTH=""

_need_uint() {  # $1 = option, $2 = valeur
    is_uint "${2:-}" || die "$EXIT_USAGE" "$1 attend un entier (reçu : '${2:-}')"
}

parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            -h|--help|--aide)   print_help; exit "$EXIT_OK" ;;
            -V|--version)       echo "acmefrag ${ACMEFRAG_VERSION}"; exit "$EXIT_OK" ;;
            --auto)             CLI_MODE=auto ;;
            --interactive)      CLI_MODE=interactive ;;
            --dry-run)          CLI_DRY_RUN=true ;;
            --force-ssd)        CLI_FORCE_SSD=true ;;
            --sante)            CLI_HEALTH=true ;;
            --force-sante)      CLI_FORCE_HEALTH=true ;;
            --no-monitor)       CLI_NO_MONITOR=true ;;
            --no-qos)           CLI_NO_QOS=true ;;
            -s|--seuil)         _need_uint "$1" "${2:-}"; CLI_SEUIL="$2"; shift ;;
            -n|--top)           _need_uint "$1" "${2:-}"; CLI_TOP="$2"; shift ;;
            -e|--min-extents)   _need_uint "$1" "${2:-}"; CLI_MIN_EXT="$2"; shift ;;
            --)                 shift; break ;;
            -*)                 die "$EXIT_USAGE" "Option inconnue : $1 (voir --help)" ;;
            *)  [[ -z "$CLI_TARGET" ]] || die "$EXIT_USAGE" "Un seul dossier cible accepté ($CLI_TARGET, $1)"
                CLI_TARGET="$1" ;;
        esac
        shift
    done
    if (( $# > 0 )); then
        [[ -z "$CLI_TARGET" && $# -eq 1 ]] || die "$EXIT_USAGE" "Arguments en trop : $*"
        CLI_TARGET="$1"
    fi
}

# Les options CLI priment sur la configuration
apply_cli_overrides() {
    [[ -n "$CLI_SEUIL" ]]      && INTEL_THRESHOLD_MO="$CLI_SEUIL"
    [[ -n "$CLI_TOP" ]]        && DEFAULT_TOP_LIMIT="$CLI_TOP"
    [[ -n "$CLI_MIN_EXT" ]]    && DEFAULT_MIN_EXTENTS="$CLI_MIN_EXT"
    [[ -n "$CLI_DRY_RUN" ]]    && DRY_RUN=true
    [[ -n "$CLI_FORCE_SSD" ]]  && FORCE_SSD=true
    [[ -n "$CLI_FORCE_HEALTH" ]] && FORCE_HEALTH=true
    [[ -n "$CLI_NO_MONITOR" ]] && MONITOR_ENABLE=false
    [[ -n "$CLI_NO_QOS" ]]     && QOS_ENABLE=false
    return 0
}

# Mode effectif : explicite, sinon interactif seulement si stdin est un terminal
resolve_mode() {
    if [[ -n "$CLI_MODE" ]]; then echo "$CLI_MODE"
    elif [[ -t 0 ]]; then echo interactive
    else echo auto
    fi
}

# ==============================================================================
# PRIVILÈGES ET QUALITÉ DE SERVICE
# ==============================================================================
# Tout le script tourne en root (une seule élévation, plus de `sudo` épars) puis
# se relance sous nice/ionice : xfs_fsr et e4defrag héritent du bridage.
ensure_root() {
    (( EUID == 0 )) && return 0
    command -v sudo >/dev/null 2>&1 || die "$EXIT_ERROR" "Droits root requis (sudo introuvable)."
    exec sudo -- "$ACMEFRAG_SELF" "$@"
}

apply_qos() {
    is_true "$QOS_ENABLE" || return 0
    [[ -n "${ACMEFRAG_QOS_APPLIED:-}" ]] && return 0
    export ACMEFRAG_QOS_APPLIED=1
    local -a prio=(nice -n "$QOS_NICE")
    command -v ionice >/dev/null 2>&1 && prio+=(ionice -c "$QOS_IO_CLASS")
    exec "${prio[@]}" "$ACMEFRAG_SELF" "$@"
}

# ==============================================================================
# CYCLE DE VIE
# ==============================================================================
cleanup() {
    stop_security_monitor 2>/dev/null || true
    (( ${#TMP_FILES[@]} == 0 )) || rm -f -- "${TMP_FILES[@]}"
    give_reports_back
}

# Lancé via sudo : rendre à l'utilisateur les rapports créés en root, seulement
# s'il est de confiance et dans un dossier qui est déjà le sien et que root a
# accepté (jamais récursif, jamais à travers un lien).
give_reports_back() {
    local uid
    is_uint "${SUDO_UID:-}" && [[ -d "${REPORT_DIR:-}" && ! -L "$REPORT_DIR" ]] || return 0
    read -r uid _ < <(trusted_owner)
    [[ "$uid" == "$SUDO_UID" && "$(stat -c %u -- "$REPORT_DIR")" == "$SUDO_UID" ]] || return 0
    root_may_use "$REPORT_DIR" || return 0
    find "$REPORT_DIR" -maxdepth 2 ! -uid "$SUDO_UID" \( -type f -o -type d \) \
        -exec chown -h -- "${SUDO_UID}:${SUDO_GID:-$SUDO_UID}" {} + 2>/dev/null || true
}

# Erreur non prévue (trap ERR) : la signaler et sortir en 1, quel que soit le code
# de la commande fautive (un 2 serait lu « usage »). $1 ligne, $2 code, $3 commande.
on_error() {
    err "Erreur inattendue ligne $1 (code $2) : $(printable "$3")"
    exit "$EXIT_ERROR"
}

# $1 = code de sortie (130 Ctrl+C, 143 SIGTERM)
on_interrupt() {
    trap - INT TERM
    [[ -z "${CHILD_PID:-}" ]] || kill -TERM "$CHILD_PID" 2>/dev/null || true
    printf '\n%s\n      Bye ! Bye ! (interrompu)\n%s\n' "$RULE" "$RULE"
    exit "$1"
}

# Verrou : une seule instance par dossier de rapports (cron + manuel). Pris sur
# le dossier lui-même, ouvert en lecture : aucun fichier créé ni tronqué en root.
acquire_lock() {
    command -v flock >/dev/null 2>&1 || die "$EXIT_ERROR" "flock introuvable (paquet util-linux)."
    exec {LOCK_FD}< "$REPORT_DIR"
    flock -n "$LOCK_FD" || die "$EXIT_LOCKED" "Une autre instance d'AcmeFrag est en cours."
}

# Journal persistant : tout est dupliqué dans le fichier, rien n'est caché à
# l'écran. Refus d'un lien symbolique : root ajouterait le journal à sa cible.
start_log() {
    [[ -L "$1" || ( -e "$1" && ! -f "$1" ) ]] && die "$EXIT_UNTRUSTED" "Journal refusé (lien symbolique ou fichier spécial) : $1"
    # Couleurs à l'écran seulement : retirées de la copie écrite dans le fichier
    exec > >(tee >(LC_ALL=C sed -u $'s/\e\\[[0-9;]*m//g' >> "$1")) 2>&1
}

# En root, ne charger que du code qu'aucun autre compte (hors utilisateur sudo)
# ne peut modifier : il serait exécuté avec tous les droits.
load_modules() {
    local m f
    local -a files=("${ACMEFRAG_HOME}/config.sh" "${ACMEFRAG_HOME}"/lib/*.sh)
    # Configuration sourcée par config.sh, si elle existe
    for f in "${ACMEFRAG_SYSTEM_CONF:-/etc/acmefrag.conf}" "${ACMEFRAG_HOME}/local.conf"; do
        [[ -e "$f" ]] && files+=("$f")
    done
    for f in "${files[@]}"; do
        root_may_use "$f" || die "$EXIT_UNTRUSTED" \
            "Refus : $f $UNTRUSTED_WHY (voir README, « Sécurité »)."
    done
    # shellcheck source=config.sh
    source "${ACMEFRAG_HOME}/config.sh"
    for m in security_checks disk_health security_monitor scan_functions defrag_functions \
             display_functions maintenance_functions; do
        # shellcheck source=/dev/null
        source "${ACMEFRAG_HOME}/lib/${m}.sh"
    done
}

# --sante : mesure courte, sans verrou ni journal (compatible avec une
# défragmentation en cours, qui ne fait que lire l'historique).
run_health_mode() {
    local target="${CLI_TARGET:-$DEFAULT_TARGET}" rc=0
    local ignored=""
    [[ -n "$CLI_DRY_RUN" ]] && ignored+=" --dry-run"
    [[ -n "$CLI_MODE" ]] && ignored+=" --$CLI_MODE"
    [[ -z "$ignored" ]] || warn "Ignoré avec --sante (lecture seule) :$ignored"
    printf '%s\n   🩺 ACMEFRAG v%s — santé du disque — %s\n%s\n' "$RULE" "$ACMEFRAG_VERSION" "$(date '+%Y-%m-%d %H:%M:%S')" "$RULE"
    if ! { check_directory_exists "$target" && check_not_root_fs "$target"; }; then
        _health_unavailable "cible $target absente ou disque non monté"
        exit "$EXIT_HEALTH_UNAVAILABLE"
    fi
    require_report_dir
    trap cleanup EXIT
    run_health_check "$target" || rc=$?
    exit "$rc"
}

# Choix de la cible : CLI, sinon DEFAULT_TARGET ; en interactif, proposer les
# montages détectés si aucune cible n'est configurée ou si elle n'est pas montée.
resolve_target() {
    local mode="$1" target="${CLI_TARGET:-$DEFAULT_TARGET}"
    if [[ -z "$CLI_TARGET" ]] \
       && [[ -z "$target" || ! -d "$target" || "$(fs_devno "$target")" == "$(fs_devno /)" ]]; then
        [[ "$mode" == interactive ]] || die "$EXIT_USAGE" \
            "Aucune cible : passez un DOSSIER ou définissez DEFAULT_TARGET dans local.conf (voir --help)"
        [[ -n "$target" ]] && warn "Cible par défaut indisponible : $target" >&2
        target=$(prompt_target_directory) || exit "$EXIT_USAGE"
    fi
    readlink -f -- "$target" 2>/dev/null || printf '%s\n' "$target"
}

# Dossier des rapports, créé au besoin ; refusé si un autre compte peut y
# substituer des fichiers (root y écrit : verrou, journal, CSV, historique).
# L'ancêtre existant est contrôlé AVANT de créer quoi que ce soit ; dans un
# dossier de l'utilisateur sudo, le dossier neuf lui est donné (ses rapports
# lui seront rendus).
require_report_dir() {
    local d="$REPORT_DIR" parent="${REPORT_DIR%/*}"
    while [[ ! -e "$d" ]]; do d="${d%/*}"; d="${d:-/}"; done
    if [[ "$d" != "$REPORT_DIR" ]]; then
        root_may_use "$d" parent || die "$EXIT_UNTRUSTED" "Dossier de rapports refusé : $d $UNTRUSTED_WHY."
    fi
    if [[ ! -e "$REPORT_DIR" ]]; then
        if is_uint "${SUDO_UID:-}" && [[ -d "${parent:-/}" && "$(stat -c %u -- "${parent:-/}")" == "$SUDO_UID" ]]; then
            install -d -m 0755 -o "$SUDO_UID" -g "${SUDO_GID:-$SUDO_UID}" -- "$REPORT_DIR"
        else
            mkdir -p -- "$REPORT_DIR"
        fi
    fi
    root_may_use "$REPORT_DIR" || die "$EXIT_UNTRUSTED" "Dossier de rapports refusé : $REPORT_DIR $UNTRUSTED_WHY."
}

main() {
    local ORIGINAL_ARGS=("$@")
    parse_args "$@"
    load_modules
    apply_cli_overrides
    validate_config || die "$EXIT_USAGE" "Configuration invalide"

    # Échouer tôt (avant sudo) si le mode auto n'a aucune cible ; sauf si la
    # configuration système, illisible avant sudo (0600), peut en définir une
    local sysconf="${ACMEFRAG_SYSTEM_CONF:-/etc/acmefrag.conf}"
    if [[ -z "$CLI_TARGET" && -z "$DEFAULT_TARGET" ]] && ! [[ -e "$sysconf" && ! -r "$sysconf" ]] \
       && [[ -n "$CLI_HEALTH" || "$(resolve_mode)" == auto ]]; then
        die "$EXIT_USAGE" "Aucune cible : passez un DOSSIER ou définissez DEFAULT_TARGET dans local.conf (voir --help)"
    fi
    ensure_root "${ORIGINAL_ARGS[@]}"
    apply_qos "${ORIGINAL_ARGS[@]}"
    [[ -n "$CLI_HEALTH" ]] && run_health_mode

    local mode target csv logf
    mode=$(resolve_mode)
    target=$(resolve_target "$mode")

    require_report_dir
    csv="${REPORT_DIR}/fragmentation_$(date +%Y-%m-%d).csv"
    logf="${REPORT_DIR}/acmefrag_$(date +%Y-%m-%d).log"
    # `tee` est lancé AVANT le verrou pour ne pas en hériter (il survit un instant au script).
    start_log "$logf"
    acquire_lock

    trap cleanup EXIT
    trap 'on_interrupt "$EXIT_INTERRUPTED"' INT
    trap 'on_interrupt "$EXIT_TERMINATED"' TERM
    trap 'on_error "${LINENO}" "$?" "${BASH_COMMAND}"' ERR

    printf '%s\n   🚀 ACMEFRAG v%s — %s — %s\n%s\n' "$RULE" "$ACMEFRAG_VERSION" "$(date '+%Y-%m-%d %H:%M:%S')" "$mode" "$RULE"
    log "   Cible   : $(printable "$target")"
    log "   Seuil   : $( (( INTEL_THRESHOLD_MO == 0 )) && echo 'désactivé' || echo "${INTEL_THRESHOLD_MO} Mo/extent" )"
    log "   Dry-run : $DRY_RUN · QoS : $( [[ -n "${ACMEFRAG_QOS_APPLIED:-}" ]] && echo "nice ${QOS_NICE} + ionice -c${QOS_IO_CLASS}" || echo 'désactivée' )"

    run_security_checks "$target" || exit "$EXIT_REFUSED"

    if monitor_wanted "$mode"; then
        start_security_monitor "$target"
    fi

    clean_old_reports
    scan_filesystem "$target" "$csv"
    display_top "$csv" "$DEFAULT_TOP_LIMIT"
    display_eligibility_summary "$csv"

    if [[ "$mode" == auto ]]; then
        title "🤖 MODE AUTOMATIQUE : ${DEFAULT_TOP_LIMIT} premiers fichiers éligibles"
        process_csv_rows "$DEFAULT_TOP_LIMIT" "$DEFAULT_MIN_EXTENTS" "$csv" "$target"
    else
        run_maintenance "$target" "$csv"
    fi

    display_session_summary
    display_free_space_status "$target"

    if is_true "$STOPPED_BY_MONITOR"; then
        err "Exécution interrompue par la surveillance (seuil critique atteint)."
        exit "$EXIT_ALERT"
    fi
    printf '\n%s\n      ✅ Maintenance terminée. Journal : %s\n%s\n' "$RULE" "$logf" "$RULE"
}

# Exécution directe uniquement (le fichier reste « sourçable » pour les tests)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
