# shellcheck shell=bash
################################################################################
# OUTILS COMMUNS - AcmeFrag
# Journalisation, codes de sortie, détection FS / disque, mesure des extents.
# Source unique : aucune de ces fonctions ne doit être redéfinie ailleurs.
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Jean-Philippe Reculeau — voir LICENSE
################################################################################

# --- Codes de sortie ---------------------------------------------------------
readonly EXIT_OK=0
readonly EXIT_ERROR=1
readonly EXIT_USAGE=2
readonly EXIT_REFUSED=3     # vérification de sécurité refusée
readonly EXIT_LOCKED=4      # une autre instance tourne déjà
readonly EXIT_ALERT=5       # arrêt demandé par le module de surveillance
readonly EXIT_INTERRUPTED=130

readonly MIB=1048576

# --- Couleurs (désactivées hors terminal ou si NO_COLOR est défini) ----------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_RED=$'\e[31m' C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m' C_BLUE=$'\e[34m' C_RESET=$'\e[0m'
else
    C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_RESET=''
fi

readonly RULE='=============================================================================='

log()   { printf '%s\n' "$*"; }
ok()    { printf '   %s✅ %s%s\n' "$C_GREEN" "$*" "$C_RESET"; }
warn()  { printf '   %s⚠️  %s%s\n' "$C_YELLOW" "$*" "$C_RESET"; }
err()   { printf '   %s❌ %s%s\n' "$C_RED" "$*" "$C_RESET" >&2; }
die()   { local code="$1"; shift; err "$*"; exit "$code"; }
title() { printf '\n%s\n---   %s\n%s\n' "$RULE" "$*" "$RULE"; }

is_uint() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }
is_true() { [[ "${1,,}" == "true" ]]; }

# Taille lisible (octets -> "2.4G"). numfmt fait partie de coreutils.
human_size() { numfmt --to=iec --format='%.1f' "$1" 2>/dev/null || printf '%sB' "$1"; }

# --- Système de fichiers -----------------------------------------------------
# Toutes ces fonctions acceptent n'importe quel chemin situé DANS le montage.
fs_type()   { findmnt -no FSTYPE -T "$1" 2>/dev/null | head -n1; }
fs_source() { findmnt -no SOURCE -T "$1" 2>/dev/null | head -n1; }
fs_target() { findmnt -no TARGET -T "$1" 2>/dev/null | head -n1; }
fs_options(){ findmnt -no OPTIONS -T "$1" 2>/dev/null | head -n1; }

# Espace disponible en octets sur le FS qui contient $1
fs_avail_bytes() { df -B1 --output=avail "$1" 2>/dev/null | tail -n1 | tr -d ' '; }

# Disque physique portant la partition (ex: /dev/sda1 -> sda, nvme0n1p2 -> nvme0n1)
parent_disk() {
    local src="$1" pk
    pk=$(lsblk -no PKNAME "$src" 2>/dev/null | head -n1)
    [[ -n "$pk" ]] || pk=$(basename "$src")
    printf '%s\n' "$pk"
}

# "ssd", "hdd" ou "unknown"
disk_kind() {
    local disk rota
    disk=$(parent_disk "$(fs_source "$1")")
    [[ "$disk" == nvme* ]] && { echo ssd; return 0; }
    rota=$(cat "/sys/block/${disk}/queue/rotational" 2>/dev/null || true)
    case "$rota" in
        0) echo ssd ;;
        1) echo hdd ;;
        *) echo unknown ;;
    esac
}

# --- Fragmentation -----------------------------------------------------------
# Convertit la sortie de `filefrag` ("CHEMIN: N extents found") en "N<TAB>CHEMIN".
# Robuste aux ": " dans les noms (on ancre sur la fin de ligne).
parse_filefrag() {
    awk '{
        if (match($0, /: [0-9]+ extents? found$/)) {
            path = substr($0, 1, RSTART - 1)
            n = substr($0, RSTART + 2); sub(/ .*/, "", n)
            printf "%s\t%s\n", n, path
        }
    }'
}

# Nombre d'extents d'un fichier (vide si illisible)
file_extents() {
    filefrag "$1" 2>/dev/null | parse_filefrag | cut -f1
}

# Âge du fichier en minutes depuis la dernière modification
file_age_min() {
    local mtime
    mtime=$(stat -c %Y "$1" 2>/dev/null) || return 1
    echo $(( ( $(date +%s) - mtime ) / 60 ))
}
