# Changelog

## 3.0.0 — 2026-09-27

Audit complet de la v2.0 : correction des défauts bloquants, convergence avec la
version monolithique utilisée en production (v1.x d'avril 2026), mise aux normes.

### Corrigé (bloquant en v2.0)
- Arrêt du script après le **premier** fichier défragmenté : `((count++))` renvoie 1 quand `count=0`, fatal sous `set -e`.
- Arrêt immédiat sous **cron** : `clear` échoue sans `TERM`.
- Scan **EXT4** toujours vide (`filefrag -v` finit par « extents found », pas par « extents ») et défragmentation EXT4 en erreur (le chemin était lu comme nombre d'extents).
- Bilan XFS de l'espace libre : expression `sed` qui ne correspondait jamais, puis erreur arithmétique ; taille de bloc codée en dur.
- Sélection de fichiers « 1 3 5 » : jamais découpée (`IFS=$'\n\t'` global).
- Détection des disques : lisait la colonne « Use% » comme type de FS ; menu capturé par `$(…)` au lieu d'être affiché.
- `--force-ssd` sans effet ; `--dry-run` ignoré pour la sélection manuelle.
- CSV séparé par `;` : noms de fichiers contenant `;` mal découpés (→ TAB).
- Mode par défaut `--auto` alors que l'aide annonçait l'interactif.
- Surveillance : `smartctl` sur la partition sans `-d sat` (USB), fichiers `/tmp` prévisibles écrits en root, processus orphelin si le script est tué.
- Rapports écrits dans le dossier courant (pollution sous cron).
- `validate_config` : `echo "\n"` non interprété, valeurs invalides corrigées en silence.

### Ajouté
- Bridage **QoS** : `nice 19` + `ionice` idle (priorité à la lecture vidéo).
- **Verrou** `flock` (cron + lancement manuel simultanés).
- Garde-fou **FS racine** (remplace « doit être un point de montage » : un sous-dossier comme `/mnt/HDD/Films` est désormais accepté).
- Fichiers **modifiés récemment** ignorés, vérification de l'espace libre avant chaque fichier.
- Options `-s/--seuil`, `-n/--top`, `-e/--min-extents`, `--no-monitor`, `--no-qos`, `--version` ; codes de sortie documentés.
- Journal de session persistant, compteurs et résumé (repris de la v1.x).
- Défragmentation globale `xfs_fsr` bornée dans le temps (reprise de la v1.x).
- Surcharges `local.conf` / `/etc/acmefrag.conf` : `config.sh` n'est plus édité à la main.
- Tests unitaires, tests d'intégration sur images loop, `make lint test`.

### Modifié
- Un seul scanner (`filefrag` par lots) pour XFS et EXT4 ; tailles en octets (plus de `bc` ni de conversion « 2,4G »).
- Résultat mesuré (extents avant/après) au lieu d'interpréter le texte des outils.
- Élévation root unique au lancement (plus de `sudo` éparpillés).
- Modules déplacés dans `lib/` ; `get_fs_type` n'est plus défini trois fois.
- Écran rafraîchi (`clear`) remplacé par une ligne de surveillance par fichier : lisible dans les journaux.

### Supprimé
- Clause « usage commercial payant » : incompatible avec la GPL (§7, §10). La licence est désormais la GPL v3 officielle, sans restriction ajoutée (`GPL-3.0-or-later`).
- `migrate_acmefrag.sh` (migration v1→v2 terminée), `MANIFEST.md` et `REFACTORING_NOTES.md` (obsolètes, encodage cassé) — remplacés par ce fichier.
- Dépendance à `bc`.
