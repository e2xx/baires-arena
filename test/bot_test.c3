module arena::bot_test;
import std::io, std::math, std::collections::list;
import arena::map, arena::mathx, arena::defs, arena::world, arena::nav, arena::bot;

// 60 x 60 m: west room with a raised platform (stairs up), east side split in two rooms,
// a 1 m crate (needs a jump), a jump pad up to a 5 m ledge, a teleporter onto the platform.
const String GEOMETRY = `
name "Bots"
box -30 -1 -30  30 0 30  concrete
box -31 0 -31  31 6 -30  brick
box -31 0 30  31 6 31  brick
box -31 0 -30  -30 6 30  brick
box 30 0 -30  31 6 30  brick
box -0.5 0 -30  0.5 4 -2  brick
box -0.5 0 2  0.5 4 30  brick
box 0.5 0 -0.5  12 4 0.5  brick
box 16 0 -0.5  30 4 0.5  brick
box -30 0 10  -18 3 30  concrete
stairs -18 0 14  -12 3 18  6 -x wood
box -12 0 -14  -8 1 -10  wood
box 24 0 18  30 5 30  metal
jumppad 20 0 24  26 7 24
teleport 25 0 -25  -24 3 20  180
spawn -20 0 -10 0
spawn 20 0 -10 0
spawn 20 0 10 180
spawn -10 0 20 90
spawn 10 0 -25 0
spawn -25 0 0 90
`;

const String ITEMS = `
item mega -24 3 24
item rail 27 5 26
item rocket 20 0 -20
item armor_red -20 0 -20
item health 8 0 8
item shotgun -6 0 0
item ammo_rocket 12 0 -12
item health_big -10 1 -12
`;

const String ARENA = GEOMETRY +++ ITEMS;

const String[*] REAL_MAPS = { "maps/subte.map", "maps/obelisco.map", "maps/puerto.map" };

fn Map* load_text(String text)
{
	Map* m = mem::new(Map);
	ParseReport rep;
	if (catch err = m.parse(text, &rep)) abort("parse failed at line %d: %s", rep.line, rep.what);
	return m;
}

fn bool route(NavGraph* g, Vec3 a, Vec3 b, List{int}* out)
{
	return g.path(g.nearest(a), g.nearest(b), out);
}

fn bool route_has(NavGraph* g, List{int}* r, LinkKind kind)
{
	for (sz k = 1; k < r.len(); k++)
	{
		if (try l = g.link_kind((*r)[k - 1], (*r)[k]) && l == kind) return true;
	}
	return false;
}

fn void nav_builds_graph() @test
{
	Map* m = load_text(ARENA);
	defer m.free();
	NavGraph* g = nav::build(m);
	defer g.free();
	io::printfn("nav: %d samples, %d nodes, %d links (walk %d jump %d drop %d pad %d), %d pruned, %d workers, %.1f ms",
		g.stats.samples, g.stats.nodes, g.stats.links, g.stats.by_kind[0], g.stats.by_kind[1], g.stats.by_kind[2],
		g.stats.by_kind[3], g.stats.pruned, g.stats.workers, g.stats.ms);
	assert(g.stats.nodes > 500, "nodes %d", g.stats.nodes);
	assert(g.stats.by_kind[(int)LinkKind.WALK.ordinal] > g.stats.nodes * 2);
	assert(g.stats.by_kind[(int)LinkKind.JUMP.ordinal] > 0);
	assert(g.stats.by_kind[(int)LinkKind.DROP.ordinal] > 0);
	assert(g.stats.by_kind[(int)LinkKind.PAD.ordinal] == 1);
	assert(g.stats.by_kind[(int)LinkKind.TELEPORT.ordinal] == 1);
	// Every node is standing room: hull fits, floor right below.
	foreach (&n : g.nodes)
	{
		assert(!m.box_solid(n.pos + (Vec3){ 0, 0.02f, 0 }, defs::PLAYER_MINS, defs::PLAYER_MAXS, PLAYER), "node in solid at %s", n.pos);
	}
}

fn void astar_crosses_rooms() @test
{
	Map* m = load_text(ARENA);
	defer m.free();
	NavGraph* g = nav::build(m);
	defer g.free();
	List{int} r;
	r.init(mem);
	defer r.free();
	// West room to the south-east room: through the x = 0 door, around the z = 0 wall.
	assert(route(g, { -20, 0, -10 }, { 20, 0, 20 }, &r));
	bool through_door = false;
	foreach (n : r)
	{
		Vec3 p = g.nodes[n].pos;
		if (math::abs(p.x) < 1.0f && math::abs(p.z) < 2.0f) through_door = true;
	}
	assert(through_door);
	// Consecutive nodes are linked and the route ends where we asked.
	for (sz k = 1; k < r.len(); k++) assert(@ok(g.link_kind(r[k - 1], r[k])));
	assert((g.nodes[r[^1]].pos - (Vec3){ 20, 0, 20 }).length() < 1.5f);
	// Up the stairs onto the platform.
	assert(route(g, { -20, 0, -10 }, { -24, 3, 24 }, &r));
	assert(g.nodes[r[^1]].pos.y > 2.9f);
	// Onto the crate needs a jump; off the platform is a drop (or the stairs).
	assert(route(g, { -20, 0, -10 }, { -10, 1, -12 }, &r));
	assert(route_has(g, &r, JUMP));
	assert(route(g, { -24, 3, 24 }, { -24, 0, 5 }, &r));
}

fn void astar_takes_jumppad() @test
{
	Map* m = load_text(ARENA);
	defer m.free();
	NavGraph* g = nav::build(m);
	defer g.free();
	List{int} r;
	r.init(mem);
	defer r.free();
	assert(route(g, { 10, 0, 10 }, { 27, 5, 26 }, &r));
	assert(route_has(g, &r, LinkKind.PAD));
	assert(g.nodes[r[^1]].pos.y > 4.9f);
	// And back down without the pad.
	assert(route(g, { 27, 5, 26 }, { 10, 0, 10 }, &r));
	assert(route_has(g, &r, DROP));
	// The teleporter is the short way from the south-east room onto the platform.
	assert(route(g, { 20, 0, -20 }, { -24, 3, 24 }, &r));
	assert(route_has(g, &r, LinkKind.TELEPORT));
}

<*
 One bot alone with a single item: seconds until it picks it up, or -1 after 40 s.
*>
fn float solo_pickup(String text, ItemKind kind, Vec3 start)
{
	Map* m = load_text(text);
	defer m.free();
	NavGraph* g = nav::build(m);
	defer g.free();
	World* w = world::create(m);
	defer w.free();
	int slot = w.add_player("Solo", 0, true);
	w.players[slot].ps.origin = start;
	Bot b;
	b.init(slot, 0.5f, 42);
	uint seen = 0;
	for (int tick = 0; tick < 40 * defs::TICK_RATE; tick++)
	{
		w.run_cmd(slot, b.think(w, g, (uint)tick + 1));
		w.step();
		bool got = false;
		w.@events_since(seen; GameEvent* e)
		{
			seen = e.id;
			if (e.kind == PICKUP && e.b == (char)kind.ordinal) got = true;
		};
		if (got) return w.time;
	}
	return -1;
}

fn void bot_reaches_items() @test
{
	// Through two doors, onto the jump pad, up to the ledge.
	float t = solo_pickup(GEOMETRY +++ "item rail 27 5 26", WEAPON_RAIL, { -20, 0, -10 });
	io::printfn("rail on the ledge: %.1f s", t);
	assert(t > 0 && t < 20.0f);
	// Jump onto the crate.
	t = solo_pickup(GEOMETRY +++ "item rocket -10 1 -12", WEAPON_ROCKET, { 20, 0, 20 });
	io::printfn("rocket on the crate: %.1f s", t);
	assert(t > 0 && t < 20.0f);
	// Up the stairs (from the west room) or through the teleporter (from the east).
	t = solo_pickup(GEOMETRY +++ "item mega -24 3 24", MEGA, { -20, 0, -20 });
	io::printfn("mega on the platform, stairs: %.1f s", t);
	assert(t > 0 && t < 20.0f);
	t = solo_pickup(GEOMETRY +++ "item mega -24 3 24", MEGA, { 22, 0, -22 });
	io::printfn("mega on the platform, teleporter: %.1f s", t);
	assert(t > 0 && t < 10.0f);
}

fn void jump_and_drop_links_replay_in_pmove() @test
{
	Map* m = load_text(ARENA);
	defer m.free();
	// Geometry-only links (no pmove filter): how many would pmove actually fly?
	NavGraph* g = nav::build(m, GEOMETRY);
	defer g.free();
	int total;
	int ok;
	foreach (a, &n : g.nodes)
	{
		foreach (l : g.links_of((int)a))
		{
			if (l.kind != JUMP && l.kind != DROP) continue;
			total++;
			if (nav::simulate_link(m, n.pos, g.nodes[l.to].pos, l)) ok++;
		}
	}
	io::printfn("pmove replay: %d of %d geometry-only jump/drop links land", ok, total);
	assert(total > 0);
	assert(ok * 10 >= total * 9, "only %d of %d", ok, total);

	NavGraph* strict = nav::build(m);
	defer strict.free();
	io::printfn("pmove-verified build: %d jump/drop links (%d rejected), %.1f ms",
		strict.stats.by_kind[(int)LinkKind.JUMP.ordinal] + strict.stats.by_kind[(int)LinkKind.DROP.ordinal], strict.stats.rejected, strict.stats.ms);
	List{int} r;
	r.init(mem);
	defer r.free();
	assert(route(strict, { -20, 0, -10 }, { -10, 1, -12 }, &r));
}

fn void nearest_is_reachable() @test
{
	Map* m = load_text(ARENA);
	defer m.free();
	NavGraph* g = nav::build(m);
	defer g.free();
	// Right next to the divider wall the nearest node is on our side of it.
	int n = g.nearest({ -1.2f, 0, 10 });
	assert(n >= 0);
	assert(g.nodes[n].pos.x < -0.5f, "nearest %s", g.nodes[n].pos);
	// From mid-air above the floor it is a floor node, not the ledge.
	n = g.nearest({ 22, 2, 15 });
	assert(g.nodes[n].pos.y < 0.1f);
}

fn void tactics_follow_weapon_order() @test
{
	foreach (w : Weapon::values) assert(bot::tactic_of(w).weapon == w);
	assert(bot::bot_name(0) == "Pity");
	assert(bot::bot_name(17) == "Colo");
	assert(BotState.FIGHT.label == "fight");
}

struct MatchStats
{
	int kills;
	int suicides;
	int pickups;
	int pads;
	int teleports;
	float[defs::MAX_PLAYERS] travelled;
	int[defs::MAX_PLAYERS] stuck_ticks;
	int solid_ticks;
}

<*
 Runs `count` bots on map m for `seconds`, the way a server would.
*>
fn MatchStats play(Map* m, NavGraph* g, int count, float seconds, uint seed)
{
	World* w = world::create(m);
	defer w.free();
	w.fraglimit = 1000;
	Bot[defs::MAX_PLAYERS] bots;
	for (int i = 0; i < count; i++)
	{
		int slot = w.add_player(bot::bot_name(i), (char)(i % PlayerColor::len), true);
		bots[i].init(slot, 0.35f + 0.6f * (float)i / (float)math::max(count - 1, 1), seed + (uint)i * 7919);
	}
	MatchStats st;
	Vec3[defs::MAX_PLAYERS] last;
	for (int i = 0; i < count; i++) last[i] = w.players[bots[i].slot].ps.origin;
	uint seen = 0;
	int ticks = (int)(seconds * (float)defs::TICK_RATE);
	for (int tick = 0; tick < ticks; tick++)
	{
		for (int i = 0; i < count; i++) w.run_cmd(bots[i].slot, bots[i].think(w, g, (uint)tick + 1));
		w.step();
		for (int i = 0; i < count; i++)
		{
			Player* p = &w.players[bots[i].slot];
			float moved = (p.ps.origin - last[i]).length();
			last[i] = p.ps.origin;
			if (!p.alive()) continue;
			if (moved < 2.0f) st.travelled[i] += moved;
			if (m.box_solid(p.ps.origin, defs::PLAYER_MINS, defs::PLAYER_MAXS, PLAYER)) st.solid_ticks++;
		}
		w.@events_since(seen; GameEvent* e)
		{
			seen = e.id;
			switch (e.kind)
			{
				case DEATH:
					if (e.b == defs::NO_PLAYER) st.suicides++;
					if (e.b != defs::NO_PLAYER) st.kills++;
				case PICKUP: st.pickups++;
				case JUMPPAD: st.pads++;
				case TELEPORT: st.teleports++;
				default: break;
			}
		};
	}
	for (int i = 0; i < count; i++)
	{
		Player* p = &w.players[bots[i].slot];
		io::printfn("  %-8s skill %.2f  %3d frags %3d deaths  %6.0f m  [%s]", p.name(), bots[i].skill, p.frags, p.deaths,
			st.travelled[i], bots[i].label());
	}
	return st;
}

fn void bots_play_deathmatch() @test
{
	Map* m = load_text(ARENA);
	defer m.free();
	NavGraph* g = nav::build(m);
	defer g.free();
	io::printn("test arena, 4 bots, 60 s:");
	MatchStats st = play(m, g, 4, 60.0f, 1234);
	io::printfn("  kills %d, suicides %d, pickups %d, pads %d, teleports %d", st.kills, st.suicides, st.pickups, st.pads, st.teleports);
	assert(st.kills > 0, "nobody fragged anybody");
	assert(st.solid_ticks == 0, "%d ticks inside solid", st.solid_ticks);
	for (int i = 0; i < 4; i++) assert(st.travelled[i] > 100.0f, "bot %d only moved %f m", i, st.travelled[i]);
}

fn void bots_on_real_maps() @test
{
	foreach (path : REAL_MAPS)
	{
		ParseReport rep;
		Map*? loaded = map::load(path, &rep);
		if (catch err = loaded)
		{
			io::printfn("%s: skipped (%s)", path, rep.what);
			continue;
		}
		Map* m = loaded;
		defer m.free();
		NavGraph* g = nav::build(m);
		defer g.free();
		io::printfn("%s: %d brushes, %d nodes, %d links (jump %d drop %d pad %d tele %d), %d pruned, %.1f ms",
			path, m.brush_count, g.stats.nodes, g.stats.links, g.stats.by_kind[1], g.stats.by_kind[2], g.stats.by_kind[3],
			g.stats.by_kind[4], g.stats.pruned, g.stats.ms);
		MatchStats st = play(m, g, 6, 45.0f, 99);
		io::printfn("  kills %d, suicides %d, pickups %d, pads %d, teleports %d, solid ticks %d", st.kills, st.suicides, st.pickups,
			st.pads, st.teleports, st.solid_ticks);
		for (int i = 0; i < 6; i++) assert(st.travelled[i] > 50.0f, "bot %d only moved %f m", i, st.travelled[i]);
		assert(g.stats.nodes > 0);
		assert(st.solid_ticks == 0);
	}
}

const int N = 10;
const float S = 12.0f;

// ~1500 brushes: a 10 x 10 grid of rooms with doors, crates, a platform and stairs each.
fn Map* city_map()
{
	Map* m = mem::new(Map);
	m.reset();
	Rng rng = mathx::rng(77);
	for (int i = 0; i < N; i++)
	{
		for (int j = 0; j < N; j++)
		{
			float x = (float)(i - N / 2) * S;
			float z = (float)(j - N / 2) * S;
			m.add_brush(mathx::aabb({ x, -1, z }, { x + S, 0, z + S }), CONCRETE)!!;
			m.add_brush(mathx::aabb({ x, 0, z }, { x + S * 0.4f, 3, z + 0.5f }), BRICK)!!;
			m.add_brush(mathx::aabb({ x + S * 0.6f, 0, z }, { x + S, 3, z + 0.5f }), BRICK)!!;
			m.add_brush(mathx::aabb({ x, 0, z }, { x + 0.5f, 3, z + S * 0.4f }), BRICK)!!;
			m.add_brush(mathx::aabb({ x, 0, z + S * 0.6f }, { x + 0.5f, 3, z + S }), BRICK)!!;
			for (int k = 0; k < 4; k++)
			{
				float cx = x + 2.0f + rng.unit() * 4.0f;
				float cz = z + 2.0f + rng.unit() * 4.0f;
				float h = 0.4f + rng.unit() * 1.2f;
				m.add_brush(mathx::aabb({ cx, 0, cz }, { cx + 1.0f + rng.unit(), h, cz + 1.0f + rng.unit() }), WOOD)!!;
			}
			m.add_brush(mathx::aabb({ x + 8, 0, z + 7 }, { x + 11.5f, 2, z + 11.5f }), CONCRETE)!!;
			m.add_stairs(mathx::aabb({ x + 5, 0, z + 9 }, { x + 8, 2, z + 11 }), 4, "+x", WOOD)!!;
		}
	}
	// (10, 3) inside a room is clear of its walls, crates, platform and stairs.
	for (int k = 0; k < 8; k++) m.spawns[m.spawn_count++] = { { (float)(k * 12 - 60) + 10.0f, 0, (float)(k % 3 * 24 - 24) + 3.0f }, 0 };
	m.finish();
	return m;
}

fn void nav_build_is_fast() @test
{
	Map* m = city_map();
	defer m.free();
	NavGraph* g = nav::build(m);
	defer g.free();
	io::printfn("city: %d brushes -> %d nodes, %d links (jump %d drop %d, %d rejected by pmove), %d workers, %.1f ms",
		m.brush_count, g.stats.nodes, g.stats.links, g.stats.by_kind[1], g.stats.by_kind[2], g.stats.rejected, g.stats.workers, g.stats.ms);
	NavGraph* fast = nav::build(m, GEOMETRY, 1);
	defer fast.free();
	io::printfn("city, geometry only, 1 thread: %.1f ms", fast.stats.ms);
	assert(m.brush_count >= 1400);
	assert(g.stats.nodes > 3000);
	List{int} r;
	r.init(mem);
	defer r.free();
	assert(route(g, { -57, 0, -57 }, { 57, 0, 57 }, &r));
}
