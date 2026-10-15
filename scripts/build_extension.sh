#!/bin/sh

# Copyright (C) 2025-2026 Intel Corporation
# SPDX-License-Identifier: BSD-3-Clause
#
# build_extension.sh
# Stages the VS Code Schematic Viewer extension for VSIX packaging.
#
# 2025 January
# Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
echo "Building extension in $ROOT"

# Ensure ELK assets are staged
echo "Staging ELK assets"
bash "$ROOT/scripts/stage_js_bridge.sh"

# Extension staging directory
PKG_NAME=$(node -p "require('$ROOT/package.json').name")
PKG_VERSION=$(node -p "require('$ROOT/package.json').version")
EXT_STAGE="${EXT_STAGE:-$ROOT/build/extension/${PKG_NAME}-${PKG_VERSION}}"

echo "Staging extension files in $EXT_STAGE"
rm -rf "$EXT_STAGE"
mkdir -p "$EXT_STAGE"

# Copy main files
cp "$ROOT/package.json" "$EXT_STAGE/"
cp "$ROOT/extension.js" "$EXT_STAGE/"
cp "$ROOT/README.md" "$EXT_STAGE/"
cp "$ROOT/LICENSE" "$EXT_STAGE/"
cp "$ROOT/CODE_OF_CONDUCT.md" "$EXT_STAGE/"
cp "$ROOT/CHANGELOG.md" "$EXT_STAGE/"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$EXT_STAGE/"
cp "$ROOT/scripts/extension.vscodeignore" "$EXT_STAGE/.vscodeignore"

# Copy shared helpers beside extension.js.
mkdir -p "$EXT_STAGE/shared"
node "$ROOT/scripts/copy_devtools_extension_assets.cjs" "$EXT_STAGE/shared"

# VSIX manifest icon. Reuse the high-resolution Flutter web icon rather than
# maintaining a duplicate root-level binary.
EXTENSION_ICON="$ROOT/web/icons/schematic-512.png"
if [ ! -f "$EXTENSION_ICON" ]; then
	echo "Error: VSIX icon not found: $EXTENSION_ICON" >&2
	exit 1
fi
cp "$EXTENSION_ICON" "$EXT_STAGE/icon.png"

# Copy any root-level screenshot PNGs (for README images)
for png in "$ROOT"/*.png; do
	[ -f "$png" ] && cp "$png" "$EXT_STAGE/"
done

# Copy the README screenshot. Demo videos are GitHub-hosted release media and
# are deliberately excluded from the Marketplace package.
if [ -f "$ROOT/images/filter_bank_schematic.png" ]; then
	mkdir -p "$EXT_STAGE/images"
	cp "$ROOT/images/filter_bank_schematic.png" "$EXT_STAGE/images/"
fi

# Copy assets if present
if [ -d "$ROOT/assets" ]; then
	cp -a "$ROOT/assets" "$EXT_STAGE/"
fi
if [ -d "$ROOT/build_assets" ]; then
	cp -a "$ROOT/build_assets" "$EXT_STAGE/"
fi
if [ -d "$ROOT/media" ]; then
	cp -a "$ROOT/media" "$EXT_STAGE/"
fi
if [ -d "$ROOT/scripts" ]; then
	cp -a "$ROOT/scripts" "$EXT_STAGE/scripts"
fi

# Include Flutter web build (required for rendering)
FLUTTER_WEB="$ROOT/build/web"
if [ -d "$FLUTTER_WEB" ]; then
	echo "Including Flutter web build in extension package"
	for required in \
		"$FLUTTER_WEB/index.html" \
		"$FLUTTER_WEB/flutter_bootstrap.js" \
		"$FLUTTER_WEB/main.dart.wasm" \
		"$FLUTTER_WEB/main.dart.mjs" \
		"$FLUTTER_WEB/main.dart.js"; do
		if [ ! -f "$required" ]; then
			echo "Error: required Flutter Wasm/fallback artifact missing: $required" >&2
			exit 1
		fi
	done
	cp -a "$FLUTTER_WEB" "$EXT_STAGE/flutter_web"
else
	echo "Error: Flutter web build not found at $FLUTTER_WEB" >&2
	echo "Run 'make web-release' first to build the Flutter web app" >&2
	exit 1
fi

echo "Extension staging complete at $EXT_STAGE"
exit 0
