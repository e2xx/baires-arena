// Client-side visual effects: particles, rail beams, flashes (dynamic lights).
module arena::fx;
import std::math, raylib6, arena::mathx, arena::defs;

const int MAX_PARTICLES = 4096;
const int MAX_BEAMS = 48;
const int MAX_FLASHES = 48;
const int MAX_DYN_LIGHTS = 16;
const float RAIL_LIFE = 1.1f;

enum Blend : char
{
	GLOW,    // additive: sparks, fire, energy
	SOLID,   // alpha: smoke, debris, blood
}

struct Particle
{
	Vec3 pos;
	Vec3 vel;
	Vec3 color;
	Vec3 color_end;
	float life;
	float max_life;
	float size;
	float size_end;
	float drag;
	float gravity;
	Blend blend;
}

struct Beam
{
	Vec3 a;
	Vec3 b;
	Vec3 color;
	float life;
}

struct Flash
{
	Vec3 pos;
	Vec3 color;
	float radius;
	float life;
	float max_life;
}

struct DynLight
{
	Vec3 pos;
	float radius;
	Vec3 color;
}

struct Fx
{
	Particle[MAX_PARTICLES] particles;
	int count;
	Beam[MAX_BEAMS] beams;
	Flash[MAX_FLASHES] flashes;
	Rng rng;
}

fn void Fx.init(&self)
{
	self.count = 0;
	self.rng = mathx::rng(0xF00D);
	foreach (&b : self.beams) b.life = 0;
	foreach (&f : self.flashes) f.life = 0;
}

fn Particle* Fx.spawn(&self)
{
	if (self.count >= MAX_PARTICLES) return &self.particles[self.rng.range(MAX_PARTICLES)];
	return &self.particles[self.count++];
}

fn void Fx.flash(&self, Vec3 pos, Vec3 color, float radius, float life)
{
	Flash* slot = &self.flashes[0];
	foreach (&f : self.flashes)
	{
		if (f.life <= 0)
		{
			slot = f;
			break;
		}
		if (f.life < slot.life) slot = f;
	}
	*slot = { pos, color, radius, life, life };
}

<*
 Emits `n` particles around pos with velocities `dir * speed` plus spread.
*>
macro void Fx.@burst(&self, int n; @body(Particle* p))
{
	for (int i = 0; i < n; i++)
	{
		Particle* p = self.spawn();
		*p = { .drag = 1.0f, .size = 0.1f, .size_end = 0.1f, .life = 0.5f, .max_life = 0.5f, .blend = GLOW };
		@body(p);
		p.max_life = p.life;
	}
}

// ---------------------------------------------------------------- effects

fn void Fx.explosion(&self, Vec3 pos, Vec3 normal, bool quad)
{
	Vec3 hot = quad ? (Vec3){ 0.4f, 0.6f, 1.6f } : (Vec3){ 1.8f, 1.0f, 0.35f };
	self.flash(pos + normal * 0.5f, hot * 2.0f, 9.0f, 0.45f);
	self.@burst(70; Particle* p)
	{
		Vec3 d = (self.rng.dir() + normal * 0.6f).normalize();
		p.pos = pos + d * 0.2f;
		p.vel = d * (4.0f + self.rng.unit() * 9.0f);
		p.color = hot;
		p.color_end = { 0.5f, 0.1f, 0.0f };
		p.life = 0.35f + self.rng.unit() * 0.35f;
		p.size = 0.35f + self.rng.unit() * 0.3f;
		p.size_end = 0.05f;
		p.drag = 3.5f;
	};
	self.@burst(28; Particle* p)
	{
		Vec3 d = (self.rng.dir() + normal).normalize();
		p.pos = pos + d * 0.4f;
		p.vel = d * (1.0f + self.rng.unit() * 2.5f) + (Vec3){ 0, 1.2f, 0 };
		p.color = { 0.25f, 0.23f, 0.22f };
		p.color_end = { 0.12f, 0.12f, 0.12f };
		p.life = 1.0f + self.rng.unit() * 1.2f;
		p.size = 0.4f;
		p.size_end = 1.3f;
		p.drag = 1.6f;
		p.blend = SOLID;
	};
	self.@burst(24; Particle* p)
	{
		Vec3 d = (self.rng.dir() + normal * 0.8f).normalize();
		p.pos = pos;
		p.vel = d * (8.0f + self.rng.unit() * 10.0f);
		p.color = { 2.0f, 1.6f, 0.8f };
		p.color_end = { 0.8f, 0.3f, 0.0f };
		p.life = 0.5f + self.rng.unit() * 0.4f;
		p.size = 0.06f;
		p.size_end = 0.03f;
		p.gravity = 14.0f;
		p.drag = 0.8f;
	};
}

fn void Fx.rail(&self, Vec3 a, Vec3 b, Vec3 color)
{
	Beam* slot = &self.beams[0];
	foreach (&bm : self.beams)
	{
		if (bm.life <= 0)
		{
			slot = bm;
			break;
		}
	}
	*slot = { a, b, color, RAIL_LIFE };

	// Spiral of energy around the beam.
	Vec3 dir = b - a;
	float len = dir.length();
	if (len < 0.01f) return;
	dir /= len;
	Vec3 side = dir.cross({ 0, 1, 0 });
	if (side.length_sq() < 0.001f) side = { 1, 0, 0 };
	side = side.normalize();
	Vec3 up = side.cross(dir);
	int n = math::min((int)(len * 6.0f), 900);
	for (int i = 0; i < n; i++)
	{
		float t = (float)i / 6.0f;
		float ang = t * 4.0f;
		Vec3 ring = side * math::cos(ang) + up * math::sin(ang);
		Particle* p = self.spawn();
		*p = {
			.pos = a + dir * t + ring * 0.12f,
			.vel = ring * 0.6f,
			.color = color * 1.6f,
			.color_end = color * 0.2f,
			.life = 0.6f + self.rng.unit() * 0.5f,
			.size = 0.07f,
			.size_end = 0.02f,
			.drag = 2.0f,
			.blend = GLOW,
		};
		p.max_life = p.life;
	}
	self.flash(b, color * 1.5f, 4.0f, 0.3f);
}

fn void Fx.bullet_hit(&self, Vec3 pos, Vec3 normal, bool big)
{
	self.@burst(big ? 14 : 6; Particle* p)
	{
		Vec3 d = (self.rng.dir() * 0.7f + normal).normalize();
		p.pos = pos + normal * 0.02f;
		p.vel = d * (3.0f + self.rng.unit() * 6.0f);
		p.color = { 2.0f, 1.7f, 1.0f };
		p.color_end = { 0.6f, 0.2f, 0.0f };
		p.life = 0.2f + self.rng.unit() * 0.25f;
		p.size = 0.04f;
		p.size_end = 0.01f;
		p.gravity = 12.0f;
	};
	self.@burst(3; Particle* p)
	{
		p.pos = pos + normal * 0.05f;
		p.vel = normal * 0.8f + self.rng.dir() * 0.3f;
		p.color = { 0.45f, 0.43f, 0.4f };
		p.color_end = { 0.3f, 0.3f, 0.3f };
		p.life = 0.6f;
		p.size = 0.08f;
		p.size_end = 0.3f;
		p.drag = 2.0f;
		p.blend = SOLID;
	};
}

fn void Fx.muzzle(&self, Vec3 pos, Vec3 color)
{
	self.flash(pos, color, 4.5f, 0.07f);
}

fn void Fx.blood(&self, Vec3 pos, int amount)
{
	self.@burst(amount; Particle* p)
	{
		p.pos = pos + self.rng.dir() * 0.2f;
		p.vel = self.rng.dir() * (1.5f + self.rng.unit() * 3.0f) + (Vec3){ 0, 1.5f, 0 };
		p.color = { 0.55f, 0.03f, 0.03f };
		p.color_end = { 0.3f, 0.0f, 0.0f };
		p.life = 0.5f + self.rng.unit() * 0.4f;
		p.size = 0.07f;
		p.size_end = 0.05f;
		p.gravity = 20.0f;
		p.blend = SOLID;
	};
}

fn void Fx.gibs(&self, Vec3 pos, Vec3 color)
{
	self.blood(pos + (Vec3){ 0, 1, 0 }, 50);
	self.@burst(14; Particle* p)
	{
		p.pos = pos + (Vec3){ 0, 1.0f, 0 } + self.rng.dir() * 0.3f;
		p.vel = self.rng.dir() * (3.0f + self.rng.unit() * 5.0f) + (Vec3){ 0, 5.0f, 0 };
		p.color = color * 0.6f;
		p.color_end = color * 0.3f;
		p.life = 1.5f + self.rng.unit();
		p.size = 0.18f;
		p.size_end = 0.16f;
		p.gravity = 22.0f;
		p.drag = 0.3f;
		p.blend = SOLID;
	};
}

fn void Fx.rocket_trail(&self, Vec3 pos, bool quad)
{
	Particle* fire = self.spawn();
	*fire = {
		.pos = pos,
		.vel = self.rng.dir() * 0.4f,
		.color = quad ? (Vec3){ 0.5f, 0.7f, 2.0f } : (Vec3){ 2.0f, 1.2f, 0.4f },
		.color_end = { 0.4f, 0.1f, 0.0f },
		.life = 0.18f,
		.size = 0.2f,
		.size_end = 0.05f,
		.drag = 1.0f,
		.blend = GLOW,
	};
	fire.max_life = fire.life;
	Particle* smoke = self.spawn();
	*smoke = {
		.pos = pos,
		.vel = self.rng.dir() * 0.3f + (Vec3){ 0, 0.4f, 0 },
		.color = { 0.4f, 0.4f, 0.42f },
		.color_end = { 0.25f, 0.25f, 0.27f },
		.life = 1.1f,
		.size = 0.12f,
		.size_end = 0.6f,
		.drag = 1.5f,
		.blend = SOLID,
	};
	smoke.max_life = smoke.life;
}

fn void Fx.sparkle(&self, Vec3 pos, Vec3 color, int n, float speed)
{
	self.@burst(n; Particle* p)
	{
		p.pos = pos + self.rng.dir() * 0.4f;
		p.vel = self.rng.dir() * speed + (Vec3){ 0, speed * 0.6f, 0 };
		p.color = color * 1.8f;
		p.color_end = color * 0.3f;
		p.life = 0.5f + self.rng.unit() * 0.5f;
		p.size = 0.08f;
		p.size_end = 0.02f;
		p.drag = 2.0f;
	};
}

// ---------------------------------------------------------------- update / draw

fn void Fx.update(&self, float dt)
{
	int i = 0;
	while (i < self.count)
	{
		Particle* p = &self.particles[i];
		p.life -= dt;
		if (p.life <= 0)
		{
			*p = self.particles[--self.count];
			continue;
		}
		p.vel.y -= p.gravity * dt;
		p.vel *= math::max(0.0f, 1.0f - p.drag * dt);
		p.pos += p.vel * dt;
		i++;
	}
	foreach (&b : self.beams) b.life -= dt;
	foreach (&f : self.flashes) f.life -= dt;
}

<*
 Active flashes as dynamic lights, brightest first is not needed: shaders sum them all.
*>
fn int Fx.lights(&self, DynLight[] out)
{
	int n;
	foreach (&f : self.flashes)
	{
		if (f.life <= 0 || n >= out.len) continue;
		float k = f.life / f.max_life;
		out[n++] = { f.pos, f.radius * (0.6f + 0.4f * k), f.color * k };
	}
	return n;
}

fn RLColor to_color(Vec3 c, float alpha) @local
{
	Vec3 v = math::clamp(c, (Vec3){ 0, 0, 0 }, (Vec3){ 1, 1, 1 });
	return { (char)(v.x * 255), (char)(v.y * 255), (char)(v.z * 255), (char)(math::clamp(alpha, 0.0f, 1.0f) * 255) };
}

fn void draw_quad(Vec3 c, Vec3 right, Vec3 up, float s, RLColor col) @local
{
	Vec3 r = right * s;
	Vec3 u = up * s;
	rl::draw_triangle3d(c - r - u, c + r - u, c + r + u, col);
	rl::draw_triangle3d(c - r - u, c + r + u, c - r + u, col);
}

fn void Fx.draw_pass(&self, Blend blend, Vec3 right, Vec3 up)
{
	for (int i = 0; i < self.count; i++)
	{
		Particle* p = &self.particles[i];
		if (p.blend != blend) continue;
		float t = 1.0f - p.life / p.max_life;
		Vec3 c = p.color.lerp(p.color_end, t);
		float size = p.size + (p.size_end - p.size) * t;
		float alpha = blend == GLOW ? 1.0f - t * t : (1.0f - t) * 0.8f;
		draw_quad(p.pos, right, up, size, to_color(c, alpha));
	}
}

fn void Fx.draw(&self, RLCamera3D cam)
{
	Vec3 fwd = (cam.target - cam.position).normalize();
	Vec3 right = fwd.cross({ 0, 1, 0 }).normalize();
	Vec3 up = right.cross(fwd);

	rl::gl_disable_depth_mask();
	rl::gl_disable_backface_culling();
	self.draw_pass(SOLID, right, up);
	rl::begin_blend_mode(ADDITIVE);
	self.draw_pass(GLOW, right, up);
	foreach (&b : self.beams)
	{
		if (b.life <= 0) continue;
		float k = b.life / RAIL_LIFE;
		rl::draw_cylinder_ex(b.a, b.b, 0.03f * k + 0.01f, 0.03f * k + 0.01f, 6, to_color(b.color * 1.5f, k));
		rl::draw_cylinder_ex(b.a, b.b, 0.09f * k, 0.09f * k, 8, to_color(b.color * 0.6f, k * 0.5f));
	}
	rl::end_blend_mode();
	rl::gl_enable_backface_culling();
	rl::gl_enable_depth_mask();
}
