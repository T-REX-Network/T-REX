#!/usr/bin/env bash
# Downloads the pinned Apalache release (0.62.4) into .tools/ next to this script and checks its sha256.
# Usage: ./get-apalache.sh
set -euo pipefail
cd "$(dirname "$0")"

VERSION="0.62.4"
TGZ="apalache-${VERSION}.tgz"
URL="https://github.com/apalache-mc/apalache/releases/download/v${VERSION}/${TGZ}"
SHA256="b781b53bba32fac14ac2e02b0332e1dc2edc64cb7b850c0608d8142cc7aa2ef4"   # the release's sha256sum.txt
DIR=".tools"

mkdir -p "$DIR"
if [ ! -x "$DIR/apalache-${VERSION}/bin/apalache-mc" ]; then
  if [ ! -f "$DIR/$TGZ" ]; then
    curl -fsSL -o "$DIR/$TGZ.part" "$URL"
    mv "$DIR/$TGZ.part" "$DIR/$TGZ"
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    echo "${SHA256}  ${DIR}/${TGZ}" | sha256sum -c - >/dev/null
  else
    echo "${SHA256}  ${DIR}/${TGZ}" | shasum -a 256 -c - >/dev/null
  fi || { echo "${TGZ}: sha256 mismatch; delete ${DIR}/${TGZ} and run again" >&2; exit 1; }
  # Extract into a fresh directory first, so a failed extraction leaves no partial install behind.
  rm -rf "$DIR/extract" && mkdir "$DIR/extract"
  tar -xzf "$DIR/$TGZ" -C "$DIR/extract"
  rm -rf "$DIR/apalache-${VERSION}"
  mv "$DIR/extract/apalache" "$DIR/apalache-${VERSION}" 2>/dev/null \
    || mv "$DIR/extract/apalache-${VERSION}" "$DIR/apalache-${VERSION}"
  rm -rf "$DIR/extract"
  rm -f "$DIR/$TGZ"
  echo "Apalache ${VERSION}: sha256 OK"
fi

echo "Apalache ${VERSION}: ${DIR}/apalache-${VERSION}/bin/apalache-mc"
