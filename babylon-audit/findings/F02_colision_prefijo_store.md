# F02 — Colisión de prefijos en el store de `x/btcstaking`: `HeightToVersionMapKey {0x10}` vs `FpBbnAddrKey NewPrefix(16)`

**Estado:** bug real en live (v4.7.0). Arreglado en `main` con cambio de prefijo + **migración de store** (`x/btcstaking/migrations/v2/store.go`) y utilidad de test (`testutil/store/key_collision.go`).
**Clasificación:** corrupción de namespace de store. **No hay extracción de valor**; el riesgo es operativo (halt / export-import de génesis), por tanto **fuera** del criterio de "crítico con robo".

---

## 1. El hecho

`x/btcstaking/types/keys.go` (live, `0c1f1447`):

```go
AllowedStakingTxHashesKey = collections.NewPrefix(9)   // {0x09}
HeightToVersionMapKey     = []byte{0x10}               // <-- hex 0x10 = decimal 16
LargestBtcReorgInBlocks   = collections.NewPrefix(11)  // {0x0B}
...
FpBbnAddrKey             = collections.NewPrefix(16)   // <-- decimal 16 = {0x10}
FinalityProvidersDeleted = collections.NewPrefix(17)   // {0x11}
```

El comentario de la migración de `main` lo dice literalmente:

```go
// (hex 0x10 = decimal 16) key prefix for height to version map
// which collides with FpBbnAddrKey that is prefix decimal 16
OldHeightToVersionMapKey = []byte{0x10}
```

`main` lo corrige a `HeightToVersionMapKey = collections.NewPrefix(10)` (decimal 10 = `{0x0A}`, libre entre 9 y 11) y **mueve los datos**:

```go
bz, err := store.Get(OldHeightToVersionMapKey)      // lee el blob del mapa
if bz == nil { rebuiltMap := rebuildHeightToVersionMap(k.GetAllParams(ctx)); return k.SetHeightToVersionMap(ctx, rebuiltMap) }
var old types.HeightToVersionMap; cdc.Unmarshal(bz, &old)
k.SetHeightToVersionMap(ctx, &old)                 // reescribe bajo {0x0A}
store.Delete(OldHeightToVersionMapKey)             // borra {0x10}
```

## 2. Efecto exacto en live (verificado, no especulado)

- `HeightToVersionMap` se guarda como **clave exacta** `{0x10}` (un solo byte): `x/btcstaking/keeper/params.go:182-200` (`store.Set/Get(HeightToVersionMapKey)`).
- El índice FP→addr es un `collections.KeySet` con prefijo `{0x10}` y `collections.BytesKey`: `x/btcstaking/keeper/keeper.go:76-82`, `finality_providers.go:78-80` (`k.fpBbnAddr.Set(ctx, fpAddr)` → clave `{0x10}||addr20`, valor vacío), lectura puntual `Has` en `finality_providers.go:147-149`.
- Las lecturas puntuales **no** se pisan (claves distintas: `{0x10}` vs `{0x10}||20B`). La única interacción es **por iteración**: el blob del mapa aparece como una entrada del KeySet con clave vacía.
- `x/btcstaking/keeper/genesis.go:329-352` (`fpBbnAddrs`) ya tiene la guarda `if len(key) == 0 { continue }`, así que el export de génesis **hoy** no se rompe.
- `GetParamsForBtcHeight` hace `panic("height to version map not found")` si el mapa no existe (`params.go:203+`): cualquier operación de borrado/prefijo sobre `{0x10}` (upgrade, `DeleteAll`, limpieza futura) puede llevarse por delante el mapa y **haltar la cadena** (liveness).

Conclusión: en live es una bomba de relojería de mantenimiento (namespace compartido + datos críticos bajo una clave que colisiona con un índice), **sin ruta de robo**: el atacante no puede escribir `{0x10}` (su addr BBN debe tener 20 bytes por `VerifyAddressFormat`), ni leer/escribir el blob del mapa.

## 3. Por qué lo reporto igual

Porque es una divergencia live↔main **con migración de estado** (señal de bug real, no de estilo), porque `testutil/store/key_collision.go` en main es una herramienta añadida para cazar exactamente esta clase de fallo, y porque un auditor de "estado desplegado" debe poder decir qué prefijos están ocupados y cuáles colisionan. Se entrega como hallazgo **no-crítico** con su repro:

`scripts/f02_evidence.sh` lista los prefijos de live y comprueba la igualdad de bytes `{0x10}` vs `NewPrefix(16)` y el diff con main.
