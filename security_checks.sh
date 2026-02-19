#!/bin/bash
################################################################################
# VÉRIFICATIONS DE SÉCURITÉ - AcmeFrag (Support XFS + EXT4 + SSD Protection)
#
# Licence / License: GNU General Public License v3
# COMMERCIAL USE REQUIRES PAID LICENSE
# Copyright (C) 2026 [Jean-Philippe Reculeau]
# See LICENSE file for full details
################################################################################

# Détecte le type de système de fichiers
# Argument: $1 = cible directory
# Retourne: Le type de FS (xfs, ext4, etc.) ou "unknown"
detect_filesystem_type() {
    local target_dir="$1"
    
    # Méthode 1: statfs (plus fiable sur Raspberry Pi)
    local fs_type
    fs_type=$(stat -f -c %T "$target_dir" 2>/dev/null)
    
    # Si stat échoue, essayer df
    if [ -z "$fs_type" ]; then
        fs_type=$(df -T "$target_dir" 2>/dev/null | tail -1 | awk '{print $2}')
    fi
    
    echo "${fs_type:-unknown}"
}

# Détecte si le disque est un SSD ou un HDD
# Argument: $1 = target directory
# Retourne: "ssd" ou "hdd" ou "unknown"
detect_disk_type() {
    local target_dir="$1"
    local dev_path
    local rotational
    
    # Obtenir le chemin du device
    dev_path=$(lsblk -o NAME,MOUNTPOINT -J 2>/dev/null | grep -F "$target_dir" | grep -o 'nvme[^"]*\|sd[a-z]*' | head -1)
    
    # Si lsblk échoue, essayer avec df
    if [ -z "$dev_path" ]; then
        dev_path=$(df "$target_dir" 2>/dev/null | tail -1 | awk '{print $1}' | sed 's/[0-9]*$//')
        dev_path="${dev_path##*/}"  # Garder que le nom (sda, nvme0n1, etc.)
    fi
    
    if [ -z "$dev_path" ]; then
        echo "unknown"
        return 1
    fi
    
    # Vérifier si c'est un NVMe (toujours SSD)
    if [[ "$dev_path" =~ nvme ]]; then
        echo "ssd"
        return 0
    fi
    
    # Vérifier le flag rotational pour HDD vs SSD
    if [ -f "/sys/block/$dev_path/queue/rotational" ]; then
        rotational=$(cat "/sys/block/$dev_path/queue/rotational" 2>/dev/null)
        if [ "$rotational" = "0" ]; then
            echo "ssd"
            return 0
        elif [ "$rotational" = "1" ]; then
            echo "hdd"
            return 0
        fi
    fi
    
    echo "unknown"
    return 1
}

# Vérifie si le chemin fourni existe physiquement sur le système.
check_directory_exists() {
    local target_dir="$1"
    if [ ! -d "$target_dir" ]; then
        echo -e "\n   ❌ Erreur : Le dossier $target_dir n'existe pas."
        return 1
    fi
    return 0
}

# Vérifie si le dossier est un point de montage (un disque branché).
# C'est crucial : cela évite d'écrire par erreur sur le disque système
# si le disque externe s'est déconnecté.
check_mount_point() {
    local target_dir="$1"
    if ! mountpoint -q "$target_dir"; then
        echo -e "\n   ❌ Erreur : $target_dir n'est pas un point de montage actif."
        return 1
    fi
    return 0
}

# Vérifie le type de système de fichiers.
# Support de XFS (xfs_fsr, xfs_bmap, xfs_db)
# Support de EXT4 (e4defrag, filefrag, tune2fs)
check_filesystem_type() {
    local target_dir="$1"
    local fs_type
    local supported="false"
    
    fs_type=$(detect_filesystem_type "$target_dir")
    
    # Vérifier que le FS est dans la liste supportée
    case "$fs_type" in
        xfs)
            echo -e "\n   ✅ Système de fichiers détecté : XFS"
            supported="true"
            ;;
        ext4)
            echo -e "\n   ✅ Système de fichiers détecté : EXT4"
            supported="true"
            ;;
        *)
            echo -e "\n   ❌ Erreur : Le système de fichiers détecté est : $fs_type"
            echo "   Les formats supportés sont : XFS et EXT4"
            return 1
            ;;
    esac
    
    return 0
}

# NOUVELLE FONCTION: Vérification SSD
# Les SSDs ne doivent PAS être défragmentés (wear leveling, usure)
check_ssd_warning() {
    local target_dir="$1"
    local disk_type
    local allow_ssd_defrag="${ALLOW_SSD_DEFRAG:-false}"
    
    disk_type=$(detect_disk_type "$target_dir")
    
    if [ "$disk_type" = "ssd" ]; then
        echo -e "\n   ⚠️  ATTENTION : Le disque détecté est UN SSD (ou NVMe)"
        echo ""
        echo "   ⚠️  Les SSDs utilisent le \"wear leveling\" (distribution interne de l'usure)."
        echo "   La défragmentation tradicelle est:"
        echo "      • INUTILE (performance interne gérée par le contrôleur)"
        echo "      • DANGEREUSE (usure accélérée de la mémoire flash)"
        echo "      • NON RECOMMANDÉE par les fabricants"
        echo ""
        
        if [ "$allow_ssd_defrag" = "true" ]; then
            echo "   🚨 La défragmentation SSD est ACTIVÉE dans config.sh"
            echo "   Continuons à vos risques et périls..."
            sleep 2
        else
            echo "   ❌ La défragmentation est DÉSACTIVÉE pour protéger le SSD"
            return 1
        fi
    elif [ "$disk_type" = "hdd" ]; then
        echo -e "\n   ✅ Disque détecté : HDD (mécanique) - Défragmentation utile"
    else
        echo -e "\n   ⚠️  Type de disque : Impossible à déterminer"
        echo "   Continuation prudente (meilleures pratiques appliquées)"
    fi
    
    return 0
}

# Vérifie que les outils nécessaires sont disponibles
check_required_tools() {
    local target_dir="$1"
    local fs_type
    
    fs_type=$(detect_filesystem_type "$target_dir")
    
    case "$fs_type" in
        xfs)
            # Vérifier les outils XFS
            if ! command -v xfs_fsr &> /dev/null; then
                echo -e "\n   ❌ Erreur : xfs_fsr n'est pas installé"
                echo "      Sur Raspberry Pi: sudo apt install xfsprogs"
                return 1
            fi
            if ! command -v xfs_bmap &> /dev/null; then
                echo -e "\n   ❌ Erreur : xfs_bmap n'est pas installé"
                echo "      Sur Raspberry Pi: sudo apt install xfsprogs"
                return 1
            fi
            ;;
        ext4)
            # Vérifier les outils EXT4
            if ! command -v e4defrag &> /dev/null; then
                echo -e "\n   ❌ Erreur : e4defrag n'est pas installé"
                echo "      Sur Raspberry Pi: sudo apt install e2fsprogs"
                return 1
            fi
            # filefrag est inclus dans debugfs/e2fsprogs
            if ! command -v filefrag &> /dev/null; then
                echo -e "\n   ❌ Erreur : filefrag n'est pas installé"
                echo "      Sur Raspberry Pi: sudo apt install e2fsprogs"
                return 1
            fi
            ;;
    esac
    
    echo -e "\n   ✅ Tous les outils requis sont disponibles"
    return 0
}

# Fonction principale pour exécuter toutes les vérifications de sécurité
run_security_checks() {
    local target_dir="$1"
    
    echo ""
    echo "=============================================================================="
    echo "---   🔒 VÉRIFICATIONS DE SÉCURITÉ"
    echo "=============================================================================="
    
    check_directory_exists "$target_dir" || return 1
    check_mount_point "$target_dir" || return 1
    check_filesystem_type "$target_dir" || return 1
    check_ssd_warning "$target_dir" || return 1
    check_required_tools "$target_dir" || return 1
    
    echo -e "\n   ✅ TOUTES LES VÉRIFICATIONS PASSÉES"
    echo "=============================================================================="
    
    return 0
}
