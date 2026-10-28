#!/bin/sh
# Ships a build to pay1.oxid.dev and activates it. Used by the deploy workflow; runnable by hand:
#   DEPLOY_HOST=85.236.47.72 DEPLOY_USER=github-actions sh deploy/deploy.sh
# The user is the CI user: only it writes the project folder (deploy/server-setup.sh, once, as root).
# Expects `npm run build` to have run (dist/, build/instances, build/nginx-pay1.conf).
set -eu

: "${DEPLOY_HOST:?}" "${DEPLOY_USER:?}"
BASE="${DEPLOY_PATH:-/var/www/oxid/oxid75/peroxid}"
RELEASE="$BASE/releases/${GITHUB_SHA:-$(git rev-parse HEAD)}"
SSH="ssh -o BatchMode=yes ${DEPLOY_SSH_OPTS:-}"
TARGET="$DEPLOY_USER@$DEPLOY_HOST"

# only what runs: the compiled app, the RENDERED instance configs, the nginx config — never the YAML
$SSH "$TARGET" "mkdir -p '$RELEASE'"
tar -czf - dist build/instances build/nginx-pay1.conf | $SSH "$TARGET" "tar -xzf - -C '$RELEASE'"
$SSH "$TARGET" "sh -s '$RELEASE'" < deploy/remote-activate.sh
