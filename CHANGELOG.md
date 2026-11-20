# Journal des modifications

## 2.4.0

### Mode anglais
- Toute l'interface en français ou en anglais : outils, aide, tableau de bord, assistant d'installation,
  intégration au shell, assistant IA (y compris ses consignes au modèle). Langue choisie à l'installation,
  modifiable avec `pst setup`, sinon celle de Windows ; `PSTOOLS_LANG` pour une session.
- Dictionnaires par fichier (`src/i18n/en`), repli automatique sur le français, vérificateur
  `build/Test-Translations.ps1` exécuté par la CI.

### Tableau de bord et nouvelle interface
- `pst` ouvre un tableau de bord plein écran inspiré de l'interface de DefenseClaw : onglets numérotés par
  catégorie, liste des outils, fiche avec exemples, lancement direct, filtre `/`, barre des touches et
  bandeau d'état (shell, IA, budget, tâches du jour).
- Nouveau thème par défaut « Cyan » (panneaux sombres, accent cyan) ; titres de panneaux en capitales,
  ligne choisie surlignée, ✓ ✗ ▸ dans Windows Terminal.

### Au quotidien
- **todo** (tâches, échéances en langage courant, priorités, étiquettes), **note** (journal Markdown),
  **timer** (minuteur, chronomètre, Pomodoro), **weather**, **calc** (calculs, pourcentages, unités,
  devises hors ligne), **awake** (empêche la mise en veille).

### Fichiers, code, réseau
- **tidy** (range les Téléchargements, avec annulation), **dupes** (doublons vers la corbeille),
  **gitignore**, **cheat** (exemples tldr hors ligne), **paths** (diagnostic et réparation du PATH),
  **speed** (test de débit avec verdict).

### Corrigé
- Un nombre égal à zéro n'était pas inséré dans certains messages.
- « Modifier une étape » dans l'assistant d'installation ouvrait l'étape suivante.

## 2.3.0

### Assistant d'installation
- Installation guidée en sept écrans : environnement, portée, outils, apparence, intégration au shell,
  assistant IA, récapitulatif. Retour arrière avec Échap ; rien n'est modifié avant la confirmation.
- `pst setup` : centre de configuration pour tout régler plus tard (apparence, shell, IA, test).
- Thèmes de couleurs : Nuit, Océan, Ambre, Clair (terminaux à fond blanc), Mono ; l'invite du shell suit.

### Assistant IA multi-fournisseurs
- `ask` fonctionne avec Anthropic Claude, OpenAI, Google Gemini, Mistral, Groq, DeepSeek, xAI, OpenRouter,
  Ollama (local) et tout service compatible OpenAI. Clé vérifiée en direct, enregistrée chiffrée (DPAPI).
- Jetons et coût affichés après chaque réponse ; `ask -Usage` / `pst usage` : bilan par période et par
  modèle, coût par jour, budget mensuel avec alertes. Tarifs officiels datés, paliers longs, changements
  de prix annoncés, heures de pointe ; prix OpenRouter lus en direct ; prix personnalisés possibles.
- `ask -Provider` et `ask -Model` pour changer d'IA le temps d'une question ; `ask -Status`.

### Corrigé
- **Profil PowerShell sur un partage réseau** (dossier Documents redirigé) : `pst shell on` écrivait dans un
  profil que Windows refusait ensuite de charger (« n'est pas signé numériquement »). Le chargement est
  désormais testé réellement avant toute écriture ; un profil bloqué n'est jamais modifié (l'ancien bloc
  est retiré, plus d'erreur au démarrage) et trois solutions sont proposées, toutes réversibles :
  partage de confiance (zone Intranet), stratégie Bypass pour le compte, profil Windows Terminal dédié.
- La vérification de stratégie ignorait la préférence « Bypass » héritée des lanceurs : le test est fait
  avec la stratégie réelle de l'utilisateur.

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
