// Authoritative game simulation. Runs on the server (or locally in offline mode).
module arena::world;
import std::math, arena::mathx, arena::defs, arena::map, arena::pmove;

const int NUM_WEAPONS = Weapon::len;
const float MAX_SHOT_RANGE = 300.0f;
const float ROCKET_LIFE = 10.0f;
const float ROCKET_HIT_PAD = 0.15f;
const float AUTO_RESPAWN_TIME = 5.0f;
const float PAIN_INTERVAL = 0.35f;
const float WEAPON_SWITCH_TIME = 0.25f;
const float ITEM_REACH = 0.9f;
const float ITEM_HEIGHT = 1.2f;
const float MUZZLE_FORWARD = 0.6f;
const float DECAY_INTERVAL = 1.0f;
const int MAX_NAME = 24;

enum MatchPhase : char
{
	PLAYING,
	INTERMISSION,
}

struct Player
{
	bool active;
	bool is_bot;
	char[MAX_NAME] name_buf;
	usz name_len;
	char color;
	PlayerState ps;
	uint last_cmd_seq;
	Buttons last_buttons;
	int health;
	int armor;
	Weapon weapon;
	bool[NUM_WEAPONS] owned;
	int[NUM_WEAPONS] ammo;
	float weapon_time;
	float quad_time;
	float respawn_time;
	float pain_time;
	float decay_time;
	int frags;
	int deaths;
}

struct Projectile
{
	bool active;
	char owner;
	bool quad;
	ushort serial;   // changes on every spawn so clients don't interpolate across reuse
	Vec3 pos;
	Vec3 vel;
	float life;
}

struct ItemState
{
	bool available;
	float respawn_at;
}

struct World
{
	Map* map;
	Player[defs::MAX_PLAYERS] players;
	Projectile[defs::MAX_PROJECTILES] projectiles;
	ushort projectile_serial;
	ItemState[defs::MAX_ITEMS] items;

	uint tick;
	float time;
	MatchPhase phase;
	float phase_end;
	float match_start;
	int fraglimit;
	float timelimit;   // seconds, 0 = none
	char winner;

	GameEvent[defs::MAX_EVENTS] events;
	uint next_event;   // id of the next event to emit (ids start at 1)
	Rng rng;
}

fn String Player.name(&self) => (String)self.name_buf[:self.name_len];

fn bool Player.alive(&self) => self.active && !self.ps.flags.dead;

fn Vec3 Player.eye(&self) => self.ps.origin + (Vec3){ 0, defs::EYE_HEIGHT, 0 };

fn Aabb Player.hitbox(&self) => { self.ps.origin + defs::PLAYER_MINS, self.ps.origin + defs::PLAYER_MAXS };

fn World* create(Map* m)
{
	World* w = mem::new(World);
	w.map = m;
	w.fraglimit = defs::DEFAULT_FRAGLIMIT;
	w.timelimit = (float)defs::DEFAULT_TIMELIMIT_MIN * 60.0f;
	w.next_event = 1;
	w.rng = mathx::rng(0xBA05);
	w.restart_match();
	return w;
}

fn void World.free(&self) => free(self);

// ---------------------------------------------------------------- events

fn void World.emit(&self, EventKind kind, char a = 0, char b = 0, char c = 0, Vec3 pos = {}, Vec3 pos2 = {})
{
	uint id = self.next_event++;
	self.events[id % defs::MAX_EVENTS] = { id, kind, a, b, c, pos, pos2 };
}

<*
 Events with id > after that are still in the ring, oldest first.
*>
macro void World.@events_since(&self, uint after; @body(GameEvent* e))
{
	uint first = self.next_event > defs::MAX_EVENTS ? self.next_event - defs::MAX_EVENTS : 1;
	if (after + 1 > first) first = after + 1;
	for (uint id = first; id < self.next_event; id++)
	{
		@body(&self.events[id % defs::MAX_EVENTS]);
	}
}

// ---------------------------------------------------------------- players

fn int World.add_player(&self, String name, char color, bool bot)
{
	for (int i = 0; i < defs::MAX_PLAYERS; i++)
	{
		Player* p = &self.players[i];
		if (p.active) continue;
		*p = {};
		p.active = true;
		p.is_bot = bot;
		p.color = color;
		p.set_name(name);
		self.spawn(i);
		return i;
	}
	return -1;
}

fn void Player.set_name(&self, String name)
{
	self.name_len = name.len < MAX_NAME ? name.len : MAX_NAME;
	self.name_buf[:self.name_len] = name[:self.name_len];
}

fn void World.remove_player(&self, int slot)
{
	self.players[slot].active = false;
	foreach (&pr : self.projectiles)
	{
		if (pr.active && pr.owner == (char)slot) pr.active = false;
	}
}

fn int World.player_count(&self)
{
	int n;
	foreach (&p : self.players)
	{
		if (p.active) n++;
	}
	return n;
}

<*
 Picks a free spawn far from living opponents (random among the farthest half, like Q3).
*>
fn Spawn World.pick_spawn(&self, int slot)
{
	Map* m = self.map;
	float[map::MAX_SPAWNS] score;
	int[map::MAX_SPAWNS] order;
	int n = m.spawn_count;
	for (int s = 0; s < n; s++)
	{
		order[s] = s;
		score[s] = 1e9f;
		for (int i = 0; i < defs::MAX_PLAYERS; i++)
		{
			Player* p = &self.players[i];
			if (i == slot || !p.alive()) continue;
			score[s] = math::min(score[s], (p.ps.origin - m.spawns[s].pos).length());
		}
	}
	// Insertion sort by distance, farthest first.
	for (int i = 1; i < n; i++)
	{
		int k = order[i];
		int j = i - 1;
		while (j >= 0 && score[order[j]] < score[k])
		{
			order[j + 1] = order[j];
			j--;
		}
		order[j + 1] = k;
	}
	int half = math::max(1, n / 2);
	return m.spawns[order[self.rng.range(half)]];
}

fn void World.spawn(&self, int slot)
{
	Player* p = &self.players[slot];
	Spawn s = self.pick_spawn(slot);
	bool bit = p.ps.flags.teleport_bit;
	p.ps = { .origin = s.pos, .yaw = s.yaw };
	p.ps.flags.teleport_bit = !bit;
	p.health = defs::SPAWN_HEALTH;
	p.armor = 0;
	p.owned = {};
	p.ammo = {};
	p.owned[(int)Weapon.MACHINEGUN] = true;
	p.ammo[(int)Weapon.MACHINEGUN] = Weapon.MACHINEGUN.start_ammo;
	p.weapon = MACHINEGUN;
	p.weapon_time = 0;
	p.quad_time = 0;
	p.decay_time = DECAY_INTERVAL;
	self.emit(RESPAWN, (char)slot, pos: s.pos);
}

// ---------------------------------------------------------------- commands

<*
 Applies one user command to one player: movement, weapons, pickups.
 The server calls this for every new command, in order.
*>
fn void World.run_cmd(&self, int slot, UserCmd cmd)
{
	Player* p = &self.players[slot];
	if (!p.active) return;
	p.last_cmd_seq = cmd.seq;
	Buttons pressed = cmd.buttons & ~p.last_buttons;
	p.last_buttons = cmd.buttons;
	if (self.phase == INTERMISSION) return;

	if (p.ps.flags.dead)
	{
		pmove::move(&p.ps, cmd, self.map, defs::TICK_DT);
		bool wants = pressed.attack || pressed.jump;
		if (self.time >= p.respawn_time && (wants || self.time >= p.respawn_time + AUTO_RESPAWN_TIME)) self.spawn(slot);
		return;
	}

	PmEvents ev = pmove::move(&p.ps, cmd, self.map, defs::TICK_DT);
	if (ev.jumped) self.emit(JUMP, (char)slot);
	if (ev.landed) self.emit(LAND, (char)slot, ev.hard_landing ? 1 : 0);
	if (ev.jumppad) self.emit(JUMPPAD, (char)slot, pos: p.ps.origin);
	if (ev.teleported) self.emit(TELEPORT, (char)slot, pos: p.ps.origin);

	self.weapon_think(slot, cmd);
	self.touch_items(slot);
}

fn void World.weapon_think(&self, int slot, UserCmd cmd)
{
	Player* p = &self.players[slot];
	if (p.weapon_time > 0) p.weapon_time -= defs::TICK_DT;
	if (p.weapon_time > 0) return;

	if (cmd.weapon != p.weapon && p.owned[(int)cmd.weapon])
	{
		p.weapon = cmd.weapon;
		p.weapon_time = WEAPON_SWITCH_TIME;
		return;
	}
	if (!cmd.buttons.attack) return;

	int w = (int)p.weapon;
	if (p.ammo[w] <= 0)
	{
		p.weapon_time = 0.5f;
		self.auto_switch(p);
		return;
	}
	p.ammo[w]--;
	p.weapon_time = p.weapon.refire;
	self.fire(slot);
}

// Out of ammo: switch to the best weapon that still has some.
fn void World.auto_switch(&self, Player* p)
{
	for (int w = NUM_WEAPONS - 1; w >= 0; w--)
	{
		if (p.owned[w] && p.ammo[w] > 0)
		{
			p.weapon = (Weapon)w;
			return;
		}
	}
}

// ---------------------------------------------------------------- weapons

fn void World.fire(&self, int slot)
{
	Player* p = &self.players[slot];
	Vec3 eye = p.eye();
	Vec3 fwd = mathx::forward(p.ps.yaw, p.ps.pitch);
	bool quad = p.quad_time > 0;
	Weapon w = p.weapon;
	Vec3 muzzle = eye + fwd * MUZZLE_FORWARD;

	switch (w.fire)
	{
		case HITSCAN:
			Vec3 end = self.hitscan(slot, eye, self.spread(fwd, w.spread), w, quad);
			self.emit(FIRE, (char)slot, (char)w.ordinal, quad ? 1 : 0, muzzle, end);
		case PELLETS:
			for (int i = 0; i < w.pellets; i++) self.hitscan(slot, eye, self.spread(fwd, w.spread), w, quad);
			self.emit(FIRE, (char)slot, (char)w.ordinal, quad ? 1 : 0, muzzle, eye + fwd * 10.0f);
		case ROCKET:
			self.spawn_rocket(slot, muzzle, fwd * w.speed, quad);
			self.emit(FIRE, (char)slot, (char)w.ordinal, quad ? 1 : 0, muzzle, muzzle + fwd);
		case RAIL:
			Vec3 end = self.rail(slot, eye, fwd, quad);
			self.emit(FIRE, (char)slot, (char)w.ordinal, quad ? 1 : 0, muzzle, end);
			self.emit(RAIL, (char)slot, pos: muzzle, pos2: end);
	}
}

fn Vec3 World.spread(&self, Vec3 fwd, float amount)
{
	if (amount <= 0) return fwd;
	Vec3 right = fwd.cross({ 0, 1, 0 });
	if (right.length_sq() < 0.0001f) right = { 1, 0, 0 };
	right = right.normalize();
	Vec3 up = right.cross(fwd);
	float r = self.rng.unit() * amount;
	float a = self.rng.unit() * (float)math::PI * 2.0f;
	return (fwd + right * (math::cos(a) * r) + up * (math::sin(a) * r)).normalize();
}

<*
 Slab test: distance along dir (unit) to box, or -1 if missed within max_t.
*>
fn float ray_box(Vec3 origin, Vec3 dir, float max_t, Aabb box)
{
	float t0 = 0;
	float t1 = max_t;
	for (int a = 0; a < 3; a++)
	{
		if (math::abs(dir[a]) < 1e-6f)
		{
			if (origin[a] < box.min[a] || origin[a] > box.max[a]) return -1;
			continue;
		}
		float inv = 1.0f / dir[a];
		float near = (box.min[a] - origin[a]) * inv;
		float far = (box.max[a] - origin[a]) * inv;
		if (near > far) @swap(near, far);
		t0 = math::max(t0, near);
		t1 = math::min(t1, far);
		if (t0 > t1) return -1;
	}
	return t0;
}

// Nearest living player (other than `skip`) hit by the ray before max_t, or -1.
fn int World.ray_player(&self, Vec3 origin, Vec3 dir, float max_t, int skip, float* hit_t)
{
	int best = -1;
	float best_t = max_t;
	for (int i = 0; i < defs::MAX_PLAYERS; i++)
	{
		Player* p = &self.players[i];
		if (i == skip || !p.alive()) continue;
		float t = ray_box(origin, dir, best_t, p.hitbox());
		if (t >= 0 && t < best_t)
		{
			best = i;
			best_t = t;
		}
	}
	*hit_t = best_t;
	return best;
}

fn Vec3 World.hitscan(&self, int slot, Vec3 eye, Vec3 dir, Weapon w, bool quad)
{
	Trace tr = self.map.trace_ray(eye, eye + dir * MAX_SHOT_RANGE, SHOT);
	float wall_t = tr.fraction * MAX_SHOT_RANGE;
	float t;
	int victim = self.ray_player(eye, dir, wall_t, slot, &t);
	if (victim >= 0)
	{
		self.damage(victim, slot, w.damage, dir, w, quad);
		return eye + dir * t;
	}
	if (tr.fraction < 1.0f) self.emit(BULLET_HIT, (char)slot, pos: tr.endpos, pos2: tr.normal);
	return tr.endpos;
}

// The railgun goes through every player on its line.
fn Vec3 World.rail(&self, int slot, Vec3 eye, Vec3 dir, bool quad)
{
	Trace tr = self.map.trace_ray(eye, eye + dir * MAX_SHOT_RANGE, SHOT);
	float wall_t = tr.fraction * MAX_SHOT_RANGE;
	for (int i = 0; i < defs::MAX_PLAYERS; i++)
	{
		Player* p = &self.players[i];
		if (i == slot || !p.alive()) continue;
		if (ray_box(eye, dir, wall_t, p.hitbox()) >= 0) self.damage(i, slot, Weapon.RAILGUN.damage, dir, RAILGUN, quad);
	}
	if (tr.fraction < 1.0f) self.emit(BULLET_HIT, (char)slot, 1, pos: tr.endpos, pos2: tr.normal);
	return tr.endpos;
}

fn void World.spawn_rocket(&self, int slot, Vec3 pos, Vec3 vel, bool quad)
{
	foreach (&pr : self.projectiles)
	{
		if (pr.active) continue;
		*pr = { true, (char)slot, quad, ++self.projectile_serial, pos, vel, ROCKET_LIFE };
		return;
	}
}

fn void World.update_projectiles(&self)
{
	foreach (i, &pr : self.projectiles)
	{
		if (!pr.active) continue;
		pr.life -= defs::TICK_DT;
		if (pr.life <= 0)
		{
			pr.active = false;
			continue;
		}
		Vec3 next = pr.pos + pr.vel * defs::TICK_DT;
		Trace tr = self.map.trace_ray(pr.pos, next, SHOT);
		float seg = (next - pr.pos).length();
		Vec3 dir = pr.vel.normalize();
		float wall_t = tr.fraction * seg;

		// Players are hit with a slightly padded box (rockets are not points).
		int victim = -1;
		float best = wall_t;
		for (int k = 0; k < defs::MAX_PLAYERS; k++)
		{
			Player* p = &self.players[k];
			if (k == (int)pr.owner || !p.alive()) continue;
			Aabb box = p.hitbox();
			Vec3 pad = { ROCKET_HIT_PAD, ROCKET_HIT_PAD, ROCKET_HIT_PAD };
			box = { box.min - pad, box.max + pad };
			float t = ray_box(pr.pos, dir, best, box);
			if (t >= 0 && t < best)
			{
				victim = k;
				best = t;
			}
		}

		if (victim >= 0)
		{
			Vec3 at = pr.pos + dir * best;
			self.damage(victim, pr.owner, Weapon.ROCKET.damage, dir, ROCKET, pr.quad);
			self.explode(at, -dir, pr.owner, victim, pr.quad);
			pr.active = false;
			continue;
		}
		if (tr.fraction < 1.0f)
		{
			// Pull back a little so the blast isn't inside the wall.
			self.explode(tr.endpos + tr.normal * 0.05f, tr.normal, pr.owner, -1, pr.quad);
			pr.active = false;
			continue;
		}
		pr.pos = next;
	}
}

fn float dist_to_box(Vec3 p, Aabb b)
{
	Vec3 c = math::clamp(p, b.min, b.max);
	return (p - c).length();
}

<*
 Radius damage. `skip` was already hit directly (Q3 rule: no splash on the direct target).
*>
fn void World.explode(&self, Vec3 at, Vec3 normal, int owner, int skip, bool quad)
{
	self.emit(EXPLOSION, (char)owner, pos: at, pos2: normal);
	Weapon w = ROCKET;
	for (int i = 0; i < defs::MAX_PLAYERS; i++)
	{
		Player* p = &self.players[i];
		if (i == skip || !p.alive()) continue;
		Aabb box = p.hitbox();
		float d = dist_to_box(at, box);
		if (d >= w.splash_radius) continue;
		Vec3 center = box.center();
		if (self.map.trace_ray(at, center, SHOT).fraction < 1.0f && self.map.trace_ray(at, p.eye(), SHOT).fraction < 1.0f) continue;
		int points = (int)((float)w.splash_damage * (1.0f - d / w.splash_radius));
		if (points <= 0) continue;
		Vec3 dir = center - at;
		dir.y += 0.6f;   // Q3 pushes splash slightly upwards: makes rocket jumps work
		self.damage(i, owner, points, dir, w, quad);
	}
}

// ---------------------------------------------------------------- damage

fn void World.damage(&self, int target, int attacker, int amount, Vec3 dir, Weapon w, bool quad)
{
	Player* t = &self.players[target];
	if (!t.alive() || self.phase == INTERMISSION) return;
	int dmg = amount;
	if (quad) dmg = (int)((float)dmg * defs::QUAD_FACTOR);

	// Knockback is applied before self-damage reduction: rocket jumps keep their full push.
	float knock = (float)math::min(dmg, 200);
	if (dir.length_sq() > 0.0001f && knock > 0)
	{
		t.ps.velocity += dir.normalize() * (knock * defs::KNOCKBACK_SCALE * (target == attacker ? 1.0f : 0.8f));
		t.ps.knockback_time = math::clamp(knock * 0.002f, 0.05f, 0.2f);
		t.ps.flags.on_ground = false;
	}
	if (target == attacker) dmg = (int)((float)dmg * defs::SELF_DAMAGE_FACTOR);

	int save = math::min((int)math::ceil((float)dmg * defs::ARMOR_PROTECTION), t.armor);
	t.armor -= save;
	dmg -= save;
	t.health -= dmg;

	if (attacker >= 0 && attacker != target) self.emit(HIT_CONFIRM, (char)attacker, (char)math::min(amount, 255));
	if (t.health <= 0)
	{
		self.kill(target, attacker, w);
		return;
	}
	if (self.time >= t.pain_time)
	{
		t.pain_time = self.time + PAIN_INTERVAL;
		self.emit(PAIN, (char)target, (char)math::clamp(t.health, 0, 255));
	}
}

fn void World.kill(&self, int target, int attacker, Weapon w)
{
	Player* t = &self.players[target];
	t.ps.flags.dead = true;
	t.health = math::min(t.health, 0);
	t.deaths++;
	t.respawn_time = self.time + defs::RESPAWN_DELAY;
	t.quad_time = 0;

	bool suicide = attacker < 0 || attacker == target;
	if (suicide)
	{
		t.frags--;
	}
	else
	{
		self.players[attacker].frags++;
	}
	char killer = suicide ? defs::NO_PLAYER : (char)attacker;
	self.emit(DEATH, (char)target, killer, (char)w.ordinal, t.ps.origin);

	if (!suicide && self.players[attacker].frags >= self.fraglimit) self.end_match();
}

// ---------------------------------------------------------------- items

fn bool World.give_item(&self, Player* p, ItemKind k)
{
	switch (k.cls)
	{
		case HEALTH:
			int cap = k == MEGA ? defs::MAX_MEGA_HEALTH : defs::MAX_HEALTH;
			if (p.health >= cap) return false;
			p.health = math::min(p.health + k.amount, cap);
		case ARMOR:
			if (p.armor >= defs::MAX_ARMOR) return false;
			p.armor = math::min(p.armor + k.amount, defs::MAX_ARMOR);
		case WEAPON:
			int w = (int)k.weapon;
			p.owned[w] = true;
			p.ammo[w] = math::min(math::max(p.ammo[w], k.weapon.pickup_ammo), k.weapon.max_ammo);
		case AMMO:
			int w = (int)k.weapon;
			if (p.ammo[w] >= k.weapon.max_ammo) return false;
			p.ammo[w] = math::min(p.ammo[w] + k.amount, k.weapon.max_ammo);
		case POWERUP:
			p.quad_time = defs::QUAD_DURATION;
	}
	return true;
}

fn void World.touch_items(&self, int slot)
{
	Player* p = &self.players[slot];
	Aabb body = p.hitbox();
	Map* m = self.map;
	for (int i = 0; i < m.item_count; i++)
	{
		if (!self.items[i].available) continue;
		ItemSpot* it = &m.items[i];
		Aabb box = { it.pos - (Vec3){ ITEM_REACH, 0, ITEM_REACH }, it.pos + (Vec3){ ITEM_REACH, ITEM_HEIGHT, ITEM_REACH } };
		if (!body.overlaps(box)) continue;
		if (!self.give_item(p, it.kind)) continue;
		self.items[i] = { false, self.time + it.kind.respawn };
		self.emit(PICKUP, (char)slot, (char)it.kind.ordinal, (char)i, it.pos);
	}
}

fn void World.update_items(&self)
{
	Map* m = self.map;
	for (int i = 0; i < m.item_count; i++)
	{
		ItemState* s = &self.items[i];
		if (s.available || self.time < s.respawn_at) continue;
		s.available = true;
		self.emit(ITEM_RESPAWN, 0, (char)i, pos: m.items[i].pos);
	}
}

// ---------------------------------------------------------------- match

fn void World.restart_match(&self)
{
	self.phase = PLAYING;
	self.match_start = self.time;
	self.winner = defs::NO_PLAYER;
	foreach (&pr : self.projectiles) pr.active = false;
	for (int i = 0; i < defs::MAX_ITEMS; i++) self.items[i] = { true, 0 };
	for (int i = 0; i < defs::MAX_PLAYERS; i++)
	{
		Player* p = &self.players[i];
		if (!p.active) continue;
		p.frags = 0;
		p.deaths = 0;
		self.spawn(i);
	}
}

fn void World.end_match(&self)
{
	if (self.phase == INTERMISSION) return;
	int best = -1;
	for (int i = 0; i < defs::MAX_PLAYERS; i++)
	{
		Player* p = &self.players[i];
		if (!p.active) continue;
		if (best < 0 || p.frags > self.players[best].frags) best = i;
	}
	self.winner = best < 0 ? defs::NO_PLAYER : (char)best;
	self.phase = INTERMISSION;
	self.phase_end = self.time + defs::INTERMISSION_TIME;
	self.emit(MATCH_END, self.winner);
}

fn float World.time_left(&self)
{
	if (self.timelimit <= 0) return 0;
	return math::max(self.timelimit - (self.time - self.match_start), 0.0f);
}

fn void World.decay_stats(&self, Player* p)
{
	if (!p.alive()) return;
	if (p.quad_time > 0) p.quad_time = math::max(p.quad_time - defs::TICK_DT, 0.0f);
	p.decay_time -= defs::TICK_DT;
	if (p.decay_time > 0) return;
	p.decay_time = DECAY_INTERVAL;
	if (p.health > defs::MAX_HEALTH) p.health--;
	if (p.armor > defs::MAX_HEALTH) p.armor--;
}

<*
 Advances everything that isn't driven by a player command. Call once per tick,
 after all commands for the tick were applied.
*>
fn void World.step(&self)
{
	self.tick++;
	self.time += defs::TICK_DT;

	if (self.phase == INTERMISSION)
	{
		if (self.time >= self.phase_end) self.restart_match();
		return;
	}

	self.update_projectiles();
	self.update_items();
	foreach (&p : self.players) self.decay_stats(p);
	if (self.timelimit > 0 && self.time_left() <= 0) self.end_match();
}
