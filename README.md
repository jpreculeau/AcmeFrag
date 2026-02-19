# 🎯 ACMEFRAG

> **Défragmenteur intelligent pour partitions XFS et EXT4** - Parce que vos têtes de lecture méritent un traitement ACME !

[![License: GPL v3 + Commercial](https://img.shields.io/badge/License-GPLv3%2BCommercial-blue.svg)](LICENSE)
[![Bash](https://img.shields.io/badge/bash-%23121011.svg?style=flat&logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Platform](https://img.shields.io/badge/platform-Raspberry%20Pi-red)](https://www.raspberrypi.org/)
[![Version](https://img.shields.io/badge/version-2.0.0-green.svg)]()

## 📖 Description

**ACMEFRAG** est un script bash «intelligent» conçu pour optimiser la lecture vidéo sur disques durs en défragmentant les fichiers **XFS** et **EXT4** fichier par fichier. Contrairement aux outils traditionnels qui tentent de tout défragmenter aveuglément, ACMEFRAG analyse intelligemment la fragmentation, protège les SSDs, et ne traite que les fichiers qui en ont vraiment besoin.

### 🎬 Cas d'usage idéal

- **Bitorrent / Syncthing** Morcellement des fichiers important
- **Élimination des saccades** causées par la fragmentation lors d’une lecture vidéos
- **Optimisation des disques durs** (HDD) Des accès plus constant et contribue à éviter une fragmentation sur disques saturés
- **Maintenance préventive** Améliore la durée de vie des HDD en évitant des seek constants

### ✨ Fonctionnalités principales

- 🔍 **Analyse complète** de la fragmentation sur systèmes de fichiers **XFS et EXT4**
- 🧠 **Défragmentation intelligente** : ignore les fichiers déjà optimaux (blocs > 4Go)
- 🛡️ **Protection SSD automatique** : détecte et refuse la défragmentation sur SSDs
- 📊 **Rapports CSV horodatés** avec tri par niveau de fragmentation
- 🏆 **TOP 10** des fichiers les plus fragmentés
- 🔒 **Sécurités avancées** : vérification du point de montage, du type de FS et du type de disque
- 🧹 **Auto-nettoyage** : suppression des rapports > 30 jours
- 📈 **Diagnostic santé** : analyse de l'espace libre du disque
- ⚙️ **Modes d'exécution** : interactif ou automatique (cron-friendly)
- 📦 **Architecture modulaire** : code facile à maintenir et à étendre
- 🌡️ **Surveillance en temps réel** : SMART (secteurs réalloués), température disque/système
- 🚨 **Arrêt automatique** : interruption intelligente sur seuils critiques

---

## 🚀 Installation rapide

### Prérequis

- **OS** : toute distribution Linux
- **Système de fichiers** : XFS ou EXT4
- **Paquets requis** : 
  - XFS : `xfsprogs`, `bc`, `coreutils`
  - EXT4 : `e2fsprogs`, `bc`, `coreutils`
- **Droits** : `sudo` pour les opérations de défragmentation

### Installation en 3 étapes

```bash
# 1️⃣ Installer les dépendances
sudo apt update && sudo apt install xfsprogs bc -y

# 2️⃣ Cloner et configurer
git clone https://github.com/jpreculeau/acmefrag.git
cd acmefrag
chmod +x AcmeFrag.sh

# 3️⃣ (Optionnel) Installation globale
sudo cp AcmeFrag.sh /usr/local/bin/acmefrag
```

---

## 💻 Utilisation

### Commandes essentielles

```bash
# Analyse du dossier par défaut
./AcmeFrag.sh

# Analyse d'un dossier spécifique (mode interactif)
./AcmeFrag.sh /mnt/mon-disque/

# Mode automatique (pour cron)
./AcmeFrag.sh --auto

# Avec chemin personnalisé (pour cron)
./AcmeFrag.sh /mnt/HDD/Films --auto
```

### Menu interactif

Le script propose trois options :
1. **Défragmenter le TOP 10** des fichiers les plus fragmentés
2. **Défragmenter selon un seuil personnalisé** (nombre d'extents)
3. **Quitter**

### Exemples de sortie

```
⏳ [14:32:18] (1.4G ) Le_Seigneur_des_balos.mkv           : before:47 after:1 ✅
⏳ [14:32:45] (850M ) Game_de_Corniaux.mkv                : Déjà optimisé ✅
⏳ [14:33:12] (2.1G ) Galadragtus et le serveur doré.mp4  : before:23 after:2 ✅
```

---

## ⚙️ Configuration

### Variables modifiables

| Variable | Par défaut | Description |
|----------|-----------|-------------|
| `DEFAULT_TARGET` | `/mnt/HDD` | Dossier analysé si aucun argument fourni |
| `INTEL_THRESHOLD_MO` | `4096` | Taille min d'un extent (Mo) pour ignorer le fichier |
| `OUTPUT_CSV` | `fragmentation_YYYY-MM-DD.csv` | Nom du rapport généré |
| `REPORT_RETENTION_DAYS` | `30` | Jours de rétention des rapports |
| **Surveillance & Sécurité** | | |
| `MONITOR_INTERVAL_SEC` | `5` | Fréquence des relevés SMART et température (secondes) |
| `SMART_BAD_SECTOR_THRESHOLD` | `100` | Seuil critique absolu de secteurs réalloués |
| `SMART_BAD_SECTOR_DRIFT_THRESHOLD` | `5` | Dérive autorisée durant l'exécution (secteurs) |
| `DISK_TEMP_THRESHOLD_C` | `60` | Température critique du disque (°C) |
| `SYSTEM_TEMP_THRESHOLD_C` | `85` | Température critique du système (°C) |
| `AUTO_STOP_ON_ALERT` | `true` | Arrêt automatique des opérations en cas d'alerte |

### Personnaliser les paramètres

```bash
nano config.sh

# Exemple : Changer le seuil intelligent à 2Go
INTEL_THRESHOLD_MO=2048
```

---

## 📋 Guide de démarrage

### ✅ Avant de commencer

Vérifiez que votre disque utilise XFS ou EXT4 :

```bash
df -T /mnt/HDD
# Résultat attendu : xfs ou ext4 dans la colonne Type
```

### 🎯 Premier usage (5 minutes)

```bash
# 1. Lancer une analyse simple
./AcmeFrag.sh

# 2. Consulter le rapport généré
cat fragmentation_$(date +%Y-%m-%d).csv

# 3. Si nécessaire, lancer la défragmentation
```

### 🔄 Automatiser avec cron

```bash
# Éditer le crontab
crontab -e

# Ajouter cette ligne : chaque dimanche à 3h du matin
0 3 * * 0 /usr/local/bin/acmefrag --auto >> /var/log/acmefrag.log 2>&1
```

---

## 🔄 Mise à jour

### Mettre à jour vers v2.0

Si vous avez une version antérieure (v1.0 ou v1.5), la mise à jour est simple :

```bash
# 1. Aller dans le répertoire d'installation
cd /chemin/vers/acmefrag

# 2. Récupérer les dernières modifications
git pull origin main

# 3. Vérifier les fichiers à jour
ls -la AcmeFrag.sh config.sh *.sh

# 4. Tester sur un dossier de test
./AcmeFrag.sh /mnt/test --dry-run
```

### Changements en v2.0

- ✅ Nouveau support EXT4 en plus de XFS
- ✅ Protection SSD automatique
- ✅ Architecture modulaire (7 modules au lieu d'1)
- ✅ Configuration centralisée dans `config.sh`
- ✅ Gestion d'erreur robuste

---

## 🗑️ Suppression / Désinstallation

### Désinstallation locale
lter les rapports CSV | ❌ Ignorer les avertissements |

### Désinstallation système (installation globale)

```bash
# Supprimer le script du répertoire système
sudo rm /usr/local/bin/acmefrag

# Supprimer la tâche cron (optionnel)
crontab -e
# Puis supprimer la ligne du crontab

# Nettoyer les rapports générés
rm ~/fragmentation_*.csv
rm /tmp/acmefrag_*.log
```

### Vérifier la suppression

```bash
# Vérifier que le script n'est plus accessible
which acmefrag
# Ne doit rien retourner

# Vérifier les rapports résiduels
ls -la fragmentation_*.csv
# Ne doit rien trouver
```

### Note : Sauvegarde avant suppression

```bash
# Si vous voulez garder vos rapports CSV avant suppression
mkdir -p ~/acmefrag_backup
cp fragmentation_*.csv ~/acmefrag_backup/
cp /tmp/acmefrag_*.log ~/acmefrag_backup/ 2>/dev/null || true
```

---

## 🏗️ Architecture modulaire (v2.0)

AcmeFrag v2.0 repose sur une **architecture modulaire et maintenable** :

```
AcmeFrag.sh                 # Orchestrateur principal
├── config.sh              # Configuration centralisée
├── security_checks.sh     # Vérifications de sécurité et détection SSD
├── scan_functions.sh      # Analyse de la fragmentation
├── defrag_functions.sh    # Défragmentation des fichiers
├── display_functions.sh   # Affichage et rapports
└── maintenance_functions.sh # Gestion du menu interactif
```

### Avantages de cette architecture

- ✅ **Maintenabilité** : Chaque module a une responsabilité unique
- ✅ **Réutilisabilité** : Les fonctions peuvent être importées dans d'autres scripts
- ✅ **Robustesse** : Gestion d'erreur cohérente (`set -euo pipefail`)
- ✅ **Extensibilité** : Facile d'ajouter de nouvelles fonctionnalités
- ✅ **Documentation** : Chaque fonction est complètement documentée

---

## 🌡️ Surveillance en temps réel & Module de Sécurité

### Vue d'ensemble

ACMEFRAG v2.0 inclut un **module de surveillance autonome** (`security_monitor.sh`) qui fonctionne en parallèle de la défragmentation :

- 📊 Lit les attributs SMART pour détecter les secteurs réalloués
- 🌡️ Surveille la température du disque (SMART) et du système (lm-sensors)
- 📈 Calcule la **dérive** (augmentation) des secteurs défectueux durant l'exécution
- 🚨 Déclenche un **arrêt automatique** si les seuils critiques sont franchis
- 📝 Affiche un **statut dynamique** avant chaque fichier traité

### Préparer l'environnement

Installez les dépendances optionnelles pour une surveillance complète :

```bash
# Détecter les capteurs thermiques (une seule fois)
sudo apt install lm-sensors smartmontools -y
sudo sensors-detect --yes

# Vérifier les cœurs de témperature disponibles
sensors

# Vérifier SMART (si le disque le supporte)
sudo smartctl -A /dev/sda | grep "Reallocated\|Temperature"
```

### Seuils et comportement

| Seuil | Valeur défaut | Action |
|-------|---------------|--------|
| **Bad Sectors absolus** | 100 | ⚠️ Alerte; 150 = Arrêt auto |
| **Dérive SMART** | +5 secteurs | ⚠️ Alerte; +10 = Arrêt auto |
| **Température disque** | 60°C | ⚠️ Alerte; 70°C = Arrêt auto |
| **Température système** | 85°C | ⚠️ Alerte; 95°C = Arrêt auto |

### Affichage du statut en temps réel avec code couleur

Pendant la défragmentation, vous verrez un écran qui se rafraîchit avec :

**Zone de surveillance fixe en haut** (avec code couleur) :

```
==============================================================================
---   🔒 STATUT DE SÉCURITÉ (MONITOR)
==============================================================================
   Horodatage         : 2026-02-19 14:32:45
   Périphérique       : /dev/sda1
   SMART disponible   : true
   Secteurs réalloués : 45          [VERT: <50  | YELLOW: 50-100 | ROUGE: ≥100]
   Dérive (Δ)         : +2          [VERT: <5   | YELLOW: 5-10   | ROUGE: ≥10]
   Temp disque        : 52°C        [VERT: <50  | YELLOW: 50-60  | ROUGE: ≥60]
   Temp système       : 62°C        [VERT: <75  | YELLOW: 75-85  | ROUGE: ≥85]
   ALERTES            : none        [VERT: none | ROUGE: détectée]
==============================================================================
```

**Zone de fichiers traités (défilé dynamique)** :

```
--- Fichiers traités ---
14:32:18 - /mnt/HDD/Films/BugsBunny.mkv : 47 → 1 extents ✅
14:32:45 - /mnt/HDD/Films/Game.mkv : Déjà optimisé ✅
14:33:12 - /mnt/HDD/Films/LongMovie.mp4 : 23 → 2 extents ✅
```

**Code couleur appliqué** :
- 🟢 **VERT** : Normal, aucun problème
- 🟡 **JAUNE** : Zone d'alerte, à surveiller
- 🔴 **ROUGE** : Seuil critique, arrêt automatique possible

### En cas d'arrêt automatique

Si un seuil critique est dépassé, le script arrête proprement :

```
🔒 MONITOR: bad_sectors=105 bad_drift=+0 disk_temp=68C system_temp=88C alerts=BAD_SECTORS_HIGH,SYS_TEMP
🚨 Arrêt automatique déclenché par le module de surveillance. Opérations interrompues.

✅ Tâche complétée avec succès! (interrompue proprement)
```

### Personnaliser les seuils (config.sh)

```bash
# Éditer config.sh et ajuster :
MONITOR_INTERVAL_SEC=5                   # Relevés toutes les 5 secondes
SMART_BAD_SECTOR_THRESHOLD=100           # Secteurs réalloués max
SMART_BAD_SECTOR_DRIFT_THRESHOLD=5       # Augmentation max tolérée
DISK_TEMP_THRESHOLD_C=60                 # Température disque max
SYSTEM_TEMP_THRESHOLD_C=85               # Température système max
AUTO_STOP_ON_ALERT="true"                # true = arrêt auto, false = avertissement seulement
```

### Dépannage du monitoring

| Problème | Cause | Solution |
|----------|-------|----------|
| "MONITOR: device=unknown" | smartctl non trouvé | `sudo apt install smartmontools` |
| "disk_temp: N/A" | SMART non dispo | Disque trop vieux ou USB |
| "system_temp: N/A" | lm-sensors absent | `sudo apt install lm-sensors && sudo sensors-detect` |
| Monitor ne s'arrête pas | `AUTO_STOP_ON_ALERT=false` | Modifier dans `config.sh` |

---

## 🔒 Sécurité et bonnes pratiques

### ⚠️ Points importants

| ✓ À faire | ✗ À éviter |
|-----------|-----------|
| ✅ Exécuter pendant les heures creuses | ❌ Lancer pendant le streaming actif |
| ✅ Faire une sauvegarde avant | ❌ Interrompre brutalement (Ctrl+C OK) |
| ✅ Surveiller l'espace libre (>10%) | ❌ Lancer plusieurs instances |
| ✅ Consuet EXT4 uniquement** : Ne fonctionne qu'avec ces deux systèmes de fichiers
2. **Droits root** : Nécessaire pour `xfs_fsr`, `xfs_bmap`, `e4defrag` et `filefrag`
3. **Espace disque** : Minimum 10% libre requis
4. **SSD protégés** : La défragmentation est automatiquement bloquée sur les SSDs
5. **I/O intensive** : Peut ralentir lors de défragmentation (utiliser hors-pics)
1. **XFS uniquement** : Ne fonctionne qu'avec XFS
2. **Droits root** : Nécessaire pour `xfs_fsr` et `xfs_bmap`
3. **Espace disque** : Minimum 10% libre requis
4. **I/O intensive** : Peut ralentir lors de défragmentation

---

## 📊 Rapports CSV

### Format des données

```csv
Taille,Extents,Dossier,Nom,Chemin_Complet
1.4G,47,/mnt/HDD/Films,BugsBunny.mkv,/mnt/HDD/Films/BugsBunny.mkv
```

| Colonne | Signification |
|---------|---------------|
| **Taille** | Format lisible (1.4G, 500M, etc.) |
| **Extents** | Nombre de fragments (moins = mieux) |
| **Dossier** | Répertoire parent |
| **Nom** | Nom du fichier |
- [x] Support EXT4 ✅ (v2.0)
- [x] Protection SSD ✅ (v2.0)
- [x] Architecture modulaire ✅ (v2.0)
- [ ] Affichage dynamique des températures et données SMART
- [ ] Mode dry-run avancé
- [ ] Gestion des fichiers partiellement fragmentés

## 🐛 Dépannage

### "n'est pas un point de montage"
Ce projet est licencié sous la **GNU General Public License v3 (GPL v3)** :

- ✅ **Usage personnel et non-commercial** : Libre d'utilisation, modification et distribution
- ℹ️ **Usage commercial** : Merci de nous contacter pour discuter d'une licence appropriée

``` /mnt/SSD --force-ssd  # À utiliser avec extrême prudence
```

### "Espace insuffisant"

```bash
# Voir l'usage disque
df -h /mnt/HDD

# Solution : Augmenter le seuil intelligent
INTEL_THRESHOLD_MO=8192  # Ignorer les gros fichiers
```

---

## 🤝 Contribution

Vos contributes sont bienvenues !

```bash
# 1. Fork le projet
# 2. Créer une branche
git checkout -b feature/votre-idee

# 3. Commit et push
git commit -m "Ajout : description"
git push origin feature/votre-idee

# 4. Ouvrir une Pull Request
```

### Roadmap

- [ ] Support EXT4
- [ ] Affichage Dynamique des températures et données SMART
- [ ] Fool Proof
- [ ] Mode dry-run
- [ ] Débug Analyse de l’espace libre

---

## 📜 Licence

**GNU GPL v3** - [Voir LICENSE](LICENSE)

✅ Usage libre | ✅ Modification | ✅ Distribution | ✅ Commercial*  
*accord préallable nécessaire et le code doit rester open-source

---

## 👤 Auteur

**jphreculeau**

- 🔗 [GitHub](https://github.com/jpreculeau/acmefrag)
- 📧 [Contactez-moi](https://github.com/jpreculeau)

---

## 📚 Ressources

- [Documentation XFS](https://xfs.wiki.kernel.org/)
- [Manuel xfs_fsr](https://man7.org/linux/man-pages/man8/xfs_fsr.8.html)
- [Raspberry Pi Docs](https://www.raspberrypi.org/documentation/)

---

## 📜 Licence

Ce projet est licencié sous la **GNU General Public License v3 (GPL v3)** avec la restriction suivante :

- ✅ **Usage personnel et non-commercial** : Libre d'utilisation, modification et distribution
- ❌ **Usage commercial** : Nécessite une **licence commerciale payante**

Cela inclut :
- Vente ou location du logiciel
- Utilisation par une entreprise à titre commercial
- Intégration dans des produits/services commerciaux
- Services de conseil utilisant ce logiciel

Pour obtenir une licence commerciale, veuillez consulter le fichier [LICENSE](LICENSE) ou contacter le détenteur des droits d'auteur.

---

<div align="center">

**⭐ Aimez ce projet ? Donnez-lui une étoile ! ⭐**

Fait avec ❤️ pour les débutants de la communauté Linux et la communauté Raspberry Pi

</div>
