#!/usr/bin/env bash
#
# Pre-commit quality gate — run it before every commit.
#
# The same file lives in oxid-fe-core, oxid-fe-user and peroxid. It runs a gate only
# when the repo's package.json defines the npm script, so one file serves all three and the
# gates stay the ones documented in docs/quality-gates.md (CI runs the same npm scripts).
#
# Usage: ./bin/pre-commit-check.sh [--fast] [--no-e2e] [--help]
#   --fast     static analysis + unit tests only (no build, no violations report, no e2e)
#   --no-e2e   everything except the Playwright suite (e2e needs a running shop/browser)
#
# Gates, in order (a failed gate does not stop the run — all results are collected):
#   1. Lint + format      npm run lint            ESLint + Prettier
#   2. Types              npm run type-check      vue-tsc --noEmit
#   3. Dead code          npm run knip
#   4. Security audit     npm audit               any advisory fails; never waived
#   5. Unit/integration   npm run test:coverage   (falls back to npm test)
#   6. Build              npm run build
#   7. Violations report  npm run evaluate
#   8. E2E                npm run test:e2e        Playwright
#
# Exit code: 0 = COMMITABLE, 1 = at least one gate failed.

set -u

FAST=false
RUN_E2E=true
for arg in "$@"; do
  case "$arg" in
    --fast) FAST=true; RUN_E2E=false ;;
    --no-e2e) RUN_E2E=false ;;
    -h | --help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown flag '$arg' (known: --fast, --no-e2e, --help)" >&2; exit 2 ;;
  esac
done

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'
FAILED=()
SKIPPED=()

has_script() {
  node -e 'process.exit(require("./package.json").scripts?.[process.argv[1]] ? 0 : 1)' "$1"
}

# run_gate <label> <command...> — runs the command, records pass/fail.
run_gate() {
  local label="$1"
  shift
  echo ">>> $label"
  if "$@"; then
    echo "${GREEN}✓ $label passed${NC}"
  else
    echo "${RED}✗ $label failed${NC}"
    FAILED+=("$label")
  fi
  echo
}

# run_script_gate <label> <npm-script> [<fallback-npm-script>]
run_script_gate() {
  local label="$1" script="$2" fallback="${3:-}"
  if has_script "$script"; then
    run_gate "$label" npm run --silent "$script"
  elif [ -n "$fallback" ] && has_script "$fallback"; then
    run_gate "$label" npm run --silent "$fallback"
  else
    SKIPPED+=("$label (no npm script '$script')")
  fi
}

if [ ! -d node_modules ]; then
  echo "${RED}node_modules is missing — run 'npm ci' first.${NC}" >&2
  exit 2
fi

echo "======================================"
echo "Pre-commit checks: $(basename "$PWD")$($FAST && echo ' (fast)')"
echo "======================================"
echo

run_script_gate "Lint + format" lint
run_script_gate "Types" type-check
run_script_gate "Dead code (knip)" knip
run_gate "Security audit (npm audit)" npm audit
run_script_gate "Unit/integration tests" test:coverage test

if ! $FAST; then
  run_script_gate "Build" build
  run_script_gate "Violations report" evaluate
fi

if $RUN_E2E; then
  run_script_gate "E2E (Playwright)" test:e2e
fi

echo "======================================"
echo "SUMMARY"
echo "======================================"
for item in "${SKIPPED[@]+"${SKIPPED[@]}"}"; do
  echo "${YELLOW}- skipped: $item${NC}"
done
if $FAST || ! $RUN_E2E; then
  echo "${YELLOW}- not run by choice: $($FAST && echo 'build, violations report, ')e2e${NC}"
fi

if [ ${#FAILED[@]} -eq 0 ]; then
  echo "${GREEN}✓ ALL CHECKS PASSED — Status: COMMITABLE${NC}"
  exit 0
fi

echo "${RED}✗ FAILED GATES:${NC}"
for gate in "${FAILED[@]}"; do
  echo "${RED}  - $gate${NC}"
done
echo "${RED}Status: NON-COMMITABLE — fix the issues above before committing.${NC}"
exit 1
