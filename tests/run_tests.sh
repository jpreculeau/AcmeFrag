#!/usr/bin/env bash
# Tests unitaires AcmeFrag — sans root, sans disque. Usage : tests/run_tests.sh
set -uo pipefail

SOURCE="$(cd "$(dirname "$0")/.." && pwd)"
# Copie du dépôt sans local.conf ni rapports, /etc/acmefrag.conf ignoré : un test
# qui lance AcmeFrag ne doit jamais viser le vrai DEFAULT_TARGET de la machine.
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
tar -C "$SOURCE" --exclude=./.git --exclude=./local.conf --exclude=./reports -cf - . | tar -C "$ROOT" -xf -
export ACMEFRAG_SYSTEM_CONF=/nonexistent LC_ALL=C.UTF-8
# Faux sudo en tête du PATH : un lancement qui atteindrait `exec sudo` ne doit
# jamais devenir root (sudo effacerait ACMEFRAG_SYSTEM_CONF). Appels notés.
SUDO_LOG="$ROOT/.faux-sudo/appels"; mkdir -p "$ROOT/.faux-sudo"; : > "$SUDO_LOG"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> %q\nexit 97\n' "$SUDO_LOG" > "$ROOT/.faux-sudo/sudo"
chmod +x "$ROOT/.faux-sudo/sudo"
export PATH="$ROOT/.faux-sudo:$PATH"
PASS=0 FAIL=0

check() {  # check "description" commande...
    local desc="$1"; shift
    if "$@"; then PASS=$((PASS + 1)); printf '  ok   %s\n' "$desc"
    else FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$desc"; fi
}
not() { ! "$@"; }
eq() { [[ "$1" == "$2" ]] || { printf '       attendu [%s] obtenu [%s]\n' "$2" "$1"; return 1; }; }

export NO_COLOR=1
# shellcheck source=../AcmeFrag.sh
source "$ROOT/AcmeFrag.sh"
set +e +E; trap - ERR
REPORT_DIR=$(mktemp -d "$ROOT/rapports.XXXXXX"); load_modules   # sous $ROOT : nettoyé par le trap

echo "parse_filefrag"
out=$(printf '%s\n' \
    '/m/Film: la suite.mkv: 12 extents found' \
    '/m/a.txt: 1 extent found' \
    'filefrag: /m/x: Permission denied' | parse_filefrag)
check "nom contenant ': '" eq "$(sed -n 1p <<< "$out")" $'12\t/m/Film: la suite.mkv'
check "singulier 'extent'" eq "$(sed -n 2p <<< "$out")" $'1\t/m/a.txt'
check "lignes d'erreur ignorées" eq "$(wc -l <<< "$out")" "2"

echo "is_eligible"
INTEL_THRESHOLD_MO=4096
check "8 Gio en 1 extent : non éligible"   not is_eligible $((8 * 1024 * MIB)) 1
check "8 Gio en 4 extents : éligible"      is_eligible $((8 * 1024 * MIB)) 4
INTEL_THRESHOLD_MO=0
check "seuil 0 : toujours éligible"        is_eligible 99999999999 1
INTEL_THRESHOLD_MO=4096

echo "validate_config"
check "config par défaut valide" validate_config
check "seuil non numérique refusé" bash -c "source '$ROOT/lib/common.sh'; ACMEFRAG_HOME='$ROOT' INTEL_THRESHOLD_MO=abc; source '$ROOT/config.sh'; ! validate_config 2>/dev/null"
check "booléen normalisé (TRUE -> true)" bash -c "source '$ROOT/lib/common.sh'; ACMEFRAG_HOME='$ROOT' DRY_RUN=TRUE; source '$ROOT/config.sh'; validate_config && [[ \$DRY_RUN == true ]]"
check "REPORT_DIR relatif refusé" bash -c "source '$ROOT/lib/common.sh'; ACMEFRAG_HOME='$ROOT' REPORT_DIR=reports; source '$ROOT/config.sh'; ! validate_config 2>/dev/null"
check "min-extents < 2 refusé" bash -c "source '$ROOT/lib/common.sh'; ACMEFRAG_HOME='$ROOT' DEFAULT_MIN_EXTENTS=1; source '$ROOT/config.sh'; ! validate_config 2>/dev/null"

echo "parse_args"
parse_args /mnt/X -s 0 --dry-run --auto -n 3
check "cible"   eq "$CLI_TARGET" /mnt/X
check "seuil 0" eq "$CLI_SEUIL" 0
check "top 3"   eq "$CLI_TOP" 3
check "mode"    eq "$CLI_MODE" auto
check "option inconnue -> code 2" bash -c "'$ROOT/AcmeFrag.sh' --nope >/dev/null 2>&1; [[ \$? -eq 2 ]]"
check "-s sans entier -> code 2"  bash -c "'$ROOT/AcmeFrag.sh' -s abc >/dev/null 2>&1; [[ \$? -eq 2 ]]"
check "deux cibles -> code 2"     bash -c "'$ROOT/AcmeFrag.sh' /a /b >/dev/null 2>&1; [[ \$? -eq 2 ]]"
check "auto sans cible ni DEFAULT_TARGET -> code 2" bash -c "DEFAULT_TARGET= '$ROOT/AcmeFrag.sh' --auto --dry-run --no-qos </dev/null >/dev/null 2>&1; [[ \$? -eq 2 ]]"
check "config par défaut sans chemin personnel" bash -c "! grep -q '^: \"\${DEFAULT_TARGET:=/' '$ROOT/config.sh'"
check "--help -> code 0"          bash -c "'$ROOT/AcmeFrag.sh' --help >/dev/null"
check "--help -> aide affichée"   bash -c "'$ROOT/AcmeFrag.sh' --help | grep -q ACMEFRAG"
CLI_MODE=""
check "hors terminal -> mode auto" eq "$(resolve_mode < /dev/null)" auto

echo "divers"
check "human_size" eq "$(human_size $((2621440 * 1024)))" "2.5G"
mapfile -d '' -t ex < <(_find_exclude_args)
check "exclusions find" eq "${ex[0]} ${ex[1]} ${ex[2]}" "! -name *.tmp"
MONITOR_DIR=$(mktemp -d)
printf 'bad_sectors=3\nbad_drift=1\ndisk_temp=41\nsystem_temp=55\nalerts=none\n' > "$MONITOR_DIR/status"
check "ligne monitor" eq "$(monitor_status_line)" "   🔒 MONITOR: bad_sectors=3 bad_drift=+1 disk_temp=41°C system_temp=55°C alerts=none"
check "pas d'arrêt sans fichier stop" not monitor_should_stop
echo "BAD" > "$MONITOR_DIR/stop"
check "arrêt demandé" monitor_should_stop
rm -rf "$MONITOR_DIR"; MONITOR_DIR=""
SMART_BAD_SECTOR_THRESHOLD=50 SMART_BAD_SECTOR_DRIFT_THRESHOLD=5 DISK_TEMP_THRESHOLD_C=60 SYSTEM_TEMP_THRESHOLD_C=85
check "surveillance : valeurs saines -> aucune alerte" eq "$(_monitor_alerts 10 10 40 50)" ""
check "surveillance : secteurs au seuil -> alerte" eq "$(_monitor_alerts 50 48 40 50)" "BAD_SECTORS:50"
check "surveillance : dérive au seuil -> alerte" eq "$(_monitor_alerts 15 10 40 50)" "BAD_DRIFT:+5"
check "surveillance : température disque au seuil -> alerte" eq "$(_monitor_alerts 10 10 60 50)" "DISK_TEMP:60C"
check "surveillance : température système au seuil -> alerte" eq "$(_monitor_alerts 10 10 40 85)" "SYS_TEMP:85C"
check "surveillance : valeurs absentes (NA) -> aucune alerte" eq "$(_monitor_alerts NA NA NA NA)" ""
check "surveillance : alertes cumulées" eq "$(_monitor_alerts 60 50 61 90)" "BAD_SECTORS:60 BAD_DRIFT:+10 DISK_TEMP:61C SYS_TEMP:90C"
ROT=$(mktemp -d "$ROOT/rot.XXXXXX")
touch -d '40 days ago' "$ROT/fragmentation_2026-01-01.csv" "$ROT/acmefrag_2026-01-01.log" "$ROT/autre.txt"
touch "$ROT/fragmentation_recent.csv"
REPORT_DIR="$ROT" REPORT_MAX_AGE_DAYS=30 clean_old_reports >/dev/null
check "rotation : vieux rapports et journaux supprimés, le reste gardé" eq "$(find "$ROT" -type f -printf '%f\n' | sort | tr '\n' ' ')" "autre.txt fragmentation_recent.csv "
rm -rf "$ROT"

echo "santé du disque (SMART)"
FIX="$ROOT/tests/fixtures/smartctl_ata.txt"
FAKE_BIN="$ROOT/.faux-bin"; mkdir -p "$FAKE_BIN"   # sous $ROOT : nettoyé par le trap
# Faux smartctl : FAKE_SMART_OUT (sortie), FAKE_SMART_RC (code), FAKE_SMART_SAT=1 (pont USB
# qui exige -d sat), FAKE_SMART_STANDBY=1 (disque en veille) ; appels notés dans FAKE_SMART_LOG
cat > "$FAKE_BIN/smartctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_SMART_LOG:-/dev/null}"
if [[ -n "${FAKE_SMART_SAT:-}" && " $* " != *" -d sat "* ]]; then
    echo "/dev/x: Unknown USB bridge [0x174c:0x55aa (0x100)]"; exit 1
fi
if [[ -n "${FAKE_SMART_STANDBY:-}" && " $* " == *" -n standby "* ]]; then
    echo "Device is in STANDBY mode, exit(2)"; exit 2
fi
cat "$FAKE_SMART_OUT"; exit "${FAKE_SMART_RC:-0}"
EOF
chmod +x "$FAKE_BIN/smartctl"
PATH_SANS_FAUX="$PATH"
export PATH="$FAKE_BIN:$PATH" FAKE_SMART_LOG="$FAKE_BIN/appels"
# shellcheck disable=SC2317  # appelée indirectement par le code testé
disk_device() { echo /dev/fake; }     # pas de vrai disque dans les tests
HIST="$REPORT_DIR/sante/TEST123.tsv"
# Sortie dérivée de la fixture : smart_out 's/motif/remplacement/' ...
smart_out() {
    local f="$FAKE_BIN/sortie" e; cp "$FIX" "$f"
    for e in "$@"; do sed -i -E "$e" "$f"; done
    export FAKE_SMART_OUT="$f"
}
reset_smart() { rm -rf "$REPORT_DIR/sante"; : > "$FAKE_SMART_LOG"; unset FAKE_SMART_SAT FAKE_SMART_STANDBY FAKE_SMART_RC; smart_out; }
mesure() { HC_OUT=$(run_health_check /mnt/X 2>&1); HC_RC=$?; }

reset_smart
rec=$(_health_parse < "$FIX")
check "parse : série, bilan, 1 5 9 187 188 194 196 197 198 199, erreurs ATA" \
    eq "$rec" $'TEST123\tPASSED\t0\t40\t12345\tNA\tNA\t40\t7\t0\t0\t3\t4'
check "parse : bilan FAILED (point d'exclamation retiré)" \
    eq "$(sed 's/result: PASSED/result: FAILED!/' "$FIX" | _health_parse | cut -f2)" FAILED
check "parse : heures au format 12345h+12m" \
    eq "$(sed -E 's/12345$/12345h+12m+03.000s/' "$FIX" | _health_parse | cut -f5)" 12345
check "parse : température par l'attribut 190 à défaut du 194" \
    eq "$(sed -E 's/^194 Temperature_Celsius /190 Airflow_Temperature_Cel /' "$FIX" | _health_parse | cut -f8)" 40
check "parse : série hostile assainie (tabulation, échappement)" \
    eq "$(sed $'s/TEST123/AB\\tFAILED\\x1b[31m/' "$FIX" | _health_parse | cut -f1-2)" $'AB_FAILED__31m\tPASSED'
check "parse : « No Errors Logged » -> 0 erreur ATA" \
    eq "$(sed -E 's/^ATA Error Count.*/No Errors Logged/' "$FIX" | _health_parse | cut -f13)" 0

check "surveillance : secteurs réalloués et température" eq "$(_smart_read /dev/fake "")" "40 40"
smart_out 's/^(194 Temperature_Celsius.*)$/190 Airflow_Temperature_Cel 0x0022 059 045 045 Old_age Always - 41\n\1/'
check "surveillance : attribut 194 prioritaire sur 190 (comme --sante)" eq "$(_smart_read /dev/fake "")" "40 40"
check "surveillance : valeur brute non numérique ignorée" eq "$(sed -E 's/(Reallocated_Sector_Ct .*)40$/\1x/' "$FIX" | _health_parse | cut -f4)" NA
check "parse : température NVMe (« Temperature: 45 Celsius »)" \
    eq "$(printf 'Serial Number: N1\nSMART overall-health self-assessment test result: PASSED\nTemperature:                        45 Celsius\n' | _health_parse | cut -f8)" 45
reset_smart
mesure
check "1re mesure PASSED -> code 0" eq "$HC_RC" 0
check "historique créé (en-tête + 1 mesure)" eq "$(wc -l < "$HIST")" 2
check "ligne de bilan pour un orchestrateur" grep -q "BILAN SANTÉ : " <<< "$HC_OUT"
mesure
check "mesure identique -> code 0" eq "$HC_RC" 0
check "historique : 2 mesures" eq "$(wc -l < "$HIST")" 3

smart_out 's/(Reallocated_Sector_Ct .*)40$/\148/'; mesure
check "hausse des réalloués -> code 6" eq "$HC_RC" 6
check "évolution affichée 40 → 48" grep -q "40 → 48" <<< "$HC_OUT"
mesure
check "réalloués stables ensuite -> code 0" eq "$HC_RC" 0

for a in 196:7 197:0 198:0; do
    reset_smart; mesure
    smart_out "s/^(${a%%:*} .* )${a#*:}\$/\\1$(( ${a#*:} + 1 ))/"; mesure
    check "hausse de l'attribut ${a%%:*} -> code 6" eq "$HC_RC" 6
done
reset_smart; mesure; smart_out 's/^ATA Error Count: 4/ATA Error Count: 6/'; mesure
check "hausse des erreurs ATA -> code 6" eq "$HC_RC" 6
check "erreurs ATA 4 → 6" grep -q "4 → 6" <<< "$HC_OUT"
reset_smart; mesure; smart_out 's/(UDMA_CRC_Error_Count .*)3$/\14/'; mesure
check "hausse du CRC (199) -> code 6" eq "$HC_RC" 6
check "CRC : piste câble/boîtier" grep -qi "câble" <<< "$HC_OUT"
reset_smart; mesure; smart_out 's/(Raw_Read_Error_Rate .*)0$/\1999/'; mesure
check "attribut 1 suivi sans alerte -> code 0" eq "$HC_RC" 0

reset_smart; smart_out 's/- +40 \(Min/-       56 (Min/'; mesure
check "température 56 °C > 55 -> code 6" eq "$HC_RC" 6
SMART_TEMP_ALERT_C=60; mesure
check "seuil de température configurable (60)" eq "$HC_RC" 0
SMART_TEMP_ALERT_C=55

reset_smart; smart_out 's/result: PASSED/result: FAILED!/'; FAKE_SMART_RC=8 mesure
check "bilan FAILED, 1re fois -> code 6" eq "$HC_RC" 6
FAKE_SMART_RC=8 mesure
check "bilan FAILED déjà connu -> code 0" eq "$HC_RC" 0
check "FAILED connu rappelé au journal" grep -q "connu" <<< "$HC_OUT"
smart_out 's/result: PASSED/result: FAILED!/' 's/(Reallocated_Sector_Ct .*)40$/\141/'
FAKE_SMART_RC=8 mesure
check "FAILED connu + hausse des réalloués -> code 6" eq "$HC_RC" 6

reset_smart; export FAKE_SMART_SAT=1; mesure
check "pont USB non reconnu : repli -d sat -> code 0" eq "$HC_RC" 0
check "pont USB : -d sat utilisé" grep -q -- "-d sat" "$FAKE_SMART_LOG"
check "smart_args (surveillance) : -d sat détecté" eq "$(smart_args /dev/fake)" "-d sat"
reset_smart; smart_out; FAKE_SMART_RC=2 mesure
check "pont USB illisible (sat compris) -> code 7" eq "$HC_RC" 7

reset_smart; export FAKE_SMART_STANDBY=1; mesure
check "disque en veille -> code 7 (mesure reportée)" eq "$HC_RC" 7
check "disque en veille : jamais réveillé" not grep -qv -- "-n standby" "$FAKE_SMART_LOG"
check "veille : pas d'historique" not test -e "$HIST"

reset_smart
PATH="$PATH_SANS_FAUX" mesure
check "smartctl absent -> code 7" eq "$HC_RC" 7

reset_smart; mesure; mesure; FAKE_SMART_SAT=1 mesure
check "lecture seule : aucun auto-test SMART lancé" not grep -qE -- '(^| )(-t|--test|-X|--abort|-s|--smart|-o|-S)( |=|$)' "$FAKE_SMART_LOG"

reset_smart; smart_out 's#TEST123#../../x y#'; mesure
check "n° de série assaini : fichier dans sante/" test -f "$REPORT_DIR/sante/.._.._x_y.tsv"
reset_smart; mkdir -p "$REPORT_DIR/sante"; ln -s "$REPORT_DIR/cible" "$HIST"; mesure
check "historique en lien symbolique refusé -> code 7" eq "$HC_RC" 7
check "lien symbolique : cible non écrite" not test -e "$REPORT_DIR/cible"
reset_smart; AILLEURS="$ROOT/.ailleurs"; mkdir -p "$AILLEURS"; ln -s "$AILLEURS" "$REPORT_DIR/sante"; mesure
check "dossier sante/ en lien symbolique refusé -> code 7" eq "$HC_RC" 7
check "dossier sante/ en lien : rien écrit ailleurs" eq "$(ls -A "$AILLEURS")" ""
rm -rf "$AILLEURS" "$REPORT_DIR/sante"
reset_smart; smart_out '/^Serial Number:/d'; mesure
check "série illisible : mesure sans historique -> code 0" eq "$HC_RC" 0
check "série illisible : aucun historique partagé" not test -e "$REPORT_DIR/sante"
reset_smart; smart_out '/self-assessment/d' '/^ *[0-9]+ [A-Z]/d' '/^ATA Error Count/d'; mesure
check "ni bilan ni attribut (SMART désactivé) -> code 7" eq "$HC_RC" 7
check "ni bilan ni attribut : pas d'historique" not test -e "$HIST"

echo "garde-fou santé avant défragmentation"
garde() { CD_OUT=$(check_disk_health /mnt/X 2>&1); CD_RC=$?; }
reset_smart; mesure; garde
check "disque sain -> défragmentation autorisée" eq "$CD_RC" 0
check "garde-fou : historique non modifié" eq "$(wc -l < "$HIST")" 2
smart_out 's/result: PASSED/result: FAILED!/'; garde
check "bilan FAILED -> refus" eq "$CD_RC" 1
check "refus expliqué (--force-sante)" grep -q -- "--force-sante" <<< "$CD_OUT"
FORCE_HEALTH=true garde
check "--force-sante -> autorisé" eq "$CD_RC" 0
DRY_RUN=true garde
check "dry-run -> avertissement seulement" eq "$CD_RC" 0
: > "$FAKE_SMART_LOG"; DRY_RUN=true garde
check "dry-run : SMART lu sans réveiller le disque (-n standby)" not grep -qv -- "-n standby" "$FAKE_SMART_LOG"
smart_out 's/(Reallocated_Sector_Ct .*)40$/\141/'; garde
check "réalloués en hausse depuis la dernière mesure -> refus" eq "$CD_RC" 1
smart_out 's/result: PASSED/result: HARDWARE IMPENDING FAILURE!/'; garde
check "bilan autre que PASSED (SAS) -> refus" eq "$CD_RC" 1
# Fenêtre du garde-fou : une hausse déjà enregistrée par --sante reste bloquante
historique() {  # historique "jours:réalloués"... (du plus ancien au plus récent)
    local e; { printf 'date\tbilan\t1\t5\t9\t187\t188\t194\t196\t197\t198\t199\tata\n'
    for e in "$@"; do printf '%s\tPASSED\t0\t%s\t12345\tNA\tNA\t40\t7\t0\t0\t3\t4\n' \
        "$(date -d "-${e%%:*} days" '+%Y-%m-%dT%H:%M:%S')" "${e#*:}"; done; } > "$HIST"
}
smart_out
historique 10:38 1:40; garde
check "hausse enregistrée hier par --sante, sur 30 jours -> refus" eq "$CD_RC" 1
historique 40:38 10:40; garde
check "hausse hors de la fenêtre de 30 jours -> autorisé" eq "$CD_RC" 0
historique 40:38; garde
check "aucune mesure dans la fenêtre : comparaison à la dernière -> refus" eq "$CD_RC" 1
historique 10:38 1:40
SMART_GUARD_DAYS=5 garde
check "fenêtre configurable (SMART_GUARD_DAYS=5) -> autorisé" eq "$CD_RC" 0
historique 1:40; smart_out 's/(Current_Pending_Sector .*)0$/\13/'; garde
check "secteurs en attente > 0 -> refus" eq "$CD_RC" 1
check "refus motivé par les secteurs en attente" grep -q "3 secteur(s) en attente" <<< "$CD_OUT"
# Disque mourant redevenu PASSED (attribut fautif remonté au-dessus du seuil) : cas réel
historique 1:40; printf '%s\tFAILED\t0\t40\t12345\tNA\tNA\t40\t7\t0\t0\t3\t4\n' "$(date -d '-60 days' '+%Y-%m-%dT%H:%M:%S')" \
    | sed -i '1r /dev/stdin' "$HIST"; smart_out; garde
check "FAILED déjà enregistré (même hors fenêtre), PASSED aujourd'hui -> refus" eq "$CD_RC" 1
check "refus motivé par le FAILED enregistré, avec sa date" grep -q "bilan SMART FAILED enregistré le $(date -d '-60 days' +%Y-%m-%d)" <<< "$CD_OUT"
check "FAILED enregistré : jamais présenté comme sain" not grep -q "sous les seuils" <<< "$CD_OUT"
# Réalloués au-delà du seuil absolu, sans hausse récente (152 stables)
historique 10:152 1:152; smart_out 's/(Reallocated_Sector_Ct .*)40$/\1152/'; garde
check "152 réalloués stables, seuil 50 -> refus" eq "$CD_RC" 1
check "refus motivé par le seuil des réalloués" grep -q "152 secteurs réalloués (seuil 50)" <<< "$CD_OUT"
SMART_BAD_SECTOR_THRESHOLD=153 garde
check "réalloués sous le seuil configuré -> autorisé" eq "$CD_RC" 0
SMART_BAD_SECTOR_THRESHOLD=152 garde
check "réalloués au seuil (comme la surveillance : >=) -> refus" eq "$CD_RC" 1
SMART_BAD_SECTOR_THRESHOLD=0 garde
check "seuil 0 : critère désactivé" eq "$CD_RC" 0
historique 1:40; smart_out; garde
check "disque sain : valeurs affichées, pas seulement un verdict" grep -q "bilan PASSED, réalloués 40, en attente 0, erreurs ATA 4" <<< "$CD_OUT"
PATH="$PATH_SANS_FAUX" garde
check "smartctl absent -> poursuite (avertissement)" eq "$CD_RC" 0
historique 1:1; cp "$HIST" "$REPORT_DIR/sante/NA.tsv"; smart_out '/^Serial Number:/d'; garde
check "série illisible : NA.tsv jamais pris pour référence" eq "$CD_RC" 0
# Menu interactif : sortir du dry-run rejoue le garde-fou
menu_d() { run_maintenance /mnt/X /dev/null <<< $'d\nq' >/dev/null 2>&1; echo "$DRY_RUN"; }
smart_out 's/result: PASSED/result: FAILED!/'
check "menu « d » sur disque FAILED : dry-run maintenu" eq "$(DRY_RUN=true; menu_d)" true
check "menu « d » sur disque FAILED avec --force-sante : dry-run désactivé" eq "$(DRY_RUN=true FORCE_HEALTH=true; menu_d)" false
smart_out; rm -f "$REPORT_DIR/sante/NA.tsv"; historique 1:40
check "menu « d » sur disque sain : dry-run désactivé" eq "$(DRY_RUN=true; menu_d)" false
unset -f disk_device
export PATH="$PATH_SANS_FAUX"; unset FAKE_SMART_LOG FAKE_SMART_OUT
rm -rf "$FAKE_BIN"

echo "options santé"
CLI_TARGET="" CLI_HEALTH="" CLI_FORCE_HEALTH=""
parse_args --sante /mnt/Y --force-sante
check "--sante" eq "$CLI_HEALTH" true
check "--force-sante" eq "$CLI_FORCE_HEALTH" true
check "--sante sans cible ni DEFAULT_TARGET -> code 2" bash -c "DEFAULT_TARGET= '$ROOT/AcmeFrag.sh' --sante </dev/null >/dev/null 2>&1; [[ \$? -eq 2 ]]"
check "SMART_GUARD_DAYS=3651 refusé" bash -c "source '$ROOT/lib/common.sh'; ACMEFRAG_HOME='$ROOT' SMART_GUARD_DAYS=3651; source '$ROOT/config.sh'; ! validate_config 2>/dev/null"
check "SMART_GUARD_DAYS=3650 accepté" bash -c "source '$ROOT/lib/common.sh'; ACMEFRAG_HOME='$ROOT' SMART_GUARD_DAYS=3650; source '$ROOT/config.sh'; validate_config"
check "SMART_GUARD_DAYS=0 refusé" bash -c "source '$ROOT/lib/common.sh'; ACMEFRAG_HOME='$ROOT' SMART_GUARD_DAYS=0; source '$ROOT/config.sh'; ! validate_config 2>/dev/null"
check "SMART_GUARD_DAYS non numérique refusé" bash -c "source '$ROOT/lib/common.sh'; ACMEFRAG_HOME='$ROOT' SMART_GUARD_DAYS=x; source '$ROOT/config.sh'; ! validate_config 2>/dev/null"
check "SMART_TEMP_ALERT_C non numérique refusé" bash -c "source '$ROOT/lib/common.sh'; ACMEFRAG_HOME='$ROOT' SMART_TEMP_ALERT_C=x; source '$ROOT/config.sh'; ! validate_config 2>/dev/null"
rm -rf "$REPORT_DIR"

echo "garde-fous disque (montages et périphériques simulés)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh" 2>/dev/null   # restaure disk_device (readonly : erreurs ignorées)
# shellcheck disable=SC2317  # fonctions appelées indirectement par le code testé
{
findmnt() {
    local champ="" chemin="" a
    while (( $# )); do case "$1" in -o|-no) champ="$2"; shift ;; -T) chemin="$2"; shift ;; esac; shift; done
    if [[ -z "$chemin" ]]; then                     # liste des montages XFS/EXT4
        printf '259:2 /\n259:2 /srv/lie\n8:1 /mnt/hdd\n8:1 /mnt/mon\\x20disque\n'; return
    fi
    local src mm opts=rw,noatime
    case "$chemin" in
        /mnt/lie*)   src='/dev/nvme0n1p2[/srv/media]' mm=259:2 ;;
        /mnt/hdd*)   src=/dev/sda1 mm=8:1 ;;
        /mnt/crypt*) src=/dev/mapper/crypt mm=254:0 ;;
        /mnt/ro*)    src=/dev/sda1 mm=8:1 opts=ro,noatime ;;
        /mnt/inc*)   src=/dev/sdz1 mm=8:99 ;;
        *)           src=/dev/nvme0n1p2 mm=259:2 ;;
    esac
    # findmnt -no MAJ:MIN complète par des espaces («   8:1  »), comme le vrai
    case "$champ" in SOURCE) echo "$src" ;; MAJ:MIN) printf "  %-6s\\n" "$mm" ;; OPTIONS) echo "$opts" ;; FSTYPE) echo ext4 ;; TARGET) echo "$chemin" ;; esac
}
lsblk() {
    case "${*: -1}" in
        /dev/sda1)         printf 'sda1 part\nsda disk\n' ;;
        /dev/mapper/crypt) printf 'crypt crypt\nsda1 part\nsda disk\n' ;;
        /dev/nvme0n1p2)    printf 'nvme0n1p2 part\nnvme0n1 disk\n' ;;
        /dev/sdz1)         printf 'sdz1 part\nsdz disk\n' ;;
    esac
}
_disk_rotational() { case "$1" in sda) echo 1 ;; sdz) echo "" ;; *) echo 0 ;; esac; }
}
check "bind mount du FS racine -> refusé" not check_not_root_fs /mnt/lie/films
check "disque monté -> pas le FS racine" check_not_root_fs /mnt/hdd/films
check "disque d'une partition -> /dev/sda" eq "$(disk_device /mnt/hdd/films)" /dev/sda
check "disque sous LUKS/LVM -> /dev/sda" eq "$(disk_device /mnt/crypt/x)" /dev/sda
check "disque d'un bind mount -> /dev/nvme0n1" eq "$(disk_device /mnt/lie/x)" /dev/nvme0n1
check "bind mount sur NVMe -> ssd" eq "$(disk_kind /mnt/lie/x)" ssd
check "LUKS/LVM sur HDD -> hdd" eq "$(disk_kind /mnt/crypt/x)" hdd
check "type de disque inconnu -> refusé" not check_ssd_warning /mnt/inc/x
check "type inconnu + --force-ssd -> autorisé" eval 'FORCE_SSD=true check_ssd_warning /mnt/inc/x'
check "SSD -> refusé" not check_ssd_warning /mnt/lie/x
check "HDD -> autorisé" check_ssd_warning /mnt/hdd/x
check "montage en lecture seule -> refusé" not check_mounted_rw /mnt/ro/x
check "montage en lecture-écriture -> autorisé" check_mounted_rw /mnt/hdd/x
mapfile -t DISQUES < <(detect_available_disks)
check "montages détectés : racine et ses bind mounts exclus, espaces décodés" eq "${DISQUES[*]}" "/mnt/hdd /mnt/mon disque"
unset -f findmnt lsblk _disk_rotational
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh" 2>/dev/null   # restaure _disk_rotational

echo "défragmentation d'un fichier (outils simulés)"
DF="$ROOT/.defrag"; mkdir -p "$DF/cible" "$DF/bin" "$DF/ailleurs"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> %q\n' "$DF/appels" > "$DF/bin/xfs_fsr"; chmod +x "$DF/bin/xfs_fsr"
printf 'x' > "$DF/cible/vieux.mkv"; touch -d '2 days ago' "$DF/cible/vieux.mkv"
printf 'x' > "$DF/cible/recent.mkv"
printf 'x' > "$DF/ailleurs/autre.mkv"; touch -d '2 days ago' "$DF/ailleurs/autre.mkv"
ln -s "$DF/ailleurs/autre.mkv" "$DF/cible/lien.mkv"; touch -h -d '2 days ago' "$DF/cible/lien.mkv"
defrag() {  # defrag CHEMIN : lance defrag_file, note la sortie et les appels à l'outil
    : > "$DF/appels"; STAT_SKIPPED=0 STAT_FAILED=0 STAT_SIMULATED=0 STAT_OK=0 STAT_ALREADY=0
    PATH="$DF/bin:$PATH" defrag_file "$1" 5 1 xfs "$DF/cible" > "$DF/sortie" 2>&1
}
MIN_FILE_AGE_MIN=60 DRY_RUN=false
defrag "$DF/cible/vieux.mkv"
check "fichier ancien : outil lancé" eq "$(cat "$DF/appels")" "-v $DF/cible/vieux.mkv"
defrag "$DF/cible/recent.mkv"
check "fichier récent : outil jamais lancé" eq "$(cat "$DF/appels")" ""
check "fichier récent : compté ignoré" eq "$STAT_SKIPPED" 1
defrag "$DF/cible/absent.mkv"
check "fichier disparu : outil jamais lancé" eq "$(cat "$DF/appels")" ""
defrag "$DF/cible/lien.mkv"
check "lien symbolique : outil jamais lancé" eq "$(cat "$DF/appels")" ""
defrag "$DF/ailleurs/autre.mkv"
check "fichier hors de la cible : outil jamais lancé" eq "$(cat "$DF/appels")" ""
mkdir -p "$DF/hors"; printf 'x' > "$DF/hors/secret.mkv"; touch -d '2 days ago' "$DF/hors/secret.mkv"
ln -s ../hors "$DF/cible/dossier"
defrag "$DF/cible/dossier/secret.mkv"
check "dossier parent remplacé par un lien : outil jamais lancé" eq "$(cat "$DF/appels")" ""
defrag "$DF/cible/../ailleurs/autre.mkv"
check "chemin en « .. » : outil jamais lancé" eq "$(cat "$DF/appels")" ""
DRY_RUN=true defrag "$DF/cible/vieux.mkv"
check "dry-run : outil jamais lancé" eq "$(cat "$DF/appels")" ""
check "dry-run : compté simulé" eq "$STAT_SIMULATED" 1
# shellcheck disable=SC2317  # appelée par defrag_file
fs_avail_bytes() { echo 0; }
defrag "$DF/cible/vieux.mkv"
check "espace libre insuffisant : outil jamais lancé" eq "$(cat "$DF/appels")" ""
check "espace libre insuffisant : compté en échec" eq "$STAT_FAILED" 1
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh" 2>/dev/null   # restaure fs_avail_bytes
# shellcheck disable=SC2016  # développé par le faux outil
printf '#!/usr/bin/env bash\nprintf "\\033]0;PIRATE\\007 erreur sur %%s\\n" "$1"; exit 1\n' > "$DF/bin/e4defrag"; chmod +x "$DF/bin/e4defrag"
PATH="$DF/bin:$PATH" defrag_file "$DF/cible/vieux.mkv" 1 1 ext4 "$DF/cible" > "$DF/sortie" 2>&1
check "échec de l'outil : raison affichée sans séquence de terminal" not grep -q $'\e' "$DF/sortie"
# Scan : un nom à retour à la ligne ne doit pas faire entrer un chemin relatif au CSV
# shellcheck disable=SC2016  # $f est développé par le faux filefrag
printf '#!/usr/bin/env bash\nfor f; do printf "%%s: 5 extents found\\n" "$f"; done\n' > "$DF/bin/filefrag"; chmod +x "$DF/bin/filefrag"
mkdir -p "$DF/scan"; printf 'x' > "$DF/scan/a"$'\n'"hors.txt"; printf 'x' > "$DF/hors.txt"
( cd "$DF" && PATH="$DF/bin:$PATH" scan_filesystem "$DF/scan" "$DF/f.csv" >/dev/null 2>&1 )
check "scan : chemin hors de la cible écarté du CSV" not grep -q 'hors.txt' "$DF/f.csv"
# Scan : CSV attendu, et coût constant en processus (pas de stat ni numfmt par fichier)
rm -rf "$DF/scan"; mkdir -p "$DF/scan/sous dossier"
head -c 1536 /dev/zero > "$DF/scan/a.mkv"; head -c 3000000 /dev/zero > "$DF/scan/sous dossier/b c.mkv"
printf 'x' > "$DF/scan/petit"; printf 'x' > "$DF/scan/x.part"
for outil in stat numfmt; do
    printf '#!/usr/bin/env bash\necho >> %q\nexec /usr/bin/%s "$@"\n' "$DF/$outil.n" "$outil" > "$DF/bin/$outil"; chmod +x "$DF/bin/$outil"
done
: > "$DF/stat.n"; : > "$DF/numfmt.n"
PATH="$DF/bin:$PATH" scan_filesystem "$DF/scan" "$DF/g.csv" > "$DF/scan.out" 2>&1
check "scan : CSV trié (extents puis taille), tailles lisibles, exclusions" eq "$(cat "$DF/g.csv")" "$CSV_HEADER"$'\n'"3000000"$'\t'"5"$'\t'"2.9M"$'\t'"$DF/scan/sous dossier/b c.mkv"$'\n'"1536"$'\t'"5"$'\t'"1.5K"$'\t'"$DF/scan/a.mkv"$'\n'"1"$'\t'"5"$'\t'"1B"$'\t'"$DF/scan/petit"
check "scan : nombre de fichiers analysés" grep -q "3 fichier(s) fragmenté(s) sur 3 analysé(s)" "$DF/scan.out"
check "scan : au plus 2 appels à stat pour 3 fichiers (par lots)" test "$(wc -l < "$DF/stat.n")" -le 2
check "scan : aucun appel à numfmt" eq "$(wc -l < "$DF/numfmt.n")" 0
mkdir -p "$DF/a\\b"; printf 'x' > "$DF/a\\b/f.mkv"
PATH="$DF/bin:$PATH" scan_filesystem "$DF/a\\b" "$DF/h.csv" > /dev/null 2>&1
check "scan : cible contenant « \\ » analysée" grep -q 'f.mkv' "$DF/h.csv"
rm -rf "$DF"; MIN_FILE_AGE_MIN=60 DRY_RUN=false

echo "surveillance : arrêt d'un outil en cours"
SV="$ROOT/.surv"; mkdir -p "$SV/bin" "$SV/cible"
printf '#!/usr/bin/env bash\nexec sleep 20\n' > "$SV/bin/xfs_fsr"; chmod +x "$SV/bin/xfs_fsr"
printf 'x' > "$SV/cible/f.mkv"; touch -d '2 days ago' "$SV/cible/f.mkv"
MONITOR_DIR="$SV/mon"; mkdir -p "$MONITOR_DIR"; STOPPED_BY_MONITOR=false DRY_RUN=false
( sleep 1; echo "DISK_TEMP:61C" > "$SV/mon/stop" ) &
debut=$SECONDS
PATH="$SV/bin:$PATH" defrag_file "$SV/cible/f.mkv" 5 1 xfs "$SV/cible" > "$SV/sortie" 2>&1
check "fichier en cours : arrêté par la surveillance en moins de 10 s" test $((SECONDS - debut)) -lt 10
check "fichier en cours : arrêt signalé" eq "$STOPPED_BY_MONITOR" true
check "fichier en cours : arrêt expliqué" grep -q "surveillance" "$SV/sortie"
rm -f "$SV/mon/stop"; STOPPED_BY_MONITOR=false
( sleep 1; echo "DISK_TEMP:61C" > "$SV/mon/stop" ) &
debut=$SECONDS
# shellcheck disable=SC2317  # appelée par defrag_global_xfs
fs_source() { echo /dev/faux; }
PATH="$SV/bin:$PATH" defrag_global_xfs "$SV/cible" > "$SV/sortie" 2>&1
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh" 2>/dev/null   # restaure fs_source
check "xfs_fsr global : arrêté par la surveillance en moins de 10 s" test $((SECONDS - debut)) -lt 10
check "xfs_fsr global : arrêt signalé" eq "$STOPPED_BY_MONITOR" true
# Arrêt (SIGTERM d'un orchestrateur, Ctrl+C) : l'outil, lancé en arrière-plan, doit
# être arrêté aussi. SIGTERM ici : un job d'arrière-plan d'un script ignore SIGINT.
printf '#!/usr/bin/env bash\necho $$ > %q\nexec sleep 20\n' "$SV/pid" > "$SV/bin/xfs_fsr"
PATH="$SV/bin:$PATH" bash -c "source '$ROOT/AcmeFrag.sh'; load_modules; trap 'on_interrupt 130' INT; \
    trap 'on_interrupt 143' TERM; MONITOR_DIR=''; defrag_file '$SV/cible/f.mkv' 5 1 xfs '$SV/cible'" > /dev/null 2>&1 &
acme=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -s "$SV/pid" ]] && break; sleep 0.5; done
kill -TERM "$acme"; wait "$acme"; rc_term=$?
check "SIGTERM : code 143" eq "$rc_term" 143
check "SIGTERM : outil en cours arrêté" not kill -0 "$(cat "$SV/pid")" 2>/dev/null
rm -rf "$SV"; MONITOR_DIR="" STOPPED_BY_MONITOR=false

echo "sécurité root (fichiers et dossiers)"
MOI=$(id -u) MON_GID=$(id -g)
SEC_TMP=$(mktemp -d /tmp/acmefrag-test.XXXXXX); chmod 755 "$SEC_TMP"; : > "$SEC_TMP/f"; chmod 644 "$SEC_TMP/f"
SEC="$ROOT/.securite"; mkdir -p "$SEC/sain" "$SEC/ouvert"; chmod 755 "$ROOT" "$SEC" "$SEC/sain"
: > "$SEC/sain/f.sh"; chmod 644 "$SEC/sain/f.sh"
check "chemin à soi, propriétaire autorisé -> sûr" path_trusted "$SEC/sain/f.sh" "$MOI" "$MON_GID"
check "chemin à soi, propriétaire non autorisé -> refusé" not path_trusted "$SEC/sain/f.sh" 0 "$MON_GID"
chmod 664 "$SEC/sain/f.sh"
check "inscriptible par un groupe non autorisé -> refusé" not path_trusted "$SEC/sain/f.sh" "$MOI" 0
check "inscriptible par le groupe de l'utilisateur sudo -> sûr" path_trusted "$SEC/sain/f.sh" "$MOI" "$MON_GID"
chmod 644 "$SEC/sain/f.sh"; chmod 777 "$SEC/ouvert"; : > "$SEC/ouvert/f.sh"
check "dossier parent inscriptible par tous -> refusé" not path_trusted "$SEC/ouvert/f.sh" "$MOI" "$MON_GID"
ln -s "$SEC/sain" "$SEC/lien"
check "lien symbolique sur le chemin -> refusé" not path_trusted "$SEC/lien/f.sh" "$MOI"
check "chemin relatif -> refusé" not path_trusted "sain/f.sh" "$MOI"
check "dossier « sticky » de root (/tmp) comme parent -> sûr" path_trusted "$SEC_TMP/f" "$MOI" "$MON_GID"
check "dossier « sticky » de root comme dossier final -> refusé" not path_trusted /tmp "$MOI" "$MON_GID"
SUDO_UID=$MOI SUDO_GID=$MON_GID
check "confiance : clone de l'utilisateur sudo -> lui et son groupe" eq "$(trusted_owner)" "$MOI $MON_GID"
mkdir -p "$SEC/getent"
# shellcheck disable=SC2016  # développé par le faux getent
printf '#!/usr/bin/env bash\ncase "$1" in group) echo "partage:x:$2:autre" ;; passwd) echo "moi:x:%s:$2::/:/bin/sh" ;; esac\n' "$MOI" > "$SEC/getent/getent"
chmod +x "$SEC/getent/getent"
check "confiance : groupe sudo partagé avec un autre compte -> groupe refusé" eq "$(PATH="$SEC/getent:$PATH" trusted_owner)" "$MOI 0"
# Groupe sans membre déclaré mais principal d'un autre compte (cas « users »)
# shellcheck disable=SC2016  # développé par le faux getent
printf '#!/usr/bin/env bash\ncase "$1" in group) echo "users:x:$2:" ;; passwd) printf "moi:x:%s:%s::/:/bin/sh\\nautre:x:%s:%s::/:/bin/sh\\n" ;; esac\n' \
    "$MOI" "$MON_GID" "$((MOI + 1))" "$MON_GID" > "$SEC/getent/getent"
check "confiance : groupe principal d'un autre compte (« users ») -> groupe refusé" eq "$(PATH="$SEC/getent:$PATH" trusted_owner)" "$MOI 0"
mkdir -p "$SEC/sansgetent"; for o in stat awk cut; do ln -s "$(command -v "$o")" "$SEC/sansgetent/$o"; done
check "confiance : getent absent -> groupe refusé (dans le doute)" eq "$(PATH="$SEC/sansgetent" trusted_owner)" "$MOI 0"
# shellcheck disable=SC2016  # développé par le faux getent
printf '#!/usr/bin/env bash\ncase "$1" in group) echo "g:x:$2:" ;; passwd) exit 2 ;; esac\n' > "$SEC/getent/getent"
check "confiance : énumération des comptes en échec -> groupe refusé" eq "$(PATH="$SEC/getent:$PATH" trusted_owner)" "$MOI 0"
SUDO_UID=$((MOI + 1))
check "confiance : AcmeFrag n'appartient pas à l'utilisateur sudo -> root seul" eq "$(trusted_owner)" "0 0"
unset SUDO_UID SUDO_GID
# Verrou : ne jamais ouvrir (ni tronquer) un fichier posé dans le dossier des rapports
echo "PRÉCIEUX" > "$SEC/victime"; mkdir -p "$SEC/rep"; ln -s "$SEC/victime" "$SEC/rep/.acmefrag.lock"
check "verrou : lien symbolique posé -> cible intacte" bash -c "source '$ROOT/AcmeFrag.sh'; load_modules; REPORT_DIR='$SEC/rep'; acquire_lock; [[ \$(cat '$SEC/victime') == PRÉCIEUX ]]"
ln -s "$SEC/victime" "$SEC/rep/journal.log"
check "journal en lien symbolique -> code 8" bash -c "source '$ROOT/AcmeFrag.sh'; load_modules; set +e; (start_log '$SEC/rep/journal.log') >/dev/null 2>&1; [[ \$? -eq 8 ]]"
check "journal en lien symbolique -> cible intacte" eq "$(cat "$SEC/victime")" "PRÉCIEUX"
# Rapports rendus à l'utilisateur sudo : jamais `chown -R`, jamais un dossier qui n'est pas le sien
mkdir -p "$SEC/bin"; printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> %q\n' "$SEC/chown.log" > "$SEC/bin/chown"; chmod +x "$SEC/bin/chown"
: > "$SEC/chown.log"
PATH="$SEC/bin:$PATH" SUDO_UID=$((MOI + 1)) bash -c "source '$ROOT/AcmeFrag.sh'; load_modules; REPORT_DIR='$SEC/rep'; cleanup"
check "chown : dossier de rapports d'un autre compte que l'utilisateur sudo -> rien" eq "$(cat "$SEC/chown.log")" ""
PATH="$SEC/bin:$PATH" SUDO_UID=$MOI bash -c "source '$ROOT/AcmeFrag.sh'; load_modules; REPORT_DIR='$SEC/rep'; cleanup"
check "chown : jamais récursif" not grep -q -- '-R' "$SEC/chown.log"
printf '#!/usr/bin/env bash\necho "$*" >> %q\n' "$SEC/find.log" > "$SEC/bin/find"; chmod +x "$SEC/bin/find"; : > "$SEC/find.log"
PATH="$SEC/bin:$PATH" SUDO_UID=$MOI bash -c "source '$ROOT/AcmeFrag.sh'; load_modules; trusted_owner() { echo '0 0'; }; REPORT_DIR='$SEC/rep'; cleanup"
check "chown : utilisateur sudo hors confiance (installation root) -> rien" eq "$(cat "$SEC/find.log")" ""
rm -f "$SEC/bin/find"
check "REPORT_DIR avec barre finale normalisé" bash -c "source '$ROOT/lib/common.sh'; ACMEFRAG_HOME='$ROOT' REPORT_DIR=/x/rapports/; source '$ROOT/config.sh'; validate_config && [[ \$REPORT_DIR == /x/rapports ]]"
check "dossier « sticky » de root comme ancêtre à compléter -> sûr" path_trusted /tmp 0 0 parent
# Scan interrompu : aucun fichier temporaire laissé à côté du CSV
mkdir -p "$SEC/scan" "$SEC/scanrep" "$SEC/bin2"
printf 'x' > "$SEC/scan/a"
# Ctrl+C : SIGINT à tout le groupe de processus (pipeline compris), comme au terminal
TEMOIN="$SEC/temoin"; : > "$TEMOIN"; mkdir -p "$SEC/tmp"
# shellcheck disable=SC2016  # développé par le faux outil
printf '#!/usr/bin/env bash\nfor f; do printf "%%s: 5 extents found\\n" "$f"; done\nkill -INT -- "-$ACME_TEST_PID"; sleep 2\n' > "$SEC/bin2/filefrag"; chmod +x "$SEC/bin2/filefrag"
TMPDIR="$SEC/tmp" PATH="$SEC/bin2:$PATH" setsid bash -c "source '$ROOT/AcmeFrag.sh'; load_modules; export ACME_TEST_PID=\$\$; trap cleanup EXIT; trap 'exit 130' INT; REPORT_DIR='$SEC/scanrep'; scan_filesystem '$SEC/scan' '$SEC/scanrep/fragmentation_x.csv'" >/dev/null 2>&1
check "scan interrompu : aucun temporaire laissé" eq "$(ls -A "$SEC/scanrep")" ""
check "scan interrompu : aucun temporaire laissé dans TMPDIR" \
    eq "$(ls -A "$SEC/tmp")" ""
rm -rf "$SEC" "$SEC_TMP"

echo "mineurs : affichage, entiers, codes, quota, configuration"
check "nom avec séquence de terminal : neutralisé à l'affichage" eq "$(printable $'film\e]0;PIRATE\a\e[2J.mkv')" "film?]0;PIRATE??[2J.mkv"
MN="$ROOT/.mineurs"; mkdir -p "$MN"
printf '%s\n' "$CSV_HEADER" $'5\t3\t5B\t/m/film\e[2J.mkv' > "$MN/f.csv"
check "classement : aucune séquence de terminal" not grep -q $'\e' <<< "$(display_top "$MN/f.csv" 5)"
check "entier à zéro initial refusé (08)" not is_uint 08
check "zéro seul accepté" is_uint 0
check "-s 08 -> code 2" bash -c "'$ROOT/AcmeFrag.sh' /x -s 08 >/dev/null 2>&1; [[ \$? -eq 2 ]]"
check "erreur inattendue -> code 1" bash -c "source '$ROOT/AcmeFrag.sh'; load_modules; set +e; (on_error 12 2 'sort x') 2>/dev/null; [[ \$? -eq 1 ]]"
check "flock absent -> code 1 (pas « déjà en cours »)" bash -c "source '$ROOT/AcmeFrag.sh'; load_modules; set +e; REPORT_DIR='$MN'; (PATH=/nonexistent; acquire_lock) 2>/dev/null; [[ \$? -eq 1 ]]"
# Quota -n : un fichier ignoré (récent) ne consomme pas la place d'un fichier traitable
mkdir -p "$MN/cible"; for f in r1 r2 vieux; do printf 'x' > "$MN/cible/$f.mkv"; done
touch -d '2 days ago' "$MN/cible/vieux.mkv"
printf '%s\n' "$CSV_HEADER" $'1\t9\t1B\t'"$MN/cible/r1.mkv" $'1\t8\t1B\t'"$MN/cible/r2.mkv" $'1\t7\t1B\t'"$MN/cible/vieux.mkv" > "$MN/q.csv"
STAT_SIMULATED=0 STAT_SKIPPED=0 DRY_RUN=true MIN_FILE_AGE_MIN=60 MONITOR_DIR=""
process_csv_rows 1 2 "$MN/q.csv" "$MN/cible" > /dev/null 2>&1
check "quota -n 1 : fichiers récents ignorés sans consommer le quota" eq "$STAT_SIMULATED" 1
DRY_RUN=false
# /etc/acmefrag.conf illisible avant sudo (0600) : ne pas conclure « aucune cible »
mkdir -p "$MN/sudo"; printf '#!/usr/bin/env bash\necho appel >> %q\nexit 0\n' "$MN/sudo.log" > "$MN/sudo/sudo"; chmod +x "$MN/sudo/sudo"
: > "$MN/etc.conf"; chmod 000 "$MN/etc.conf"
PATH="$MN/sudo:$PATH" ACMEFRAG_SYSTEM_CONF="$MN/etc.conf" DEFAULT_TARGET="" "$ROOT/AcmeFrag.sh" --auto --dry-run </dev/null >/dev/null 2>&1
check "configuration système illisible avant sudo : relance par sudo" test -s "$MN/sudo.log"
check "surveillance inutile en simulation automatique" not eval 'DRY_RUN=true MONITOR_ENABLE=true monitor_wanted auto'
check "surveillance active en simulation interactive (dry-run désactivable)" eval 'DRY_RUN=true MONITOR_ENABLE=true monitor_wanted interactive'
check "surveillance active hors simulation" eval 'DRY_RUN=false MONITOR_ENABLE=true monitor_wanted auto'
check "surveillance désactivée par --no-monitor" not eval 'DRY_RUN=false MONITOR_ENABLE=false monitor_wanted auto'
# Journal : couleurs à l'écran seulement, jamais dans le fichier
( C_RED=$'\e[31m' C_RESET=$'\e[0m'; start_log "$MN/j.log"; err "rouge" ) >/dev/null 2>&1; sleep 0.3
check "journal : aucune séquence de couleur" not grep -q $'\e' "$MN/j.log"
check "journal : texte écrit" grep -q "rouge" "$MN/j.log"
check "locale UTF-8 imposée (troncature des noms par caractères)" bash -c "LC_ALL=C; source '$ROOT/AcmeFrag.sh'; [[ \$LC_ALL == C.UTF-8 ]]"
check "--sante : --dry-run ignoré, et dit" bash -c "source '$ROOT/AcmeFrag.sh'; load_modules; set +e; CLI_TARGET=/nulle-part CLI_DRY_RUN=true; out=\$(run_health_mode 2>&1); grep -q -- 'Ignoré avec --sante (lecture seule) : --dry-run' <<< \"\$out\""
rm -rf "$MN"

echo "isolation"
check "aucun appel à sudo pendant les tests" eq "$(cat "$SUDO_LOG")" ""

printf '\n%d réussi(s), %d échec(s)\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
