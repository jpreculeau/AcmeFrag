#!/bin/bash
################################################################################
# ACMEFRAG - Défragmenteur Intelligent XFS + EXT4
# Version Multi-Filesystems avec Protection SSD
#
# Licence / License: GNU General Public License v3
# COMMERCIAL USE REQUIRES PAID LICENSE
# Copyright (C) 2026 [Jean-Philippe Reculeau]
# See LICENSE file for full details
################################################################################

set -euo pipefail
IFS=$'\n\t'

# ==============================================================================
# GESTION DU SIGNAL (Ctrl+C)
# ==============================================================================
trap "echo -e '\n==============================================================================\n      Bye ! Bye !\n==============================================================================\n'; exit" INT

# ==============================================================================
# CONFIGURATION ET VARIABLES
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Note: toutes les variables de configuration (seuils, options par défaut,
# noms de fichiers) sont centralisées dans `config.sh` et chargées via
# `load_modules` (qui source `config.sh`). Ne pas redéfinir de variables
# de configuration ici pour éviter les duplications.

# ==============================================================================
# CHARGEMENT DES MODULES
# ==============================================================================

load_modules() {
    # Liste minimale des modules requis ; on source directement les noms de base.
    local modules=(
        "config.sh"
        "security_checks.sh"
        "security_monitor.sh"
        "scan_functions.sh"
        "defrag_functions.sh"
        "display_functions.sh"
        "maintenance_functions.sh"
    )

    for module in "${modules[@]}"; do
        local candidate="${SCRIPT_DIR}/${module}"
        if [ -f "$candidate" ]; then
            # shellcheck source=/dev/null
            source "$candidate"
        else
            echo "❌ Module manquant : $candidate"
            exit 1
        fi
    done
}




# ==============================================================================
# MAIN
# ==============================================================================

main() {
    clear

    # --- Parsing des arguments & options ---
    # Positionnels : $1 = target_dir (optionnel), $2 = mode ("--auto" ou autre)
    TARGET_DIR="${1:-${DEFAULT_TARGET:-/mnt/HDD}}"
    MODE="${2:---auto}"

    # Options booléennes (par défaut issues de config.sh)
    DRY_RUN="${DRY_RUN:-false}"
    FORCE_SSD="${FORCE_SSD:-false}"
    for a in "$@"; do
        case "$a" in
            --dry-run)
                DRY_RUN="true"
                ;;
            --force-ssd)
                FORCE_SSD="true"
                ;;
        esac
    done

    export DRY_RUN FORCE_SSD

    # ==================================================================================
    # VÉRIFICATION DU RÉPERTOIRE CIBLE
    # ==================================================================================
    # Si l'utilisateur n'a pas changé le répertoire par défaut, le notifier et proposer
    # une alternative (détection automatique ou saisie manuelle)
    if [ "${TARGET_DIR}" = "${ORIGINAL_DEFAULT_TARGET}" ]; then
        echo ""
        echo "╔════════════════════════════════════════════════════════════════════════════╗"
        echo "║                     ⚠️  ATTENTION                                           ║"
        echo "╚════════════════════════════════════════════════════════════════════════════╝"
        echo ""
        echo "🔴 VOUS UTILISEZ LE RÉPERTOIRE PAR DÉFAUT : $ORIGINAL_DEFAULT_TARGET"
        echo ""
        echo "❗ Cela peut ne pas correspondre à votre configuration réelle."
        echo "   Veuillez vérifier ou modifier le chemin cible."
        echo ""
        echo "🔀 Options :"
        echo "   1. Sélectionner un disque détecté / Entrer un chemin personnalisé"
        echo "   2. Continuer avec $ORIGINAL_DEFAULT_TARGET (NON RECOMMANDÉ)"
        echo "   3. Annuler l'exécution"
        echo ""
        read -p "🔍 Votre choix [1-3] : " choice_target
        
        case "$choice_target" in
            1)
                echo ""
                echo "🔄 Sélection d'un répertoire cible..."
                if new_target=$(prompt_target_directory); then
                    TARGET_DIR="$new_target"
                    echo "✅ Répertoire cible défini à : $TARGET_DIR"
                else
                    echo "❌ Erreur lors de la sélection du répertoire."
                    exit 1
                fi
                ;;
            2)
                echo ""
                echo "⚠️  Poursuite avec le répertoire par défaut : $ORIGINAL_DEFAULT_TARGET"
                ;;
            3)
                echo ""
                echo "❌ Exécution annulée par l'utilisateur."
                exit 1
                ;;
            *)
                echo ""
                echo "❌ Choix invalide."
                exit 1
                ;;
        esac
    fi
    
    cat << 'EOF'
╔════════════════════════════════════════════════════════════════════════════╗
║                    🚀 ACMEFRAG v2.0                                        ║
║                 Défragmenteur Intelligent XFS + EXT4                      ║
║                    Protection SSD + Surveillance 🌡️                         ║
╚════════════════════════════════════════════════════════════════════════════╝
EOF
    
    echo ""
    echo "Target: $TARGET_DIR"
    echo "CSV Output: $OUTPUT_CSV"
    echo ""
    # Valider la configuration chargée (prévenir seuils non-sensiques comme 0)
    if declare -f validate_config &> /dev/null; then
        validate_config || { echo "❌ Configuration invalide"; exit 1; }
    fi
    
    # 1️⃣ VÉRIFICATIONS DE SÉCURITÉ
    echo "1️⃣  Vérifications de sécurité..."
    if ! run_security_checks "$TARGET_DIR"; then
        echo "❌ Les vérifications de sécurité ont échoué."
        exit 1
    fi

    # Démarrer la surveillance en temps réel (SMART / Températures)
    if declare -f start_security_monitor &> /dev/null; then
        start_security_monitor "$TARGET_DIR" || echo "⚠️ Impossible de démarrer le module de surveillance"
        # S'assurer que le monitor est arrêté proprement à la fin
        trap 'if declare -f stop_security_monitor >/dev/null 2>&1; then stop_security_monitor; fi; exit' EXIT
    else
        echo "⚠️ Module de surveillance absent : actions en cours sans monitoring"
    fi
    
    # 2️⃣ NETTOYAGE DES ANCIENS RAPPORTS
    echo ""
    echo "2️⃣  Nettoyage des anciens rapports..."
    clean_old_reports
    
    # 3️⃣ SCAN DU FILESYSTEM
    echo ""
    echo "3️⃣  Scan du système de fichiers..."
    if ! scan_filesystem "$TARGET_DIR" "$OUTPUT_CSV"; then
        echo "❌ Le scan a échoué."
        exit 1
    fi
    
    # 4️⃣ AFFICHAGE DU TOP 10
    echo ""
    echo "4️⃣  Résultats du scan..."
    display_top_10 "$OUTPUT_CSV"
    
    # 5️⃣ DÉTERMINER LE MODE DE DÉFRAGMENTATION
    echo ""
    echo "5️⃣  Mode de défragmentation..."
    
    if [ "$MODE" = "--auto" ]; then
        echo "🤖 Mode AUTOMATIQUE: défragmentation du TOP 10"
        process_csv_rows "$DEFAULT_TOP_LIMIT" "$DEFAULT_MIN_EXTENTS" "$INTEL_THRESHOLD_MO" "$OUTPUT_CSV" "$TARGET_DIR" "${DRY_RUN:-false}"
    else
        echo "❓ Mode INTERACTIF"
        
        # Afficher le menu maintenance (si disponible)
        if declare -f run_maintenance &> /dev/null; then
            run_maintenance "$TARGET_DIR" "$OUTPUT_CSV"
        else
            # Fallback sinon
            echo ""
            echo "🔀 Sélectionnez une action :"
            echo "   1. Défragmenter le TOP 10"
            echo "   2. Défragmenter avec seuil personnalisé"
            echo "   3. Quitter"
            echo ""
            read -p "🔍 Votre choix [1-3]: " choice
            
            case "$choice" in
                1)
                    echo ""
                    echo "⚙️ Défragmentation du TOP 10 en cours..."
                    echo ""
                    process_csv_rows "$DEFAULT_TOP_LIMIT" "$DEFAULT_MIN_EXTENTS" "$INTEL_THRESHOLD_MO" "$OUTPUT_CSV" "$TARGET_DIR" "${DRY_RUN:-false}"
                    ;;
                2)
                    echo ""
                    read -p "🔍 Nombre minimum d'extents [2]: " threshold
                    threshold=${threshold:-2}
                    echo ""
                    process_csv_rows 0 "$threshold" "$INTEL_THRESHOLD_MO" "$OUTPUT_CSV" "$TARGET_DIR" "${DRY_RUN:-false}"
                    ;;
                *)
                    echo -e "\n✋ Opération annulée.\n"
                    ;;
            esac
        fi
    fi
    
    # 6️⃣ AFFICHAGE DES STATS FINALES
    echo ""
    echo "6️⃣  Statistiques finales..."
    display_free_space_status "$TARGET_DIR"
    
    echo ""
    # Vérifier si arrêt automatique a eu lieu
    if [ -f "/tmp/acmefrag_monitor_stop" ]; then
        echo "⚠️  Exécution interrompue par le module de surveillance (seuil critique atteint)"
        echo "✅ Tâche complétée (arrêtée automatiquement)"
    else
        echo "✅ Tâche complétée avec succès!"
    fi
}

# ==============================================================================
# EXÉCUTION
# ==============================================================================

# ------------------------------------------------------------------------------
# AIDE / HELP
# Disponible en français (--aide) et en anglais (--help)
# ------------------------------------------------------------------------------
print_help() {
                cat <<'EOF'
╔════════════════════════════════════════════════════════════════════════════╗
║           ACMEFRAG v2.0 - Défragmenteur Intelligent XFS + EXT4            ║
║                   Avec surveillance SMART & température                    ║
╚════════════════════════════════════════════════════════════════════════════╝

UTILISATION (Français) :
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    ./AcmeFrag.sh [REPERTOIRE] [MODE] [OPTIONS]

    REPERTOIRE       Chemin cible (par défaut: /mnt/HDD depuis config.sh)
    MODE             --auto (automatique) ou interactif (par défaut)

    OPTIONS:
      --aide, --help   Affiche cette aide
      --dry-run        Simule sans modifier les fichiers
      --force-ssd      Force défragmentation sur SSD (⚠️ déconseillé)
      --interactive    Lance le menu principal interactif

EXEMPLES :
    ./AcmeFrag.sh                          # Mode interactif, répertoire par défaut
    ./AcmeFrag.sh /mnt/data --auto         # Scan + défrag automatique
    ./AcmeFrag.sh /mnt/data --dry-run      # Test sans modifications

CONFIGURATION :
    Éditez config.sh pour personnaliser :
    • MONITOR_INTERVAL_SEC       : Fréquence des relevés (secondes)
    • SMART_BAD_SECTOR_THRESHOLD : Seuil critique de secteurs défectueux
    • DISK_TEMP_THRESHOLD_C      : Température critique du disque (°C)
    • SYSTEM_TEMP_THRESHOLD_C    : Température critique du système (°C)
    • AUTO_STOP_ON_ALERT         : Arrêt automatique en cas d'alerte (true/false)

MODULES INTERNES :
    security_checks.sh      → Vérifications (FS, SSD, outils, permissions)
    security_monitor.sh     → Surveillance temps réel (SMART, température, arrêt auto)
    scan_functions.sh       → Analyse de fragmentation
    defrag_functions.sh     → Défragmentation avec monitoring
    display_functions.sh    → Affichage et rapports CSV
    maintenance_functions.sh → Menu interactif

SURVEILLANCE EN TEMPS RÉEL :
    🔒 Avant chaque fichier, le statut SMART et température s'affiche :
       🔒 MONITOR: bad_sectors=42 bad_drift=+2 disk_temp=55C system_temp=68C alerts=none

    Si un seuil est dépassé :
       🚨 Arrêt automatique déclenché par le module de surveillance

BONNES PRATIQUES :
    ✅ Lancer en heures creuses (peu d'I/O)
    ✅ Disposer d'au moins 10% d'espace libre
    ✅ Surveiller d'abord avec --dry-run
    ✅ Vérifier smartmontools et lm-sensors : sudo apt install smartmontools lm-sensors

════════════════════════════════════════════════════════════════════════════

USAGE (English) :
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    ./AcmeFrag.sh [DIRECTORY] [MODE] [OPTIONS]

    DIRECTORY        Target path (default: /mnt/HDD from config.sh)
    MODE             --auto (automatic) or interactive (default)

    OPTIONS:
      --help, --aide   Show this help message
      --dry-run        Simulate without modifying files
      --force-ssd      Force defrag on SSD (⚠️ not recommended)
      --interactive    Run main menu in interactive mode

EXAMPLES :
    ./AcmeFrag.sh                          # Interactive mode, default path
    ./AcmeFrag.sh /mnt/data --auto         # Auto scan + defrag
    ./AcmeFrag.sh /mnt/data --dry-run      # Test run without changes

CONFIGURATION :
    Edit config.sh to customize:
    • MONITOR_INTERVAL_SEC       : Check frequency (seconds)
    • SMART_BAD_SECTOR_THRESHOLD : Critical bad sector count
    • DISK_TEMP_THRESHOLD_C      : Disk critical temperature (°C)
    • SYSTEM_TEMP_THRESHOLD_C    : System critical temperature (°C)
    • AUTO_STOP_ON_ALERT         : Auto-stop on alert (true/false)

INTERNAL MODULES :
    security_checks.sh      → Initial checks (FS, SSD, tools, permissions)
    security_monitor.sh     → Real-time monitoring (SMART, temperature, auto-stop)
    scan_functions.sh       → Fragmentation analysis
    defrag_functions.sh     → Defragmentation with monitoring
    display_functions.sh    → Display and CSV reports
    maintenance_functions.sh → Interactive menu

REAL-TIME MONITORING :
    🔒 Before each file, SMART and temperature status displays:
       🔒 MONITOR: bad_sectors=42 bad_drift=+2 disk_temp=55C system_temp=68C alerts=none

    If a threshold is exceeded:
       🚨 Automatic stop triggered by security monitor

BEST PRACTICES :
    ✅ Run during off-peak hours (low I/O)
    ✅ Keep at least 10% free space
    ✅ Test first with --dry-run
    ✅ Install monitoring tools: sudo apt install smartmontools lm-sensors

════════════════════════════════════════════════════════════════════════════
EOF
                exit 0
}

# Parsing robuste des options via `getopt` (supporte les long options)
# - Traitement de --help/--aide en priorité
# - Flags : --dry-run, --force-ssd, --auto, --interactive
if ! TEMP_OPTS=$(getopt -o h --long help,aide,dry-run,force-ssd,auto,interactive -- "$@"); then
    echo "❌ Erreur lors de l'analyse des options"
    exit 1
fi
eval set -- "$TEMP_OPTS"

# Valeurs par défaut (peuvent être redéfinies par config.sh lors du source)
DRY_RUN="${DRY_RUN:-false}"
FORCE_SSD="${FORCE_SSD:-false}"
MODE="${MODE:---auto}"

positional=()
while true; do
    case "$1" in
        -h|--help|--aide)
            print_help
            ;;
        --dry-run)
            DRY_RUN="true"; shift
            ;;
        --force-ssd)
            FORCE_SSD="true"; shift
            ;;
        --auto)
            MODE="--auto"; shift
            ;;
        --interactive)
            MODE="--interactive"; shift
            ;;
        --)
            shift; break
            ;;
        *)
            break
            ;;
    esac
done

# Récupérer les arguments positionnels restants
while [ "$#" -gt 0 ]; do
    positional+=("$1")
    shift
done

# Charger les modules (config.sh va définir DEFAULT_TARGET etc.)
load_modules

# Déterminer TARGET_DIR et MODE en s'appuyant sur les valeurs de config
TARGET_DIR="${positional[0]:-${DEFAULT_TARGET:-/mnt/HDD}}"
MODE="${positional[1]:-${MODE:---auto}}"

export DRY_RUN FORCE_SSD TARGET_DIR MODE

# Appel principal
main "$TARGET_DIR" "$MODE"
