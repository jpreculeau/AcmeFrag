# 🎯 ACMEFRAG

> **Défragmenteur intelligent XFS pour Raspberry Pi** - Parce que vos têtes de lecture méritent un traitement ACME !

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)
[![Bash](https://img.shields.io/badge/bash-%23121011.svg?style=flat&logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Platform](https://img.shields.io/badge/platform-Raspberry%20Pi-red)](https://www.raspberrypi.org/)

## 📖 Description

**ACMEFRAG** est un script bash «intelligent» conçu pour optimiser la lecture vidéo sur disques durs en défragmentant les fichiers XFS fichier par fichier. Contrairement aux outils traditionnels qui tentent de tout défragmenter aveuglément, ACMEFRAG analyse intelligemment la fragmentation et ne traite que les fichiers qui en ont vraiment besoin.

### 🎬 Cas d'usage idéal

- **Streaming vidéo** depuis un NAS ou disque USB vers Freebox/Kodi/Plex
- **Élimination des saccades** causées par la fragmentation
- **Optimisation des disques durs** (HDD) connectés à un Raspberry Pi
- **Maintenance préventive** de vos bibliothèques multimédia

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

## 🚀 Installation

### Prérequis

- **OS** : Raspberry Pi OS (Debian/Ubuntu) ou toute distribution Linux
- **Système de fichiers** : XFS (obligatoire)
- **Paquets requis** : `xfsprogs`, `bc`, `coreutils`
- **Droits** : `sudo` pour les opérations de défragmentation

### Installation des dépendances

```bash
# Installer les outils XFS
sudo apt update
sudo apt install xfsprogs bc -y
```

### Installation du script

```bash
# Cloner le dépôt
git clone https://github.com/jpreculeau/acmefrag.git
cd acmefrag

# Rendre le script exécutable
chmod +x acmefrag.sh

# (Optionnel) Installer dans /usr/local/bin pour un accès global
sudo cp acmefrag.sh /usr/local/bin/acmefrag
```

---

## 💻 Utilisation

### Syntaxe de base

```bash
./acmefrag.sh [CHEMIN_CIBLE] [OPTIONS]
```

### Exemples

#### Mode interactif (par défaut)

```bash
# Analyse du dossier par défaut (/mnt/HDD)
./acmefrag.sh

# Analyse d'un dossier spécifique
./acmefrag.sh /mnt/mon-disque/Videos
```

Le script vous proposera ensuite :
1. Défragmenter le TOP 10
2. Défragmenter selon un seuil d'extents personnalisé
3. Quitter

#### Mode automatique (pour cron)

```bash
# Défragmente automatiquement le TOP 10 sans interaction
./acmefrag.sh --auto

# Avec un chemin personnalisé
./acmefrag.sh /mnt/nas/Films --auto
```

### Exemples de sortie

```
⏳ [14:32:18] (1.4G ) Le_Seigneur_des_Anneaux_Extended.mkv : before:47 after:1 ✅
⏳ [14:32:45] (850M ) Game_of_Thrones_S08E06_4K.mkv       : Déjà optimisé ✅
⏳ [14:33:12] (2.1G ) Interstellar_IMAX.mkv                : before:23 after:2 ✅
```

---

## ⚙️ Configuration

### Variables modifiables (début du script)

| Variable | Valeur par défaut | Description |
|----------|-------------------|-------------|
| `DEFAULT_TARGET` | `/mnt/HDD` | Dossier analysé si aucun argument fourni |
| `INTEL_THRESHOLD_MO` | `4096` | Taille min d'un extent (en Mo) pour ignorer le fichier |
| `OUTPUT_CSV` | `fragmentation_YYYY-MM-DD.csv` | Nom du rapport généré |

### Personnalisation

Éditez le script pour modifier ces valeurs :

```bash
nano acmefrag.sh

# Exemple : Changer le seuil intelligent à 2Go
INTEL_THRESHOLD_MO=2048
```

---

## 🔒 Conditions d'utilisation

### ⚠️ Avertissements importants

1. **XFS uniquement** : Ce script ne fonctionne qu'avec le système de fichiers XFS
2. **Droits sudo** : Nécessite des privilèges root pour `xfs_fsr` et `xfs_bmap`
3. **Espace disque** : Assurez-vous d'avoir au moins 10% d'espace libre
4. **Sauvegarde** : Bien que `xfs_fsr` soit sûr, faites une sauvegarde critique avant
5. **Charge système** : La défragmentation est I/O intensive (évitez pendant le streaming actif)

### 🎯 Bonnes pratiques

- ✅ Exécutez le script pendant les heures creuses (nuit)
- ✅ Utilisez `--auto` dans une tâche cron hebdomadaire
- ✅ Surveillez l'état de santé de l'espace libre
- ❌ N'interrompez pas brutalement le script (Ctrl+C est géré proprement)
- ❌ Ne lancez pas plusieurs instances simultanées

### 📅 Automatisation avec cron

```bash
# Éditer le crontab
crontab -e

# Exemple : Tous les dimanches à 3h du matin
0 3 * * 0 /usr/local/bin/acmefrag --auto >> /var/log/acmefrag.log 2>&1
```

---

## 🧪 Tests et validation

### Vérifier que votre disque est en XFS

```bash
df -T /mnt/HDD
# Doit afficher "xfs" dans la colonne Type
```

### Test de défragmentation manuelle

```bash
# Tester sur un seul fichier
sudo xfs_fsr -v /mnt/HDD/test_video.mkv
```

---

## 🐛 Dépannage

### Le script s'arrête avec "n'est pas un point de montage"

**Cause** : Le disque n'est pas monté ou le chemin est incorrect

**Solution** :
```bash
# Vérifier les points de montage
mount | grep xfs

# Monter manuellement si nécessaire
sudo mount /dev/sda1 /mnt/HDD
```

### "Système de fichiers détecté est (ext4)"

**Cause** : Votre disque n'est pas formaté en XFS

**Solution** : Convertir en XFS (⚠️ DÉTRUIT LES DONNÉES)
```bash
# ATTENTION : Sauvegardez d'abord !
sudo umount /dev/sda1
sudo mkfs.xfs -f /dev/sda1
sudo mount /dev/sda1 /mnt/HDD
```

### "ÉCHEC (Espace insuffisant)"

**Cause** : Moins de 10% d'espace libre sur le disque

**Solution** : Libérez de l'espace ou ignorez les gros fichiers en augmentant `INTEL_THRESHOLD_MO`

---

## 📊 Comprendre les rapports CSV

Les fichiers `fragmentation_YYYY-MM-DD.csv` contiennent :

| Colonne | Description |
|---------|-------------|
| Taille | Taille du fichier (format humain : 1.4G, 500M) |
| Extents | Nombre de morceaux (fragments) sur le disque |
| Dossier | Chemin complet du répertoire parent |
| Nom | Nom du fichier |
| Chemin_Complet | Path absolu complet |

**Tri** : Par défaut, trié par nombre d'extents (décroissant), puis taille (décroissant)

---

## 🤝 Contribution

Les contributions sont les bienvenues ! N'hésitez pas à :

1. 🍴 Fork le projet
2. 🌿 Créer une branche (`git checkout -b feature/amelioration`)
3. 💾 Commit vos changements (`git commit -m 'Ajout fonctionnalité X'`)
4. 📤 Push vers la branche (`git push origin feature/amelioration`)
5. 🔃 Ouvrir une Pull Request

### Idées d'améliorations futures

- [ ] Support EXT4 (en cours de développement)
- [ ] Interface web de monitoring
- [ ] Notifications par email/Telegram
- [ ] Mode "dry-run" (simulation)
- [ ] Statistiques graphiques (avant/après)

---

## 📜 Licence

Ce projet est sous licence **GNU GPL v3** - voir le fichier [LICENSE](LICENSE) pour plus de détails.

### En résumé

✅ Usage libre et gratuit  
✅ Modification autorisée  
✅ Distribution autorisée  
✅ Usage commercial autorisé **SI le code reste open-source**  
✅ Protection contre les brevets logiciels  
❌ **Interdiction de fermer le code source** (copyleft)  
❌ Toute modification doit rester sous GPL v3  
❌ Aucune garantie fournie  

### 🔒 Protection copyleft

Toute version modifiée ou dérivée de ce logiciel **DOIT** :
- Rester open-source sous GPL v3
- Partager le code source complet
- Mentionner les modifications apportées

**Usage commercial** : Autorisé mais le code doit rester public et sous GPL v3.  

---

## 👤 Auteur

**Votre nom**

- 🌍 Projet : [github.com/votre-username/acmefrag](https://github.com/votre-username/acmefrag)

---

## 🙏 Remerciements

- **XFS Developers** pour `xfs_fsr` et `xfs_bmap`
- **Looney Tunes / Warner Bros** pour l'inspiration ACME 🎬
- **La communauté Raspberry Pi** pour le support et les tests

---

## 📚 Ressources additionnelles

- [Documentation XFS](https://xfs.wiki.kernel.org/)
- [Guide xfs_fsr](https://man7.org/linux/man-pages/man8/xfs_fsr.8.html)
- [Raspberry Pi OS Documentation](https://www.raspberrypi.org/documentation/)

---

<div align="center">

**⭐ Si ce projet vous aide, n'oubliez pas de lui donner une étoile ! ⭐**

Fait avec ❤️ pour la communauté Raspberry Pi et les amateurs de streaming fluide

</div>
