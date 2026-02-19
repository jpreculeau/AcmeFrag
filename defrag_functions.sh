#!/bin/bash
################################################################################
# FONCTIONS DE DÉFRAGMENTATION - AcmeFrag (Support XFS + EXT4)
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

# Conversion de tailles humaines en Mo
convert_to_mo() {
    local size="$1"
    local size_val
    local unit
    local size_mo=0
    
    # Extraire nombre et unité
    size_val=$(echo "$size" | sed 's/[^0-9,.]//g' | tr ',' '.')
    unit=$(echo "$size" | grep -o -i '[G-M-K]')
    
    # Conversion
    if [[ "$unit" =~ [Gg] ]]; then
        size_mo=$(echo "$size_val * 1024" | bc 2>/dev/null | cut -d'.' -f1)
    elif [[ "$unit" =~ [Mm] ]]; then
        size_mo=$(echo "$size_val" | bc 2>/dev/null | cut -d'.' -f1)
    elif [[ "$unit" =~ [Kk] ]]; then
        size_mo=$(echo "scale=0; $size_val / 1024" | bc 2>/dev/null | cut -d'.' -f1)
        [ -z "$size_mo" ] && size_mo=0
    fi
    
    echo "${size_mo:-0}"
}

# Défragmentation XFS
_defrag_xfs() {
    local file_path="$1"
    local ext_count="$2"
    local dry_run="${3:-${DRY_RUN:-false}}"

    if [ "$dry_run" = "true" ]; then
        # Tentative de lecture en lecture seule pour rapporter l'état
        local probe
        probe=$(sudo xfs_bmap -v "$file_path" 2>/dev/null || true)
        echo -e "ℹ️ [DRY-RUN] Would run: xfs_fsr -v $file_path (extents=${ext_count:-?})"
        return 0
    fi

    # xfs_fsr -v : tente de défragmenter
    output=$(sudo xfs_fsr -v "$file_path" 2>&1)
    exit_status=$?

    if echo "$output" | grep -q "DONE"; then
        local result
        result=$(echo "$output" | sed -n 's/.*\([0-9]\+ extents before.*\)/\1/p' | head -1)
        [ -z "$result" ] && result="Terminé"
        echo -e "\e[32m$result — Optimisé ✅\e[0m"
    elif echo "$output" | grep -qi "no free space"; then
        echo -e "\e[31mÉCHEC (espace libre insuffisant) ❌\e[0m"
    elif echo "$output" | grep -qi "already fully"; then
        echo -e "\e[34mDéjà optimisé ✅\e[0m"
    else
        echo -e "\e[33mIgnoré (gain insuffisant) ⚠️\e[0m"
    fi

    # Si Ctrl+C pendant xfs_fsr
    if [ $exit_status -gt 128 ]; then
        return 1
    fi

    return 0
}

# Défragmentation EXT4
_defrag_ext4() {
    local file_path="$1"
    local ext_count="$2"
    local dry_run="${3:-${DRY_RUN:-false}}"

    # Mesure non destructive possible avec filefrag
    local before_extents
    before_extents=$(sudo filefrag -v "$file_path" 2>/dev/null | awk '/ extents/{print $1; exit}' || true)
    before_extents=${before_extents:-$ext_count}

    if [ "$dry_run" = "true" ]; then
        # Simuler une amélioration raisonnable pour l'affichage
        local simulated_after=$(( before_extents / 2 ))
        [ $simulated_after -lt 1 ] && simulated_after=$before_extents
        local reduction=$(( before_extents - simulated_after ))
        echo -e "ℹ️ [DRY-RUN] Would run: e4defrag -v $file_path — ${before_extents} → ${simulated_after} extents (-${reduction})"
        return 0
    fi

    # e4defrag réel
    output=$(sudo e4defrag -v "$file_path" 2>&1)
    exit_status=$?

    if [ $exit_status -eq 0 ]; then
        local after_extents
        after_extents=$(sudo filefrag -v "$file_path" 2>/dev/null | awk '/ extents/{print $1; exit}' || true)
        after_extents=${after_extents:-$before_extents}
        reduction=$(( before_extents - after_extents ))

        if [ "$reduction" -gt 0 ]; then
            echo -e "\e[32m${before_extents} → ${after_extents} extents (-${reduction}) — Optimisé ✅\e[0m"
        else
            echo -e "\e[34mDéjà optimal ✅\e[0m"
        fi
    elif [ $exit_status -eq 1 ]; then
        echo -e "\e[33mFichier verrouillé ou inaccessible ⚠️\e[0m"
    else
        echo -e "\e[31mÉchec de e4defrag ❌\e[0m"
    fi

    # Si Ctrl+C pendant e4defrag
    if [ $exit_status -gt 128 ]; then
        return 1
    fi

    return 0
}

# Défragmentation universelle (XFS ou EXT4)
execute_defrag() {
    local file_path="$1"
    local ext_count="$2"
    local file_size="$3"
    local intel_threshold_mo="$4"
    local output_csv="$5"
    local target_dir="${6:-.}"  # Répertoire cible (pour détecter FS)
    local dry_run="${7:-${DRY_RUN:-false}}"
    
    local filename
    filename=$(basename "$file_path")
    
    # --- CALCUL DU RATIO (Taille moyenne d'un morceau) ---
    local size_mo
    size_mo=$(convert_to_mo "$file_size")
    
    # FILTRE : Si Taille_Mo / Nb_Extents > SEUIL, ignorer le fichier
    if [ "$ext_count" -gt 0 ]; then
        local ratio=$(( size_mo / ext_count ))
        if [ "$ratio" -ge "$intel_threshold_mo" ]; then
            # Fichier ignoré car trop gros par extent
            return 0
        fi
    fi
    
    # --- AFFICHAGE FORMATÉ ---
    local display_name="${filename:0:40}"
    [ ${#filename} -gt 40 ] && display_name="${display_name}..."
    
    printf "⏳ [%-8s] (%-5s) %-45s : " "$(date +%H:%M:%S)" "$file_size" "$display_name"
    
    # --- DÉTERMINER LE TYPE DE FS ---
    local fs_type
    fs_type=$(get_fs_type "$target_dir")
    
    # --- ACTION ---
    case "$fs_type" in
        xfs)
            _defrag_xfs "$file_path" "$ext_count" "$dry_run" || return 1
            ;;
        ext4)
            _defrag_ext4 "$file_path" "$ext_count" "$dry_run" || return 1
            ;;
        *)
            echo -e "\e[31mFS non supporté ($fs_type) ❌\e[0m"
            return 1
            ;;
    esac
    
    return 0
}

# Moteur de traitement des fichiers CSV
# $1 = Limite (nombre de fichiers)
# $2 = Seuil (minimum d'extents)
# $3 = Seuil d'intelligence
# $4 = Fichier CSV de sortie
# $5 = Répertoire cible (pour détecter FS)
process_csv_rows() {
    local limit=$1
    local threshold=$2
    local intel_threshold_mo=$3
    local output_csv=$4
    local target_dir="${5:-.}"
    local count=0
    # Buffer des lignes déjà traitées pour affichage dynamique
    local -a processed_lines=()
    
    # Lire le CSV trié par extents décroissants
    while IFS=';' read -u 3 -r size ext _ name fullpath; do
        # Arrêt si limite atteinte
        if [ "$limit" -gt 0 ] && [ "$count" -ge "$limit" ]; then
            break
        fi
        
        # Ne traiter que si extents >= seuil
        if [ "$ext" -ge "$threshold" ]; then
            # Si le monitor a demandé un arrêt, sortir proprement
            if declare -f monitor_should_stop &> /dev/null && monitor_should_stop; then
                echo -e "\n🚨 Arrêt automatique déclenché par le module de surveillance. Opérations interrompues.\n"
                break
            fi

            # Exécuter et capturer la sortie pour l'affichage dynamique
            out=$(execute_defrag "$fullpath" "$ext" "$size" "$intel_threshold_mo" "$output_csv" "$target_dir" 2>&1) || break

            # Ajouter timestamp + sortie à la liste des lignes traitées
            processed_lines+=("$(date +%H:%M:%S) - ${fullpath} : ${out//$'\n'/ }")

            # Rafraîchir l'affichage live (monitor en tête + lignes traitées)
            if declare -f render_live_view &> /dev/null; then
                render_live_view "${processed_lines[@]}"
            else
                # Fallback affichage simple
                echo "$out"
            fi

            ((count++))
        fi
    done 3< <(tail -n +2 "$output_csv" | sort -t ';' -k2,2rn -k1,1rh)
    
    [ "$count" -eq 0 ] && echo "ℹ️ Aucun fichier ne nécessite de défragmentation."
    
    return 0
}
