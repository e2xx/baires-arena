module arena::bake_test;
import std::math, arena::map, arena::mathx, arena::defs, arena::bake;

const String ROOM = `
sun 0.3 -1 0.2  0 0 0
ambient 0.1 0.1 0.1
box -10 -1 -10  10 0 10  concrete
box -10 0 -10  -9 5 10  brick
box 9 0 -10  10 5 10  brick
box -10 0 -10  10 5 -9  brick
box -10 0 9  10 5 10  brick
box -10 5 -10  10 6 10  concrete
box -1 4.8 -1  1 5 1  light
box 2 0 2  4 2 4  metal
light 0 4.5 0  1.2 1.1 1.0  14
spawn 0 0 -5 0
`;

fn void bakes_lit_room() @test
{
	Map* m = mem::new(Map);
	defer m.free();
	ParseReport rep;
	if (catch err = m.parse(ROOM, &rep)) abort("parse failed at line %d: %s", rep.line, rep.what);

	Baked* b = bake::bake(m);
	defer
	{
		b.free();
		free(b);
	}
	assert(b.vertex_count() > 1000, "vertices %d", b.vertex_count());
	assert(b.vertex_count() % 3 == 0);
	// The floor under the light is brighter than a corner behind the metal block.
	Vec3 under = b.sample({ 0, 1, 0 });
	Vec3 corner = b.sample({ 8, 1, 8 });
	assert(under.x > corner.x, "under %s corner %s", under, corner);
	assert(under.x > 0.2f);

	// No vertex has NaN or negative light; emissive panel is overbright.
	bool saw_emissive = false;
	foreach (mat_index, &list : b.tris)
	{
		foreach (v : list.array_view())
		{
			assert(v.light.x >= 0 && v.light.y >= 0 && v.light.z >= 0, "bad light %s", v.light);
			if ((Material)mat_index == LIGHT) saw_emissive = v.light.x > 1.0f;
		}
	}
	assert(saw_emissive);
	// Without culling: 2 slabs x (400 top + 400 bottom + 80 side) cells = 3520 tris. Walls hide 160 cells.
	sz floor_tris = b.tris[(int)Material.CONCRETE].len() / 3;
	assert(floor_tris == 3520 - 2 * 160, "concrete tris %d", floor_tris);
}
