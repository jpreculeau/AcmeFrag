# shellcheck shell=bash
################################################################################
# VÉRIFICATIONS DE SÉCURITÉ - AcmeFrag (XFS + EXT4 + protection SSD)
# Chaque check renvoie 0 (OK) ou 1 (refus) et explique pourquoi.
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Jean-Philippe Reculeau — voir LICENSE
################################################################################

readonly SUPPORTED_FS_TYPES=(xfs ext4)

is_supported_fs() {
    local fs="$1" s
    for s in "${SUPPORTED_FS_TYPES[@]}"; do [[ "$fs" == "$s" ]] && return 0; done
    return 1
}

# Outils nécessaires selon le FS ("xfs" ou "ext4")
required_tools_for() {
    case "$1" in
        xfs)  echo "filefrag findmnt lsblk flock numfmt xfs_fsr" ;;
        ext4) echo "filefrag findmnt lsblk flock numfmt e4defrag" ;;
    esac
}

check_directory_exists() {
    [[ -d "$1" ]] && return 0
    err "Le dossier $1 n'existe pas."
    return 1
}

check_filesystem_type() {
    local fs
    fs=$(fs_type "$1")
    if is_supported_fs "$fs"; then
        ok "Système de fichiers : ${fs^^} ($(fs_source "$1") monté sur $(fs_target "$1"))"
        return 0
    fi
    err "Système de fichiers '${fs:-inconnu}' non supporté (supportés : ${SUPPORTED_FS_TYPES[*]})."
    return 1
}

# Protège le disque système : si le disque externe est débranché, son point de montage devient
# un simple dossier de la racine — on ne doit surtout pas le « défragmenter ».
check_not_root_fs() {
    [[ "$(fs_source "$1")" != "$(fs_source /)" ]] && return 0
    if is_true "$ALLOW_ROOT_FS"; then
        warn "La cible est sur le FS racine (autorisé par ALLOW_ROOT_FS)."
        return 0
    fi
    err "$1 est sur le système de fichiers racine (disque non monté ?). Refus."
    return 1
}

check_mounted_rw() {
    local opts
    opts=$(fs_options "$1")
    [[ ",$opts," == *",rw,"* ]] && return 0
    err "$(fs_target "$1") est monté en lecture seule."
    return 1
}

check_ssd_warning() {
    case "$(disk_kind "$1")" in
        hdd)
            ok "Disque mécanique (HDD) : défragmentation utile" ;;
        ssd)
            warn "Le disque est un SSD/NVMe : la défragmentation use la mémoire flash sans gain."
            if is_true "$ALLOW_SSD_DEFRAG" || is_true "$FORCE_SSD"; then
                warn "Forcé par --force-ssd / ALLOW_SSD_DEFRAG : à vos risques et périls."
            else
                err "Défragmentation refusée pour protéger le SSD (--force-ssd pour passer outre)."
                return 1
            fi ;;
        *)
            warn "Type de disque indéterminé : poursuite prudente." ;;
    esac
    return 0
}

check_required_tools() {
    local fs tool missing=()
    fs=$(fs_type "$1")
    for tool in $(required_tools_for "$fs"); do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done
    if (( ${#missing[@]} > 0 )); then
        err "Outils manquants : ${missing[*]} (Debian/RPi OS : sudo apt install xfsprogs e2fsprogs util-linux)"
        return 1
    fi
    ok "Outils requis présents"
    for tool in smartctl ionice; do
        command -v "$tool" >/dev/null 2>&1 || warn "Optionnel absent : $tool"
    done
    return 0
}

run_security_checks() {
    local target="$1"
    title "🔒 VÉRIFICATIONS DE SÉCURITÉ"
    check_directory_exists "$target" &&
    check_filesystem_type "$target" &&
    check_not_root_fs "$target" &&
    check_mounted_rw "$target" &&
    check_ssd_warning "$target" &&
    check_required_tools "$target" || return 1
    ok "TOUTES LES VÉRIFICATIONS PASSÉES"
}

# Montages XFS/EXT4 candidats (hors racine), un par ligne
detect_available_disks() {
    local root_src target src
    root_src=$(fs_source /)
    while read -r target src; do
        [[ "$src" == "$root_src" ]] && continue
        printf '%s\n' "$target"
    done < <(findmnt -rn -t xfs,ext4 -o TARGET,SOURCE 2>/dev/null)
}

# Menu de sélection : affichage sur stderr, résultat (chemin) sur stdout.
prompt_target_directory() {
    local -a disks=() ; local choice path
    mapfile -t disks < <(detect_available_disks)
    {
        echo ""
        if (( ${#disks[@]} > 0 )); then
            echo "📦 Montages XFS/EXT4 détectés :"
            for i in "${!disks[@]}"; do echo "   $((i + 1)). ${disks[$i]}"; done
        else
            echo "⚠️  Aucun montage XFS/EXT4 détecté hors racine."
        fi
        echo "   C. Saisir un chemin"
    } >&2
    read -rp "🔍 Votre choix : " choice
    if is_uint "$choice" && (( choice >= 1 && choice <= ${#disks[@]} )); then
        printf '%s\n' "${disks[$((choice - 1))]}"
    elif [[ "$choice" == [Cc] ]]; then
        read -rp "   Chemin > " path
        [[ -d "$path" ]] || { err "Chemin introuvable : $path"; return 1; }
        printf '%s\n' "$path"
    else
        err "Choix invalide"; return 1
    fi
}
