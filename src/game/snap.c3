// Snapshot: everything a client needs to draw one tick. The common currency between the
// server (builds it from World), the network (encodes it) and the client (render, HUD, sound).
module arena::snap;
import std::math, arena::mathx, arena::defs, arena::world;

const int NAME_LEN = world::MAX_NAME;
const int NUM_WEAPONS = world::NUM_WEAPONS;

struct PlayerSnap
{
	bool active;
	bool bot;
	char[NAME_LEN] name_buf;
	char name_len;
	char color;
	Vec3 origin;
	Vec3 velocity;
	float yaw;
	float pitch;
	PmFlags flags;
	Weapon weapon;
	bool quad;
	short frags;
	short deaths;
	ushort ping;   // ms, filled by the server
}

struct ProjSnap
{
	bool active;
	char owner;
	bool quad;
	ushort serial;
	Vec3 pos;
	Vec3 vel;
}

// Private state of the player this snapshot is for.
struct LocalSnap
{
	char slot;
	PlayerState ps;
	uint last_cmd;       // last command the server applied (prediction replays the rest)
	short health;
	short armor;
	Weapon weapon;
	bool[NUM_WEAPONS] owned;
	short[NUM_WEAPONS] ammo;
	float weapon_time;
	float quad_time;
	float respawn_in;    // seconds until respawn is allowed (dead only)
}

struct Snapshot
{
	uint tick;
	float time;
	MatchPhase phase;
	float time_left;
	short fraglimit;
	char winner;
	PlayerSnap[defs::MAX_PLAYERS] players;
	ProjSnap[defs::MAX_PROJECTILES] projectiles;
	bool[defs::MAX_ITEMS] items;
	LocalSnap local;
	GameEvent[defs::MAX_EVENTS] events;   // events newer than the client's last acked id
	int event_count;
}

fn String PlayerSnap.name(&self) => (String)self.name_buf[:self.name_len];

fn bool PlayerSnap.alive(&self) => self.active && !self.flags.dead;

fn Vec3 PlayerSnap.eye(&self) => self.origin + (Vec3){ 0, defs::EYE_HEIGHT, 0 };

<*
 Fills `s` from the authoritative world for player `slot` (-1 = spectator / no local player),
 including events with id > `events_after`.
*>
fn void Snapshot.from_world(&self, World* w, int slot, uint events_after)
{
	self.tick = w.tick;
	self.time = w.time;
	self.phase = w.phase;
	self.time_left = w.time_left();
	self.fraglimit = (short)w.fraglimit;
	self.winner = w.winner;

	for (int i = 0; i < defs::MAX_PLAYERS; i++)
	{
		Player* p = &w.players[i];
		PlayerSnap* s = &self.players[i];
		s.active = p.active;
		if (!p.active) continue;
		s.bot = p.is_bot;
		s.name_len = (char)p.name_len;
		s.name_buf[:p.name_len] = p.name_buf[:p.name_len];
		s.color = p.color;
		s.origin = p.ps.origin;
		s.velocity = p.ps.velocity;
		s.yaw = p.ps.yaw;
		s.pitch = p.ps.pitch;
		s.flags = p.ps.flags;
		s.weapon = p.weapon;
		s.quad = p.quad_time > 0;
		s.frags = (short)p.frags;
		s.deaths = (short)p.deaths;
	}

	foreach (i, &pr : w.projectiles)
	{
		self.projectiles[i] = { pr.active, pr.owner, pr.quad, pr.serial, pr.pos, pr.vel };
	}
	for (int i = 0; i < defs::MAX_ITEMS; i++) self.items[i] = w.items[i].available;

	self.event_count = 0;
	w.@events_since(events_after; GameEvent* e)
	{
		if (self.event_count < defs::MAX_EVENTS) self.events[self.event_count++] = *e;
	};

	self.local = {};
	self.local.slot = slot < 0 ? defs::NO_PLAYER : (char)slot;
	if (slot < 0) return;
	Player* p = &w.players[slot];
	LocalSnap* l = &self.local;
	l.ps = p.ps;
	l.last_cmd = p.last_cmd_seq;
	l.health = (short)p.health;
	l.armor = (short)p.armor;
	l.weapon = p.weapon;
	for (int k = 0; k < NUM_WEAPONS; k++)
	{
		l.owned[k] = p.owned[k];
		l.ammo[k] = (short)p.ammo[k];
	}
	l.weapon_time = p.weapon_time;
	l.quad_time = p.quad_time;
	l.respawn_in = p.ps.flags.dead ? math::max(p.respawn_time - w.time, 0.0f) : 0.0f;
}

<*
 out = b, with players and projectiles moved `t` of the way from a to b. Entities that
 teleported/respawned (teleport bit flipped) or were replaced (serial changed) snap to b.
*>
fn void lerp(Snapshot* a, Snapshot* b, float t, Snapshot* out)
{
	*out = *b;
	for (int i = 0; i < defs::MAX_PLAYERS; i++)
	{
		PlayerSnap* pa = &a.players[i];
		PlayerSnap* pb = &b.players[i];
		if (!pa.active || !pb.active || pa.flags.teleport_bit != pb.flags.teleport_bit) continue;
		PlayerSnap* o = &out.players[i];
		o.origin = pa.origin + (pb.origin - pa.origin) * t;
		o.velocity = pa.velocity + (pb.velocity - pa.velocity) * t;
		o.yaw = pa.yaw + mathx::wrap_angle(pb.yaw - pa.yaw) * t;
		o.pitch = pa.pitch + (pb.pitch - pa.pitch) * t;
	}
	for (int i = 0; i < defs::MAX_PROJECTILES; i++)
	{
		ProjSnap* qa = &a.projectiles[i];
		ProjSnap* qb = &b.projectiles[i];
		if (!qa.active || !qb.active || qa.serial != qb.serial) continue;
		out.projectiles[i].pos = qa.pos + (qb.pos - qa.pos) * t;
	}
	if (a.local.ps.flags.teleport_bit == b.local.ps.flags.teleport_bit)
	{
		out.local.ps.origin = a.local.ps.origin + (b.local.ps.origin - a.local.ps.origin) * t;
	}
}

fn PlayerSnap* Snapshot.me(&self)
{
	if (self.local.slot == defs::NO_PLAYER) return null;
	return &self.players[self.local.slot];
}
