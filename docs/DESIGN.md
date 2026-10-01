# Baires Arena — diseño

Shooter de arena estilo Quake III, escrito en C3 (0.8.4) sobre raylib 6. Homenaje a Baires LAN:
multijugador real por red local, bots, consola, mapas inspirados en Buenos Aires.

**Antes de escribir C3, leer `C:\Users\fbarr\source\repos\c3\CLAUDE.md`** (reglas verificadas del
lenguaje, gotchas, dónde está la doc y la stdlib). Ante duda de API: `grep` en
`C:\Users\fbarr\source\repos\c3\c3c-bin\lib\std` y compilar. No inventar funciones.

## Alcance

- Movimiento Quake III (strafe-jump, bunny-hop, rocket-jump, step-up de escalones), determinista.
- Armas: ametralladora, escopeta, lanzacohetes, railgun. Quad damage. Salud / armadura / mega.
- Deathmatch FFA: fraglimit + timelimit, scoreboard, rotación de mapas.
- Red: servidor autoritativo UDP a 60 ticks, predicción en cliente + reconciliación,
  interpolación de entidades remotas, descubrimiento de servidores LAN por broadcast.
- Modo `--dedicated` sin ventana (consola de texto) para correrlo en un server.
- Bots: grafo de navegación autogenerado del mapa + A*, puntería con error por habilidad.
- Render: mundo de brushes AABB, iluminación horneada por vértice (luces con sombras + AO) en
  threads, texturas procedurales, partículas, rail beams, luces dinámicas de explosiones.
- Audio 100% sintetizado en código (sin archivos).
- Consola estilo Quake (`~`) con cvars y comandos; `autoexec.cfg`.
- Mapas: `subte` (andén de subte, azulejos), `obelisco` (plaza abierta), `puerto` (contenedores).

## Unidades y convenciones

- 1 unidad = 1 metro. **Y es arriba** (raylib). Ángulos en radianes. `yaw` 0 mira a +Z,
  crece hacia +X (`forward = { sin(yaw)*cos(pitch), -sin(pitch), cos(yaw)*cos(pitch) }`;
  pitch positivo = mirar abajo).
- Tick fijo `TICK_RATE = 60` (`TICK_DT = 1/60`).
- Jugador: origen en los **pies**. Hull `mins = {-0.45, 0, -0.45}`, `maxs = {0.45, 1.75, 0.45}`.
  Ojos a `1.55`. Escalón máx `0.56`. Valores de Quake III divididos por 32: correr 10 m/s,
  gravedad 25 m/s², salto 8.44 m/s (altura ≈ 1.42 m).
- Vectores: `Vec3` (= `float[<3>]` de std::math, mismo tipo que `RLVector3`).

## Árbol de módulos

```
src/main.c3                 arena            entrada, args, máquina de estados de la app
src/core/mathx.c3           arena::mathx     Aabb, ángulos, rng determinista (xorshift)
src/core/bitbuf.c3          arena::bitbuf    BitWriter / BitReader (paquetes de red)
src/core/cvar.c3            arena::cvar      cvars + comandos de consola
src/game/defs.c3            arena::defs      constantes y enums compartidos (este doc §Defs)
src/game/map.c3             arena::map       Map + parser del formato .map
src/game/collide.c3         arena::map       trazas de caja/rayo contra brushes (métodos de Map)
src/game/pmove.c3           arena::pmove     física del jugador (determinista, cliente+server)
src/game/world.c3           arena::world     simulación autoritativa: jugadores, armas, items, match
src/game/nav.c3             arena::nav       grafo de navegación autogenerado + A*
src/game/bot.c3             arena::bot       IA de bots → produce UserCmd
src/game/bots.c3            arena::bots      plantel de bots de una partida (hook por tick)
src/game/snap.c3            arena::snap      Snapshot: lo que el cliente necesita para dibujar un tick
src/client/bake.c3          arena::bake      horneado de luz por vértice + grilla de sondas
src/client/fx.c3            arena::fx        partículas, rail beams, luces dinámicas
src/client/cgame.c3         arena::cgame     input → UserCmd, cámara, eventos → sonido/fx/HUD
src/client/session.c3       arena::session   partida offline / anfitrión / remota
src/client/synth.c3         arena::synth     DSP de audio
src/net/udp.c3              arena::udp       sockets UDP no bloqueantes (extern Winsock/POSIX)
src/net/proto.c3            arena::proto     mensajes, snapshots, handshake
src/net/server.c3           arena::server    servidor: clientes, snapshots, timeouts
src/net/client.c3           arena::client    cliente: predicción, interpolación
src/client/render.c3        arena::render    malla del mundo, horneado de luz, entidades, efectos
src/client/textures.c3      arena::textures  texturas procedurales por Material
src/client/audio.c3         arena::audio     síntesis de efectos + reproducción 3D
src/client/console.c3       arena::console   UI de consola desplegable
src/client/hud.c3           arena::hud       HUD, killfeed, scoreboard, chat
src/client/menu.c3          arena::menu      menú principal, browser LAN, opciones
maps/*.map                                   mapas en texto
test/*.c3                                    tests (@test), `c3c test`
```

## Defs (arena::defs) — compartido por todos

```c3
enum Material : char (String id, Vec3 base) — ids usados en los .map:
  TILE_WHITE "tile_white"   azulejo blanco de subte (biselado)
  TILE_BAND  "tile_band"    franja de azulejos de color (línea A celeste)
  CONCRETE   "concrete"     hormigón
  COBBLE     "cobble"       adoquines porteños
  STONE      "stone"        piedra clara (obelisco)
  METAL      "metal"        chapa semilla de melón
  CONTAINER_RED  "container_red"   contenedor corrugado
  CONTAINER_BLUE "container_blue"
  WOOD       "wood"
  BRICK      "brick"
  TRIM       "trim"         borde amarillo/negro de andén
  GRASS      "grass"
  LIGHT      "light"        panel emisivo (no se ilumina, brilla)
  JUMPPAD    "jumppad"
  CLIP       "clip"         invisible, solo colisión
```

`Weapon`, `ItemKind`, `UserCmd`, `PlayerState`, `Buttons`, `PmFlags`, `EventKind` están definidos
en `src/game/defs.c3` — **esa es la fuente de verdad**, leerla.

## Formato .map (texto, una directiva por línea, `#` comenta)

```
name "Subte Línea A"
sky   0.02 0.03 0.05            # color de fondo/cielo
fog   0.03 0.035 0.05 0.012     # color + densidad
ambient 0.18 0.18 0.22
sun   0.3 -1 0.2   0.0 0.0 0.0  # dirección + color (0 = sin sol, mapa cerrado)
box   x0 y0 z0  x1 y1 z1  material        # brush sólido AABB (orden de esquinas libre)
stairs x0 y0 z0  x1 y1 z1  steps axis material
       # escalera dentro de la caja: sube de y0 a y1 a lo largo de axis (+x -x +z -z)
light x y z  r g b  radius               # luz puntual (color 0..N, puede >1)
spawn x y z  yaw_grados
item  kind x y z                         # kind = id de ItemKind (ver defs)
jumppad x y z  tx ty tz                  # pad 1.6x0.2x1.6 centrado en x,z con piso en y;
                                         # lanza para pasar por el punto t (ápice)
teleport x y z  dx dy dz  yaw_grados      # trigger 1.4x2x1.4 con base en x,y,z → destino
mirror x | z                             # duplica TODO lo declarado hasta acá espejado en ese eje
```

## Red (resumen)

- Puerto por defecto 27960. Header: `u16 magic 0xBA05`, `u8 version`, `u8 tipo`.
- Sin conexión: `INFO_REQUEST` (broadcast) → `INFO`; `CONNECT(nombre, color)` → `ACCEPT(id, mapa)`
  o `REJECT(motivo)`.
- Cliente → server, cada tick: últimos 3 `UserCmd` (redundancia), ack del último snapshot,
  mensajes confiables (chat/comandos) con número de secuencia.
- Server → cliente, cada tick: tick, último cmd procesado de ese cliente, `PlayerState` completo
  del jugador local, estado cuantizado de todos los jugadores, proyectiles, máscara de items,
  eventos recientes (con id, el cliente deduplica), mensajes confiables.
- Predicción: el cliente guarda cmds sin confirmar; al llegar un snapshot pisa su estado y
  re-simula los cmds pendientes con el mismo `pmove`. Remotos: interpolados 100 ms atrás.

## Calidad

- Cada módulo con `@test` propios donde haya lógica pura (bitbuf, parser, trazas, pmove,
  síntesis, nav). El runner chequea leaks.
- Estilo de `C:\Users\fbarr\source\repos\c3\CLAUDE.md`: plano, early return, `@private`/`@local`
  para lo interno, enums antes que bools, sin números mágicos, llaves siempre.
