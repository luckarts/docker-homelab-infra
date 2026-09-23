#!/bin/sh
# =============================================================================
# entrypoint.sh — Entrypoint Alertmanager avec substitution de variables
# =============================================================================
# Remplace les variables d'environnement ${VAR} dans le template par leurs
# valeurs, ecrit le resultat dans alertmanager.yml, puis lance Alertmanager.
#
# Pourquoi un template ?
#   Alertmanager ne supporte PAS les variables d'environnement dans sa config
#   — contrairement a Prometheus ou Grafana. On passe par envsubst.
# =============================================================================

set -e

CONFIG_FILE="/etc/alertmanager/alertmanager.yml"
TEMPLATE_FILE="/etc/alertmanager/alertmanager.template.yml"

if [ -f "$TEMPLATE_FILE" ]; then
  if ! command -v envsubst >/dev/null 2>&1; then
    apk add --no-cache gettext >/dev/null 2>&1
  fi
  echo "Substituting environment variables in Alertmanager config..."
  envsubst < "$TEMPLATE_FILE" > "$CONFIG_FILE"
fi

exec alertmanager "$@"
