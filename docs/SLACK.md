# Brancher Slack sur Compagnon

Compagnon affiche en temps réel tes **messages directs** (et messages de groupe)
et les messages où l'on te **mentionne**, et te laisse **répondre depuis l'île**.
La réponse part en ton nom ; pour une mention dans un canal, elle part dans le
fil du message.

Il faut une petite app Slack à toi, dans l'espace de travail. Elle n'est visible
que par toi et n'a pas de bot.

## 1. Créer l'app (5 minutes)

1. Compagnon → **Réglages… → Intégrations → Slack → Copier le manifeste**
   (le même contenu est dans [`slack-manifest.json`](slack-manifest.json)).
2. Va sur <https://api.slack.com/apps> → **Create New App** → **From a manifest**,
   choisis l'espace de travail du boulot, colle le manifeste, **Create**.

## 2. La faire valider puis l'installer

3. Dans l'app : **Install App** → **Install to Workspace** (ou **Request to
   Install** : un administrateur Slack doit approuver, c'est le cas chez nous).
4. Une fois installée, sur la même page, copie le **User OAuth Token**
   (commence par `xoxp-`).

Ce que l'app peut faire (droits demandés) : lire les conversations où tu es
(canaux, groupes privés, messages directs), lire les noms des personnes et des
canaux, et écrire un message en ton nom quand tu cliques sur **Envoyer**.
C'est utile de le dire à l'admin qui valide.

## 3. Le jeton de connexion temps réel

5. Dans l'app : **Basic Information** → **App-Level Tokens** → **Generate Token
   and Scopes**, nom au choix (« compagnon »), droit `connections:write`,
   **Generate**. Copie le jeton (commence par `xapp-`).

## 4. Coller les jetons dans Compagnon

6. Compagnon → **Réglages… → Intégrations → Slack** : colle le `xoxp-…` et le
   `xapp-…`, puis **Enregistrer les intégrations**. Le statut passe à
   « Connecté · en écoute ».
7. **Réglages… → Pastilles actives** : vérifie que **Slack** est coché.

Les jetons restent dans le Trousseau du Mac, jamais sur disque ni dans git.

## Comment ça se comporte

- Nouveau message direct ou mention : petit son, la lampe de l'antenne passe en
  cyan, et l'île s'ouvre sur la carte Slack (sauf si Claude attend une
  autorisation ou si tu es en train d'utiliser une autre carte : la pastille
  Slack prend alors un badge bulle).
- **Répondre** ouvre un champ : Entrée envoie, Échap annule.
- **Ouvrir dans Slack** ouvre la conversation dans l'app Slack.
- Tes propres messages et les messages modifiés ou supprimés sont ignorés.

## En cas de souci

| Statut affiché | Cause probable |
|---|---|
| Jetons non configurés | un des deux jetons manque |
| Erreur : jeton invalide | jeton mal copié, ou app désinstallée |
| Erreur : droits manquants | l'app a été créée sans le manifeste complet : recolle-le dans **App Manifest**, puis réinstalle |
| Connecté, mais rien n'arrive | vérifie que **Socket Mode** est activé et que les 4 *user events* sont listés dans **Event Subscriptions** |

Le journal est dans `~/Library/Logs/Compagnon/slack.log`.
