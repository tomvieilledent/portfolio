# portfolio

Dépôt GitHub **`portfolio`**. Deux rôles :

## 1. Site perso — `https://vlldnt.fr`

Stack au choix (Astro recommandé, sortie statique dans `dist/`). Pages : Accueil,
Portfolio, Contact. **Contenu à remplir par Tom** — le reste de ce dépôt est
l'infra, déjà en place.

Le build est fait **sur le VPS** par `deploy-portfolio.sh` : il suffit d'un
`package.json` avec un script `build` produisant `dist/index.html`.

## 2. Cerveau de l'infra du domaine

| Chemin | Rôle |
|---|---|
| `projects.yml` | **source de vérité** des projets (voir en-tête du fichier) |
| `projects.md` | vue lisible, **générée** par `sync-projects.sh` — ne pas éditer |
| `scripts/` | déployés vers `/opt/vlldnt/scripts/` (voir tableau ci-dessous) |
| `deploy/nginx/` | snippet d'en-têtes + templates de vhost |
| `.github/workflows/` | `deploy-portfolio.yml` (push → build+publish) · `sync.yml` (orchestrateur) |
| `examples/` | modèles à copier dans chaque dépôt de projet |
| `VPS-BOOTSTRAP.md` | **mise en place unique** de `/opt/vlldnt/` + wildcard TLS |

### Scripts (`/opt/vlldnt/scripts/`)

| Script | Rôle |
|---|---|
| `lib.sh` | fonctions communes (sourcé, pas exécuté) |
| `deploy-portfolio.sh` | pull + build du site + réinstall infra + `sync-projects.sh` |
| `deploy-project.sh <nom>` | (re)déploie un projet **si `deployed: true`** ; landing auto ; static/compose |
| `sync-projects.sh [--dry-run] [--apply-renames]` | réconcilie `projects.yml` ↔ VPS ; régénère `projects.md` |
| `remove-project.sh <nom> [--confirm] [--purge-data]` | suppression sécurisée (dry-run par défaut, backup, saisie du nom) |
| `deploy-all.sh` | boucle sur tous les `deployed: true` |
| `healthcheck.sh` | HTTP 200 apex + sous-domaines + landings, conteneurs, expiration TLS |
| `rollback.sh <nom\|portfolio> [--steps N]` | release précédente (static) ou SHA précédent (compose) |

Garde-fous communs : `set -Eeuo pipefail`, `<nom>` validé `^[a-z][a-z0-9-]{1,38}$`
(refus `..` `/` et noms réservés), `rm` borné à `/opt/vlldnt/`, logs dans
`/opt/vlldnt/logs/`, `projects.yml` illisible → abandon sans rien toucher.

## Cycle de vie d'un projet

1. **Ajouter** : nouvelle entrée dans `projects.yml` (`deployed: true`) + copier
   `examples/project.deploy.yml` dans le dépôt du projet. Push → workflow *Sync*
   (dry-run) → *Run workflow* `dry_run: false` pour appliquer.
2. **Désactiver** : `deployed: false` → le projet est **retiré du VPS** (données
   archivées, pas détruites).
3. **Supprimer** : retirer la ligne de `projects.yml` → suppression complète
   après backup + confirmation.
4. **Renommer** : changer `name` (même `repo`) → `sync-projects.sh --apply-renames`.

Détails infra : `../DEPLOYMENT.md`. Mise en place pas à pas : `../MIGRATION.md`
et `VPS-BOOTSTRAP.md`.

## État

Infra **générée et vérifiée** (parsing yq v4, validation des noms, rendu des
templates, plan de réconciliation, dry-run de suppression : testés).
Reste : créer le dépôt GitHub, y pousser ce contenu + le code du site, exécuter
`VPS-BOOTSTRAP.md`.
