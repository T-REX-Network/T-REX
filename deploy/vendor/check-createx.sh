#!/bin/sh
# Opt-in check: rebuilds CreateX from its pinned source commit with its own compiler settings and compares the
# creation code with deploy/vendor/createx.hex (and BytecodeStore.CREATEX_INITCODE_HASH). Needs network and forge.
#   sh deploy/vendor/check-createx.sh
set -eu
COMMIT=6e853597b890fe49cb67c3c1f6e8df39a99c560d
EXPECTED=0x12ec861579b63a3ab9db3b5a23c57d56402ad3061475b088f17054e2f2daf22f
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/src"
curl -sSfL -o "$WORK/src/CreateX.sol" "https://raw.githubusercontent.com/pcaversaccio/createx/$COMMIT/src/CreateX.sol"
cat > "$WORK/foundry.toml" <<'TOML'
[profile.default]
src = "src"
out = "out"
solc_version = "0.8.23"
evm_version = "paris"
optimizer = true
optimizer_runs = 10_000_000
via_ir = false
bytecode_hash = "none"
TOML
(cd "$WORK" && forge build --root "$WORK" >/dev/null)
BUILT=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['bytecode']['object'])" "$WORK/out/CreateX.sol/CreateX.json" | cast keccak)
VENDORED=$(cast keccak "$(tr -d '[:space:]' < "$ROOT/deploy/vendor/createx.hex")")
echo "rebuilt:  $BUILT"
echo "vendored: $VENDORED"
echo "pinned:   $EXPECTED"
[ "$BUILT" = "$EXPECTED" ] && [ "$VENDORED" = "$EXPECTED" ] && echo "OK: createx.hex rebuilds bit for bit from $COMMIT"
