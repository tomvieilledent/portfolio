# Architecture — vlldnt.fr

Vue d'ensemble complète de l'infra du domaine : VPS, utilisateurs, projets,
conteneurs, nginx, TLS, CI/CD. Généré à partir de l'état réel du VPS le
2026-09-11. `projects.yml` (ce repo) reste la **source de vérité** — ce
document est une photo lisible, pas une source à éditer.

---

## 1. Vue d'ensemble

```
Internet
   │
   ▼
nginx (VPS, seul point d'entrée 80/443)
   │
   ├── vlldnt.fr ─────────────► conteneur portfolio (127.0.0.1:8086)
   ├── flashcard.vlldnt.fr ───► conteneur flashcard (127.0.0.1:8084)
   ├── tilleul-canac.vlldnt.fr ─► conteneur tilleul-canac (127.0.0.1:8085)
   ├── tilleul-canac-api.vlldnt.fr ─► conteneur tilleul-canac-api (127.0.0.1:8083)
   │                                        │
   │                                        ▼
   │                              postgres (réseau docker interne, non exposé)
   │
   └── vlldnt.fr/<nom> ───────► landing pages statiques (fragments servis par nginx)
```

Tout tourne en conteneurs Docker (voir §5) derrière un nginx hôte qui fait
office de reverse proxy + TLS + en-têtes de sécurité. Un seul certificat
wildcard (`*.vlldnt.fr`) couvre tous les sous-domaines.

---

## 2. VPS

| | |
|---|---|
| Host | `137.74.175.164` (`vps-1bc7bf67`) |
| Alias shell | `vps -u` (ubuntu), `vps -d` (deploy), `vps -p` (ping) |
| `root` | **désactivé** (login bloqué) — toute action passe par `sudo` |

### Utilisateurs

| User | UID | Rôle | Groupes | Sudo |
|---|---|---|---|---|
| `ubuntu` | 1000 | Accès/admin système (paquets, docker, sudo général) | `ubuntu`, `docker` | complet |
| `deploy` | 1001 | **Seul propriétaire de `/opt/vlldnt/`**, exécute tous les scripts de déploiement, cible des workflows GitHub Actions | `deploy`, `users`, `docker` | restreint : `nginx -t`, `systemctl reload nginx` uniquement (NOPASSWD) |

Règle : **aucun code de projet ne doit vivre dans `/home/ubuntu`** — `ubuntu`
sert uniquement à administrer la machine (paquets système, Docker, accès
SSH). Tout ce qui est déployé vit sous `/opt/vlldnt`, possédé par `deploy`.

---

## 3. Arborescence `/opt/vlldnt`

```
/opt/vlldnt/
├── config/
│   ├── projects.yml          source de vérité (ce repo, synchronisé par deploy-portfolio.sh)
│   ├── projects.md           vue générée (ne pas éditer)
│   ├── <name>.env            secrets par projet, chmod 600, hors Git
│   └── ovh.ini               identifiants API OVH — usage certbot (DNS-01, cert wildcard) uniquement
├── portfolio/
│   ├── src/                  checkout git du repo `portfolio`
│   ├── current, releases/    obsolètes depuis le passage en conteneur (§5) — à purger
├── projects/<name>/src/      checkout git de chaque projet (front à la racine, backend/ si besoin)
├── data/<name>/               volumes persistants (ex. tilleul-canac-api/pg)
├── landing-pages/<name>/      pages statiques servies sous vlldnt.fr/<name>
├── nginx/
│   ├── vlldnt.conf            vhost apex, installé depuis deploy/nginx/vlldnt.conf.base
│   ├── templates/             gabarits (app.static.tmpl, app.compose.tmpl, landing.location.tmpl)
│   ├── snippets/               security-headers.conf
│   └── generated/apps|landings/*.conf   blocs générés par deploy-project.sh
├── scripts/                    voir §7
├── logs/                       un fichier par run, horodaté
└── backups/                    tar.gz avant migration/suppression (jamais de perte sèche)
```

---

## 4. Projets déclarés (`config/projects.yml`)

| `name` | Rôle | Repo | Runtime | Port loopback | Public (page d'accueil) | Landing `vlldnt.fr/<name>` |
|---|---|---|---|---|---|---|
| `flashcard` | App perso — révision fullstack | `tomvieilledent/flashcard` | compose | 8084 | oui | oui |
| `tilleul-canac` | Site vitrine client (chambre d'hôtes) | `tomvieilledent/tilleul-canac` | compose | 8085 | oui (`wip: true` — pas de lien public actif) | oui |
| `tilleul-canac-api` | Backend Django+Postgres de réservation de `tilleul-canac` — même repo, dossier `backend/`, déployé comme un service séparé (cycle de vie, ports et base de données indépendants) | `tomvieilledent/tilleul-canac` (branch `main`, `compose_file: backend/compose.yml`) | compose | 8083 | **non** (`public: false` — invisible du portfolio, appelé uniquement par le front `tilleul-canac`) | oui |

Le portfolio (`vlldnt.fr` lui-même) n'est **pas** une entrée de `projects.yml`
— il est spécial (vhost apex `default_server`) et déployé par
`deploy-portfolio.sh`, configuré séparément sous la clé `portfolio:` du même
fichier (`port: 8086`).

### Ajouter / retirer un projet

- **Ajouter** : entrée dans `projects.yml` (`deployed: true`) + le repo doit
  contenir un `compose.yml` (runtime `compose`) ou juste un script `build`
  (runtime `static`). Push → workflow *Sync projects* (dry-run automatique)
  → déclencher manuellement *Run workflow* avec `dry_run: false` pour appliquer.
- **Désactiver** (garder les données) : `deployed: false`.
- **Supprimer** (avec backup) : retirer la ligne de `projects.yml`.

---

## 5. Conteneurs Docker

| Conteneur | Image (build local) | Port hôte (loopback) | Dépend de |
|---|---|---|---|
| `vlldnt-portfolio-web-1` | Astro build → nginx | 127.0.0.1:8086 → 8080 | — |
| `vlldnt-flashcard-web-1` | Vite build → nginx | 127.0.0.1:8084 → 8080 | — |
| `vlldnt-tilleul-canac-web-1` | Vite build → nginx | 127.0.0.1:8085 → 8080 | — |
| `vlldnt-tilleul-canac-api-web-1` | Django + gunicorn | 127.0.0.1:8083 → 8000 | `vlldnt-tilleul-canac-api-db-1` |
| `vlldnt-tilleul-canac-api-db-1` | postgres:16-alpine | interne uniquement (réseau `vlldnt-tilleul-canac-api`) | — |

Aucun port n'est exposé publiquement par Docker : tout est bindé sur
`127.0.0.1`, nginx (hôte) est l'unique point d'entrée public (80/443).

Chaque conteneur `web` est démarré par `docker compose -p vlldnt-<name>` —
l'isolation par projet (réseau, nom) évite les collisions entre projets.

---

## 6. Nginx & TLS

- **Un seul vhost apex** (`nginx/vlldnt.conf`, généré depuis
  `deploy/nginx/vlldnt.conf.base` de ce repo) : `vlldnt.fr` / `www.vlldnt.fr`,
  `proxy_pass` vers le conteneur portfolio, inclut les landing pages
  (`nginx/generated/landings/*.conf`) et les en-têtes de sécurité/CSP.
- **Un vhost généré par projet** (`nginx/generated/apps/<name>.conf`, produit
  par `deploy-project.sh` à partir de `app.compose.tmpl` ou `app.static.tmpl`) :
  `<name>.vlldnt.fr` → `proxy_pass` vers le port loopback du conteneur.
- **Certificat unique** : wildcard `*.vlldnt.fr` (Let's Encrypt, validation
  DNS-01 via l'API OVH — identifiants dans `config/ovh.ini`), expire
  2026-12-09, partagé par tous les vhosts. Renouvellement à vérifier
  (certbot timer côté OS, hors du périmètre de ce repo).

---

## 7. Scripts de déploiement (`/opt/vlldnt/scripts/`)

| Script | Rôle |
|---|---|
| `lib.sh` | fonctions communes (sourcé, jamais exécuté seul) |
| `deploy-portfolio.sh` | pull du repo `portfolio` + réinstalle l'infra (scripts, templates nginx, `projects.yml`) + build/déploie le conteneur portfolio + `sync-projects.sh` |
| `deploy-project.sh <name>` | (re)déploie un projet si `deployed: true` dans `projects.yml` ; build/lance le conteneur (ou publie le build statique) ; génère le vhost ; publie la landing page si présente |
| `sync-projects.sh [--dry-run] [--apply-renames]` | réconcilie l'état réel du VPS avec `projects.yml` (ajouts, retraits, renommages) ; régénère `projects.md` |
| `remove-project.sh <name>` | suppression sécurisée (backup avant suppression, confirmation) |
| `deploy-all.sh` | boucle `deploy-project.sh` sur tous les projets `deployed: true` |
| `healthcheck.sh` | vérifie HTTP 200 sur apex + sous-domaines + landings, état des conteneurs, expiration TLS |
| `rollback.sh <name\|portfolio>` | revient à la release/`SHA` précédent·e |

Garde-fous communs : `set -Eeuo pipefail`, noms de projet validés
(`^[a-z][a-z0-9-]{1,38}$`), toute suppression (`rm -rf`) bornée à
`/opt/vlldnt/`, `projects.yml` illisible → abandon sans rien toucher, logs
horodatés dans `/opt/vlldnt/logs/`.

**Important — exécution manuelle** : lancer ces scripts en tant que
`deploy` avec son propre `cwd` (`sudo -iu deploy <script>`, pas
`sudo -u deploy` depuis le home de `ubuntu`) — sinon `docker compose`
échoue en tentant de lire un répertoire courant auquel `deploy` n'a pas accès.

---

## 8. CI/CD — GitHub Actions

Chaque repo projet et le repo `portfolio` ont leurs propres workflows,
tous ciblant le même VPS via SSH (secret `SSH_HOST`/`SSH_USER`/`SSH_KEY`,
`concurrency: vlldnt-vps` pour sérialiser les déploiements).

| Repo | Workflow | Déclencheur | Rôle |
|---|---|---|---|
| `flashcard` | `ci.yml` | push + PR → `main` | lint, tests (vitest), lint OpenAPI (Spectral), build — **matrice Node 20/22** |
| `flashcard` | `deploy.yml` | push → `main` | SSH → `deploy-project.sh flashcard` |
| `tilleul-canac` | `docker.yml` | push + PR → `main`, tags `v*` | build image Docker (front) + smoke test HTTP ; push GHCR hors PR |
| `tilleul-canac` | `backend-tests.yml` | push + PR → `main` | pytest (Django) avec service Postgres |
| `tilleul-canac` | `deploy.yml` | push → `main` | SSH → `deploy-project.sh tilleul-canac` |
| `tilleul-canac` | `sync-availability.yml` | cron (3h) | régénère `public/data/availability.json` depuis l'iCal Booking, commit auto |
| `tilleul-canac` | `reviews-reminder.yml` | cron (lundi) | ouvre une issue de rappel pour mettre à jour les avis Booking |
| `portfolio` | `ci.yml` | push + PR → `main` | build check (Astro) |
| `portfolio` | `deploy-portfolio.yml` | push → `main` | SSH → `deploy-portfolio.sh` (déploie le site perso + réinstalle l'infra) |
| `portfolio` | `sync.yml` | push → `main` sur `projects.yml` (dry-run) ; `workflow_dispatch` (apply) | SSH → `deploy-portfolio.sh && sync-projects.sh` — seul moyen d'ajouter/retirer un projet du VPS |

**Protection de branche `main`** (recommandée, à activer une fois par repo) :
statuts requis avant merge —
- `flashcard` : `Lint, tests & build (20)`, `Lint, tests & build (22)`
- `tilleul-canac` : `docker`, `pytest`
- `portfolio` : `build`

`tilleul-canac-api` n'a pas de workflow séparé : il partage le repo et les
workflows de `tilleul-canac` (le déploiement de l'API est déclenché par
`sync-projects.sh`, pas par un `deploy.yml` dédié).

---

## 9. Tâches planifiées (cron, user `deploy`)

```
17 */3 * * *  tilleul-canac-api/backend/scripts/cron.sh sync_ical      → logs/tilleul-canac-api-sync_ical.log
*/10 * * * *  tilleul-canac-api/backend/scripts/cron.sh expire_holds   → logs/tilleul-canac-api-expire_holds.log
```

---

## 10. État connu / points ouverts

- **DNS `tilleul-canac-api.vlldnt.fr` manquant** : le conteneur et le vhost
  nginx sont prêts, mais aucun enregistrement A n'existe côté OVH pour ce
  sous-domaine (contrairement à `flashcard` et `tilleul-canac`) → à ajouter
  manuellement dans la zone DNS (`A` → `137.74.175.164`).
- **Protection de branche** non encore activée sur les 3 repos (voir §8) —
  commandes prêtes, à exécuter avec un compte ayant les droits admin repo.
- **`/opt/vlldnt/portfolio/{current,releases}`** : résidus de l'ancien mode
  de déploiement statique du portfolio, remplacés par le conteneur (§5) —
  à purger.
