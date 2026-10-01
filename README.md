# Baires Arena

Shooter de arena estilo Quake III escrito en **C3** sobre raylib 6. Homenaje a Baires LAN:
multijugador real por red local, bots, consola, y mapas porteños.

## Cómo jugar

```
c3c build
build\arena.exe
```

Desde el menú: **Jugar contra bots**, **Crear partida LAN** (otros se unen desde
"Unirse a partida", que busca servidores por broadcast) o **Unirse** por IP.

| Tecla | Acción |
|---|---|
| WASD | moverse |
| Mouse | apuntar |
| Click izq. | disparar |
| Espacio / click der. | saltar |
| 1–4 / rueda | arma (ametralladora, escopeta, lanzacohetes, railgun) |
| Shift | caminar |
| Tab | tabla de posiciones |
| Esc | pausa |
| `~` o F1 | consola |

Movimiento de Quake III: strafe-jump, bunny-hop, rocket-jump (mirá al piso, saltá y disparale).

## Mapas

- `subte`: estación Perú de la Línea A, andenes, vías, entrepisos y vagones de madera.
- `obelisco`: Plaza de la República al atardecer, avenidas elevadas con jump pads y quad damage.
- `puerto`: Dársena Sur de noche, contenedores apilados y grúa pórtico.
- `dev`: sala de pruebas.

## Consola

`map <id>`, `host <id>`, `connect <ip[:puerto]>`, `disconnect`, `addbot [n]`, `say <texto>`,
`cvarlist`, `cmdlist`, `help <nombre>`. Cvars útiles: `name`, `color` (0–7), `sensitivity`,
`fov`, `r_exposure`, `s_volume`, `fraglimit`, `timelimit`, `bot_count`, `bot_skill`.
Lo marcado como archivable se guarda en `autoexec.cfg`.

## Servidor dedicado

```
build\arena.exe --dedicated +map obelisco +set bot_count 4 +set fraglimit 30
```

Sin ventana, UDP 27960 (prueba los 3 siguientes si está ocupado), lee `server.cfg`.
Compila también para Linux (`--target linux-x64`). En Windows, la primera vez que se abre
el puerto el firewall puede pedir permiso para la red local.

## Arquitectura

Ver `docs/DESIGN.md`. Resumen:

- `src/game`: simulación determinista compartida por servidor y cliente (pmove de Q3,
  trazas contra brushes AABB, mundo autoritativo, bots con navegación autogenerada + A*).
- `src/net`: UDP no bloqueante (Winsock/POSIX vía `extern fn`), bit-packing, snapshots,
  canal confiable, predicción del lado del cliente e interpolación de remotos.
- `src/client`: horneado de luz por vértice en threads (sombras + AO + sondas), shaders,
  partículas, audio 100% sintetizado (efectos + música), texturas procedurales, HUD,
  menús y consola estilo Quake.

## Tests

```
c3c test
```

138 tests (física, colisión, armas, red con predicción bit a bit, bots en los mapas reales,
validación de mapas, síntesis de audio, texturas, HUD, consola). El runner verifica leaks.
