# examples/ — modèles pour les dépôts de projet

Ces fichiers ne sont **pas** utilisés tels quels : ils servent de base à copier
dans chaque dépôt de projet.

| Fichier | Va dans | Rôle |
|---|---|---|
| `project.deploy.yml` | `<projet>/.github/workflows/deploy.yml` | déclenche `deploy-project.sh <nom>` sur le VPS à chaque push `main` (remplacer `<NOM>`) |
| `compose.example.yml` | `<projet>/compose.yml` | modèle pour un projet `runtime: compose` (ports loopback, non-root, volumes sous `/opt/vlldnt/data`, healthcheck) |
| `env.example` | `<projet>/.env.example` | variables attendues, **sans valeurs** ; la vraie version est sur le VPS (`/opt/vlldnt/config/<nom>.env`) |

## Landing page d'un projet

Optionnelle. Si le dépôt du projet contient un dossier **`landing-page/`** à sa
racine, `deploy-project.sh` le détecte, le construit (si `package.json`) ou le
copie tel quel, et le publie sur `https://vlldnt.fr/<nom>`. Aucun dossier
`landing-page/` = aucune erreur, la landing est simplement absente.

Secrets GitHub à définir sur **chaque** dépôt de projet (mêmes valeurs que le
dépôt `portfolio`) : `SSH_HOST`, `SSH_USER`, `SSH_KEY`, `SSH_KNOWN_HOSTS`.
