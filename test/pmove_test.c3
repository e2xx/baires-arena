module arena::pmove_test;
import std::math, arena::map, arena::mathx, arena::defs, arena::pmove;

const String FIELD = `
box -100 -1 -100  100 0 100  concrete
box 10 0 -5  14 0.5 5  metal          # 0.5 m step: walkable
box 20 0 -5  24 1.2 5  metal          # 1.2 m block: needs a jump
jumppad -20 0 0  -20 10 20
teleport -40 0 -40  40 0 40  90
spawn 0 0 0 0
`;

fn Map* field()
{
	Map* m = mem::new(Map);
	ParseReport rep;
	if (catch err = m.parse(FIELD, &rep)) abort("parse failed at line %d: %s", rep.line, rep.what);
	return m;
}

fn UserCmd cmd(float yaw, ichar fwd, ichar side, bool jump)
{
	return { .yaw = yaw, .forward = fwd, .side = side, .buttons = { .jump = jump } };
}

fn PmEvents run(PlayerState* ps, Map* m, UserCmd c, int ticks)
{
	PmEvents all;
	for (int i = 0; i < ticks; i++)
	{
		PmEvents e = pmove::move(ps, c, m, defs::TICK_DT);
		all = all | e;
	}
	return all;
}

fn float hspeed(PlayerState* ps) => ((Vec3){ ps.velocity.x, 0, ps.velocity.z }).length();

fn void stands_still() @test
{
	Map* m = field();
	defer m.free();
	PlayerState ps = { .origin = { 0, 0, 0 } };
	run(&ps, m, cmd(0, 0, 0, false), 120);
	assert(ps.flags.on_ground);
	assert(math::abs(ps.origin.y) < 0.01f, "y = %f", ps.origin.y);
	assert(ps.velocity.length() < 0.001f);
}

fn void falls_and_lands() @test
{
	Map* m = field();
	defer m.free();
	PlayerState ps = { .origin = { 0, 5, 0 } };
	PmEvents e = run(&ps, m, cmd(0, 0, 0, false), 120);
	assert(e.landed);
	assert(ps.flags.on_ground);
	assert(math::abs(ps.origin.y) < 0.01f);
}

fn void runs_at_run_speed() @test
{
	Map* m = field();
	defer m.free();
	PlayerState ps = { .origin = { 0, 0, -50 } };
	run(&ps, m, cmd(0, 127, 0, false), 120);
	assert(math::abs(hspeed(&ps) - defs::RUN_SPEED) < 0.05f, "speed %f", hspeed(&ps));
	assert(ps.velocity.z > 9.9f);
	// Diagonal input is normalized: still run speed, not 1.41x.
	PlayerState d = { .origin = { 0, 0, -50 } };
	run(&d, m, cmd(0, 127, 127, false), 120);
	assert(math::abs(hspeed(&d) - defs::RUN_SPEED) < 0.05f, "diag speed %f", hspeed(&d));
}

fn void jump_height() @test
{
	Map* m = field();
	defer m.free();
	PlayerState ps = { .origin = { 0, 0, 0 } };
	run(&ps, m, cmd(0, 0, 0, false), 5);
	float peak = 0;
	PmEvents e = pmove::move(&ps, cmd(0, 0, 0, true), m, defs::TICK_DT);
	assert(e.jumped);
	for (int i = 0; i < 90; i++)
	{
		pmove::move(&ps, cmd(0, 0, 0, true), m, defs::TICK_DT);
		peak = math::max(peak, ps.origin.y);
	}
	assert(peak > 1.3f && peak < 1.55f, "peak %f", peak);
	// Holding jump does not auto-bunnyhop.
	assert(ps.flags.on_ground);
}

fn void climbs_step_but_not_wall() @test
{
	Map* m = field();
	defer m.free();
	// Walk +x into the 0.5 m step at x = 10.
	PlayerState ps = { .origin = { 5, 0, 0 } };
	run(&ps, m, cmd((float)math::PI / 2, 127, 0, false), 60);
	assert(ps.origin.x > 11.0f, "x %f", ps.origin.x);
	assert(math::abs(ps.origin.y - 0.5f) < 0.02f, "y %f", ps.origin.y);
	// Keep walking: the 1.2 m block at x = 20 stops us.
	run(&ps, m, cmd((float)math::PI / 2, 127, 0, false), 120);
	assert(ps.origin.x < 20.0f - 0.44f && ps.origin.x > 19.0f, "x %f", ps.origin.x);
}

fn void strafe_jumping_gains_speed() @test
{
	Map* m = field();
	defer m.free();
	PlayerState ps = { .origin = { 0, 0, -90 } };
	run(&ps, m, cmd(0, 127, 0, false), 60);
	// Classic strafe-jump: hold forward+right, turn the view a little each tick, hop on landing.
	float yaw = 0;
	float top = 0;
	for (int i = 0; i < 300; i++)
	{
		yaw -= 0.012f;
		bool jump = ps.flags.on_ground;
		pmove::move(&ps, cmd(yaw, 127, 127, jump), m, defs::TICK_DT);
		if (!jump) pmove::move(&ps, cmd(yaw, 127, 127, false), m, 0.0001f);
		top = math::max(top, hspeed(&ps));
	}
	assert(top > defs::RUN_SPEED * 1.25f, "top speed %f", top);
}

fn void jumppad_launches() @test
{
	Map* m = field();
	defer m.free();
	PlayerState ps = { .origin = { -20, 0.5f, 0 } };
	PmEvents e = run(&ps, m, cmd(0, 0, 0, false), 2);
	assert(e.jumppad);
	float peak = 0;
	for (int i = 0; i < 120; i++)
	{
		pmove::move(&ps, cmd(0, 0, 0, false), m, defs::TICK_DT);
		peak = math::max(peak, ps.origin.y);
	}
	assert(peak > 8.0f, "peak %f", peak);
}

fn void teleporter_moves_player() @test
{
	Map* m = field();
	defer m.free();
	PlayerState ps = { .origin = { -40, 0, -42 } };
	bool bit = ps.flags.teleport_bit;
	PmEvents e = run(&ps, m, cmd(0, 127, 0, false), 30);
	assert(e.teleported);
	assert(ps.flags.teleport_bit != bit);
	assert((ps.origin - (Vec3){ 40, 0, 40 }).length() < 8.0f, "origin %s", ps.origin);
}
