#!/usr/bin/env bash

# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: BSD-3-Clause
#
# verify_extension_vsix.sh
# Verifies the Marketplace VSIX structure and Flutter Wasm fallback assets.
#
# 2026 October
# Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VSIX="${1:-}"

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

if [[ -z "$VSIX" ]]; then
  archives=("$ROOT"/build/*.vsix)
  [[ "${#archives[@]}" == 1 ]] ||
    fail 'Expected exactly one VSIX; run make extension first'
  VSIX="${archives[0]}"
fi

[[ -f "$VSIX" ]] || fail "VSIX not found: $VSIX"

entries="$(unzip -Z1 "$VSIX")"
require_entry() {
  grep -Fxq "$1" <<<"$entries" ||
    fail "VSIX is missing required entry: $1"
}

for entry in \
  '[Content_Types].xml' \
  extension.vsixmanifest \
  extension/package.json \
  extension/extension.js \
  extension/icon.png \
  extension/readme.md \
  extension/LICENSE.txt \
  extension/changelog.md \
  extension/THIRD_PARTY_NOTICES.md \
  extension/shared/module_info_helper.js \
  extension/flutter_web/index.html \
  extension/flutter_web/flutter_bootstrap.js \
  extension/flutter_web/main.dart.wasm \
  extension/flutter_web/main.dart.mjs \
  extension/flutter_web/main.dart.js \
  extension/flutter_web/assets/AssetManifest.bin \
  extension/flutter_web/assets/elk_layout_only.js; do
  require_entry "$entry"
done

unzip -p "$VSIX" extension/flutter_web/flutter_bootstrap.js |
  node -e '
    let source = "";
    process.stdin.on("data", chunk => source += chunk);
    process.stdin.on("end", () => {
      const match = source.match(/_flutter\.buildConfig\s*=\s*(\{[^\n]*\});/);
      if (!match) throw new Error("Flutter bootstrap has no readable build configuration");
      const { builds } = JSON.parse(match[1]);
      const [wasm, javascript] = builds;
      if (wasm?.compileTarget !== "dart2wasm" ||
          wasm.mainWasmPath !== "main.dart.wasm" ||
          wasm.jsSupportRuntimePath !== "main.dart.mjs" ||
          javascript?.compileTarget !== "dart2js" ||
          javascript.mainJsPath !== "main.dart.js") {
        throw new Error("Flutter bootstrap must select Wasm first with a JavaScript fallback");
      }
    });
  '

pubspec_version="$(awk '/^version:/ { print $2; exit }' "$ROOT/pubspec.yaml")"
source_publisher="$(
  node -p 'require(process.argv[1]).publisher' "$ROOT/package.json"
)"
package_version="$(
  unzip -p "$VSIX" extension/package.json |
    node -e 'let input = ""; process.stdin.on("data", c => input += c); process.stdin.on("end", () => console.log(JSON.parse(input).version));'
)"
package_publisher="$(
  unzip -p "$VSIX" extension/package.json |
    node -e 'let input = ""; process.stdin.on("data", c => input += c); process.stdin.on("end", () => console.log(JSON.parse(input).publisher));'
)"
[[ "$package_version" == "$pubspec_version" ]] ||
  fail "VSIX package version $package_version does not match pubspec $pubspec_version"
[[ "$package_publisher" == "$source_publisher" ]] ||
  fail "VSIX package publisher $package_publisher does not match package.json $source_publisher"
[[ "$package_publisher" == "intel-corporation" ]] ||
  fail "VSIX package publisher must be intel-corporation, got $package_publisher"

printf 'Verified Marketplace VSIX: %s (%s.rohd-schematic-viewer %s, Wasm + JS fallback present).\n' \
  "${VSIX#$ROOT/}" "$package_publisher" "$package_version"
