# 📜 MANIFEST - ARCHITECTURE ACTUELLE v2.0

> **Licence**: GNU GPL v3 + Clause commerciale payante - Voir [LICENSE](LICENSE)

## 🔄 État: Migration complètement intégrée ✅

Tous les fichiers refactoris�s ont �t� int�gr�s avec succ�s. Le projet b�n�ficie maintenant d'une architecture modulaire, robuste et maintenable.

---

## ?? Fichiers int�gr�s (version production)

#### 1. AcmeFrag.sh 
- Script principal - Orchestrateur
- **Status** : ? Int�gr� en production
- **Lignes** : 267 (structure claire avec 7 sections)

#### 2. config.sh
- Configuration centralis�e
- **Status** : ? Int�gr� en production
- **Am�liorations** : Support EXT4, protection SSD, validation

#### 3. security_checks.sh
- V�rifications de s�curit�
- **Status** : ? Int�gr� en production
- **Nouveau** : D�tection automatique des SSDs

#### 4-7. Modules sp�cialis�s
- scan_functions.sh, defrag_functions.sh, display_functions.sh, maintenance_functions.sh
- **Status** : ? Int�gr�s en production
- **Am�liorations** : Support XFS + EXT4

---

## ?? Documentation principale

- README.md - **Guide utilisateur** (mise � jour v2.0) ?
- INTEGRATION_RAPIDE.md - Int�gration rapide
- REFACTORISATION_GUIDE.md - Architecture technique
- CHANGEMENTS_DETAILLES.md - Historique complet

---

## ?? Comparaison v1.0 vs v2.0

| M�trique | v1.0 | v2.0 |
|----------|------|------|
| Syst�mes FS | XFS | XFS + EXT4 |
| Protection SSD | Non | Oui ? |
| Architecture | Monolithique | Modulaire ? |
| Code dupliqu� | Oui | Non ? |
| Bugs | 1 | 0 ? |

---

## ?? Utilisations courantes

./AcmeFrag.sh                  # Mode par d�faut
./AcmeFrag.sh /mnt/HDD         # Chemin sp�cifique  
./AcmeFrag.sh --auto           # Mode automatique (cron)
./AcmeFrag.sh --dry-run        # Simulation

---

## ? �volutions principales

- **Support EXT4** : D�fragmentation native ext4
- **Protection SSD** : D�tection et blocage automatique
- **Architecture modulaire** : 7 modules sp�cialis�s
- **Configuration centralis�e** : Un seul fichier config.sh
- **D�tection intelligente** : Auto-choix des outils selon FS

---

## ?? Historique des versions

- **v1.0** : Support XFS basique, monolithe
- **v2.0** : Support EXT4, Protection SSD, Architecture modulaire

---

## ? �tat du projet

? Code production
? Architecture modulaire
? Documentation compl�te
? Z�ro bugs connus
? Ready for contribution

**Projet maintenu:** v2.0 - F�vrier 2026
