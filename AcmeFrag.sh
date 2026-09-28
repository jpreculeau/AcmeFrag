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

readonly ACMEFRAG_VERSION="3.0.0"
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

OPTIONS
    -s, --seuil N           Seuil intelligent en Mo par extent (défaut 4096,
                            0 = tout traiter)
    -n, --top N             Nb de fichiers éligibles traités en mode auto (défaut 10)
    -e, --min-extents N     Nb minimum d'extents pour traiter un fichier (défaut 2)
        --dry-run           Simule : aucune modification
        --force-ssd         Autorise un SSD (déconseillé)
        --no-monitor        Désactive la surveillance SMART / température
        --no-qos            Ne pas brider CPU/E-S (déconseillé pendant une lecture vidéo)
    -h, --help, --aide      Cette aide
    -V, --version           Version

EXEMPLES
    acmefrag /mnt/data --dry-run           # voir ce qui serait fait
    acmefrag /mnt/data/Films --auto        # cron : TOP 10 éligible
    acmefrag /mnt/data -s 0 --auto -n 50   # 50 fichiers, sans filtre

CONFIGURATION
    config.sh (défauts documentés), surchargés par /etc/acmefrag.conf puis
    local.conf à côté du script. Rapports et journaux : REPORT_DIR
    (défaut : ${ACMEFRAG_HOME}/reports).

SÉCURITÉS
    Refus si : cible sur le FS racine, FS non XFS/EXT4, montage en lecture seule,
    SSD (sauf --force-ssd), autre instance en cours. Fichiers modifiés depuis moins
    de MIN_FILE_AGE_MIN minutes ignorés (téléchargement / synchro en cours).
    Tâche bridée par défaut : nice 19 + E/S « idle ».

CODES DE SORTIE
    0 OK · 1 erreur · 2 usage · 3 refus sécurité · 4 déjà en cours ·
    5 arrêt par la surveillance · 130 interruption (Ctrl+C)
EOF
}

# ==============================================================================
# ARGUMENTS
# ==============================================================================
CLI_TARGET="" CLI_MODE="" CLI_SEUIL="" CLI_TOP="" CLI_MIN_EXT=""
CLI_DRY_RUN="" CLI_FORCE_SSD="" CLI_NO_MONITOR="" CLI_NO_QOS=""

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
    # Lancé via sudo : rendre les rapports à l'utilisateur (pas de fichiers root dans son dossier)
    if [[ -n "${SUDO_UID:-}" && -d "${REPORT_DIR:-}" ]]; then
        chown -R "${SUDO_UID}:${SUDO_GID:-$SUDO_UID}" -- "$REPORT_DIR" 2>/dev/null || true
    fi
}

on_interrupt() {
    trap - INT TERM
    printf '\n%s\n      Bye ! Bye ! (interrompu)\n%s\n' "$RULE" "$RULE"
    exit "$EXIT_INTERRUPTED"
}

# Verrou : une seule instance par dossier de rapports (cron + manuel)
acquire_lock() {
    exec {LOCK_FD}> "${REPORT_DIR}/.acmefrag.lock"
    flock -n "$LOCK_FD" || die "$EXIT_LOCKED" "Une autre instance d'AcmeFrag est en cours."
}

load_modules() {
    local m
    # shellcheck source=config.sh
    source "${ACMEFRAG_HOME}/config.sh"
    for m in security_checks security_monitor scan_functions defrag_functions \
             display_functions maintenance_functions; do
        # shellcheck source=/dev/null
        source "${ACMEFRAG_HOME}/lib/${m}.sh"
    done
}

# Choix de la cible : CLI, sinon DEFAULT_TARGET ; en interactif, proposer les
# montages détectés si aucune cible n'est configurée ou si elle n'est pas montée.
resolve_target() {
    local mode="$1" target="${CLI_TARGET:-$DEFAULT_TARGET}"
    if [[ -z "$CLI_TARGET" ]] \
       && [[ -z "$target" || ! -d "$target" || "$(fs_source "$target")" == "$(fs_source /)" ]]; then
        [[ "$mode" == interactive ]] || die "$EXIT_USAGE" \
            "Aucune cible : passez un DOSSIER ou définissez DEFAULT_TARGET dans local.conf (voir --help)"
        [[ -n "$target" ]] && warn "Cible par défaut indisponible : $target" >&2
        target=$(prompt_target_directory) || exit "$EXIT_USAGE"
    fi
    readlink -f -- "$target" 2>/dev/null || printf '%s\n' "$target"
}

main() {
    local ORIGINAL_ARGS=("$@")
    parse_args "$@"
    load_modules
    apply_cli_overrides
    validate_config || die "$EXIT_USAGE" "Configuration invalide"

    # Échouer tôt (avant sudo) si le mode auto n'a aucune cible
    if [[ -z "$CLI_TARGET" && -z "$DEFAULT_TARGET" && "$(resolve_mode)" == auto ]]; then
        die "$EXIT_USAGE" "Aucune cible : passez un DOSSIER ou définissez DEFAULT_TARGET dans local.conf (voir --help)"
    fi
    ensure_root "${ORIGINAL_ARGS[@]}"
    apply_qos "${ORIGINAL_ARGS[@]}"

    local mode target csv logf
    mode=$(resolve_mode)
    target=$(resolve_target "$mode")

    mkdir -p -- "$REPORT_DIR"
    csv="${REPORT_DIR}/fragmentation_$(date +%Y-%m-%d).csv"
    logf="${REPORT_DIR}/acmefrag_$(date +%Y-%m-%d).log"
    # Journal persistant : tout est dupliqué dans le fichier, rien n'est caché à l'écran.
    # `tee` est lancé AVANT le verrou pour ne pas en hériter (il survit un instant au script).
    exec > >(tee -a "$logf") 2>&1
    acquire_lock

    trap cleanup EXIT
    trap on_interrupt INT TERM
    trap 'err "Erreur inattendue ligne ${LINENO} (code $?) : ${BASH_COMMAND}"' ERR

    printf '%s\n   🚀 ACMEFRAG v%s — %s — %s\n%s\n' "$RULE" "$ACMEFRAG_VERSION" "$(date '+%Y-%m-%d %H:%M:%S')" "$mode" "$RULE"
    log "   Cible   : $target"
    log "   Seuil   : $( (( INTEL_THRESHOLD_MO == 0 )) && echo 'désactivé' || echo "${INTEL_THRESHOLD_MO} Mo/extent" )"
    log "   Dry-run : $DRY_RUN · QoS : $( [[ -n "${ACMEFRAG_QOS_APPLIED:-}" ]] && echo "nice ${QOS_NICE} + ionice -c${QOS_IO_CLASS}" || echo 'désactivée' )"

    run_security_checks "$target" || exit "$EXIT_REFUSED"

    if is_true "$MONITOR_ENABLE"; then
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
