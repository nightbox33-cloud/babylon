# Auditoría de seguridad — Babylon mainnet (`bbn-1`, `babylond v4.7.0`)

**Fecha:** 2026-11-07
**Código auditado (live):** `0c1f1447` = tag `v4.7.0` = `release/v4.7.x` (2026-11-02)
**Referencia:** `main` = `8b9673c` (2026-11-02)
**Método:** análisis estático del árbol live + diff dirigido + historial de PRs/commits vía API. **Sin toolchain Go** en el entorno: no hubo compilación ni PoC.

---

## 1. Resultado

**No se encontró un bug crítico de robo de valor.** Sí se encontró **un bug real de liveness** (§4) y varias debilidades de higiene.

| Categoría | Resultado |
|---|---|
| Robo / drenaje de valor | **No encontrado** (ver `ROBO_veredicto.md`) |
| Bypass de safety/finality con robo | **No encontrado** |
| Bug real en código live (liveness) | **Sí** — FP soft-deleted gana peso y no puede votar (`BUG_soft_deleted_fp.md`) |
| Debilidades no explotables | 4 documentadas (§6) |

---

## 2. Topología del código

Lo desplegado **no** es un ancestro de `main`: son linajes divergentes.

| Comparación | Resultado |
|---|---|
| `v4.7.0...main` | diverged — 114 / 71 |
| `v4.3.1...v4.7.0` | diverged — 37 / 17 |
| `v4.6.0...v4.7.0` | ahead 2 — sólo rebuild Go 1.26.10 |

| Tag | Commit | Fecha |
|---|---|---|
| v4.7.0 | `0c1f1447` | 2026-11-02 |
| v4.6.0 | `b56abc97` | 2026-10-22 |
| v4.5.0 | `f9006e42` | 2026-09-29 |
| v4.4.0 | `132d0502` | 2026-08-06 |
| v4.3.1 | `a93eadc9` | 2026-07-21 |

**Hecho pivotal — `9e0c93c` (#2026, 2026-08-05, 106 ficheros):** la línea v4.4.x fue **rebasada al árbol de v4.3.x**. Por tanto v4.5–v4.7 = v4.3.x + GHSAs + rebuilds. Eliminó deliberadamente: `app/upgrades/v4_4`, el rework de costaking (#1906), el fix de colisión de claves (#1913), `MaxVoteExtensionSize` (#1923), orden de FPs y `refreshFPCommissions` (#1953/#1956), y los e2e de wasm-ibc.

⇒ Que un fix esté en `main` y falte en live **no es un bug**: ese código nunca llegó a release, o se revirtió a propósito.

Dependencias: cosmos-sdk `v0.53.8`, cometbft `v0.38.23`, ibc-go `v10.5.0`, wasmd `v0.60.9`, tokenfactory `v0.50.6-wasmvm2` (fork de babylonlabs-io).

---

## 3. Fixes ausentes en live (con PR/commit)

| Fix | PR | Merge commit | Fecha | ¿Bug? |
|---|---|---|---|---|
| `BeforeValidatorSlashed` / costaking bond-slash-bond-unbond | #1906 | `44dd6fc1` | 2026-01-08 | No — contabilidad de `ActiveBaby` |
| Migración btcstaking v2, colisión de claves | #1913 | `438312a5` | 2026-01-07 | No — requiere estado corrupto |
| `MaxVoteExtensionSize` | #1923 | `dead25d5` | 2026-02-26 | No — DoS de propuesta |
| Igualdad de `btc_pk` en stake expansion | #1882 | `92bcea06` | 2025-11-28 | No — sin víctima |
| `validateStakerBtcPk` | #1883 | `e4f1317c` | 2025-12-08 | No |
| `fundingInputValue <= 0` | #1855 | `6409d4a4` | 2026-02-04 | No |
| `refreshFPCommissions` | #1953 | `c1c2abe1` | 2026-02-19 | No — misdistribución |
| Orden de FPs por VP | #1956 | `992d7e74` | 2026-02-19 | No — determinismo |
| `wasmStack` nil en router IBC | #1981 | `f0e9b723` | 2026-03-25 | No — inalcanzable (0 contratos) |
| Type-assertion comprobada en checkpoint | — | `51a52a52` | 2026-01-03 | No — `recover()` en ABCI |
| **FP soft-deleted recibe stake/randomness** | **#1875** | **`292b5d49`** | **2025-11-25** | **Sí — liveness (§4)** |

---

## 4. Bug real en código live: FP soft-deleted gana peso y no puede votar

Detalle completo en `BUG_soft_deleted_fp.md`.

En `0c1f1447` la marca `IsFinalityProviderDeleted` **sólo** se consulta al rechazar `MsgAddFinalitySig` (`x/finality/keeper/msg_server.go:90`). No se consulta en:

- `validateStakedFPs` ⇒ se acepta delegar a un FP borrado
- `BtcStakeExpand` ⇒ se acepta expansión
- `CommitPubRandList` ⇒ se acepta randomness (sólo mira `HasFinalityProvider`)
- power distribution ⇒ le da slot activo (el flag vive en el store prefijo 17, no en el protobuf)

Resultado: peso muerto en la tabla. `tally` lo suma en `totalPower` pero nunca en `votedPower`:

```go
return votedPower*3 > totalPower*2
```

Si el peso muerto supera ~1/3, ningún bloque finaliza nunca.

Vector barato: **no hace falta ser el FP borrado**. Cualquiera con BTC puede delegar y commitear randomness en su nombre; `MsgCommitPubRandList` sólo verifica la firma contra la clave del FP.

**Clasificación honesta:** liveness/safety de la finality, **no robo**. Precondición no verificada: que exista un FP soft-deleted con peso relevante en `bbn-1`.

---

## 5. Búsqueda de robo: cierre

Detalle en `ROBO_veredicto.md`. Resumen de los cortes:

| Hipótesis | Corte |
|---|---|
| Inflar stake declarado | salida exacta verificada en la tx BTC + rango min/max |
| Inflar `ActiveBaby` | `Min(ActiveSatoshis, ActiveBaby/ratio)` exige más BTC también |
| Reusar hash de reembolso | `tmhash` del msg completo, borrado al primer uso |
| `MsgWithdrawReward` ajeno | signer = `address` en proto |
| `MsgSetWithdrawAddress` ajeno | signer = `delegator_address` |
| FP con dirección ajena | PoP con la clave BTC + `CheckDuplicatedFpBbnAddr` |
| Doble conteo stake expansion | activar el hijo exige firma del staker **y unbondea al padre** |
| Porciones de fee | `GetCoinsPortion` trunca; suma = 0.743477 < 1; orden correcto |
| Mint | ninguna entrada depende del usuario |
| Tokenfactory | params sin campo de mint por sudo |
| Slashing | 1% a dirección de quema; no lo cobra nadie |

---

## 6. Debilidades reales (no explotables)

1. **Costaking: acredita el gauge antes de mover fondos** (`CalculateCostakerRewardsAndSendToGauge`). Si el módulo no tuviera saldo → rollback, usuario bloqueado; nunca cobra de más.
2. **`BtcUndelegate` es `export`** y salta toda la validación de `MsgBTCUndelegate` ("intended ONLY for upgrades"). Hoy sin caller de mensaje; si se conecta, es crítico.
3. **`MultiCheckpointingHooks.AfterRawCheckpointForgotten` corta en `i=0`** ⇒ sólo corre el primer hook; `removeCheckpointRecord` nunca se ejecuta (basura de estado en `monitor`).
4. **Dos `panic()` en `calculateDelegationRewardsBetween`** alcanzables desde hooks ABCI ⇒ halt, no robo.

---

## 7. Limitaciones

- **Sin toolchain Go**: nada compilado, sin tests ni PoC. Todo es estático.
- **Sin estado live**: endpoints RPC/API devuelven `000`. No se midieron saldos ni el set de FPs. El genesis de `networks/bbn-1` es sólo metadata (13 KB) sin `app_state`.
- **`/home/user` y `/tmp` se borraron durante la sesión** (3 veces). Esta versión se reconstruyó y se versiona en git para que sobreviva.
- Clone shallow: `git log -L`/`-S` no datan bien; el historial se reconstruyó vía API.

**Recrear el entorno:**
```bash
git fetch --depth 1 origin 0c1f144711e138b558f579a4af27ec728f487636
git worktree add -f /tmp/v470 0c1f1447
bash babylon-audit/scripts/static_evidence.sh
```

---

## 8. Recomendaciones

1. **Backportar #1875** (`292b5d49`) a la línea de release: es el único bug con cadena de explotación completa.
2. Portar los fixes de corrección contable (#1953, #1956, #1923, #1913) si se quiere paridad con `main`.
3. Restaurar el bucle completo en `AfterRawCheckpointForgotten`.
4. Eliminar el `wasmStack` nil del router IBC (#1981).
5. Invertir el orden en `CalculateCostakerRewardsAndSendToGauge` (fondos primero, gauge después).
6. Fijar un nodo de referencia para poder verificar hipótesis contra estado real.

---

### Anexo — artefactos (en `babylon-audit/`)

| Archivo | Contenido |
|---|---|
| `findings/INFORME_FINAL.md` | Este documento |
| `findings/BUG_soft_deleted_fp.md` | El bug de liveness, con cadena de explotación |
| `findings/ROBO_veredicto.md` | Cierre exhaustivo de la búsqueda de robo |
| `findings/descartes.md` | 19 candidatos con el criterio exacto que falla cada uno |
| `findings/divergencia_main_vs_live.md` | Topología, tags, tabla de fixes |
| `evidence/static_evidence.txt` | 273 líneas de evidencia (E1–E19) |
| `scripts/static_evidence.sh` | Script reproducible |
