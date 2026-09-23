# Watchtower → CI/CD : Pourquoi et comment GitHub Actions a remplacé Watchtower

## 🧠 TL;DR

Watchtower a été **retiré de l'infrastructure partagée** et remplacé par un pipeline GitHub Actions qui fait la même chose (scruter les changements + redéployer), mais **avec validation, staging, et rollback**.

Le projet applicatif (`my-app`) utilise maintenant un workflow CI/CD complet. L'infra partagée (Traefik, Registry, Monitoring) continue d'être déployée manuellement via `deploy.sh` — ces services critiques ne doivent **pas** se mettre à jour tout seuls.

---

## 1. Qu'est-ce que Watchtower faisait ?

Watchtower était un conteneur qui tournait **sur le VPS** et surveillait le registry Docker privé. Toutes les 5 minutes, il vérifiait si une image avait changé. Si oui, il :

1. Pullait la nouvelle image
2. Arrêtait le conteneur en cours
3. Redémarrait avec la nouvelle image

```yaml
# compose.watchtower.yml (concept — ce fichier n'est plus utilisé)
services:
  watchtower:
    image: containrrr/watchtower:latest
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    environment:
      - WATCHTOWER_POLL_INTERVAL=300
      - WATCHTOWER_LABEL_ENABLE=true   # opt-in uniquement
      - WATCHTOWER_CLEANUP=true
      - REPO_USER=${REPO_USER}
      - REPO_PASS=${REPO_PASS}
```

### ✅ Les avantages de Watchtower

- **Zéro configuration CI/CD** : pas de GitHub Actions, pas de secrets, pas de pipeline à maintenir
- **Auto-update en continu** : dès qu'une image est pushée, elle est déployée dans les 5 minutes
- **Simple** : un seul conteneur, quelques variables d'environnement

### ❌ Les problèmes de Watchtower

| Problème | Pourquoi c'est grave |
|----------|---------------------|
| **Pas de validation** | Watchtower déploie sans savoir si l'image fonctionne. Crash → downtime direct |
| **Pas de rollback automatique** | Si une version est buggée, Watchtower ne sait pas revenir en arrière — intervention humaine obligatoire |
| **Déploiement "cowboy"** | Aucune séparation staging/prod : ce qui arrive sur le registry arrive en prod |
| **Pas de traçabilité** | GitHub SHA ? Tag ? Aucune metadata — on ne sait pas quelle version tourne sans `docker inspect` |
| **Scope trop large** | Même avec `WATCHTOWER_LABEL_ENABLE=true`, Watchtower est un agent avec accès root au socket Docker — un bug dans Watchtower = tous les conteneurs sont exposés |

---

## 2. Ce que GitHub Actions apporte à la place

Le workflow `deploy.yml` fait exactement la même boucle (build → push → déployer) mais **découpée en étapes validées** :

```
                    ┌──────────────┐
                    │  git push    │
                    └──────┬───────┘
                           ▼
                    ┌──────────────┐
                    │  Build image │  ← Docker Buildx (multi-stage)
                    │  Push → Reg  │     cache GHA, linux/arm64
                    └──────┬───────┘
                           ▼
              ┌────────────────────────┐
              │  Deploy → STAGING     │  ← branche develop
              │  (ssh ci-gate deploy) │
              └───────────┬────────────┘
                          ▼
              ┌────────────────────────┐
              │  Deploy → PROD        │  ← branche main, seulement si
              │  (ssh ci-gate deploy) │     staging a réussi
              └────────────────────────┘
```

### 🔍 Détail de chaque étape

#### Build (job `build`)

```yaml
- name: Build and push (runner)
  uses: docker/build-push-action@v6
  with:
    context: .
    target: runner
    push: true
    tags: |
      ${{ env.REGISTRY }}/portfolio:${{ github.sha }}
      ${{ env.REGISTRY }}/portfolio:latest-${{ github.ref == 'refs/heads/main' && 'prod' || 'staging' }}
```

- **Tagging explicite** : `latest-prod` ou `latest-staging` selon la branche — le serveur ne pull pas "latest" aveuglément
- **SHA commité** : tag `${{ github.sha }}` = traçabilité exacte
- **Double target** : `runner` (l'app Next.js) ET `migrate` (les migrations de base de données) — Watchtower n'aurait eu aucun concept de cibles multiples
- **Cache GHA** : `cache-from: type=gha` et `cache-to: type=gha,mode=max` → les builds suivants sont accélérés car les couches Docker sont réutilisées entre runs GitHub

#### Staging (job `deploy-staging`)

```yaml
deploy-staging:
  runs-on: ubuntu-latest
  needs: build
  if: github.ref == 'refs/heads/develop'
```

- Se déclenche **uniquement** sur la branche `develop`
- Dépend du job `build` : si le build échoue, staging ne démarre pas
- Utilise la **SSH gate** (`ci-gate.sh`) : le CI ne peut exécuter QUE la commande `deploy portfolio staging <sha>` — pas de shell, pas de `rm -rf`, pas d'accès aux autres projets

#### Production (job `deploy-prod`)

```yaml
deploy-prod:
  needs: [build, deploy-staging]
  if: |
    github.ref == 'refs/heads/main' &&
    needs.build.result == 'success' &&
    (needs.deploy-staging.result == 'success' || needs.deploy-staging.result == 'skipped')
```

- Se déclenche **uniquement** sur `main`
- Exige que **staging ait réussi OU ait été skip** (un push direct sur main ne passe pas par staging, mais c'est le cas normal d'un merge PR)
- Environnement `production` dans GitHub : les secrets de prod sont séparés du staging

### 📦 Transfert des fichiers de déploiement

```yaml
- name: Sync deploy files
  run: |
    rsync -avz --delete \
      --exclude='.env.*' \
      --exclude='acme.json' \
      --exclude='htpasswd' \
      -e "ssh $SSH_VERBOSE" \
      deploy/ oracle:/home/deploy/portfolio/deploy/
```

Avant chaque déploiement, les fichiers `deploy/` du repo sont synchronisés avec le VPS. Cela permet de versionner les `docker-compose.yml` et les scripts, sans jamais exposer les secrets (exclus par `--exclude`). Watchtower n'avait aucun mécanisme de synchonisation : il redémarrait le conteneur, mais les fichiers de configuration qui ne sont pas dans l'image ou dans le volume restaient figés sur le serveur.

---

## 3. Comparaison détaillée

| Critère | Watchtower | GitHub Actions (ce workflow) |
|---------|-----------|------------------------------|
| **Déclencheur** | Pull du registry toutes les 5min | Push git + workflow_dispatch (manuel) |
| **Build** | Sur le serveur (déconseillé) | Sur runner GitHub (Docker Buildx) |
| **Validation** | Aucune | Staging obligatoire avant prod |
| **Rollback** | Aucun (docker pull + up manuel) | git revert + push → CI rebuild |git revert + push → CI rebuild |
| **Traçabilité** | Aucune | SHA du commit, tags explicites |
| **Multi-cibles** | Un seul tag `latest` | Targets Docker `runner` + `migrate` |
| **Sécurité SSH** | Pas d'agent CI | Forced command SSH (ci-gate.sh) |
| **Caching** | Aucun | Cache GitHub Actions entre builds |
| **Sync fichiers** | Aucun | rsync des `deploy/` avant déploiement |
| **Coût cognitif** | Faible (prêt en 5min) | Moyen (à configurer une fois) |

---

## 4. Pourquoi Watchtower est resté dans `tasks/S5.md`

Le fichier S5.md est un **support pédagogique**, pas une spec de production. Il documente :

1. **La tentation Watchtower** : pourquoi c'est séduisant (c'est simple, ça marche)
2. **Les pièges** : ce qui casse quand on le met en prod sans réflexion
3. **Le label opt-in** : première leçon de sécurité "defense-in-depth"
4. **La leçon finale** : comprendre pourquoi CI/CD est supérieur

C'est un outil d'apprentissage, pas un plan d'implémentation. Tout le monde passe par "j'utilise Watchtower" avant d'arriver à "je build un pipeline CI/CD" — c'est le chemin normal.

---

## 5. Où va le CI/CD maintenant ?

Le workflow `deploy.yml` dans `my-app/.github/workflows/deploy.yml` est le **template de référence** pour tout nouveau projet :

1. Chaque projet a son propre fichier `deploy.yml` dans son repo
2. Le repo d'infrastructure (`docker-homelab-infra`) contient seulement les scripts serveur : `ci-gate.sh`, `deploy.sh`
3. La SSH gate vérifie que le CI ne peut exécuter QUE les commandes autorisées (un projet ne peut pas déployer un autre projet)

```
┌─────────────────────┐     ┌──────────────────────┐     ┌─────────────────┐
│  my-app/.github/    │     │  docker-homelab-infra │     │  VPS            │
│  workflows/         │     │                       │     │                 │
│  deploy.yml         │────>│  deploy/scripts/      │────>│  ci-gate.sh     │
│                     │     │  ci-gate.sh           │     │  (forced cmd)   │
└─────────────────────┘     └──────────────────────┘     └─────────────────┘
   Chaque projet              Un seul point                Script verrouillé
   a son pipeline             d'entrée serveur             sans shell
```

---

## 6. Leçons apprises

1. **Watchtower est un excellent outil pédagogique** : il montre le besoin (auto-update) sans la complexité (CI/CD), et crée la frustration qui motive à apprendre le pipeline.
2. **Ne jamais mettre Watchtower en prod** : le piège est d'y rester. C'est confortable, mais ça n'évolue pas.
3. **CI/CD = validation gate** : le vrai bénéfice n'est pas "déploiement automatique" (Watchtower le fait aussi), c'est "je ne déploie pas si les tests ne passent pas".
4. **SSH gate = defense-in-depth** : même si le CI est compromis, le serveur ne donne qu'un accès limité via `ci-gate.sh`.
5. **Tags explicites > `latest`** : avec Watchtower, tout est `latest`. Avec CI/CD, chaque déploiement a un SHA, une branche, un environnement. Le rollback est un `git revert`.

---

## 🔗 Références

- [Workflow deploy.yml](../../my-app/.github/workflows/deploy.yml) — le pipeline actuel
- [S5.md — Watchtower (pédagogique)](../tasks/S5.md) — la leçon qui explique pourquoi on a changé
- [S7.md — SSH Gate et déploiement sécurisé](../tasks/S7.md) — comment `ci-gate.sh` verrouille les accès
- [Fichier : ci-gate.sh](deploy/scripts/ci-gate.sh) — le script de forced command
- [Fichier : deploy.sh](deploy/scripts/deploy.sh) — l'orchestrateur des sous-commandes