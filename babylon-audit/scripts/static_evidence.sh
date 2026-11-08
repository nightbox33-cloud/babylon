#!/usr/bin/env bash
# Evidencia estática reproducible — auditoría Babylon v4.7.0 (live 0c1f1447) vs main.
# Uso: bash static_evidence.sh [worktree_live] [repo_main]
set -uo pipefail

LIVE_WT="${1:-/tmp/v470}"
MAIN="${2:-/home/user/babylon}"
LIVE=0c1f1447

hr() { printf '\n=== %s ===\n' "$*"; }

if [ ! -d "$LIVE_WT" ]; then
  echo "[!] worktree live ausente; recreando en $LIVE_WT"
  ( cd "$MAIN" && git fetch --depth 1 origin 0c1f144711e138b558f579a4af27ec728f487636 \
    && git worktree add -f "$LIVE_WT" "$LIVE" )
fi
if [ ! -f /tmp/gen.json ]; then
  python3 - <<'PYEOF'
import json,base64,urllib.request
u="https://api.github.com/repos/babylonlabs-io/networks/contents/bbn-1/network-artifacts/genesis.json"
d=json.load(urllib.request.urlopen(u))
open('/tmp/gen.json','w').write(json.dumps(json.loads(base64.b64decode(d["content"]))))
PYEOF
fi

hr "identidad de los dos árboles"
( cd "$LIVE_WT" && git log --oneline -1 )
( cd "$MAIN"    && git log --oneline -1 )

hr "E1 · wasmStack nil en el router IBC (sólo main lo corrige)"
for t in 132d0502 f9006e42 b56abc97 0c1f1447; do
  printf 'live %s: var-nil=%s  AddRoute(nil)=%s\n' "$t" \
    "$( cd "$MAIN" && git show "$t:app/keepers/keepers.go" | grep -c 'var wasmStack porttypes.IBCModule' )" \
    "$( cd "$MAIN" && git show "$t:app/keepers/keepers.go" | grep -c 'AddRoute(wasmtypes.ModuleName, wasmStack)\.' )"
done
printf 'main    : var-nil=%s  AddRoute(nil)=%s\n' \
  "$( cd "$MAIN" && git show HEAD:app/keepers/keepers.go | grep -c 'var wasmStack porttypes.IBCModule' )" \
  "$( cd "$MAIN" && git show HEAD:app/keepers/keepers.go | grep -c 'AddRoute(wasmtypes.ModuleName, wasmStack)\.' )"

hr "E2 · AfterRawCheckpointForgotten corta el bucle en i=0"
( cd "$MAIN" && echo '-- live --' && git show "$LIVE:x/checkpointing/types/hooks.go" | sed -n '/AfterRawCheckpointForgotten/,/^}/p' )
( cd "$MAIN" && echo '-- main --' && git show 'HEAD:x/checkpointing/types/hooks.go' | sed -n '/AfterRawCheckpointForgotten/,/^}/p' )

hr "E3 · Sanitize: Equal(-1) vs IsNegative()"
( cd "$MAIN" && echo '-- live --' && git show "$LIVE:x/costaking/types/rewards.go" | sed -n '/func.*Sanitiz/,/^}/p' )
( cd "$MAIN" && echo '-- main --' && git show 'HEAD:x/costaking/types/rewards.go' | sed -n '/func.*Sanitiz/,/^}/p' )

hr "E4 · Validate del tracker rechaza ActiveBaby negativo"
( cd "$MAIN" && git show "$LIVE:x/costaking/types/rewards.go" | sed -n '/func (crt CostakerRewardsTracker) Validate/,/^}/p' )

hr "E5 · UpdateScore = Min(ActiveSatoshis, ActiveBaby/ratio)"
( cd "$MAIN" && git show "$LIVE:x/costaking/types/score.go" )

hr "E6 · VoteExtension.Validate en live (sólo nil/empty)"
( cd "$MAIN" && git show "$LIVE:x/checkpointing/types/types.go" | sed -n '/func.*VoteExtension.*Validate/,/^}/p' )

hr "E7 · IsFinalityProviderDeleted presente en live"
( cd "$MAIN" && git grep -n 'IsFinalityProviderDeleted' "$LIVE" -- 'x/**/*.go' | grep -v _test | grep -v mocked | grep -v expected_keepers )

hr "E8 · patrones presentes sólo en main"
for pat in validateStakerBtcPk fundingInputValue refreshFPCommissions MaxVoteExtensionSize; do
  printf '%-24s live=%s main=%s\n' "$pat" \
    "$( cd "$MAIN" && git grep -c "$pat" "$LIVE" -- '*.go' 2>/dev/null | awk -F: '{s+=$NF} END{print s+0}' )" \
    "$( cd "$MAIN" && git grep -c "$pat" HEAD -- '*.go' 2>/dev/null | awk -F: '{s+=$NF} END{print s+0}' )"
done

hr "E9 · minter.go: diff sólo de comentario"
( cd "$MAIN" && git diff "$LIVE" HEAD -- x/mint/types/minter.go )

hr "E10 · hechos de dependencias (verificados por lectura, no reproducibles offline)"
cat <<'EOF'
  cosmos-sdk v0.53.8  baseapp/baseapp.go  -> runTx tiene recover()
  cosmos-sdk v0.53.8  baseapp/abci.go     -> ProcessProposal Y PrepareProposal con defer recover()
  cosmos-sdk v0.53.8  types/utils.go      -> BigEndianToUint64 panica con 1..7 bytes
  ibc-go v10.5.0      core/keeper/msg_server.go -> ChannelOpenInit resuelve cbs del router
  wasmd v0.60.9       NewIBCHandler(...) IBCHandler -> devuelve VALOR, no puntero
EOF

hr "E11 · ante construye RefundTxDecorator con nil, el post handler real usa el keeper"
( cd "$MAIN" && git show "$LIVE:app/ante/ante.go" | grep -n 'NewRefundTxDecorator' )
( cd "$MAIN" && git show "$LIVE:app/app.go" | grep -n 'NewRefundTxDecorator\|SetPostHandler' )

hr "E12 · gas_limit del ante (10M, sólo CheckTx)"
( cd "$MAIN" && git show "$LIVE:app/ante/gas_limit.go" | grep -n 'DefaultMaxGasWantedPerTx\|IsCheckTx' )

hr "E13 · NewSortedValidatorSet con BigEndianToUint64 (panic si Addr de 1..7 bytes)"
( cd "$MAIN" && git show "$LIVE:x/epoching/types/validator.go" | sed -n '/func NewSortedValidatorSet/,/^}/p' )
echo '-- corte: el verificador de Babylon exige 20 o 32 bytes --'
( cd "$MAIN" && git show "$LIVE:app/params/config.go" | sed -n '/SetAddressVerifier/,/})/p' )

hr "E14 · de dónde salen los Addr del conjunto (validadores reales)"
( cd "$MAIN" && git show "$LIVE:x/epoching/keeper/epoch_val_set.go" | sed -n '/func (k Keeper) InitValidatorSet/,/^}/p' | head -14 )

hr "E15 · FP soft-deleted: la marca sólo se comprueba al firmar"
( cd "$MAIN" && git show "$LIVE:x/btcstaking/keeper/btc_delegations.go" | sed -n '/func (k Keeper) validateStakedFPs/,/^}/p' )
echo '-- quién escribe la marca (sólo upgrade y genesis) --'
( cd "$MAIN" && git grep -n "SoftDeleteFinalityProvider" "$LIVE" -- '*.go' | grep -v _test )
echo '-- tally: totalPower incluye peso muerto --'
( cd "$MAIN" && git show "$LIVE:x/finality/keeper/tallying.go" | sed -n '/^func tally(/,/^}/p' )

hr "E16 · robo: porciones de fee (genesis mainnet) y orden de BeginBlock"
python3 - <<'PYEOF'
import json
g=json.load(open('/tmp/gen.json'))
print("incentive:", json.dumps(g['app_state']['incentive']['params']))
p=g['app_state']['btcstaking']['params'][0]
print("slashing_rate:", p['slashing_rate'], "->", p['slashing_address'])
PYEOF
( cd "$MAIN" && git show "$LIVE:app/app.go" | grep -n "minttypes.ModuleName, incentivetypes.ModuleName" )
echo '-- GetCoinsPortion trunca (nunca redondea a favor del receptor) --'
( cd "$MAIN" && git show "$LIVE:x/incentive/types/incentive.go" | sed -n '/^func GetCoinsPortion/,/^}/p' )

hr "E17 · stake expansion: el patrón sigue permitido, el doble conteo no"
( cd "$MAIN" && git show "$LIVE:x/btcstaking/keeper/msg_server.go" | grep -n "the stk exp can unbond early prior to having the inclusion proof" )
echo '-- sólo MsgBTCUndelegate puede activar una expansión --'
( cd "$MAIN" && git show "$LIVE:x/btcstaking/keeper/msg_server.go" | grep -n "is a stake expansion, use MsgBTCUndelegate" )
echo '-- esa vía exige firma del staker y unbondea al padre en la misma tx --'
( cd "$MAIN" && git show "$LIVE:x/btcstaking/keeper/msg_server.go" | grep -n "VerifySpendStakeTxStakerSig\|ms.btcUndelegate(ctx, btcDel" )
echo '-- la remediación del GHSA-4rm2 fue una migración de una sola vez --'
( cd "$MAIN" && git show "$LIVE:app/upgrades/v4_3/upgrade.go" | grep -n "func RemediatePoisonedStakeExpansions" )

hr "E18 · mint: ninguna entrada la controla el usuario"
( cd "$MAIN" && git show "$LIVE:x/mint/types/minter.go" | sed -n '/func (m Minter) CalculateBlockProvision/,/^}/p' )

hr "E19 · tokenfactory: params sin campo de mint por sudo"
echo "Params{DenomCreationFee, DenomCreationGasConsume} — no existe EnableSudoMint en el fork"

hr "fin"
