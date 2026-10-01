// Authoritative server: owns the World, runs fixed 60 Hz ticks, talks UDP to clients.
// Per tick: queued client cmds -> tick hook (bots) -> world.step() -> one snapshot per client.
module arena::server;
import std::math, arena::defs, arena::map, arena::world, arena::snap, arena::bitbuf;
import arena::udp, arena::proto;

const float CLIENT_TIMEOUT = 10.0f;
const int MAX_CATCHUP = 5;
const int MAX_CMDS_PER_TICK = 4;
const int CMD_QUEUE = 16;
const int RTT_RING = 64;          // snapshot send times, indexed by tick
const float RTT_SMOOTH = 0.125f;
const int PORT_TRIES = 4;         // requested port + the next 3
const String DEFAULT_NAME = "Baires Arena";

struct ServerConfig
{
	String name;           // shown in the LAN browser ("" = DEFAULT_NAME)
	ushort port;           // 0 = ephemeral
	int max_clients;       // <= 0 or > MAX_PLAYERS: MAX_PLAYERS
	int fraglimit;         // 0 = default, < 0 = none
	int timelimit_min;     // 0 = default, < 0 = none
	String map_id;         // what clients load ("map <id>", ACCEPT); "" = Map.name()
}

alias TickHook = fn void(World* w, void* ctx);

// One connected client.
struct Peer
{
	bool used;
	NetAddr addr;
	uint nonce;
	int slot;
	double last_heard;
	UserCmd[CMD_QUEUE] queue;
	int queued;
	uint last_seq;        // newest cmd seq queued or applied
	uint acked_event;
	uint acked_tick;
	double[RTT_RING] sent_at;
	float rtt;            // seconds, smoothed; < 0 = no sample yet
	Reliable rel;
}

struct Server
{
	Text name;
	Text map_id;
	int max_clients;
	int fraglimit;
	int timelimit_min;
	UdpSock sock;
	Map* map;
	World* sim;           // the World (accessor: world())
	TickHook hook;
	void* hook_ctx;
	double now;
	double acc;
	Peer[defs::MAX_PLAYERS] peers;
	Snapshot snap;
	char[proto::MAX_PACKET] packet;
}

<*
 Creates the world for `m` (borrowed, not freed by the server) and binds UDP: cfg.port, or one
 of the next 3 ports if busy. Release with stop().
*>
fn Server*? start(ServerConfig cfg, Map* m)
{
	UdpSock sock = open_port(cfg.port)!;
	Server* s = mem::new(Server);
	s.sock = sock;
	s.name.set(cfg.name.len ? cfg.name : DEFAULT_NAME);
	s.max_clients = cfg.max_clients <= 0 ? defs::MAX_PLAYERS : math::min(cfg.max_clients, defs::MAX_PLAYERS);
	s.fraglimit = cfg.fraglimit;
	s.timelimit_min = cfg.timelimit_min;
	s.map = m;
	s.sim = s.new_world(m);
	s.map_id.set(cfg.map_id.len ? cfg.map_id : m.name());
	return s;
}

fn UdpSock? open_port(ushort port) @local
{
	if (!port) return udp::open(0, false);
	for (int i = 0; i < PORT_TRIES; i++)
	{
		if (try sock = udp::open(port + (ushort)i, false)) return sock;
	}
	return udp::BIND_FAILED~;
}

fn World* Server.new_world(&self, Map* m)
{
	World* w = world::create(m);
	if (self.fraglimit != 0) w.fraglimit = self.fraglimit < 0 ? int::max : self.fraglimit;
	if (self.timelimit_min != 0) w.timelimit = self.timelimit_min < 0 ? 0 : (float)self.timelimit_min * 60.0f;
	return w;
}

fn void Server.set_tick_hook(&self, TickHook hook, void* ctx)
{
	self.hook = hook;
	self.hook_ctx = ctx;
}

fn World* Server.world(&self) => self.sim;

fn ushort Server.port(&self) => self.sock.local_port();

fn int Server.client_count(&self)
{
	int n;
	foreach (&p : self.peers)
	{
		if (p.used) n++;
	}
	return n;
}

<*
 Receives, then runs as many fixed ticks as `real_dt` covers (at most MAX_CATCHUP).
*>
fn void Server.frame(&self, float real_dt) => @pool()
{
	self.now += real_dt;
	self.receive();
	self.check_timeouts();
	self.acc = math::min(self.acc + real_dt, (double)MAX_CATCHUP * defs::TICK_DT);
	while (self.acc >= defs::TICK_DT)
	{
		self.acc -= defs::TICK_DT;
		self.run_tick();
	}
}

fn void Server.run_tick(&self)
{
	foreach (&p : self.peers)
	{
		if (p.used) self.apply_cmds(p);
	}
	if (self.hook) self.hook(self.sim, self.hook_ctx);
	self.sim.step();
	foreach (&p : self.peers)
	{
		if (p.used) self.send_snapshot(p);
	}
}

fn void Server.apply_cmds(&self, Peer* p)
{
	int n = math::min(p.queued, MAX_CMDS_PER_TICK);
	for (int i = 0; i < n; i++) self.sim.run_cmd(p.slot, p.queue[i]);
	p.queued -= n;
	for (int i = 0; i < p.queued; i++) p.queue[i] = p.queue[i + n];
}

fn void Server.send_snapshot(&self, Peer* p)
{
	Snapshot* s = &self.snap;
	s.from_world(self.sim, p.slot, p.acked_event);
	foreach (&ps : s.players) ps.ping = 0;   // from_world leaves it alone; bots stay at 0
	foreach (&q : self.peers)
	{
		if (q.used) s.players[q.slot].ping = (ushort)(math::max(q.rtt, 0.0f) * 1000.0f);
	}
	BitWriter w = bitbuf::writer(&self.packet);
	proto::write_snapshot(&w, &p.rel, s);
	if (w.overflowed()) return;
	p.sent_at[s.tick % RTT_RING] = self.now;
	(void)self.sock.send(p.addr, self.packet[:w.bytes()]);
}

// ---------------------------------------------------------------- receiving

fn void Server.receive(&self)
{
	NetAddr from;
	while (try n = self.sock.recv(&self.packet, &from))
	{
		BitReader r = bitbuf::reader(self.packet[:n]);
		PacketHeader h;
		if (!proto::read_header(&r, &h)) continue;
		if (h.version != defs::PROTOCOL_VERSION)
		{
			if (h.type == CONNECT) self.reject(from, "version de protocolo incompatible");
			continue;
		}
		switch (h.type)
		{
			case INFO_REQUEST: self.on_info_request(from, &r);
			case CONNECT: self.on_connect(from, &r);
			case CMDS: self.on_cmds(from, &r);
			case DISCONNECT: self.on_disconnect(from);
			default: break;
		}
	}
}

fn Peer* Server.find(&self, NetAddr a)
{
	foreach (&p : self.peers)
	{
		if (p.used && p.addr.equals(a)) return p;
	}
	return null;
}

fn void Server.send_packet(&self, NetAddr to, BitWriter* w)
{
	if (w.overflowed()) return;
	(void)self.sock.send(to, self.packet[:w.bytes()]);
}

fn void Server.reject(&self, NetAddr to, String reason)
{
	BitWriter w = bitbuf::writer(&self.packet);
	proto::write_reject(&w, reason);
	self.send_packet(to, &w);
}

fn void Server.on_info_request(&self, NetAddr from, BitReader* r)
{
	Info info = { .echo = r.u32(), .players = (char)self.sim.player_count(), .max_players = (char)self.max_clients };
	if (r.overflowed()) return;
	info.name = self.name;
	info.map.set(self.map.name());
	info.gametype.set(proto::GAMETYPE);
	BitWriter w = bitbuf::writer(&self.packet);
	proto::write_info(&w, &info);
	self.send_packet(from, &w);
}

fn void Server.on_connect(&self, NetAddr from, BitReader* r)
{
	Connect msg;
	if (!proto::read_connect(r, &msg)) return;
	Peer* p = self.find(from);
	if (p && p.nonce == msg.nonce)
	{
		self.send_accept(p);   // our ACCEPT got lost
		return;
	}
	if (p) self.drop(p, "se reconecto");
	if (self.client_count() >= self.max_clients)
	{
		self.reject(from, "servidor lleno");
		return;
	}
	String name = msg.name.str().len ? msg.name.str() : "Jugador";
	int slot = self.sim.add_player(name, msg.color % (char)PlayerColor::len, false);
	if (slot < 0)
	{
		self.reject(from, "servidor lleno");
		return;
	}
	foreach (&q : self.peers)
	{
		if (q.used) continue;
		*q = { .used = true, .addr = from, .nonce = msg.nonce, .slot = slot, .last_heard = self.now, .rtt = -1 };
		// A new client doesn't want the backlog of old events.
		q.acked_event = self.sim.next_event - 1;
		self.send_accept(q);
		self.broadcast_print(string::tformat("%s entro al juego", self.sim.players[slot].name()));
		return;
	}
	self.sim.remove_player(slot);
	self.reject(from, "servidor lleno");
}

fn void Server.send_accept(&self, Peer* p)
{
	Accept msg = { .slot = (char)p.slot, .tick = self.sim.tick, .nonce = p.nonce };
	msg.map = self.map_id;
	BitWriter w = bitbuf::writer(&self.packet);
	proto::write_accept(&w, &msg);
	self.send_packet(p.addr, &w);
}

fn void Server.on_cmds(&self, NetAddr from, BitReader* r)
{
	Peer* p = self.find(from);
	if (!p)
	{
		// Stale client (server restarted?): tell it to go away.
		BitWriter w = bitbuf::writer(&self.packet);
		proto::begin(&w, DISCONNECT);
		self.send_packet(from, &w);
		return;
	}
	Cmds msg;
	if (!proto::read_cmds(r, &msg, &p.rel)) return;
	p.last_heard = self.now;
	if (msg.ack_event > p.acked_event && msg.ack_event < self.sim.next_event) p.acked_event = msg.ack_event;
	self.measure_rtt(p, msg.ack_tick);
	for (int i = 0; i < msg.count; i++) p.enqueue(msg.cmds[i]);
	while (try text = p.rel.next()) self.on_client_text(p, text);
}

fn void Peer.enqueue(&self, UserCmd c)
{
	if (c.seq <= self.last_seq) return;
	self.last_seq = c.seq;
	if (self.queued == CMD_QUEUE)
	{
		// Client runs too fast or we stalled: drop the oldest.
		self.queued--;
		for (int i = 0; i < self.queued; i++) self.queue[i] = self.queue[i + 1];
	}
	self.queue[self.queued++] = c;
}

fn void Server.measure_rtt(&self, Peer* p, uint tick)
{
	uint now_tick = self.sim.tick;
	if (tick <= p.acked_tick || tick > now_tick || now_tick - tick >= RTT_RING) return;
	p.acked_tick = tick;
	float sample = (float)(self.now - p.sent_at[tick % RTT_RING]);
	p.rtt = p.rtt < 0 ? sample : p.rtt + (sample - p.rtt) * RTT_SMOOTH;
}

fn void Server.on_client_text(&self, Peer* p, String text)
{
	if (!text.starts_with(proto::MSG_SAY)) return;
	String line = text[proto::MSG_SAY.len..];
	String who = self.sim.players[p.slot].name();
	self.broadcast(string::tformat("%s%s: %s", proto::MSG_CHAT, who, line));
}

fn void Server.on_disconnect(&self, NetAddr from)
{
	Peer* p = self.find(from);
	if (p) self.drop(p, "se fue");
}

<* Removes the player without a DEATH (no frag change) and tells everybody. *>
fn void Server.drop(&self, Peer* p, String why)
{
	String msg = string::tformat("%s %s", self.sim.players[p.slot].name(), why);
	self.sim.remove_player(p.slot);
	p.used = false;
	self.broadcast_print(msg);
}

fn void Server.check_timeouts(&self)
{
	foreach (&p : self.peers)
	{
		if (p.used && self.now - p.last_heard > CLIENT_TIMEOUT) self.drop(p, "se desconecto (timeout)");
	}
}

// ---------------------------------------------------------------- messages & lifecycle

fn void Server.broadcast(&self, String text)
{
	foreach (&p : self.peers)
	{
		if (p.used) p.rel.push(text);
	}
}

<* Reliable console line for every client ("print <text>"). *>
fn void Server.broadcast_print(&self, String text) => @pool()
{
	self.broadcast(string::tformat("%s%s", proto::MSG_PRINT, text));
}

<*
 Switches map keeping connections: rebuilds the world, re-adds every client's player and
 sends a reliable "map <id>" so clients reload. Tick and event ids keep counting (clients
 drop older ticks and dedupe events by id). Bots are not carried over: re-add them.
 `new_map` is borrowed; the old one is not freed.
*>
fn void Server.change_map(&self, Map* new_map, String map_id = "") => @pool()
{
	World* old = self.sim;
	World* w = self.new_world(new_map);
	w.tick = old.tick;
	w.events = old.events;
	w.next_event = old.next_event;
	self.map = new_map;
	self.sim = w;
	self.map_id.set(map_id.len ? map_id : new_map.name());
	foreach (&p : self.peers)
	{
		if (!p.used) continue;
		Player* was = &old.players[p.slot];
		int slot = w.add_player(was.name(), was.color, false);
		if (slot < 0)
		{
			p.used = false;
			continue;
		}
		w.players[slot].last_cmd_seq = was.last_cmd_seq;
		p.slot = slot;
		p.queued = 0;
		p.rel.push(string::tformat("%s%s", proto::MSG_MAP, self.map_id.str()));
	}
	old.free();
	self.broadcast_print(string::tformat("mapa: %s", new_map.name()));
}

<* Tells clients we're leaving, then frees everything (the Map stays with the caller). *>
fn void Server.stop(&self)
{
	BitWriter w = bitbuf::writer(&self.packet);
	proto::begin(&w, DISCONNECT);
	foreach (&p : self.peers)
	{
		if (p.used) self.send_packet(p.addr, &w);
	}
	self.sock.close();
	self.sim.free();
	free(self);
}
