# F04 — Drift de `ActiveBaby` en costaking: upstream lo *resetea* con un upgrade (v4.8), la explotabilidad no está demostrada estáticamente

**Estado:** hecho verificado (main contiene `app/upgrades/v4_8/upgrade.go`, +352 líneas, que **recalcula `ActiveBaby` de todos los costakers**). Camino de explotación: **analítico, no ejecutado**. Severidad propuesta: candidato a robo del pool de co-staking; **no** lo cuento como confirmado.

## 1. Hechos verificados

1. `main` añade el upgrade **v4.8** cuyo único trabajo es:
   - `zeroOutCoStakerRwdsActiveBaby` (pone `ActiveBaby = 0` en **todos** los `CostakerRewardsTracker`),
   - `IncrementRewardsPeriod`,
   - `getAllBABYStakers` (delegaciones actuales a validadores del set del epoch) y `updateCostakerActiveBabyRewardsTracker` (recalcula `ActiveBaby` y `TotalScore`).
   Es decir: **upstream considera que el `ActiveBaby` del estado vivo está mal** y sólo se arregla recalculándolo.
2. Ya hubo un reset equivalente en **v4.2** (`ResetCoStakerRwdsTracker`, que resetea `ActiveSats`/`ActiveBaby`); el comentario de main lo corrige para decir "ActiveSats **and ActiveBaby**". Dos resets ⇒ la contabilidad se degrada de forma recurrente.
3. En live la contabilidad depende de `StakingCache.DeltaSharesPerDelegator` + `OriginalTokens/OriginalShares` para reconstruir el stake *pre-slash* en el cierre de epoch (`hooks_epoching.go:updateCoStkTrackerForDelegators`), y `Sanitize()` **sólo** corrige `ActiveBaby == -1` (`types/rewards.go:100-108`); con cualquier otro negativo o con un delta perdido, el valor queda desviado.
4. `x/costaking` tiene un `EndBlocker` que hace `stkCache.Clear()` **en cada bloque** (`keeper.go:125-128`), y el orden de EndBlockers (`app/app.go:402-432`) decide si los `DeltaShares` cacheados sobreviven hasta `AfterEpochEnds`. Si no sobreviven, el cierre de epoch resta el stake **actual** (post-unbond) con tokens **pre-slash**: `ActiveBaby` residual = parte desbondeada, es decir **BABY fantasma** que sigue puntuando.

## 2. Camino de robo (si el drift es alcista)

`TotalScore = min(ActiveSatoshis, ActiveBaby / 200)` (`types/score.go`). `ActiveBaby` fantasma con BTC real (`ActiveSatoshis`) ⇒ score inflado ⇒ mayor parte del pool de co-staking **a costa del resto de costakers**:

1. Ser validador (permissionless) con autodelegación de BABY `X`.
2. Delegar `X` (o captar) a ese validador: `ActiveBaby = X`.
3. Auto-slash (equivocación, permitida; coste 1 % del stake del validador + jail).
4. Desbondear **parcialmente** `P` en el mismo epoch (`MsgUndelegate` se ejecuta en el cierre de epoch vía `x/epoching`).
5. Cierre de epoch: el validador slasheado sale del set activo ⇒ `removeBabyForDelegators`; si los `DeltaShares` no se aplican, resta `X − P` ⇒ **`ActiveBaby = P`** aunque el stake real a validadores activos sea 0.
6. Como el validador ya no está en el set activo, ningún hook posterior corrige ese `P` ⇒ el score inflado **persiste** hasta el reset de v4.8.
7. Coste: 1 % del stake del validador (capital propio) + gas; el `P` desbondeado **se recupera** tras el unbonding. PnL > 0 contra el pool (fondos de terceros) y contra la parte de los demás costakers.

## 3. Qué falta para confirmarlo (y por qué no lo declaro crítico)

- **Ejecutar** el harness (`repos/babylon-benchmark`: bitcoind + babylond + FP) con `MsgUndelegate` parcial + slash en el mismo epoch y leer `ActiveBaby`/`TotalScore`: es el único modo de fijar (a) si el drift es alcista, (b) cuánto vale, y (c) si el `EndBlocker` de costaking corre antes o después del de epoching en el bloque de cierre. Sin toolchain Go en este entorno no se puede.
- Los tests nuevos de main (`TestHookStakingSlashedValidator_{PreSlashDelegationUnbond,PostSlashDelegationUnbond,MixedPreAndPostSlashUnbond,MultipleDeltaShares,OnlyPostSlashDelegationExists}`) fijan el comportamiento correcto y son el **mapa exacto** de los casos en que live desvía: se pueden portar tal cual como PoC en cuanto haya Go.
- El "hecho que lo mata": que el orden de EndBlockers haga sobrevivir los `DeltaShares` en todos los caminos (entonces el drift sería sólo redondeo ±1, ya tolerado por `Sanitize`) y que el residuo sea siempre ≤ 0. **Esto no lo he podido descartar ni confirmar.**

## 4. Por qué lo incluyo en el informe

Porque es el único punto del árbol donde upstream **migra estado** para corregir contabilidad de usuarios en el release siguiente (v4.8) y porque el vector encaja con el encargo (permissionless, valor de terceros, estado desplegado). Se entrega como **hipótesis fuerte con evidencia documental** (el propio upgrade), no como hallazgo cerrado.
