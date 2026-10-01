module arena::map_test;
import std::math, arena::map, arena::mathx, arena::defs;

const String ROOM = `
name "Caja de prueba"
box -10 -1 -10  10 0 10  concrete      # piso
box -10 0 -10  -9 6 10  brick          # pared oeste
box 2 0 -2  4 1 2  metal               # bloque de 1 m
stairs -4 0 4  -2 1.5 8  3 +z wood
light 0 4 0  1 0.9 0.8  12
spawn 0 0 -5 0
item rocket 5 0 5
jumppad 6 0 -6  6 5 0
teleport -6 0 -6  6 0 6  90
mirror x
`;

fn Map* load_room()
{
	Map* m = mem::new(Map);
	ParseReport rep;
	if (catch err = m.parse(ROOM, &rep)) abort("parse failed at line %d: %s", rep.line, rep.what);
	return m;
}

fn void parse_counts() @test
{
	Map* m = load_room();
	defer m.free();
	assert(m.name() == "Caja de prueba");
	// 3 boxes + 3 stair steps + 1 pad brush = 7, mirrored = 14.
	assert(m.brush_count == 14, "brushes: %d", m.brush_count);
	assert(m.spawn_count == 2);
	assert(m.item_count == 2);
	assert(m.pad_count == 2);
	assert(m.teleport_count == 2);
	assert(m.items[0].kind == WEAPON_ROCKET);
	// Mirrored spawn across x keeps z, negates x.
	assert(m.items[1].pos.x == -5.0f);
}

fn void parse_errors() @test
{
	Map* m = mem::new(Map);
	defer m.free();
	ParseReport rep;
	assert(@catch(m.parse("box 0 0 0 1 1 1 plutonio\nspawn 0 0 0 0", &rep)) == map::UNKNOWN_MATERIAL);
	assert(rep.line == 1);
	assert(@catch(m.parse("spawn 0 0 0 0\nbanana 1", &rep)) == map::UNKNOWN_DIRECTIVE);
	assert(rep.line == 2);
}

fn void trace_hits_floor() @test
{
	Map* m = load_room();
	defer m.free();
	Trace tr = m.trace({ 0, 5, 0 }, { 0, -5, 0 }, defs::PLAYER_MINS, defs::PLAYER_MAXS, PLAYER);
	assert(tr.fraction < 1.0f);
	assert(math::abs(tr.endpos.y) < 0.01f, "endpos.y = %f", tr.endpos.y);
	assert(tr.normal.y == 1.0f);
	assert(!tr.startsolid);
}

fn void trace_hits_wall_with_box_extent() @test
{
	Map* m = load_room();
	defer m.free();
	// Moving west at y=1.5 (above the mirrored metal block) the hull (half width .45) must stop .45 from the wall at x=-9.
	Trace tr = m.trace({ 0, 1.5f, 0 }, { -20, 1.5f, 0 }, defs::PLAYER_MINS, defs::PLAYER_MAXS, PLAYER);
	assert(math::abs(tr.endpos.x - (-9.0f + 0.45f)) < 0.01f, "endpos.x = %f", tr.endpos.x);
	assert(tr.normal.x == 1.0f);
}

fn void trace_startsolid() @test
{
	Map* m = load_room();
	defer m.free();
	Trace tr = m.trace_ray({ 3, 0.5f, 0 }, { 3, 0.5f, 0.1f }, SHOT);
	assert(tr.startsolid);
	assert(m.point_solid({ 3, 0.5f, 0 }, SHOT));
	assert(!m.point_solid({ 0, 3, 0 }, SHOT));
}

fn void jumppad_reaches_apex() @test
{
	Map* m = load_room();
	defer m.free();
	JumpPad p = m.pads[0];
	// Integrate the ballistic arc: it should pass near the apex.
	Vec3 pos = p.pos;
	Vec3 vel = p.launch;
	float best = 1e9f;
	for (int i = 0; i < 600; i++)
	{
		vel.y -= defs::GRAVITY * defs::TICK_DT;
		pos += vel * defs::TICK_DT;
		best = math::min(best, (pos - p.apex).length());
	}
	assert(best < 0.3f, "closest approach %f", best);
}
