#!/usr/bin/env bash

# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: BSD-3-Clause
#
# pana_source.sh
# Runs hosted dependency compatibility checks and Pana on this Flutter package.

set -euo pipefail

export PATH="$PATH:${PUB_CACHE:-$HOME/.pub-cache}/bin"

if ! command -v pana >/dev/null; then
  echo "Pana is required; run tool/gh_actions/install_pana.sh first." >&2
  exit 2
fi

flutter_root="${FLUTTER_ROOT:-}"
if [[ -z "$flutter_root" ]]; then
  flutter_executable="$(command -v flutter)"
  flutter_root="$(dirname "$(dirname "$(readlink -f "$flutter_executable")")")"
fi

temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/rohd-schematic-pana.XXXXXXXX")"
trap 'rm -rf "$temp_dir"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir "$temp_dir/package"

# Analyze a clean checkout so local dependency overrides and generated state
# cannot hide hosted dependency or package-quality issues.
tar -C . \
  --exclude=.git --exclude=.dart_tool --exclude=.packages \
  --exclude=build --exclude=coverage --exclude=analysis_options.yaml \
  --exclude=pubspec.lock --exclude=pubspec_overrides.yaml \
  --exclude=.flutter-plugins --exclude=.flutter-plugins-dependencies \
  -cf - . | tar -C "$temp_dir/package" -xf -

cd "$temp_dir/package"
if grep -Eq '^[[:space:]]*dependency_overrides[[:space:]]*:' pubspec.yaml; then
  echo "Move inline dependency overrides to pubspec_overrides.yaml before hosted checks." >&2
  exit 2
fi

echo "=== Hosted dependency compatibility ==="
flutter pub get
flutter analyze --fatal-infos --no-pub
flutter pub downgrade
flutter analyze --fatal-infos --no-pub

echo "=== Pana score gate ==="
# Allow the current partial API documentation score while requiring all other
# package-quality checks to pass.
PANA_ANALYSIS_INCLUDES=0 \
  pana --exit-code-threshold "${PANA_SCORE_THRESHOLD:-10}" \
  --flutter-sdk "$flutter_root" .
