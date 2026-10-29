# Changelog

## 3.1.0 — 2026-10-29

### Ajouté
- `--sante` : santé du disque qui porte la cible. Lecture SMART passive (`-n standby` : un disque en veille n'est pas réveillé ; jamais d'auto-test), historique par numéro de série dans `REPORT_DIR/sante/`, évolution « avant → après » et alertes : bilan différent de PASSED (au changement), hausse des attributs 5, 196, 197, 198, 199 ou des erreurs ATA, température au-dessus de `SMART_TEMP_ALERT_C` (55 °C). Codes de sortie `6` (alerte) et `7` (mesure impossible), dernière ligne `BILAN SANTÉ : …` pour les orchestrateurs.
- Garde-fou avant défragmentation : refus (code 3) d'un disque au bilan autre que PASSED, avec des secteurs en attente ou des réalloués en hausse sur `SMART_GUARD_DAYS` jours d'historique (30) ; `--force-sante` pour passer outre, simple avertissement en `--dry-run` (rejoué quand on quitte le dry-run depuis le menu interactif).
- `ACMEFRAG_SYSTEM_CONF` : chemin du fichier de configuration système (défaut `/etc/acmefrag.conf`).

### Corrigé
- Tests unitaires : ils lisaient le `local.conf` de la machine. Le test « auto sans cible » lançait alors une vraie défragmentation du `DEFAULT_TARGET` réel. Ils tournent désormais sur une copie sans `local.conf` ni `/etc/acmefrag.conf`, sous une locale fixe (`2.5G` et non `2,5G`).
- Détection SMART : le code de retour de `smartctl` est un masque ; seuls les bits « ligne de commande » et « ouverture » signalent un accès impossible (un disque FAILED renvoie 8 et reste lisible). Repli `-d auto`, redondant, retiré.

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
- Tests unitaires, tests d'intégration sur images loop, `make lint test`, CI GitHub Actions (shellcheck + tests unitaires + intégration EXT4/XFS sur images loop).

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
