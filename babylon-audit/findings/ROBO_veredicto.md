# Robo de valor — cierre exhaustivo (v4.7.0, live `0c1f1447`)

**Pregunta:** ¿existe un bug que permita quedarse con valor ajeno —drenar el pool de incentive, inflar recompensas propias, robar BTC delegado o capturar fees—?

**Respuesta: no lo encontré.** Este documento cierra los frentes que quedaban abiertos en la ronda anterior: aritmética de `DecimalRewards`, reparto del fee collector, el GHSA-4rm2 de stake expansion, el módulo mint, tokenfactory y el slashing.

---

## 1. El reparto de fees no se puede inflar

Portions reales (módulo `incentive` + `costaking`), tomadas en este orden en `BeginBlock`:

```
mint → incentive → costaking → distribution     (app/app.go:366-372)
```

| Etapa | Porción | Sobre |
|---|---|---|
| incentive `BtcStakingPortion` | 0.181818182 | saldo del fee collector |
| incentive `FpPortion` | 0.013636364 | saldo del fee collector |
| costaking `CostakingPortion` | 0.531073446 | **remanente** |
| costaking `ValidatorsPortion` | 0.016949153 | **remanente** |

Total detraído del fee collector: **0.743477145**; queda **0.256522855** para `x/distribution`.

Puntos que descartan robo:

- `GetCoinsPortion` calcula en `DecCoins`, multiplica y **trunca** (`TruncateDecimal`). El truncamiento siempre juega **contra** el que cobra: la suma de partes nunca excede el total.
- Ninguna porción es manipulable por un usuario: son params de módulo (gov).
- El orden es el correcto (`incentive` y `costaking` antes de `distribution`), así que no hay porción que se aplique dos veces sobre el mismo saldo.
- `accumulateRewards` (incentive) transfiere **antes** de repartir; si falla, `panic` ⇒ rollback. No hay crédito sin fondos.

**Debilidad anotada (no robo):** en costaking el orden está invertido — `AccumulateRewardGaugeForCostaker` primero y `SendCoinsFromModuleToModule` después. Si el módulo costaking no tuviera saldo, la tx revierte y el usuario queda bloqueado; nunca cobra de más. Vale reportarlo como higiene.

## 2. `DecimalRewards` y el redondeo

- `DecimalRewards = 10^20`. Los acumuladores guardan `rewards × 1e20 / sats` y se dividen al pagar (`QuoInt`), truncando.
- La multiplicación pasa por `CoinsSafeMulInt` → `Int.SafeMul`, que **devuelve error en overflow** (no envuelve). Con `Int` de 256 bits y acumuladores de ~1e20 × coins, no hay desbordamiento práctico.
- El truncamiento al pagar perjudica al costaker/delegador (queda polvo en el módulo), nunca lo beneficia.
- Para cobrar de más habría que **inflar los sats propios**. Eso exige (a) declarar más `StakingValue` del que la tx paga —imposible, se verifica la salida exacta en la tx real de Bitcoin—, o (b) mantener las recompensas acumulándose tras el unbonding —imposible, `MsgBTCUndelegate` exige la firma del staker—, o (c) forzar `RemoveBondedSats` a fallar para que el delta negativo no se aplique —eso hace `panic`, no suma.

## 3. GHSA-4rm2 ("phantom stake"): el patrón sigue permitido, pero el doble conteo no

Éste era el frente más prometedor de la ronda. Hallazgo relevante:

**La remediación del upgrade v4.3 actuó sólo sobre el estado existente, no cerró el patrón.** `RemediatePoisonedStakeExpansions` (`app/upgrades/v4_3/upgrade.go`) busca hijos que son stake-expansion, **sin inclusion proof**, con `DelegatorUnbondingInfo` ya fijado, y fuerza el unbond del padre. Es una migración de una sola vez, idempotente, con contadores de "skipped".

Y el patrón **sigue siendo legal en el código de v4.7.0**, por diseño explícito:

```go
// x/btcstaking/keeper/msg_server.go:549
!stakeExpansionDel.IsUnbondedEarly() // the stk exp can unbond early prior to having the inclusion proof
```

Pero el doble conteo está cerrado estructuralmente, y lo verifiqué en tres puntos:

1. **Una expansión no puede activarse por la vía normal.** `AddBTCDelegationInclusionProof` la rechaza explícitamente: *"the BTC delegation %s is a stake expansion, use MsgBTCUndelegate to set the inclusion proof"* (`msg_server.go:226`). La **única** vía de activación es `MsgBTCUndelegate`.
2. **Esa vía exige la firma del staker sobre el gasto** (`VerifySpendStakeTxStakerSig`, línea 593) — no basta con que la tx exista en Bitcoin: hay que demostrar autoría.
3. **Y en la misma transacción unbondea al padre** (`ms.btcUndelegate(ctx, btcDel, ...)`, línea 643). Padre e hijo **nunca coexisten como ACTIVE**, así que no hay peso duplicado.

Conclusión: el "phantom stake" fue un problema real y explotable *en su momento* (por eso el GHSA y el upgrade), pero en v4.7.0 el camino de activación obliga a canjear el padre por el hijo. Queda como deuda de diseño (un tercero puede *registrar* expansiones y dejar peso fantasma si el staker no firma), no como robo.

## 4. Módulo mint: la fuente primaria de valor, sin palanca para el atacante

`x/mint` acuña por tiempo transcurrido:

```go
portionOfYear := elapsed / NanosecondsPerYear
blockProvision := m.AnnualProvisions * portionOfYear
amountToMint := min(blockProvisionInt, MaxMintedPerBlock)   // 600e6 ubbn
```

- Ninguna entrada depende del usuario: `AnnualProvisions` sale de `InflationRate × StakingTokenSupply`, y `InflationRate` del calendario desde genesis.
- El `min(...)` con `MaxMintedPerBlock` acota un salto temporal grande.
- **Observación honesta:** si el tiempo de bloque pudiera adelantarse de forma sostenida, el cap de 600 ubbn/bloque se convertiría en el verdadero límite de emisión (≈3.17× la tasa actual, según el propio comentario del código). Pero (a) el consenso de CometBFT acota la desviación de tiempo, y (b) la dilución afectaría a todos por igual — no es transferencia a un atacante. No lo cuento como hallazgo.

## 5. Tokenfactory: sin autoridad de mint expuesta

- Este fork (`babylonlabs-io/tokenfactory v0.50.6-wasmvm2`) tiene params de sólo dos campos: `denom_creation_fee` (10 BBN) y `denom_creation_gas_consume`. **No existe `EnableSudoMint`**, que era la vía por la que un contrato podría acuñar.
- El módulo sí tiene `Minter`/`Burner`, pero ninguna ruta de mensaje de usuario permite acuñar: sólo crear denoms (pagando fee) y acuñar sobre denoms propios.

## 6. Slashing: 1% al burn, no un vector de robo

Params reales de mainnet:

```
slashing_rate    = 0.01
slashing_address = 1111111111111111111114oLvT2   (dirección de quema)
```

- El slashing quema el 1% a una dirección sin clave conocida ⇒ nadie lo cobra.
- Un tercero no puede forzar el slashing de una delegación ajena en su beneficio: `BuildSlashingTxWithWitness` exige la SK del FP (vía evidencia EOTS) o la del staker.
- Nota de calibración económica (no hallazgo): con 1% de penalización, el coste de equivocar es bajo *en BTC*, pero la extracción de la SK vía EOTS expone la clave del FP, que es la penalización real del diseño.

## 7. Superficies que revalidé y siguen cerradas

| Vector | Corte |
|---|---|
| `MsgSetWithdrawAddress` ajeno | signer = `delegator_address` en proto; el destino es propio |
| `MsgWithdrawReward` ajeno | signer = `address`; destino = `GetWithdrawAddr(address)` |
| Crear FP con dirección ajena | PoP firmada con la clave BTC + `CheckDuplicatedFpBbnAddr` |
| Declarar stake falso | salida exacta verificada en la tx BTC + rango min/max |
| Reusar hash de reembolso | `tmhash` del msg completo + borrado al primer uso |

## 8. Qué queda sin agotar (y por qué)

1. **Sin toolchain Go**: no compilé ni ejecuté nada. Todo el análisis es estático. Un bug de aritmética sutil (p. ej. un caso de redondeo concreto en una secuencia larga de periodos) sólo se cierra con tests de propiedad o fuzzing.
2. **Sin estado live**: no pude medir saldos reales del módulo costaking, ni el set de FPs, ni si hay duplicados de dirección con delegaciones activas. Los endpoints siguen devolviendo `000`.
3. **Fuzzing dirigido que haría falta**: (a) secuencias slash→delegate→unbond→epoch-boundary contra el invariante `Σ gauges ≤ Σ fondos`; (b) property test de `Σ portions ≤ 1` con truncamientos; (c) fuzzing de `MsgBtcStakeExpand` con expansiones anidadas (A→B→C) para buscar huecos de activación.

## 9. Conclusión

En todas las rutas donde el valor se mueve, **la cantidad que controla el atacante acaba contrastada contra una transacción real de Bitcoin, una firma del dueño legítimo, o el propio estado previo del atacante**. Los defectos que sí existen en el árbol live producen misdistribución entre partes que ya tenían el valor, o pérdida de liveness — no transferencia de valor ajeno.

El bug más cercano a "robo" que encontré en toda la auditoría (colisión de direcciones en la contabilidad de recompensas, §2 del documento anterior) está cerrado por `CheckDuplicatedFpBbnAddr` y por el soft-delete de los duplicados históricos.
