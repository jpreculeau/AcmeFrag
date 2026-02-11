# 🎯 ACMEFRAG

> **Défragmenteur intelligent pour partitions XFS** - Parce que vos têtes de lecture méritent un traitement ACME !

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)
[![Bash](https://img.shields.io/badge/bash-%23121011.svg?style=flat&logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Platform](https://img.shields.io/badge/platform-Raspberry%20Pi-red)](https://www.raspberrypi.org/)
[![Version](https://img.shields.io/badge/version-1.0.0-green.svg)]()

## 📖 Description

**ACMEFRAG** est un script bash «intelligent» conçu pour optimiser la lecture vidéo sur disques durs en défragmentant les fichiers XFS fichier par fichier. Contrairement aux outils traditionnels qui tentent de tout défragmenter aveuglément, ACMEFRAG analyse intelligemment la fragmentation et ne traite que les fichiers qui en ont vraiment besoin.

### 🎬 Cas d'usage idéal

- **Bitorrent / Syncthing** Morcellement des fichiers important
- **Élimination des saccades** causées par la fragmentation lors d’une lecture vidéos
- **Optimisation des disques durs** (HDD) Des accès plus constant et contribue à éviter une fragmentation sur disques saturés
- **Maintenance préventive** Améliore la durée de vie des HDD en évitant des seek constants

### ✨ Fonctionnalités principales

- 🔍 **Analyse complète** de la fragmentation sur systèmes de fichiers XFS
- 🧠 **Défragmentation intelligente** : ignore les fichiers déjà optimaux (blocs > 4Go)
- 📊 **Rapports CSV horodatés** avec tri par niveau de fragmentation
- 🏆 **TOP 10** des fichiers les plus fragmentés
- 🛡️ **Sécurités intégrées** : vérification du point de montage et du type de FS
- 🧹 **Auto-nettoyage** : suppression des rapports > 30 jours
- 📈 **Diagnostic santé** : analyse de l'espace libre du disque
- ⚙️ **Modes d'exécution** : interactif ou automatique (cron-friendly)

---

## 🚀 Installation rapide

### Prérequis

- **OS** : toute distribution Linux
- **Système de fichiers** : XFS (obligatoire)
- **Paquets requis** : `xfsprogs`, `bc`, `coreutils`
- **Droits** : `sudo` pour les opérations de défragmentation

### Installation en 3 étapes

```bash
# 1️⃣ Installer les dépendances
sudo apt update && sudo apt install xfsprogs bc -y

# 2️⃣ Cloner et configurer
git clone https://github.com/jpreculeau/acmefrag.git
cd acmefrag
chmod +x acmefrag.sh

# 3️⃣ (Optionnel) Installation globale
sudo cp acmefrag.sh /usr/local/bin/acmefrag
acmefrag --help
```

---

## 💻 Utilisation

### Commandes essentielles

```bash
# Analyse du dossier par défaut
./acmefrag.sh

# Analyse d'un dossier spécifique (mode interactif)
./acmefrag.sh /mnt/mon-disque/

# Mode automatique (pour cron)
./acmefrag.sh --auto

# Avec chemin personnalisé (pour cron)
./acmefrag.sh /mnt/HDD/Films --auto
```

### Menu interactif

Le script propose trois options :
1. **Défragmenter le TOP 10** des fichiers les plus fragmentés
2. **Défragmenter selon un seuil personnalisé** (nombre d'extents)
3. **Quitter**

### Exemples de sortie

```
⏳ [14:32:18] (1.4G ) Le_Seigneur_des_Anneaux_Extended.mkv : before:47 after:1 ✅
⏳ [14:32:45] (850M ) Game_of_Thrones_S08E06_4K.mkv       : Déjà optimisé ✅
⏳ [14:33:12] (2.1G ) Interstellar_IMAX.mkv                : before:23 after:2 ✅
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

### Personnaliser les paramètres

```bash
nano acmefrag.sh

# Exemple : Changer le seuil intelligent à 2Go
INTEL_THRESHOLD_MO=2048
```

---

## 📋 Guide de démarrage

### ✅ Avant de commencer

Vérifiez que votre disque utilise bien XFS :

```bash
df -T /mnt/HDD
# Résultat attendu : xfs dans la colonne Type
```

### 🎯 Premier usage (5 minutes)

```bash
# 1. Lancer une analyse simple
./acmefrag.sh

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

## 🔒 Sécurité et bonnes pratiques

### ⚠️ Points importants

| ✓ À faire | ✗ À éviter |
|-----------|-----------|
| ✅ Exécuter pendant les heures creuses | ❌ Lancer pendant le streaming actif |
| ✅ Faire une sauvegarde avant | ❌ Interrompre brutalement (Ctrl+C OK) |
| ✅ Surveiller l'espace libre (>10%) | ❌ Lancer plusieurs instances |
| ✅ Consulter les rapports CSV | ❌ Ignorer les avertissements |

### Limites et contraintes

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
| **Chemin_Complet** | Chemin absolu |

**Tri** : Par extents décroissants, puis taille décroissante

---

## 🐛 Dépannage

### "n'est pas un point de montage"

```bash
# Vérifier les disques XFS montés
mount | grep xfs

# Monter manuellement
sudo mount /dev/sda1 /mnt/HDD
```

### "Système de fichiers détecté est (ext4)"

⚠️ **Votre disque n'est pas en XFS**

```bash
# Convertir en XFS (DÉTRUIT LES DONNÉES)
sudo umount /dev/sda1
sudo mkfs.xfs -f /dev/sda1
sudo mount /dev/sda1 /mnt/HDD
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
*Code doit rester open-source

---

## 👤 Auteur

**jpreculeau**

- 🔗 [GitHub](https://github.com/jpreculeau/acmefrag)
- 📧 [Contactez-moi](https://github.com/jpreculeau)

---

## 📚 Ressources

- [Documentation XFS](https://xfs.wiki.kernel.org/)
- [Manuel xfs_fsr](https://man7.org/linux/man-pages/man8/xfs_fsr.8.html)
- [Raspberry Pi Docs](https://www.raspberrypi.org/documentation/)

---

<div align="center">

**⭐ Aimez ce projet ? Donnez-lui une étoile ! ⭐**

Fait avec ❤️ pour les débutants de la communauté Linux et la communauté Raspberry Pi

</div>
