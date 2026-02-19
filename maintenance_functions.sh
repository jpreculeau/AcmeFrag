#!/bin/bash
################################################################################
# FONCTIONS DE MAINTENANCE - AcmeFrag (Support XFS + EXT4)
#
# Licence / License: GNU General Public License v3
# COMMERCIAL USE REQUIRES PAID LICENSE
# Copyright (C) 2026 [Jean-Philippe Reculeau]
# See LICENSE file for full details
################################################################################

# Affiche le menu de maintenance interactif
run_maintenance() {
    local target_dir="$1"
    local output_csv="$2"
    local dry_run_mode="${DRY_RUN:-false}"
    
    while true; do
        # Afficher l'état du mode dry run
        local dry_run_status="❌ DÉSACTIVÉ"
        if [ "$dry_run_mode" = "true" ]; then
            dry_run_status="✅ ACTIVÉ"
        fi
        
        echo ""
        echo "=============================================================================="
        echo "---   🔧 MENU DE MAINTENANCE"
        echo "=============================================================================="
        echo ""
        echo "Mode Dry Run: $dry_run_status"
        echo ""
        echo "1. Défragmenter le TOP 10 (fichiers les plus fragmentés)"
        echo "2. Défragmenter avec un seuil personnalisé d'extents"
        echo "3. Analyser l'état du disque (simple analyse)"
        echo "4. Afficher le rapport TOP 10"
        echo "5. Analyser l'espace libre"
        echo "6. Nettoyer les anciens rapports"
        echo "7. Basculer le mode Dry Run (actuellement: $dry_run_status)"
        echo "8. Quitter"
        echo ""
        read -p "🔍 Sélectionnez une option [1-8]: " choice
        
        case "$choice" in
            1)
                echo ""
                echo "⚙️ Défragmentation du TOP 10 en cours..."
                echo ""
                process_csv_rows "$DEFAULT_TOP_LIMIT" "$DEFAULT_MIN_EXTENTS" "$INTEL_THRESHOLD_MO" "$output_csv" "$target_dir" "$dry_run_mode"
                ;;
            2)
                handle_custom_threshold_defrag "$output_csv" "$target_dir" "$dry_run_mode"
                ;;
            3)
                echo ""
                echo "📊 Analyse de l'état du disque avec propositions d'actions..."
                echo ""
                analyze_and_propose_actions "$target_dir" "$output_csv" "$dry_run_mode"
                ;;
            4)
                display_top_10 "$output_csv"
                ;;
            5)
                display_free_space_status "$target_dir"
                ;;
            6)
                clean_old_reports
                echo "✅ Nettoyage terminé"
                ;;
            7)
                # Basculer le mode dry run (mettre à jour la variable globale DRY_RUN)
                if [ "$dry_run_mode" = "true" ]; then
                    dry_run_mode="false"
                    DRY_RUN="false"
                    export DRY_RUN
                    echo ""
                    echo "⚠️  Mode Dry Run DÉSACTIVÉ - Les opérations modifieront les fichiers !"
                else
                    dry_run_mode="true"
                    DRY_RUN="true"
                    export DRY_RUN
                    echo ""
                    echo "✅ Mode Dry Run ACTIVÉ - Les opérations seront simulées"
                fi
                ;;
            8)
                echo -e "\n✋ Bye Bye!\n"
                break
                ;;
            *)
                echo -e "\n   ❌ Erreur : Choix invalide. Veuillez choisir 1-8.\n"
                ;;
        esac
    done
}

# Traite la défragmentation avec seuil personnalisé
handle_custom_threshold_defrag() {
    local output_csv="$1"
    local target_dir="$2"
    local dry_run_mode="${3:-${DRY_RUN:-false}}"
    
    echo ""
    read -p "🔍 Nombre minimum d'extents [5]: " threshold
    threshold=${threshold:-5}
    
    # Valider que c'est un nombre
    if ! [[ "$threshold" =~ ^[0-9]+$ ]]; then
        echo -e "\n   ❌ Erreur : '$threshold' n'est pas un nombre valide"
        return 1
    fi
    
    if [ "$threshold" -lt 2 ]; then
        echo -e "\n   ❌ Erreur : Le seuil minimum est 2"
        return 1
    fi
    
    echo ""
    echo "⚙️ Défragmentation de tous les fichiers avec >= $threshold extents..."
    echo ""
    process_csv_rows 0 "$threshold" "$INTEL_THRESHOLD_MO" "$output_csv" "$target_dir" "$dry_run_mode"
}

# Affiche des informations détaillées sur un fichier fragmenté
show_file_details() {
    local filepath="$1"
    local fs_type
    
    echo ""
    echo "📄 Détails du fichier: $filepath"
    echo "───────────────────────────────────"
    
    # Taille et permissions
    ls -lh "$filepath" | awk '{print "Taille: " $5 " | Permissions: " $1 " | Modifié: " $6 " " $7 " " $8}'
    
    # FS Type
    fs_type=$(detect_filesystem_type "$(dirname "$filepath")")
    echo "🗄 Type FS: $fs_type"
    
    # Fragmentation
    case "$fs_type" in
        xfs)
            echo "Extents XFS:"
            sudo xfs_bmap -v "$filepath" 2>/dev/null | grep -E "^\s*[0-9]" | wc -l
            ;;
        ext4)
            echo "Fragmentation EXT4:"
            sudo filefrag -v "$filepath" 2>/dev/null | head -5
            ;;
    esac
}

# Effectue une analyse complète du disque et propose des actions
analyze_and_propose_actions() {
    local target_dir="$1"
    local output_csv="$2"
    local dry_run_mode="${3:-${DRY_RUN:-false}}"
    
    # Effectuer le scan
    if ! scan_filesystem "$target_dir" "$output_csv"; then
        echo "❌ L'analyse a échoué."
        return 1
    fi
    
    # Afficher le TOP 10
    display_top_10 "$output_csv"
    
    # Afficher l'analyse de l'espace libre
    display_free_space_status "$target_dir"
    
    # Analyser le niveau de fragmentation
    local top_extents
    top_extents=$(tail -n +2 "$output_csv" | sort -t ';' -k2,2rn | head -1 | cut -d ';' -f2)
    
    echo ""
    echo "=============================================================================="
    echo "---   📊 ANALYSE ET RECOMMANDATIONS"
    echo "=============================================================================="
    
    if [ -z "$top_extents" ] || [ "$top_extents" -lt 5 ]; then
        echo ""
        echo "✅ Excellent ! Le système de fichiers n'est pas fragmenté."
        echo "   Fragmentation très faible : aucune défragmentation nécessaire."
        echo ""
    elif [ "$top_extents" -lt 20 ]; then
        echo ""
        echo "⚠️  Fragmentation légère détectée."
        echo "   Niveau: $top_extents extents (TOP fichier)"
        echo "   Recommandation: Défragmentation optionnelle"
        echo ""
    else
        echo ""
        echo "❌ Fragmentation importante détectée !"
        echo "   Niveau: $top_extents extents (TOP fichier)"
        echo "   Recommandation: Défragmentation vivement conseillée"
        echo ""
    fi
    
    # Proposer les actions
    while true; do
        echo "---   🎯 ACTIONS PROPOSÉES"
        echo ""
        echo "1. Défragmenter le TOP 10 (fichiers les plus fragmentés)"
        echo "2. Défragmenter avec un seuil personnalisé d'extents"
        echo "3. Sélectionner des fichiers spécifiques à défragmenter"
        echo "4. Ne rien faire et revenir au menu"
        echo ""
        read -p "🔍 Choisissez une action [1-4]: " action_choice
        
        case "$action_choice" in
            1)
                echo ""
                echo "⚙️ Défragmentation du TOP 10 en cours..."
                echo ""
                process_csv_rows "$DEFAULT_TOP_LIMIT" "$DEFAULT_MIN_EXTENTS" "$INTEL_THRESHOLD_MO" "$output_csv" "$target_dir" "$dry_run_mode"
                break
                ;;
            2)
                echo ""
                read -p "🔍 Nombre minimum d'extents [5]: " threshold
                threshold=${threshold:-5}
                
                if ! [[ "$threshold" =~ ^[0-9]+$ ]] || [ "$threshold" -lt 2 ]; then
                    echo -e "\n   ❌ Erreur : Seuil invalide"
                    continue
                fi
                
                echo ""
                echo "⚙️ Défragmentation de tous les fichiers avec >= $threshold extents..."
                echo ""
                process_csv_rows 0 "$threshold" "$INTEL_THRESHOLD_MO" "$output_csv" "$target_dir" "$dry_run_mode"
                break
                ;;
            3)
                echo ""
                echo "📋 Fichiers les plus fragmentés disponibles :"
                echo "───────────────────────────────────────────────"
                tail -n +2 "$output_csv" | sort -t ';' -k2,2rn | head -20 | nl | \
                    awk -F';' '{printf "  %2d. [%s extents] %s\n", NR, $2, $4}'
                echo ""
                echo "Note: Entrez les numéros séparés par des espaces (ex: 1 3 5)"
                read -p "🔍 Sélectionnez les fichiers à défragmenter : " file_selection
                
                if [ -z "$file_selection" ]; then
                    echo "❌ Aucun fichier sélectionné"
                    continue
                fi
                
                # Traiter la sélection
                _defrag_selected_files "$output_csv" "$target_dir" "$dry_run_mode" "$file_selection"
                break
                ;;
            4)
                echo ""
                echo "✋ Retour au menu principal."
                break
                ;;
            *)
                echo -e "\n   ❌ Erreur : Choix invalide. Veuillez choisir 1-4.\n"
                ;;
        esac
    done
}

# Défragmente les fichiers sélectionnés
_defrag_selected_files() {
    local output_csv="$1"
    local target_dir="$2"
    local dry_run_mode="${3:-${DRY_RUN:-false}}"
    local file_selection="$4"
    
    echo ""
    echo "⚙️ Défragmentation des fichiers sélectionnés..."
    echo ""
    
    # Créer un tableau des fichiers du TOP 20
    local -a top_files
    mapfile -t top_files < <(tail -n +2 "$output_csv" | sort -t ';' -k2,2rn | head -20)
    
    if [ ${#top_files[@]} -eq 0 ]; then
        echo "❌ Aucun fichier trouvé."
        return 1
    fi
    
    # Traiter les fichiers sélectionnés
    local file_count=0
    for num in $file_selection; do
        # Conversion du numéro en index (1-based to 0-based)
        if [ "$num" -gt 0 ] && [ "$num" -le ${#top_files[@]} ]; then
            local line="${top_files[$((num-1))]}"
            IFS=';' read -r size extents folder name fullpath <<< "$line"
            
            if [ -f "$fullpath" ]; then
                echo "📄 Traitement: $name ($extents extents, $size)"
                if [ "$dry_run_mode" = "true" ]; then
                    echo "   [DRY RUN] Défragmentation simulée"
                else
                    if declare -f execute_defrag &> /dev/null; then
                        execute_defrag "$fullpath" "$extents" "$size" "$INTEL_THRESHOLD_MO" "$OUTPUT_CSV" "$target_dir" "$dry_run_mode"
                    else
                        echo "   ❌ Fonction execute_defrag non disponible"
                    fi
                fi
                ((file_count++))
            fi
        fi
    done
    
    if [ "$file_count" -eq 0 ]; then
        echo "❌ Aucun fichier valide sélectionné."
        return 1
    fi
    
    echo ""
    echo "✅ Défragmentation de $file_count fichier(s) terminée"
}

# Valide un seuil d'extents
validate_extent_threshold() {
    local threshold="$1"
    
    if ! [[ "$threshold" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    
    if [ "$threshold" -lt 2 ]; then
        return 1
    fi
    
    return 0
}
