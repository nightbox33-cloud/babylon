# Descartes — candidatos evaluados contra el binario live (`0c1f1447` = v4.7.0)

Criterios: **C1** bug concreto y explotable · **C2** alcanzable en live · **C3** impacto real (valor/finality) · **C4** sin estado corrupto ni privilegios comprometidos.

| # | Candidato | C1 | C2 | C3 | C4 | Punto de corte |
|---|---|---|---|---|---|---|
| 1 | FP soft-deleted recibe stake/randomicidad y peso pero no puede votar | ✓ | ✓* | ✗ | ✓ | Liveness (halt). Ver `BUG_soft_deleted_fp.md`. *Requiere FP borrado con peso en estado. |
| 2 | `ActiveBaby ≤ -2` sobrevive a `Sanitize` (`Equal(-1)`) | ✗ | ✓ | ✗ | ✓ | El error de `Validate` aborta la tx (sin escritura parcial) o se absorbe con log en `AfterEpochEnds`. Peor caso: tracker desactualizado ⇒ misdistribución. |
| 3 | Stake expansion sin comparar `btc_pk` (#1882/#1883) | ✗ | ✓ | ✗ | ✓ | Exige `StakerAddr` del padre, mismo FP[0], firma con pk nueva y 6/9 covenants. Sin víctima. |
| 4 | `ExtractInjectedCheckpoint` con type-assertion sin comprobar | ✗ | ✓ | ✗ | ✓ | Panic dentro de `ProcessProposal`/`PrepareProposal`, ambos con `defer recover()` en sdk 0.53.8. |
| 5 | `wasmStack` nil en el router IBC (`keepers.go:651/714`, en v4.4–v4.7) | ✗ | ✗ | ✗ | ✓ | `NewIBCHandler` devuelve valor; `OnChanOpenInit` exige puerto `wasm.<hash>`; mainnet tiene **0 codes / 0 contracts**. |
| 6 | `MaxVoteExtensionSize` ausente (#1923) | ✗ | ✓ | ✗ | ✓ | DoS de propuesta; `ValidateVoteExtensions` devuelve error ⇒ rechazo. |
| 7 | `refreshFPCommissions` ausente (#1953) | ✗ | ✓ | ✗ | ✓ | Misdistribución entre FPs/delegadores; no crea valor. |
| 8 | Orden no determinista de la tabla VP (#1956) | ✗ | ✗ | ✗ | ✓ | Divergencia potencial entre nodos; no demostrada; no es robo. |
| 9 | `AfterRawCheckpointForgotten` corta en `i=0` | ✗ | ✓ | ✗ | ✓ | Sólo corre el primer hook; `removeCheckpointRecord` nunca se ejecuta ⇒ basura de estado en `monitor`. |
| 10 | `IsFinalityProviderDeleted` ausente en 3 sitios de main | ✗ | ✗ | ✗ | ✓ | Live sí valida en `finality/keeper/msg_server.go:90`. Sin secuencia de delegación a FP borrado que otorgue valor. |
| 11 | Migración btcstaking v2 / colisión `hex 0x10 == dec 16` (#1913) | ✗ | ✗ | ✗ | ✗ | Necesita colisión preexistente ⇒ estado corrupto. |
| 12 | `BeforeValidatorSlashed` no implementado (#1906) | ✗ | ✓ | ✗ | ✓ | Live restaura `OriginalTokens`/`OriginalShares` en epoch boundary; efecto = exactitud de `ActiveBaby` ⇒ score. |
| 13 | `BigEndianToUint64` con 1–7 bytes (sdk) | ✗ | ✗ | ✗ | ✓ | Todas las claves se escriben con `Uint64ToBigEndian` (8 bytes). |
| 14 | Panic en handlers ABCI ⇒ halt | ✗ | ✗ | ✗ | ✓ | `ProcessProposal` y `PrepareProposal` tienen `recover()`; `runTx` también. |
| 15 | Tokenfactory (mint por sudo) | ✗ | ✗ | ✗ | ✗ | El fork no tiene campo de mint por sudo; sólo `denom_creation_fee`. |
| 16 | `fundingInputValue <= 0` (#1855) | ✗ | ✓ | ✗ | ✓ | Chequeo de sanidad; no acuña ni libera UTXO ajeno. |
| 17 | `RefundTxDecorator(nil)` en la cadena ante | ✗ | ✓ | ✗ | ✓ | `AnteHandle` no toca `d.k`; el post handler real usa `&app.IncentiveKeeper` (`app.go:558`). |
| 18 | `PriorityDecorator` reserva prioridad alta para liveness | ✗ | ✓ | ✗ | ✓ | Sólo orden del mempool. |
| 19 | `NewSortedValidatorSet` con `BigEndianToUint64(Addr)` ⇒ panic | ✗ | ✗ | ✗ | ✓ | Panic sería halt real, pero un `Addr` corto no puede existir: el verificador exige 20 o 32 bytes (`app/params/config.go:74`). |
| 20 | Orden por últimos 8 bytes (20 vs 32 bytes) | ✗ | ✗ | ✗ | ✓ | `GetValidatorSet` y `binarySearch` usan el mismo criterio ⇒ coherentes en live. |
| 21 | Colisión de direcciones BBN en contabilidad de recompensas | ✗ | ✗ | ✗ | ✓ | El crédito va a la dirección compartida (misatribución, no tercero); `CheckDuplicatedFpBbnAddr` impide duplicar; los duplicados históricos están soft-deleted y no votan ⇒ no cobran. |
| 22 | Doble conteo de sats vía stake expansion ("phantom stake", GHSA-4rm2) | ✗ | ✓ | ✗ | ✓ | El patrón sigue siendo legal (unbond temprano antes del inclusion proof), pero activar el hijo exige `MsgBTCUndelegate` con firma del staker, que **unbondea al padre en la misma tx** ⇒ nunca coexisten como ACTIVE. |
| 23 | Inflar recompensas vía `DecimalRewards` / redondeo | ✗ | ✗ | ✗ | ✓ | Truncamiento siempre contra el receptor; `CoinsSafeMulInt` devuelve error en overflow; cobrar más exige más sats, y los sats se verifican contra la tx BTC. |
| 24 | Capturar fees del fee collector manipulando porciones | ✗ | ✗ | ✗ | ✓ | Porciones son params (gov); `GetCoinsPortion` trunca; orden `mint→incentive→costaking→distribution` correcto; suma 0.7435 < 1. |
| 25 | Inflación / mint manipulable | ✗ | ✗ | ✗ | ✓ | Ninguna entrada depende del usuario; `AnnualProvisions` sale del calendario y del supply. |

## Advisories ya publicados y presentes en v4.7.0 (no se reabren)

4rm2, 786p, 24xq, 692h, 2fcv, xq4h, 4rmq, 56j4, 7mm3, 869w.

## Ramas revisadas sin parche aplicable

| Rama | Veredicto |
|---|---|
| `fix/costaking-stale-expectations` (`bb785bb9`, `c0db15d0`) | sólo `test/replay/costaking_test.go`; expectativas de test |
| `fix/voting-power-assigning` | 2024, pre-v4 |
| `fix/epoch-num-missing-in-commit-query` | 2024, conversión de respuesta |
| `fix/external-events-format` | 2024, formato de eventos |
| `rafilx/dstr-int-overflow`, `Vvaradinov/enable-transfers-end-blocker` | 2024, no aplican |
| `reject-staking-msg-on-slashed-fps` | rechazo de msg; no altera valores |
| `fix/jailing-non-determinism` | 2024 |

## Nota sobre el GHSA-4rm2

La remediación (`RemediatePoisonedStakeExpansions`, `app/upgrades/v4_3/upgrade.go:71`) fue una **migración de una sola vez** sobre el estado existente: busca hijos stake-expansion sin inclusion proof con `DelegatorUnbondingInfo` fijado y fuerza el unbond del padre (idempotente, con contadores de "skipped"). **No cerró el patrón**: `msg_server.go:549` documenta que *"the stk exp can unbond early prior to having the inclusion proof"*. Lo que impide el doble conteo es el camino de activación, no la validación de creación.
