#!/usr/bin/env bash
# Build the org-roam-ui frontend from source with Neovim backend ports.
#
# Clones the upstream org-roam-ui repo at a pinned commit, applies
# scripts/neovim-ports.patch (source-level changes only — no minified JS
# patching), builds a static export, and replaces web/org-roam-ui/.
#
# Requirements: node, npm
# Run from the repository root.

set -euo pipefail

UPSTREAM="https://github.com/org-roam/org-roam-ui.git"
UPSTREAM_COMMIT="2894dcbf56d2eca8d3cae2b1ae183f51724b5db6"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PATCH="$REPO_ROOT/scripts/neovim-ports.patch"
WORK_DIR="$(mktemp -d)"
OUT_DIR="$REPO_ROOT/web/org-roam-ui"

cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

echo "==> Cloning upstream org-roam-ui @ $UPSTREAM_COMMIT"
git clone --depth 1 "$UPSTREAM" "$WORK_DIR/org-roam-ui"
git -C "$WORK_DIR/org-roam-ui" fetch --depth 1 origin "$UPSTREAM_COMMIT"
git -C "$WORK_DIR/org-roam-ui" checkout "$UPSTREAM_COMMIT"

echo "==> Applying Neovim ports patch"
git -C "$WORK_DIR/org-roam-ui" apply "$PATCH"

echo "==> Installing dependencies"
npm --prefix "$WORK_DIR/org-roam-ui" install --legacy-peer-deps

echo "==> Building static export"
NODE_OPTIONS=--openssl-legacy-provider \
NEXT_PUBLIC_HTTP_HOST=127.0.0.1 \
NEXT_PUBLIC_HTTP_PORT=35911 \
NEXT_PUBLIC_WS_HOST=127.0.0.1 \
NEXT_PUBLIC_WS_PORT=35913 \
npm --prefix "$WORK_DIR/org-roam-ui" run build

NODE_OPTIONS=--openssl-legacy-provider \
NEXT_PUBLIC_HTTP_HOST=127.0.0.1 \
NEXT_PUBLIC_HTTP_PORT=35911 \
NEXT_PUBLIC_WS_HOST=127.0.0.1 \
NEXT_PUBLIC_WS_PORT=35913 \
npm --prefix "$WORK_DIR/org-roam-ui" run export

echo "==> Replacing web/org-roam-ui"
rm -rf "$OUT_DIR"
cp -r "$WORK_DIR/org-roam-ui/out" "$OUT_DIR"

echo "==> Done. Frontend written to web/org-roam-ui/"
