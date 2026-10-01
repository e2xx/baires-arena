// Map data and the line-based .map text format (see docs/DESIGN.md).
module arena::map;
import std::math, std::io, std::core::string, arena::mathx, arena::defs;

const int MAX_BRUSHES = 4096;
const int MAX_LIGHTS = 256;
const int MAX_SPAWNS = 64;
const int MAX_PADS = 32;
const int MAX_TELEPORTS = 32;
const int MAX_NAME = 64;
const float GRID_CELL = 4.0f;
const int MAX_GRID_REFS = 65536;

const float PAD_SIZE = 1.6f;
const float PAD_HEIGHT = 0.12f;
const float PAD_TRIGGER_HEIGHT = 0.6f;
const Vec3 TELEPORT_HALF = { 0.7f, 1.0f, 0.7f };

faultdef PARSE_ERROR, TOO_MANY, UNKNOWN_MATERIAL, UNKNOWN_ITEM, UNKNOWN_DIRECTIVE, FILE_ERROR;

struct Brush
{
	Aabb box;
	Material material;
}

struct Light
{
	Vec3 pos;
	Vec3 color;
	float radius;
}

struct Spawn
{
	Vec3 pos;
	float yaw;
}

struct ItemSpot
{
	ItemKind kind;
	Vec3 pos;
}

struct JumpPad
{
	Vec3 pos;        // center of the pad surface
	Vec3 launch;     // velocity applied on touch
	Vec3 apex;       // where the arc peaks (bots aim for it)
	Aabb trigger;
}

struct Teleport
{
	Aabb trigger;
	Vec3 dest;
	float yaw;
}

enum MirrorAxis : char
{
	X,
	Z,
}

// Where a parse error happened, for messages like "subte.map:42: unknown material".
struct ParseReport
{
	int line;
	String what;
}

struct Map
{
	char[MAX_NAME] name_buf;
	usz name_len;
	Vec3 sky;
	Vec3 fog_color;
	float fog_density;
	Vec3 ambient;
	Vec3 sun_dir;
	Vec3 sun_color;

	Brush[MAX_BRUSHES] brushes;
	int brush_count;
	Light[MAX_LIGHTS] lights;
	int light_count;
	Spawn[MAX_SPAWNS] spawns;
	int spawn_count;
	ItemSpot[defs::MAX_ITEMS] items;
	int item_count;
	JumpPad[MAX_PADS] pads;
	int pad_count;
	Teleport[MAX_TELEPORTS] teleports;
	int teleport_count;

	Aabb bounds;

	// Broadphase: uniform grid, brush indices stored CSR-style.
	int gx;
	int gy;
	int gz;
	Vec3 grid_origin;
	int[] cell_start;
	int[MAX_GRID_REFS] cell_refs;
	int ref_count;
}

fn String Map.name(&self) => (String)self.name_buf[:self.name_len];

<*
 Loads and parses a .map file. The returned map is heap allocated: release with Map.free().
*>
fn Map*? load(String path, ParseReport* report)
{
	char[]? data = file::load(mem, path);
	if (catch data)
	{
		report.line = 0;
		report.what = "no se pudo leer el archivo";
		return FILE_ERROR~;
	}
	defer free(data);
	Map* m = mem::new(Map);
	if (catch err = m.parse((String)data, report))
	{
		m.free();
		return err~;
	}
	return m;
}

fn void Map.free(&self)
{
	if (self.cell_start.ptr) free(self.cell_start.ptr);
	free(self);
}

fn void Map.reset(&self)
{
	self.name_len = 0;
	self.sky = { 0.05f, 0.06f, 0.08f };
	self.fog_color = { 0.05f, 0.06f, 0.08f };
	self.fog_density = 0.01f;
	self.ambient = { 0.2f, 0.2f, 0.22f };
	self.sun_dir = { 0.3f, -1.0f, 0.2f };
	self.sun_color = { 0, 0, 0 };
	self.brush_count = 0;
	self.light_count = 0;
	self.spawn_count = 0;
	self.item_count = 0;
	self.pad_count = 0;
	self.teleport_count = 0;
}

// ---------------------------------------------------------------- parsing

const int MAX_TOKENS = 16;

struct Line
{
	String[MAX_TOKENS] tok;
	int count;
}

<*
 Splits on spaces/tabs; a token starting with '"' runs until the closing quote.
*>
fn Line split_line(String s) @local
{
	Line line;
	usz i = 0;
	while (i < s.len && line.count < MAX_TOKENS)
	{
		char c = s[i];
		if (c == ' ' || c == '\t' || c == '\r')
		{
			i++;
			continue;
		}
		if (c == '#') break;
		usz start = i;
		if (c == '"')
		{
			start = i + 1;
			i = start;
			while (i < s.len && s[i] != '"') i++;
			line.tok[line.count++] = s[start:i - start];
			i++;
			continue;
		}
		while (i < s.len && s[i] != ' ' && s[i] != '\t' && s[i] != '\r') i++;
		line.tok[line.count++] = s[start:i - start];
	}
	return line;
}

fn float? Line.num(&self, int i)
{
	if (i >= self.count) return PARSE_ERROR~;
	return self.tok[i].to_float();
}

fn Vec3? Line.vec(&self, int i)
{
	return { self.num(i)!, self.num(i + 1)!, self.num(i + 2)! };
}

fn Material? material_by_id(String id)
{
	foreach (m : Material::values)
	{
		if (m.id == id) return m;
	}
	return UNKNOWN_MATERIAL~;
}

fn ItemKind? item_by_id(String id)
{
	foreach (k : ItemKind::values)
	{
		if (k.id == id) return k;
	}
	return UNKNOWN_ITEM~;
}

fn void? Map.add_brush(&self, Aabb box, Material mat)
{
	if (self.brush_count >= MAX_BRUSHES) return TOO_MANY~;
	self.brushes[self.brush_count++] = { box, mat };
}

<*
 Expands a staircase into one box per step, rising from y0 to y1 along `axis`.
*>
fn void? Map.add_stairs(&self, Aabb box, int steps, String axis, Material mat)
{
	if (steps < 1) return PARSE_ERROR~;
	float rise = (box.max.y - box.min.y) / (float)steps;
	for (int s = 0; s < steps; s++)
	{
		float t0 = (float)s / (float)steps;
		Aabb step = box;
		step.max.y = box.min.y + rise * (float)(s + 1);
		switch (axis)
		{
			case "+x":
				step.min.x = box.min.x + (box.max.x - box.min.x) * t0;
			case "-x":
				step.max.x = box.max.x - (box.max.x - box.min.x) * t0;
			case "+z":
				step.min.z = box.min.z + (box.max.z - box.min.z) * t0;
			case "-z":
				step.max.z = box.max.z - (box.max.z - box.min.z) * t0;
			default:
				return PARSE_ERROR~;
		}
		self.add_brush(step, mat)!;
	}
}

fn void? Map.add_jumppad(&self, Vec3 pos, Vec3 apex)
{
	if (self.pad_count >= MAX_PADS) return TOO_MANY~;
	Vec3 half = { PAD_SIZE * 0.5f, 0, PAD_SIZE * 0.5f };
	self.add_brush({ pos - half, pos + half + (Vec3){ 0, PAD_HEIGHT, 0 } }, JUMPPAD)!;

	Vec3 top = pos + (Vec3){ 0, PAD_HEIGHT, 0 };
	float h = math::max(apex.y - top.y, 0.5f);
	float vy = math::sqrt(2.0f * defs::GRAVITY * h);
	float t = vy / defs::GRAVITY;
	Vec3 launch = { (apex.x - top.x) / t, vy, (apex.z - top.z) / t };
	Aabb trig = { top - half, top + half + (Vec3){ 0, PAD_TRIGGER_HEIGHT, 0 } };
	self.pads[self.pad_count++] = { top, launch, apex, trig };
}

fn void? Map.add_teleport(&self, Vec3 base, Vec3 dest, float yaw)
{
	if (self.teleport_count >= MAX_TELEPORTS) return TOO_MANY~;
	Vec3 center = base + (Vec3){ 0, TELEPORT_HALF.y, 0 };
	self.teleports[self.teleport_count++] = { mathx::aabb_at(center, TELEPORT_HALF), dest, yaw };
}

fn Vec3 mirror_point(Vec3 p, MirrorAxis axis) @local
{
	if (axis == X) return { -p.x, p.y, p.z };
	return { p.x, p.y, -p.z };
}

fn float mirror_yaw(float yaw, MirrorAxis axis) @local
{
	if (axis == X) return -yaw;
	return (float)math::PI - yaw;
}

fn Aabb mirror_box(Aabb b, MirrorAxis axis) @local => mathx::aabb(mirror_point(b.min, axis), mirror_point(b.max, axis));

<*
 Duplicates everything declared so far, mirrored across the given axis.
*>
fn void? Map.mirror(&self, MirrorAxis axis)
{
	int n = self.brush_count;
	for (int i = 0; i < n; i++)
	{
		Brush b = self.brushes[i];
		self.add_brush(mirror_box(b.box, axis), b.material)!;
	}
	n = self.light_count;
	for (int i = 0; i < n; i++)
	{
		if (self.light_count >= MAX_LIGHTS) return TOO_MANY~;
		Light l = self.lights[i];
		l.pos = mirror_point(l.pos, axis);
		self.lights[self.light_count++] = l;
	}
	n = self.spawn_count;
	for (int i = 0; i < n; i++)
	{
		if (self.spawn_count >= MAX_SPAWNS) return TOO_MANY~;
		Spawn s = self.spawns[i];
		self.spawns[self.spawn_count++] = { mirror_point(s.pos, axis), mirror_yaw(s.yaw, axis) };
	}
	n = self.item_count;
	for (int i = 0; i < n; i++)
	{
		if (self.item_count >= defs::MAX_ITEMS) return TOO_MANY~;
		ItemSpot it = self.items[i];
		self.items[self.item_count++] = { it.kind, mirror_point(it.pos, axis) };
	}
	n = self.pad_count;
	for (int i = 0; i < n; i++)
	{
		JumpPad p = self.pads[i];
		// Re-add through add_jumppad so launch velocity is recomputed; it also adds the pad brush,
		// which the brush loop above already mirrored, so drop that duplicate.
		self.add_jumppad(mirror_point(p.pos - (Vec3){ 0, PAD_HEIGHT, 0 }, axis), mirror_point(p.apex, axis))!;
		self.brush_count--;
	}
	n = self.teleport_count;
	for (int i = 0; i < n; i++)
	{
		if (self.teleport_count >= MAX_TELEPORTS) return TOO_MANY~;
		Teleport t = self.teleports[i];
		self.teleports[self.teleport_count++] = { mirror_box(t.trigger, axis), mirror_point(t.dest, axis), mirror_yaw(t.yaw, axis) };
	}
}

fn void? Map.parse_line(&self, Line* l)
{
	String d = l.tok[0];
	switch (d)
	{
		case "name":
			if (l.count < 2) return PARSE_ERROR~;
			String n = l.tok[1];
			self.name_len = n.len < MAX_NAME ? n.len : MAX_NAME;
			self.name_buf[:self.name_len] = n[:self.name_len];
		case "sky":
			self.sky = l.vec(1)!;
		case "fog":
			self.fog_color = l.vec(1)!;
			self.fog_density = l.num(4)!;
		case "ambient":
			self.ambient = l.vec(1)!;
		case "sun":
			self.sun_dir = l.vec(1)!.normalize();
			self.sun_color = l.vec(4)!;
		case "box":
			if (l.count < 8) return PARSE_ERROR~;
			self.add_brush(mathx::aabb(l.vec(1)!, l.vec(4)!), material_by_id(l.tok[7])!)!;
		case "stairs":
			if (l.count < 10) return PARSE_ERROR~;
			int steps = (int)l.num(7)!;
			self.add_stairs(mathx::aabb(l.vec(1)!, l.vec(4)!), steps, l.tok[8], material_by_id(l.tok[9])!)!;
		case "light":
			if (self.light_count >= MAX_LIGHTS) return TOO_MANY~;
			self.lights[self.light_count++] = { l.vec(1)!, l.vec(4)!, l.num(7)! };
		case "spawn":
			if (self.spawn_count >= MAX_SPAWNS) return TOO_MANY~;
			self.spawns[self.spawn_count++] = { l.vec(1)!, l.num(4)! * mathx::DEG };
		case "item":
			if (l.count < 5) return PARSE_ERROR~;
			if (self.item_count >= defs::MAX_ITEMS) return TOO_MANY~;
			self.items[self.item_count++] = { item_by_id(l.tok[1])!, l.vec(2)! };
		case "jumppad":
			self.add_jumppad(l.vec(1)!, l.vec(4)!)!;
		case "teleport":
			self.add_teleport(l.vec(1)!, l.vec(4)!, l.num(7)! * mathx::DEG)!;
		case "mirror":
			if (l.count < 2) return PARSE_ERROR~;
			switch (l.tok[1])
			{
				case "x": self.mirror(X)!;
				case "z": self.mirror(Z)!;
				default: return PARSE_ERROR~;
			}
		default:
			return UNKNOWN_DIRECTIVE~;
	}
}

fn void? Map.parse(&self, String text, ParseReport* report)
{
	self.reset();
	int line_no = 0;
	Splitter lines = text.tokenize_all("\n");
	while (try raw = lines.next())
	{
		line_no++;
		Line l = split_line(raw);
		if (l.count == 0) continue;
		if (catch err = self.parse_line(&l))
		{
			report.line = line_no;
			report.what = describe(err);
			return err~;
		}
	}
	if (self.brush_count == 0 || self.spawn_count == 0)
	{
		report.line = line_no;
		report.what = "el mapa necesita brushes y al menos un spawn";
		return PARSE_ERROR~;
	}
	self.finish();
}

fn String describe(fault err)
{
	switch (err)
	{
		case TOO_MANY: return "demasiados elementos";
		case UNKNOWN_MATERIAL: return "material desconocido";
		case UNKNOWN_ITEM: return "item desconocido";
		case UNKNOWN_DIRECTIVE: return "directiva desconocida";
		default: return "error de sintaxis";
	}
}

// ---------------------------------------------------------------- broadphase

fn void Map.finish(&self)
{
	Aabb b = self.brushes[0].box;
	for (int i = 1; i < self.brush_count; i++) b = b.merge(self.brushes[i].box);
	self.bounds = b;
	self.build_grid();
}

fn void Map.cell_range(&self, Aabb box, int* lo, int* hi)
{
	Vec3 a = (box.min - self.grid_origin) / GRID_CELL;
	Vec3 c = (box.max - self.grid_origin) / GRID_CELL;
	lo[0] = math::clamp((int)math::floor(a.x), 0, self.gx - 1);
	lo[1] = math::clamp((int)math::floor(a.y), 0, self.gy - 1);
	lo[2] = math::clamp((int)math::floor(a.z), 0, self.gz - 1);
	hi[0] = math::clamp((int)math::floor(c.x), 0, self.gx - 1);
	hi[1] = math::clamp((int)math::floor(c.y), 0, self.gy - 1);
	hi[2] = math::clamp((int)math::floor(c.z), 0, self.gz - 1);
}

fn void Map.build_grid(&self)
{
	Vec3 pad = { GRID_CELL, GRID_CELL, GRID_CELL };
	self.grid_origin = self.bounds.min - pad;
	Vec3 size = self.bounds.size() + pad * 2.0f;
	self.gx = math::max(1, (int)math::ceil(size.x / GRID_CELL));
	self.gy = math::max(1, (int)math::ceil(size.y / GRID_CELL));
	self.gz = math::max(1, (int)math::ceil(size.z / GRID_CELL));
	int cells = self.gx * self.gy * self.gz;
	if (self.cell_start.ptr) free(self.cell_start.ptr);
	self.cell_start = mem::new_array(int, (sz)cells + 1);

	// Pass 1: count refs per cell. Pass 2: prefix sum. Pass 3: fill.
	int[3] lo;
	int[3] hi;
	for (int i = 0; i < self.brush_count; i++)
	{
		self.cell_range(self.brushes[i].box, &lo, &hi);
		for (int z = lo[2]; z <= hi[2]; z++)
		{
			for (int y = lo[1]; y <= hi[1]; y++)
			{
				for (int x = lo[0]; x <= hi[0]; x++) self.cell_start[(z * self.gy + y) * self.gx + x + 1]++;
			}
		}
	}
	for (int c = 0; c < cells; c++) self.cell_start[c + 1] += self.cell_start[c];
	self.ref_count = math::min(self.cell_start[cells], MAX_GRID_REFS);

	int[] cursor = mem::new_array(int, cells);
	defer free(cursor);
	cursor[..] = self.cell_start[:cells];
	for (int i = 0; i < self.brush_count; i++)
	{
		self.cell_range(self.brushes[i].box, &lo, &hi);
		for (int z = lo[2]; z <= hi[2]; z++)
		{
			for (int y = lo[1]; y <= hi[1]; y++)
			{
				for (int x = lo[0]; x <= hi[0]; x++)
				{
					int k = cursor[(z * self.gy + y) * self.gx + x]++;
					if (k < MAX_GRID_REFS) self.cell_refs[k] = i;
				}
			}
		}
	}
}

<*
 Visits each brush whose grid cells overlap `box`. A brush spanning several cells is visited
 once per cell; callers must be idempotent (trace keeps the nearest hit, so it is).
*>
macro void Map.@each_brush(&self, Aabb box; @body(int index))
{
	int[3] lo;
	int[3] hi;
	self.cell_range(box, &lo, &hi);
	for (int z = lo[2]; z <= hi[2]; z++)
	{
		for (int y = lo[1]; y <= hi[1]; y++)
		{
			for (int x = lo[0]; x <= hi[0]; x++)
			{
				int c = (z * self.gy + y) * self.gx + x;
				int end = math::min(self.cell_start[c + 1], MAX_GRID_REFS);
				for (int k = self.cell_start[c]; k < end; k++) @body(self.cell_refs[k]);
			}
		}
	}
}
