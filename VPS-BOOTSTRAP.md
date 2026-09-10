# VPS-BOOTSTRAP — mise en place unique de `/opt/vlldnt/`

À exécuter **une seule fois**, connecté en `ssh ubuntu@137.74.175.164`
(root SSH désactivé → `sudo`). Idempotent dans les grandes lignes : relançable.

Pré-requis :
- l'apex `vlldnt.fr` répond déjà en HTTPS (ancien layout `/var/www/` — on bascule ici) ;
- un jeton API OVH (zone DNS `vlldnt.fr`, droits GET/POST/PUT/DELETE) — créé sur
  <https://api.ovh.com/createToken/> ;
- le dépôt GitHub `portfolio` existe (peut être quasi vide, mais **doit** contenir
  `projects.yml`, `scripts/`, `deploy/nginx/`).

---

## 1. Paquets

```bash
sudo apt-get update
sudo apt-get install -y git curl rsync jq nginx python3-certbot-dns-ovh

# yq v4 (mikefarah) — parseur YAML des scripts
sudo curl -fsSL -o /usr/local/bin/yq \
  https://github.com/mikefarah/yq/releases/download/v4.44.3/yq_linux_amd64
sudo chmod +x /usr/local/bin/yq
yq --version

# Node 20 (build des sites statiques sur le VPS)
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt-get install -y nodejs
node -v
```

> Docker n'est nécessaire que pour un projet `runtime: compose` — l'installer
> alors : `curl -fsSL https://get.docker.com | sudo sh && sudo usermod -aG docker deploy`.

## 2. Squelette `/opt/vlldnt/`

```bash
sudo mkdir -p /opt/vlldnt/{portfolio/releases,projects,landing-pages,config,data,scripts,logs} \
              /opt/vlldnt/backups/orphan-data \
              /opt/vlldnt/nginx/{templates,snippets,generated/apps,generated/landings}
sudo chown -R deploy:deploy /opt/vlldnt
sudo chmod 750 /opt/vlldnt/config

# page d'attente pour que nginx charge avant le 1er déploiement
sudo -u deploy mkdir -p /opt/vlldnt/portfolio/releases/000000
echo '<!doctype html><title>vlldnt.fr</title><h1>Déploiement en cours…</h1>' \
  | sudo -u deploy tee /opt/vlldnt/portfolio/releases/000000/index.html >/dev/null
sudo -u deploy ln -sfn releases/000000 /opt/vlldnt/portfolio/current
```

## 3. Droits sudo minimaux pour `deploy`

```bash
echo 'deploy ALL=(root) NOPASSWD: /usr/sbin/nginx -t, /bin/systemctl reload nginx' \
  | sudo tee /etc/sudoers.d/vlldnt-deploy
sudo chmod 440 /etc/sudoers.d/vlldnt-deploy
sudo visudo -cf /etc/sudoers.d/vlldnt-deploy
```

## 4. Certificat wildcard (DNS-01 OVH)

```bash
sudo -u deploy tee /opt/vlldnt/config/ovh.ini >/dev/null <<'EOF'
dns_ovh_endpoint = ovh-eu
dns_ovh_application_key = REMPLACER
dns_ovh_application_secret = REMPLACER
dns_ovh_consumer_key = REMPLACER
EOF
sudo chmod 600 /opt/vlldnt/config/ovh.ini
sudo chown root:root /opt/vlldnt/config/ovh.ini   # certbot tourne en root

sudo certbot certonly --dns-ovh \
  --dns-ovh-credentials /opt/vlldnt/config/ovh.ini \
  --dns-ovh-propagation-seconds 60 \
  --cert-name vlldnt.fr \
  -d 'vlldnt.fr' -d '*.vlldnt.fr' \
  --non-interactive --agree-tos -m tomvieilledent@gmail.com --expand

# hook de reload après renouvellement (si absent)
sudo mkdir -p /etc/letsencrypt/renewal-hooks/deploy
printf '#!/bin/sh\nsystemctl reload nginx\n' \
  | sudo tee /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh >/dev/null
sudo chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
sudo certbot renew --dry-run
```

## 5. Premier clone du dépôt `portfolio` + installation de l'infra

```bash
sudo -u deploy git clone https://github.com/tomvieilledent/portfolio.git \
  /opt/vlldnt/portfolio/src

cd /opt/vlldnt/portfolio/src
sudo -u deploy install -m 755 scripts/*.sh /opt/vlldnt/scripts/
sudo -u deploy install -m 644 deploy/nginx/*.tmpl /opt/vlldnt/nginx/templates/
sudo -u deploy install -m 644 deploy/nginx/vlldnt-security-headers.conf \
  /opt/vlldnt/nginx/snippets/security-headers.conf
sudo -u deploy install -m 644 deploy/nginx/vlldnt.conf.base /opt/vlldnt/nginx/vlldnt.conf
sudo -u deploy cp projects.yml /opt/vlldnt/config/projects.yml
```

## 6. Bascule du vhost apex vers `/opt/vlldnt/`

```bash
# sauvegarde de l'ancien
sudo tar czf /opt/vlldnt/backups/pre-migration-$(date +%Y%m%d-%H%M%S).tar.gz \
  /etc/nginx /var/www 2>/dev/null || true

sudo rm -f /etc/nginx/sites-enabled/vlldnt.fr.conf /etc/nginx/sites-enabled/default
sudo ln -sf /opt/vlldnt/nginx/vlldnt.conf /etc/nginx/sites-enabled/vlldnt.conf
sudo nginx -t && sudo systemctl reload nginx

curl -I https://vlldnt.fr            # page d'attente, en-têtes de sécurité présents
```

## 7. Premier déploiement

```bash
sudo -u deploy bash /opt/vlldnt/scripts/deploy-portfolio.sh
sudo -u deploy bash /opt/vlldnt/scripts/sync-projects.sh --dry-run
```

> `deploy-portfolio.sh` échoue tant que le dépôt `portfolio` ne contient pas de
> vrai site (`package.json` + build produisant `dist/index.html`). Le remplir,
> puis relancer (ou pousser sur `main` → workflow **Deploy portfolio**).

## 8. Secrets GitHub (dépôts `portfolio` et chaque projet)

`Settings → Secrets and variables → Actions` :

| Nom | Valeur |
|---|---|
| `SSH_HOST` | `137.74.175.164` |
| `SSH_USER` | `deploy` |
| `SSH_KEY` | clé privée de déploiement (celle déjà dans `~deploy/.ssh/authorized_keys`) |
| `SSH_KNOWN_HOSTS` | `ssh-keyscan -p 22 137.74.175.164` |

## 9. Activer flashcard

1. Dépôt `flashcard` : copier `examples/project.deploy.yml` → `.github/workflows/deploy.yml`
   (remplacer `<NOM>` par `flashcard`), retirer l'ancien `deploy.yml` (rsync direct),
   ajouter les 4 secrets.
2. Dépôt `portfolio` : `projects.yml` → `flashcard: deployed: true`, commit/push.
3. Actions → **Sync projects** → *Run workflow* → `dry_run: false`.
4. `sudo -u deploy bash /opt/vlldnt/scripts/healthcheck.sh`.

## 10. Décommissionner l'ancien layout

Une fois `vlldnt.fr`, `vlldnt.fr/flashcard` et `flashcard.vlldnt.fr` verts :

```bash
sudo rm -rf /var/www/vlldnt.fr
sudo rm -f  /etc/nginx/sites-available/vlldnt.fr.conf
# le tar de l'étape 6 reste dans /opt/vlldnt/backups/
```
