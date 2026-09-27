#!/usr/bin/env bash
# Tests d'intégration AcmeFrag sur des images XFS et EXT4 montées en loop.
# Requiert root, mkfs.xfs, mkfs.ext4. N'utilise AUCUN disque réel.
# Usage : sudo tests/integration.sh [xfs] [ext4]
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ACME="$ROOT/AcmeFrag.sh"
(( EUID == 0 )) || { echo "root requis"; exit 1; }
# IT_TMPDIR : dossier des images (éviter un /tmp en RAM sur petite machine)
WORK=$(mktemp -d "${IT_TMPDIR:-/tmp}/acmefrag-it.XXXXXX")
PASS=0 FAIL=0
MNT="" LOOP=""

cleanup() {
    if [[ -n "$MNT" ]]; then umount "$MNT" 2>/dev/null || true; fi
    if [[ -n "$LOOP" ]]; then losetup -d "$LOOP" 2>/dev/null || true; fi
    rm -rf "$WORK"
}
trap cleanup EXIT

check() {
    local desc="$1"; shift
    if "$@"; then PASS=$((PASS + 1)); echo "  ok   $desc"
    else FAIL=$((FAIL + 1)); echo "  FAIL $desc"; fi
}
not() { ! "$@"; }
extents() { filefrag "$1" | sed -E 's/.*: ([0-9]+) extents? found$/\1/'; }

# Deux fichiers écrits en alternance par blocs de 64 Kio avec fsync : fragmentés
make_fragmented() {
    local a="$1" b="$2" i
    for i in $(seq 1 80); do
        dd if=/dev/urandom of="$a" bs=64K count=1 oflag=append conv=notrunc,fsync status=none
        dd if=/dev/urandom of="$b" bs=64K count=1 oflag=append conv=notrunc,fsync status=none
    done
}

run_acme() {  # lance AcmeFrag comme le ferait cron : pas de TTY, pas de TERM
    env -u TERM REPORT_DIR="$WORK/reports" MIN_FILE_AGE_MIN=60 \
        "$ACME" "$@" < /dev/null > "$WORK/out.log" 2>&1
}

test_fs() {
    local fs="$1" rc
    echo "== $fs"
    truncate -s 400M "$WORK/$fs.img"
    "mkfs.$fs" -q "$WORK/$fs.img" >/dev/null 2>&1 || "mkfs.$fs" -q -F "$WORK/$fs.img"
    LOOP=$(losetup -f --show "$WORK/$fs.img")
    MNT="$WORK/mnt-$fs"; mkdir -p "$MNT"; mount "$LOOP" "$MNT"

    mkdir -p "$MNT/films"
    make_fragmented "$MNT/films/vieux A.mkv" "$MNT/films/vieux: B.mkv"
    touch -d '2 days ago' "$MNT/films/vieux A.mkv" "$MNT/films/vieux: B.mkv"
    make_fragmented "$MNT/films/recent.mkv" "$MNT/films/recent2.mkv"
    local a0 b0 r0
    a0=$(extents "$MNT/films/vieux A.mkv"); b0=$(extents "$MNT/films/vieux: B.mkv")
    r0=$(extents "$MNT/films/recent.mkv")
    check "$fs : fichiers de test fragmentés ($a0/$b0/$r0 extents)" test "$a0" -gt 2 -a "$b0" -gt 2 -a "$r0" -gt 2

    rc=0; run_acme "$MNT" --dry-run --no-monitor --force-ssd || rc=$?
    check "$fs : dry-run hors TTY -> code 0" test "$rc" -eq 0
    check "$fs : dry-run en mode auto" grep -q "MODE AUTOMATIQUE" "$WORK/out.log"
    check "$fs : dry-run ne modifie rien" test "$(extents "$MNT/films/vieux A.mkv")" -eq "$a0"
    check "$fs : CSV produit" test -s "$WORK/reports/fragmentation_$(date +%Y-%m-%d).csv"

    rc=0; run_acme "$MNT/films" -s 0 --no-monitor --force-ssd || rc=$?
    check "$fs : défragmentation réelle -> code 0" test "$rc" -eq 0
    check "$fs : 'vieux A' défragmenté ($a0 -> $(extents "$MNT/films/vieux A.mkv"))" test "$(extents "$MNT/films/vieux A.mkv")" -lt "$a0"
    check "$fs : nom avec ': ' traité ($b0 -> $(extents "$MNT/films/vieux: B.mkv"))" test "$(extents "$MNT/films/vieux: B.mkv")" -lt "$b0"
    check "$fs : fichier récent protégé" test "$(extents "$MNT/films/recent.mkv")" -eq "$r0"
    check "$fs : journal écrit" test -s "$WORK/reports/acmefrag_$(date +%Y-%m-%d).log"

    # Menu interactif piloté par stdin : classement, bascule dry-run, TOP N, sélection, quitter
    rc=0
    printf '4\nd\n1\n3\n1 2\nq\n' | env -u TERM REPORT_DIR="$WORK/reports" \
        "$ACME" "$MNT" --interactive --no-monitor --force-ssd > "$WORK/menu.log" 2>&1 || rc=$?
    check "$fs : menu interactif -> code 0" test "$rc" -eq 0
    check "$fs : menu affiché et dry-run basculé" grep -q "Dry-run ACTIVÉ" "$WORK/menu.log"

    # Deux lancements successifs AVEC surveillance : le verrou doit être libéré à la sortie
    rc=0
    env -u TERM REPORT_DIR="$WORK/reports" MONITOR_INTERVAL_SEC=30 "$ACME" "$MNT" --dry-run --auto --force-ssd </dev/null >/dev/null 2>&1 || rc=$?
    env -u TERM REPORT_DIR="$WORK/reports" MONITOR_INTERVAL_SEC=30 "$ACME" "$MNT" --dry-run --auto --force-ssd </dev/null >/dev/null 2>&1 || rc=$?
    check "$fs : verrou libéré entre deux lancements surveillés" test "$rc" -ne 4

    # Verrou : une seconde instance doit refuser (code 4)
    exec {fd}> "$WORK/reports/.acmefrag.lock"; flock "$fd"
    rc=0; run_acme "$MNT" --dry-run --no-monitor --force-ssd || rc=$?
    check "$fs : instance concurrente refusée (code 4)" test "$rc" -eq 4
    exec {fd}>&-

    umount "$MNT"; losetup -d "$LOOP"; MNT="" LOOP=""
    check "$fs : aucune erreur inattendue" not grep -q "Erreur inattendue" "$WORK/reports/acmefrag_$(date +%Y-%m-%d).log"
}

# FS racine / non supporté : refus (code 3)
rc=0; run_acme / --dry-run --no-monitor --force-ssd || rc=$?
check "racine refusée (code 3)" test "$rc" -eq 3
rc=0; run_acme "$WORK/inexistant" --dry-run || rc=$?
check "dossier inexistant refusé (code 3)" test "$rc" -eq 3

for fs in "${@:-xfs ext4}"; do
    for f in $fs; do test_fs "$f"; done
done

printf '\n%d réussi(s), %d échec(s)\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
