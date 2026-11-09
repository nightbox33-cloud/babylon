#!/usr/bin/env bash
# F02 - colision de prefijos {0x10} entre HeightToVersionMapKey y FpBbnAddrKey (live)
set -euo pipefail
LIVE=${LIVE:-/home/user/audit/v470}
UP=${UP:-/home/user/audit/upstream-babylon}

echo "### 1. live: prefijos del store de x/btcstaking"
grep -n "Key *=\|NewPrefix" "$LIVE/x/btcstaking/types/keys.go"

echo
echo "### 2. live: el mapa height->version se guarda en la clave EXACTA {0x10}"
grep -n "HeightToVersionMapKey" -A12 "$LIVE/x/btcstaking/keeper/params.go"

echo
echo "### 3. live: el indice FP->addr es un KeySet con prefijo decimal 16 (= {0x10})"
grep -n "fpBbnAddr" -A6 "$LIVE/x/btcstaking/keeper/keeper.go" | head -20
grep -n "fpBbnAddr\." "$LIVE/x/btcstaking/keeper/"*.go

echo
echo "### 4. export de genesis: guarda para la clave vacia (hoy no rompe)"
sed -n '329,352p' "$LIVE/x/btcstaking/keeper/genesis.go"

echo
echo "### 5. main: cambio de prefijo + migracion de store"
cd "$UP"
git diff v4.7.0 main -- x/btcstaking/types/keys.go
git show main:x/btcstaking/migrations/v2/store.go | head -60
git show main:testutil/store/key_collision.go 2>/dev/null | head -25
