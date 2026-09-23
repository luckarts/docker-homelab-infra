#!/usr/bin/env bash
# =============================================================================
# install-ci-gate.sh — Installer ci-gate et le lier à une clé de déploiement
# =============================================================================
# Usage :
#   sudo bash install-ci-gate.sh <fichier-clé-publique>
#
# Exécution unique sur le serveur, en root.
# Copie ci-gate.sh dans /usr/local/sbin/ci-gate et ajoute la forced command
# à la ligne correspondant à la clé publique fournie dans authorized_keys.
#
# La clé publique doit déjà être présente dans ~deploy/.ssh/authorized_keys
# (sans forced command). Ce script l'y ajoute.
#
# Pièges :
#   - La clé publique doit exister dans authorized_keys AVANT de lancer ce script
#   - Une sauvegarde de authorized_keys est créée avant modification
#   - L'utilisateur deploy doit exister (créé avec adduser)
# =============================================================================

set -euo pipefail

# ── Vérifications ──────────────────────────────────────────────────────────

if [[ $# -lt 1 ]]; then
  echo "Usage: sudo bash $0 <fichier-clé-publique>" >&2
  echo "  Ex: sudo bash $0 ci-portfolio.pub" >&2
  exit 1
fi

PUBKEY_FILE="$1"
PUBKEY_CONTENT="$(tr -d '\n' < "$PUBKEY_FILE")"

if [[ -z "$PUBKEY_CONTENT" ]]; then
  echo "Fichier de clé publique vide ou introuvable : $PUBKEY_FILE" >&2
  exit 1
fi

if [[ $(id -u) -ne 0 ]]; then
  echo "Ce script doit être exécuté en root (sudo)." >&2
  exit 1
fi

if ! id deploy &>/dev/null; then
  echo "L'utilisateur deploy n'existe pas. Créez-le d'abord :" >&2
  echo "  sudo adduser --disabled-password --gecos '' deploy" >&2
  exit 1
fi

# ── Étape 1 : Installer ci-gate.sh dans /usr/local/sbin ──────────────────────
# Ce script est le garde-barrière : le CI ne peut exécuter QUE ce qu'il autorise.
# Il est placé dans /usr/local/sbin/, pas dans le repo, car c'est une config
# serveur (comme authorized_keys), pas du code applicatif à versionner.

echo "==> Installation de ci-gate dans /usr/local/sbin/ci-gate..."

cat > /usr/local/sbin/ci-gate << 'SCRIPT'
#!/usr/bin/env bash
# =============================================================================
# ci-gate — forced command for GitHub Actions deploy key
# =============================================================================
# Installé dans /usr/local/sbin/ci-gate par install-ci-gate.sh.
# Référencé depuis ~deploy/.ssh/authorized_keys via l'option :
#   restrict,command="/usr/local/sbin/ci-gate" ssh-ed25519 AAAA...
#
# sshd exécute ce script au lieu de la commande demandée par le client.
# La commande originale est disponible dans $SSH_ORIGINAL_COMMAND.
# Toute commande non reconnue échoue avec exit 1 → le job CI devient rouge.
# =============================================================================

set -euo pipefail

# ── Configuration ───────────────────────────────────────────────────────────
# Liste blanche des projets autorisés à être déployés par cette gate.
# Ajoutez ici chaque nouveau projet qui utilise cette clé CI.
readonly PROJECTS=(
  portfolio
  # poker-training   # ← décommentez quand le projet est ajouté
)

# Expressions régulières de validation
readonly SAFE_CHARS='^[A-Za-z0-9 ._/-]+$'
readonly SHA_RE='^[0-9a-f]{40}$'

# ── Helpers ─────────────────────────────────────────────────────────────────
deny() {
  echo "[ci-gate] COMMAND REFUSED: ${SSH_ORIGINAL_COMMAND:-<empty>}" >&2
  exit 1
}

is_project() {
  local p; for p in "${PROJECTS[@]}"; do [[ "$1" == "$p" ]] && return 0; done
  return 1
}

log() {
  logger -t ci-gate "$*"
}

# ── Dispatch ────────────────────────────────────────────────────────────────
read -ra argv <<< "$SSH_ORIGINAL_COMMAND"
cmd="${argv[0]:-}"

# Vérification : caractères autorisés uniquement (pas de quotes, $, ;, |, &, `, etc.)
[[ -n "$SSH_ORIGINAL_COMMAND" && "$SSH_ORIGINAL_COMMAND" =~ $SAFE_CHARS ]] || deny

log "cmd=${SSH_ORIGINAL_COMMAND}"

case "$cmd" in
  # ── ping : test de connexion ──────────────────────────────────────────────
  ping)
    echo "ci-gate: ok"
    ;;

  # ── status : état des conteneurs ──────────────────────────────────────────
  status)
    exec docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
    ;;

  # ── deploy : déploiement ──────────────────────────────────────────────────
  deploy)
    # Format : deploy <projet> <environnement> <sha>
    # Ex : deploy portfolio staging abc123def456...
    [[ $# -eq 3 ]] || deny
    is_project "${argv[1]}" || deny
    [[ "${argv[2]}" =~ ^(staging|prod)$ ]] || deny
    [[ "${argv[3]:-}" =~ $SHA_RE ]] || deny

    PROJECT="${argv[1]}"
    ENV="${argv[2]}"
    SHA="${argv[3]}"

    log "deploy $PROJECT ($ENV) — SHA: $SHA"

    cd "/home/deploy/$PROJECT"
    exec bash deploy/scripts/deploy.sh "$ENV" "$SHA"
    ;;

  # ── rollback : retour à la version précédente ─────────────────────────────
  rollback)
    # Format : rollback <projet> <environnement> [<sha>]
    # Ex : rollback portfolio staging abc123def456...
    # Sans SHA : utilise le tag sauvegardé avant le dernier déploiement
    [[ $# -eq 2 || $# -eq 3 ]] || deny
    is_project "${argv[1]}" || deny
    [[ "${argv[2]}" =~ ^(staging|prod)$ ]] || deny
    [[ "${argv[3]:-}" =~ $SHA_RE || -z "${argv[3]:-}" ]] || deny

    PROJECT="${argv[1]}"
    ENV="${argv[2]}"
    SHA="${argv[3]:---previous}"

    log "rollback $PROJECT ($ENV) — SHA: $SHA"

    cd "/home/deploy/$PROJECT"
    exec bash deploy/scripts/deploy.sh "$ENV" "$SHA"
    ;;

  # ── Tout le reste est refusé ──────────────────────────────────────────────
  *)
    deny
    ;;
esac
SCRIPT

chmod 755 /usr/local/sbin/ci-gate
echo "  ✓ /usr/local/sbin/ci-gate installé"

# ── Étape 2 : Ajouter la forced command dans authorized_keys ────────────────
# On cherche la ligne qui contient la clé publique (sans forced command déjà)
# et on la préfixe avec restrict,command=...

AUTH_KEYS="/home/deploy/.ssh/authorized_keys"
BACKUP="${AUTH_KEYS}.bak.$(date +%Y%m%d-%H%M%S)"

echo "==> Configuration de la forced command dans $AUTH_KEYS..."

if [[ ! -f "$AUTH_KEYS" ]]; then
  echo "  Fichier $AUTH_KEYS introuvable. Créez-le d'abord avec la clé publique." >&2
  exit 1
fi

# Sauvegarde
cp "$AUTH_KEYS" "$BACKUP"
echo "  ✓ Sauvegarde : $BACKUP"

# Chercher la ligne correspondant à la clé
LINE_NUM=$(grep -n -F "$PUBKEY_CONTENT" "$AUTH_KEYS" | head -1 | cut -d: -f1)

if [[ -z "$LINE_NUM" ]]; then
  echo "  Clé publique introuvable dans $AUTH_KEYS." >&2
  echo "  Ajoutez-la d'abord (sans forced command), puis relancez ce script." >&2
  exit 1
fi

# Vérifier si la forced command est déjà présente
if grep -F "$PUBKEY_CONTENT" "$AUTH_KEYS" | grep -q 'command='; then
  echo "  ⚠️  Une forced command est déjà configurée pour cette clé. Vérifie $AUTH_KEYS"
  echo "  Aucune modification effectuée."
  exit 0
fi

# Ajouter restrict,command=... devant la ligne
PREFIX='restrict,command="/usr/local/sbin/ci-gate",no-pty,no-port-forwarding,no-agent-forwarding,no-X11-forwarding '
sed -i "${LINE_NUM}s|^|${PREFIX}|" "$AUTH_KEYS"

echo "  ✓ Forced command ajoutée à la ligne $LINE_NUM"
echo ""
echo "==> Installation terminée."
echo ""
echo "Résumé :"
echo "  - /usr/local/sbin/ci-gate    : script garde-barrière"
echo "  - $AUTH_KEYS      : clé liée au script (ligne $LINE_NUM)"
echo "  - Sauvegarde                 : $BACKUP"
echo ""
echo "Testez la connexion :"
echo "  ssh -i ~/keys/ci-portfolio deploy@<vps> status"
echo ""
echo "Pour ajouter un nouveau projet :"
echo "  1. Ajouter le nom dans PROJECTS dans /usr/local/sbin/ci-gate"
echo "  2. Relancer install-ci-gate.sh avec la nouvelle clé (ou ajouter manuellement)"