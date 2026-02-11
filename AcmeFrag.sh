#!/bin/bash
# Empêche le script de continuer si l'utilisateur appuie sur Ctrl+C
# Affiche un message d'adieu avant de fermer proprement
trap "echo -e '\n==============================================================================\n\n      Bye ! Bye !\n\n==============================================================================\n\n'; exit" INT

# ==============================================================================
# CONFIGURATION ET VARIABLES
# ==============================================================================

# Dossier cible par défaut si aucun n'est précisé au lancement
DEFAULT_TARGET="/mnt/HDD"
# ${1:-...} récupère le 1er argument du script, sinon utilise le défaut
TARGET_DIR="${1:-$DEFAULT_TARGET}"

# Création d'un nom de fichier CSV horodaté (ex: fragmentation_2026-27-08.csv)
DATE_STR=$(date +%Y-%m-%d)
OUTPUT_CSV="fragmentation_${DATE_STR}.csv"

# SEUIL D'INTELLIGENCE : Si un morceau de fichier (extent) fait déjà plus de 4 Go (4096 Mo),
# on considère qu'il est inutile de fatiguer le disque pour le défragmenter.
INTEL_THRESHOLD_MO=4096

# ==============================================================================
# FONCTION DE DÉFRAGMENTATION UNIFIÉE
# ==============================================================================
execute_defrag() {
    local file_path="$1"
    local ext_count="$2"
    local file_size="$3"
    local filename
    filename=$(basename "$file_path")
    
    # --- CALCUL DU RATIO (Taille moyenne d'un morceau) ---
    # On extrait le nombre (ex: 1.4) et l'unité (ex: G)
    local size_val
    size_val=$(echo "$file_size" | sed 's/[^0-9,.]//g' | tr ',' '.')
    local unit
    unit=$(echo "$file_size" | grep -o -i '[G-M]')
    local size_mo=0

    # Conversion en Mo pour pouvoir faire un calcul mathématique
    if [[ "$unit" =~ [Gg] ]]; then
        size_mo=$(echo "$size_val * 1024" | bc 2>/dev/null)
        size_mo=$(echo "$size_mo" | cut -d'.' -f1)
    elif [[ "$unit" =~ [Mm] ]]; then
        size_mo=$(echo "$size_val" | bc 2>/dev/null)
        size_mo=$(echo "$size_mo" | cut -d'.' -f1)
    fi

    # FILTRE : Si Taille_Mo / Nb_Extents > 4096 Mo, on quitte la fonction sans rien faire
    if [ "$ext_count" -gt 0 ]; then
        local ratio=$(( size_mo / ext_count ))
        if [ "$ratio" -ge "$INTEL_THRESHOLD_MO" ]; then
            # On peut décommenter la ligne suivante si on veut voir les fichiers ignorés
            # printf "⏳ [%-8s] (%-5s) %-40s : \e[34mDéjà optimal (Blocs > 4Go)\e[0m\n" "$(date +%H:%M:%S)" "$file_size" "${filename:0:40}"
            return 
        fi
    fi

    # --- AFFICHAGE FORMATÉ ---
    # On limite le nom à 40 caractères pour que les colonnes soient toujours alignées
    local display_name="${filename:0:40}"
    [ ${#filename} -gt 40 ] && display_name="${display_name}..."
    
    # %-45s force une largeur de 45 caractères, aligné à gauche
    printf "⏳ [%-8s] (%-5s) %-45s : " "$(date +%H:%M:%S)" "$file_size" "$display_name"
    
    # --- ACTION ---
    # xfs_fsr -v : tente de défragmenter. On capture la sortie (stdout + stderr)
    output=$(sudo xfs_fsr -v "$file_path" 2>&1)
    exit_status=$?

    if echo "$output" | grep -q "DONE"; then
        # On supprime tout ce qui suit le mot "DONE" (le chemin complet du fichier)
        local result
        result=$(echo "$output" | grep "extents before" | sed 's/DONE.*//; s/extents //g; s/  */ /g')
        echo -e "\e[32m$result ✅\e[0m"
    elif echo "$output" | grep -q "no free space"; then
        echo -e "\e[31mÉCHEC (Espace insuffisant) ❌\e[0m"
    elif echo "$output" | grep -q "already fully"; then
        echo -e "\e[34mDéjà optimisé ✅\e[0m"
    else
        echo "Ignoré (Gain insuffisant)"
    fi

    # Si le code de sortie > 128, c'est que l'utilisateur a fait Ctrl+C pendant xfs_fsr
    if [ $exit_status -gt 128 ]; then exit 1; fi
}

# ==============================================================================
# MOTEUR DE TRAITEMENT CSV
# ==============================================================================
# $1 = Limite (nombre de fichiers à traiter, 10 pour le TOP 10, 0 pour infini)
# $2 = Seuil (minimum d'extents requis pour traiter le fichier)
process_csv_rows() {
    local limit=$1      # 10 pour le TOP 10, 0 pour tout
    local threshold=$2  # Seuil minimum d'extents (ex: 5)
    local count=0

    # On lit le CSV via le descripteur 3 pour ne pas interférer avec les commandes internes
    # sort -k2,2rn : trie par le nombre d'extents (colonne 2) du plus grand au plus petit
    while IFS=';' read -u 3 -r size ext _ name fullpath; do
        # On s'arrête si on a atteint la limite fixée (si > 0)
        if [ "$limit" -gt 0 ] && [ "$count" -ge "$limit" ]; then break; fi
        
        # On ne traite que si le fichier a au moins X extents
        if [ "$ext" -ge "$threshold" ]; then
            execute_defrag "$fullpath" "$ext" "$size"
            ((count++))
        fi
    done 3< <(tail -n +2 "$OUTPUT_CSV" | sort -t ';' -k2,2rn -k1,1rh)
    
    [ "$count" -eq 0 ] && echo "ℹ️ Aucun fichier ne nécessite de défragmentation."
}


# ==============================================================================
# VÉRIFICATIONS DE SÉCURITÉ (À placer impérativement avant le SCAN)
# ==============================================================================

# 1. Vérifie si le chemin fourni existe physiquement sur le système.
# Le test [ ! -d ... ] renvoie "vrai" si le répertoire n'existe PAS.
if [ ! -d "$TARGET_DIR" ]; then
    echo -e "\n   ❌ Erreur : Le dossier $TARGET_DIR n'existe pas."
    exit 1
fi

# 2. Vérifie si le dossier est un point de montage (un disque branché).
# C'est crucial : cela évite d'écrire par erreur sur le disque système
# si le disque externe s'est déconnecté.
if ! mountpoint -q "$TARGET_DIR"; then
    echo -e "\n   ❌ Erreur : $TARGET_DIR n'est pas un point de montage actif."
    exit 1
fi

# 3. Vérifie le type de système de fichiers.
# xfs_fsr et xfs_bmap ne fonctionnent QUE sur du XFS.
# stat -f -c %T récupère le nom du système de fichiers (ex: xfs, ext4, ntfs).
fs_type=$(stat -f -c %T "$TARGET_DIR")
if [ "$fs_type" != "xfs" ]; then
    echo -e "\n   ❌ Erreur : Le système de fichiers détecté est ($fs_type)."
    echo "   XFS est requis pour utiliser xfs_fsr."
    exit 1
fi

# ==============================================================================
# PHASE 1 : SCAN DU SYSTÈME DE FICHIERS
# ==============================================================================

echo -e "\n=============================================================================="
echo "---   🔍 Analyse de la fragmentation XFS en cours sur : $TARGET_DIR"
echo "---   Note : Cela peut prendre du temps selon le nombre de fichiers..."
echo "=============================================================================="

# On prépare le fichier CSV. L'entête permet de s'y retrouver si on l'ouvre dans Excel.
# Le symbole '>' écrase le fichier s'il existait déjà.
echo "Taille;Extents;Dossier;Nom;Chemin_Complet" > "$OUTPUT_CSV"

# Utilisation de 'find -print0' : 
# C'est la méthode la plus sûre pour gérer les noms de fichiers contenant des espaces,
# des crochets ou des apostrophes (très fréquents dans les noms de vidéos).
# Le caractère 'NULL' (\0) sert de séparateur universel.
sudo find "$TARGET_DIR" -type f -print0 | while IFS= read -r -d '' file; do
    
    # xfs_bmap : interroge les métadonnées XFS pour voir comment le fichier est stocké.
    # On compte le nombre de lignes renvoyées par la commande.
    # 2>/dev/null : ignore les erreurs si un fichier est inaccessible ou verrouillé.
    lines=$(sudo xfs_bmap "$file" 2>/dev/null | wc -l)
    
    # Logique XFS : xfs_bmap renvoie toujours au moins 1 ligne (le nom du fichier).
    # S'il y a plus de 2 lignes, cela signifie que le fichier est en plusieurs morceaux (extents).
    if [ "$lines" -gt 2 ]; then
        # On calcule le nombre réel de morceaux (Lignes totales - 1 ligne d'entête)
        real_extents=$((lines - 1))
        
        # du -h : récupère la taille "humaine" (ex: 1.4G, 500M)
        # cut -f1 : on ne garde que la première colonne (la taille)
        size=$(du -h "$file" | cut -f1)
        
        # dirname/basename : séparent le chemin d'accès du nom du fichier
        dirname=$(dirname "$file")
        basename=$(basename "$file")
        
        # On écrit tout dans le CSV en utilisant le point-virgule comme séparateur.
        # '>>' signifie qu'on ajoute à la fin du fichier sans effacer le reste.
        echo "$size;$real_extents;$dirname;$basename;$file" >> "$OUTPUT_CSV"
        
        # Petit point visuel pour montrer que le script travaille et n'est pas planté.
        echo -n "."        
    fi
done

echo -e "\n\n✅ Rapport généré : $OUTPUT_CSV"

# ==============================================================================
# Phase 2 : NETTOYAGE DES ANCIENS RAPPORTS (ROTATION)
# ==============================================================================
# Ce module cherche les fichiers .csv créés par ce script et supprime ceux 
# datant de plus de 30 jours pour éviter d'encombrer ton système.

echo "---  Nettoyage des anciens rapports (plus de 30 jours) ---"

# -name "fragmentation_*.csv" : cible uniquement les rapports
# -maxdepth 1 : Oblige find à ne chercher QUE dans le dossier actuel, sans entrer dans les sous-dossiers
# -mtime +30 : sélectionne les fichiers modifiés il y a plus de 30 jours
# -delete : les supprime automatiquement
find . -maxdepth 1 -name "fragmentation_*.csv" -type f -mtime +30 -delete

# ==============================================================================
# PHASE 3 : AFFICHAGE DES RÉSULTATS (TOP 10)
# ==============================================================================

echo -e "\n=============================================================================="
echo "---   🏆 TOP 10 DES FICHIERS LES PLUS FRAGMENTÉS "
echo "---   (Trié par : Nb Extents, puis par Taille de fichier)"
echo "=============================================================================="

# printf : permet de créer des colonnes parfaitement alignées à l'écran.
# %-10s signifie "chaîne de 10 caractères alignée à gauche".
printf "%-10s   %-10s   %-s\n" "EXTENTS" "TAILLE" "NOM DU FICHIER"
echo "------------------------------------------------------------------------------"

# tail -n +2 : saute la première ligne (l'entête du CSV)
# sort : 
#   -t ';' : utilise le point-virgule comme séparateur
#   -k2,2rn : trie la colonne 2 (extents) en numérique (n) inversé (r)
#   -k1,1rh : trie la colonne 1 (taille) en format humain (h) inversé (r)
# head -n 10 : ne garde que les 10 premières lignes du résultat trié
# awk : formate le résultat final pour l'affichage avec des barres verticales '|'
tail -n +2 "$OUTPUT_CSV" | sort -t ';' -k2,2rn -k1,1rh | head -n 10 | awk -F';' '{printf "%-10s | %-10s | %-s\n", $2, $1, $4}'

echo -e "\n=============================================================================="

# ==============================================================================
# PHASE 4 : MAINTENANCE (AUTO OU MANUELLE)
# ==============================================================================

# On calcule le maximum pour l'affichage du menu
max_found=$(tail -n +2 "$OUTPUT_CSV" | cut -d';' -f2 | sort -rn | head -n 1)
[ -z "$max_found" ] && max_found=0

if [ ! -t 0 ] || [[ "$*" == *"--auto"* ]]; then
    echo -e "\n Mode automatique : Défragmentation du TOP 10."
    process_csv_rows 10 2 # Limite=10, Seuil=2
else
    # MODE INTERACTIF
    echo -e "\n=============================================================================="
    echo "---   🛠️ OPTIONS DE MAINTENANCE (Max actuel : $max_found extents)"
    echo "=============================================================================="
    echo ""
    echo "     1) Défragmenter le TOP 10"
    echo "     2) Défragmenter selon un SEUIL d'extents"
    echo "     q) Quitter"
    echo ""
    echo "------------------------------------------------------------------------------"
    echo ""
    read -p "      Votre choix : " choice

    case $choice in
        1)
            echo -e "\n=============================================================================="
            echo -e "---   ⚙️ Traitement du TOP 10 (fichiers les plus fragmentés)"
            echo "=============================================================================="
            process_csv_rows 10 2 # Limite=10, Seuil=2
            ;;
        2)
            read -p "      Seuil minimum d'extents (ex: 5) : " threshold
            if [[ "$threshold" =~ ^[0-9]+$ ]] && [ "$threshold" -ge 2 ]; then
                echo -e "\n---   ⚙️ Traitement des fichiers >= $threshold extents\n"
                process_csv_rows 0 "$threshold" # Limite=0 (tout), Seuil=threshold
            else
                echo -e  "\n   ❌ Seuil invalide."
            fi
            ;;
        *)
            echo -e  "\n   Pas de défragmentation effectuée."
            ;;
    esac
fi

# ==============================================================================
# PHASE 5 : BILAN DE L'ESPACE LIBRE (DYNAMIQUE)
# ==============================================================================

echo -e "\n=============================================================================="
echo "---   📊 ÉTAT DE SANTÉ DE L'ESPACE LIBRE"
echo "=============================================================================="
echo -e "\n\n---   ⏳ Analyse des métadonnées (patience…)"

# Récupération du nom du disque (ex: /dev/sda1) associé au point de montage
DEV_PATH=$(df "$TARGET_DIR" | tail -1 | awk '{print $1}')

# xfs_db -r -c "freesp -s" : interroge la structure interne du disque.
# -r (read-only) est indispensable pour ne pas corrompre le disque pendant l'analyse.
# freesp -s donne un résumé global de l'espace libre.
stats_line=$(sudo xfs_db -r -c "freesp -s" "$DEV_PATH" 2>/dev/null | grep "free blocks")

# On vérifie si xfs_db a bien renvoyé une information exploitable
if echo "$stats_line" | grep -q "average"; then
    # sed : extrait uniquement le nombre situé juste après le mot "average"
    avg_blocks=$( )

    # Calcul de la taille moyenne en Mo (approximation shell)
    # Sur XFS, 1 bloc standard = 4096 octets. 
    # (Nombre de blocs * 4 / 1024) nous donne la taille en Mo.
    avg_size_mo=$((avg_blocks * 4 / 1024))

    echo -e "\n   Sur le disque $DEV_PATH :"
    echo "   > Taille moyenne des zones vides : ~ $avg_size_mo Mo"

    
    # Interprétation du résultat :
    # Si la zone moyenne est trop petite, xfs_fsr ne pourra pas déplacer les gros fichiers.
    if [ "$avg_size_mo" -gt 500 ]; then
        echo -e "\n   Excellent ✅ (Espace sain et continu)"
    elif [ "$avg_size_mo" -gt 100 ]; then
        echo "Correct ⚠️ (Fragmentation légère de l'espace libre)"
    else
        echo -e "\n   Critique ❌ (Espace très haché : défragmentation conseillée)"
    fi
else
    echo -e "\n   ⚠️ Info : Analyse impossible (le disque est peut-être verrouillé ou trop occupé)."
fi

echo -e "\n =============================================================================="
echo "      ✅ Maintenance terminée."
echo "=============================================================================="
