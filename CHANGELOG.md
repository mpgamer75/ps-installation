# Journal des modifications

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
