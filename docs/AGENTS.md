# Brancher un autre agent sur Kumo

Kumo suit Claude Code de lui-même. N'importe quel autre outil capable de lancer une
commande à chaque étape (un hook) peut aussi apparaître dans l'île, avec sa propre
pastille.

## La commande

Fais appeler le relais de Kumo avec `--agent <nom>` :

```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "type": "command", "command": "\"$HOME/Library/Application Support/Kumo/kumo-hook\" --agent mon-outil" }
    ]
  }
}
```

Le relais lit le JSON reçu sur l'entrée standard, y ajoute `"kumo_agent": "mon-outil"` et
l'envoie à Kumo. Si l'outil ne précise pas le nom de l'étape (`hook_event_name`), passe-le
en argument : `kumo-hook --agent mon-outil Stop`.

Le nom doit respecter `^[a-z0-9-]{1,24}$` (minuscules, chiffres, tirets). Sans nom valide,
l'évènement va à la pastille Claude Code.

## Parler directement à Kumo

On peut aussi écrire une ligne de JSON sur le socket
`~/Library/Application Support/Kumo/kumo.sock` :

```json
{"hook_event_name": "UserPromptSubmit", "session_id": "s1", "kumo_agent": "mon-outil", "prompt": "Je m'y mets"}
```

## Ce que chaque étape fait

| Étape | Effet dans l'île |
|---|---|
| `SessionStart` | Crée la pastille |
| `UserPromptSubmit` | Réfléchit ; la demande s'affiche |
| `PreToolUse` | Travaille ; l'outil utilisé s'affiche |
| `PostToolUse` / `PostToolUseFailure` | Travaille |
| `Notification` | Limite atteinte ou question, si c'est le cas |
| `Stop` | Terminé |
| `StopFailure` | Erreur |
| `SessionEnd` | Retire la pastille |

Les demandes d'autorisation (`PermissionRequest`) restent réservées à Claude Code : pour un
autre agent, Kumo ne répond rien et l'agent repose la question dans son terminal.

## Essai rapide

Kumo ouvert :

```sh
echo '{"hook_event_name":"UserPromptSubmit","session_id":"t1","prompt":"bonjour"}' \
  | /bin/sh ~/Library/Application\ Support/Kumo/kumo-hook --agent demo
```

Une pastille « demo » apparaît dans l'île.
