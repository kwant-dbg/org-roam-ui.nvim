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

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

guard_frontend_output() {
  local dir="$1"

  echo "==> Validating frontend output"

  if find "$dir" -maxdepth 1 -type f \( -name 'sw.js' -o -name 'workbox-*.js' -o -name 'vercel.svg' \) | grep -q .; then
    fail "stale service worker/workbox/vercel artifact remains in $dir"
  fi

  if grep -RIEq 'localhost:35901|localhost:35903|127\.0\.0\.1:35901|127\.0\.0\.1:35903|Open in Emacs|Connection with Emacs' "$dir"; then
    fail "old Emacs backend ports or visible Emacs labels remain in $dir"
  fi

  local html
  while IFS= read -r html; do
    local build_id
    build_id="$(sed -n 's/.*"buildId":"\([^"]*\)".*/\1/p' "$html")"
    [[ -n "$build_id" ]] || fail "missing Next buildId in $html"

    if grep -Eo '/_next/static/[^"]+' "$html" | grep -v "^/_next/static/$build_id/" | grep -q '/_buildManifest.js\|/_ssgManifest.js'; then
      fail "stale service-worker/build manifest build id reference in $html"
    fi

    local asset
    while IFS= read -r asset; do
      [[ -f "$dir${asset%%\?*}" ]] || fail "missing static asset referenced by $html: $asset"
    done < <(grep -Eo '/_next/static/[^"]+' "$html" | sed 's/&quot;.*//' | sort -u)
  done < <(find "$dir" -maxdepth 1 -type f -name '*.html' | sort)
}

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
NEXT_PUBLIC_WS_PORT=35913 \
npm --prefix "$WORK_DIR/org-roam-ui" run build

NODE_OPTIONS=--openssl-legacy-provider \
NEXT_PUBLIC_WS_PORT=35913 \
npm --prefix "$WORK_DIR/org-roam-ui" run export

echo "==> Removing static-export service worker leftovers"
rm -f "$WORK_DIR/org-roam-ui/out/sw.js"
rm -f "$WORK_DIR/org-roam-ui/out"/workbox-*.js
rm -f "$WORK_DIR/org-roam-ui/out/vercel.svg"
guard_frontend_output "$WORK_DIR/org-roam-ui/out"

echo "==> Replacing web/org-roam-ui"
rm -rf "$OUT_DIR"
cp -r "$WORK_DIR/org-roam-ui/out" "$OUT_DIR"
guard_frontend_output "$OUT_DIR"

echo "==> Done. Frontend written to web/org-roam-ui/"
