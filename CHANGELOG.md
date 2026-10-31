# Changelog

## 4.1.1 — 2026-10-31

### Corrigé
- Liens physiques, journal `🔗 … déjà traité via …` : les caractères de contrôle C1 codés en UTF-8 (CSI 8 bits, `\xc2\x9b`…) d'un nom passaient, le filtre tournant en locale C ; ils sont remplacés par `?`, comme les autres caractères de contrôle.

## 4.1.0 — 2026-10-31

### Ajouté
- **Liens physiques** (cross-seed : `xseed-links/<tracker>/…`) : un fichier à plusieurs noms n'est plus lu, mesuré ni défragmenté une fois par nom. Le scan dédoublonne par inode (`st_dev:st_ino`) pendant le parcours : un seul nom par inode, le premier rencontré, est passé à `filefrag` et au filtre « assez contigu » ; les autres sont journalisés (`🔗 <nom> : déjà traité via <premier nom>`). C'est l'inode qui fait foi, pas le chemin : `xseed-links` n'est pas exclu par motif, un lien devenu le seul nom restant est traité normalement.
- Rapport : « Fichiers multi-noms : N (M partagés) · liens ignorés : L » après le scan ; espace des fichiers fragmentés compté une fois par inode (résumé d'éligibilité) ; compteur `[LIENS]` dans le résumé de session.
- Tests : fichier et son lien → une seule mesure, une seule ligne CSV, une seule passe ; seul le lien subsiste → traité (unitaires et intégration XFS/EXT4).

`--sante` inchangé (lecture SMART seule).

## 4.0.1 — 2026-10-31

### Corrigé
- **Garde-fou santé trop permissif** : un disque enregistré FAILED par `--sante`, puis redevenu PASSED parce que l'attribut fautif (Raw_Read_Error_Rate) avait remonté au-dessus de son seuil, était déclaré « aucune dégradation bloquante » malgré 152 secteurs réalloués. Le garde-fou refuse désormais aussi un disque dont l'historique `--sante` contient un bilan autre que PASSED (à n'importe quelle date), et un disque dont les secteurs réalloués atteignent `SMART_BAD_SECTOR_THRESHOLD` (50, le seuil déjà utilisé par la surveillance ; `0` désactive ce critère). `--force-sante` passe toujours outre ; en `--dry-run`, simple avertissement.
- Le ✅ du garde-fou affiche les valeurs lues (bilan, réalloués, en attente, erreurs ATA), et non plus seulement un verdict.
- Test unitaire SIGTERM instable (l'outil n'avait pas toujours eu le temps de mourir).

## 4.0.0 — 2026-10-29

Audit de la 3.1.0. Version majeure : en root, des installations jusque-là
acceptées sont désormais refusées (nouveau code `8`), et les codes de sortie changent.

### Sécurité
- En root, refus du code (`AcmeFrag.sh`, `config.sh`, `lib/`), de `local.conf`, de `/etc/acmefrag.conf` et du dossier de rapports s'ils n'appartiennent pas à un compte de confiance (root, ou l'utilisateur sudo si AcmeFrag lui appartient) ou si un autre compte peut les modifier : nouveau code `8`, « installation non sûre », distinct du `3` (SSD, FS racine…) pour qu'un orchestrateur ne le prenne pas pour un refus attendu (propriétaire, liens symboliques, droits d'écriture, contrôlés jusqu'à `/`). **Un cron root sur un clone du dossier personnel est refusé** : installer une copie appartenant à root (README, « Sécurité »).
- Verrou pris sur le dossier des rapports, ouvert en lecture : un lien symbolique posé à la place de l'ancien `.acmefrag.lock` faisait tronquer sa cible par root. Le fichier `.acmefrag.lock` n'est plus utilisé (il peut être supprimé).
- Comptes de confiance en root : root, et l'utilisateur sudo seulement si AcmeFrag lui appartient (clone personnel) ; son groupe seulement s'il lui est privé. `lib/common.sh` est contrôlé avant d'être chargé ; l'ancêtre existant du dossier de rapports est contrôlé avant toute création ; un dossier « sticky » (`/tmp`) n'est accepté que comme parent.
- Journal refusé s'il est un lien symbolique ; total du scan dans un fichier temporaire non prévisible ; rapports rendus à l'utilisateur sudo seulement dans un dossier qui est déjà le sien, sans `chown -R` (un dossier de rapports neuf, dans un dossier de l'utilisateur sudo, est créé à son nom).
- Un nom de fichier contenant un retour à la ligne, ou un fichier ou un dossier remplacé par un lien symbolique, ne fait plus traiter un fichier hors de la cible.
- Noms de fichiers et messages des outils affichés sans caractères de contrôle (séquences de terminal).

### Corrigé
- Garde-fou FS racine contourné par un bind mount ; garde-fous SSD et santé contournés par un bind mount ou par LUKS/LVM (disque physique mal identifié). Le disque est retrouvé à travers LUKS/LVM, et un type de disque indéterminé est refusé sauf `--force-ssd`.
- Surveillance : elle arrête désormais l'outil en cours (fichier ou `xfs_fsr` global), et plus seulement entre deux fichiers.
- Codes de sortie : `143` pour SIGTERM (130 reste Ctrl+C), `1` pour une erreur inattendue (et non le code de la commande fautive), `1` si `flock` manque (et non `4`) ; un outil tué n'est plus pris pour un Ctrl+C.
- Quota `-n` : les fichiers ignorés (récents, disparus) ne le consomment plus.
- Entiers à zéro initial (`08`) refusés : ils échouaient ensuite en arithmétique octale.
- `/etc/acmefrag.conf` en `0600` : plus de « aucune cible » à tort avant `sudo`.
- En `--dry-run`, SMART lu sans réveiller le disque, et pas de surveillance en mode automatique.
- Fichiers temporaires du scan supprimés après une interruption.
- Menu des montages : bind mounts de la racine exclus, points de montage avec espaces corrects.
- Scan d'une cible dont le chemin contient « \ » : il était vide.
- Journal sans codes couleur ; locale `C.UTF-8` imposée quand elle existe ; `--sante` signale les options ignorées.
- `REPORT_DIR` doit être un chemin absolu.

### Modifié
- Scan : tailles obtenues par lots et calculées en awk (100 fois plus rapide sur 5000 fichiers fragmentés) ; `numfmt` n'est plus requis ; tailles toujours au format `2.5G` / `7B`.
- La surveillance utilise l'analyseur SMART de `--sante` (et lit aussi la température NVMe).
- Tests : intégration sur une copie isolée (sans `local.conf` ni `/etc/acmefrag.conf`), faux `sudo` dans les tests unitaires, garde-fous testés (SSD, lecture seule, racine, espace libre, âge, dry-run, surveillance, rotation), CI épinglée par empreinte.

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
