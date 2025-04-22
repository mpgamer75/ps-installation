# PS-Installation 🚀

Une collection de scripts PowerShell utilitaires pour Windows, faciles à installer et à utiliser.
Pour faciliter l'utilisation du terminal sur Windows ( rapprochement des commandes que l'on peut retrouver sur MacOS / Linux). 

## 📦 Paquets disponibles

### 🖥️ Monitor (`monitor`)

Moniteur système en temps réel affichant :

- Utilisation CPU
- État de la mémoire
- Espace disque
- Activité réseau
- Processus les plus gourmands
- État des services critiques

### 🧹 Clean (`clean`)

Nettoyeur système interactif permettant de :

- Nettoyer différents emplacements (Bureau, Documents, etc.)
- Supprimer les fichiers temporaires
- Effacer les logs
- Nettoyer le cache
- Supprimer les dossiers vides
- Gérer les vieux fichiers

### 📡 Ping Monitor (`ping-mon`)

Outil de surveillance réseau offrant :

- Surveillance de plusieurs hôtes prédéfinis
- Ajout d'hôtes personnalisés
- Statistiques en temps réel
- Historique visuel
- Détection des paquets perdus
- Graphiques de latence

### ⏰ Remind (`remind`)

Système de rappels avec :

- Création de rappels avec date et heure
- Notifications Windows
- Gestion des rappels actifs
- Sauvegarde automatique
- Interface utilisateur intuitive

## 💻 Installation

1. Ouvrez PowerShell en tant qu'administrateur
2. Exécutez la commande :

```powershell
iwr -useb https://raw.githubusercontent.com/mpgamer75/ps-installation/main/install.ps1 | iex
```

## 🛠️ Utilisation

Après l'installation, utilisez les commandes suivantes :

- `monitor` : Lance le moniteur système
- `clean` : Lance l'utilitaire de nettoyage
- `ping-mon` : Lance le moniteur de ping
- `remind` : Lance le système de rappels

## ⚙️ Configuration requise

- Windows 10/11
- PowerShell 5.1 ou supérieur
- Droits administrateur pour l'installation
- .NET Framework 4.5 ou supérieur

## 🚨 Remarques importantes

- Certains scripts nécessitent des droits administrateur
- Les scripts sont automatiquement installés dans `C:\Program Files\WindowsPowerShell\Scripts`
- Les données des rappels sont sauvegardées dans `%USERPROFILE%\AppData\Local\RemindSystem`

## 🐛 Problèmes connus

Si vous rencontrez l'erreur "L'exécution de scripts est désactivée sur ce système", exécutez :
```powershell
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
```

## 🔄 Mise à jour

Pour mettre à jour les scripts :

1. Désinstallez l'ancienne version
2. Réexécutez la commande d'installation

## 🗑️ Désinstallation

Pour désinstaller les paquets :

```powershell
iwr -useb https://raw.githubusercontent.com/mpgamer75/ps-installation/main/install.ps1 | iex
```

## 🤝 Contributions

Les contributions sont les bienvenues ! Pour contribuer :

1. Fork le projet
2. Créez votre branche (`git checkout -b feature/AmazingFeature`)
3. Committez vos changements (`git commit -m 'Add AmazingFeature'`)
4. Push vers la branche (`git push origin feature/AmazingFeature`)
5. Ouvrez une Pull Request

## 📝 Licence

Ce projet est sous licence MIT. Voir le fichier `LICENSE` pour plus de détails.

## 📧 Contact

- Charles L 

Lien du projet : [https://github.com/mpgamer75/ps-installation](https://github.com/votre-username/ps-installation)
