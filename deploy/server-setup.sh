#!/bin/sh
# ONE-TIME server setup, run as root on pay1.oxid.dev (outside the project folder). After this,
# /var/www/oxid/oxid75/peroxid is written ONLY by the `github-actions` user (the CI):
#   - a self-signed origin certificate (Cloudflare "Full" mode reaches custom ports over TLS)
#   - /etc/nginx/conf.d/peroxid.conf that INCLUDES the config the CI ships with each release
#   - the folder owned by github-actions
# The CI then needs only `sudo nginx -s reload` (sudoers: /etc/sudoers.d/github-actions-nginx).
set -eu

BASE="${DEPLOY_PATH:-/var/www/oxid/oxid75/peroxid}"
CERT_DIR=/etc/ssl/peroxid

# migration from the old name (hydroxid-project): move the folder and the certificate, drop the old
# include (two includes = duplicate listen ports), and leave symlinks at the old paths so the live
# release (its config still names the old paths) keeps serving until the next deploy
OLD_BASE=/var/www/oxid/oxid75/hydroxid-project
OLD_CERT_DIR=/etc/ssl/hydroxid
if [ -d "$OLD_BASE" ] && [ ! -L "$OLD_BASE" ] && [ ! -e "$BASE" ]; then
  mv "$OLD_BASE" "$BASE" && ln -s "$BASE" "$OLD_BASE"
fi
if [ -d "$OLD_CERT_DIR" ] && [ ! -L "$OLD_CERT_DIR" ] && [ ! -e "$CERT_DIR" ]; then
  mv "$OLD_CERT_DIR" "$CERT_DIR" && ln -s "$CERT_DIR" "$OLD_CERT_DIR"
fi
rm -f /etc/nginx/conf.d/hydroxid-project.conf

mkdir -p "$CERT_DIR"
if [ ! -f "$CERT_DIR/origin.crt" ]; then
  openssl req -x509 -nodes -newkey rsa:2048 -days 3650 -keyout "$CERT_DIR/origin.key" \
    -out "$CERT_DIR/origin.crt" -subj "/CN=pay1.oxid.dev" -addext "subjectAltName=DNS:pay1.oxid.dev" 2>/dev/null
  chmod 600 "$CERT_DIR/origin.key"
fi

mkdir -p "$BASE/releases"
chown -R github-actions:github-actions "$BASE"

# root owns this one-line file; the content it pulls in belongs to the CI
printf '# managed by deploy/server-setup.sh — the server blocks ship with each release\ninclude %s/current/build/nginx-pay1.conf;\n' "$BASE" \
  > /etc/nginx/conf.d/peroxid.conf
echo "server setup done (nginx is reloaded by the next deploy)"
