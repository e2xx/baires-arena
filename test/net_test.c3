module arena::net_test;
import std::math, arena::mathx, arena::map, arena::defs, arena::world, arena::snap, arena::bitbuf;
import std::thread, arena::udp, arena::proto, arena::server, arena::client;

const String ARENA @local = `
name "Caja de red"
box -50 -1 -50  50 0 50  concrete
box -50 0 -50  -49 10 50  brick
box 49 0 -50  50 10 50  brick
box -50 0 -50  50 10 -49  brick
box -50 0 49  50 10 50  brick
spawn -20 0 0 90
item mega 0 0 10
item rocket 0 0 -10
`;

const float DT @local = defs::TICK_DT;
const int CONNECT_FRAMES @local = 120;
const int MOVE_CMDS @local = 120;

fn Map* test_map() @local
{
	Map* m = mem::new(Map);
	ParseReport rep;
	if (catch err = m.parse(ARENA, &rep)) abort("parse failed at line %d: %s", rep.line, rep.what);
	return m;
}

fn float dist(Vec3 a, Vec3 b) @local => (a - b).length();

fn bool same(Vec3 a, Vec3 b) @local => a.x == b.x && a.y == b.y && a.z == b.z;

fn Client* dial(ushort port, String name, char color) @local => @pool()
{
	return client::connect(string::tformat("127.0.0.1:%d", port), name, color)!!;
}

<* Waiting loops yield 1 ms of real time: loopback delivery is fast but not synchronous. *>
fn void settle(Server* s, Client* c) @local
{
	pump(s, c, 1);
	thread::sleep_ms(1);
}

fn void pump(Server* s, Client* c, int frames) @local
{
	for (int i = 0; i < frames; i++)
	{
		s.frame(DT);
		c.frame(DT);
	}
}

fn Client* join(Server* s, String name) @local
{
	Client* c = dial(s.port(), name, 2);
	for (int i = 0; i < CONNECT_FRAMES && (c.state != CONNECTED || !c.latest()); i++) settle(s, c);
	assert(c.state == CONNECTED, "not connected: %s", c.reason());
	assert(c.latest() != null);
	return c;
}

// ---------------------------------------------------------------- encoding

fn void cmd_round_trip_edges() @test
{
	UserCmd[*] cases = {
		{ .seq = 0, .yaw = 0, .pitch = 0 },
		{ .seq = uint::max, .yaw = (float)math::PI, .pitch = 1.55f, .forward = 127, .side = -127,
		  .buttons = { .attack, .jump, .walk }, .weapon = RAILGUN },
		{ .seq = 12345, .yaw = -3.0f, .pitch = -1.55f, .forward = -128, .side = 127,
		  .buttons = { .jump }, .weapon = ROCKET },
		{ .seq = 7, .yaw = 10.0f, .pitch = 0.3f, .forward = 1, .side = -1, .weapon = SHOTGUN },
	};
	char[64] buf;
	BitWriter w = bitbuf::writer(&buf);
	foreach (&c : cases) proto::encode_cmd(&w, c);
	assert(!w.overflowed());
	assert(w.bytes() <= cases.len * 11, "cmds take %d bytes", w.bytes());

	BitReader r = bitbuf::reader(buf[:w.bytes()]);
	double bound = math::PI / 65536.0 + 1e-5;
	foreach (&c : cases)
	{
		UserCmd d = proto::decode_cmd(&r);
		assert(d.seq == c.seq && d.forward == c.forward && d.side == c.side);
		assert((char)d.buttons == (char)c.buttons && d.weapon == c.weapon);
		double dy = math::abs(mathx::wrap_angle(d.yaw - c.yaw));
		assert(dy <= bound, "yaw %f -> %f", c.yaw, d.yaw);
		assert(math::abs(d.pitch - c.pitch) <= bound);
		// What the server sees is a fixed point of quantization.
		UserCmd q = proto::quantize_cmd(*c);
		UserCmd qq = proto::quantize_cmd(q);
		assert(q.yaw == d.yaw && q.pitch == d.pitch && qq.yaw == q.yaw && qq.pitch == q.pitch);
	}
	assert(!r.overflowed());
}

fn World* busy_world(Map* m) @local
{
	World* w = world::create(m);
	int a = w.add_player("Pity", 0, false);
	int b = w.add_player("Colo Ñandú con nombre larguísimo", 7, true);
	w.players[a].frags = -3;
	w.players[b].frags = 32000;
	w.players[a].ps.velocity = { 31.5f, -50.25f, 0.001f };
	w.players[b].ps.origin = { 511.0f, -511.0f, 0.25f };
	w.players[b].ps.flags.dead = true;
	w.spawn_rocket(a, { 1, 2, 3 }, { 28, 0, -28 }, true);
	w.items[1].available = false;
	for (int i = 0; i < 70; i++) w.emit(EXPLOSION, (char)a, 255, (char)i, { -511.9f, 0.5f, 3 }, { 0, 1, 0 });
	return w;
}

fn void snapshot_round_trip() @test
{
	Map* m = test_map();
	defer m.free();
	World* w = busy_world(m);
	defer w.free();
	Snapshot s;
	s.from_world(w, 0, 0);
	s.players[1].ping = 65535;
	assert(s.event_count == defs::MAX_EVENTS);

	char[proto::MAX_PACKET] buf;
	BitWriter bw = bitbuf::writer(&buf);
	proto::encode_snapshot(&bw, &s);
	assert(!bw.overflowed());
	Snapshot d;
	BitReader br = bitbuf::reader(buf[:bw.bytes()]);
	assert(proto::decode_snapshot(&br, &d));

	assert(d.tick == s.tick && d.time == s.time && d.phase == s.phase && d.time_left == s.time_left);
	assert(d.fraglimit == s.fraglimit && d.winner == s.winner);
	float pos_err = proto::POS_RANGE / (float)(1 << proto::POS_BITS) + 1e-4f;
	float vel_err = proto::VEL_RANGE / (float)(1 << proto::VEL_BITS) + 1e-4f;
	for (int i = 0; i < defs::MAX_PLAYERS; i++)
	{
		PlayerSnap* a = &s.players[i];
		PlayerSnap* b = &d.players[i];
		assert(a.active == b.active);
		if (!a.active) continue;
		assert(a.name() == b.name() && a.bot == b.bot && a.color == b.color);
		assert(dist(a.origin, b.origin) <= pos_err * 2, "origin %d", i);
		assert(dist(a.velocity, b.velocity) <= vel_err * 2, "velocity %d", i);
		assert((ushort)a.flags == (ushort)b.flags && a.weapon == b.weapon && a.quad == b.quad);
		assert(a.frags == b.frags && a.deaths == b.deaths && a.ping == b.ping);
	}
	assert(d.players[0].frags == -3 && d.players[1].ping == 65535 && d.players[1].flags.dead);
	for (int i = 0; i < defs::MAX_PROJECTILES; i++)
	{
		ProjSnap* a = &s.projectiles[i];
		ProjSnap* b = &d.projectiles[i];
		assert(a.active == b.active);
		if (!a.active) continue;
		assert(a.owner == b.owner && a.quad == b.quad && a.serial == b.serial);
		assert(dist(a.pos, b.pos) <= pos_err * 2 && dist(a.vel, b.vel) <= vel_err * 2);
	}
	assert(d.items == s.items && !d.items[1]);

	// The local section is bit-exact: prediction starts from it.
	LocalSnap* la = &s.local;
	LocalSnap* lb = &d.local;
	assert(lb.slot == 0 && lb.last_cmd == la.last_cmd);
	assert(same(lb.ps.origin, la.ps.origin) && same(lb.ps.velocity, la.ps.velocity));
	assert(lb.ps.yaw == la.ps.yaw && (ushort)lb.ps.flags == (ushort)la.ps.flags);
	assert(lb.health == la.health && lb.armor == la.armor && lb.weapon == la.weapon);
	assert(lb.owned == la.owned && lb.ammo == la.ammo && lb.weapon_time == la.weapon_time);

	assert(d.event_count == s.event_count);
	for (int i = 0; i < d.event_count; i++)
	{
		GameEvent* a = &s.events[i];
		GameEvent* b = &d.events[i];
		assert(a.id == b.id && a.kind == b.kind && a.a == b.a && a.b == b.b && a.c == b.c);
		assert(dist(a.pos, b.pos) <= pos_err * 2 && dist(a.pos2, b.pos2) <= pos_err * 2);
	}
}

fn void snapshot_spectator_and_truncation() @test
{
	Map* m = test_map();
	defer m.free();
	World* w = busy_world(m);
	defer w.free();
	Snapshot s;
	s.from_world(w, -1, 0);
	char[proto::MAX_PACKET] buf;
	BitWriter bw = bitbuf::writer(&buf);
	proto::encode_snapshot(&bw, &s);
	usz full = bw.bytes();

	Snapshot d;
	BitReader ok = bitbuf::reader(buf[:full]);
	assert(proto::decode_snapshot(&ok, &d));
	assert(d.local.slot == defs::NO_PLAYER && d.me() == null);

	// Every truncation is detected, never a crash.
	for (usz len = 0; len < full; len += 7)
	{
		BitReader r = bitbuf::reader(buf[:len]);
		assert(!proto::decode_snapshot(&r, &d), "accepted %d of %d bytes", len, full);
	}

	// Writing into a small buffer flags overflow instead of producing a bad packet.
	char[64] small;
	BitWriter sw = bitbuf::writer(&small);
	proto::encode_snapshot(&sw, &s);
	assert(sw.overflowed());

	// Garbage header.
	char[4] junk = { 0x05, 0xBA, 1, 200 };
	BitReader jr = bitbuf::reader(&junk);
	PacketHeader h;
	assert(!proto::read_header(&jr, &h));
}

fn void reliable_resends_until_acked() @test
{
	Reliable a;
	Reliable b;
	char[512] buf;
	for (int i = 0; i < 6; i++) assert(a.push(i % 2 ? "uno" : "dos"));

	// First packet is "lost": nothing changes, everything is resent.
	BitWriter w = bitbuf::writer(&buf);
	a.write(&w);

	// Next one arrives: 4 per packet, in order.
	w = bitbuf::writer(&buf);
	a.write(&w);
	BitReader r = bitbuf::reader(buf[:w.bytes()]);
	assert(b.read(&r));
	assert(b.inbox_count == 4 && b.in_seq == 4);
	// Duplicate delivery is ignored.
	r = bitbuf::reader(buf[:w.bytes()]);
	assert(b.read(&r));
	assert(b.inbox_count == 4);

	// b acks 4 on its next packet; a sends the remaining 2.
	w = bitbuf::writer(&buf);
	b.write(&w);
	r = bitbuf::reader(buf[:w.bytes()]);
	assert(a.read(&r));
	assert(a.pending() == 2);
	w = bitbuf::writer(&buf);
	a.write(&w);
	r = bitbuf::reader(buf[:w.bytes()]);
	assert(b.read(&r));
	int n;
	while (try text = b.next())
	{
		assert(text == (n % 2 ? "uno" : "dos"), "message %d: %s", n, text);
		n++;
	}
	assert(n == 6);
	assert(@catch(b.next()) == proto::NO_MESSAGE);

	// A full queue refuses instead of overwriting unacked messages.
	Reliable c;
	for (int i = 0; i < proto::RELIABLE_QUEUE; i++) assert(c.push("x"));
	assert(!c.push("y"));
}

// ---------------------------------------------------------------- integration

// Tick hook: adds one bot on the first tick and walks it forward every tick.
struct BotDriver @local
{
	int slot;
	int calls;
	uint seq;
}

fn void drive_bot(World* w, void* ctx) @local
{
	BotDriver* d = ctx;
	if (d.calls++ == 0) d.slot = w.add_player("Bot", 3, true);
	w.run_cmd(d.slot, { .seq = ++d.seq, .yaw = 0, .forward = 127 });
}

fn void prediction_matches_server() @test
{
	Map* m = test_map();
	defer m.free();
	Server* srv = server::start({ .name = "Test" }, m)!!;
	defer srv.stop();
	Client* cl = join(srv, "Fede");
	defer cl.disconnect();
	BotDriver bot;
	srv.set_tick_hook(&drive_bot, &bot);

	int slot = cl.slot;
	Player* p = &srv.world().players[slot];
	Vec3 start = p.ps.origin;
	UserCmd hold = { .yaw = p.ps.yaw + 0.3f, .forward = 127, .side = 40, .weapon = MACHINEGUN };
	const int N = MOVE_CMDS;
	const int LAG = 4;   // the client only reads the network every LAG frames: replays up to LAG cmds
	Vec3[N + 1] pred;
	Vec3[N + 1] seen;
	bool[N + 1] have;
	for (int k = 1; k <= N; k++)
	{
		hold.buttons.jump = k % 40 < 10;
		cl.send_cmd(hold);
		pred[k] = cl.predict(m).origin;
		srv.frame(DT);
		uint applied = p.last_cmd_seq;
		if (applied > 0 && applied <= N)
		{
			seen[applied] = p.ps.origin;
			have[applied] = true;
		}
		if (k % LAG == 0) cl.frame(DT * LAG);
	}
	for (int i = 0; i < 60 && cl.latest().local.last_cmd < N; i++) settle(srv, cl);
	assert(cl.latest().local.last_cmd == N, "server applied %d cmds", cl.latest().local.last_cmd);

	assert(p.last_cmd_seq == N);
	assert(dist(p.ps.origin, start) > 10.0f, "moved only %f m", dist(p.ps.origin, start));
	assert(dist(cl.predict(m).origin, p.ps.origin) < 0.01f);
	int compared;
	for (int k = 1; k <= N; k++)
	{
		if (!have[k]) continue;
		compared++;
		assert(dist(pred[k], seen[k]) < 0.01f, "cmd %d: predicted %s server %s", k, pred[k], seen[k]);
	}
	assert(compared > N / 2, "only %d comparable ticks", compared);
	assert(cl.ping_ms() > 0 && cl.ping_ms() < 200, "ping %d", cl.ping_ms());

	// The hook ran every tick and its bot is replicated.
	assert(bot.calls >= N, "hook calls %d", bot.calls);
	assert(srv.world().players[bot.slot].alive(), "bot slot %d", bot.slot);
	Snapshot* newest = cl.latest();
	assert(newest.players[bot.slot].active && newest.players[bot.slot].bot);

	// Remote entities are shown ~0.1 s (6 ticks) in the past, the local section is the newest.
	Snapshot view;
	assert(cl.interpolated(0.1f, &view));
	assert(view.tick == newest.tick && view.local.ps.origin.x == newest.local.ps.origin.x);
	Snapshot* past = &cl.snaps[(cl.newest - 6 + client::SNAP_HISTORY) % client::SNAP_HISTORY];
	assert(past.tick == newest.tick - 6);
	Vec3 shown = view.players[bot.slot].origin;
	assert(dist(shown, past.players[bot.slot].origin) < 0.01f, "bot shown at %s, 6 ticks ago %s", shown, past.players[bot.slot].origin);
	assert(dist(shown, newest.players[bot.slot].origin) > 0.5f);
}

fn bool has_message(Client* c, String want) @local
{
	bool found;
	while (try text = c.next_message())
	{
		if (text == want) found = true;
	}
	return found;
}

fn void reliable_chat_and_map_change() @test
{
	Map* m = test_map();
	defer m.free();
	Map* m2 = test_map();
	defer m2.free();
	Server* srv = server::start({ .name = "Test", .map_id = "caja" }, m)!!;
	defer srv.stop();
	Client* cl = join(srv, "Fede");
	defer cl.disconnect();
	assert(cl.map_name() == "caja");

	assert(cl.say("hola gente"));
	srv.broadcast_print("bienvenidos");
	bool chat;
	bool print;
	for (int i = 0; i < 30 && !(chat && print); i++)
	{
		settle(srv, cl);
		while (try text = cl.next_message())
		{
			if (text == "chat Fede: hola gente") chat = true;
			if (text == "print bienvenidos") print = true;
		}
	}
	assert(chat && print);

	uint tick_before = cl.latest().tick;
	srv.change_map(m2, "obelisco");
	bool reload;
	for (int i = 0; i < 30 && !reload; i++)
	{
		settle(srv, cl);
		reload = has_message(cl, "map obelisco");
	}
	assert(reload);
	assert(cl.map_name() == "obelisco");
	assert(srv.world().map == m2 && srv.world().player_count() == 1);
	pump(srv, cl, 5);
	assert(cl.latest().tick > tick_before);
	assert(cl.latest().local.slot != defs::NO_PLAYER);
}

fn void full_server_rejects() @test
{
	Map* m = test_map();
	defer m.free();
	Server* srv = server::start({ .max_clients = 1 }, m)!!;
	defer srv.stop();
	Client* a = join(srv, "Uno");
	defer a.disconnect();
	Client* b = dial(srv.port(), "Dos", 1);
	defer b.disconnect();
	for (int i = 0; i < CONNECT_FRAMES && b.state == CONNECTING; i++) settle(srv, b);
	assert(b.state == DISCONNECTED);
	assert(b.reason() == "servidor lleno", "reason: %s", b.reason());
	assert(srv.client_count() == 1);
}

fn void timeouts_and_shutdown() @test
{
	Map* m = test_map();
	defer m.free();
	Server* srv = server::start({}, m)!!;
	Client* cl = join(srv, "Fede");

	// Client goes silent: the server drops it after CLIENT_TIMEOUT, with no frag/death change.
	int ticks = (int)((server::CLIENT_TIMEOUT + 0.5f) * defs::TICK_RATE);
	for (int i = 0; i < ticks; i++) srv.frame(DT);
	assert(srv.client_count() == 0 && srv.world().player_count() == 0);
	// When it wakes up the server tells it to go away.
	for (int i = 0; i < 30 && cl.state == CONNECTED; i++) settle(srv, cl);
	assert(cl.state == DISCONNECTED);
	cl.disconnect();

	// stop() notifies connected clients.
	cl = join(srv, "Otra vez");
	srv.stop();
	for (int i = 0; i < 30 && cl.state == CONNECTED; i++)
	{
		cl.frame(DT);
		thread::sleep_ms(1);
	}
	assert(cl.state == DISCONNECTED, "state %s", cl.state);
	assert(cl.reason() == "el servidor cerro la conexion");
	cl.disconnect();
}

fn void connect_to_nobody_gives_up() @test
{
	UdpSock probe = udp::open(0, false)!!;
	ushort dead = probe.local_port();
	probe.close();
	Client* cl = dial(dead, "Nadie", 0);
	defer cl.disconnect();
	int frames = (int)((client::CONNECT_TIMEOUT + 0.5f) * defs::TICK_RATE);
	for (int i = 0; i < frames && cl.state == CONNECTING; i++) cl.frame(DT);
	assert(cl.state == DISCONNECTED);
	assert(cl.reason().len > 0);
	assert(@catch(client::connect("999.1.1.1", "x", 0)) == udp::BAD_ADDRESS);
}

fn void lan_query_finds_server() @test
{
	Map* m = test_map();
	defer m.free();
	Server* srv = server::start({ .name = "LAN de prueba", .port = defs::DEFAULT_PORT, .max_clients = 8 }, m)!!;
	defer srv.stop();
	UdpSock sock = udp::open(0, true)!!;
	defer sock.close();

	client::lan_query(&sock);
	LanInfo[8] found;
	int count;
	int mine = -1;
	for (int i = 0; i < 100 && mine < 0; i++)
	{
		srv.frame(DT);
		thread::sleep_ms(1);
		count = client::lan_collect(&sock, &found, count);
		for (int k = 0; k < count; k++)
		{
			if (found[k].name_str() == "LAN de prueba") mine = k;
		}
	}
	assert(mine >= 0, "server not found (%d replies)", count);
	LanInfo* e = &found[mine];
	assert(e.map_str() == "Caja de red");
	assert(e.players == 0 && e.max_players == 8);
	assert(e.ping_ms >= 0 && e.ping_ms < 1000);
	@pool()
	{
		assert(e.address_str().ends_with(string::tformat(":%d", srv.port())), "address %s", e.address_str());
		// A second round updates in place instead of duplicating.
		client::lan_query(&sock);
		for (int i = 0; i < 20; i++)
		{
			srv.frame(DT);
			thread::sleep_ms(1);
			count = client::lan_collect(&sock, &found, count);
		}
		int same;
		for (int k = 0; k < count; k++)
		{
			if (found[k].address_str() == e.address_str()) same++;
		}
		assert(same == 1);
	};
}
