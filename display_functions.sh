#!/bin/bash
################################################################################
# FONCTIONS D'AFFICHAGE - AcmeFrag (Support XFS + EXT4)
#
# Licence / License: GNU General Public License v3
# COMMERCIAL USE REQUIRES PAID LICENSE
# Copyright (C) 2026 [Jean-Philippe Reculeau]
# See LICENSE file for full details
################################################################################

# Détecte le type de FS
# Argument: $1 = répertoire cible
# Retourne: "xfs" ou "ext4"
get_fs_type() {
    detect_filesystem_type "$1"
}

# Affiche le TOP 10 des fichiers les plus fragmentés
# $1 = Fichier CSV de sortie
display_top_10() {
    local output_csv="$1"
    
    echo -e "\n=============================================================================="
    echo "---   🏆 TOP 10 DES FICHIERS LES PLUS FRAGMENTÉS "
    echo "---   (Trié par : Nb Extents, puis par Taille de fichier)"
    echo "=============================================================================="
    
    printf "%-10s   %-10s   %-s\n" "EXTENTS" "TAILLE" "NOM DU FICHIER"
    echo "------------------------------------------------------------------------------"
    
    tail -n +2 "$output_csv" | sort -t ';' -k2,2rn -k1,1rh | head -n 10 | \
        awk -F';' '{printf "%-10s | %-10s | %-s\n", $2, $1, $4}'
    
    echo -e "\n=============================================================================="
}

# Analyse l'espace libre et affiche un résumé XFS
_display_free_space_xfs() {
    local target_dir="$1"
    local dev_path
    
    echo -e "\n---   ⏳ Analyse des métadonnées XFS (patience…)"
    
    dev_path=$(df "$target_dir" | tail -1 | awk '{print $1}')
    
    # Requête XFS pour l'espace libre
    stats_line=$(sudo xfs_db -r -c "freesp -s" "$dev_path" 2>/dev/null | grep "free blocks")
    
    if echo "$stats_line" | grep -q "average"; then
        avg_blocks=$(echo "$stats_line" | sed 's/.*average \([0-9]\+\).*/\1/')
        avg_size_mo=$((avg_blocks * 4 / 1024))
        
        echo -e "\n   Sur le disque $dev_path :"
        echo "   > Taille moyenne des zones vides : ~ $avg_size_mo Mo"
        
        if [ "$avg_size_mo" -gt 500 ]; then
            echo -e "\n   Excellent ✅ (Espace sain et continu)"
        elif [ "$avg_size_mo" -gt 100 ]; then
            echo "   Correct ⚠️ (Fragmentation légère de l'espace libre)"
        else
            echo -e "\n   Critique ❌ (Espace très haché : défragmentation conseillée)"
        fi
    else
        echo -e "\n   ⚠️ Info : Analyse impossible (le disque est peut-être verrouillé)."
    fi
}

# Analyse l'espace libre et affiche un résumé EXT4
_display_free_space_ext4() {
    local target_dir="$1"
    local dev_path
    
    echo -e "\n---   ⏳ Analyse des métadonnées EXT4 (patience…)"
    
    dev_path=$(df "$target_dir" | tail -1 | awk '{print $1}')
    
    # Récupérer les stats EXT4
    # -l = labels, affiche l'état du filesystem
    stats=$(sudo tune2fs -l "$dev_path" 2>/dev/null)
    
    if [ -n "$stats" ]; then
        # Extraire l'espace libre en blocs
        free_blocks=$(echo "$stats" | grep "Free blocks:" | awk '{print $3}')
        block_size=$(echo "$stats" | grep "Block size:" | awk '{print $3}')
        
        if [ -n "$free_blocks" ] && [ -n "$block_size" ]; then
            # Convertir en Mo: (blocs libres * taille_bloc) / 1024 / 1024
            free_mo=$((free_blocks * block_size / 1024 / 1024))
            
            echo -e "\n   Sur le disque $dev_path :"
            echo "   > Espace libre : ~ $free_mo Mo"
            
            # Taille totale
            total_blocks=$(echo "$stats" | grep "Block count:" | awk '{print $3}')
            if [ -n "$total_blocks" ]; then
                total_mo=$((total_blocks * block_size / 1024 / 1024))
                percent=$(( free_mo * 100 / total_mo ))
                echo "   > Pourcentage libre : $percent %"
                
                if [ "$percent" -gt 20 ]; then
                    echo -e "\n   Excellent ✅ (Espace sain)"
                elif [ "$percent" -gt 10 ]; then
                    echo "   Correct ⚠️ (Fragmentation légère)"
                else
                    echo -e "\n   Critique ❌ (Espace très limité : défragmentation réservée)"
                fi
            fi
        fi
    else
        echo -e "\n   ⚠️ Info : Analyse impossible (permissions insuffisantes)."
    fi
}

# Affiche l'état de santé de l'espace libre
# Adapte l'affichage au type de FS
display_free_space_status() {
    local target_dir="$1"
    local fs_type
    
    fs_type=$(get_fs_type "$target_dir")
    
    echo -e "\n=============================================================================="
    echo "---   📊 ÉTAT DE SANTÉ DE L'ESPACE LIBRE ($fs_type)"
    echo "=============================================================================="
    
    case "$fs_type" in
        xfs)
            _display_free_space_xfs "$target_dir"
            ;;
        ext4)
            _display_free_space_ext4 "$target_dir"
            ;;
        *)
            echo -e "\n   ❌ Type de FS non supporté : $fs_type"
            ;;
    esac
    
    echo -e "\n =============================================================================="
    echo "      ✅ Maintenance terminée."
    echo "=============================================================================="
}

# Affiche un résumé simpliste du CSV (alternative rapide)
display_csv_summary() {
    local output_csv="$1"
    
    if [ ! -f "$output_csv" ]; then
        echo -e "\n   ❌ Erreur : Fichier non trouvé: $output_csv"
        return 1
    fi
    
    local total_files
    local total_extents
    local avg_extents
    
    total_files=$(tail -n +2 "$output_csv" | wc -l)
    if [ "$total_files" -eq 0 ]; then
        echo "\n📊 Résumé du rapport:"
        echo "   • Aucun fichier fragmenté trouvé."
        return 0
    fi

    # Somme des extents, protéger contre les valeurs vides
    total_extents=$(tail -n +2 "$output_csv" | awk -F';' '{s+=$2} END{print s+0}')
    # Calculer la moyenne en évitant la division par zéro
    avg_extents=$(( total_extents / total_files ))

    echo ""
    echo "📊 Résumé du rapport:"
    echo "   • Fichiers fragmentés: $total_files"
    echo "   • Extents totaux: $total_extents"
    echo "   • Moyenne extents/fichier: $avg_extents"
}

# Affiche le bloc de surveillance (lecture du statut produit par security_monitor)
# Ce bloc est conçu pour être réimprimé en tête d'écran à chaque rafraîchissement.
render_monitor_block() {
    local status
    # Codes couleurs ANSI
    local NC="\033[0m"
    local RED="\033[31m"
    local YELLOW="\033[33m"
    local GREEN="\033[32m"
    local BLUE="\033[36m"

    # read_monitor_status est exporté par security_monitor.sh
    if declare -f read_monitor_status &> /dev/null; then
        status=$(read_monitor_status 2>/dev/null)
    else
        status=$(
            echo "timestamp: N/A"
            echo "device: N/A"
            echo "smart_available: false"
            echo "bad_sectors: N/A"
            echo "bad_drift: N/A"
            echo "disk_temp: N/A"
            echo "system_temp: N/A"
            echo "alerts: none"
        )
    fi

    # Extraire valeurs
    local timestamp="N/A" device="N/A" smart_available="false"
    local bad_sectors="N/A" bad_drift="N/A" disk_temp="N/A" system_temp="N/A" alerts="none"
    while IFS= read -r line; do
        key=${line%%:*}
        val=${line#*: }
        case "$key" in
            timestamp) timestamp="$val" ;;
            device) device="$val" ;;
            smart_available) smart_available="$val" ;;
            bad_sectors) bad_sectors="$val" ;;
            bad_drift) bad_drift="$val" ;;
            disk_temp) disk_temp="$val" ;;
            system_temp) system_temp="$val" ;;
            alerts) alerts="$val" ;;
        esac
    done <<< "$status"

    # Fonctions utilitaires de couleur selon seuils (config.sh variables utilisées)
    _color_for_bad_sectors() {
        local v=$1
        if ! [[ "$v" =~ ^[0-9]+$ ]]; then
            printf "%b%s%b" "$BLUE" "$v" "$NC"
            return
        fi
        local thr=${SMART_BAD_SECTOR_THRESHOLD:-100}
        if [ "$v" -ge "$thr" ]; then
            printf "%b%s%b" "$RED" "$v" "$NC"
        elif [ "$v" -ge $(( thr / 2 )) ]; then
            printf "%b%s%b" "$YELLOW" "$v" "$NC"
        else
            printf "%b%s%b" "$GREEN" "$v" "$NC"
        fi
    }

    _color_for_drift() {
        local v=$1
        if ! [[ "$v" =~ ^[0-9]+$ ]]; then
            printf "%b%s%b" "$BLUE" "$v" "$NC"
            return
        fi
        local thr=${SMART_BAD_SECTOR_DRIFT_THRESHOLD:-5}
        if [ "$v" -ge "$thr" ]; then
            printf "%b+%s%b" "$RED" "$v" "$NC"
        elif [ "$v" -ge $(( thr / 2 )) ]; then
            printf "%b+%s%b" "$YELLOW" "$v" "$NC"
        else
            printf "%b+%s%b" "$GREEN" "$v" "$NC"
        fi
    }

    _color_for_temp() {
        local v=$1
        local thr=$2
        if ! [[ "$v" =~ ^[0-9]+$ ]]; then
            printf "%b%s%b" "$BLUE" "$v" "$NC"
            return
        fi
        if [ "$v" -ge "$thr" ]; then
            printf "%b%s°C%b" "$RED" "$v" "$NC"
        elif [ "$v" -ge $(( thr - 10 )) ]; then
            printf "%b%s°C%b" "$YELLOW" "$v" "$NC"
        else
            printf "%b%s°C%b" "$GREEN" "$v" "$NC"
        fi
    }

    # Construire le bloc formaté avec couleurs
    echo "=============================================================================="
    echo "---   🔒 STATUT DE SÉCURITÉ (MONITOR)"
    echo "=============================================================================="
    printf "   %-16s : %s\n" "Horodatage" "$timestamp"
    printf "   %-16s : %s\n" "Périphérique" "$device"
    printf "   %-16s : %s\n" "SMART disponible" "$smart_available"
    printf "   %-16s : %s\n" "Secteurs réalloués" "$(_color_for_bad_sectors "$bad_sectors")"
    printf "   %-16s : %s\n" "Dérive (Δ)" "$(_color_for_drift "${bad_drift#*+}")"
    printf "   %-16s : %s\n" "Temp disque" "$(_color_for_temp "${disk_temp%[Cc]}" ${DISK_TEMP_THRESHOLD_C:-60})"
    printf "   %-16s : %s\n" "Temp système" "$(_color_for_temp "${system_temp%[Cc]}" ${SYSTEM_TEMP_THRESHOLD_C:-85})"
    if [ -n "$alerts" ] && [ "$alerts" != "none" ]; then
        printf "   %-16s : %b%s%b\n" "ALERTES" "$RED" "$alerts" "$NC"
    else
        printf "   %-16s : %b%s%b\n" "ALERTES" "$GREEN" "none" "$NC"
    fi
    echo "=============================================================================="
}

# Reconstruit l'écran : affiche en tête le bloc monitor, puis les lignes de traitement
# Usage: render_live_view <array_of_lines>
render_live_view() {
    # Effacer l'écran
    printf "\033[H\033[2J"

    # Afficher le bloc monitor
    render_monitor_block

    # Afficher les lignes traitées (arguments passés)
    echo ""
    echo "--- Fichiers traités ---"
    for line in "$@"; do
        echo "$line"
    done
}
