# 🎯 ACMEFRAG

> **Défragmenteur intelligent pour partitions XFS et EXT4** — parce que vos têtes de lecture méritent un traitement ACME !

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Bash](https://img.shields.io/badge/bash-%23121011.svg?style=flat&logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Platform](https://img.shields.io/badge/platform-Raspberry%20Pi-red)](https://www.raspberrypi.org/)
[![Version](https://img.shields.io/badge/version-4.0.0-green.svg)](CHANGELOG.md)

## 📖 Description

**ACMEFRAG** optimise la lecture vidéo sur disques durs en défragmentant les fichiers **XFS** et **EXT4** un par un. Au lieu de tout défragmenter aveuglément, il mesure la fragmentation, ne traite que les fichiers qui gênent vraiment la lecture, protège les SSD, surveille la santé du disque et s'efface devant les usages prioritaires (lecture vidéo, sessions interactives).

### 🎬 Cas d'usage

- **BitTorrent / Syncthing** : fichiers écrits par morceaux, donc très fragmentés
- **Saccades de lecture** vidéo dues à la fragmentation
- **Disques durs pleins** : accès plus réguliers, moins de déplacements de têtes

### ✨ Fonctionnalités

- 🔍 **Scan rapide** XFS et EXT4 (`filefrag` par lots) → rapport CSV trié
- 🧠 **Filtre intelligent** : ignore les fichiers dont l'extent moyen dépasse 4 Go (déjà fluides)
- 🛡️ **Sécurités** : refus du FS racine (disque USB débranché, bind mount compris), des SSD et des disques de type indéterminé, des montages en lecture seule ; verrou anti-double exécution ; en root, refus du code et des dossiers modifiables par un autre compte
- ⏱️ **Fichiers en cours d'écriture ignorés** (modifiés depuis moins d'1 h : téléchargements, synchro)
- 🐢 **Bridage automatique** : `nice 19` + E/S `idle` — la défragmentation ne passe qu'une fois le disque libre (classe `idle` effective avec l'ordonnanceur BFQ : `cat /sys/block/sdX/queue/scheduler`)
- 🌡️ **Surveillance temps réel** : secteurs réalloués SMART, température disque et système, arrêt automatique sur seuil (y compris au milieu d'un fichier ou d'un `xfs_fsr` global)
- 🩺 **Santé du disque** (`--sante`) : relevé SMART en lecture seule (aucun auto-test, disque en veille non réveillé), historique par numéro de série, alertes sur dégradation ; refus de défragmenter un disque qui se dégrade
- 📊 **Bilan** : avant/après mesuré par fichier, résumé de session, santé de l'espace libre
- ⚙️ **Deux modes** : interactif (menu) ou automatique (cron)

---

## 🚀 Installation

```bash
# Dépendances (Debian / Raspberry Pi OS)
sudo apt install xfsprogs e2fsprogs util-linux coreutils smartmontools

git clone https://github.com/jpreculeau/AcmeFrag.git acmefrag
cd acmefrag
sudo ln -sf "$PWD/AcmeFrag.sh" /usr/local/bin/acmefrag   # optionnel : commande globale
```

Le script demande lui-même les droits root (`sudo`) au lancement.

### 🔐 Sécurité

AcmeFrag travaille en root : son code, sa configuration et son dossier de rapports doivent être hors d'atteinte des autres comptes. En root, il refuse (code `8`) tout fichier ou dossier — et chacun de ses parents — qui n'appartient pas à un compte de confiance, qui est un lien symbolique, ou qui est inscriptible par un autre groupe que celui de ce compte (ou par tous, sauf un dossier parent « sticky » de root comme `/tmp`). Les comptes de confiance sont root et, **si AcmeFrag lui appartient**, l'utilisateur qui a lancé `sudo` ; son groupe principal n'est accepté que s'il lui est privé (aucun membre déclaré et aucun autre compte qui l'a pour groupe principal : pas `users`, d'après `getent` ; avec un annuaire réseau qui ne liste pas tous ses comptes, gardez le clone hors d'écriture pour le groupe : `chmod -R g-w`). Le contrôle de `AcmeFrag.sh` lui-même vient forcément après son lancement : c'est au lanceur (cron, sudoers) de garantir ce fichier.

- **Lancement par `sudo` depuis votre clone** (cas ci-dessus) : accepté, vous pourriez de toute façon tout faire en root. Un dossier de rapports neuf est créé à votre nom, et les rapports vous sont rendus.
- **Cron root, ou règle sudoers `NOPASSWD` limitée à AcmeFrag** : installez une copie qui appartient à root, sinon n'importe quel processus de votre compte pourrait modifier le code exécuté en root :

```bash
sudo install -d -o root -g root -m 0755 /usr/local/lib/acmefrag
sudo cp -r AcmeFrag.sh config.sh lib /usr/local/lib/acmefrag/
sudo chown -R root:root /usr/local/lib/acmefrag && sudo chmod -R go-w /usr/local/lib/acmefrag
sudo ln -sf /usr/local/lib/acmefrag/AcmeFrag.sh /usr/local/bin/acmefrag
```

Les rapports sont alors dans `/usr/local/lib/acmefrag/reports` (ou `REPORT_DIR` dans `/etc/acmefrag.conf`, par exemple `/var/lib/acmefrag`) : ils doivent appartenir à root, l'utilisateur sudo n'étant plus de confiance.

Limite connue : un compte qui peut écrire dans la cible (client BitTorrent, synchronisation) peut encore remplacer un fichier par un lien symbolique dans l'instant qui sépare le dernier contrôle du lancement de `xfs_fsr` ou `e4defrag`. Ces outils ne modifient pas le contenu des fichiers qu'ils traitent.

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
| `--sante` | Santé du disque qui porte la cible, sans défragmenter (voir ci-dessous) |
| `--force-sante` | Défragmente malgré une mauvaise santé SMART (déconseillé) |
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

### Santé du disque (`--sante`)

```bash
acmefrag /mnt/HDD --sante
```

Une sonde `smartctl -n standby -i` (pont USB : repli automatique sur `-d sat`) puis une lecture `smartctl -n standby -H -i -A -l error` : **aucun auto-test**, et un disque en veille n'est pas réveillé (mesure reportée). Chaque mesure est ajoutée à `REPORT_DIR/sante/<numéro de série>.tsv` (bilan, attributs 1, 5, 9, 187, 188, 194, 196, 197, 198, 199, erreurs ATA) et comparée à la précédente, avec l'évolution « avant → après ».

Alertes (code `6`) :
- bilan SMART différent de `PASSED` : au **changement** seulement (un FAILED déjà signalé est rappelé « connu » au journal, pour que les vraies aggravations ne soient pas noyées) ;
- hausse des attributs 5, 196, 197, 198, 199 (CRC : câble ou boîtier) ou du nombre d'erreurs ATA ;
- température (attribut 194, à défaut 190) strictement au-dessus de `SMART_TEMP_ALERT_C` (la surveillance pendant une défragmentation, elle, s'arrête dès `DISK_TEMP_THRESHOLD_C` atteint).

Un disque sans numéro de série lisible est mesuré sans historique (pas de comparaison possible) ; un disque dont SMART ne rend ni bilan ni attribut est « mesure impossible » (code `7`).

La dernière ligne, `BILAN SANTÉ : …`, résume le résultat pour un orchestrateur. Aucun verrou : `--sante` peut tourner pendant une défragmentation.

**Garde-fou** : avant toute défragmentation, AcmeFrag refuse (code `3`) un disque au bilan autre que PASSED, avec des secteurs en attente (197), ou dont les secteurs réalloués (5) ont augmenté depuis la plus ancienne mesure `--sante` des `SMART_GUARD_DAYS` derniers jours (30) : des écritures massives sur un disque mourant accélèrent sa fin. Le garde-fou lit l'historique sans l'écrire ; la fenêtre évite qu'un `--sante` quotidien, qui enregistre la hausse, ne la fasse oublier avant la défragmentation suivante. `--force-sante` passe outre ; en `--dry-run`, simple avertissement, et le contrôle est rejoué si l'on quitte le dry-run depuis le menu (touche `d`). Si SMART est illisible (smartmontools absent, pont USB muet), le garde-fou avertit et laisse passer.

### Automatiser avec cron

Le cron root exige une copie d'AcmeFrag qui appartient à root (voir [Sécurité](#-sécurité)) : un clone dans votre dossier personnel y est refusé.

```bash
sudo crontab -e
# Chaque dimanche à 3 h : pas de TTY -> mode automatique
0 3 * * 0 /usr/local/bin/acmefrag /mnt/HDD --auto
# Chaque jour à 8 h : santé du disque
0 8 * * * /usr/local/bin/acmefrag /mnt/HDD --sante
```

Codes de sortie : `0` OK · `1` erreur · `2` usage · `3` refus de sécurité · `4` déjà en cours · `5` arrêt par la surveillance · `8` installation non sûre (voir [Sécurité](#-sécurité)) · `130` interruption (Ctrl+C) · `143` arrêt (SIGTERM). Avec `--sante` : `0` pas de nouvelle dégradation · `6` alerte · `7` mesure impossible (SMART indisponible, disque en veille ou non monté) · `8` installation non sûre.

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
| `DEFAULT_TARGET` | *(vide)* | Cible sans argument (vide : argument obligatoire en auto, choix interactif sinon) |
| `INTEL_THRESHOLD_MO` | `4096` | Extent moyen au-delà duquel le fichier est ignoré |
| `DEFAULT_TOP_LIMIT` / `DEFAULT_MIN_EXTENTS` | `10` / `2` | Mode auto |
| `MIN_FILE_AGE_MIN` | `60` | Ignore les fichiers modifiés récemment |
| `SCAN_EXCLUDES` | `*.tmp *.part *.parts *.!qB .syncthing.* *.crdownload` | Motifs exclus |
| `REPORT_DIR` / `REPORT_MAX_AGE_DAYS` | `<dossier d'AcmeFrag>/reports` / `30` | Rapports CSV, journaux et historique santé (chemin absolu) |
| `QOS_ENABLE` / `QOS_NICE` / `QOS_IO_CLASS` | `true` / `19` / `3` (idle) | Bridage |
| `MONITOR_ENABLE` / `MONITOR_INTERVAL_SEC` | `true` / `30` | Surveillance |
| `SMART_BAD_SECTOR_THRESHOLD` / `..._DRIFT_THRESHOLD` | `50` / `5` | Secteurs réalloués (absolu / dérive) |
| `DISK_TEMP_THRESHOLD_C` / `SYSTEM_TEMP_THRESHOLD_C` | `60` / `85` | Températures critiques |
| `AUTO_STOP_ON_ALERT` | `true` | Arrêt automatique sur alerte |
| `SMART_TEMP_ALERT_C` | `55` | `--sante` : alerte si la température du disque dépasse ce seuil (°C) |
| `SMART_GUARD_DAYS` | `30` | Garde-fou (1 à 3650) : période sur laquelle une hausse des secteurs réalloués bloque la défragmentation |
| `ALLOW_SSD_DEFRAG` / `ALLOW_ROOT_FS` | `false` | Garde-fous |

Priorité : options CLI > `local.conf` > `/etc/acmefrag.conf` (autre chemin : `ACMEFRAG_SYSTEM_CONF`) > variables d'environnement > défauts. Les variables d'environnement ne servent que si AcmeFrag est lancé directement en root : `sudo` les efface.

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
lib/disk_health.sh          Santé du disque : lecture SMART passive, historique, alertes, garde-fou
lib/scan_functions.sh       Scan -> CSV, rotation des rapports
lib/defrag_functions.sh     Défragmentation mesurée (xfs_fsr / e4defrag)
lib/display_functions.sh    Classement, bilans, santé de l'espace libre
lib/maintenance_functions.sh Menu interactif
tests/run_tests.sh          Tests unitaires (sans root ni disque ; faux smartctl, copie sans local.conf)
tests/integration.sh        Tests réels sur images XFS/EXT4 en loop (root)
```

```bash
make lint          # shellcheck
make test          # tests unitaires
sudo make it       # tests d'intégration (images loop, aucun disque réel touché ; IT_TMPDIR=/var/tmp si /tmp est en RAM)
```

---

## 🐛 Dépannage

- **« est sur le système de fichiers racine »** : le disque n'est pas monté (`findmnt /mnt/HDD`), ou la cible est un bind mount de la racine. C'est voulu : on ne défragmente pas la carte SD / le SSD système par erreur.
- **« Type de disque indéterminé »** : le noyau ne dit pas si le disque est rotatif (`lsblk -o NAME,ROTA`). `--force-ssd` si vous êtes sûr qu'il s'agit d'un disque dur.
- **« Refus : … est modifiable par un autre compte »** : voir [Sécurité](#-sécurité) ; `stat -c '%U %G %a' <chemin>` sur le fichier et ses dossiers parents.
- **« SMART indisponible »** : installez `smartmontools` ; certains ponts USB ne relaient pas SMART.
- **« Défragmentation refusée : bilan SMART FAILED »** : le disque annonce sa fin ; sauvegardez-le plutôt que de le réorganiser. `acmefrag <cible> --sante` montre l'évolution, `--force-sante` passe outre.
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
