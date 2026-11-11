#!/usr/bin/env bash
# Downloads the pinned TLA+ tools (v1.7.4) next to this script and checks their sha256.
# Usage: ./get-tla2tools.sh
set -euo pipefail
cd "$(dirname "$0")"

VERSION="v1.7.4"
URL="https://github.com/tlaplus/tlaplus/releases/download/${VERSION}/tla2tools.jar"
SHA256="936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88"
JAR="tla2tools.jar"

if [ ! -f "$JAR" ]; then
  curl -fsSL -o "$JAR.part" "$URL"
  mv "$JAR.part" "$JAR"
fi

if command -v sha256sum >/dev/null 2>&1; then
  echo "${SHA256}  ${JAR}" | sha256sum -c - >/dev/null
else
  echo "${SHA256}  ${JAR}" | shasum -a 256 -c - >/dev/null
fi || { echo "tla2tools.jar: sha256 mismatch; delete it and run again" >&2; exit 1; }

echo "tla2tools.jar ${VERSION}: sha256 OK"
