// A running game as seen by the local player. OFFLINE runs the World in-process.
module arena::session;
import std::math, std::io, raylib6;
import arena::defs, arena::map, arena::world, arena::snap, arena::bake, arena::render, arena::cgame, arena::textures;

faultdef MAP_FAILED;

enum Mode : char (String label)
{
	OFFLINE { "Contra bots" },
}

// Hook the app uses to drive bots each tick (they call w.run_cmd for their slots).
alias BotHook = fn void(World* w, void* ctx);

struct Session
{
	Mode mode;
	Map* map;
	Baked* baked;
	Renderer* gfx;
	World* world;
	int me;
	Cgame cg;
	Snapshot prev;
	Snapshot cur;
	Snapshot view;
	float acc;
	BotHook bot_hook;
	void* bot_ctx;
}

fn Map*? load_map(String name)
{
	String path = string::tformat("maps/%s.map", name);
	ParseReport rep;
	Map* m = map::load(path, &rep)!;
	io::printfn("mapa %s: %d brushes, %d luces, %d spawns, %d items", m.name(), m.brush_count, m.light_count, m.spawn_count, m.item_count);
	return m;
}

fn Session*? start_offline(String map_name, String player_name, char color)
{
	Map* m = load_map(map_name)!;
	Session* s = mem::new(Session);
	s.mode = OFFLINE;
	s.map = m;
	s.baked = bake::bake(m);
	io::printfn("luz horneada: %d caras, %d vértices en %.2f s", s.baked.face_count, s.baked.vertex_count(), s.baked.seconds);
	s.gfx = render::create(m, s.baked);
	s.world = world::create(m);
	s.me = s.world.add_player(player_name, color, false);
	s.cg.init(m, s.gfx, s.me);
	s.cur.from_world(s.world, s.me, 0);
	s.prev = s.cur;
	s.cg.on_snapshot(&s.cur);
	return s;
}

fn void Session.free(&self)
{
	self.gfx.destroy();
	self.baked.free();
	free(self.baked);
	if (self.world) self.world.free();
	self.map.free();
	free(self);
}

fn void Session.set_bot_hook(&self, BotHook hook, void* ctx)
{
	self.bot_hook = hook;
	self.bot_ctx = ctx;
}

fn void Session.tick(&self, bool input)
{
	UserCmd cmd = self.cg.make_cmd(input);
	World* w = self.world;
	w.run_cmd(self.me, cmd);
	if (self.bot_hook) self.bot_hook(w, self.bot_ctx);
	w.step();
	self.prev = self.cur;
	self.cur.from_world(w, self.me, self.cg.last_event);
	self.cg.on_snapshot(&self.cur);
}

fn void Session.frame(&self, float dt, bool input, int screen_w, int screen_h)
{
	self.cg.look(input);
	self.acc += dt;
	int ticks = 0;
	while (self.acc >= defs::TICK_DT && ticks < 8)
	{
		self.tick(input);
		self.acc -= defs::TICK_DT;
		ticks++;
	}
	if (ticks == 8) self.acc = 0;

	float alpha = self.acc / defs::TICK_DT;
	snap::lerp(&self.prev, &self.cur, alpha, &self.view);
	PlayerState ps = self.view.local.ps;
	self.cg.update(dt, &self.view);
	self.cg.draw(&self.view, &ps, dt, screen_w, screen_h);
}
