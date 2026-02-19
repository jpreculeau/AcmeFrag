#!/bin/bash
################################################################################
# CONFIGURATION CENTRALISÉE - AcmeFrag (Multi-FS: XFS + EXT4)
# Tous les paramètres du programme sont définis ici
#
# Licence / License: GNU General Public License v3
# COMMERCIAL USE REQUIRES PAID LICENSE
# Copyright (C) 2026 [Jean-Philippe Reculeau]
# See LICENSE file for full details
################################################################################

# --- RÉPERTOIRE CIBLE ---
# Dossier cible par défaut si aucun n'est précisé au lancement
# Cette valeur sera modifiée par detect_available_disks() au chargement
DEFAULT_TARGET="/mnt/USB6To"
ORIGINAL_DEFAULT_TARGET="/mnt/USB6To"  # Conserve la valeur de base pour comparaison

# --- SYSTÈMES DE FICHIERS SUPPORTÉS ---
SUPPORTED_FS_TYPES="xfs ext4"  # Systèmes de fichiers acceptés

# --- SEUILS DE DÉFRAGMENTATION ---
# SEUIL D'INTELLIGENCE : Si un morceau (extent) fait déjà plus de 4 Go,
# inutile de fatiguer le disque pour le défragmenter
INTEL_THRESHOLD_MO=4096

# Seuil minimum d'extents pour traiter un fichier (défaut: 2)
DEFAULT_MIN_EXTENTS=2

# Limite pour le TOP 10 (nombre de fichiers à traiter)
DEFAULT_TOP_LIMIT=10

# --- FICHIERS DE SORTIE ---
# Création d'un nom de fichier CSV horodaté (ex: fragmentation_2026-02-19.csv)
DATE_STR=$(date +%Y-%m-%d)
OUTPUT_CSV="fragmentation_${DATE_STR}.csv"

# --- NETTOYAGE DES FICHIERS ANCIENS ---
# Nombre de jours avant suppression des anciens rapports
REPORT_MAX_AGE_DAYS=30

# --- FORMATS D'AFFICHAGE ---
# Largeur maximale pour le nom de fichier dans les logs
MAX_FILENAME_DISPLAY=45

# --- PROTECTION SSD ---
# Les SSDs ne doivent PAS être défragmentés (usure, "wear leveling")
ALLOW_SSD_DEFRAG="false"  # Ne JAMAIS changer à true sans comprendre les risques!

# --- OPTIONS D'EXÉCUTION (par défaut) ---
# Ces variables peuvent être modifiées à la volée par le script principal via
# des arguments (ex: --dry-run, --force-ssd). Les valeurs par défaut sont
# définies ici pour centraliser la configuration.
DRY_RUN="false"
FORCE_SSD="false"

# --- SURVEILLANCE / SÉCURITÉ EN TEMPS RÉEL ---
# Intervalle en secondes pour les relevés SMART / température
MONITOR_INTERVAL_SEC=5

# SEUILS DE SECTEURS RÉALLOUÉS (SMART Attribute 5)
# 
# Référence industrielle :
#   0-5 : EXCELLENT (disque neuf)
#   6-20 : BON (usure normale)
#   21-50 : ALERTE (dégradation légère, remplacement en mois)
#   51-100 : CRITIQUE (dégradation rapide, remplacement en semaines)
#   >100 : DANGEREUX (imminent failure, risque perte de données)
#
# Cas d'usage NAS/Serveur critique (haute disponibilité) :
#   SMART_BAD_SECTOR_THRESHOLD=20
#   SMART_BAD_SECTOR_DRIFT_THRESHOLD=3
#
# Cas d'usage Multimédia personnel (USB 6To pour Torrents/Syncthing) ← ACTIF
#   SMART_BAD_SECTOR_THRESHOLD=50
#   SMART_BAD_SECTOR_DRIFT_THRESHOLD=5
#
# Cas d'usage Fin de vie / Test :
#   SMART_BAD_SECTOR_THRESHOLD=100
#   SMART_BAD_SECTOR_DRIFT_THRESHOLD=10
#
SMART_BAD_SECTOR_THRESHOLD=50
SMART_BAD_SECTOR_DRIFT_THRESHOLD=5

# SEUILS DE TEMPÉRATURE (en °C)
# Disque USB tends à chauffer rapidement lors de défragmentation intensive
DISK_TEMP_THRESHOLD_C=60
# Raspberry Pi CPU peut atteindre rapidement 85°C sous charge
SYSTEM_TEMP_THRESHOLD_C=85

# Si true, le script arrête automatiquement les actions lors d'alerte critique
AUTO_STOP_ON_ALERT="true"

# --- AFFICHAGE DYNAMIQUE ---
# Nombre de lignes réservées en haut de l'écran pour la zone de surveillance
MONITOR_DISPLAY_LINES=6
# --- OUTILS SYSTÈME REQUIS ---
# Détectés automatiquement selon le FS, mais vous pouvez personnaliser ici
# (Laisser vide = détection automatique)
CUSTOM_SCAN_TOOL=""      # Laisser vide pour auto (xfs_bmap ou filefrag)
CUSTOM_DEFRAG_TOOL=""    # Laisser vide pour auto (xfs_fsr ou e4defrag)
CUSTOM_FSINFO_TOOL=""    # Laisser vide pour auto (xfs_db ou tune2fs)


# ==============================================================================
# DÉTECTION ET SÉLECTION DU RÉPERTOIRE CIBLE
# ==============================================================================

# Détecte les disques disponibles et retourne la liste
detect_available_disks() {
	local available_disks=()
	
	# Utiliser 'df' pour détecter les disques montés pertinents
	# Filtre sur les systèmes de fichiers supportés (xfs, ext4)
	while IFS= read -r line; do
		local mount_point=$(echo "$line" | awk '{print $NF}')
		local fs_type=$(echo "$line" | awk '{print $(NF-1)}')
		
		# Vérifier si c'est un FS supporté et accessible en écriture
		if [[ "$SUPPORTED_FS_TYPES" =~ $fs_type ]] && [ -w "$mount_point" ] 2>/dev/null; then
			available_disks+=("$mount_point")
		fi
	done < <(df -t xfs -t ext4 2>/dev/null)
	
	echo "${available_disks[@]}"
}

# Prompt interactif pour sélectionner le répertoire cible
prompt_target_directory() {
	local -a available_disks=($(detect_available_disks))
	
	if [ ${#available_disks[@]} -eq 0 ]; then
		echo ""
		echo "⚠️  Aucun disque pertinent détecté"
		echo "📝 Saisissez manuellement le chemin du répertoire cible :"
		read -p "   Chemin > " custom_path
		if [ -d "$custom_path" ] && [ -w "$custom_path" ]; then
			echo "$custom_path"
		else
			echo ""
			echo "❌ Le chemin n'existe pas ou n'est pas accessible en écriture : $custom_path"
			return 1
		fi
	else
		echo ""
		echo "📦 Disques détectés :"
		for i in "${!available_disks[@]}"; do
			echo "   $((i + 1)). ${available_disks[$i]}"
		done
		echo "   C. Entrer un chemin personnalisé"
		echo ""
		read -p "🔍 Sélectionnez un disque [1-$((${#available_disks[@]}))] ou [C] : " choice
		
		if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#available_disks[@]} ]; then
			echo "${available_disks[$((choice - 1))]}"
		elif [[ "$choice" =~ ^[Cc]$ ]]; then
			echo ""
			echo "📝 Saisissez le chemin du répertoire cible :"
			read -p "   Chemin > " custom_path
			if [ -d "$custom_path" ] && [ -w "$custom_path" ]; then
				echo "$custom_path"
			else
				echo ""
				echo "❌ Le chemin n'existe pas ou n'est pas accessible en écriture : $custom_path"
				return 1
			fi
		else
			echo ""
			echo "❌ Choix invalide"
			return 1
		fi
	fi
}

# --------------------------------------------------------------------------------
# Validation de la configuration et valeurs par défaut sécurisées
# S'assure que les seuils critiques sont numériques et raisonnables pour éviter des
# comportements non désirés (ex: INTEL_THRESHOLD_MO=0 qui bloquerait tout).
# Appeler `validate_config` après le source du fichier de config.
validate_config() {
	# INTEL_THRESHOLD_MO : doit être un entier >= 1. Valeur par défaut recommandée = 4096
	if ! [[ "$INTEL_THRESHOLD_MO" =~ ^[0-9]+$ ]] || [ "$INTEL_THRESHOLD_MO" -lt 1 ]; then
		echo "\n   ⚠️  INTEL_THRESHOLD_MO invalide ou trop faible: réinitialisation à 4096 Mo"
		INTEL_THRESHOLD_MO=4096
	fi

	# DEFAULT_MIN_EXTENTS : doit être >= 2
	if ! [[ "$DEFAULT_MIN_EXTENTS" =~ ^[0-9]+$ ]] || [ "$DEFAULT_MIN_EXTENTS" -lt 2 ]; then
		echo "\n   ⚠️  DEFAULT_MIN_EXTENTS invalide: réinitialisation à 2"
		DEFAULT_MIN_EXTENTS=2
	fi

	# DEFAULT_TOP_LIMIT : doit être >= 1
	if ! [[ "$DEFAULT_TOP_LIMIT" =~ ^[0-9]+$ ]] || [ "$DEFAULT_TOP_LIMIT" -lt 1 ]; then
		echo "\n   ⚠️  DEFAULT_TOP_LIMIT invalide: réinitialisation à 10"
		DEFAULT_TOP_LIMIT=10
	fi

	# REPORT_MAX_AGE_DAYS : doit être >= 1
	if ! [[ "$REPORT_MAX_AGE_DAYS" =~ ^[0-9]+$ ]] || [ "$REPORT_MAX_AGE_DAYS" -lt 1 ]; then
		echo "\n   ⚠️  REPORT_MAX_AGE_DAYS invalide: réinitialisation à 30"
		REPORT_MAX_AGE_DAYS=30
	fi

	# ALLOW_SSD_DEFRAG : normaliser à "true" ou "false"
	if [ "${ALLOW_SSD_DEFRAG,,}" = "true" ]; then
		ALLOW_SSD_DEFRAG="true"
	else
		ALLOW_SSD_DEFRAG="false"
	fi

	return 0
}
