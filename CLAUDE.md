# Compagnon — guide pour les agents

Compagnon est une app macOS native (`Compagnon/`) : un petit personnage qui vit
dans l'encoche du Mac et fait trois choses, pour un seul utilisateur :
- suivre les sessions Claude Code via leurs hooks et autoriser / refuser depuis l'encoche ;
- afficher les messages directs et mentions Slack, et y répondre ;
- piloter le timer Harvest (projet, tâche, note, start / stop, rappel).
Plus l'Agenda, Vercel et GitHub. C'est un fork de [Coucou](https://github.com/Louis-CFM/coucou)
(MIT), entièrement en français et avec sa propre identité. Garder l'app minimale :
pas de nouvelle fonction sans usage réel.

## Où est quoi
- `Compagnon/Sources/App/` — tout le code Swift. `Compagnon/project.yml` — projet
  XcodeGen (le `.xcodeproj` est généré, jamais commité).
- `Compagnon/Sources/App/CompagnonStyle.swift` — l'apparence du personnage
  (couleurs, silhouette, antenne), partagée par `BotEngine.swift` (personnage
  principal) et `GreetingCanvasView.swift` (accueil).
- `Compagnon/Sources/App/HookServer.swift` — le pont avec Claude Code : socket
  `~/Library/Application Support/Compagnon/compagnon.sock`, script relais
  `compagnon-hook`, installation des hooks dans `~/.claude/settings.json`.
- `Compagnon/Sources/App/PillCatalog.swift` — les pastilles (Claude Code toujours ;
  Slack, Harvest, Agenda, Vercel, GitHub dès qu'elles sont configurées) et leurs
  couleurs (`PillColor`, une teinte distincte par pastille).
- `Compagnon/Sources/App/OverviewCards.swift` — la vue d'ensemble et les cartes
  (Claude Code, Slack, Harvest + sélecteur de projet, Agenda, Vercel, GitHub).
- `Compagnon/Sources/App/IslandTypes.swift` — `CardLayout` : la grille commune à
  toutes les vues (personnage centré à gauche, même marge bord → personnage → contenu).
- `Compagnon/Sources/App/IslandCursor.swift` — curseur main / texte au survol de l'île.
- `SlackService.swift`, `HarvestService.swift`, `GithubPoller.swift`,
  `UpdateService.swift` (mise à jour automatique depuis les releases GitHub).
- `Compagnon/Resources/sounds/` — générés par `scripts/gen-sounds.py`.
  `Compagnon/Assets.xcassets/` — icônes générées par `scripts/gen-icons.py`.
  On modifie les scripts, puis on relance, plutôt que d'éditer les fichiers.
- `docs/SLACK.md`, `docs/HARVEST.md` — mise en place des intégrations.

## Build
Le conteneur cloud ne peut pas compiler d'app macOS : chaque push est compilé
par GitHub Actions (`.github/workflows/build.yml`), qui publie `Compagnon.zip`.
En local sur un Mac :
```
cd Compagnon && xcodegen && xcodebuild -scheme Compagnon -configuration Debug build
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
- Les hooks de Compagnon sont reconnus par `HookServer.isOwnHook` (nom du script
  `compagnon-hook`) : ne jamais toucher aux hooks d'une autre app (Coucou…).
- Secrets dans le Trousseau, jamais sur disque ni dans git. Pas de télémétrie.
- Ne jamais bloquer Claude Code : si l'app ne répond pas, le hook sort aussitôt.
- Ne jamais écraser `~/.claude/settings.json` : sauvegarde datée, fusion, diff
  montré, écriture seulement après confirmation.
- Ne jamais envoyer un mail ni autoriser une action sans clic explicite.
- Performance : 0 % de CPU quand l'île est cachée.
- Les identifiants de pastilles sont des valeurs stables (Trousseau, réglages,
  routage des hooks) : ne pas les renommer.
