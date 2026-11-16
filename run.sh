#!/usr/bin/env bash
# One-command DSH Web launch from source: ./run.sh [dsh web args...]
# Example: ./run.sh --no-open
set -euo pipefail
cd "$(dirname "$0")"

# start:web serves apps/web/dist without building; build once after a clean.
if [[ ! -d apps/web/dist ]]; then
  pnpm run build:artifacts
fi

exec pnpm dsh web "$@"