#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Orchestrateur de l'infrastructure Docker partagée
# =============================================================================
# Usage: ./scripts/deploy.sh <sous-commande>
#
# Ce repo NE contient PAS les apps (portfolio, poker_training) — chacune
# garde son compose.yml + .env dans son propre projet. Ici : uniquement
# ce qui est partagé entre tous les projets (réseaux, traefik, monitoring,
# registry).
#
# Sous-commandes :
#   networks     Créer les réseaux Docker partagés (idempotent)
#   traefik      Déployer Traefik v3 (reverse proxy + Let's Encrypt)
#   registry     Déployer le registry Docker privé (auth htpasswd)
#   monitoring   Déployer la stack monitoring (Prometheus + Loki + Grafana
#                + cAdvisor + node-exporter + Promtail)
#   all          Déployer toute l'infra partagée
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

# ── Helper : ensure_network ────────────────────────────────────────────
# Crée un réseau Docker s'il n'existe pas déjà (idempotent)
ensure_network() {
  docker network inspect "$1" >/dev/null 2>&1 || docker network create "$1"
}

# ── Sous-commande : networks ──────────────────────────────────────────
cmd_networks() {
  log_info "Vérification des réseaux partagés..."
  ensure_network traefik-web
  ensure_network monitoring-network
  log_info "✓ traefik-web + monitoring-network prêts"
}

# ── Sous-commande : traefik ────────────────────────────────────────────
cmd_traefik() {
  log_info "Déploiement de Traefik v3..."

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

# ── Sous-commande : registry ────────────────────────────────────────────
cmd_registry() {
  log_info "Déploiement du registry Docker..."

  if [[ -f "$PROJECT_ROOT/.env" ]]; then
    set -a
    source "$PROJECT_ROOT/.env"
    set +a
  fi

  if ! command -v htpasswd &> /dev/null; then
    log_error "htpasswd absent — installe apache2-utils (apt install apache2-utils)"
    exit 1
  fi

  mkdir -p "$PROJECT_ROOT/registry/data"

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
  log_info "✓ Registry déployé."
}

# ── Sous-commande : monitoring ─────────────────────────────────────────
cmd_monitoring() {
  log_info "Déploiement de la stack monitoring (Prometheus, Loki, Grafana, cAdvisor, Promtail)..."

  ensure_network traefik-web
  ensure_network monitoring-network

  mkdir -p "$PROJECT_ROOT/monitoring/prometheus/rules"
  mkdir -p "$PROJECT_ROOT/monitoring/loki"
  mkdir -p "$PROJECT_ROOT/monitoring/promtail"
  mkdir -p "$PROJECT_ROOT/monitoring/grafana/datasources"
  mkdir -p "$PROJECT_ROOT/monitoring/grafana/dashboards"

  docker compose -f "$PROJECT_ROOT/monitoring/compose.monitoring.yml" \
    --env-file "$PROJECT_ROOT/monitoring/.env.monitoring" up -d

  log_info "✓ Monitoring déployé."
  log_info "  Prometheus : http://localhost:9090"
  log_info "  Grafana    : https://monitoring.bachelart.fr"
}

# ── Sous-commande : all ────────────────────────────────────────────────
cmd_all() {
  log_info "Déploiement complet de l'infra partagée..."
  cmd_networks
  cmd_traefik
  cmd_monitoring
  cmd_registry
  log_info "✓ Infra partagée (traefik + monitoring + registry) déployée."
}

# ── Aide ───────────────────────────────────────────────────────────────
cmd_help() {
  cat <<EOF
Usage: $(basename "$0") <sous-commande>

Sous-commandes :
  networks     Créer les réseaux Docker partagés (idempotent)
  traefik      Déployer Traefik v3 (reverse proxy + Let's Encrypt)
  registry     Déployer le registry Docker privé (auth htpasswd)
  monitoring   Déployer la stack monitoring
  all          Déployer toute l'infra partagée

Exemple :
  ./scripts/deploy.sh networks
  ./scripts/deploy.sh all
EOF
}

# ── Dispatch ── ( dirige le flux )
main() {
  if [[ $# -lt 1 ]]; then
    cmd_help
    exit 1
  fi

  case "$1" in
    networks)     cmd_networks    "$@" ;;
    traefik)      cmd_traefik     "$@" ;;
    registry)     cmd_registry    "$@" ;;
    monitoring)   cmd_monitoring  "$@" ;;
    all)          cmd_all         "$@" ;;
    *)
        log_error "Sous-commande inconnue : $1"
        cmd_help
        exit 1
        ;;
  esac
}

main "$@"
