// Client game: input → UserCmd, camera, and turning snapshot events into sound/fx/HUD.
module arena::cgame;
import std::math, raylib6, arena::mathx, arena::defs, arena::map, arena::snap, arena::fx, arena::render;
import arena::audio, arena::hud;

const float MAX_PITCH = 1.55f;
const float FOOTSTEP_DISTANCE = 2.4f;
const float FOOTSTEP_MIN_SPEED = 3.0f;
const float KICK_DECAY = 6.0f;
const float LAND_DIP = 0.22f;
const float SHAKE_RANGE = 8.0f;

struct Cgame
{
	Map* map;
	Renderer* gfx;
	Fx fx;
	int slot;
	float yaw;
	float pitch;
	Weapon wanted;
	uint cmd_seq;
	uint last_event;
	Snapshot cur;
	bool have_snap;
	bool teleport_bit;
	float sensitivity;
	float fov;
	float time;
	float kick;
	float bob;
	float bob_amount;
	float land_dip;
	float shake;
	float step_acc;
	float[defs::MAX_PLAYERS] other_step_acc;
	bool show_scores;
	int follow;          // slot whose eyes the camera uses while spectating (-1 = none)
}

fn void Cgame.init(&self, Map* m, Renderer* gfx, int slot)
{
	*self = {};
	self.map = m;
	self.gfx = gfx;
	self.slot = slot;
	self.wanted = MACHINEGUN;
	self.sensitivity = 3.0f;
	self.fov = 100.0f;
	self.follow = -1;
	self.fx.init();
}

fn PlayerSnap* Cgame.me(&self)
{
	if (!self.have_snap || self.slot < 0) return null;
	return &self.cur.players[self.slot];
}

// ---------------------------------------------------------------- input

fn ichar axis(RLKeyboardKey plus, RLKeyboardKey minus) @local
{
	int v = 0;
	if (rl::is_key_down(plus)) v += 127;
	if (rl::is_key_down(minus)) v -= 127;
	return (ichar)v;
}

<*
 Per-frame view input: mouse look, weapon keys. Call every frame before make_cmd.
*>
fn void Cgame.look(&self, bool enabled)
{
	if (!enabled) return;
	RLVector2 md = rl::get_mouse_delta();
	float scale = 0.022f * mathx::DEG * self.sensitivity;   // Quake III m_yaw/m_pitch
	self.yaw = mathx::wrap_angle(self.yaw - md.x * scale);
	self.pitch = math::clamp(self.pitch + md.y * scale, -MAX_PITCH, MAX_PITCH);

	if (!self.have_snap) return;
	LocalSnap* l = &self.cur.local;
	RLKeyboardKey[4] keys = { RLKeyboardKey.ONE, RLKeyboardKey.TWO, RLKeyboardKey.THREE, RLKeyboardKey.FOUR };
	foreach (i, k : keys)
	{
		if (rl::is_key_pressed(k) && l.owned[i]) self.select((Weapon)i);
	}
	float wheel = rl::get_mouse_wheel_move();
	if (wheel != 0) self.cycle_weapon(wheel > 0 ? 1 : -1);
}

fn void Cgame.select(&self, Weapon w)
{
	if (w == self.wanted) return;
	self.wanted = w;
	audio::play(WEAPON_SWITCH, 0.6f);
}

fn void Cgame.cycle_weapon(&self, int dir)
{
	LocalSnap* l = &self.cur.local;
	int w = (int)self.wanted;
	for (int i = 0; i < snap::NUM_WEAPONS; i++)
	{
		w = (w + dir + snap::NUM_WEAPONS) % snap::NUM_WEAPONS;
		if (l.owned[w] && l.ammo[w] > 0)
		{
			self.select((Weapon)w);
			return;
		}
	}
}

fn UserCmd Cgame.make_cmd(&self, bool enabled)
{
	UserCmd c = { .seq = ++self.cmd_seq, .yaw = self.yaw, .pitch = self.pitch, .weapon = self.wanted };
	if (!enabled) return c;
	c.forward = axis(RLKeyboardKey.W, RLKeyboardKey.S);
	c.side = axis(RLKeyboardKey.D, RLKeyboardKey.A);
	c.buttons.attack = rl::is_mouse_button_down(RLMouseButton.LEFT);
	c.buttons.jump = rl::is_key_down(RLKeyboardKey.SPACE) || rl::is_mouse_button_down(RLMouseButton.RIGHT);
	c.buttons.walk = rl::is_key_down(RLKeyboardKey.LEFT_SHIFT);
	return c;
}

// ---------------------------------------------------------------- snapshots & events

fn void Cgame.on_snapshot(&self, Snapshot* s)
{
	self.cur = *s;
	self.have_snap = true;
	self.slot = s.local.slot == defs::NO_PLAYER ? -1 : (int)s.local.slot;

	// Teleports and respawns hand the view angles to the server.
	if (self.slot >= 0 && s.local.ps.flags.teleport_bit != self.teleport_bit)
	{
		self.teleport_bit = s.local.ps.flags.teleport_bit;
		self.yaw = s.local.ps.yaw;
		self.pitch = 0;
	}
	for (int i = 0; i < s.event_count; i++)
	{
		GameEvent* e = &s.events[i];
		if (e.id <= self.last_event) continue;
		self.last_event = e.id;
		self.on_event(e);
		hud::on_event(e, &self.cur);
	}
}

fn Vec3 Cgame.listener_right(&self) => mathx::flat_right(self.yaw);

fn Vec3 Cgame.eye(&self)
{
	PlayerSnap* me = self.me();
	if (me == null) return { 0, 2, 0 };
	return me.eye();
}

fn void Cgame.sound_at(&self, Sfx s, Vec3 pos, float volume = 1.0f)
{
	audio::play_at(s, pos, self.eye(), self.listener_right(), volume);
}

fn Vec3 Cgame.player_pos(&self, char a)
{
	if (a >= defs::MAX_PLAYERS) return { 0, 0, 0 };
	return self.cur.players[a].origin;
}

fn Vec3 Cgame.player_color(&self, char a)
{
	if (a >= defs::MAX_PLAYERS) return { 1, 1, 1 };
	return ((PlayerColor)(self.cur.players[a].color % PlayerColor::len)).rgb;
}

fn Sfx fire_sound(Weapon w) @local
{
	switch (w)
	{
		case MACHINEGUN: return MG_FIRE;
		case SHOTGUN: return SHOTGUN_FIRE;
		case ROCKET: return ROCKET_FIRE;
		case RAILGUN: return RAIL_FIRE;
	}
}

fn void Cgame.on_event(&self, GameEvent* e)
{
	bool mine = self.slot >= 0 && e.a == (char)self.slot;
	switch (e.kind)
	{
		case FIRE:
			Weapon w = (Weapon)e.b;
			Vec3 flash = w == RAILGUN ? self.player_color(e.a) : (Vec3){ 1.6f, 1.2f, 0.6f };
			self.fx.muzzle(e.pos, flash);
			if (mine)
			{
				self.kick = 1.0f;
				audio::play(fire_sound(w), 0.8f);
				if (e.c == 1) audio::play(QUAD_FIRE, 0.7f);
				break;
			}
			self.sound_at(fire_sound(w), e.pos);
		case EXPLOSION:
			self.fx.explosion(e.pos, e.pos2, false);
			self.sound_at(EXPLOSION, e.pos);
			float d = (e.pos - self.eye()).length();
			if (d < SHAKE_RANGE) self.shake = math::max(self.shake, 1.0f - d / SHAKE_RANGE);
		case RAIL:
			self.fx.rail(e.pos, e.pos2, self.player_color(e.a));
		case BULLET_HIT:
			self.fx.bullet_hit(e.pos, e.pos2, e.b == 1);
		case PAIN:
			self.fx.blood(self.player_pos(e.a) + (Vec3){ 0, 1.1f, 0 }, 10);
			if (mine)
			{
				audio::play(PAIN, 0.8f);
				break;
			}
			self.sound_at(PAIN, self.player_pos(e.a), 0.8f);
		case DEATH:
			Vec3 at = e.pos;
			bool gib = (Weapon)e.c == ROCKET || (Weapon)e.c == RAILGUN;
			if (gib)
			{
				self.fx.gibs(at, self.player_color(e.a));
				self.sound_at(GIB, at);
			}
			else
			{
				self.fx.blood(at + (Vec3){ 0, 1, 0 }, 30);
			}
			self.sound_at(DEATH, at);
			if (self.slot >= 0 && e.b == (char)self.slot && e.a != e.b) audio::play(FRAG, 0.9f);
		case PICKUP:
			ItemKind k = (ItemKind)e.b;
			self.fx.sparkle(e.pos + (Vec3){ 0, 0.6f, 0 }, { 1, 1, 0.8f }, 16, 2.0f);
			if (!mine) break;
			self.on_pickup(k);
		case JUMP:
			if (mine)
			{
				audio::play(JUMP, 0.6f);
				break;
			}
			self.sound_at(JUMP, self.player_pos(e.a), 0.6f);
		case LAND:
			if (mine)
			{
				self.land_dip = e.b == 1 ? LAND_DIP * 1.6f : LAND_DIP;
				audio::play(LAND, e.b == 1 ? 0.9f : 0.5f);
				break;
			}
			self.sound_at(LAND, self.player_pos(e.a), 0.5f);
		case JUMPPAD:
			self.fx.sparkle(e.pos, { 0.3f, 1.0f, 0.6f }, 20, 3.0f);
			self.sound_at(JUMPPAD, e.pos);
		case TELEPORT:
			self.fx.sparkle(e.pos + (Vec3){ 0, 1, 0 }, { 0.4f, 0.7f, 1.0f }, 40, 3.0f);
			self.sound_at(TELEPORT, e.pos);
		case RESPAWN:
			self.fx.sparkle(e.pos + (Vec3){ 0, 1, 0 }, self.player_color(e.a), 30, 2.5f);
			self.sound_at(RESPAWN, e.pos, 0.7f);
			if (mine) self.wanted = MACHINEGUN;
		case HIT_CONFIRM:
			if (mine) audio::play(HIT_CONFIRM, 0.7f);
		case ITEM_RESPAWN:
			self.fx.sparkle(e.pos + (Vec3){ 0, 0.6f, 0 }, { 0.8f, 0.9f, 1.0f }, 12, 1.5f);
			self.sound_at(ITEM_RESPAWN, e.pos, 0.6f);
		case MATCH_END:
			audio::play(MATCH_END);
		case NONE:
			break;
	}
}

fn void Cgame.on_pickup(&self, ItemKind k)
{
	switch (k.cls)
	{
		case HEALTH: audio::play(k == MEGA ? PICKUP_MEGA : PICKUP_HEALTH, 0.8f);
		case ARMOR: audio::play(PICKUP_ARMOR, 0.8f);
		case AMMO: audio::play(PICKUP_WEAPON, 0.5f);
		case POWERUP: audio::play(QUAD_PICKUP);
		case WEAPON:
			audio::play(PICKUP_WEAPON, 0.8f);
			// Auto-switch to a newly picked weapon that is "better" than the current one.
			if ((int)k.weapon > (int)self.wanted) self.wanted = k.weapon;
	}
}

// ---------------------------------------------------------------- per frame

fn void Cgame.update(&self, float dt, Snapshot* view)
{
	self.time += dt;
	self.kick = math::max(self.kick - dt * KICK_DECAY, 0.0f);
	self.land_dip = math::max(self.land_dip - dt * 1.2f, 0.0f);
	self.shake = math::max(self.shake - dt * 2.5f, 0.0f);

	foreach (&pr : view.projectiles)
	{
		if (pr.active) self.fx.rocket_trail(pr.pos - pr.vel.normalize() * 0.35f, pr.quad);
	}
	for (int i = 0; i < self.map.pad_count; i++)
	{
		if (self.fx.rng.unit() < dt * 10.0f) self.fx.sparkle(self.map.pads[i].pos + (Vec3){ 0, 0.2f, 0 }, { 0.2f, 0.9f, 0.5f }, 1, 1.5f);
	}
	self.footsteps(dt, view);
	self.fx.update(dt);
}

fn void Cgame.footsteps(&self, float dt, Snapshot* view)
{
	for (int i = 0; i < defs::MAX_PLAYERS; i++)
	{
		PlayerSnap* p = &view.players[i];
		if (!p.alive() || !p.flags.on_ground) continue;
		float speed = ((Vec3){ p.velocity.x, 0, p.velocity.z }).length();
		if (speed < FOOTSTEP_MIN_SPEED) continue;
		self.other_step_acc[i] += speed * dt;
		if (self.other_step_acc[i] < FOOTSTEP_DISTANCE) continue;
		self.other_step_acc[i] = 0;
		if (i == self.slot)
		{
			audio::play(FOOTSTEP, 0.35f);
			continue;
		}
		self.sound_at(FOOTSTEP, p.origin, 0.4f);
	}
}

<*
 Camera for the local player. `ps` is the predicted (or interpolated) local state.
*>
fn RLCamera3D Cgame.camera(&self, PlayerState* ps)
{
	float speed = ((Vec3){ ps.velocity.x, 0, ps.velocity.z }).length();
	float target_bob = ps.flags.on_ground ? math::min(speed / defs::RUN_SPEED, 1.0f) : 0.0f;
	self.bob_amount += (target_bob - self.bob_amount) * 0.15f;
	self.bob += speed * 0.016f * 0.9f;

	float height = ps.flags.dead ? 0.45f : defs::EYE_HEIGHT;
	Vec3 eye = ps.origin + (Vec3){ 0, height - self.land_dip, 0 };
	eye.y += math::abs(math::sin(self.bob)) * 0.035f * self.bob_amount;
	float jitter = self.shake * 0.04f;
	float yaw = self.yaw + (self.fx.rng.signed() * jitter);
	float pitch = self.pitch + (self.fx.rng.signed() * jitter) - self.kick * 0.015f;
	Vec3 fwd = mathx::forward(yaw, pitch);
	// Horizontal FOV → vertical fovy for the window's aspect ratio.
	float aspect = (float)rl::get_screen_width() / (float)math::max(rl::get_screen_height(), 1);
	float hfov = self.fov * mathx::DEG;
	float fovy = 2.0f * math::atan(math::tan(hfov * 0.5f) / aspect) / mathx::DEG;
	return { .position = eye, .target = eye + fwd, .up = { 0, 1, 0 }, .fovy = fovy, .projection = PERSPECTIVE };
}

fn void Cgame.draw(&self, Snapshot* view, PlayerState* ps, float dt, int screen_w, int screen_h)
{
	RLCamera3D cam = self.camera(ps);
	DynLight[fx::MAX_DYN_LIGHTS] lights;
	int n = self.fx.lights(lights[..]);
	// Quad damage carriers glow.
	for (int i = 0; i < defs::MAX_PLAYERS && n < fx::MAX_DYN_LIGHTS; i++)
	{
		PlayerSnap* p = &view.players[i];
		if (p.alive() && p.quad) lights[n++] = { p.origin + (Vec3){ 0, 1, 0 }, 5.0f, { 0.3f, 0.5f, 1.6f } };
	}
	foreach (&pr : view.projectiles)
	{
		if (pr.active && n < fx::MAX_DYN_LIGHTS) lights[n++] = { pr.pos, 4.0f, { 1.4f, 0.8f, 0.3f } };
	}

	self.gfx.begin_frame(cam, lights[:n], self.time);
	rl::begin_mode3d(cam);
	self.gfx.draw_world();
	self.gfx.draw_items(view);
	self.gfx.draw_teleports();
	self.gfx.draw_players(view, self.slot >= 0 ? self.slot : self.follow, dt);
	self.gfx.draw_projectiles(view);
	self.fx.draw(cam);
	if (self.slot >= 0 && !ps.flags.dead)
	{
		self.gfx.draw_viewmodel(cam, self.yaw, self.pitch, self.cur.local.weapon, self.kick, self.bob, self.bob_amount);
	}
	rl::end_mode3d();

	if (self.slot >= 0) hud::draw(&self.cur, screen_w, screen_h, dt, self.show_scores || self.cur.phase == INTERMISSION);
}
