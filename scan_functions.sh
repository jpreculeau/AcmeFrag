#!/bin/bash
################################################################################
# FONCTIONS DE SCAN - AcmeFrag (Support XFS + EXT4)
#
# Licence / License: GNU General Public License v3
# COMMERCIAL USE REQUIRES PAID LICENSE
# Copyright (C) 2026 [Jean-Philippe Reculeau]
# See LICENSE file for full details
################################################################################

# Détecte le type de FS (réutilise la fonction de security_checks.sh)
# Argument: $1 = répertoire cible
# Retourne: "xfs" ou "ext4"
get_fs_type() {
    # Soumettre que security_checks.sh a été sourced
    detect_filesystem_type "$1"
}

# Scanner spécifique XFS
# Crée un rapport CSV des fichiers fragmentés
_scan_xfs() {
    local target_dir="$1"
    local output_csv="$2"
    
    echo -e "\n---   📋 Utilisation de xfs_bmap pour le scan XFS"
    
    echo "Taille;Extents;Dossier;Nom;Chemin_Complet" > "$output_csv"
    
    sudo find "$target_dir" -type f -print0 | while IFS= read -r -d '' file; do
        # xfs_bmap : interroge les métadonnées XFS
        lines=$(sudo xfs_bmap "$file" 2>/dev/null | wc -l)
        
        # XFS retourne au moins 1 ligne (nom); si > 2 = fragmenté
        if [ "$lines" -gt 2 ]; then
            real_extents=$((lines - 1))
            size=$(du -h "$file" | cut -f1)
            dirname=$(dirname "$file")
            basename=$(basename "$file")
            
            echo "$size;$real_extents;$dirname;$basename;$file" >> "$output_csv"
            echo -n "."
        fi
    done
}

# Scanner spécifique EXT4
# Crée un rapport CSV des fichiers fragmentés
_scan_ext4() {
    local target_dir="$1"
    local output_csv="$2"
    
    echo -e "\n---   📋 Utilisation de filefrag pour le scan EXT4"
    
    echo "Taille;Extents;Dossier;Nom;Chemin_Complet" > "$output_csv"
    
    sudo find "$target_dir" -type f -print0 | while IFS= read -r -d '' file; do
        # filefrag : interroge les métadonnées EXT4
        # Format: "File: /path/file" ou "/path/file: X extents"
        output=$(sudo filefrag -v "$file" 2>/dev/null | grep -E "extents?$|invalid")
        
        if [ -z "$output" ]; then
            # Si filefrag échoue (permissions, etc.), avancer
            continue
        fi
        
        # Extraire le nombre d'extents
        # Format typique: "File has 5 extents:" ou "5 extents"
        extents=$(echo "$output" | head -1 | grep -o -E "[0-9]+" | head -1)
        
        if [ -z "$extents" ] || [ "$extents" -lt 2 ]; then
            continue
        fi
        
        # Récupérer la taille
        size=$(du -h "$file" | cut -f1)
        dirname=$(dirname "$file")
        basename=$(basename "$file")
        
        echo "$size;$extents;$dirname;$basename;$file" >> "$output_csv"
        echo -n "."
    done
}

# Scanner universel (XFS ou EXT4)
scan_filesystem() {
    local target_dir="$1"
    local output_csv="$2"
    local fs_type
    
    fs_type=$(get_fs_type "$target_dir")
    
    echo -e "\n=============================================================================="
    echo "---   🔍 Analyse de la fragmentation ($fs_type) en cours sur : $target_dir"
    echo "---   ⏳ Note : Cela peut prendre du temps selon le nombre de fichiers..."
    echo "=============================================================================="
    
    case "$fs_type" in
        xfs)
            _scan_xfs "$target_dir" "$output_csv"
            ;;
        ext4)
            _scan_ext4 "$target_dir" "$output_csv"
            ;;
        *)
            echo -e "\n   ❌ Type de FS non supporté : $fs_type"
            return 1
            ;;
    esac
    
    echo -e "\n\n✅ Rapport généré : $output_csv"
}

# Fonction pour nettoyer les anciens rapports CSV
clean_old_reports() {
    echo -e "\n---  🧹 Nettoyage des anciens rapports (plus de 30 jours) ---"
    
    # Chercher et supprimer les fichiers fragmentation_*.csv modifiés il y a plus de 30 jours
    find . -maxdepth 1 -name "fragmentation_*.csv" -type f -mtime +"${REPORT_MAX_AGE_DAYS:-30}" -delete
}
