// Player movement: a port of Quake III's bg_pmove to AABB worlds.
// Deterministic: the client runs the exact same code to predict its own player.
module arena::pmove;
import std::math, arena::mathx, arena::defs, arena::map;

const int MAX_CLIP_PLANES = 5;
const int MAX_BUMPS = 4;
const float GROUND_PROBE = 0.25f / 32.0f;   // Q3 probes a quarter unit down
const float JUMP_KICKOFF = 10.0f / 32.0f;
const float HARD_LANDING_SPEED = 14.0f;
const float WALK_FACTOR = 0.5f;
const float TELEPORT_SPEED = 12.5f;
const float DEAD_FRICTION = 3.0f;

struct Pm @local
{
	PlayerState* ps;
	UserCmd cmd;
	Map* map;
	float dt;
	Vec3 maxs;
	bool walking;
	bool ground_plane;
	Vec3 ground_normal;
	PmEvents events;
}

<*
 Advances one player by one command. Returns the events that happened (for sound/fx).
 @require dt > 0.0f
*>
fn PmEvents move(PlayerState* ps, UserCmd cmd, Map* m, float dt)
{
	Pm pm = { .ps = ps, .cmd = cmd, .map = m, .dt = dt, .maxs = defs::PLAYER_MAXS };
	bool dead = ps.flags.dead;
	if (dead)
	{
		pm.maxs = defs::DEAD_MAXS;
		pm.cmd.forward = 0;
		pm.cmd.side = 0;
		pm.cmd.buttons = {};
	}
	else
	{
		ps.yaw = cmd.yaw;
		ps.pitch = cmd.pitch;
	}

	if (!pm.cmd.buttons.jump) ps.flags.jump_held = false;
	if (ps.knockback_time > 0) ps.knockback_time = math::max(ps.knockback_time - dt, 0.0f);

	bool was_on_ground = ps.flags.on_ground;
	float fall_speed = -ps.velocity.y;

	pm.ground_trace();
	if (dead)
	{
		pm.dead_move();
	}
	else if (pm.walking)
	{
		pm.walk_move();
	}
	else
	{
		pm.air_move();
	}
	pm.ground_trace();

	if (!was_on_ground && pm.walking)
	{
		pm.events.landed = true;
		pm.events.hard_landing = fall_speed > HARD_LANDING_SPEED;
	}
	pm.touch_triggers();
	return pm.events;
}

// ---------------------------------------------------------------- ground

fn Trace Pm.trace(&self, Vec3 start, Vec3 end) @inline
{
	return self.map.trace(start, end, defs::PLAYER_MINS, self.maxs, PLAYER);
}

fn void Pm.ground_trace(&self)
{
	PlayerState* ps = self.ps;
	Vec3 down = ps.origin - (Vec3){ 0, GROUND_PROBE, 0 };
	Trace tr = self.trace(ps.origin, down);

	self.walking = false;
	self.ground_plane = false;
	ps.flags.on_ground = false;
	if (tr.allsolid || tr.fraction == 1.0f) return;

	// Moving up fast enough off the plane: we are jumping, not standing.
	if (ps.velocity.y > 0 && ps.velocity.dot(tr.normal) > JUMP_KICKOFF) return;

	self.ground_plane = true;
	self.ground_normal = tr.normal;
	if (tr.normal.y < defs::MIN_WALK_NORMAL) return;

	self.walking = true;
	ps.flags.on_ground = true;
}

// ---------------------------------------------------------------- moves

fn bool Pm.check_jump(&self)
{
	PlayerState* ps = self.ps;
	if (!self.cmd.buttons.jump || ps.flags.jump_held) return false;
	ps.flags.jump_held = true;
	ps.velocity.y = defs::JUMP_VELOCITY;
	ps.flags.on_ground = false;
	self.walking = false;
	self.ground_plane = false;
	self.events.jumped = true;
	return true;
}

fn void Pm.friction(&self, float strength)
{
	PlayerState* ps = self.ps;
	Vec3 vel = ps.velocity;
	if (self.walking) vel.y = 0;
	float speed = vel.length();
	if (speed < 0.03f)
	{
		ps.velocity.x = 0;
		ps.velocity.z = 0;
		return;
	}
	if (!self.walking || ps.knockback_time > 0) return;
	float control = math::max(speed, defs::STOP_SPEED);
	float drop = control * strength * self.dt;
	float scale = math::max(speed - drop, 0.0f) / speed;
	ps.velocity *= scale;
}

fn void Pm.accelerate(&self, Vec3 wishdir, float wishspeed, float accel)
{
	float current = self.ps.velocity.dot(wishdir);
	float add = wishspeed - current;
	if (add <= 0) return;
	float accel_speed = math::min(accel * self.dt * wishspeed, add);
	self.ps.velocity += wishdir * accel_speed;
}

<*
 Wish direction and speed from the command (Q3 CmdScale normalizes diagonals).
*>
fn float Pm.wish(&self, Vec3* dir)
{
	float f = (float)self.cmd.forward;
	float s = (float)self.cmd.side;
	float most = math::max(math::abs(f), math::abs(s));
	if (most == 0)
	{
		*dir = { 0, 0, 0 };
		return 0;
	}
	Vec3 wishvel = mathx::flat_forward(self.ps.yaw) * f + mathx::flat_right(self.ps.yaw) * s;
	float len = wishvel.length();
	*dir = wishvel / len;
	float speed = defs::RUN_SPEED * most / 127.0f;
	if (self.cmd.buttons.walk) speed *= WALK_FACTOR;
	return speed;
}

fn void Pm.walk_move(&self)
{
	if (self.check_jump())
	{
		self.air_move();
		return;
	}
	self.friction(defs::FRICTION);

	Vec3 wishdir;
	float wishspeed = self.wish(&wishdir);
	self.accelerate(wishdir, wishspeed, defs::GROUND_ACCEL);

	PlayerState* ps = self.ps;
	if (ps.knockback_time > 0) ps.velocity.y -= defs::GRAVITY * self.dt;

	// Keep speed while sliding along the ground plane.
	float speed = ps.velocity.length();
	ps.velocity = clip_velocity(ps.velocity, self.ground_normal, defs::OVERCLIP);
	float now = ps.velocity.length();
	if (now > 0.0001f) ps.velocity *= speed / now;

	if (ps.velocity.x == 0 && ps.velocity.z == 0) return;
	self.step_slide_move(false);
}

fn void Pm.air_move(&self)
{
	self.friction(defs::FRICTION);
	Vec3 wishdir;
	float wishspeed = self.wish(&wishdir);
	self.accelerate(wishdir, wishspeed, defs::AIR_ACCEL);
	if (self.ground_plane)
	{
		self.ps.velocity = clip_velocity(self.ps.velocity, self.ground_normal, defs::OVERCLIP);
	}
	self.step_slide_move(true);
}

fn void Pm.dead_move(&self)
{
	if (self.walking) self.friction(DEAD_FRICTION);
	self.step_slide_move(!self.walking);
}

// ---------------------------------------------------------------- sliding

fn Vec3 clip_velocity(Vec3 v, Vec3 normal, float overbounce)
{
	float backoff = v.dot(normal);
	backoff = backoff < 0 ? backoff * overbounce : backoff / overbounce;
	return v - normal * backoff;
}

<*
 Returns true if the velocity was clipped by something.
*>
fn bool Pm.slide_move(&self, bool gravity)
{
	PlayerState* ps = self.ps;
	Vec3[MAX_CLIP_PLANES] planes;
	int num_planes = 0;
	Vec3 end_velocity;

	if (gravity)
	{
		end_velocity = ps.velocity;
		end_velocity.y -= defs::GRAVITY * self.dt;
		ps.velocity.y = (ps.velocity.y + end_velocity.y) * 0.5f;
		if (self.ground_plane) ps.velocity = clip_velocity(ps.velocity, self.ground_normal, defs::OVERCLIP);
	}

	float time_left = self.dt;
	if (self.ground_plane) planes[num_planes++] = self.ground_normal;
	float speed = ps.velocity.length();
	if (speed > 0) planes[num_planes++] = ps.velocity / speed;

	int bump = 0;
	for (; bump < MAX_BUMPS; bump++)
	{
		Vec3 end = ps.origin + ps.velocity * time_left;
		Trace tr = self.trace(ps.origin, end);
		if (tr.allsolid)
		{
			ps.velocity.y = 0;
			return true;
		}
		if (tr.fraction > 0) ps.origin = tr.endpos;
		if (tr.fraction == 1.0f) break;

		time_left -= time_left * tr.fraction;
		if (num_planes >= MAX_CLIP_PLANES)
		{
			ps.velocity = { 0, 0, 0 };
			return true;
		}

		// Same plane as before: nudge out along it to avoid getting stuck.
		bool repeat = false;
		for (int i = 0; i < num_planes; i++)
		{
			if (tr.normal.dot(planes[i]) > 0.99f)
			{
				ps.velocity += tr.normal;
				repeat = true;
				break;
			}
		}
		if (repeat) continue;
		planes[num_planes++] = tr.normal;

		if (!self.clip_to_planes(planes[:num_planes], &end_velocity)) return true;
	}

	if (gravity) ps.velocity = end_velocity;
	return bump != 0;
}

<*
 Makes velocity parallel to every clip plane (creasing along two-plane intersections).
 Returns false if the player is wedged and must stop.
*>
fn bool Pm.clip_to_planes(&self, Vec3[] planes, Vec3* end_velocity)
{
	PlayerState* ps = self.ps;
	for (usz i = 0; i < planes.len; i++)
	{
		if (ps.velocity.dot(planes[i]) >= 0.1f) continue;

		Vec3 clipped = clip_velocity(ps.velocity, planes[i], defs::OVERCLIP);
		Vec3 end_clipped = clip_velocity(*end_velocity, planes[i], defs::OVERCLIP);

		for (usz j = 0; j < planes.len; j++)
		{
			if (j == i) continue;
			if (clipped.dot(planes[j]) >= 0.1f) continue;

			clipped = clip_velocity(clipped, planes[j], defs::OVERCLIP);
			end_clipped = clip_velocity(end_clipped, planes[j], defs::OVERCLIP);
			if (clipped.dot(planes[i]) >= 0) continue;

			// Slide along the crease between the two planes.
			Vec3 dir = planes[i].cross(planes[j]).normalize();
			clipped = dir * dir.dot(ps.velocity);
			end_clipped = dir * dir.dot(*end_velocity);

			for (usz k = 0; k < planes.len; k++)
			{
				if (k == i || k == j) continue;
				if (clipped.dot(planes[k]) >= 0.1f) continue;
				ps.velocity = { 0, 0, 0 };
				return false;
			}
		}
		ps.velocity = clipped;
		*end_velocity = end_clipped;
		break;
	}
	return true;
}

fn void Pm.step_slide_move(&self, bool gravity)
{
	PlayerState* ps = self.ps;
	Vec3 start_o = ps.origin;
	Vec3 start_v = ps.velocity;

	if (!self.slide_move(gravity)) return;

	Vec3 down = start_o - (Vec3){ 0, defs::STEP_HEIGHT, 0 };
	Trace tr = self.trace(start_o, down);
	// Never step up while still moving up off the ground.
	if (ps.velocity.y > 0 && (tr.fraction == 1.0f || tr.normal.y < defs::MIN_WALK_NORMAL)) return;

	Vec3 up = start_o + (Vec3){ 0, defs::STEP_HEIGHT, 0 };
	tr = self.trace(start_o, up);
	if (tr.allsolid) return;

	float step = tr.endpos.y - start_o.y;
	ps.origin = tr.endpos;
	ps.velocity = start_v;
	self.slide_move(gravity);

	down = ps.origin - (Vec3){ 0, step, 0 };
	tr = self.trace(ps.origin, down);
	if (!tr.allsolid) ps.origin = tr.endpos;
	if (tr.fraction < 1.0f) ps.velocity = clip_velocity(ps.velocity, tr.normal, defs::OVERCLIP);
}

// ---------------------------------------------------------------- triggers

fn void Pm.touch_triggers(&self)
{
	PlayerState* ps = self.ps;
	if (ps.flags.dead) return;
	Aabb body = { ps.origin + defs::PLAYER_MINS, ps.origin + defs::PLAYER_MAXS };
	Map* m = self.map;

	for (int i = 0; i < m.pad_count; i++)
	{
		JumpPad* pad = &m.pads[i];
		if (!body.overlaps(pad.trigger)) continue;
		if (ps.velocity.y < pad.launch.y * 0.9f) self.events.jumppad = true;
		ps.velocity = pad.launch;
		ps.flags.on_ground = false;
	}

	for (int i = 0; i < m.teleport_count; i++)
	{
		Teleport* t = &m.teleports[i];
		if (!body.overlaps(t.trigger)) continue;
		ps.origin = t.dest;
		ps.yaw = t.yaw;
		ps.pitch = 0;
		ps.velocity = mathx::flat_forward(t.yaw) * TELEPORT_SPEED;
		ps.flags.teleport_bit = !ps.flags.teleport_bit;
		ps.flags.on_ground = false;
		self.events.teleported = true;
		return;
	}
}
