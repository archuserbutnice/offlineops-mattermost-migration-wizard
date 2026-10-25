#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/mattermost-migration-wizard.sh"

bash -n "$SCRIPT"
output="$(bash "$SCRIPT" --self-test)"
printf '%s\n' "$output"
grep -Fq "PASS:" <<<"$output"
printf '\nSmoke tests passed (local checks only; no migration performed).\n'
