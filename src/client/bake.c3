// Lighting baker: turns brushes into lit triangles (per-vertex light with shadows + AO)
// and fills a coarse light-probe grid for dynamic objects. CPU only, multithreaded.
module arena::bake;
import std::math, std::os, std::thread, std::collections::list, std::time::clock;
import arena::mathx, arena::defs, arena::map;

const float CELL = 1.0f;
const int AO_RAYS = 14;
const float AO_RANGE = 2.2f;
const float AO_STRENGTH = 0.8f;
const float NORMAL_OFFSET = 0.03f;
const float SUN_RANGE = 400.0f;
const float FIXTURE_SLACK = 0.35f;     // shadow rays may stop this close to a light (its own fixture)
const float PROBE_SPACING = 2.0f;
const float TEXTURE_METERS = 2.0f;     // one texture repeat every 2 m
const Vec3 EMISSIVE_LIGHT = { 1.7f, 1.7f, 1.7f };
const int MAX_WORKERS = 32;

struct Vertex
{
	Vec3 pos;
	Vec3 normal;
	Vec3 light;   // linear RGB, may exceed 1 (overbright)
	float u;
	float v;
}

alias VertexList = List{Vertex};

struct Baked
{
	VertexList[Material::len] tris;   // 3 vertices per triangle, grouped by material
	Vec3 probe_origin;
	int px;
	int py;
	int pz;
	Vec3[] probes;
	float seconds;
	int face_count;
}

// One brush face to subdivide; light values live in a shared array at `light_base`.
struct Face @local
{
	int brush;
	int axis;
	float sign;
	Vec3 origin;
	Vec3 a;          // edge vector along the first face axis (full length)
	Vec3 b;
	int nu;
	int nv;
	int light_base;  // (nu + 1) * (nv + 1) entries
	int cell_base;   // nu * nv visibility flags
}

struct Job @local
{
	Map* map;
	Face[] faces;
	Vec3[] lights;
	bool[] visible;
	int from;
	int to;
	Baked* out;
}

fn void Baked.free(&self)
{
	foreach (&l : self.tris) l.free();
	if (self.probes.ptr) free(self.probes.ptr);
}

fn sz Baked.vertex_count(&self)
{
	sz n;
	foreach (&l : self.tris) n += l.len();
	return n;
}

// ---------------------------------------------------------------- sampling

<*
 Cosine-ish hemisphere directions around n (fixed pattern, deterministic).
*>
fn Vec3 hemisphere(Vec3 n, int i) @local
{
	float golden = 2.39996323f;
	float t = ((float)i + 0.5f) / (float)AO_RAYS;
	float r = math::sqrt(t);
	float phi = (float)i * golden;
	Vec3 tangent = math::abs(n.y) < 0.9f ? n.cross({ 0, 1, 0 }).normalize() : n.cross({ 1, 0, 0 }).normalize();
	Vec3 bitangent = n.cross(tangent);
	float h = math::sqrt(math::max(1.0f - t, 0.0f));
	return (tangent * (math::cos(phi) * r) + bitangent * (math::sin(phi) * r) + n * h).normalize();
}

fn float ambient_occlusion(Map* m, Vec3 p, Vec3 n) @local
{
	int hits;
	for (int i = 0; i < AO_RAYS; i++)
	{
		Vec3 d = hemisphere(n, i);
		if (m.trace_ray(p, p + d * AO_RANGE, SHOT).fraction < 1.0f) hits++;
	}
	return 1.0f - AO_STRENGTH * (float)hits / (float)AO_RAYS;
}

fn bool lit_by(Map* m, Vec3 p, Vec3 target) @local
{
	Trace tr = m.trace_ray(p, target, SHOT);
	if (tr.fraction >= 1.0f) return true;
	float total = (target - p).length();
	return total * (1.0f - tr.fraction) < FIXTURE_SLACK;
}

<*
 Light arriving at p. With a zero normal (probes) surfaces are treated as facing every light.
*>
fn Vec3 light_at(Map* m, Vec3 p, Vec3 n, float ao) @local
{
	bool omni = n.length_sq() < 0.5f;
	Vec3 sum = m.ambient * ao;

	if (m.sun_color.length_sq() > 0)
	{
		float ndl = omni ? 1.0f : n.dot(-m.sun_dir);
		if (ndl > 0 && lit_by(m, p, p - m.sun_dir * SUN_RANGE)) sum += m.sun_color * ndl;
	}

	for (int i = 0; i < m.light_count; i++)
	{
		Light* l = &m.lights[i];
		Vec3 to = l.pos - p;
		float d = to.length();
		if (d >= l.radius || d < 0.001f) continue;
		Vec3 dir = to / d;
		float ndl = omni ? 1.0f : n.dot(dir);
		if (ndl <= 0) continue;
		float att = 1.0f - d / l.radius;
		att *= att;
		if (!lit_by(m, p, l.pos)) continue;
		sum += l.color * (ndl * att);
	}
	return sum;
}

// ---------------------------------------------------------------- faces

fn void collect_faces(Map* m, List{Face}* faces, int* light_total, int* cell_total) @local
{
	for (int bi = 0; bi < m.brush_count; bi++)
	{
		Brush* br = &m.brushes[bi];
		if (br.material.surface == INVISIBLE) continue;
		Aabb box = br.box;
		Vec3 size = box.size();
		for (int k = 0; k < 3; k++)
		{
			for (int s = 0; s < 2; s++)
			{
				float sign = s == 0 ? 1.0f : -1.0f;
				int i = (k + 1) % 3;
				int j = (k + 2) % 3;
				Vec3 ei;
				Vec3 ej;
				ei[i] = size[i];
				ej[j] = size[j];
				// a x b must point along the outward normal.
				Vec3 a = sign > 0 ? ei : ej;
				Vec3 b = sign > 0 ? ej : ei;
				Vec3 origin = box.min;
				origin[k] = sign > 0 ? box.max[k] : box.min[k];
				int nu = math::max(1, (int)math::ceil(a.length() / CELL));
				int nv = math::max(1, (int)math::ceil(b.length() / CELL));
				faces.push({ bi, k, sign, origin, a, b, nu, nv, *light_total, *cell_total });
				*light_total += (nu + 1) * (nv + 1);
				*cell_total += nu * nv;
			}
		}
	}
}

fn void bake_face(Job* job, Face* f) @local
{
	Map* m = job.map;
	Vec3 n;
	n[f.axis] = f.sign;
	Material mat = m.brushes[f.brush].material;

	// Visibility per cell: drop cells buried inside other brushes.
	for (int v = 0; v < f.nv; v++)
	{
		for (int u = 0; u < f.nu; u++)
		{
			Vec3 c = f.origin + f.a * (((float)u + 0.5f) / (float)f.nu) + f.b * (((float)v + 0.5f) / (float)f.nv);
			job.visible[f.cell_base + v * f.nu + u] = !m.point_solid(c + n * 0.01f, SHOT);
		}
	}

	for (int v = 0; v <= f.nv; v++)
	{
		for (int u = 0; u <= f.nu; u++)
		{
			int idx = f.light_base + v * (f.nu + 1) + u;
			if (mat.surface == EMISSIVE)
			{
				job.lights[idx] = EMISSIVE_LIGHT;
				continue;
			}
			// Sample slightly inside the face so corner vertices don't sit in neighbouring walls.
			float fu = math::clamp((float)u / (float)f.nu, 0.02f, 0.98f);
			float fv = math::clamp((float)v / (float)f.nv, 0.02f, 0.98f);
			Vec3 p = f.origin + f.a * fu + f.b * fv + n * NORMAL_OFFSET;
			job.lights[idx] = light_at(m, p, n, ambient_occlusion(m, p, n));
		}
	}
}

fn int face_worker(void* arg) @local
{
	Job* job = arg;
	for (int i = job.from; i < job.to; i++) bake_face(job, &job.faces[i]);
	return 0;
}

fn void uv_for(Vec3 p, int axis, float* u, float* v) @local
{
	switch (axis)
	{
		case 0:
			*u = p.z / TEXTURE_METERS;
			*v = -p.y / TEXTURE_METERS;
		case 1:
			*u = p.x / TEXTURE_METERS;
			*v = p.z / TEXTURE_METERS;
		default:
			*u = p.x / TEXTURE_METERS;
			*v = -p.y / TEXTURE_METERS;
	}
}

fn void emit_face(Baked* out, Map* m, Face* f, Vec3[] lights, bool[] visible) @local
{
	Vec3 n;
	n[f.axis] = f.sign;
	VertexList* list = &out.tris[(int)m.brushes[f.brush].material];
	for (int v = 0; v < f.nv; v++)
	{
		for (int u = 0; u < f.nu; u++)
		{
			if (!visible[f.cell_base + v * f.nu + u]) continue;
			Vertex[4] q;
			int[2][4] corner = { { 0, 0 }, { 1, 0 }, { 1, 1 }, { 0, 1 } };
			for (int c = 0; c < 4; c++)
			{
				int cu = u + corner[c][0];
				int cv = v + corner[c][1];
				Vec3 p = f.origin + f.a * ((float)cu / (float)f.nu) + f.b * ((float)cv / (float)f.nv);
				q[c] = { .pos = p, .normal = n, .light = lights[f.light_base + cv * (f.nu + 1) + cu] };
				uv_for(p, f.axis, &q[c].u, &q[c].v);
			}
			list.push(q[0]);
			list.push(q[1]);
			list.push(q[2]);
			list.push(q[0]);
			list.push(q[2]);
			list.push(q[3]);
		}
	}
}

// ---------------------------------------------------------------- probes

struct ProbeJob @local
{
	Map* map;
	Baked* out;
	int from;
	int to;
}

fn Vec3 Baked.probe_pos(&self, int x, int y, int z) => self.probe_origin + (Vec3){ (float)x, (float)y, (float)z } * PROBE_SPACING;

fn int probe_worker(void* arg) @local
{
	ProbeJob* job = arg;
	Baked* b = job.out;
	for (int i = job.from; i < job.to; i++)
	{
		int x = i % b.px;
		int y = (i / b.px) % b.py;
		int z = i / (b.px * b.py);
		Vec3 p = b.probe_pos(x, y, z);
		if (job.map.point_solid(p, SHOT))
		{
			b.probes[i] = { -1, -1, -1 };   // marker: inside geometry, skipped when sampling
			continue;
		}
		b.probes[i] = light_at(job.map, p, { 0, 0, 0 }, 1.0f);
	}
	return 0;
}

<*
 Trilinear light at p from the probe grid, ignoring probes buried in walls.
*>
fn Vec3 Baked.sample(&self, Vec3 p)
{
	if (self.probes.len == 0) return { 1, 1, 1 };
	Vec3 g = (p - self.probe_origin) / PROBE_SPACING;
	int x0 = math::clamp((int)math::floor(g.x), 0, self.px - 2);
	int y0 = math::clamp((int)math::floor(g.y), 0, self.py - 2);
	int z0 = math::clamp((int)math::floor(g.z), 0, self.pz - 2);
	Vec3 f = math::clamp(g - (Vec3){ (float)x0, (float)y0, (float)z0 }, (Vec3){ 0, 0, 0 }, (Vec3){ 1, 1, 1 });
	Vec3 sum;
	float wsum = 0;
	for (int c = 0; c < 8; c++)
	{
		int dx = c & 1;
		int dy = (c >> 1) & 1;
		int dz = (c >> 2) & 1;
		Vec3 val = self.probes[((z0 + dz) * self.py + (y0 + dy)) * self.px + (x0 + dx)];
		if (val.x < 0) continue;
		float w = (dx == 1 ? f.x : 1 - f.x) * (dy == 1 ? f.y : 1 - f.y) * (dz == 1 ? f.z : 1 - f.z);
		sum += val * w;
		wsum += w;
	}
	if (wsum < 0.0001f) return { 0.3f, 0.3f, 0.3f };
	return sum / wsum;
}

// ---------------------------------------------------------------- driver

<*
 Splits [0, count) into `workers` ranges; job i is a copy of `proto` with from/to set.
 The calling thread runs range 0 itself.
*>
macro void run_parallel(int count, int workers, proto, ThreadFn worker)
{
	$Typeof(proto)[MAX_WORKERS] jobs;
	Thread[MAX_WORKERS] threads;
	int chunk = (count + workers - 1) / workers;
	for (int w = 0; w < workers; w++)
	{
		jobs[w] = proto;
		jobs[w].from = math::min(w * chunk, count);
		jobs[w].to = math::min((w + 1) * chunk, count);
	}
	for (int w = 1; w < workers; w++)
	{
		if (catch threads[w].create(worker, &jobs[w])) worker(&jobs[w]);
	}
	worker(&jobs[0]);
	for (int w = 1; w < workers; w++) (void)threads[w].join();
}

fn Baked* bake(Map* m)
{
	Clock clock = clock::now();
	Baked* out = mem::new(Baked);
	foreach (&l : out.tris) l.init(mem);
	int workers = math::clamp(os::num_cpu(), 1, MAX_WORKERS);

	List{Face} faces;
	faces.init(mem);
	defer faces.free();
	int light_total;
	int cell_total;
	collect_faces(m, &faces, &light_total, &cell_total);
	out.face_count = (int)faces.len();

	Vec3[] lights = mem::new_array(Vec3, (sz)light_total);
	defer free(lights);
	bool[] visible = mem::new_array(bool, (sz)cell_total);
	defer free(visible);

	Face[] face_arr = faces.array_view();
	run_parallel((int)face_arr.len, workers, (Job){ .map = m, .faces = face_arr, .lights = lights, .visible = visible, .out = out }, &face_worker);
	foreach (&f : face_arr) emit_face(out, m, f, lights, visible);

	// Probe grid covering the map bounds.
	Vec3 size = m.bounds.size();
	out.probe_origin = m.bounds.min;
	out.px = math::max(2, (int)math::ceil(size.x / PROBE_SPACING) + 1);
	out.py = math::max(2, (int)math::ceil(size.y / PROBE_SPACING) + 1);
	out.pz = math::max(2, (int)math::ceil(size.z / PROBE_SPACING) + 1);
	int probe_count = out.px * out.py * out.pz;
	out.probes = mem::new_array(Vec3, (sz)probe_count);
	run_parallel(probe_count, workers, (ProbeJob){ .map = m, .out = out }, &probe_worker);

	out.seconds = (float)clock.mark().to_sec();
	return out;
}
