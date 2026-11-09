# F01 — La comisión usada para repartir recompensas es la *cacheada* (stale), no la vigente: un FP se queda con la parte de sus delegadores

**Estado:** bug real en el código desplegado (v4.7.0 `0c1f1447`). Arreglado en `main` (`8b9673c`) con `refreshFPCommissions` + test `TestRewardBTCStakingRefreshesCommission`.
**Clasificación honesta:** extracción de valor de terceros (delegadores del propio FP), permissionless y viva. **No** es drenaje de un pool sin cooperación: el atacante necesita que existan delegadores suyos (victimización opt-in).
**Módulos:** `x/finality` (construcción de la voting-power-dist-cache) + `x/incentive` (split de recompensas).

---

## 1. Bug concreto (criterio 1)

En live el split de la recompensa de un FP se calcula con `fp.Commission` **que viene del VotingPowerDistCache**, y ese campo **nunca se refresca** mientras el FP permanezca en la cache.

Split (live, `x/incentive/keeper/btc_staking_gauge.go:60-85`):

```go
fpPortion        := sdkmath.LegacyNewDec(int64(fp.TotalBondedSat)).QuoInt64(int64(totalVotingPowerOfVoters))
coinsForFpsAndDels := gauge.GetCoinsPortion(fpPortion)
coinsForCommission := types.GetCoinsPortion(coinsForFpsAndDels, *fp.Commission)   // <-- COMISIÓN CACHEADA
coinsForBTCDels    := coinsForFpsAndDels.Sub(coinsForCommission...)               // <-- lo que queda a los delegadores
k.accumulateRewardGauge(ctx, FINALITY_PROVIDER, fp.GetAddress(), coinsForCommission.Add(coinsForFpDirect...))
k.AddFinalityProviderRewardsForBtcDelegations(fp.GetAddress(), coinsForBTCDels)   // reparto por sat entre delegaciones
```

De dónde sale `fp.Commission` (live):

- `x/finality/types/power_table.go:226-238` — `NewFinalityProviderDistInfo(fp)` copia `Commission: fp.Commission` **leyendo del store de btcstaking**.
- `x/finality/keeper/power_dist_change.go:316-329` — esa función **sólo** se llama para FPs que *entran por primera vez* en la dist-cache (`fpActiveBtcPkHexList`, FPs que no estaban en la cache previa). Los FPs que ya estaban se copian tal cual, con su `Commission` de la vez anterior.
- `x/finality/keeper/rewarding.go:50-70` (live) — `rewardBTCStaking` pasa **esa** cache a `RewardBTCStaking(...)`; no hay relectura de la comisión.

`grep -rn Commission x/finality x/incentive` en live devuelve sólo: `grpc_query.go:447` (query), `power_table.go:233/290-298` (validación), `btc_staking_gauge.go:70/74/79` (el split). No existe ninguna ruta de refresco.

`main` añade exactamente eso (`x/finality/keeper/rewarding.go`):

```go
+	// refresh commission rates from the btcstaking store so that
+	// edits via MsgEditFinalityProvider are reflected in reward distribution
+	k.refreshFPCommissions(ctx, dc)
...
+func (k Keeper) refreshFPCommissions(ctx context.Context, dc *types.VotingPowerDistCache) {
+	for i := uint32(0); i < dc.NumActiveFps; i++ {
+		fp := dc.FinalityProviders[i]
+		currentFP, err := k.BTCStakingKeeper.GetFinalityProvider(ctx, fp.BtcPk.MustMarshal())
+		...
+		fp.Commission = currentFP.Commission
+	}
+}
```

y el test `TestRewardBTCStakingRefreshesCommission` (nuevo en main) fija `staleCommission=5%` en la cache, devuelve `updatedCommission=10%` desde el store y exige que la cache que llega a `RewardBTCStaking` lleve **10%**: es decir, el propio upstream documenta que en la versión previa se repartía con el valor viejo.

## 2. Permissionless / PnL (criterio 2)

- Ser FP es permissionless: `MsgCreateFinalityProvider` (BtcPk + addr BBN + PoP + `CommissionRates`), `x/btcstaking/keeper/finality_providers.go:20-70`. No hay allowlist.
- `CommissionRates.Validate()` (`x/btcstaking/types/commission.go:19-50`) sólo exige `0 ≤ Rate ≤ MaxRate ≤ 1`, `MaxChangeRate ≤ MaxRate`. **`Rate = MaxRate = MaxChangeRate = 1.0` es válido.**
- `UpdateFinalityProviderCommission` (`x/btcstaking/keeper/finality_providers.go:265-320`) permite **bajar** la comisión (sujeto a `MinCommissionRate`, 24 h entre cambios y `MaxChangeRate`), y **no toca la dist-cache**.
- PnL del atacante = `Σ_h (commission_cacheada − comisión anunciada) × coinsForFpsAndDels(h)`, sin riesgo de slashing (no hace falta ningún comportamiento equivocado en consenso). Coste: gas de 2 mensajes + el stake propio (que sigue siendo suyo).
- Víctimas: los delegadores del FP, que ven en cadena una comisión que el reparto **no** aplica.

## 3. Call graph / estado live (criterio 3)

1. `MsgCreateFinalityProvider{Rate:1.0, MaxRate:1.0, MaxChangeRate:1.0}` → FP con comisión 100 %.
2. Autodelegación mínima (`MsgCreateBTCDelegation`, ≥ `MinStakingValueSat`) → el FP entra en la dist-cache con `Commission = 1.0` **cacheada** (`power_dist_change.go` → `loadFP` → `NewFinalityProviderDistInfo`).
3. +24 h: `MsgEditFinalityProvider{Commission: 0.05}` → store = 5 %, **cache = 100 %**.
4. Cada altura finalizada: `HandleRewarding` → `rewardBTCStaking` → `RewardBTCStaking(height, dc, voters)` → el 100 % de `coinsForFpsAndDels` va al gauge `FINALITY_PROVIDER` del atacante; los delegadores reciben 0 (no 95 %).
5. Los delegadores sólo pueden cobrar lo acreditado en `BTC_STAKER`; lo acreditado es 0.

Parámetros que fijan el techo: `Commission` está acotada por `MaxRate ≤ 1`, así que el robo máximo por delegador es `(1 − comisión_anunciada)` de su parte (≈95 % si anuncia el mínimo del 5 %). El reparto **no** sobre-asigna: `coinsForCommission + coinsForBTCDels = coinsForFpsAndDels`, así que no rompe la contabilidad del módulo incentivos; simplemente cambia el beneficiario.

## 4. PoC (criterio 4) — reproducible sobre los clones, sin toolchain Go

`scripts/f01_evidence.sh` reproduce las citas (grep + `git diff v4.7.0 main`) sobre `/home/user/audit/v470` (worktree de `0c1f1447`) y `/home/user/audit/upstream-babylon`. El PoC ejecutable (test unitario, espejo del test de main) sería:

```go
// (esquema; requiere toolchain Go, no disponible en este entorno)
dc := types.NewVotingPowerDistCache()
dc.AddFinalityProviderDistInfo(&types.FinalityProviderDistInfo{
    BtcPk: fpPk, Addr: fpAddr, Commission: &one /*100% cacheada*/, TotalBondedSat: 100_000, IsTimestamped: true})
dc.NumActiveFps = 1
fKeeper.SetVotingPowerDistCache(ctx, h, dc)
fKeeper.SetVoters(ctx, h, []bbn.BIP340PubKey{fpPk})
bstakingKeeper.SetFinalityProvider(fp.Commission = 5%)     // store: 5 %
fKeeper.HandleRewarding(ctx, h, h+1)                       // live: reparte 100 % al FP
// esperado en live: gauge(FINALITY_PROVIDER, fpAddr) == 100 % de la parte del FP; gauge de delegaciones == 0
// esperado en main: 5 % / 95 %
```
PnL tras deshacer todo lo reversible: el BTC del atacante sigue siendo suyo; las recompensas de terceros acaban en su gauge → **PnL > 0** para el atacante y negativo para el delegador. No hay flash-loan/swap que deshacer.

## 5. Qué lo mataría (si no)

- Que la dist-cache se reconstruya desde el store cada altura → **no ocurre** (se copia de la previa, `power_dist_change.go`).
- Que el set activo de FPs esté permissionado (gobierno/allowlist) → no lo está: `NumActiveFps` ordena por `TotalBondedSat`.
- Que los delegadores no deleguen en un FP de comisión 100 % → **esto es lo único que limita el ataque**: es victimización opt-in, no un drenaje de un pool ajeno.
- Que `MsgEditFinalityProvider` invalidara/refrescara la cache → no lo hace.

## 6. Por qué no lo clasifico como "crítico de drenaje"

Cumple (1) bug real en live, (2) permissionless con PnL>0 y (3) transición real con params desplegados, y (4) tiene PoC. **Falla** la parte fuerte del encargo ("valor extraído de fondos de TERCEROS sin cooperación"): la víctima debe haber delegado voluntariamente en el FP del atacante. Por eso lo reporto como *el hallazgo de robo live* y marco explícitamente su condición: sin delegaciones de terceros, el bug sólo mueve recompensas del propio atacante (auto-daño).

Techo económico estimado (no medible sin estado on-chain, ver §Limitaciones del informe): el 100 % de la parte de los delegadores del atacante en el pool de BTC staking (`BtcStakingPortion = 0.181818182` de las fees + provisión de bloque interceptada), que en bbn-1 es la principal fuente de yield de los BTC delegators.
