#!/bin/sh
# Entrypoint wrapper that substitutes environment variables in alertmanager.yml
# before starting Alertmanager.

set -e

CONFIG_FILE="/etc/alertmanager/alertmanager.yml"
TEMPLATE_FILE="/etc/alertmanager/alertmanager.template.yml"

if [ -f "$TEMPLATE_FILE" ]; then
  # envsubst from gettext is unavailable in non-Alpine images,
  # so substitute variables with a portable sed expression.
  echo "Substituting environment variables in Alertmanager config..."
  envsubst_portable() {
    sed \
      -e "s|\${ALERTMANAGER_SMTP_USERNAME}|${ALERTMANAGER_SMTP_USERNAME:-}|g" \
      -e "s|\${ALERTMANAGER_SMTP_PASSWORD}|${ALERTMANAGER_SMTP_PASSWORD:-}|g" \
      -e 's/\${[^}]*}//g' \
  }
  envsubst_portable < "$TEMPLATE_FILE" > "$CONFIG_FILE"
fi

exec alertmanager "$@"