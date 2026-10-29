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
REPORT_DIR=$(mktemp -d); load_modules

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
check "--help -> code 0"          bash -c "'$ROOT/AcmeFrag.sh' --help | grep -q ACMEFRAG"
CLI_MODE=""
check "hors terminal -> mode auto" eq "$(resolve_mode < /dev/null)" auto

echo "divers"
check "human_size" eq "$(human_size $((2621440 * 1024)))" "2.5G"
mapfile -d '' -t ex < <(_find_exclude_args)
check "exclusions find" eq "${ex[0]} ${ex[1]} ${ex[2]}" "! -name *.tmp"
MONITOR_DIR=$(mktemp -d)
printf 'bad_sectors=3\nbad_drift=1\ndisk_temp=41\nsystem_temp=55\nalerts=none\n' > "$MONITOR_DIR/status"
check "ligne monitor" eq "$(monitor_status_line)" "   🔒 MONITOR: bad_sectors=3 bad_drift=+1 disk_temp=41°C system_temp=55°C alerts=none"
check "pas d'arrêt sans fichier stop" bash -c "! [[ -f '$MONITOR_DIR/stop' ]]"
echo "BAD" > "$MONITOR_DIR/stop"
check "arrêt demandé" monitor_should_stop
rm -rf "$MONITOR_DIR"; MONITOR_DIR=""

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

echo "sécurité root (fichiers et dossiers)"
MOI=$(id -u) MON_GID=$(id -g)
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
check "dossier « sticky » de root (/tmp) -> sûr" path_trusted /tmp
# Verrou : ne jamais ouvrir (ni tronquer) un fichier posé dans le dossier des rapports
echo "PRÉCIEUX" > "$SEC/victime"; mkdir -p "$SEC/rep"; ln -s "$SEC/victime" "$SEC/rep/.acmefrag.lock"
check "verrou : lien symbolique posé -> cible intacte" bash -c "source '$ROOT/AcmeFrag.sh'; load_modules; REPORT_DIR='$SEC/rep'; acquire_lock; [[ \$(cat '$SEC/victime') == PRÉCIEUX ]]"
ln -s "$SEC/victime" "$SEC/rep/journal.log"
check "journal en lien symbolique -> code 3" bash -c "source '$ROOT/AcmeFrag.sh'; load_modules; set +e; (start_log '$SEC/rep/journal.log') >/dev/null 2>&1; [[ \$? -eq 3 ]]"
check "journal en lien symbolique -> cible intacte" eq "$(cat "$SEC/victime")" "PRÉCIEUX"
# Rapports rendus à l'utilisateur sudo : jamais `chown -R`, jamais un dossier qui n'est pas le sien
mkdir -p "$SEC/bin"; printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> %q\n' "$SEC/chown.log" > "$SEC/bin/chown"; chmod +x "$SEC/bin/chown"
: > "$SEC/chown.log"
PATH="$SEC/bin:$PATH" SUDO_UID=$((MOI + 1)) bash -c "source '$ROOT/AcmeFrag.sh'; load_modules; REPORT_DIR='$SEC/rep'; cleanup"
check "chown : dossier de rapports d'un autre compte que l'utilisateur sudo -> rien" eq "$(cat "$SEC/chown.log")" ""
PATH="$SEC/bin:$PATH" SUDO_UID=$MOI bash -c "source '$ROOT/AcmeFrag.sh'; load_modules; REPORT_DIR='$SEC/rep'; cleanup"
check "chown : jamais récursif" not grep -q -- '-R' "$SEC/chown.log"
# Scan interrompu : aucun fichier temporaire laissé à côté du CSV
mkdir -p "$SEC/scan" "$SEC/scanrep" "$SEC/bin2"
printf 'x' > "$SEC/scan/a"
# shellcheck disable=SC2016  # $ACME_TEST_PID est développé par le faux filefrag
printf '#!/usr/bin/env bash\nkill -INT "$ACME_TEST_PID"; sleep 2\n' > "$SEC/bin2/filefrag"; chmod +x "$SEC/bin2/filefrag"
PATH="$SEC/bin2:$PATH" bash -c "source '$ROOT/AcmeFrag.sh'; load_modules; export ACME_TEST_PID=\$\$; trap cleanup EXIT; trap 'exit 130' INT; REPORT_DIR='$SEC/scanrep'; scan_filesystem '$SEC/scan' '$SEC/scanrep/fragmentation_x.csv'" >/dev/null 2>&1
check "scan interrompu : aucun temporaire laissé" eq "$(ls -A "$SEC/scanrep")" ""
rm -rf "$SEC"

echo "isolation"
check "aucun appel à sudo pendant les tests" eq "$(cat "$SUDO_LOG")" ""

printf '\n%d réussi(s), %d échec(s)\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
