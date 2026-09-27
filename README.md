# 🎯 ACMEFRAG

> **Défragmenteur intelligent pour partitions XFS et EXT4** — parce que vos têtes de lecture méritent un traitement ACME !

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Bash](https://img.shields.io/badge/bash-%23121011.svg?style=flat&logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Platform](https://img.shields.io/badge/platform-Raspberry%20Pi-red)](https://www.raspberrypi.org/)
[![Version](https://img.shields.io/badge/version-3.0.0-green.svg)](CHANGELOG.md)

## 📖 Description

**ACMEFRAG** optimise la lecture vidéo sur disques durs en défragmentant les fichiers **XFS** et **EXT4** un par un. Au lieu de tout défragmenter aveuglément, il mesure la fragmentation, ne traite que les fichiers qui gênent vraiment la lecture, protège les SSD, surveille la santé du disque et s'efface devant les usages prioritaires (lecture vidéo, sessions interactives).

### 🎬 Cas d'usage

- **BitTorrent / Syncthing** : fichiers écrits par morceaux, donc très fragmentés
- **Saccades de lecture** vidéo dues à la fragmentation
- **Disques durs pleins** : accès plus réguliers, moins de déplacements de têtes

### ✨ Fonctionnalités

- 🔍 **Scan rapide** XFS et EXT4 (`filefrag` par lots) → rapport CSV trié
- 🧠 **Filtre intelligent** : ignore les fichiers dont l'extent moyen dépasse 4 Go (déjà fluides)
- 🛡️ **Sécurités** : refus du FS racine (disque USB débranché), des SSD, des montages en lecture seule ; verrou anti-double exécution
- ⏱️ **Fichiers en cours d'écriture ignorés** (modifiés depuis moins d'1 h : téléchargements, synchro)
- 🐢 **Bridage automatique** : `nice 19` + E/S `idle` — la défragmentation ne passe qu'une fois le disque libre
- 🌡️ **Surveillance temps réel** : secteurs réalloués SMART, température disque et système, arrêt automatique sur seuil
- 📊 **Bilan** : avant/après mesuré par fichier, résumé de session, santé de l'espace libre
- ⚙️ **Deux modes** : interactif (menu) ou automatique (cron)

---

## 🚀 Installation

```bash
# Dépendances (Debian / Raspberry Pi OS)
sudo apt install xfsprogs e2fsprogs util-linux coreutils smartmontools

git clone https://github.com/jpreculeau/acmefrag.git
cd acmefrag
sudo ln -sf "$PWD/AcmeFrag.sh" /usr/local/bin/acmefrag   # optionnel : commande globale
```

Le script demande lui-même les droits root (`sudo`) au lancement.

---

## 💻 Utilisation

```bash
acmefrag --help                        # aide complète
acmefrag /mnt/HDD --dry-run            # voir ce qui serait fait, sans rien modifier
acmefrag /mnt/HDD                      # menu interactif
acmefrag /mnt/HDD/Films --auto         # 10 premiers fichiers éligibles, sans question
acmefrag /mnt/HDD -s 0 -n 50 --auto    # filtre désactivé, 50 fichiers
```

| Option | Effet |
|---|---|
| `--auto` / `--interactive` | Mode (défaut : interactif dans un terminal, automatique sinon) |
| `-s, --seuil N` | Seuil intelligent en Mo/extent (défaut 4096, `0` = tout traiter) |
| `-n, --top N` | Nombre de fichiers éligibles traités en mode auto (défaut 10) |
| `-e, --min-extents N` | Extents minimum pour traiter un fichier (défaut 2) |
| `--dry-run` | Simulation |
| `--force-ssd` | Autorise un SSD (déconseillé) |
| `--no-monitor` / `--no-qos` | Désactive la surveillance / le bridage |

La cible peut être le point de montage ou n'importe quel dossier à l'intérieur.

### Menu interactif

1. Défragmenter les N premiers fichiers éligibles
2. Défragmenter au-delà d'un seuil d'extents
3. Choisir des fichiers dans le classement
4. Afficher le classement · 5. Relancer le scan · 6. État de l'espace libre
7. Défragmentation globale `xfs_fsr` (XFS, durée bornée)
d. Basculer le dry-run · q. Quitter

### Exemple de sortie

```
   🔒 MONITOR: bad_sectors=0 bad_drift=+0 disk_temp=41°C system_temp=55°C alerts=none
⏳ [14:32:18] (  1.4G) Le_Seigneur_des_balos.mkv                     : 47 → 1 extents (-46) ✅
⏳ [14:32:45] (  850M) Game_de_Corniaux.mkv                          : Aucun gain possible (3 extents) ✅
⏳ [14:33:12] (  2.1G) Galadragtus_et_le_serveur_doré.mp4            : Modifié il y a 12 min (écriture en cours ?) ⏭️
```

### Automatiser avec cron

```bash
sudo crontab -e
# Chaque dimanche à 3 h : pas de TTY -> mode automatique
0 3 * * 0 /usr/local/bin/acmefrag /mnt/HDD --auto
```

Codes de sortie : `0` OK · `1` erreur · `2` usage · `3` refus de sécurité · `4` déjà en cours · `5` arrêt par la surveillance · `130` interruption.

---

## ⚙️ Configuration

Les défauts sont documentés dans [`config.sh`](config.sh). **Ne le modifiez pas** : créez plutôt `local.conf` à côté du script (ignoré par git) ou `/etc/acmefrag.conf` :

```bash
# local.conf
DEFAULT_TARGET=/mnt/HDD
INTEL_THRESHOLD_MO=2048
SMART_BAD_SECTOR_THRESHOLD=20
```

| Variable | Défaut | Rôle |
|---|---|---|
| `DEFAULT_TARGET` | `/mnt/HDD` | Cible sans argument |
| `INTEL_THRESHOLD_MO` | `4096` | Extent moyen au-delà duquel le fichier est ignoré |
| `DEFAULT_TOP_LIMIT` / `DEFAULT_MIN_EXTENTS` | `10` / `2` | Mode auto |
| `MIN_FILE_AGE_MIN` | `60` | Ignore les fichiers modifiés récemment |
| `SCAN_EXCLUDES` | `*.tmp *.part *.parts *.!qB .syncthing.* *.crdownload` | Motifs exclus |
| `REPORT_DIR` / `REPORT_MAX_AGE_DAYS` | `./reports` / `30` | Rapports CSV et journaux |
| `QOS_ENABLE` / `QOS_NICE` / `QOS_IO_CLASS` | `true` / `19` / `3` (idle) | Bridage |
| `MONITOR_ENABLE` / `MONITOR_INTERVAL_SEC` | `true` / `30` | Surveillance |
| `SMART_BAD_SECTOR_THRESHOLD` / `..._DRIFT_THRESHOLD` | `50` / `5` | Secteurs réalloués (absolu / dérive) |
| `DISK_TEMP_THRESHOLD_C` / `SYSTEM_TEMP_THRESHOLD_C` | `60` / `85` | Températures critiques |
| `AUTO_STOP_ON_ALERT` | `true` | Arrêt automatique sur alerte |
| `ALLOW_SSD_DEFRAG` / `ALLOW_ROOT_FS` | `false` | Garde-fous |

Priorité : options CLI > `local.conf` > `/etc/acmefrag.conf` > variables d'environnement > défauts.

---

## 📊 Rapport CSV

`reports/fragmentation_AAAA-MM-JJ.csv`, séparateur **tabulation** (les noms de films contiennent volontiers des `;`), trié par extents puis taille décroissants :

```
Octets	Extents	Taille	Chemin
2899102105	731	2.7G	/mnt/HDD/Films/Mon.Film.2017.mkv
```

Le journal complet de chaque session est dans `reports/acmefrag_AAAA-MM-JJ.log`.

---

## 🏗️ Architecture

```
AcmeFrag.sh                 Point d'entrée : arguments, root, QoS, verrou, orchestration
config.sh                   Défauts documentés + validation
lib/common.sh               Journalisation, codes de sortie, FS/disque, mesure des extents
lib/security_checks.sh      Vérifications préalables, sélection de la cible
lib/security_monitor.sh     Surveillance SMART / températures en tâche de fond
lib/scan_functions.sh       Scan -> CSV, rotation des rapports
lib/defrag_functions.sh     Défragmentation mesurée (xfs_fsr / e4defrag)
lib/display_functions.sh    Classement, bilans, santé de l'espace libre
lib/maintenance_functions.sh Menu interactif
tests/run_tests.sh          Tests unitaires (sans root)
tests/integration.sh        Tests réels sur images XFS/EXT4 en loop (root)
```

```bash
make lint          # shellcheck
make test          # tests unitaires
sudo make it       # tests d'intégration (images loop, aucun disque réel touché ; IT_TMPDIR=/var/tmp si /tmp est en RAM)
```

---

## 🐛 Dépannage

- **« est sur le système de fichiers racine »** : le disque n'est pas monté (`findmnt /mnt/HDD`). C'est voulu : on ne défragmente pas la carte SD / le SSD système par erreur.
- **« SMART indisponible »** : installez `smartmontools` ; certains ponts USB ne relaient pas SMART.
- **Beaucoup d'« Espace libre insuffisant »** : libérez de la place ou lancez la défragmentation globale (menu 7, XFS).
- **Rien n'est traité** : les fichiers sont peut-être déjà assez contigus (colonne `TRAITABLE`), essayez `-s 0`.

---

## 📜 Licence

Copyright (C) 2026 Jean-Philippe Reculeau.

Ce programme est un logiciel libre, distribué sous la **GNU General Public License v3** ou toute version ultérieure (`GPL-3.0-or-later`) : vous pouvez l'utiliser, y compris commercialement, le modifier et le redistribuer, à condition que toute version redistribuée reste sous GPL avec son code source. Il est fourni **sans aucune garantie**. Texte complet : [LICENSE](LICENSE).

## 👤 Auteur

**Jean-Philippe Reculeau** — [GitHub](https://github.com/jpreculeau/acmefrag)

## 📚 Ressources

- [Documentation XFS](https://xfs.wiki.kernel.org/) · [xfs_fsr(8)](https://man7.org/linux/man-pages/man8/xfs_fsr.8.html) · [e4defrag(8)](https://man7.org/linux/man-pages/man8/e4defrag.8.html) · [filefrag(8)](https://man7.org/linux/man-pages/man8/filefrag.8.html)
