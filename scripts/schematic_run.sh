#!/usr/bin/env bash

# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: BSD-3-Clause
#
# schematic_run.sh
# Runs the Schematic Viewer with selected dependency and runtime modes.
#
# 2026 August
# Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

set -euo pipefail

cd "$(dirname "$0")/.."

bash scripts/verify_flutter_version.sh

run_mode="${1:-}"

usage() {
  cat <<'USAGE'
Usage: scripts/schematic_run.sh <run-mode>

Dependency sources are selected separately with scripts/schematic_dev_mode.sh.
This command runs using the currently generated dependency configuration.
Run modes: web-debug, web-release, linux-debug, linux-release
USAGE
}

if [[ -z "$run_mode" ]]; then
  usage >&2
  exit 2
fi

case "$run_mode" in
  -h|--help|help) usage; exit 0 ;;
esac

flutter pub get

case "$run_mode" in
  web-debug)
    make stage-js
    flutter run -d web-server --web-port=9199 --web-hostname=localhost
    ;;
  web-release)
    make stage-js
    flutter run --release --wasm -d web-server --web-port=9199 --web-hostname=localhost
    ;;
  linux-debug)
    make linux-run-debug
    ;;
  linux-release)
    make linux-run-release
    ;;
  *) usage >&2; exit 2 ;;
esac
