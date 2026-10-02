# Compagnon

Un petit assistant qui vit dans l'encoche du Mac (ou en haut de l'écran) et qui
suit tes sessions Claude Code : il te prévient quand Claude a besoin de toi, et
tu peux autoriser ou refuser une action sans revenir dans Claude.

Compagnon est notre version de [Coucou](https://github.com/Louis-CFM/coucou)
(Louis Raillé, licence MIT) : même base, mais en français, avec notre propre
nom, notre personnage, nos sons et notre icône.

## Le personnage

Une petite boule menthe en forme de bonbon, aux yeux bleu nuit, avec une
**antenne** : sa lampe est corail quand tout est calme, prend la couleur de ce
que fait Claude (bleu il travaille, violet il réfléchit, vert c'est fini…) et
**clignote quand Claude a besoin de toi**. Elle se balance quand il saute ou
qu'on le secoue. Toutes les animations de Coucou sont conservées.

Les couleurs et la forme sont dans `Compagnon/Sources/App/CompagnonStyle.swift`.

## Installer et mettre à jour (sans Xcode)

Chaque modification poussée sur GitHub est compilée automatiquement.

1. Sur GitHub : onglet **Actions** → dernier build vert → en bas, **Artifacts**
   → **Compagnon** (un zip qui contient `Compagnon.zip`).
2. Dézippe, glisse **Compagnon.app** dans `/Applications` (remplace l'ancienne).
3. Première ouverture : clic droit sur l'app → **Ouvrir** → **Ouvrir**
   (l'app n'est pas signée par Apple, c'est normal pour un usage perso).
   Si macOS refuse quand même : `xattr -cr /Applications/Compagnon.app`.
4. Icône Compagnon dans la barre des menus → **Réglages…** → **Installer les
   hooks** pour brancher Claude Code.

Après une mise à jour, macOS peut redemander une fois l'accès au Trousseau
(clés API enregistrées) : clique **Toujours autoriser**.

Compagnon et Coucou peuvent tourner en même temps : chacun a ses propres
hooks, son dossier et ses réglages.

## Ce que Compagnon voit

Les sessions Claude Code qui tournent **sur ton Mac** : terminal, VS Code,
Cursor, ou l'app Claude (onglet Code) en mode local. Les sessions cloud
(claude.ai/code) s'exécutent sur les serveurs d'Anthropic et n'envoient rien à
ton Mac.

## Compiler soi-même (optionnel)

Prérequis : macOS 15+, Xcode 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
cd Compagnon && xcodegen && open Compagnon.xcodeproj   # puis ⌘R
```

## Sons et icônes

Générés par script, rien n'est repris de Coucou :

```bash
python3 scripts/gen-sounds.py   # 28 sons dans Compagnon/Resources/sounds/
python3 scripts/gen-icons.py    # icône de l'app et de la barre des menus
```

## Licence et origine

- Le **code** vient de Coucou, sous licence MIT ([`LICENSE`](LICENSE)) : la
  notice de copyright de Louis Raillé doit rester.
- Le nom « Coucou », le personnage Mochi, son icône, ses sons et ses médias ne
  sont pas sous MIT ([`LICENSE-ASSETS.md`](LICENSE-ASSETS.md)) : ils ne sont pas
  dans ce dépôt et ne doivent pas y revenir.
- Le commit de Coucou de départ est noté dans [`UPSTREAM_COMMIT`](UPSTREAM_COMMIT).

## Feuille de route

- [x] Renommer en Compagnon (identifiant, dossiers, hooks séparés)
- [x] Interface en français
- [x] Personnage, sons et icône à nous
- [x] Build automatique sur GitHub (pas besoin d'Xcode)
- [ ] Slack : messages directs et mentions dans l'île
- [ ] Harvest : timer en cours, démarrer / arrêter
- [ ] Répondre aux questions de Claude depuis Compagnon
- [ ] Écrire à Claude depuis Compagnon
- [ ] Nettoyer ou migrer `windows/` (version Windows/Linux héritée, pas utilisée)

## Où est quoi

- `Compagnon/` — l'app macOS (Swift 6, SwiftUI, AppKit, sans dépendance).
- `scripts/` — génération des sons et icônes, petits tests.
- `docs/SPEC.md`, `docs/INTEGRATIONS.md` — spécifications.
- `docs/COUCOU-README.md` — le README d'origine de Coucou.
