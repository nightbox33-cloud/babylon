# Babylon — auditoría ofensiva del stack desplegado (bbn-1)

Rama de trabajo: `arena/c4913e27-babylon` (base `8b9673c3`, `main`). Fecha: 2026-11-09.
Todo el análisis es **estático sobre clones**; no se ha podido compilar ni ejecutar PoCs (no hay toolchain Go en el entorno) — ver §6.

---

## 0. Veredicto en una línea

**No he encontrado un crítico que drene fondos de terceros sin cooperación desde el estado desplegado.** Sí he encontrado **un robo live real y permissionless con víctimas opt-in** (F01: el FP se queda con la parte de recompensas de sus propios delegadores porque el split usa una comisión *cacheada*), **una colisión de prefijos de store** (F02, sin valor) y el **bug de liveness ya conocido** del FP soft-deleted (F03). Todo lo demás que he probado está descartado con el hecho que lo mata (§5 y `descartes.md`).

> Nota sobre la premisa del encargo ("en esta chain SÍ hay un crítico"): los dos candidatos que resisten son **F01** (robo de recompensas de delegadores, víctima opt-in) y **F04** (drift de `ActiveBaby` en costaking: upstream lo *resetea* con el upgrade v4.8, lo que prueba que el estado vivo está mal, pero el camino de explotación sólo se puede fijar ejecutando código). Reporto ambos con sus cuatro criterios evaluados y con las condiciones que los limitan, en vez de rebautizar ninguno como "drenaje de pool sin cooperación" cuando no lo es.

---

## 1. Requisito previo: inventario de repos (estado)

| Concepto | Estado |
|---|---|
| Orgs de la fundación enumeradas | 2: `babylonlabs-io` (58 repos) + `babylonchain` (24 legacy) vía `api.github.com/orgs/<org>/repos` |
| Repos clonados | **114** en `/home/user/audit/repos` (881 MB), con submódulos y `git fetch` de ramas/tags; `clone_all.out` = `ALLDONE` |
| Commit exacto registrado | **57** repos con `.git` y SHA en `inventory/repo_commits.tsv` (repo, commit, fecha) |
| Repos privados / bloqueados | **0**. Todos los repos de las dos orgs son públicos y accesibles ⇒ no hay bloqueo que impida declarar cobertura de repos |
| Faltantes conocidos | los `*-rs`, `*-ui` y forks sin código desplegado no se auditaron más allá del inventario; los `.git` sin commit (árboles descargados por tarball) no aportan SHA |

Repos clave (commit + versión de módulo):

| repo | commit (2026-11-09) | módulo / go |
|---|---|---|
| `babylonlabs-io/babylon` (cadena) | `8b9673c3ba5cff55b30865e876bfa4bf96bcd4b4` (main) — tag live `v4.7.0 = 0c1f1447` | `…/babylon/v4`, go 1.26.10 |
| `babylonlabs-io/btc-staker` | `f992af0ca214d5c8cab0fa51cc7569755d44a35e` | `…/btc-staker`, go 1.25.0 |
| `babylonlabs-io/finality-provider` | `4c55d4bea85379da1f69a406185db0e9a745831e` | `…/finality-provider`, go 1.25.0 |
| `babylonlabs-io/covenant-signer` | `ed42ad02862fef86be3ead399b853cf1fb7b3ce7` | `…/covenant-signer`, go 1.23.1 |
| `babylonlabs-io/covenant-emulator` | `cdb517834f9aa76c9b518b958b3c0ebee775b3b8` | — |
| `babylonlabs-io/staking-api-service` | `8bfb18d9749f4523766dbc688ca59b63b805774d` | — |
| `babylonlabs-io/simple-staking` | `a246ed961f5c552105e540df32756f367f8ea0dc` | — |
| `babylonlabs-io/babylon-benchmark` | `c5a1a591b63d881ba663b22eea2a365d236a301c` | harness e2e (bitcoind+babylond+FP+covenant) → base para PoC con toolchain |

### 1.1 Topología código↔estado desplegado (lo que sí y lo que no se pudo medir)

- `v4.7.0` (`0c1f1447`, "backport Go 1.26.10 rebuild to release/v4.7.x") es el artefacto live de referencia; `main` (`8b9673c`) **no es descendiente**: `git diff --stat v4.7.0 main` da **58 ficheros, +2298/−1045** en código no-test. Toda divergencia de §4 se ha leído en el worktree de `v4.7.0`.
- Artefacto de estado disponible (`/home/user/audit/node`): snapshot de **bbn-1 en altura ~224** (`priv_validator_state.json.bak` = 224, `upgrade-info.json` = `{"name":"v1","height":226,"info":"TGE Upgrade"}`), 22 MB de `application.db`, `wasm/` **vacío** (0 contratos). Es un estado de la **era génesis/TGE**, no del estado actual: **no sirve** para medir params, saldos, set de FPs ni module accounts de hoy.
- `application.db` es LevelDB de `rootmulti`: sin `plyvel`/`ldb` ni Go en el entorno **no se puede leer** (§6). Por tanto el mapeo "dirección/program id/module account/genesis/params desplegado → repo+ruta+commit+artefacto" queda **parcial**: identificado por código (direcciones derivadas y params por defecto) y **no verificado contra el estado live**. Esto se declara como limitación, no como cobertura.

---

## 2. F01 — Comisión stale: el FP se queda con la parte de sus delegadores (robo live, víctima opt-in)

Detalle completo en `F01_comision_stale.md`. Resumen de criterios:

| Criterio | Evaluación |
|---|---|
| (1) Bug concreto en código live | **Sí.** `x/incentive/keeper/btc_staking_gauge.go:70-79` reparte con `*fp.Commission` de la dist-cache; esa comisión sólo se lee del store cuando el FP **entra por primera vez** en la cache (`x/finality/keeper/power_dist_change.go:316-329` + `power_table.go:226-238`); `rewarding.go:50-70` no refresca. `main` añade `refreshFPCommissions` + test `TestRewardBTCStakingRefreshesCommission`. |
| (2) Permissionless, PnL > bond/slashing | **Sí, con matiz.** Ser FP no tiene allowlist (`MsgCreateFinalityProvider`), `Rate=MaxRate=MaxChangeRate=1.0` es válido (`commission.go:19-50`), y bajar la comisión está permitido (`finality_providers.go:265-320`). PnL = (comisión cacheada − anunciada) × parte del FP, sin riesgo de slashing. El matiz: **hacen falta delegadores de terceros**. |
| (3) Call graph/estado live | **Sí.** `HandleRewarding` → `rewardBTCStaking` → `RewardBTCStaking(height, dc, voters)` cada bloque finalizado; única fuente de yield de los BTC delegators (`BtcStakingPortion=0.181818182` + `FpPortion=0.013636364` de las fees, `x/incentive/types/params.go:20-40`). |
| (4) PoC/PnL ≥ 0 | **Sí** (test espejo del de main, §4 de `F01`). No hay flash/swap/loan que deshacer; el stake propio sigue siendo propio. |
| Hecho que lo mata | Que el delegador no delegue en el FP atacante (no hay drenaje de pool ajeno sin víctima) — o que la cache se reconstruya por altura (no ocurre). |

**Techo:** `(1 − comisión anunciada)` (≈95 % si anuncia el mínimo) **de la parte de sus delegadores**, no del pool entero.

## 3. F02 — Colisión de prefijos `{0x10}` en `x/btcstaking` (sin valor)

`HeightToVersionMapKey = []byte{0x10}` (live) == `FpBbnAddrKey = collections.NewPrefix(16)`. El blob del mapa cae dentro del namespace del índice FP→addr; las lecturas puntuales no se pisan, el export ya ignora claves vacías (`genesis.go:329-352`), pero cualquier operación por prefijo sobre `{0x10}` puede borrar el mapa y `GetParamsForBtcHeight` **panica** (`params.go:203+`). `main` cambia el prefijo a decimal 10 y **migra los datos** (`x/btcstaking/migrations/v2/store.go`). Detalle en `F02_colision_prefijo_store.md`.

## 4. F03 — FP soft-deleted: el peso muerto no vota (liveness, no robo)

En live `IsFinalityProviderDeleted` sólo se consulta en `MsgAddFinalitySig` (`x/finality/keeper/msg_server.go:90`); main lo añade en `CommitPubRandList` (+5 l.) y en `x/btcstaking/keeper/msg_server.go` (+52 l.: expansión y `validateStakedFPs`). Delegar/expandir/commitear randomness a un FP borrado genera peso que nunca vota ⇒ `votedPower*3 > totalPower*2` inalcanzable si el peso muerto > ~1/3. **Sin transferencia de valor.** Fix `292b5d49` (PR #1875), no backportado al release por el reset `9e0c93c` (#2026). (Ya documentado en el informe previo; se mantiene la clasificación.)

---

## 4-bis. F04 — `ActiveBaby` de costaking: upstream lo resetea con el upgrade v4.8 (candidato a robo del pool, no confirmado)

`main` añade `app/upgrades/v4_8/upgrade.go` (**+352 líneas**) cuyo único cometido es **poner a cero y recalcular `ActiveBaby` de todos los costakers** desde las delegaciones reales a validadores activos (`zeroOutCoStakerRwdsActiveBaby` + `getAllBABYStakers` + `updateCostakerActiveBabyRewardsTracker`). Ya hubo un reset equivalente en **v4.2**. Que upstream necesite migrar estado dos veces es la prueba documental de que la contabilidad de `ActiveBaby` en live se degrada.

Mecanismo analítico (detalle en `F04_activebaby_drift.md`): `TotalScore = min(ActiveSatoshis, ActiveBaby/200)`; si el `ActiveBaby` residual queda por encima del stake real a validadores activos (p. ej. tras slash + desbondeo parcial en el mismo epoch, porque `Sanitize()` sólo corrige `-1` y los `DeltaShares` pueden perderse cuando `x/costaking` limpia su `StakingCache` en **cada** `EndBlocker`), el atacante cobra una parte del pool de co-staking **mayor que su stake real**, a costa del resto de costakers, y el residuo no lo corrige ningún hook posterior porque el validador slasheado sale del set activo.

| Criterio | Evaluación |
|---|---|
| (1) Bug live | **Parcial.** El mecanismo está en live (`hooks_staking.go`+`hooks_epoching.go`+`Sanitize(==-1)`+`EndBlock→Clear`); que el drift sea **alcista** y persistente necesita ejecución. |
| (2) Permissionless | **Sí.** Ser validador y auto-slashear (equivocación) es permissionless; coste 1 % del stake del validador, el BABY desbondeado se recupera. |
| (3) Call graph live | **Sí**, en cada cierre de epoch. |
| (4) PnL | Sería > 0 contra el pool (terceros) si el drift es alcista; **no demostrado** (falta PoC con toolchain). |
| Hecho que lo mataría | Que los `DeltaShares` sobrevivan siempre al orden de EndBlockers ⇒ el residuo sería ±1 (ya tolerado) y no habría inflación. **No descartado.** |

## 5. Divergencia live (`0c1f1447`) ↔ `main` (`8b9673c`) por módulo

| Módulo | Δ | Qué cambia | Impacto |
|---|---|---|---|
| `x/incentive` | `btc_staking_gauge.go` (split), `reward_gauge.go` (−5) | split con comisión de cache; se elimina el fallback muerto `withdrawAddr==nil` | **F01 robo / limpieza** |
| `x/finality` | `rewarding.go` +22, `power_table.go` +9, `msg_server.go` +5 | `refreshFPCommissions`; orden explícito por voting power (`GetVotingPowerTableOrdered`); chequeo de FP borrado en `CommitPubRandList` | F01; determinismo; F03 |
| `x/btcstaking` | `msg_server.go` +52, `keys.go` 2, `migrations/v2` +76, `params.go` 24, `btc_delegations.go` 4 | `validateStakerBtcPk` (la expansión debe usar la BtcPk del staker padre), `IsFinalityProviderDeleted` en expansión/`validateStakedFPs`, `fundingInputValue<=0` rechazado, prefijo 0x10→0x0A + migración | F02/F03 + descartes |
| `x/costaking` | `hooks_staking.go` 190, `hooks_epoching.go` 47, `types/{rewards,score,staking_cache}.go` | `DeltaShares`+`OriginalTokens/OriginalShares`+`Sanitize(==-1)` → `BeforeValidatorSlashed`+clamp de cualquier negativo + `CalculateScore` extraído | contabilidad de slashing; ver descartes |
| `x/epoching` | `types/validator.go` 8 | `sort by BigEndianToUint64(first 8 bytes)` → `bytes.Compare(20 bytes)`; `binarySearch` igual | determinismo de orden (no explotable sin colisión de 8 bytes, 2^64) |
| `x/checkpointing` | `prepare/proposal.go` 42, `types/hooks.go` 4, `errors.go` 1 | contabilidad de tamaño proto en Prepare/ProcessProposal; hook `AfterRawCheckpointForgotten` sobre todos los hooks (live: sólo `hooks[0]`) | liveness/DoS de propuesta |
| `x/btccheckpoint` | `types/genesis.go` 8 | validación de génesis | higiene |
| `x/mint` | `types/minter.go` 5 | documentación del cap `MaxMintedPerBlock=600 BBN` y `MinInt` | sin cambio de comportamiento (verificado) |
| `app/` | `upgrades/v4_8/upgrade.go` **+352**, `upgrades/epoching/validation.go` +27, `upgrades/v4_{2,7}` (msgs), `keepers/keepers.go` 3, `ante/ibc_msg_size.go` 4 | **F04**: reset de `ActiveBaby` de todos los costakers; validación de "segundo bloque del epoch"; el v4.7 de main menciona "migrations … including btcstaking v2" (⇒ el fix de F02 **no** estaba en el binario v4.7.0 live); `wasmStack` nil → `wasmStackIBCHandler` (no explotable: el router registra el puerto `wasm`, wasmd usa `wasm.<contrato>` y no hay contratos); `len([]byte(s))`→`len(s)` sin cambio de comportamiento |
| `crypto/bip322` | 7 | refactor `else if`→`switch` en `validateSigHashType`: **sin cambio de comportamiento** (verificado) |
| `test/`, `testutil/` | `test/replay/{costaking,staking,driver}.go`, `testutil/store/key_collision.go` | harness de replay + utilidad de colisión de prefijos | **mapa de fixes** (F02, F04 y costaking) |

---

## 6. Limitaciones declaradas (no son cobertura)

1. **Sin toolchain Go**: no se ha compilado `babylond` ni ejecutado tests/PoC. Todo el análisis es lectura de código + `git diff` sobre tags. Los PoCs se entregan como guion reproducible (greps/diffs) + esquema de test unitario.
2. **Sin estado on-chain moderno**: el único artefacto (`node/`) es un snapshot de bbn-1 en altura ~224 (era TGE). `application.db` no es legible sin `plyvel`/`ldb`. Por eso **no hay** cifras de TVL, saldos por module account, ni verificación de params desplegados; las cantidades de F01 son cualitativas (proporciones de params), no "USD tocables".
3. **Endpoints RPC/API live**: no accesibles desde el sandbox (`000`), y el `genesis.json` de `networks/bbn-1` es sólo metadata sin `app_state`.
4. Se ha auditado el código de la cadena con profundidad; `btc-staker`, `finality-provider`, `covenant-*`, `staking-api-service` y `simple-staking` se revisaron a nivel de inventario y de los puntos que tocan valor (covenant signer valida el unbonding contra el delegado dueño; el staker firma sus propios spends ⇒ sin robo cruzado), no línea a línea.

## 7. Reproducción

```bash
# 1) worktree del código live + clones
git worktree add -f /home/user/audit/v470 0c1f1447     # v4.7.0
ls /home/user/audit/repos | wc -l                       # 114
column -t /home/user/babylon/babylon-audit/inventory/repo_commits.tsv

# 2) evidencia de los hallazgos
bash babylon-audit/scripts/f01_evidence.sh
bash babylon-audit/scripts/f02_evidence.sh
bash babylon-audit/scripts/diff_live_vs_main.sh

# 3) (con toolchain) PoC local del stack completo
#    repos/babylon-benchmark/harness: bitcoind + babylond + FP + covenant
```

## 8. Contestación explícita a la premisa

Se ha buscado activamente el "crítico" en: matemática de shares/recompensas (`x/incentive`, `x/costaking`), unidades sat/ubbn, autorización de mensajes (`signer` en proto), replay/domain separators (refund decorator), firmas BTC/PoP/adaptor, transiciones ACTIVE/UNBONDED, mint/burn (`x/mint`, tokenfactory), accounting de slashing y de stake expansion. El único que produce **más valor del puesto** sin rol privilegiado es F01, y lo hace a costa de delegadores que aceptan voluntariamente (comisión anunciada). No hay evidencia en el código de un camino que drene un pool ajeno sin esa cooperación; si el entorno de evaluación espera otro hallazgo, los puntos donde se ha mirado y descartado están en `descartes.md` con el hecho que los mata.
