#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Orchestrateur de l'infrastructure Docker partagée
# =============================================================================
# Usage: ./deploy.sh <sous-commande>
#
# Sous-commandes :
#   networks     Créer les réseaux Docker partagés (fait)
#   traefik      Déployer Traefik (fait)
#   registry     Déployer le registry privé (à venir)
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


# ── Aide ──────────────────────────────────────────────────────────────────────
cmd_help() {
  cat <<EOF
Usage: $(basename "$0") <sous-commande>

Sous-commandes :
  networks     Créer les réseaux Docker partagés (idempotent)
  traefik      Déployer Traefik

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
     traefik)     cmd_traefik     "$@" ;;

    *)
        log_error "Sous-commande inconnue :  $1"
        cmd_help
        exit 1
        ;;
  esac
}

main "$@"
