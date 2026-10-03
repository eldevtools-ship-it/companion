# Kumo — guide pour les agents

Kumo (雲, « nuage » en japonais ; anciennement Compagnon) est une app macOS native (`Kumo/`) : un petit personnage qui vit
dans l'encoche du Mac et fait trois choses, pour un seul utilisateur :
- suivre les sessions Claude Code via leurs hooks et autoriser / refuser depuis l'encoche ;
- afficher les messages directs et mentions Slack, et y répondre ;
- piloter le timer Harvest (projet, tâche, note, start / stop, rappel).
Plus l'Agenda, Vercel, GitHub, un pense-bête et un petit chat avec Claude. C'est un fork de [Coucou](https://github.com/Louis-CFM/coucou)
(MIT), entièrement en français et avec sa propre identité. Garder l'app minimale :
pas de nouvelle fonction sans usage réel.

## Où est quoi
- `Kumo/Sources/App/` — tout le code Swift. `Kumo/project.yml` — projet
  XcodeGen (le `.xcodeproj` est généré, jamais commité).
- `Kumo/Sources/App/KumoStyle.swift` — l'apparence du personnage :
  un nuage blanc à cinq bouffées (`cloudPoint`), yeux en pilules sobres (sans
  reflet), la couleur de l'état qui monte par le bas. Éclairage (`BotEngine.lighting`) :
  la couleur de la pastille au calme, celle de l'état quand il s'active ; ombres teintées
  de cette couleur (jamais de noir), halo qui épouse le nuage, lumière posée sous lui. Partagé par `BotEngine.swift`
  (personnage principal) et `GreetingCanvasView.swift` (accueil). Les mini-robots
  des pastilles gardent la silhouette « bonbon » (`bodyPoint`).
  Sa « vie » est dans `BotEngine` (section Cloud life) : regard en saccades, bouffées
  à ressort (souris proche, clic, caresse), vapeur / gouttes / ciel d'orage selon
  l'état, sieste après 10 min, regard vers le champ quand on tape, « parole » pendant
  la réponse du chat, bâillement le matin, paupières lourdes tard le soir.
- `Kumo/Sources/App/HookServer.swift` — le pont avec Claude Code : socket
  `~/Library/Application Support/Kumo/kumo.sock`, script relais
  `kumo-hook`, installation des hooks dans `~/.claude/settings.json`.
- `Kumo/Sources/App/PillCatalog.swift` — les pastilles (Claude Code toujours ;
  Slack, Harvest, Agenda, Vercel, GitHub dès qu'elles sont configurées) et leurs
  couleurs (`PillColor`, une teinte distincte par pastille).
- `Kumo/Sources/App/OverviewCards.swift` — la vue d'ensemble et les cartes
  (Claude Code, Slack, Harvest + sélecteur de projet, Agenda, Vercel, GitHub).
- Cartes d'autorisation et de question (`IslandViewContent.swift`) : elles grandissent avec
  leur contenu (`PromptLayout`) ; l'autorisation dit ce qui est en jeu (commande et sa
  description, fichier, URL, aperçu de modification — `HookServer.describeTool`), les
  options d'une question s'affichent avec leur explication. Plusieurs demandes à la fois
  font une file (« +N en attente », ⏎ ⏎ pour enchaîner) au lieu de se remplacer.
- Carte « Terminé » : « Répondre » donne une suite à la session (`ChatService.reply`,
  `claude -p --resume … --fork-session` dans le dossier du projet ; ses hooks la montrent
  dans l'île ; un outil qui demande une permission y est refusé).
- `Kumo/Sources/App/IslandTypes.swift` — `CardLayout` : la grille commune à
  toutes les vues (personnage centré à gauche, même marge bord → personnage → contenu).
- `Kumo/Sources/App/IslandCursor.swift` — curseur main / texte au survol de l'île.
- `NotesStore.swift` / `NotesView.swift` — le pense-bête (bouton notes à côté de la
  lune) : notes et dossiers dans `~/Library/Application Support/Kumo/notes.json`.
  ⌥⌘N l'ouvre depuis n'importe quelle app (`HotKey.swift`, raccourci Carbon).
- `ChatService.swift` / `ChatView.swift` — petit chat avec Claude (bouton bulle, ‹ › pour les 10 dernières
  conversations, poubelle à double clic pour en supprimer une,
  ⌥⌘J) via la CLI Claude Code installée (`claude -p`, abonnement de l'utilisateur,
  Claude Sonnet, sans choix de modèle). Lancé avec `KUMO_CHAT=1` : le relais `kumo-hook`
  l'ignore, pour que le chat n'apparaisse jamais comme une session dans l'île.
- `SpotifyService.swift` / `MusicView.swift` — la musique (bouton note à côté du chat, visible si
  Spotify est installé) : pilote l'app Spotify du Mac par AppleScript (pas de compte ni de clé),
  suit ses changements par sa notification distribuée (rien ne tourne en boucle). Pochette,
  titre, ⏮ ⏯ ⏭ ; espace / ← → dans la vue ; égaliseur dans la barre compacte. Le nuage se
  balance pendant la lecture et danse dans la vue (sauts sur le temps, yeux fermés, notes ♪),
  dans la couleur de la pochette.
- `DayService.swift` / `DayCardView.swift` — bonjour le matin, résumé du soir,
  concentration automatique en réunion (caméra allumée ou réunion de l'agenda).
- `SlackService.swift`, `HarvestService.swift`, `GithubPoller.swift`,
  `UpdateService.swift` (mise à jour automatique depuis les releases GitHub).
- `Kumo/Resources/sounds/` — générés par `scripts/gen-sounds.py`.
  `Kumo/Assets.xcassets/` — icônes générées par `scripts/gen-icons.py`.
  On modifie les scripts, puis on relance, plutôt que d'éditer les fichiers.
- `docs/SLACK.md`, `docs/HARVEST.md` — mise en place des intégrations.

## Build
Le conteneur cloud ne peut pas compiler d'app macOS : chaque push est compilé
par GitHub Actions (`.github/workflows/build.yml`), qui publie `Kumo.zip`.
En local sur un Mac :
```
cd Kumo && xcodegen && xcodebuild -scheme Kumo -configuration Debug build
```

## Règles
- Swift 6, SwiftUI + AppKit, sans dépendance tierce sauf nécessité absolue.
  Le personnage est dessiné en code (`Canvas` + `TimelineView`).
- Tout texte visible est en français, au tutoiement, court (l'île est petite).
- Arrondis concentriques : rayon intérieur = rayon extérieur − marge. Utiliser
  `IslandConst.expandedCorner` / `cardRadius` / `innerRadius` et les marges
  `contentInset` / `cardInset`, jamais de rayon en dur.
- Mise en page : le contenu d'une carte commence à `CardLayout.contentLeading`, les
  encadrés aussi (alignés sur le texte). Tout bouton de l'île porte `.pointingHand()`,
  tout champ texte `.textCursor()`.
- L'île se replie `autoCloseDelay` secondes (3 par défaut) après la sortie de la souris.
- Ne jamais réintroduire le nom « Coucou », le personnage Mochi, l'icône, les
  sons ou les médias de Coucou (`LICENSE-ASSETS.md`). Garder la notice MIT de
  Louis Raillé dans `LICENSE`.
- Les hooks de Kumo sont reconnus par `HookServer.isOwnHook` (nom du script
  `kumo-hook`, ou `compagnon-hook` pour ceux installés avant le renommage) : ne jamais toucher aux hooks d'une autre app (Coucou…).
- Secrets dans le Trousseau, jamais sur disque ni dans git. Pas de télémétrie.
- Ne jamais bloquer Claude Code : si l'app ne répond pas, le hook sort aussitôt.
- Ne jamais écraser `~/.claude/settings.json` : sauvegarde datée, fusion, diff
  montré, écriture seulement après confirmation.
- Ne jamais envoyer un mail ni autoriser une action sans clic explicite.
- Performance : 0 % de CPU quand l'île est cachée. Le suivi de la souris tourne à
  60 Hz seulement près de l'île ou quand elle est ouverte (8 Hz sinon) ; seules la vue
  affichée et celle qui disparaît sont construites ; les mini-animations sont plafonnées
  à 30 i/s ; aucun appel réseau pendant que les écrans dorment (`AppState.macAsleep`) ;
  les journaux s'écrivent en arrière-plan.
- Ancien nom (Compagnon) : `KumoMigration` copie au premier lancement les réglages de
  `com.eldevtools.Compagnon`, déplace `Application Support/Compagnon` vers `…/Kumo` (en laissant
  un lien) ; `KeychainStore` déplace les secrets de l'ancien service Trousseau. Le relais
  `compagnon-hook` reste un petit renvoi vers `kumo-hook` tant que les hooks n'ont pas été mis à
  jour depuis les Réglages (sauvegarde, diff, confirmation). Les releases publient aussi
  `Compagnon.zip` pour les installations antérieures à la version 45.
- Les identifiants de pastilles sont des valeurs stables (Trousseau, réglages,
  routage des hooks) : ne pas les renommer.
