// Validates every map in maps/: parses, spawns/items/pads/teleports are sane and the world is sealed.
module arena::maps_valid_test;
import std::io, std::math, std::io::path, arena::map, arena::mathx, arena::defs;

const int MIN_SPAWNS = 8;
const int MAX_BRUSH_BUDGET = 1500;
const int MAX_LIGHT_BUDGET = 200;
const float GROUND_DEPTH = 0.6f;          // ground must be this close below a spawn
const float ITEM_REST_TOLERANCE = 0.05f;  // items sit on the floor top
const int ENCLOSURE_RAYS = 200;
const float ENCLOSURE_DIST = 200.0f;
const float VOID_MAX_DIR_Y = 0.05f;       // rays at or below the horizon must hit visible geometry
const float APEX_REACH = 0.5f;            // the flight must pass this close to the declared apex
const int MAX_FLIGHT_TICKS = 900;
const Vec3 LIFT = { 0, 0.05f, 0 };
const String[*] REQUIRED_MAPS = { "subte.map", "obelisco.map", "puerto.map" };

alias MapCheck = fn void(Map* m, String name);

<*
 maps/ next to test/, resolved from this file's location so the test runs from any directory.
*>
fn String maps_dir() => string::tformat("%s/../maps", $$FILEPATH.path_tdirname()!!);

<*
 Loads each *.map in maps/ and runs `check` on it.
*>
fn int each_map(MapCheck check)
{
	int count = 0;
	@pool()
	{
		String dir = maps_dir();
		PathList? files = path::ls(tmem, path::tnew(dir)!!, no_dirs: true, mask: "*.map");
		if (catch err = files) abort("cannot list %s: %s", dir, err);
		foreach (file : files)
		{
			String name = (String)file;
			ParseReport rep;
			Map*? loaded = map::load(string::tformat("%s/%s", dir, name), &rep);
			if (catch err = loaded) abort("%s:%d: %s", name, rep.line, rep.what);
			Map* m = loaded;
			check(m, name);
			m.free();
			count++;
		}
	};
	return count;
}

fn bool ground_below(Map* m, Vec3 pos, float depth)
{
	Vec3 start = pos + LIFT;
	Trace tr = m.trace(start, start - (Vec3){ 0, depth + LIFT.y, 0 }, defs::PLAYER_MINS, defs::PLAYER_MAXS, PLAYER);
	return !tr.startsolid && tr.fraction < 1.0f && tr.normal.y >= defs::MIN_WALK_NORMAL;
}

fn bool hull_free(Map* m, Vec3 pos) => !m.box_solid(pos + LIFT, defs::PLAYER_MINS, defs::PLAYER_MAXS, PLAYER);

fn Vec3 fibonacci_dir(int i, int n)
{
	float golden = (float)math::PI * (3.0f - math::sqrt(5.0f));
	float y = 1.0f - 2.0f * ((float)i + 0.5f) / (float)n;
	float r = math::sqrt(math::max(0.0f, 1.0f - y * y));
	float theta = golden * (float)i;
	return { math::cos(theta) * r, y, math::sin(theta) * r };
}

<*
 Returns how many of the sampled rays from `eye` escape (no hit within ENCLOSURE_DIST) for the
 player mask, and how many near-horizontal rays see no visible geometry (the void).
*>
fn int[<2>] leaks_from(Map* m, Vec3 eye)
{
	int[<2>] leaks;
	for (int k = 0; k < ENCLOSURE_RAYS; k++)
	{
		Vec3 d = fibonacci_dir(k, ENCLOSURE_RAYS);
		Vec3 end = eye + d * ENCLOSURE_DIST;
		if (m.trace_ray(eye, end, PLAYER).fraction >= 1.0f) leaks.x++;
		if (d.y > VOID_MAX_DIR_Y) continue;
		if (m.trace_ray(eye, end, SHOT).fraction >= 1.0f) leaks.y++;
	}
	return leaks;
}

// ---------------------------------------------------------------- checks

fn void check_budget(Map* m, String name)
{
	int cells = m.gx * m.gy * m.gz;
	assert(m.brush_count <= MAX_BRUSH_BUDGET, "%s: %d brushes", name, m.brush_count);
	assert(m.light_count <= MAX_LIGHT_BUDGET, "%s: %d lights", name, m.light_count);
	assert(m.cell_start[cells] <= map::MAX_GRID_REFS, "%s: broadphase overflow (%d refs)", name, m.cell_start[cells]);
}

fn void check_spawns(Map* m, String name)
{
	assert(m.spawn_count >= MIN_SPAWNS, "%s: only %d spawns", name, m.spawn_count);
	for (int i = 0; i < m.spawn_count; i++)
	{
		Vec3 pos = m.spawns[i].pos;
		assert(hull_free(m, pos), "%s: spawn %d %s is inside solid", name, i, pos);
		assert(ground_below(m, pos, GROUND_DEPTH), "%s: spawn %d %s has no ground below", name, i, pos);
	}
}

fn void check_items(Map* m, String name)
{
	for (int i = 0; i < m.item_count; i++)
	{
		ItemSpot it = m.items[i];
		Vec3 up = { 0, 0.25f, 0 };
		Trace tr = m.trace_ray(it.pos + up, it.pos - up, PLAYER);
		assert(!tr.startsolid && tr.fraction < 1.0f, "%s: item %d %s at %s floats", name, i, it.kind.id, it.pos);
		assert(math::abs(tr.endpos.y - it.pos.y) < ITEM_REST_TOLERANCE, "%s: item %d %s at %s is not on the floor (floor %f)", name, i, it.kind.id, it.pos, tr.endpos.y);
		assert(hull_free(m, it.pos), "%s: item %d %s at %s is inside solid", name, i, it.kind.id, it.pos);
	}
}

<*
 Flies the ballistic arc from the pad: it must pass near the apex without hitting anything first
 and come down on walkable ground that is not another pad (no ping-pong).
*>
fn void check_pads(Map* m, String name)
{
	for (int i = 0; i < m.pad_count; i++)
	{
		JumpPad p = m.pads[i];
		assert(m.bounds.contains(p.apex), "%s: pad %d apex %s outside the map", name, i, p.apex);
		assert(!m.box_solid(p.apex, defs::PLAYER_MINS, defs::PLAYER_MAXS, PLAYER), "%s: pad %d apex %s inside solid", name, i, p.apex);

		Vec3 pos = p.pos;
		Vec3 vel = p.launch;
		float closest = float::max;
		bool landed = false;
		for (int k = 0; k < MAX_FLIGHT_TICKS && !landed; k++)
		{
			vel.y -= defs::GRAVITY * defs::TICK_DT;
			Trace tr = m.trace(pos, pos + vel * defs::TICK_DT, defs::PLAYER_MINS, defs::PLAYER_MAXS, PLAYER);
			pos = tr.endpos;
			closest = math::min(closest, (pos - p.apex).length());
			if (tr.fraction >= 1.0f) continue;
			assert(closest < APEX_REACH, "%s: pad %d flight blocked at %s before its apex", name, i, pos);
			landed = tr.normal.y >= defs::MIN_WALK_NORMAL;
			vel -= tr.normal * vel.dot(tr.normal);
		}
		assert(landed, "%s: pad %d never lands", name, i);
		for (int j = 0; j < m.pad_count; j++)
		{
			Aabb feet = { pos + defs::PLAYER_MINS, pos + defs::PLAYER_MAXS };
			assert(j == i || !m.pads[j].trigger.overlaps(feet), "%s: pad %d lands on pad %d", name, i, j);
		}
	}
}

fn void check_teleports(Map* m, String name)
{
	for (int i = 0; i < m.teleport_count; i++)
	{
		Vec3 dest = m.teleports[i].dest;
		assert(hull_free(m, dest), "%s: teleport %d destination %s inside solid", name, i, dest);
	}
}

fn void check_enclosed(Map* m, String name)
{
	Vec3 eye_up = { 0, defs::EYE_HEIGHT, 0 };
	for (int i = 0; i < m.spawn_count; i++)
	{
		Vec3 eye = m.spawns[i].pos + eye_up;
		int[<2>] leaks = leaks_from(m, eye);
		assert(leaks.x == 0, "%s: %d rays escape the map from spawn %d %s", name, leaks.x, i, eye);
		assert(leaks.y == 0, "%s: spawn %d %s sees the void in %d directions", name, i, eye, leaks.y);
	}
	for (int i = 0; i < m.pad_count; i++)
	{
		int[<2>] leaks = leaks_from(m, m.pads[i].apex);
		assert(leaks.x == 0, "%s: %d rays escape the map from pad %d apex", name, leaks.x, i);
	}
}

// ---------------------------------------------------------------- tests

fn void required_maps_exist() @test
{
	@pool()
	{
		foreach (file : REQUIRED_MAPS)
		{
			String full = string::tformat("%s/%s", maps_dir(), file);
			assert(path::is_file(path::tnew(full)!!), "missing %s", full);
		}
	};
}

fn void maps_within_budget() @test
{
	assert(each_map(&check_budget) >= REQUIRED_MAPS.len);
}

fn void spawns_free_and_grounded() @test
{
	each_map(&check_spawns);
}

fn void items_rest_on_floor() @test
{
	each_map(&check_items);
}

fn void jumppads_fly_clear() @test
{
	each_map(&check_pads);
}

fn void teleport_destinations_free() @test
{
	each_map(&check_teleports);
}

fn void maps_are_enclosed() @test
{
	each_map(&check_enclosed);
}
