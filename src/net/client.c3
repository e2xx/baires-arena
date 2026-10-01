// Client side of the netcode: handshake, cmd upload, snapshot history, prediction,
// interpolation, reliable text inbox and LAN server discovery.
module arena::client;
import std::math, std::time, arena::mathx, arena::defs, arena::map, arena::snap, arena::pmove;
import arena::bitbuf, arena::udp, arena::proto;

const float CONNECT_RESEND = 0.5f;
const float CONNECT_TIMEOUT = 10.0f;
const float SERVER_TIMEOUT = 10.0f;
const float KEEPALIVE = 0.25f;     // send CMDS (acks) at least this often even without input
const int CMD_RING = 128;
const int SNAP_HISTORY = 12;       // 0.2 s at 60 Hz: room for a 0.1 s interpolation delay + loss
const int LAN_PORTS = 4;           // DEFAULT_PORT .. DEFAULT_PORT + 3
const usz LAN_PACKET = 1024;

enum ClientState : char
{
	DISCONNECTED,
	CONNECTING,
	CONNECTED,
}

struct Client
{
	ClientState state;
	UdpSock sock;
	NetAddr server;
	Text name;
	char color;
	uint nonce;
	Text map;            // id from ACCEPT, updated by "map <id>" messages
	Text why;            // why we ended up DISCONNECTED (accessor: reason())
	int slot;            // from ACCEPT; -1 before

	float now;
	float started;
	float last_connect;
	float last_heard;
	float last_sent;

	uint cmd_seq;
	UserCmd[CMD_RING] cmds;   // quantized, indexed by seq

	Snapshot[SNAP_HISTORY] snaps;
	float[SNAP_HISTORY] arrived;
	int newest;
	int snap_count;
	uint last_event;

	Reliable rel;
	Snapshot scratch;
	char[proto::MAX_PACKET] packet;
}

<*
 Starts connecting to "host[:port]" (default port DEFAULT_PORT). Poll frame() and watch
 `state`; on REJECT or timeout it becomes DISCONNECTED with `reason()`. Free with disconnect().
*>
fn Client*? connect(String address, String name, char color)
{
	NetAddr addr = udp::parse_addr(address, defs::DEFAULT_PORT)!;
	UdpSock sock = udp::open(0, false)!;
	Client* c = mem::new(Client);
	c.sock = sock;
	c.server = addr;
	c.name.set(name);
	c.color = color;
	c.nonce = (uint)((ulong)clock::now() >> 10) ^ (uint)sock.local_port() << 16;
	c.slot = -1;
	c.state = CONNECTING;
	c.send_connect();
	return c;
}

fn String Client.map_name(&self) => self.map.str();

fn String Client.reason(&self) => self.why.str();

fn void Client.fail(&self, String why)
{
	self.state = DISCONNECTED;
	self.why.set(why);
}

fn void Client.frame(&self, float dt)
{
	self.now += dt;
	self.receive();
	switch (self.state)
	{
		case CONNECTING:
			if (self.now - self.started > CONNECT_TIMEOUT)
			{
				self.fail("el servidor no responde");
				return;
			}
			if (self.now - self.last_connect >= CONNECT_RESEND) self.send_connect();
		case CONNECTED:
			if (self.now - self.last_heard > SERVER_TIMEOUT)
			{
				self.fail("se perdio la conexion (timeout)");
				return;
			}
			if (self.now - self.last_sent >= KEEPALIVE) self.send_cmds();
		case DISCONNECTED:
			break;
	}
}

// ---------------------------------------------------------------- sending

fn void Client.send(&self, BitWriter* w)
{
	if (w.overflowed()) return;
	(void)self.sock.send(self.server, self.packet[:w.bytes()]);
	self.last_sent = self.now;
}

fn void Client.send_connect(&self)
{
	Connect msg = { .name = self.name, .color = self.color, .nonce = self.nonce };
	BitWriter w = bitbuf::writer(&self.packet);
	proto::write_connect(&w, &msg);
	self.send(&w);
	self.last_connect = self.now;
}

<*
 Queues one tick of input: the client assigns `seq`, keeps the quantized cmd for prediction
 and sends it with the two previous ones (loss redundancy) plus acks.
*>
fn void Client.send_cmd(&self, UserCmd cmd)
{
	if (self.state != CONNECTED) return;
	cmd.seq = ++self.cmd_seq;
	self.cmds[cmd.seq % CMD_RING] = proto::quantize_cmd(cmd);
	self.send_cmds();
}

fn void Client.send_cmds(&self)
{
	UserCmd[proto::CMDS_PER_PACKET] recent;
	uint count = math::min(self.cmd_seq, (uint)proto::CMDS_PER_PACKET);
	for (uint i = 0; i < count; i++) recent[i] = self.cmds[(self.cmd_seq - count + 1 + i) % CMD_RING];
	Snapshot* s = self.latest();
	uint ack_tick = s ? s.tick : 0;
	BitWriter w = bitbuf::writer(&self.packet);
	proto::write_cmds(&w, ack_tick, self.last_event, &self.rel, recent[:count]);
	self.send(&w);
}

<* Queues a chat line ("say <text>"); the server relays it to everybody. *>
fn bool Client.say(&self, String text) => @pool()
{
	return self.rel.push(string::tformat("%s%s", proto::MSG_SAY, text));
}

// ---------------------------------------------------------------- receiving

fn void Client.receive(&self)
{
	NetAddr from;
	while (try n = self.sock.recv(&self.packet, &from))
	{
		if (!from.equals(self.server)) continue;
		BitReader r = bitbuf::reader(self.packet[:n]);
		PacketHeader h;
		if (!proto::read_header(&r, &h)) continue;
		// REJECT is version-proof so an old/new server can say why.
		if (h.type == REJECT)
		{
			self.on_reject(&r);
			continue;
		}
		if (h.version != defs::PROTOCOL_VERSION) continue;
		switch (h.type)
		{
			case ACCEPT: self.on_accept(&r);
			case SNAPSHOT: self.on_snapshot(&r);
			case DISCONNECT:
				if (self.state != DISCONNECTED) self.fail("el servidor cerro la conexion");
			default: break;
		}
	}
}

fn void Client.on_reject(&self, BitReader* r)
{
	if (self.state != CONNECTING) return;
	Text why;
	proto::read_text(r, &why);
	self.fail(why.len ? why.str() : "rechazado");
}

fn void Client.on_accept(&self, BitReader* r)
{
	Accept msg;
	if (self.state != CONNECTING || !proto::read_accept(r, &msg) || msg.nonce != self.nonce) return;
	self.state = CONNECTED;
	self.slot = msg.slot;
	self.map = msg.map;
	self.last_heard = self.now;
	self.send_cmds();
}

fn void Client.on_snapshot(&self, BitReader* r)
{
	if (self.state != CONNECTED) return;
	Snapshot* s = &self.scratch;
	if (!proto::read_snapshot(r, &self.rel, s)) return;
	self.last_heard = self.now;
	for (int i = 0; i < s.event_count; i++) self.last_event = math::max(self.last_event, s.events[i].id);
	Snapshot* newest = self.latest();
	if (newest && s.tick <= newest.tick) return;   // late or duplicate
	self.newest = (self.newest + 1) % SNAP_HISTORY;
	self.snaps[self.newest] = *s;
	self.arrived[self.newest] = self.now;
	self.snap_count = math::min(self.snap_count + 1, SNAP_HISTORY);
	if (s.local.slot != defs::NO_PLAYER) self.slot = s.local.slot;
}

<*
 Next reliable message from the server ("print …", "chat …", "map <id>"). The view is valid
 until the next frame().
*>
fn String? Client.next_message(&self)
{
	String text = self.rel.next()!;
	if (text.starts_with(proto::MSG_MAP)) self.map.set(text[proto::MSG_MAP.len..]);
	return text;
}

// ---------------------------------------------------------------- game state

fn Snapshot* Client.latest(&self)
{
	if (!self.snap_count) return null;
	return &self.snaps[self.newest];
}

fn int Client.ping_ms(&self)
{
	Snapshot* s = self.latest();
	if (!s || s.local.slot == defs::NO_PLAYER) return 0;
	return s.players[s.local.slot].ping;
}

<*
 Our player now: the newest snapshot's exact state, then every command the server hasn't
 applied yet, replayed through the same pmove the server runs.
*>
fn PlayerState Client.predict(&self, Map* m)
{
	Snapshot* s = self.latest();
	if (!s || s.local.slot == defs::NO_PLAYER) return {};
	PlayerState ps = s.local.ps;
	uint first = s.local.last_cmd + 1;
	if (self.cmd_seq >= CMD_RING) first = math::max(first, self.cmd_seq - CMD_RING + 1);
	for (uint seq = first; seq <= self.cmd_seq; seq++)
	{
		pmove::move(&ps, self.cmds[seq % CMD_RING], m, defs::TICK_DT);
	}
	return ps;
}

<*
 Copy of the newest snapshot with other players and projectiles moved `delay` seconds into
 the past, interpolated between the two snapshots around that time (0.1 s is a good delay).
 The local section and our own player entry stay as in the newest. False before the first
 snapshot.
*>
fn bool Client.interpolated(&self, float delay, Snapshot* out)
{
	Snapshot* newest = self.latest();
	if (!newest) return false;
	*out = *newest;
	double age = (double)self.now - self.arrived[self.newest];
	double target = (double)newest.tick + (age - delay) * defs::TICK_RATE;
	if (target >= (double)newest.tick) return true;

	Snapshot* b = newest;
	for (int k = 1; k < self.snap_count; k++)
	{
		Snapshot* a = &self.snaps[(self.newest - k + SNAP_HISTORY) % SNAP_HISTORY];
		if ((double)a.tick > target)
		{
			b = a;
			continue;
		}
		float t = (float)((target - (double)a.tick) / (double)(b.tick - a.tick));
		blend(out, a, b, t);
		return true;
	}
	blend(out, b, b, 0);   // older than everything we kept: show the oldest
	return true;
}

fn float lerp_angle(float a, float b, float t) @local => a + mathx::wrap_angle(b - a) * t;

fn void blend(Snapshot* out, Snapshot* a, Snapshot* b, float t) @local
{
	for (int i = 0; i < defs::MAX_PLAYERS; i++)
	{
		if (i == (int)out.local.slot) continue;
		PlayerSnap* pa = &a.players[i];
		PlayerSnap* pb = &b.players[i];
		PlayerSnap* o = &out.players[i];
		*o = *pb;
		if (!pa.active || !pb.active || pa.flags.teleport_bit != pb.flags.teleport_bit) continue;
		o.origin = pa.origin + (pb.origin - pa.origin) * t;
		o.velocity = pa.velocity + (pb.velocity - pa.velocity) * t;
		o.yaw = lerp_angle(pa.yaw, pb.yaw, t);
		o.pitch = pa.pitch + (pb.pitch - pa.pitch) * t;
	}
	for (int i = 0; i < defs::MAX_PROJECTILES; i++)
	{
		ProjSnap* pa = &a.projectiles[i];
		ProjSnap* pb = &b.projectiles[i];
		out.projectiles[i] = *pb;
		if (!pa.active || !pb.active || pa.serial != pb.serial) continue;
		out.projectiles[i].pos = pa.pos + (pb.pos - pa.pos) * t;
	}
}

<* Sends DISCONNECT (if we may still be on the server) and frees the client. *>
fn void Client.disconnect(&self)
{
	if (self.state != DISCONNECTED)
	{
		BitWriter w = bitbuf::writer(&self.packet);
		proto::begin(&w, DISCONNECT);
		self.send(&w);
		self.send(&w);   // cheap insurance against one lost datagram
	}
	self.sock.close();
	free(self);
}

// ---------------------------------------------------------------- LAN discovery

struct LanInfo
{
	char[48] name;      // zero-terminated
	char[24] map;
	char[24] address;   // "a.b.c.d:port", what connect() takes
	int players;
	int max_players;
	int ping_ms;
}

fn String LanInfo.name_str(&self) => ((ZString)&self.name).str_view();

fn String LanInfo.map_str(&self) => ((ZString)&self.map).str_view();

fn String LanInfo.address_str(&self) => ((ZString)&self.address).str_view();

fn uint clock_ms() @local => (uint)((ulong)clock::now() / 1_000_000);

fn void copy_z(char[] dst, String s) @local
{
	usz n = math::min((usz)s.len, (usz)dst.len - 1);
	dst[..] = 0;
	dst[:n] = s[:n];
}

<*
 Broadcasts INFO_REQUEST to DEFAULT_PORT..DEFAULT_PORT+3. `sock` must allow broadcast.
*>
fn void lan_query(UdpSock* sock)
{
	char[16] buf;
	BitWriter w = bitbuf::writer(&buf);
	proto::begin(&w, INFO_REQUEST);
	w.u32(clock_ms());
	for (int i = 0; i < LAN_PORTS; i++)
	{
		(void)sock.send(udp::broadcast(defs::DEFAULT_PORT + (ushort)i), buf[:w.bytes()]);
	}
}

<*
 Drains INFO replies into out[0..count), updating entries with the same address and appending
 new ones while there is room. Returns the new count.
*>
fn int lan_collect(UdpSock* sock, LanInfo[] out, int count) => @pool()
{
	char[LAN_PACKET] buf;
	NetAddr from;
	while (try n = sock.recv(&buf, &from))
	{
		BitReader r = bitbuf::reader(buf[:n]);
		PacketHeader h;
		if (!proto::read_header(&r, &h) || h.version != defs::PROTOCOL_VERSION || h.type != INFO) continue;
		Info info;
		if (!proto::read_info(&r, &info)) continue;
		String addr = from.tstr();
		int slot = count;
		for (int i = 0; i < count; i++)
		{
			if (out[i].address_str() == addr) slot = i;
		}
		if (slot == out.len) continue;
		if (slot == count) count++;
		LanInfo* e = &out[slot];
		copy_z(&e.name, info.name.str());
		copy_z(&e.map, info.map.str());
		copy_z(&e.address, addr);
		e.players = info.players;
		e.max_players = info.max_players;
		e.ping_ms = (int)(clock_ms() - info.echo);
	}
	return count;
}
