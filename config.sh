# shellcheck shell=bash
################################################################################
# CONFIGURATION - AcmeFrag (XFS + EXT4)
#
# Ne modifiez pas ce fichier pour vos réglages machine : créez plutôt
#   /etc/acmefrag.conf        (réglages système)
#   <dossier AcmeFrag>/local.conf  (réglages locaux, ignoré par git)
# en y définissant les variables à surcharger (ex: DEFAULT_TARGET=/mnt/HDD).
# Priorité : options CLI > local.conf > /etc/acmefrag.conf > variables d'env > défauts ci-dessous.
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Jean-Philippe Reculeau — voir LICENSE
################################################################################

# --- Surcharges optionnelles (chargées AVANT les défauts) --------------------
# ACMEFRAG_SYSTEM_CONF : autre fichier système (tests : fichier absent)
# (En root, AcmeFrag.sh a vérifié avant qu'aucun autre compte ne peut les modifier.)
for _conf in "${ACMEFRAG_SYSTEM_CONF:-/etc/acmefrag.conf}" "${ACMEFRAG_HOME}/local.conf"; do
    # shellcheck source=/dev/null
    [[ -r "$_conf" ]] && source "$_conf"
done
unset _conf

# --- Cible -------------------------------------------------------------------
: "${DEFAULT_TARGET:=}"                # dossier par défaut (vide = à préciser ou choix interactif)
: "${ALLOW_ROOT_FS:=false}"            # autoriser le FS racine (/) — déconseillé

# --- Seuils de défragmentation -------------------------------------------------
# Seuil d'intelligence : si la taille moyenne d'un extent (Mo) dépasse ce seuil,
# le fichier est déjà « assez contigu » pour une lecture fluide : on l'ignore.
# 0 = filtre désactivé (tout est traité).
: "${INTEL_THRESHOLD_MO:=4096}"
: "${DEFAULT_MIN_EXTENTS:=2}"          # nb minimum d'extents pour traiter un fichier
: "${DEFAULT_TOP_LIMIT:=10}"           # nb de fichiers éligibles traités en mode auto
# Fichiers modifiés depuis moins de N minutes ignorés (téléchargement / sync en cours)
: "${MIN_FILE_AGE_MIN:=60}"
# Durée max de la défragmentation globale xfs_fsr (secondes)
: "${GLOBAL_FSR_TIMEOUT_SEC:=10800}"

# Motifs exclus du scan (fichiers temporaires de qBittorrent, Syncthing, navigateurs)
if [[ -z "${SCAN_EXCLUDES+x}" ]]; then
    SCAN_EXCLUDES=('*.tmp' '*.part' '*.parts' '*.!qB' '.syncthing.*' '*.crdownload')
fi

# --- Rapports ------------------------------------------------------------------
: "${REPORT_DIR:=${ACMEFRAG_HOME}/reports}"   # CSV + journaux
: "${REPORT_MAX_AGE_DAYS:=30}"

# --- Protection SSD ------------------------------------------------------------
# Les SSD ne doivent PAS être défragmentés (usure inutile, aucun gain).
: "${ALLOW_SSD_DEFRAG:=false}"

# --- Qualité de service --------------------------------------------------------
# La défragmentation est une tâche de fond : elle ne doit jamais gêner la lecture
# vidéo ni les sessions interactives. Par défaut : CPU nice 19 + E/S classe « idle »
# (le disque n'est utilisé que lorsque personne d'autre ne s'en sert — effectif avec
# les ordonnanceurs BFQ/CFQ).
: "${QOS_ENABLE:=true}"
: "${QOS_NICE:=19}"
: "${QOS_IO_CLASS:=3}"                 # 3 = idle, 2 = best-effort

# --- Surveillance temps réel (SMART + températures) ----------------------------
: "${MONITOR_ENABLE:=true}"
: "${MONITOR_INTERVAL_SEC:=30}"        # un relevé SMART coûte une requête au pont USB
# Secteurs réalloués (attribut SMART 5) — repères :
#   0-5 excellent | 6-20 usure normale | 21-50 surveiller | 51-100 critique | >100 danger
#   NAS critique : 20 / 3   — Multimédia perso : 50 / 5   — Fin de vie : 100 / 10
: "${SMART_BAD_SECTOR_THRESHOLD:=50}"
: "${SMART_BAD_SECTOR_DRIFT_THRESHOLD:=5}"
: "${DISK_TEMP_THRESHOLD_C:=60}"
: "${SYSTEM_TEMP_THRESHOLD_C:=85}"
: "${AUTO_STOP_ON_ALERT:=true}"

# --- Santé du disque (--sante et garde-fou avant défragmentation) --------------
# Lecture SMART passive (aucun auto-test). Historique : REPORT_DIR/sante/<n° de série>.tsv
# Alerte si : bilan différent de PASSED (au changement), hausse des attributs 5, 196,
# 197, 198, 199 ou des erreurs ATA, température au-dessus du seuil ci-dessous.
# La défragmentation est refusée si le bilan est autre que PASSED, si des secteurs sont en
# attente (197) ou si les réalloués (5) ont augmenté sur SMART_GUARD_DAYS jours
# (par rapport à la plus ancienne mesure de cette période).
: "${SMART_TEMP_ALERT_C:=55}"          # alerte si la température dépasse strictement ce seuil (°C)
: "${SMART_GUARD_DAYS:=30}"            # période du garde-fou « réalloués en hausse » (jours)

# --- Options d'exécution (modifiées par la ligne de commande) -------------------
: "${DRY_RUN:=false}"
: "${FORCE_SSD:=false}"
: "${FORCE_HEALTH:=false}"             # --force-sante : défragmenter malgré une mauvaise santé

# Valide la configuration : refuse les valeurs aberrantes au lieu de les corriger
# silencieusement (une config fausse doit se voir).
validate_config() {
    local errors=0 var
    for var in INTEL_THRESHOLD_MO DEFAULT_MIN_EXTENTS DEFAULT_TOP_LIMIT MIN_FILE_AGE_MIN \
               GLOBAL_FSR_TIMEOUT_SEC REPORT_MAX_AGE_DAYS QOS_NICE QOS_IO_CLASS \
               MONITOR_INTERVAL_SEC SMART_BAD_SECTOR_THRESHOLD SMART_BAD_SECTOR_DRIFT_THRESHOLD \
               DISK_TEMP_THRESHOLD_C SYSTEM_TEMP_THRESHOLD_C SMART_TEMP_ALERT_C SMART_GUARD_DAYS; do
        if ! is_uint "${!var}"; then
            err "$var doit être un entier positif (valeur : '${!var}')"
            errors=$((errors + 1))
        fi
    done
    if is_uint "$DEFAULT_MIN_EXTENTS" && (( DEFAULT_MIN_EXTENTS < 2 )); then
        err "DEFAULT_MIN_EXTENTS doit être >= 2"; errors=$((errors + 1))
    fi
    if is_uint "$DEFAULT_TOP_LIMIT" && (( DEFAULT_TOP_LIMIT < 1 )); then
        err "DEFAULT_TOP_LIMIT doit être >= 1"; errors=$((errors + 1))
    fi
    if is_uint "$MONITOR_INTERVAL_SEC" && (( MONITOR_INTERVAL_SEC < 1 )); then
        err "MONITOR_INTERVAL_SEC doit être >= 1"; errors=$((errors + 1))
    fi
    if is_uint "$SMART_GUARD_DAYS" && (( SMART_GUARD_DAYS < 1 || SMART_GUARD_DAYS > 3650 )); then
        err "SMART_GUARD_DAYS doit être entre 1 et 3650"; errors=$((errors + 1))
    fi
    if is_uint "$QOS_IO_CLASS" && (( QOS_IO_CLASS < 1 || QOS_IO_CLASS > 3 )); then
        err "QOS_IO_CLASS doit valoir 1, 2 ou 3"; errors=$((errors + 1))
    fi
    [[ "$REPORT_DIR" == / ]] || REPORT_DIR="${REPORT_DIR%/}"
    if [[ "$REPORT_DIR" != /* ]]; then
        err "REPORT_DIR doit être un chemin absolu (valeur : '$REPORT_DIR')"; errors=$((errors + 1))
    fi
    for var in ALLOW_ROOT_FS ALLOW_SSD_DEFRAG QOS_ENABLE MONITOR_ENABLE AUTO_STOP_ON_ALERT DRY_RUN FORCE_SSD FORCE_HEALTH; do
        case "${!var,,}" in
            true|false) printf -v "$var" '%s' "${!var,,}" ;;
            *) err "$var doit valoir true ou false (valeur : '${!var}')"; errors=$((errors + 1)) ;;
        esac
    done
    (( errors == 0 ))
}
