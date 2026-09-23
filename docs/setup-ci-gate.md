# Configurer la CI/CD Gate — Clé SSH + Secrets GitHub

## 🎯 Objectif

Permettre à GitHub Actions de déployer **un projet applicatif** sur le VPS de façon sécurisée, **sans donner un shell complet au CI**.

Le principe : chaque projet a sa propre paire de clés SSH. La clé publique est posée sur le serveur avec une **forced command** (`ci-gate`) qui limite ce que le CI peut exécuter.

```
┌─ git (versionné) ──────────────────────┐
│                                        │
│  mon-app/                              │
│  ├── .github/workflows/deploy.yml      │  ← Template CI/CD
│  └── deploy/scripts/deploy.sh          │  ← Logique de déploiement
│                                        │
│  docker-homelab-infra/                 │
│  └── docs/install-ci-gate.sh           │  ← Script d'installation UNIQUE
│                                        │
└────────────────────────────────────────┘
                      │ SSH
                      ▼
┌─ serveur (pas versionné) ─────────────┐
│                                        │
│  /usr/local/sbin/ci-gate               │  ← Script garde-barrière
│  ~deploy/.ssh/authorized_keys          │  ← Clé publique + forced command
│                                        │
└────────────────────────────────────────┘
```

> **Ce qui est versionné** : le template CI/CD, le script de déploiement, et le script d'installation unique.
>
> **Ce qui ne l'est PAS** : `ci-gate` sur le serveur (comme `authorized_keys`, c'est une config serveur), les clés SSH privées.

---

## 1. Générer une clé SSH dédiée au CI

**Une seule fois par projet.** Sur ta machine locale (pas sur le serveur) :

```bash
# Créer le dossier si besoin
mkdir -p ~/keys

# Générer une clé ed25519 (plus courte et sécurisée que RSA)
ssh-keygen -t ed25519 -f ~/keys/ci-mon-projet -C "ci@mon-projet" -N ""
```

Ça produit deux fichiers :

| Fichier | Usage |
|---------|-------|
| `ci-mon-projet` | **Clé privée** → secret GitHub `ORACLE_SSH_KEY` |
| `ci-mon-projet.pub` | **Clé publique** → posée dans `authorized_keys` du serveur |

> **Pourquoi ed25519 plutôt que RSA ?** Les clés RSA 4096 bits marchent mais sont 3× plus longues. ed25519 est plus courte, aussi sécurisée, et supportée par tous les serveurs récents (OpenSSH 6.5+).

> **`-N ""`** = pas de passphrase. C'est nécessaire pour que le CI puisse se connecter sans interaction humaine. La sécurité repose sur le secret GitHub, pas sur une passphrase.

---

## 2. Créer l'utilisateur `deploy` sur le serveur (premier projet uniquement)

```bash
# Sur le VPS
sudo adduser --disabled-password --gecos "" deploy
```

L'utilisateur `deploy` est dédié au CI :
- Pas de mot de passe (`--disabled-password`)
- Pas d'accès `sudo`
- Uniquement SSH par clé

---

## 3. Poser la clé publique dans `authorized_keys`

```bash
# Sur le VPS
sudo -u deploy mkdir -p ~deploy/.ssh
sudo -u deploy chmod 700 ~deploy/.ssh
sudo -u deploy touch ~deploy/.ssh/authorized_keys
sudo -u deploy chmod 600 ~deploy/.ssh/authorized_keys
```

Depuis ta machine locale, lis la clé publique :

```bash
cat ~/keys/ci-mon-projet.pub
```

Copie la sortie, puis sur le serveur :

```bash
# Sur le VPS
echo "ta-clé-publique-copiée" | sudo tee -a ~deploy/.ssh/authorized_keys
```

> **Pourquoi ne pas utiliser `ssh-copy-id` ?** Parce que l'utilisateur `deploy` n'a pas de mot de passe, donc `ssh-copy-id` ne peut pas s'authentifier. On copie manuellement.

---

## 4. Installer `ci-gate` sur le serveur

### 4.1 Copier le script d'installation

Le script `install-ci-gate.sh` est versionné dans `docker-homelab-infra/docs/`. Transfère-le sur le serveur et exécute-le :

```bash
# Depuis ta machine locale
scp docs/install-ci-gate.sh deploy@ton-vps:/tmp/install-ci-gate.sh
```

### 4.2 Exécuter le script d'installation

```bash
# Sur le VPS
sudo bash /tmp/install-ci-gate.sh ~/ci-mon-projet.pub
```

Le script fait deux choses automatiquement :

1. **Installe `ci-gate` dans `/usr/local/sbin/ci-gate`** — le script garde-barrière
2. **Ajoute la forced command** sur la ligne de ta clé dans `authorized_keys` :
   ```
   restrict,command="/usr/local/sbin/ci-gate",no-pty,no-port-forwarding,no-agent-forwarding,no-X11-forwarding ssh-ed25519 AAAA... ci@mon-projet
   ```

Le script crée une sauvegarde de `authorized_keys` avant modification (`authorized_keys.bak.YYYYMMDD-HHMMSS`).

> **⚠️ `ci-gate` n'est pas versionné dans le repo.** C'est une configuration serveur, comme `authorized_keys` ou `sshd_config`. Le versionner créerait un paradoxe : le CI ne peut exécuter QUE `ci-gate`, donc on ne pourrait pas le mettre à jour depuis le CI... sauf que c'est lui qu'on veut contrôler.
>
> La seule chose versionnée est **`install-ci-gate.sh`** — le script d'installation unique, exécuté une fois en root sur le serveur.

### 4.3 Ajouter un nouveau projet dans `ci-gate`

Quand tu ajoutes un nouveau projet, édite `/usr/local/sbin/ci-gate` sur le serveur :

```bash
# Sur le VPS (en root)
sudo vi /usr/local/sbin/ci-gate
```

Cherche la ligne `PROJECTS` et ajoute le nom du projet :

```bash
readonly PROJECTS=(
  portfolio
  mon-nouveau-projet     # ← ajouté
)
```

Sans cette étape, `ssh oracle "deploy mon-nouveau-projet staging <sha>"` échoue avec `[ci-gate] COMMAND REFUSED` — volontairement, pas un bug.

---

## 5. Tester la gate

### 5.1 Tester que les commandes autorisées passent

```bash
# Depuis ta machine locale
ssh -i ~/keys/ci-mon-projet deploy@ton-vps status
```

Tu dois voir la liste des conteneurs Docker.

### 5.2 Tester que les commandes non autorisées sont refusées

```bash
ssh -i ~/keys/ci-mon-projet deploy@ton-vps "ls /"
# Réponse : [ci-gate] COMMAND REFUSED: ls /

ssh -i ~/keys/ci-mon-projet deploy@ton-vps "rm -rf /"
# Réponse : [ci-gate] COMMAND REFUSED: rm -rf /

ssh -i ~/keys/ci-mon-projet deploy@ton-vps
# Pas de shell — la forced command s'exécute et refuse (commande vide)
```

> **Test critique** : essaie `rm -rf /`. Si ça passe, la gate ne fonctionne pas et le CI a un accès total au serveur → corrige immédiatement.

---

## 6. Configurer les secrets GitHub

Sur GitHub, dans **Settings → Secrets and variables → Actions** de ton repo applicatif :

| Secret | Valeur |
|--------|--------|
| `REGISTRY_HOST` | `registry.bachelart.fr` |
| `REGISTRY_USER` | Le nom d'utilisateur htpasswd du registry |
| `REGISTRY_PASSWORD` | Le mot de passe htpasswd |
| `ORACLE_HOST` | L'IP ou le domaine du VPS (ex: `142.93.1.1`) |
| `ORACLE_SSH_USER` | `deploy` |
| `ORACLE_SSH_KEY` | **Le contenu du fichier `ci-mon-projet`** (pas `.pub`) |

Pour copier la clé privée :

```bash
cat ~/keys/ci-mon-projet
```

Copie **tout le contenu** (y compris les `-----BEGIN OPENSSH PRIVATE KEY-----` et `-----END OPENSSH PRIVATE KEY-----`) et colle-le dans le champ `ORACLE_SSH_KEY`.

> **⚠️ Cette clé privée donne accès au déploiement.** Ne la partage pas, ne la commite pas, ne la mets pas dans un `.env`. Stockage uniquement dans les secrets GitHub.

---

## 7. Copier le template CI/CD

Copie [`deploy-template.yml`](deploy-template.yml) dans le repo applicatif :

```bash
# Depuis docker-homelab-infra
cp docs/deploy-template.yml ../mon-app/.github/workflows/deploy.yml
```

Puis édite-le pour changer :
- `PROJECT_NAME: my-app` → `PROJECT_NAME: mon-projet` (tel qu'écrit dans `PROJECTS` du `ci-gate`)
- Les tags d'image si besoin

---

## 8. Cloner le projet sur le serveur (premier déploiement)

Avant que le CI puisse déployer, il faut que le projet existe sur le serveur :

```bash
# Sur le VPS (via ta clé personnelle, pas la clé CI)
cd /home/deploy
sudo git clone git@github.com:user/mon-projet.git
sudo chown -R deploy:deploy mon-projet/
```

> **Pourquoi `sudo` ?** L'utilisateur `deploy` n'a pas de clé GitHub — clone avec ta clé perso, puis change le propriétaire.

Une fois cloné, crée les fichiers `.env.prod` et `.env.staging` :

```bash
# Sur le VPS
sudo -u deploy cp /home/deploy/mon-projet/deploy/.env.prod.example /home/deploy/mon-projet/.env.prod
sudo -u deploy cp /home/deploy/mon-projet/deploy/.env.staging.example /home/deploy/mon-projet/.env.staging
# Éditer avec les vraies valeurs
sudo -u deploy vi /home/deploy/mon-projet/.env.prod
sudo -u deploy vi /home/deploy/mon-projet/.env.staging
```

---

## 9. Schéma final : comment ça s'assemble

```
                ┌──────────────────────────────────────┐
                │           GitHub Actions              │
                │                                      │
                │  .github/workflows/deploy.yml         │
                │                                      │
                │  1. Build + push image → registry    │
                │  2. ssh deploy@vps \                  │
                │       "deploy mon-projet staging<SHA>" │
                └──────────────┬───────────────────────┘
                               │
                               │ SSH (clé privée CI)
                               ▼
                ┌──────────────────────────────────────┐
                │      Serveur (VPS)                   │
                │                                      │
                │  authorized_keys contient :          │
                │  restrict,command="/usr/local/sbin/  │
                │  ci-gate",no-pty,... ssh-ed25519 ...  │
                │                                      │
                │  ↓ /usr/local/sbin/ci-gate           │
                │    reçoit $SSH_ORIGINAL_COMMAND       │
                │                                      │
                │  "deploy mon-projet staging <sha>"    │
                │     → projet whitelisté ?            │
                │     → environnement valide ?         │
                │     → SHA valide ?                   │
                │     → bash deploy/scripts/deploy.sh  │
                │                                      │
                │  "rm -rf /"                          │
                │     → [ci-gate] COMMAND REFUSED      │
                └──────────────────────────────────────┘
```

---

## 10. Par projet : checklist

| # | Action | Fait ? |
|---|--------|--------|
| 1 | Générer une clé : `ssh-keygen -t ed25519 -f ~/keys/ci-mon-projet -C "ci@mon-projet" -N ""` | ☐ |
| 2 | Ajouter la clé publique dans `~deploy/.ssh/authorized_keys` (sans forced command) | ☐ |
| 3 | Exécuter `install-ci-gate.sh` sur le serveur (ou ajouter manuellement la forced command) | ☐ |
| 4 | Ajouter le projet dans `PROJECTS` de `/usr/local/sbin/ci-gate` sur le serveur | ☐ |
| 5 | Copier `deploy-template.yml` dans `.github/workflows/deploy.yml` du projet | ☐ |
| 6 | Changer `PROJECT_NAME` et `platforms` dans `deploy.yml` | ☐ |
| 7 | Configurer les secrets GitHub (`ORACLE_SSH_KEY`, `REGISTRY_HOST`, etc.) | ☐ |
| 8 | Cloner le projet sur le serveur : `sudo git clone ... && chown -R deploy:deploy` | ☐ |
| 9 | Créer les fichiers `.env.prod` et `.env.staging` | ☐ |
| 10 | Tester : `ssh -i ~/keys/ci-mon-projet deploy@vps status` → OK | ☐ |
| 11 | Tester : `ssh -i ~/keys/ci-mon-projet deploy@vps "rm -rf /"` → REFUSED | ☐ |
| 12 | Push sur `develop` → vérifier CI build + déploiement staging | ☐ |
| 13 | Push sur `main` → vérifier CI déploiement prod | ☐ |

---

## 11. Pièges & debug

### 🔴 "Permission denied (publickey)"
- La clé publique n'est pas dans `authorized_keys`
- Les permissions de `~deploy/.ssh` ne sont pas `700`, ou `authorized_keys` n'est pas `600`
- L'option `command=` est mal formatée (vérifie qu'il n'y a pas de saut de ligne dans la directive)

### 🔴 "[ci-gate] COMMAND REFUSED: deploy"
- Le projet n'est pas dans la liste `PROJECTS` de `/usr/local/sbin/ci-gate`
- Ou la syntaxe est incorrecte : vérifie que le workflow envoie bien `deploy <projet> <env> <sha>` (4 arguments)

### 🔴 Le CI dit "No such file or directory"
- Le projet n'est pas cloné sur le serveur, ou pas au bon endroit
- Vérifie : `ls /home/deploy/mon-projet`

### 🔴 Le CI build OK mais le déploiement staging ne se déclenche pas
- Tu es peut-être sur la branche `main` et pas `develop`
- Vérifie les conditions `if:` dans `deploy.yml` : staging attend `refs/heads/develop`

### 🔴 Ajouter un nouveau projet : la CI échoue avec "COMMAND REFUSED"
- Le projet n'est pas whitelisté dans `PROJECTS` de `/usr/local/sbin/ci-gate` sur le serveur
- Édite le fichier, ajoute le nom, pas besoin de redémarrer quoi que ce soit

---

## 🔗 Références

- [install-ci-gate.sh](install-ci-gate.sh) — script d'installation unique (versionné ici)
- [deploy-template.yml](deploy-template.yml) — template CI/CD à copier dans chaque projet
- [S6.md — CI/CD avec SSH gate](../tasks/S6.md) — la spec pédagogique originale
- [watchtower-to-cicd.md](watchtower-to-cicd.md) — pourquoi Watchtower a été remplacé par ce pipeline