module arena::world_test;
import std::math, arena::map, arena::mathx, arena::defs, arena::world;

const String ARENA = `
box -50 -1 -50  50 0 50  concrete
box -50 0 -50  -49 10 50  brick
box 49 0 -50  50 10 50  brick
box -50 0 -50  50 10 -49  brick
box -50 0 49  50 10 50  brick
spawn -20 0 0 90
spawn 20 0 0 -90
item mega 0 0 10
item rocket 0 0 -10
`;

fn Map* arena_map()
{
	Map* m = mem::new(Map);
	ParseReport rep;
	if (catch err = m.parse(ARENA, &rep)) abort("parse failed at line %d: %s", rep.line, rep.what);
	return m;
}

fn UserCmd look(Player* p, uint seq, Vec3 at, bool attack, Weapon w = MACHINEGUN)
{
	Vec3 d = (at - p.eye()).normalize();
	float yaw = math::atan2(d.x, d.z);
	float pitch = -math::asin(d.y);
	return { .seq = seq, .yaw = yaw, .pitch = pitch, .buttons = { .attack = attack }, .weapon = w };
}

fn int count_events(World* w, EventKind kind)
{
	int n;
	w.@events_since(0; GameEvent* e)
	{
		if (e.kind == kind) n++;
	};
	return n;
}

fn void rail_kills_and_scores() @test
{
	Map* m = arena_map();
	defer m.free();
	World* w = world::create(m);
	defer w.free();
	int a = w.add_player("Pity", 0, false);
	int b = w.add_player("Colo", 1, false);
	Player* pa = &w.players[a];
	Player* pb = &w.players[b];
	pa.ps.origin = { -10, 0, 0 };
	pb.ps.origin = { 10, 0, 0 };
	pa.owned[(int)Weapon.RAILGUN] = true;
	pa.ammo[(int)Weapon.RAILGUN] = 10;
	pb.armor = 0;

	uint seq = 1;
	// Switch weapon, wait for the switch, then fire twice (refire 1.5 s).
	for (int t = 0; t < 400; t++)
	{
		w.run_cmd(a, look(pa, seq++, pb.eye(), t > 30, RAILGUN));
		w.run_cmd(b, { .seq = seq, .yaw = pb.ps.yaw, .weapon = MACHINEGUN });
		w.step();
		if (pb.ps.flags.dead) break;
	}
	assert(pb.ps.flags.dead, "health %d", pb.health);
	assert(pa.frags == 1);
	assert(pb.deaths == 1);
	assert(count_events(w, DEATH) == 1);
	assert(count_events(w, RAIL) >= 1);
}

fn void rocket_jump_lifts_shooter() @test
{
	Map* m = arena_map();
	defer m.free();
	World* w = world::create(m);
	defer w.free();
	int a = w.add_player("Toto", 0, false);
	Player* p = &w.players[a];
	p.ps.origin = { 0, 0, 30 };
	p.owned[(int)Weapon.ROCKET] = true;
	p.ammo[(int)Weapon.ROCKET] = 10;
	p.weapon = ROCKET;

	// Look straight down, jump and fire.
	UserCmd c = { .seq = 1, .yaw = 0, .pitch = 1.5f, .weapon = ROCKET, .buttons = { .jump = true, .attack = true } };
	float peak = 0;
	for (int t = 0; t < 120; t++)
	{
		c.seq++;
		if (t > 2) c.buttons.attack = false;
		w.run_cmd(a, c);
		w.step();
		peak = math::max(peak, p.ps.origin.y);
	}
	assert(count_events(w, EXPLOSION) == 1);
	assert(peak > 3.0f, "rocket jump peak %f", peak);
	assert(p.health < defs::SPAWN_HEALTH && p.health > 50, "health %d", p.health);
}

fn void items_pickup_and_respawn() @test
{
	Map* m = arena_map();
	defer m.free();
	World* w = world::create(m);
	defer w.free();
	int a = w.add_player("Nacho", 0, false);
	Player* p = &w.players[a];
	p.ps.origin = { 0, 0, -10 };
	w.run_cmd(a, { .seq = 1 });
	assert(p.owned[(int)Weapon.ROCKET]);
	assert(!w.items[1].available);
	assert(count_events(w, PICKUP) == 1);

	// Mega: needs health below 200; spawn health is 125.
	p.ps.origin = { 0, 0, 10 };
	w.run_cmd(a, { .seq = 2 });
	assert(p.health == 200, "health %d", p.health);

	for (int t = 0; t < (int)(ItemKind.WEAPON_ROCKET.respawn * defs::TICK_RATE) + 2; t++) w.step();
	assert(w.items[1].available);
}

fn void fraglimit_ends_match() @test
{
	Map* m = arena_map();
	defer m.free();
	World* w = world::create(m);
	defer w.free();
	w.fraglimit = 2;
	int a = w.add_player("Beto", 0, false);
	int b = w.add_player("Lucho", 1, false);
	for (int k = 0; k < 2; k++)
	{
		w.players[b].ps.flags.dead = false;
		w.players[b].health = 1;
		w.damage(b, a, 50, { 1, 0, 0 }, MACHINEGUN, false);
	}
	assert(w.phase == INTERMISSION);
	assert(w.winner == (char)a);
	for (int t = 0; t < (int)(defs::INTERMISSION_TIME * defs::TICK_RATE) + 2; t++) w.step();
	assert(w.phase == PLAYING);
	assert(w.players[a].frags == 0);
}
