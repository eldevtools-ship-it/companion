# Compagnon

Un petit assistant qui vit dans l'encoche du Mac (ou en haut de l'écran) et qui
suit tes sessions Claude Code : il te prévient quand Claude a besoin de toi, et
tu peux accepter ou refuser une action sans revenir dans Claude.

Compagnon est notre version de [Coucou](https://github.com/Louis-CFM/coucou)
(Louis Raillé, licence MIT), qu'on fait évoluer à notre façon : en français,
avec notre propre nom, notre personnage et nos fonctionnalités.

> **État actuel : import de base.** Le code est celui de Coucou au commit
> indiqué dans [`UPSTREAM_COMMIT`](UPSTREAM_COMMIT), sans encore le renommer.
> L'app s'appelle encore « Coucou » dans le code (voir la feuille de route).

## Ce qui a été retiré par rapport à Coucou, et pourquoi

Le **code** de Coucou est sous licence MIT : on peut le reprendre, le modifier
et l'utiliser, à condition de garder la notice de copyright ([`LICENSE`](LICENSE)).

Le **nom « Coucou », le personnage Mochi, l'icône, les sons et les images** ne
sont pas sous MIT ([`LICENSE-ASSETS.md`](LICENSE-ASSETS.md)). On ne les a donc
pas copiés ici :

| Retiré | Conséquence en attendant nos versions |
|---|---|
| `NotchBuddy/Resources/sounds/*.wav` (28 sons) | l'app tourne sans son |
| icônes de l'app et de la barre des menus | icône générique (la barre des menus affiche un rond) |
| `windows/src-tauri/icons/*` | la version Windows/Linux ne se compile pas sans icônes : `node windows/scripts/gen-icons.mjs` les régénère (dessin Mochi, à remplacer par le nôtre) |
| `docs/media`, `design/`, site web | aucune |

Le personnage reste dessiné dans le code (`BotCanvasView.swift`) : c'est le
design de Mochi, à remplacer par notre propre personnage avant de partager
l'app hors de chez nous.

## Lancer l'app sur le Mac

Prérequis : macOS 15 ou plus, Xcode 16 ou plus, [XcodeGen](https://github.com/yonaskolb/XcodeGen).
Pas besoin de compte développeur Apple payant pour l'utiliser sur son propre Mac.

```bash
brew install xcodegen
git clone https://github.com/eldevtools-ship-it/companion.git
cd companion/NotchBuddy
xcodegen
open NotchBuddy.xcodeproj   # puis ⌘R
```

Puis icône dans la barre des menus → **Settings…** → **Install hooks** pour
brancher Claude Code. ⚠️ Tant que l'app n'est pas renommée, elle utilise les
mêmes réglages, le même trousseau et les mêmes hooks que Coucou : **quitte
Coucou avant de lancer Compagnon**.

## Mettre à jour l'app sur le Mac

```bash
cd companion && git pull && cd NotchBuddy && xcodegen
```

puis relancer depuis Xcode (⌘R). Un script de mise à jour en une commande est
prévu dans la feuille de route.

## Feuille de route

1. **Renommer en Compagnon** : nom de l'app, identifiant (bundle id), dossier
   de support, socket et hooks propres, pour pouvoir tourner à côté de Coucou.
2. **Tout en français** : interface, réglages, messages.
3. **Notre identité** : personnage, icône et sons à nous.
4. **Répondre aux questions de Claude** depuis Compagnon (aujourd'hui seules
   les autorisations Autoriser / Refuser sont gérées ; les questions à choix
   ne font qu'une notification).
5. **Écrire à Claude depuis Compagnon** dans la session en cours (aujourd'hui
   le chat de l'app est un chat séparé via une clé API Anthropic, payante).
6. **Mise à jour en une commande** (`scripts/update.sh` : pull, build, relance).

## Où est quoi

- `NotchBuddy/` — l'app macOS (Swift 6, SwiftUI, AppKit, sans dépendance).
  Le pont avec Claude Code est dans `NotchBuddy/Sources/App/HookServer.swift`.
- `windows/` — la version Windows et Linux (Tauri 2 : Rust + TypeScript).
- `docs/SPEC.md`, `docs/INTEGRATIONS.md` — spécifications (en français).
- `docs/COUCOU-README.md` — le README d'origine de Coucou.
