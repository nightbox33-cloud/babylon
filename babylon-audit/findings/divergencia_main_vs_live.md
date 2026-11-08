# Divergencia `main` vs live (v4.7.0)

- **live** = `0c1f1447` = tag `v4.7.0` = `release/v4.7.x`
- **main** = `8b9673c` (2026-11-02)

## Relación entre linajes

```
compare v4.7.0...main      -> diverged, 114 commits en main / 71 en v4.7.0
compare v4.3.1...v4.7.0    -> diverged, 37 / 17
compare v4.6.0...v4.7.0    -> ahead 2  (sólo rebuild Go 1.26.10: 19f6e9c6, 0c1f1447)
```

No hay relación de ancestro: lo desplegado **no** es "main menos unos commits".

## Tags

| Tag | Commit | Fecha |
|---|---|---|
| v4.7.0 | `0c1f144711e138b558f579a4af27ec728f487636` | 2026-11-02 |
| v4.6.0 | `b56abc97` | 2026-10-22 |
| v4.5.0 | `f9006e42` | 2026-09-29 |
| v4.4.0 | `132d0502` | 2026-08-06 |
| v4.3.1 | `a93eadc9` | 2026-07-21 |

## Commit pivotal: `9e0c93c` (#2026)

"chore: reset release/v4.4.x to release/v4.3.x" — 2026-08-05, 106 ficheros.
Reescribe el árbol de release v4.4.x al de v4.3.x ⇒ **v4.5/v4.6/v4.7 = v4.3.x + GHSAs + rebuilds de Go**.

Eliminado del árbol de release (lista explícita del commit):

- `app/upgrades/v4_4` (handler de upgrade)
- rework de costaking / slashing (#1906)
- fix de colisión de claves (`x/btcstaking/types/keys.go` + `keys_test.go` de 10 módulos + `testutil/store/key_collision.go`) (#1913)
- límite `MaxVoteExtensionSize` (#1923)
- orden de FPs por voting power + `refreshFPCommissions` (#1956, #1953)
- e2e de wasm-ibc

⇒ "falta un fix" **no** implica bug: varios de estos nunca llegaron a release o se revirtieron a propósito.

## Fixes ausentes en live (con PR/commit)

| Fix | PR | Merge commit | Fecha |
|---|---|---|---|
| `BeforeValidatorSlashed` / costaking | #1906 | `44dd6fc1` | 2026-01-08 |
| Migración btcstaking v2, colisión de claves | #1913 | `438312a5` | 2026-01-07 |
| `MaxVoteExtensionSize` | #1923 | `dead25d5` | 2026-02-26 |
| Igualdad de `btc_pk` en stake expansion | #1882 | `92bcea06` | 2025-11-28 |
| `validateStakerBtcPk` | #1883 | `e4f1317c` | 2025-12-08 |
| `fundingInputValue <= 0` | #1855 | `6409d4a4` | 2026-02-04 |
| `refreshFPCommissions` | #1953 | `c1c2abe1` | 2026-02-19 |
| Orden de FPs por VP | #1956 | `992d7e74` | 2026-02-19 |
| `wasmStack` nil en router IBC | #1981 | `f0e9b723` | 2026-03-25 |
| Type-assertion comprobada en checkpoint | — | `51a52a52` | 2026-01-03 |
| **FP soft-deleted recibe stake/randomness** | **#1875** | **`292b5d49`** | **2025-11-25** |
| Hook `AfterRawCheckpointForgotten` completo | #1908 | `c5e5a5b3` | 2026-01-05 |
| Comparar bytes completos de addr de validador | #1902 | `74a4db83` | 2025-12-11 |

## Diff superficial `0c1f1447..8b9673c`

58 ficheros `.go` no-test (21 fuera de `e2e`/`testutil`). Claves:

| Fichero | Cambio |
|---|---|
| `app/keepers/keepers.go` | main usa `wasmStackIBCHandler`; live deja `var wasmStack` nil con `AddRoute` (#1981) |
| `x/checkpointing/types/hooks.go` | live corta en `i=0`; main itera |
| `x/checkpointing/prepare/proposal.go` | main añade re-marshal + igualdad |
| `x/checkpointing/types/types.go` | main añade `MaxVoteExtensionSize = 1024` |
| `x/epoching/types/validator.go` | main usa `bytes.Compare` |
| `x/costaking/types/rewards.go` | `Sanitize`: live `Equal(-1)` vs main `IsNegative()` |
| `x/costaking/types/{score,staking_cache}.go` | rework costaking |
| `app/upgrades/epoching/validation.go` | main añade `ValidateSecondBlockOfEpoch` |
| `x/mint/types/minter.go` | **sólo comentario** |

## Presente en live y distinto en main

- `withdrawAddr = addr` fallback en `x/incentive/keeper/reward_gauge.go` (sólo live).
- `removeBabyForDelegators` restaura `OriginalTokens`/`OriginalShares` (live).

## Releases

`v4.6.0...v4.7.0` = **ahead 2**, ambos rebuilds con Go 1.26.10 ⇒ entre v4.6.0 y v4.7.0 **no hay cambio funcional**.
