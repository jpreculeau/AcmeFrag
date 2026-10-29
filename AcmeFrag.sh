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

readonly ACMEFRAG_VERSION="3.1.0"
# readlink -f : fonctionne aussi via un lien symbolique (/usr/local/bin/acmefrag)
ACMEFRAG_HOME="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
readonly ACMEFRAG_HOME
readonly ACMEFRAG_SELF="${ACMEFRAG_HOME}/AcmeFrag.sh"

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
    (défaut : ${ACMEFRAG_HOME}/reports).

SÉCURITÉS
    Refus si : cible sur le FS racine, FS non XFS/EXT4, montage en lecture seule,
    SSD (sauf --force-ssd), autre instance en cours, disque en mauvaise santé :
    bilan SMART autre que PASSED, secteurs en attente, réalloués en hausse sur
    SMART_GUARD_DAYS jours d'historique --sante (sauf --force-sante ;
    avertissement seul en --dry-run). Fichiers modifiés depuis moins
    de MIN_FILE_AGE_MIN minutes ignorés (téléchargement / synchro en cours).
    Tâche bridée par défaut : nice 19 + E/S « idle ».

CODES DE SORTIE
    0 OK · 1 erreur · 2 usage · 3 refus sécurité · 4 déjà en cours ·
    5 arrêt par la surveillance · 130 interruption (Ctrl+C) · 143 arrêt (SIGTERM)
    --sante : 0 pas de nouvelle dégradation · 6 alerte · 7 mesure impossible
    (SMART indisponible, disque en veille ou non monté). Dernière ligne :
    « BILAN SANTÉ : … »
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
# dans un dossier qui est déjà le sien (jamais récursif, jamais à travers un lien).
give_reports_back() {
    is_uint "${SUDO_UID:-}" && [[ -d "${REPORT_DIR:-}" && ! -L "$REPORT_DIR" ]] || return 0
    [[ "$(stat -c %u -- "$REPORT_DIR")" == "$SUDO_UID" ]] || return 0
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
    [[ -L "$1" || ( -e "$1" && ! -f "$1" ) ]] && die "$EXIT_REFUSED" "Journal refusé (lien symbolique ou fichier spécial) : $1"
    # Couleurs à l'écran seulement : retirées de la copie écrite dans le fichier
    exec > >(tee >(LC_ALL=C sed -u $'s/\e\\[[0-9;]*m//g' >> "$1")) 2>&1
}

# En root, ne charger que du code qu'aucun autre compte (hors utilisateur sudo)
# ne peut modifier : il serait exécuté avec tous les droits.
load_modules() {
    local m f
    for f in "$ACMEFRAG_SELF" "${ACMEFRAG_HOME}/config.sh" "${ACMEFRAG_HOME}"/lib/*.sh; do
        root_may_use "$f" || die "$EXIT_REFUSED" \
            "Refus : $f est modifiable par un autre compte que root ou l'utilisateur sudo (voir README, « Sécurité »)."
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
    trap cleanup EXIT
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
require_report_dir() {
    mkdir -p -- "$REPORT_DIR"
    root_may_use "$REPORT_DIR" || die "$EXIT_REFUSED" \
        "Dossier de rapports refusé : $REPORT_DIR est modifiable par un autre compte que root ou l'utilisateur sudo."
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
