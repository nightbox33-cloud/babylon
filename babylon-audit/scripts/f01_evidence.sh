#!/usr/bin/env bash
# F01 - evidencia reproducible: la comision que usa el split de recompensas
# en v4.7.0 sale del VotingPowerDistCache (stale) y main la refresca.
# Requiere: worktree live en /home/user/audit/v470 (git worktree add -f ... 0c1f1447)
#           y el clon con tags en /home/user/audit/upstream-babylon
set -euo pipefail
LIVE=${LIVE:-/home/user/audit/v470}
UP=${UP:-/home/user/audit/upstream-babylon}

echo "### 1. live: el split usa *fp.Commission cacheada"
grep -n "fp.Commission\|GetCoinsPortion\|coinsForBTCDels" "$LIVE/x/incentive/keeper/btc_staking_gauge.go"

echo
echo "### 2. live: la comision solo se lee del store al ENTRAR en la dist-cache"
grep -n "NewFinalityProviderDistInfo\|loadFP" "$LIVE/x/finality/keeper/power_dist_change.go"
sed -n '226,240p' "$LIVE/x/finality/types/power_table.go"

echo
echo "### 3. live: rewardBTCStaking NO refresca comisiones"
grep -n "Commission" "$LIVE/x/finality/keeper/rewarding.go" || echo "  (sin coincidencias -> no hay refresco)"

echo
echo "### 4. main: refreshFPCommissions + test"
cd "$UP"
git diff v4.7.0 main -- x/finality/keeper/rewarding.go
git diff v4.7.0 main -- '*_test.go' | grep -n "RefreshesCommission" -A55 | head -70

echo
echo "### 5. limites de comision (Rate/MaxRate/MaxChangeRate <= 1)"
sed -n '19,50p' "$LIVE/x/btcstaking/types/commission.go"
sed -n '265,320p' "$LIVE/x/btcstaking/keeper/finality_providers.go"
