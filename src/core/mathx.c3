// Small math helpers shared by game, net and client code.
module arena::mathx;
import std::math;

const float DEG = (float)math::PI / 180.0f;

struct Aabb
{
	Vec3 min;
	Vec3 max;
}

fn Aabb aabb(Vec3 a, Vec3 b) => { math::min(a, b), math::max(a, b) };

fn Aabb aabb_at(Vec3 center, Vec3 half) => { center - half, center + half };

fn Vec3 Aabb.center(&self) => (self.min + self.max) * 0.5f;

fn Vec3 Aabb.size(&self) => self.max - self.min;

fn bool Aabb.contains(&self, Vec3 p)
{
	return p.x > self.min.x && p.x < self.max.x
		&& p.y > self.min.y && p.y < self.max.y
		&& p.z > self.min.z && p.z < self.max.z;
}

fn bool Aabb.overlaps(&self, Aabb o)
{
	return self.min.x < o.max.x && self.max.x > o.min.x
		&& self.min.y < o.max.y && self.max.y > o.min.y
		&& self.min.z < o.max.z && self.max.z > o.min.z;
}

fn Aabb Aabb.expand(&self, Vec3 mins, Vec3 maxs) => { self.min - maxs, self.max - mins };

fn Aabb Aabb.merge(&self, Aabb o) => { math::min(self.min, o.min), math::max(self.max, o.max) };

<*
 View direction for yaw/pitch (radians). Yaw 0 looks down +Z, pitch > 0 looks down.
*>
fn Vec3 forward(float yaw, float pitch)
{
	return { math::sin(yaw) * math::cos(pitch), -math::sin(pitch), math::cos(yaw) * math::cos(pitch) };
}

fn Vec3 flat_forward(float yaw) => { math::sin(yaw), 0, math::cos(yaw) };

fn Vec3 flat_right(float yaw) => { -math::cos(yaw), 0, math::sin(yaw) };

fn float wrap_angle(float a)
{
	float two_pi = (float)math::PI * 2.0f;
	while (a > (float)math::PI) a -= two_pi;
	while (a < -(float)math::PI) a += two_pi;
	return a;
}

fn float approach(float value, float target, float step)
{
	if (value < target) return math::min(value + step, target);
	return math::max(value - step, target);
}

// Deterministic xorshift32: same sequence on client and server.
struct Rng
{
	uint state;
}

fn Rng rng(uint seed) => { seed == 0 ? 0x9E3779B9 : seed };

fn uint Rng.next(&self)
{
	uint x = self.state;
	x ^= x << 13;
	x ^= x >> 17;
	x ^= x << 5;
	self.state = x;
	return x;
}

// Uniform in [0, 1).
fn float Rng.unit(&self) => (float)(self.next() >> 8) / 16777216.0f;

// Uniform in [-1, 1).
fn float Rng.signed(&self) => self.unit() * 2.0f - 1.0f;

fn int Rng.range(&self, int n) => n <= 0 ? 0 : (int)(self.next() % (uint)n);

fn Vec3 Rng.dir(&self)
{
	for (int i = 0; i < 16; i++)
	{
		Vec3 v = { self.signed(), self.signed(), self.signed() };
		float l2 = v.length_sq();
		if (l2 > 0.0001f && l2 <= 1.0f) return v / math::sqrt(l2);
	}
	return { 0, 1, 0 };
}
