# Compagnon — guide pour les agents

Compagnon est une app macOS native (`Compagnon/`) : un petit personnage qui vit
dans l'encoche du Mac, suit les sessions Claude Code (et d'autres agents) via
leurs hooks, et permet d'autoriser, répondre, discuter et déposer des fichiers
depuis l'encoche. C'est un fork de [Coucou](https://github.com/Louis-CFM/coucou)
(MIT), entièrement en français et avec sa propre identité.

## Où est quoi
- `Compagnon/Sources/App/` — tout le code Swift. `Compagnon/project.yml` — projet
  XcodeGen (le `.xcodeproj` est généré, jamais commité).
- `Compagnon/Sources/App/CompagnonStyle.swift` — l'apparence du personnage
  (couleurs, silhouette, antenne), partagée par `BotEngine.swift` (personnage
  principal), `GreetingCanvasView.swift` (accueil) et `UploadCanvasView.swift`.
- `Compagnon/Sources/App/HookServer.swift` — le pont avec Claude Code : socket
  `~/Library/Application Support/Compagnon/compagnon.sock`, script relais
  `compagnon-hook`, installation des hooks dans `~/.claude/settings.json`.
- `Compagnon/Sources/App/PillCatalog.swift` — la liste des pastilles (outils,
  agents, services).
- `Compagnon/Resources/sounds/` — générés par `scripts/gen-sounds.py`.
  `Compagnon/Assets.xcassets/` — icônes générées par `scripts/gen-icons.py`.
  On modifie les scripts, puis on relance, plutôt que d'éditer les fichiers.
- `docs/SPEC.md`, `docs/INTEGRATIONS.md` — spécifications héritées de Coucou.
- `windows/` — version Windows/Linux (Tauri) héritée de Coucou, **pas encore
  migrée** (encore nommée Coucou, non utilisée).

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
