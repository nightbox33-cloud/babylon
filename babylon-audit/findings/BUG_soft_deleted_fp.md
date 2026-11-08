# Bug en código: FP soft-deleted recibe stake y votos imposibles (live v4.7.0)

**Mecanismo:** `x/btcstaking` / `x/finality`
**Estado en live (`0c1f1447` = v4.7.0):** presente
**Corregido en:** `main`, commit `292b5d49` (PR #1875, 2025-11-25) — nunca backportado a release (reset `9e0c93c` / #2026)
**Reportado upstream como:** liveness contra `pm/issues/488`

> Clasificación honesta: bug real y explotable **en el código**, pero de impacto **liveness/safety**, no robo.

---

## 1. La marca y quién puede ponerla

`x/btcstaking/keeper/finality_providers.go:132`:

```go
// IsFinalityProviderDeleted returns if the finality provider is soft-deleted or not. The state of soft-deleted
// finality provider currently is only being used to avoid votes of undesired fps.
func (k Keeper) IsFinalityProviderDeleted(ctx context.Context, fpBtcPk *bbn.BIP340PubKey) bool
```

El propio comentario delimita el alcance: *"only being used to avoid votes"*.

Escritores (sólo dos, ninguno es un msg de usuario):

| Ruta | Quién |
|---|---|
| `app/upgrades/delete_dup_fp.go:127` | handler de upgrade |
| `x/btcstaking/keeper/genesis.go:89` | genesis (`DeletedFpsBtcPkHex`) |

## 2. Las rutas que no comprueban la marca

`git grep IsFinalityProviderDeleted` sobre `0c1f1447` devuelve **una sola** comprobación en lógica de mensajes: `x/finality/keeper/msg_server.go:90`. Faltan:

1. **`validateStakedFPs`** (`btc_delegations.go`) — sólo mira existencia y `IsSlashed()`:
   ```go
   fp, err := k.GetFinalityProvider(ctx, fpBTCPK)
   if err != nil { return types.ErrFpNotFound... }
   if fp.IsSlashed() { return types.ErrFpAlreadySlashed... }
   ```
2. **`BtcStakeExpand`** — misma validación, misma omisión.
3. **`CommitPubRandList`** — comprueba `HasFinalityProvider` y la firma, no la marca.
4. **Power distribution** — ni `x/btcstaking/keeper/power_dist_change.go` ni `x/finality/keeper/power_dist_change.go` la referencian; `FinalityProvider` **no tiene campo `deleted`** en el protobuf (el flag vive en el store `FinalityProvidersDeleted`, prefijo 17).

## 3. Cadena de explotación

1. Existe un FP marcado soft-deleted, con delegaciones activas.
2. Cualquiera puede delegarle (`MsgCreateBTCDelegation`) o expandirle stake.
3. El FP (o quien tenga su clave) commitea randomness: aceptado.
4. La tabla de voting power le da **slot activo** con peso real.
5. `MsgAddFinalitySig` **sí** lo rechaza ⇒ su peso nunca vota.
6. `tally` suma su poder en `totalPower` pero nunca en `votedPower`:
   ```go
   return votedPower*3 > totalPower*2
   ```
7. Si el peso muerto pasa de ~1/3, ningún bloque finaliza nunca y el estado no se recupera solo.

## 4. Por qué el vector es barato

No hace falta ser el FP borrado ni tener su clave BTC. Cualquiera puede:

- crear delegación o expansión apuntando al FP, y
- commitear randomness **en su nombre**: `MsgCommitPubRandList` sólo verifica la firma contra la clave del FP y que exista.

Se puede inyectar peso muerto a voluntad en una entidad ya neutralizada. El coste es el timelock del propio BTC, no un privilegio.

## 5. Corrección en main

`292b5d49` añade el chequeo en las tres rutas y `ErrFpDeleted` (code 1130). El PR lo describe como *"dropping quorum below ⅔ threshold and halting finality indefinitely"*.

## 6. Precondición no verificada

Requiere que exista al menos un FP soft-deleted con peso relevante en `bbn-1`. No pude comprobarlo: sin acceso a estado live y el genesis publicado es sólo metadata.

Lo que sí está probado en código: la marca existe con escritores reales, las cuatro rutas no la consultan, la tabla de poder tampoco, y el rechazo de firmas sí. **La asimetría entre "puede ganar peso" y "no puede votar" es el bug.**

## 7. Gravedad según los cuatro criterios

| Criterio | Cumple | Nota |
|---|---|---|
| 1. Bug concreto y explotable | **Sí** | cuatro rutas demostradas, PR con tests |
| 2. Alcanzable en live | **Sí en código** | presente en `0c1f1447`; requiere FP borrado en estado |
| 3. Impacto real | **Parcial** | halt de finality, **no** robo |
| 4. Sin privilegios previos | **Sí** | cualquiera puede delegar/commitear |
