// Box and ray traces against map brushes (Quake III CM_ClipBoxToBrush, specialised to AABBs).
module arena::map;
import std::math, arena::mathx, arena::defs;

const float SURFACE_EPSILON = 0.125f / 32.0f;

enum TraceMask : char
{
	PLAYER,   // everything solid, including invisible clip brushes
	SHOT,     // only visible geometry: shots and light rays pass through clip
}

struct Trace
{
	float fraction;   // 0..1 of the move completed
	Vec3 endpos;
	Vec3 normal;
	int brush;        // -1 if nothing was hit
	bool startsolid;
	bool allsolid;
}

fn bool Map.blocks(&self, int index, TraceMask mask) @inline
{
	Surface s = self.brushes[index].material.surface;
	if (mask == SHOT) return s != INVISIBLE;
	return true;
}

<*
 Sweeps the box [mins, maxs] from start to end. Returns the first contact.
*>
fn Trace Map.trace(&self, Vec3 start, Vec3 end, Vec3 mins, Vec3 maxs, TraceMask mask)
{
	Trace tr = { .fraction = 1.0f, .endpos = end, .brush = -1 };
	// Volume swept by the moving box, padded by the clip epsilon.
	Aabb path = mathx::aabb(start, end);
	Vec3 eps = { SURFACE_EPSILON, SURFACE_EPSILON, SURFACE_EPSILON };
	Aabb sweep = { path.min + mins - eps, path.max + maxs + eps };

	self.@each_brush(sweep; int i)
	{
		if (self.blocks(i, mask)) clip_box(&tr, self.brushes[i].box.expand(mins, maxs), start, end, i);
	};

	if (tr.allsolid)
	{
		tr.fraction = 0;
		tr.endpos = start;
		return tr;
	}
	if (tr.fraction < 1.0f) tr.endpos = start + (end - start) * tr.fraction;
	return tr;
}

fn Trace Map.trace_ray(&self, Vec3 start, Vec3 end, TraceMask mask)
{
	Vec3 zero = { 0, 0, 0 };
	return self.trace(start, end, zero, zero, mask);
}

<*
 Clips the segment start→end against the (already Minkowski-expanded) box e.
*>
fn void clip_box(Trace* tr, Aabb e, Vec3 start, Vec3 end, int index) @local
{
	float enter = -1.0f;
	float leave = 1.0f;
	Vec3 clip_normal;
	bool startout = false;
	bool getout = false;

	for (int p = 0; p < 6; p++)
	{
		int axis = p >> 1;
		float sign = (p & 1) == 0 ? 1.0f : -1.0f;
		float dist = sign > 0 ? e.max[axis] : -e.min[axis];
		float d1 = start[axis] * sign - dist;
		float d2 = end[axis] * sign - dist;

		if (d2 > 0) getout = true;
		if (d1 > 0) startout = true;

		// Completely in front of this face: no contact with the box.
		if (d1 > 0 && (d2 >= SURFACE_EPSILON || d2 >= d1)) return;
		if (d1 <= 0 && d2 <= 0) continue;

		if (d1 > d2)
		{
			float f = math::max((d1 - SURFACE_EPSILON) / (d1 - d2), 0.0f);
			if (f > enter)
			{
				enter = f;
				clip_normal = { 0, 0, 0 };
				clip_normal[axis] = sign;
			}
		}
		else
		{
			float f = math::min((d1 + SURFACE_EPSILON) / (d1 - d2), 1.0f);
			if (f < leave) leave = f;
		}
	}

	if (!startout)
	{
		tr.startsolid = true;
		if (!getout) tr.allsolid = true;
		return;
	}
	if (enter < leave && enter > -1.0f && enter < tr.fraction)
	{
		tr.fraction = math::max(enter, 0.0f);
		tr.normal = clip_normal;
		tr.brush = index;
	}
}

fn bool Map.point_solid(&self, Vec3 p, TraceMask mask)
{
	Aabb probe = { p, p };
	bool solid = false;
	self.@each_brush(probe; int i)
	{
		if (self.blocks(i, mask) && self.brushes[i].box.contains(p)) solid = true;
	};
	return solid;
}

fn bool Map.box_solid(&self, Vec3 pos, Vec3 mins, Vec3 maxs, TraceMask mask)
{
	Aabb box = { pos + mins, pos + maxs };
	bool solid = false;
	self.@each_brush(box; int i)
	{
		if (self.blocks(i, mask) && self.brushes[i].box.overlaps(box)) solid = true;
	};
	return solid;
}
