// Wire format: packet header, handshake messages, user commands, snapshots and a small
// reliable text channel piggy-backed on CMDS / SNAPSHOT. Pure encode/decode, no sockets.
//
// Every packet: u16 MAGIC, u8 PROTOCOL_VERSION, u8 PacketType, then the payload.
//   INFO_REQUEST  u32 echo (sender's clock, ms)
//   INFO          u32 echo, str name, str map, u8 players, u8 max, str gametype
//   CONNECT       str name, u8 color, u32 nonce
//   ACCEPT        u8 slot, str map, u32 tick, u32 nonce
//   REJECT        str reason
//   CMDS          u32 ack_tick, u32 ack_event, reliable block, 2-bit count, cmds
//   SNAPSHOT      reliable block, snapshot
//   DISCONNECT    (nothing)
// Reliable block: u32 ack (last in-order seq received), 3-bit count, (u32 seq, str text)*.
module arena::proto;
import std::math, arena::defs, arena::world, arena::snap, arena::bitbuf;

faultdef NO_MESSAGE;

const ushort MAGIC = 0xBA05;
const usz MAX_PACKET = 8192;
const usz MAX_TEXT = 200;
const int CMDS_PER_PACKET = 3;
const int RELIABLE_QUEUE = 32;
const int RELIABLE_PER_PACKET = 4;
const String GAMETYPE = "ffa";

// Reliable message verbs: "<verb> <args>".
const String MSG_PRINT = "print ";   // server -> client: console line
const String MSG_CHAT = "chat ";     // server -> client: "name: text"
const String MSG_MAP = "map ";       // server -> client: reload this map (id)
const String MSG_SAY = "say ";       // client -> server: chat line

// Quantization: positions ±512 m in 20 bits (0.5 mm), velocities ±128 m/s in 16 bits (2 mm/s).
const float POS_RANGE = 512.0f;
const int POS_BITS = 20;
const float VEL_RANGE = 128.0f;
const int VEL_BITS = 16;
const int ANGLE_BITS = 16;

const int TYPE_BITS = 8;
const int BUTTON_BITS = 3;
const int WEAPON_BITS = 2;
const int PHASE_BITS = 1;
const int EVENT_KIND_BITS = 4;
const int EVENT_COUNT_BITS = 7;
const int CMD_COUNT_BITS = 2;
const int REL_COUNT_BITS = 3;

$assert Weapon::len <= 1 << WEAPON_BITS;
$assert MatchPhase::len <= 1 << PHASE_BITS;
$assert EventKind::len <= 1 << EVENT_KIND_BITS;
$assert defs::MAX_EVENTS < 1 << EVENT_COUNT_BITS;
$assert CMDS_PER_PACKET < 1 << CMD_COUNT_BITS;
$assert RELIABLE_PER_PACKET < 1 << REL_COUNT_BITS;

enum PacketType : char
{
	INFO_REQUEST,
	INFO,
	CONNECT,
	ACCEPT,
	REJECT,
	CMDS,
	SNAPSHOT,
	DISCONNECT,
}

struct PacketHeader
{
	char version;
	PacketType type;
}

<* Fixed-capacity text for decoded messages (no allocation). *>
struct Text
{
	char[MAX_TEXT] buf;
	usz len;
}

fn String Text.str(&self) => (String)self.buf[:self.len];

fn void Text.set(&self, String s)
{
	self.len = math::min((usz)s.len, MAX_TEXT);
	self.buf[:self.len] = s[:self.len];
}

fn void read_text(BitReader* r, Text* t) => t.len = (usz)r.str(&t.buf).len;

// ---------------------------------------------------------------- header & handshake

fn void begin(BitWriter* w, PacketType type)
{
	w.u16(MAGIC);
	w.u8(defs::PROTOCOL_VERSION);
	w.u8((char)type);
}

<* False when it isn't one of ours. The caller checks `version`. *>
fn bool read_header(BitReader* r, PacketHeader* h)
{
	if (r.u16() != MAGIC) return false;
	h.version = r.u8();
	char type = r.u8();
	if (r.overflowed() || type >= PacketType::len) return false;
	h.type = (PacketType)type;
	return true;
}

struct Info
{
	uint echo;
	Text name;
	Text map;
	char players;
	char max_players;
	Text gametype;
}

fn void write_info(BitWriter* w, Info* m)
{
	begin(w, INFO);
	w.u32(m.echo);
	w.str(m.name.str());
	w.str(m.map.str());
	w.u8(m.players);
	w.u8(m.max_players);
	w.str(m.gametype.str());
}

fn bool read_info(BitReader* r, Info* m)
{
	m.echo = r.u32();
	read_text(r, &m.name);
	read_text(r, &m.map);
	m.players = r.u8();
	m.max_players = r.u8();
	read_text(r, &m.gametype);
	return !r.overflowed();
}

struct Connect
{
	Text name;
	char color;
	uint nonce;
}

fn void write_connect(BitWriter* w, Connect* m)
{
	begin(w, CONNECT);
	w.str(m.name.str());
	w.u8(m.color);
	w.u32(m.nonce);
}

fn bool read_connect(BitReader* r, Connect* m)
{
	read_text(r, &m.name);
	m.color = r.u8();
	m.nonce = r.u32();
	return !r.overflowed();
}

struct Accept
{
	char slot;
	Text map;
	uint tick;
	uint nonce;
}

fn void write_accept(BitWriter* w, Accept* m)
{
	begin(w, ACCEPT);
	w.u8(m.slot);
	w.str(m.map.str());
	w.u32(m.tick);
	w.u32(m.nonce);
}

fn bool read_accept(BitReader* r, Accept* m)
{
	m.slot = r.u8();
	read_text(r, &m.map);
	m.tick = r.u32();
	m.nonce = r.u32();
	return !r.overflowed() && m.slot < defs::MAX_PLAYERS;
}

fn void write_reject(BitWriter* w, String reason)
{
	begin(w, REJECT);
	w.str(reason);
}

// ---------------------------------------------------------------- user commands

fn void encode_cmd(BitWriter* w, UserCmd* c)
{
	w.u32(c.seq);
	w.angle(c.yaw, ANGLE_BITS);
	w.angle(c.pitch, ANGLE_BITS);
	w.u8((char)c.forward);
	w.u8((char)c.side);
	w.bits((char)c.buttons, BUTTON_BITS);
	w.bits((char)c.weapon, WEAPON_BITS);
}

fn UserCmd decode_cmd(BitReader* r)
{
	UserCmd c;
	c.seq = r.u32();
	c.yaw = r.angle(ANGLE_BITS);
	c.pitch = r.angle(ANGLE_BITS);
	c.forward = (ichar)r.u8();
	c.side = (ichar)r.u8();
	c.buttons = (Buttons)(char)r.bits(BUTTON_BITS);
	c.weapon = (Weapon)r.bits(WEAPON_BITS);
	return c;
}

<*
 The command exactly as the server will see it. Prediction must replay this, not the
 full-precision original, or the client drifts from the server.
*>
fn UserCmd quantize_cmd(UserCmd c)
{
	char[32] buf;
	BitWriter w = bitbuf::writer(&buf);
	encode_cmd(&w, &c);
	BitReader r = bitbuf::reader(&buf);
	return decode_cmd(&r);
}

struct Cmds
{
	uint ack_tick;    // newest snapshot tick the client has
	uint ack_event;   // newest event id the client has
	int count;
	UserCmd[CMDS_PER_PACKET] cmds;   // oldest first
}

<*
 @require cmds.len <= CMDS_PER_PACKET
*>
fn void write_cmds(BitWriter* w, uint ack_tick, uint ack_event, Reliable* rel, UserCmd[] cmds)
{
	begin(w, CMDS);
	w.u32(ack_tick);
	w.u32(ack_event);
	rel.write(w);
	w.bits((uint)cmds.len, CMD_COUNT_BITS);
	foreach (&c : cmds) encode_cmd(w, c);
}

fn bool read_cmds(BitReader* r, Cmds* m, Reliable* rel)
{
	m.ack_tick = r.u32();
	m.ack_event = r.u32();
	if (!rel.read(r)) return false;
	m.count = (int)r.bits(CMD_COUNT_BITS);
	if (m.count > CMDS_PER_PACKET) return false;
	for (int i = 0; i < m.count; i++) m.cmds[i] = decode_cmd(r);
	return !r.overflowed();
}

// ---------------------------------------------------------------- snapshots

fn void write_snapshot(BitWriter* w, Reliable* rel, Snapshot* s)
{
	begin(w, SNAPSHOT);
	rel.write(w);
	encode_snapshot(w, s);
}

fn bool read_snapshot(BitReader* r, Reliable* rel, Snapshot* s)
{
	if (!rel.read(r)) return false;
	return decode_snapshot(r, s);
}

fn void write_ps(BitWriter* w, PlayerState* ps) @local
{
	for (int i = 0; i < 3; i++) w.f32(ps.origin[i]);
	for (int i = 0; i < 3; i++) w.f32(ps.velocity[i]);
	w.f32(ps.yaw);
	w.f32(ps.pitch);
	w.u16((ushort)ps.flags);
	w.f32(ps.knockback_time);
}

fn void read_ps(BitReader* r, PlayerState* ps) @local
{
	for (int i = 0; i < 3; i++) ps.origin[i] = r.f32();
	for (int i = 0; i < 3; i++) ps.velocity[i] = r.f32();
	ps.yaw = r.f32();
	ps.pitch = r.f32();
	ps.flags = (PmFlags)r.u16();
	ps.knockback_time = r.f32();
}

fn void write_player(BitWriter* w, PlayerSnap* p) @local
{
	w.flag(p.bot);
	w.str(p.name());
	w.u8(p.color);
	w.vec3(p.origin, POS_RANGE, POS_BITS);
	w.vec3(p.velocity, VEL_RANGE, VEL_BITS);
	w.angle(p.yaw, ANGLE_BITS);
	w.angle(p.pitch, ANGLE_BITS);
	w.u16((ushort)p.flags);
	w.bits((char)p.weapon, WEAPON_BITS);
	w.flag(p.quad);
	w.u16((ushort)p.frags);
	w.u16((ushort)p.deaths);
	w.u16(p.ping);
}

fn void read_player(BitReader* r, PlayerSnap* p) @local
{
	p.active = true;
	p.bot = r.flag();
	p.name_len = (char)r.str(&p.name_buf).len;
	p.color = r.u8();
	p.origin = r.vec3(POS_RANGE, POS_BITS);
	p.velocity = r.vec3(VEL_RANGE, VEL_BITS);
	p.yaw = r.angle(ANGLE_BITS);
	p.pitch = r.angle(ANGLE_BITS);
	p.flags = (PmFlags)r.u16();
	p.weapon = (Weapon)r.bits(WEAPON_BITS);
	p.quad = r.flag();
	p.frags = (short)r.u16();
	p.deaths = (short)r.u16();
	p.ping = r.u16();
}

fn void write_local(BitWriter* w, LocalSnap* l) @local
{
	w.u8(l.slot);
	if (l.slot == defs::NO_PLAYER) return;
	write_ps(w, &l.ps);
	w.u32(l.last_cmd);
	w.u16((ushort)l.health);
	w.u16((ushort)l.armor);
	w.bits((char)l.weapon, WEAPON_BITS);
	for (int k = 0; k < snap::NUM_WEAPONS; k++)
	{
		w.flag(l.owned[k]);
		w.u16((ushort)l.ammo[k]);
	}
	w.f32(l.weapon_time);
	w.f32(l.quad_time);
	w.f32(l.respawn_in);
}

fn bool read_local(BitReader* r, LocalSnap* l) @local
{
	l.slot = r.u8();
	if (l.slot == defs::NO_PLAYER) return true;
	if (l.slot >= defs::MAX_PLAYERS) return false;
	read_ps(r, &l.ps);
	l.last_cmd = r.u32();
	l.health = (short)r.u16();
	l.armor = (short)r.u16();
	l.weapon = (Weapon)r.bits(WEAPON_BITS);
	for (int k = 0; k < snap::NUM_WEAPONS; k++)
	{
		l.owned[k] = r.flag();
		l.ammo[k] = (short)r.u16();
	}
	l.weapon_time = r.f32();
	l.quad_time = r.f32();
	l.respawn_in = r.f32();
	return true;
}

fn void write_event(BitWriter* w, GameEvent* e) @local
{
	w.u32(e.id);
	w.bits((char)e.kind, EVENT_KIND_BITS);
	w.u8(e.a);
	w.u8(e.b);
	w.u8(e.c);
	w.vec3(e.pos, POS_RANGE, POS_BITS);
	w.vec3(e.pos2, POS_RANGE, POS_BITS);
}

fn bool read_event(BitReader* r, GameEvent* e) @local
{
	e.id = r.u32();
	uint kind = r.bits(EVENT_KIND_BITS);
	e.a = r.u8();
	e.b = r.u8();
	e.c = r.u8();
	e.pos = r.vec3(POS_RANGE, POS_BITS);
	e.pos2 = r.vec3(POS_RANGE, POS_BITS);
	if (kind >= EventKind::len) return false;
	e.kind = (EventKind)kind;
	return true;
}

<*
 Full snapshot (no delta compression). Players and projectiles: presence bit + quantized state;
 the local section is exact (raw floats) because prediction replays from it.
*>
fn void encode_snapshot(BitWriter* w, Snapshot* s)
{
	w.u32(s.tick);
	w.f32(s.time);
	w.bits((char)s.phase, PHASE_BITS);
	w.f32(s.time_left);
	w.u16((ushort)s.fraglimit);
	w.u8(s.winner);

	foreach (&p : s.players)
	{
		w.flag(p.active);
		if (p.active) write_player(w, p);
	}
	foreach (&pr : s.projectiles)
	{
		w.flag(pr.active);
		if (!pr.active) continue;
		w.u8(pr.owner);
		w.flag(pr.quad);
		w.u16(pr.serial);
		w.vec3(pr.pos, POS_RANGE, POS_BITS);
		w.vec3(pr.vel, VEL_RANGE, VEL_BITS);
	}
	foreach (available : s.items) w.flag(available);

	write_local(w, &s.local);

	int count = math::clamp(s.event_count, 0, defs::MAX_EVENTS);
	w.bits((uint)count, EVENT_COUNT_BITS);
	for (int i = 0; i < count; i++) write_event(w, &s.events[i]);
}

<* False on truncated or invalid data; `s` is then garbage. *>
fn bool decode_snapshot(BitReader* r, Snapshot* s)
{
	*s = {};
	s.tick = r.u32();
	s.time = r.f32();
	uint phase = r.bits(PHASE_BITS);
	s.time_left = r.f32();
	s.fraglimit = (short)r.u16();
	s.winner = r.u8();
	if (phase >= MatchPhase::len) return false;
	s.phase = (MatchPhase)phase;

	foreach (&p : s.players)
	{
		if (r.flag()) read_player(r, p);
	}
	foreach (&pr : s.projectiles)
	{
		pr.active = r.flag();
		if (!pr.active) continue;
		pr.owner = r.u8();
		pr.quad = r.flag();
		pr.serial = r.u16();
		pr.pos = r.vec3(POS_RANGE, POS_BITS);
		pr.vel = r.vec3(VEL_RANGE, VEL_BITS);
	}
	foreach (&available : s.items) *available = r.flag();

	if (!read_local(r, &s.local)) return false;

	s.event_count = (int)r.bits(EVENT_COUNT_BITS);
	if (s.event_count > defs::MAX_EVENTS) return false;
	for (int i = 0; i < s.event_count; i++)
	{
		if (!read_event(r, &s.events[i])) return false;
	}
	return !r.overflowed();
}

// ---------------------------------------------------------------- reliable channel

<*
 In-order, resend-until-acked text messages for one peer. Every outgoing CMDS / SNAPSHOT
 carries the oldest unacked messages; the peer acks the last in-order seq it delivered.
 Sequence numbers start at 1; 0 means "nothing".
*>
struct Reliable
{
	Text[RELIABLE_QUEUE] out;
	uint out_next;     // seq the next pushed message gets - 1
	uint out_acked;    // peer has everything up to here
	Text[RELIABLE_QUEUE] inbox;
	uint in_seq;       // last in-order seq delivered to the inbox
	int inbox_head;
	int inbox_count;
}

fn int Reliable.pending(&self) => (int)(self.out_next - self.out_acked);

<* Queues a message (truncated to MAX_TEXT). False when the queue is full. *>
fn bool Reliable.push(&self, String text)
{
	if (self.pending() >= RELIABLE_QUEUE) return false;
	self.out_next++;
	self.out[self.out_next % RELIABLE_QUEUE].set(text);
	return true;
}

fn void Reliable.write(&self, BitWriter* w)
{
	w.u32(self.in_seq);
	int count = math::min(self.pending(), RELIABLE_PER_PACKET);
	w.bits((uint)count, REL_COUNT_BITS);
	for (int i = 1; i <= count; i++)
	{
		uint seq = self.out_acked + (uint)i;
		w.u32(seq);
		w.str(self.out[seq % RELIABLE_QUEUE].str());
	}
}

<* Applies the peer's ack and delivers new in-order messages. False on malformed data. *>
fn bool Reliable.read(&self, BitReader* r)
{
	uint ack = r.u32();
	int count = (int)r.bits(REL_COUNT_BITS);
	if (r.overflowed() || count > RELIABLE_PER_PACKET) return false;
	if (ack > self.out_acked && ack <= self.out_next) self.out_acked = ack;
	Text text;
	for (int i = 0; i < count; i++)
	{
		uint seq = r.u32();
		read_text(r, &text);
		if (r.overflowed()) return false;
		// Duplicates and gaps are dropped; a full inbox leaves it unacked (resent later).
		if (seq != self.in_seq + 1 || self.inbox_count == RELIABLE_QUEUE) continue;
		self.in_seq = seq;
		self.inbox[(self.inbox_head + self.inbox_count) % RELIABLE_QUEUE] = text;
		self.inbox_count++;
	}
	return true;
}

<* Next delivered message; the view stays valid until the next read(). *>
fn String? Reliable.next(&self)
{
	if (!self.inbox_count) return NO_MESSAGE~;
	Text* t = &self.inbox[self.inbox_head];
	self.inbox_head = (self.inbox_head + 1) % RELIABLE_QUEUE;
	self.inbox_count--;
	return t.str();
}
