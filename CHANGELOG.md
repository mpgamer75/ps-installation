# Journal des modifications

## 2.2.0

- **pst-uninstall** : commande dédiée pour désinstaller ps-tools (commandes, PATH, intégration au shell,
  rappels planifiés). `-Yes` pour ne rien demander, `-Purge` pour supprimer aussi les données personnelles.
  `pst uninstall` passe par le même chemin et accepte `-Purge`.
- La désinstallation ne laisse plus de dossier vide derrière elle.

## 2.1.0

### Intégration au shell (`pst shell on`)
- Invite : dossier raccourci, branche Git, durée des commandes longues, échec et code de sortie, badge administrateur.
- Historique filtré aux flèches, menu de complétion, suggestions en liste (PowerShell 7), secrets non mémorisés.
- Raccourcis : `Alt+A` (phrase vers commande, via l'IA), `Alt+S` (sudo), `Alt+C` (copier), `Alt+G` (Git).
- Commandes façon Unix : `ll`, `la`, `..`, `mkcd`, `touch`, `which`, `grep`, `head`, `tail`, `df`, `open`, `sudo`, `reload`.
- Favoris de dossiers (`mark`, `jump`, `marks`, `unmark`) et `fix` pour expliquer la dernière erreur.
- N'écrase jamais une invite personnalisée ni une commande existante ; activable et réversible sans droits administrateur.

### Nouveaux outils
- **ask** : assistant Claude en flux continu, mode commande avec confirmation, analyse du pipeline.
- **watch**, **logtail**, **events** : observer une commande, un journal, les événements Windows.
- **gst**, **loc**, **serve**, **dev** : tableau de bord Git, lignes de code et TODO, serveur web local, couteau suisse du développeur.
- **pst** : `menu` (lanceur), `keys` (aide-mémoire), `shell` (intégration).

## 2.0.0

Réécriture complète.

### Installation
- Fonctionne **sans droits administrateur** (installation par utilisateur dans `%LOCALAPPDATA%\ps-tools`) ;
  en administrateur, choix entre utilisateur courant et tous les utilisateurs.
- PATH modifié proprement dans le registre (entrées `%VAR%` préservées), commandes disponibles immédiatement.
- Lanceurs `.cmd` : les commandes marchent depuis PowerShell et `cmd`, quelle que soit la stratégie d'exécution.
- Sélection d'outils (`-Tools`), mode silencieux (`-Yes`), mise à jour et désinstallation intégrées (`pst`).
- Détection et remplacement de la version 1 ; reprise des rappels existants.

### Interface
- Bibliothèque d'affichage commune : couleurs 24 bits, cadres, barres, mini-graphiques, menus à flèches,
  cases à cocher, écran temps réel sans scintillement, logo original.
- Repli automatique sans couleurs (`NO_COLOR`, sortie redirigée) et mode ASCII (`PSTOOLS_ASCII`).
- Aide homogène : `-Help` sur chaque commande.

### Outils
- **monitor** : charge par cœur, historique, débit réseau, batterie, % CPU réel par processus, tri et pause au clavier, `-Once`.
- **clean** : analyse puis aperçu avant toute suppression, cibles prédéfinies (temporaires, caches navigateurs,
  miniatures, rapports d'erreurs, corbeille, Windows Update), `-DryRun`, `-Only`, `-Elevate`, mode dossier.
- **ping-mon** : plusieurs hôtes en parallèle, gigue, taux de pertes, historique, bilan final.
- **remind** : ligne de commande (`add`, `list`, `done`, `rm`, `clear`), durées et dates naturelles,
  notifications modernes, planification sans droits administrateur.
- Nouveaux : **sysinfo**, **ports**, **dsize**, **netinfo**, **pst**.

### Qualité
- Tests Pester, analyse PSScriptAnalyzer (compatibilité 5.1 et 7), intégration continue sur Windows et Linux.

## 1.0.0

Version initiale : `monitor`, `clean`, `ping-mon`, `remind` (installation administrateur uniquement).
