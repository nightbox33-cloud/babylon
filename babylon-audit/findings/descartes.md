# Descartes (con el hecho que mata cada hipótesis)

Todo verificado sobre `v4.7.0 = 0c1f1447` (worktree `/home/user/audit/v470`), salvo donde se indique `main = 8b9673c3`.

## A. Stablecoin/pool/tesorería/exchange-style (lo que el encargo pedía)

| Hipótesis | Hecho que la mata |
|---|---|
| Drenar pool/escrow/vault de terceros | **No existen** en el árbol: no hay contratos wasm desplegados (`node/wasm` vacío, `contracts: []`), no hay módulo de vault/escrow/pool; el único valor custodiado son module accounts de params/gov (privilegiados) y los depósitos BTC (self-custodial, fuera de la cadena). |
| Robar stake BTC de un tercero | Cada salida BTC está atada a script/timelock/valor exactos del delegado (`validateStakingTx`, `CheckSlashingTxMatchFundingTx`, `VerifySpendStakeTxStakerSig`); unbonding/slashing exigen la firma del staker dueño + quórum de covenants. Sin la clave del staker no hay movimiento. |
| Stake expansion con la BtcPk de otro (live no valida en `BtcStakeExpand`) | El script de la salida BTC del hijo se reconstruye desde las pk **del mensaje**: el hijo queda atado a la clave del atacante y el padre sólo se desbondea; **no apropia valor ajeno** (el stake nuevo es del atacante, el viejo lo recupera la víctima con su propia firma). Fix en main = `validateStakerBtcPk` (correctitud de identidad, no robo). |
| `fundingInputValue ≤ 0` sin guarda en `validateStakeExpansionAmt` (live) | Con funding ≤ 0, la identidad `totalInputValue = oldStakingAmt + fundingInput` y `impliedFee = totalInputValue − Σoutputs > 0` mantiene la cota: **no se puede declarar más stake que el bitcoin realmente comprometido**. Main añade el error; sin impacto de valor. |
| Undelegation sin k-depth (`inclusion_proof.go`) | Es *intent-based* por diseño: sólo prueba de inclusión Merkle, sin profundidad. No concede poder de voto, sólo **revoca** ⇒ no crea valor. |
| Replay del refund (`MsgInsertHeaders` reorgueado) | El índice del mensaje se **borra al procesarse** (`DeleteRefundableMsgIndex`); el reorg debe superar el cumulative work del tip + `CheckBlockHeaderSanity`; y todo mensaje de la tx debe estar en el índice y haber costado su propio fee (`FeeGranter` nulo o igual al pagador, bloqueado en ante). |
| Refund pagado a un tercero (fee granter) | Ante-handler rechaza `FeeGranter != FeePayer` para txs refundables. |
| `MsgWithdrawReward` a la dirección de otro | `GetWithdrawAddr` devuelve la propia addr del stakeholder si no hay entrada (nunca `nil`); el signer del mensaje es esa addr (proto); sólo retira sus propios gauges (`BTC_STAKER`+`COSTAKER` de la misma addr). El fallback `if withdrawAddr == nil` de live es **código muerto** (main lo borra). |
| Inflar el stake declarado de una delegación | `TotalSat` ligado a la salida exacta de la tx BTC (script, timelock, valor) en `ValidateParsedMessageAgainstTheParams`; `MinStakingValueSat`/`MaxStakingValueSat` por params versionados. |
| Votar con peso de un FP sin delegaciones | `AfiliatedDelegations`/`TotalBondedSat` se derivan de delegaciones ACTIVE con quórum de covenants + inclusion proof; los tres únicos puntos live que producen `ACTIVE` están identificados (`btc_delegations.go:235/245`, `inclusion_proof.go:180/190`) y todos exigen prueba (o unbonding intent-based, que no da poder). |
| Manipular el oráculo/precio | No hay oráculo de precio en la cadena; el ratio BTC/BABY de costaking es un **param** (`ScoreRatioBtcByBaby`) y los caps (`min(ActiveSatoshis, ActiveBaby/ratio)`) están en `costaking/types/score.go`. |
| Mint libre (inflación) | `x/mint` no toma input de usuario: `AnnualProvisions = inflation × totalSupply`, `CalculateBlockProvision` por tiempo, cap `MaxMintedPerBlock = 600 BBN` (comentado y verificado); tokenfactory no tiene `sudo mint` habilitado en `wasmbinding` (sólo queries). |
| Fee splits con redondeo a favor del usuario | `GetCoinsPortion` trunca a favor del módulo; la porción de validadores (`1 − 0.181818182 − 0.013636364`) queda en el fee collector. |

## B. Recompensas / shares (x/incentive, x/costaking)

| Hipótesis | Hecho que la mata |
|---|---|
| Delegación nueva "snipea" recompensas pasadas | `btcDelegationModifiedWithPreInitDel`: `IncrementFinalityProviderPeriod` (settle) → pagar al gauge → **después** `addDelegationSat` → `initializeBTCDelegation` (StartPeriod = periodo terminado). El nuevo peso nunca entra en el denominador de periodos anteriores. |
| Acumular recompensas sin tope (rate inflado) | `rps = CurrentRewards × 1e20 / TotalActiveSat` truncado; `rewards = Δrps × sats / 1e20` truncado ⇒ Σ claims ≤ depósito. `addDelegationSat`/`subDelegationSat` mueven delegación y FP **juntos**, con guardas de no-negatividad a ambos lados. |
| Retirar dos veces el mismo gauge | `withdrawReward`/`SetFullyWithdrawn` + `GetFinalityProviderHistoricalRewards` por periodo; el gauge queda a cero (`incentive.go`). |
| Inundar el gauge con denoms falsos | Los coins vienen de `GetCoinsPortion` sobre los balances del fee collector/módulo. |
| Comisión > 100 % | `CommissionRates.Validate` exige `MaxRate ≤ 1`, `Rate ≤ MaxRate`; `UpdateFinalityProviderCommission` exige `new ≤ MaxRate`, `|Δ| ≤ MaxChangeRate`, ≥ `MinCommissionRate`, 24 h. |
| Costaking: slashing de validador acredita de más (live `DeltaShares` + `OriginalTokens/OriginalShares`) | La corrección sólo reajusta el `ActiveBaby` del **propio** delgador del validador slasheado; `ActiveBaby` sólo entra en `min(ActiveSatoshis, ActiveBaby/ratio)` ⇒ no puede superar el peso del propio BTC del atacante. Residual: `Sanitize()` live sólo corrige `ActiveBaby == -1` (main: cualquier negativo) ⇒ si sobrevive un negativo distinto, `Validate()` falla ⇒ error de hook ⇒ reverts/halt (**liveness**, no robo). |
| Costaking: doble conteo de `ActiveBaby` en transición de epoch | `AfterEpochEnds` compara set previo (cacheado en `BeforeEpochEnds`) con `IterateLastValidatorPowers` y **sólo** añade/quita en transiciones; `removeBabyForDelegators` restaura `OriginalTokens/Shares` si el validador fue slasheado. No he podido construir un camino con doble-add sin una salida a mitad de epoch en la que el set quede stale; ambos caminos degeneran en halt, no en robo. |
| Costaking: truncado del periodo | `currentRewardsPerScore = Rewards.QuoInt(TotalScore)` descarta el resto **a favor del módulo** (queda sin reclamar), nunca a favor del costaker. |
| `CalculateCostakerRewardsAndSendToGauge` con orden invertido | Debilidad de higiene (settle/init): no permite reclamar más de lo depositado por el mismo mecanismo del punto anterior. |

## C. Finality / checkpointing / epoching / light client

| Hipótesis | Hecho que la mata |
|---|---|
| Finalizar checkpoints falsos sin quórum | `MsgAddFinalitySig` verifica comisión de pub rand, firma BLS sobre el app hash, y el cómputo `votedPower*3 > totalPower*2` con el `VotingPowerDistCache` de la altura; los votos fuera del set se rechazan. |
| Doble voto / equivocación | `FinalitySig` única por (FP, altura) en store; evidencia de equivocación ⇒ slashing 1 % a `1111111111111111111114oLvT2` (`slashing_rate = 0.01`). |
| Vote extension malformada (live sin `MaxVoteExtensionSize=1024` ni re-marshal-equality) | `ExtractInjectedCheckpoint` con type assert sin `ok` ⇒ **DoS** de propuesta (liveness), no robo. Main añade el límite. |
| `MultiCheckpointingHooks.AfterRawCheckpointForgotten` sólo `hooks[0]` (live) | Omisión de notificación a hooks secundarios ⇒ estado derivado no actualizado (liveness/consistencia), sin valor. |
| Orden no determinista en `NewSortedValidatorSet` (live: sólo primeros 8 bytes de la addr) | Requiere colisión de prefijo de 8 bytes (2^64) para desviar; y el efecto sería un lookup erróneo en epoching, no una transferencia de valor. Main usa `bytes.Compare` completo. |
| Panic ⇒ halt (params/height→version map ausente, `calculateDelegationRewardsBetween`) | **Liveness** explícitamente excluido del encargo. |
| `wasmStack` nil en el router IBC (#1981) | Inalcanzable: no hay contratos wasm en el estado y el stack nil sólo se toca con canales wasm. |
| Robar en el covenant signer | El signer sólo co-firma unbondings del **propio** staking output del solicitante, y el camino de gasto exige además la firma del staker ⇒ sin clave ajena no hay gasto. |
| Front-running/MEV de unbonding | MEV sin robo de inventario: excluido. |

## D. Mapa de tests nuevos de main usados como lista de ataques

`TestHookStakingSlashedValidator_{PostSlashDelegationUnbond,PreSlashDelegationUnbond,MixedPreAndPostSlashUnbond,MultipleDeltaShares,OnlyPostSlashDelegationExists}`, `TestCreateBTCDelegation_DeletedFinalityProvider`, `TestBtcStakeExpansionInvalidFundingValue` (zero/negative), caso "expand delegation with different delegator btc pk", `TestGetVotingPowerTableOrdered_SortsByVotingPower`, `TestRewardBTCStakingRefreshesCommission`, `testutil/store/key_collision.go`, `test/replay/costaking.go`. **Todos** corresponden a fixes de F01/F02/F03 o a contabilidad sin robo (tablas B y C).
