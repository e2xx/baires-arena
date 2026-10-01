// A running game as seen by the local player.
//   OFFLINE: World runs in-process (no sockets).
//   HOST:    a Server in-process plus our own Client over loopback (others can join).
//   REMOTE:  only a Client connected to someone else's server.
module arena::session;
import std::math, std::io, raylib6;
import arena::defs, arena::map, arena::world, arena::snap, arena::bake, arena::render, arena::cgame;
import arena::server, arena::client, arena::udp, arena::proto;

faultdef MAP_FAILED, CONNECT_FAILED;

const float INTERP_DELAY = 0.1f;

enum Mode : char (String label)
{
	OFFLINE { "Contra bots" },
	HOST { "Anfitrión LAN" },
	REMOTE { "Conectado" },
}

// Called every server tick before World.step: the app drives bots here.
alias BotHook = fn void(World* w, void* ctx);
alias PrintFn = fn void(String text);
alias CleanupFn = fn void(void* ctx);

struct Session
{
	Mode mode;
	String map_id;
	char[32] map_id_buf;

	// Client-side view of the map (render + prediction).
	Map* map;
	Baked* baked;
	Renderer* gfx;
	Cgame cg;
	Snapshot view;
	float acc;
	bool loaded;

	// OFFLINE
	World* world;
	int me;
	Snapshot prev;
	Snapshot cur;

	// HOST
	Server* server;
	Map* server_map;

	// HOST / REMOTE
	Client* net;
	uint last_tick;
	PlayerState pred_prev;
	PlayerState pred_cur;

	BotHook bot_hook;
	void* bot_ctx;
	CleanupFn bot_cleanup;
	PrintFn printer;
	float follow_time;
	int follow_seed;
}

fn Map*? load_map(String id)
{
	ParseReport rep;
	Map*? m = map::load(string::tformat("maps/%s.map", id), &rep);
	if (catch err = m)
	{
		io::eprintfn("maps/%s.map:%d: %s", id, rep.line, rep.what);
		return err~;
	}
	return m;
}

fn void Session.set_map_id(&self, String id)
{
	usz n = id.len < 32 ? id.len : 32;
	self.map_id_buf[:n] = id[:n];
	self.map_id = (String)self.map_id_buf[:n];
}

fn void Session.say(&self, String text)
{
	if (self.printer)
	{
		self.printer(text);
		return;
	}
	io::printn(text);
}

<*
 Loads the client-side map, bakes its lighting and builds GPU meshes.
*>
fn void? Session.load_view(&self, String id)
{
	self.unload_view();
	Map* m = load_map(id)!;
	self.set_map_id(id);
	self.map = m;
	self.baked = bake::bake(m);
	self.say(string::tformat("%s · luz horneada: %d vértices en %.0f ms", m.name(), self.baked.vertex_count(), self.baked.seconds * 1000.0f));
	self.gfx = render::create(m, self.baked);
	int slot = self.me;
	self.cg.init(m, self.gfx, slot);
	self.loaded = true;
}

fn void Session.unload_view(&self)
{
	if (!self.loaded) return;
	self.gfx.destroy();
	self.baked.free();
	free(self.baked);
	self.map.free();
	self.loaded = false;
}

fn Session*? start_offline(String map_id, String player_name, char color)
{
	Session* s = mem::new(Session);
	s.mode = OFFLINE;
	if (catch err = s.load_view(map_id))
	{
		free(s);
		return err~;
	}
	s.world = world::create(s.map);
	s.me = s.world.add_player(player_name, color, false);
	s.cg.slot = s.me;
	s.cur.from_world(s.world, s.me, 0);
	s.prev = s.cur;
	s.cg.on_snapshot(&s.cur);
	return s;
}

<*
 Menu background: bots play on their own and the camera rides along with one of them.
*>
fn Session*? start_attract(String map_id)
{
	Session* s = mem::new(Session);
	s.mode = OFFLINE;
	s.me = -1;
	if (catch err = s.load_view(map_id))
	{
		free(s);
		return err~;
	}
	s.world = world::create(s.map);
	s.world.timelimit = 0;
	s.world.fraglimit = 1000;
	s.cg.slot = -1;
	s.cur.from_world(s.world, -1, 0);
	s.prev = s.cur;
	s.cg.on_snapshot(&s.cur);
	return s;
}

fn Session*? start_host(String map_id, String player_name, char color, ServerConfig cfg)
{
	Map* sm = load_map(map_id)!;
	cfg.map_id = map_id;
	Server*? srv = server::start(cfg, sm);
	if (catch err = srv)
	{
		sm.free();
		return err~;
	}
	Session*? s = start_remote(string::tformat("127.0.0.1:%d", srv.port()), player_name, color);
	if (catch err = s)
	{
		srv.stop();
		sm.free();
		return err~;
	}
	s.mode = HOST;
	s.server = srv;
	s.server_map = sm;
	s.say(string::tformat("servidor escuchando en el puerto %d", srv.port()));
	return s;
}

fn Session*? start_remote(String address, String player_name, char color)
{
	Client* c = client::connect(address, player_name, color)!;
	Session* s = mem::new(Session);
	s.mode = REMOTE;
	s.net = c;
	s.me = -1;
	return s;
}

fn void Session.free(&self)
{
	if (self.bot_cleanup) self.bot_cleanup(self.bot_ctx);
	if (self.net) self.net.disconnect();
	if (self.server)
	{
		self.server.stop();
		self.server_map.free();
	}
	if (self.world) self.world.free();
	self.unload_view();
	free(self);
}

fn void Session.set_bot_hook(&self, BotHook hook, void* ctx)
{
	self.bot_hook = hook;
	self.bot_ctx = ctx;
	if (self.server) self.server.set_tick_hook(hook, ctx);
}

fn World* Session.authority(&self)
{
	if (self.world) return self.world;
	if (self.server) return self.server.world();
	return null;
}

fn Map* Session.authority_map(&self)
{
	if (self.world) return self.map;
	if (self.server) return self.server_map;
	return null;
}

<*
 Host-only: switch everyone to another map without dropping connections.
*>
fn void? Session.change_map(&self, String id)
{
	switch (self.mode)
	{
		case OFFLINE:
			Map* m = load_map(id)!;
			String name = self.world.players[self.me].name();
			char color = self.world.players[self.me].color;
			char[world::MAX_NAME] keep;
			keep[:name.len] = name[..];
			self.world.free();
			self.world = null;
			self.unload_view();
			m.free();
			self.load_view(id)!;
			self.world = world::create(self.map);
			self.me = self.world.add_player((String)keep[:name.len], color, false);
			self.cg.slot = self.me;
			self.cur.from_world(self.world, self.me, 0);
			self.prev = self.cur;
			self.cg.on_snapshot(&self.cur);
		case HOST:
			Map* m = load_map(id)!;
			self.server.change_map(m, id);
			self.server_map.free();
			self.server_map = m;
		case REMOTE:
			return MAP_FAILED~;
	}
}

// ---------------------------------------------------------------- per frame

fn bool Session.connected(&self) => self.mode == OFFLINE || (self.net != null && self.net.state == CONNECTED && self.loaded && self.net.latest() != null);

fn String Session.status(&self)
{
	if (self.net == null) return "";
	switch (self.net.state)
	{
		case CONNECTING: return "Conectando...";
		case DISCONNECTED: return self.net.reason();
		case CONNECTED: return self.loaded ? "" : "Cargando mapa...";
	}
}

fn bool Session.dead_link(&self) => self.net != null && self.net.state == DISCONNECTED;

fn void Session.frame(&self, float dt, bool input, int screen_w, int screen_h)
{
	if (self.mode == OFFLINE)
	{
		self.frame_offline(dt, input, screen_w, screen_h);
		return;
	}
	self.frame_net(dt, input, screen_w, screen_h);
}

fn void Session.frame_offline(&self, float dt, bool input, int screen_w, int screen_h)
{
	self.cg.look(input);
	self.acc += dt;
	int ticks = 0;
	while (self.acc >= defs::TICK_DT && ticks < 8)
	{
		UserCmd cmd = self.cg.make_cmd(input);
		if (self.me >= 0) self.world.run_cmd(self.me, cmd);
		if (self.bot_hook) self.bot_hook(self.world, self.bot_ctx);
		self.world.step();
		self.prev = self.cur;
		self.cur.from_world(self.world, self.me, self.cg.last_event);
		self.cg.on_snapshot(&self.cur);
		self.acc -= defs::TICK_DT;
		ticks++;
	}
	if (ticks == 8) self.acc = 0;

	snap::lerp(&self.prev, &self.cur, self.acc / defs::TICK_DT, &self.view);
	PlayerState ps = self.me >= 0 ? self.view.local.ps : self.spectator_view(dt);
	self.cg.update(dt, &self.view);
	self.cg.draw(&self.view, &ps, dt, screen_w, screen_h);
}

const float FOLLOW_TIME = 14.0f;

<*
 Spectator camera: rides along with a living bot, switching every FOLLOW_TIME seconds or
 when it dies; with nobody alive it pans slowly from a spawn point.
*>
fn PlayerState Session.spectator_view(&self, float dt)
{
	Cgame* cg = &self.cg;
	self.follow_time -= dt;
	bool lost = cg.follow < 0 || !self.view.players[cg.follow].alive();
	if (lost || self.follow_time <= 0)
	{
		self.follow_time = FOLLOW_TIME;
		cg.follow = -1;
		for (int k = 1; k <= defs::MAX_PLAYERS; k++)
		{
			int i = (self.follow_seed + k) % defs::MAX_PLAYERS;
			if (!self.view.players[i].alive()) continue;
			cg.follow = i;
			self.follow_seed = i;
			break;
		}
	}
	if (cg.follow >= 0)
	{
		PlayerSnap* p = &self.view.players[cg.follow];
		cg.yaw = p.yaw;
		cg.pitch = p.pitch;
		return { .origin = p.origin, .velocity = p.velocity, .flags = p.flags };
	}
	Spawn sp = self.map.spawns[self.follow_seed % self.map.spawn_count];
	cg.yaw = sp.yaw + math::sin(cg.time * 0.15f) * 0.6f;
	cg.pitch = 0.1f;
	return { .origin = sp.pos, .flags = { .on_ground = true } };
}

fn void Session.handle_messages(&self)
{
	while (try msg = self.net.next_message())
	{
		if (msg.starts_with("map "))
		{
			String id = msg[4..];
			if (self.loaded && id == self.map_id) continue;
			if (catch err = self.load_view(id)) self.say(string::tformat("no tengo el mapa '%s'", id));
			continue;
		}
		if (msg.starts_with("print "))
		{
			self.say(msg[6..]);
			continue;
		}
		if (msg.starts_with("chat "))
		{
			self.say(msg[5..]);
			continue;
		}
		self.say(msg);
	}
}

fn void Session.frame_net(&self, float dt, bool input, int screen_w, int screen_h)
{
	if (self.server) self.server.frame(dt);
	Client* c = self.net;
	c.frame(dt);
	if (c.state != CONNECTED) return;

	if (!self.loaded)
	{
		if (catch err = self.load_view(c.map_name())) self.say(string::tformat("no tengo el mapa '%s'", c.map_name()));
	}
	self.handle_messages();
	if (!self.loaded) return;

	self.me = c.slot;
	self.cg.slot = c.slot;
	self.cg.look(input);

	Snapshot* latest = c.latest();
	if (latest != null && latest.tick != self.last_tick)
	{
		self.last_tick = latest.tick;
		self.cg.on_snapshot(latest);
	}

	// Commands go out at the fixed tick rate; prediction advances with them.
	self.acc += dt;
	int ticks = 0;
	while (self.acc >= defs::TICK_DT && ticks < 8)
	{
		c.send_cmd(self.cg.make_cmd(input));
		self.acc -= defs::TICK_DT;
		ticks++;
		self.pred_prev = self.pred_cur;
		self.pred_cur = c.predict(self.map);
	}
	if (ticks == 8) self.acc = 0;
	if (latest == null) return;
	if (ticks == 0 && self.pred_cur.origin.length_sq() == 0) self.pred_cur = c.predict(self.map);

	if (!c.interpolated(INTERP_DELAY, &self.view)) self.view = *latest;
	PlayerState ps = self.pred_cur;
	if (self.pred_prev.flags.teleport_bit == self.pred_cur.flags.teleport_bit)
	{
		float t = self.acc / defs::TICK_DT;
		ps.origin = self.pred_prev.origin + (self.pred_cur.origin - self.pred_prev.origin) * t;
	}
	if (self.me >= 0)
	{
		self.view.players[self.me].origin = ps.origin;
		self.view.local.ps = ps;
	}
	self.cg.update(dt, &self.view);
	self.cg.draw(&self.view, &ps, dt, screen_w, screen_h);
}
