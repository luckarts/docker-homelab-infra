#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Orchestrateur de l'infrastructure Docker partagée
# =============================================================================
# Usage: ./deploy.sh <sous-commande>
#
# Sous-commandes :
#   networks     Créer les réseaux Docker partagés (fait)
#   traefik      Déployer Traefik (fait)
#   registry     Déployer le registry privé (fait)
#   monitoring   Déployer la stack monitoring (à venir)
#   all          Déployer toute l'infra (à venir)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Couleurs ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# ── Sous-commande : networks ──
cmd_networks() {
  log_info "Création des réseaux Docker partagés..."

  for net in traefik-web monitoring-network; do
    if docker network ls --format '{{.Name}}' | grep -q "^$net$"; then
      log_warn "Réseau '$net' existe déjà — ignoré."
    else
      docker network create --driver bridge "$net"
      log_info "Réseau '$net' créé."
    fi
  done

  log_info "✓ Réseaux terminé."
}

# ── Sous-commande : traefik ───────────────────────────────────────────────────
cmd_traefik() {
  log_info "Déploiement de Traefik v3..."

  # Créer acme.json si absent (sinon Traefik refuse de démarrer)
  if [[ ! -f "$PROJECT_ROOT/traefik/acme.json" ]]; then
    touch "$PROJECT_ROOT/traefik/acme.json"
    chmod 600 "$PROJECT_ROOT/traefik/acme.json"
    log_info "acme.json créé avec chmod 600."
  else
    log_warn "acme.json existe déjà."
  fi

  docker compose -f "$PROJECT_ROOT/traefik/docker-compose.yml" up -d
  log_info "✓ Traefik déployé."
}

# ── Sous-commande : registry ───────────────────────────────────────────────────
cmd_registry() {
  echo "🚀 Déploiement registry Docker..."

  # Charger .env s'il existe
  if [[ -f "$PROJECT_ROOT/.env" ]]; then
    set -a
    source "$PROJECT_ROOT/.env"
    set +a
  fi

  # Vérifier que htpasswd est disponible
  if ! command -v htpasswd &> /dev/null; then
    log_error "htpasswd absent — installe apache2-utils (apt install apache2-utils)"
    exit 1
  fi

  # Créer le dossier data si absent
  mkdir -p "$PROJECT_ROOT/registry/data"

  # Générer htpasswd si absent
  if [[ -f "$PROJECT_ROOT/registry/htpasswd" ]]; then
    log_warn "htpasswd existe déjà."
  else
    if [[ -z "${REGISTRY_USER:-}" || -z "${REGISTRY_PASS:-}" ]]; then
      log_warn "REGISTRY_USER/REGISTRY_PASS non définis dans .env — création interactive..."
      htpasswd -Bc "$PROJECT_ROOT/registry/htpasswd" admin
    else
      htpasswd -Bbc "$PROJECT_ROOT/registry/htpasswd" "$REGISTRY_USER" "$REGISTRY_PASS"
      log_info "htpasswd généré depuis .env ($REGISTRY_USER)."
    fi
  fi

  docker compose -f "$PROJECT_ROOT/registry/docker-compose.yml" up -d
  log_info "✅ Registry lancé"
}

# ── Aide ──────────────────────────────────────────────────────────────────────
cmd_help() {
  cat <<EOF
Usage: $(basename "$0") <sous-commande>

Sous-commandes :
  networks     Créer les réseaux Docker partagés (idempotent)
  traefik      Déployer Traefik
  registry     Déployer registry
Exemple :
  ./scripts/deploy.sh networks
EOF
}

# ── Dispatch ──
main() {
  if [[ $# -lt 1 ]]; then
    cmd_help
    exit 1
  fi

  case "$1" in
    networks)     cmd_networks    "$@" ;;
    traefik)      cmd_traefik     "$@" ;;
    registry)     cmd_registry    "$@" ;;
    *)
        log_error "Sous-commande inconnue :  $1"
        cmd_help
        exit 1
        ;;
  esac
}

main "$@"
