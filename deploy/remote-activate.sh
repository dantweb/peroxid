#!/bin/sh
# Runs ON the server as the CI user `github-actions` (never root), called by deploy.sh:
#   remote-activate.sh /var/www/oxid/oxid75/peroxid/releases/<sha>
# It writes only inside the project folder: switches `current` to the release (nginx includes
# current/build/nginx-pay1.conf), reloads nginx through its one sudo rule, health-checks every port
# and ROLLS BACK to the previous release if nginx did not come up with the new configuration.
# Keeps the five newest releases. Prerequisite: deploy/server-setup.sh (run once, as root).
set -eu

RELEASE="$1"
BASE="$(dirname "$(dirname "$RELEASE")")"   # …/peroxid
PREVIOUS="$(readlink -f "$BASE/current" 2>/dev/null || true)"
RELOAD="${NGINX_RELOAD:-sudo -n /usr/sbin/nginx -s reload}"
CURL="${HEALTH_CURL:-curl -ksf -m 10}"

test -f "$RELEASE/dist/index.html"
test -f "$RELEASE/build/nginx-pay1.conf"

switch() { ln -sfn "$1" "$BASE/current.next" && mv -Tf "$BASE/current.next" "$BASE/current"; }  # atomic

healthy() {
  for port in $(sed -n 's/^ *listen \([0-9]*\).*/\1/p' "$RELEASE/build/nginx-pay1.conf"); do
    $CURL "https://127.0.0.1:$port/oxid-config.json" > /dev/null || return 1
  done
}

switch "$RELEASE"
$RELOAD
sleep 2
if healthy; then
  echo "activated $(basename "$RELEASE")"
else
  echo "the new release is not healthy — rolling back" >&2
  if [ -n "$PREVIOUS" ]; then switch "$PREVIOUS"; $RELOAD; fi
  exit 1
fi

# housekeeping: keep the newest five releases
ls -1dt "$BASE"/releases/*/ 2>/dev/null | tail -n +6 | xargs -r rm -rf
