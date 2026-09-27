#!/usr/bin/env bash
# Tests unitaires AcmeFrag — sans root, sans disque. Usage : tests/run_tests.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
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
rm -rf "$MONITOR_DIR" "$REPORT_DIR"

printf '\n%d réussi(s), %d échec(s)\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
