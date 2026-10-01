// Navigation graph generated from the map brushes, plus A* path search. Used by the bots.
//
// Nodes sit on walkable brush tops, sampled on a world grid where the player hull fits.
// Links: walks (hull sweeps with step-up), jumps and drops (ballistic hull sweeps, optionally
// re-checked with pmove itself), jump pads and teleporters (simulated with pmove).
module arena::nav;
import std::math, std::os, std::thread, std::time::clock;
import std::collections::list, std::collections::priorityqueue;
import arena::mathx, arena::defs, arena::map, arena::pmove;

const float SPACING = 1.5f;          // sample grid on walkable tops
const float CELL = 2.0f;             // spatial hash cell (xz)
const float MERGE_DIST = 0.6f;       // samples closer than this (and level) are duplicates
const float MERGE_HEIGHT = 0.3f;
const float LIFT = 0.05f;            // traces start this far above the floor
const float FIT_LIFT = 0.01f;
const float TRIGGER_MARGIN = 0.3f;   // keep plain nodes this far from pads and teleporters
const float WALK_RADIUS = 2.3f;      // grid neighbours, diagonals included
const float TRIGGER_RADIUS = 3.6f;   // walks into pad/teleport nodes (ground nodes keep away)
const float WALK_SUBSTEP = 0.5f;     // each sub-step may climb one STEP_HEIGHT
const float PROBE_STEP = 0.75f;      // ground probes along a flat walk
const float JUMP_RADIUS = 2.6f;      // jump up onto a ledge
const float GAP_RADIUS = 3.6f;       // jump across a hole
const float DROP_RADIUS = 2.6f;
const float MAX_DROP = 6.0f;
const float JUMP_UP = 1.3f;          // highest ledge the ballistic check accepts
const float JUMP_UP_PMOVE = 1.9f;    // pmove can also step up onto the ledge while falling
const float EDGE_STEP = 0.3f;        // ledge search resolution
const int ARC_SEGMENTS = 6;
const float TAKEOFF_MIN = 3.0f;      // m/s
const float TAKEOFF_MARGIN = 1.1f;   // aim a bit long: landing short is worse than long
const float TAKEOFF_EXTRA = 0.5f;
const float AIR_SLACK = 0.5f;        // m/s of air-speed error tolerated before steering
const int SIM_TICKS = 120;
const int TRIGGER_TICKS = 480;
const float SIM_REACH = 0.6f;
const float SIM_LEVEL = 0.25f;
const float SIM_TAKEOFF = 0.3f;
const float LANDING_RADIUS = 3.0f;
const float SPAWN_RADIUS = 3.0f;
const float TELEPORT_COST = 1.0f;
const float EYE_LIFT = 0.5f;         // visibility rays between nodes run this high
const float NEAR_RADIUS = 4.0f;
const int NEAR_CHECKS = 8;
const int MAX_LINKS = 24;
const int MAX_SPECIAL = 4;           // jump/drop links per node
const int MAX_SPECIAL_TRIES = 8;
const int MAX_CANDIDATES = 96;
const int MIN_ISLAND = 6;
const int MAX_WORKERS = 32;

const Vec3 UP_LIFT = { 0, LIFT, 0 };
const float[2] NUDGE_DIST = { 0.3f, 0.6f };
const Vec3[8] NUDGES = {
	{ 1, 0, 0 }, { -1, 0, 0 }, { 0, 0, 1 }, { 0, 0, -1 },
	{ 0.7071f, 0, 0.7071f }, { -0.7071f, 0, 0.7071f }, { 0.7071f, 0, -0.7071f }, { -0.7071f, 0, -0.7071f }
};

faultdef NO_SPOT, NO_LINK;

enum NodeKind : char (String label)
{
	GROUND { "ground" },
	PAD { "pad" },              // standing here fires the jump pad `ref`
	TELEPORT { "teleport" },    // standing here fires the teleporter `ref`
}

enum LinkKind : char (String label, float cost_factor)
{
	WALK { "walk", 1.0f },
	JUMP { "jump", 1.6f },
	DROP { "drop", 1.2f },
	PAD { "pad", 1.0f },
	TELEPORT { "teleport", 0.0f },
}

// How carefully jump and drop links are checked while building.
enum Verify : char
{
	GEOMETRY,   // ballistic hull sweeps only (fast)
	PMOVE,      // also replay each one with pmove and the bot's controller (slow, exact)
}

struct NavNode
{
	Vec3 pos;        // feet position, on the floor
	NodeKind kind;
	int ref;         // pad / teleport index, -1 for ground nodes
	int first;       // first outgoing link
	int count;
	int island;      // undirected component: different islands never connect
	bool reach;      // reachable from a spawn point (only these make sensible goals)
}

struct NavLink
{
	int to;
	float cost;
	LinkKind kind;
	float speed;     // jumps and drops: horizontal take-off speed (m/s); 0 = any
}

struct NavStats
{
	int samples;
	int nodes;
	int links;
	int[LinkKind::len] by_kind;
	int pruned;
	int rejected;    // jump/drop links dropped by the pmove check
	int workers;
	float ms;
}

struct Warp
{
	Vec3 entry;
	Vec3 exit;
}

// Uniform xz grid over node indices (CSR layout).
struct CellIndex
{
	Vec3 origin;
	int nx;
	int nz;
	int[] start;
	int[] items;
}

struct OpenEntry
{
	float f;
	int node;
}

fn bool OpenEntry.less(self, OpenEntry other) => self.f < other.f;

struct NavGraph
{
	Map* map;
	NavNode[] nodes;
	NavLink[] links;
	CellIndex index;
	Warp[map::MAX_TELEPORTS] warps;
	int warp_count;
	NavStats stats;
	// A* scratch, reused by every search: path() is not thread safe.
	float[] cost;
	int[] parent;
	uint[] seen;
	uint[] closed;
	uint search;
	PriorityQueue{OpenEntry} open;
}

// Fixed link slots per node while building; jobs only ever write their own node's slots.
struct LinkTable
{
	NavLink[] slots;
	int[] count;
	int[] walk_count;
}

struct LinkJob @local
{
	NavGraph* g;
	LinkTable* table;
	Verify verify;
	int offset;
	int stride;
	int rejected;
}

struct Candidate @local
{
	int node;
	float dist;
	LinkKind kind;
}

// ---------------------------------------------------------------- small helpers

macro Vec3 flat(Vec3 v) => { v.x, 0, v.z };

macro float hlen(Vec3 v) => math::sqrt(v.x * v.x + v.z * v.z);

macro void @release(#slice)
{
	if (#slice.ptr) free(#slice.ptr);
	#slice = {};
}

fn Trace hull_trace(Map* m, Vec3 a, Vec3 b) @local => m.trace(a, b, defs::PLAYER_MINS, defs::PLAYER_MAXS, PLAYER);

fn bool hull_fits(Map* m, Vec3 p) @local
{
	return !m.box_solid(p + (Vec3){ 0, FIT_LIFT, 0 }, defs::PLAYER_MINS, defs::PLAYER_MAXS, PLAYER);
}

fn bool has_ground(Map* m, Vec3 p) @local
{
	Trace tr = hull_trace(m, p + UP_LIFT, p - UP_LIFT);
	return !tr.startsolid && tr.fraction < 1.0f;
}

fn bool clear(Map* m, Vec3 a, Vec3 b) @local
{
	Trace tr = hull_trace(m, a, b);
	return !tr.startsolid && tr.fraction == 1.0f;
}

<*
 Calls the body with every grid coordinate in [lo, hi), or with the middle if none fits.
*>
macro void @each_axis_sample(float lo, float hi; @body(float v))
{
	int k0 = (int)math::ceil(lo / SPACING);
	int k1 = (int)math::ceil(hi / SPACING) - 1;
	if (k1 < k0)
	{
		@body((lo + hi) * 0.5f);
	}
	else
	{
		for (int k = k0; k <= k1; k++) @body((float)k * SPACING);
	}
}

// Horizontal speed to cover `dist` in `secs`, padded so bots rather land long than short.
fn float takeoff_speed(float dist, float secs) @local
{
	float s = dist / math::max(secs, 0.05f);
	return math::clamp(s * TAKEOFF_MARGIN + TAKEOFF_EXTRA, TAKEOFF_MIN, defs::RUN_SPEED);
}

// Time for a jump (vy0 = JUMP_VELOCITY) to come back down to height dy, or -1 if it never gets there.
fn float jump_land_time(float dy) @local
{
	float v = defs::JUMP_VELOCITY;
	float disc = v * v - 2.0f * defs::GRAVITY * dy;
	if (disc < 0) return -1.0f;
	return (v + math::sqrt(disc)) / defs::GRAVITY;
}

<*
 Air control toward a target: the flat direction to push (or zero to coast) so the current
 flight lands on it. Steers the error between the velocity we have and the one we need.
 Shared by the bots and by the pmove link check so both fly the same way.
*>
fn Vec3 air_wish(Vec3 pos, Vec3 vel, Vec3 target)
{
	Vec3 to = flat(target - pos);
	float dist = to.length();
	float disc = vel.y * vel.y - 2.0f * defs::GRAVITY * (target.y - pos.y);
	if (disc < 0) return dist > 0.05f ? to / dist : (Vec3){};   // can't get that high: push on
	float secs = math::max((vel.y + math::sqrt(disc)) / defs::GRAVITY, 0.05f);
	Vec3 diff = to / secs - flat(vel);
	float len = diff.length();
	if (len < AIR_SLACK) return {};
	return diff / len;
}

// ---------------------------------------------------------------- spatial index

fn int CellIndex.cell_x(&self, float x) => math::clamp((int)math::floor((x - self.origin.x) / CELL), 0, self.nx - 1);

fn int CellIndex.cell_z(&self, float z) => math::clamp((int)math::floor((z - self.origin.z) / CELL), 0, self.nz - 1);

fn int CellIndex.cell_of(&self, Vec3 p) => self.cell_z(p.z) * self.nx + self.cell_x(p.x);

fn void CellIndex.build(&self, Aabb bounds, NavNode[] nodes)
{
	self.release();
	self.origin = bounds.min - (Vec3){ CELL, 0, CELL };
	Vec3 size = bounds.size();
	self.nx = (int)math::ceil(size.x / CELL) + 3;
	self.nz = (int)math::ceil(size.z / CELL) + 3;
	int cells = self.nx * self.nz;
	self.start = mem::new_array(int, (sz)cells + 1);
	self.items = mem::new_array(int, (sz)nodes.len + 1);
	foreach (&n : nodes) self.start[self.cell_of(n.pos) + 1]++;
	for (int c = 0; c < cells; c++) self.start[c + 1] += self.start[c];
	int[] cursor = mem::new_array(int, (sz)cells);
	defer free(cursor);
	cursor[..] = self.start[:cells];
	foreach (i, &n : nodes) self.items[cursor[self.cell_of(n.pos)]++] = (int)i;
}

fn void CellIndex.release(&self)
{
	@release(self.start);
	@release(self.items);
}

<*
 Visits every indexed node in the cells overlapping the square of `radius` around p.
*>
macro void CellIndex.@each_near(&self, Vec3 p, float radius; @body(int index))
{
	int x0 = self.cell_x(p.x - radius);
	int x1 = self.cell_x(p.x + radius);
	int z0 = self.cell_z(p.z - radius);
	int z1 = self.cell_z(p.z + radius);
	for (int z = z0; z <= z1; z++)
	{
		for (int x = x0; x <= x1; x++)
		{
			int c = z * self.nx + x;
			for (int k = self.start[c]; k < self.start[c + 1]; k++) @body(self.items[k]);
		}
	}
}

// ---------------------------------------------------------------- link table

fn void LinkTable.init(&self, int nodes)
{
	self.slots = mem::new_array(NavLink, (sz)nodes * MAX_LINKS + 1);
	self.count = mem::new_array(int, (sz)nodes + 1);
	self.walk_count = mem::new_array(int, (sz)nodes + 1);
}

fn void LinkTable.release(&self)
{
	@release(self.slots);
	@release(self.count);
	@release(self.walk_count);
}

fn void LinkTable.add(&self, int a, NavLink link)
{
	if (self.count[a] >= MAX_LINKS) return;
	self.slots[a * MAX_LINKS + self.count[a]++] = link;
}

fn NavLink[] LinkTable.of(&self, int a) => self.slots[a * MAX_LINKS : self.count[a]];

fn bool LinkTable.has(&self, int a, int b)
{
	foreach (&l : self.of(a))
	{
		if (l.to == b) return true;
	}
	return false;
}

// ---------------------------------------------------------------- build

<*
 Builds the navigation graph of a parsed map. Release with NavGraph.free().
 `threads` = 0 uses one worker per CPU.
 @require m != null && m.brush_count > 0
 @require threads >= 0
*>
fn NavGraph* build(Map* m, Verify verify = PMOVE, int threads = 0)
{
	Clock clock = clock::now();
	NavGraph* g = mem::new(NavGraph);
	g.map = m;
	g.open.init(mem);
	g.stats.workers = math::clamp(threads > 0 ? threads : os::num_cpu(), 1, MAX_WORKERS);

	List{NavNode} samples;
	samples.init(mem);
	defer samples.free();
	add_trigger_nodes(m, &samples);
	sample_floors(m, &samples);
	g.stats.samples = (int)samples.len();
	g.nodes = dedupe(m, samples.array_view());
	g.index.build(m.bounds, g.nodes);

	LinkTable table;
	table.init((int)g.nodes.len);
	defer table.release();
	run_jobs(g, &table, verify, &walk_worker);
	mirror_walks(g, &table);
	g.stats.rejected = run_jobs(g, &table, verify, &special_worker);
	trigger_links(g, &table);
	g.compact(&table);
	g.stats.ms = (float)clock.mark().to_sec() * 1000.0f;
	return g;
}

fn void NavGraph.free(&self)
{
	@release(self.nodes);
	@release(self.links);
	@release(self.cost);
	@release(self.parent);
	@release(self.seen);
	@release(self.closed);
	self.index.release();
	self.open.free();
	free(self);
}

fn void add_trigger_nodes(Map* m, List{NavNode}* out) @local
{
	for (int i = 0; i < m.pad_count; i++)
	{
		out.push({ .pos = m.pads[i].pos, .kind = PAD, .ref = i });
	}
	for (int i = 0; i < m.teleport_count; i++)
	{
		Aabb t = m.teleports[i].trigger;
		Vec3 base = { (t.min.x + t.max.x) * 0.5f, t.min.y, (t.min.z + t.max.z) * 0.5f };
		Trace tr = hull_trace(m, base + (Vec3){ 0, 0.5f, 0 }, base - (Vec3){ 0, 1.5f, 0 });
		Vec3 pos = tr.fraction < 1.0f && !tr.startsolid ? tr.endpos : base;
		out.push({ .pos = pos, .kind = TELEPORT, .ref = i });
	}
}

fn void sample_floors(Map* m, List{NavNode}* out) @local
{
	for (int i = 0; i < m.brush_count; i++)
	{
		Brush* b = &m.brushes[i];
		if (b.material == JUMPPAD) continue;
		float y = b.box.max.y;
		@each_axis_sample(b.box.min.x, b.box.max.x; float x)
		{
			@each_axis_sample(b.box.min.z, b.box.max.z; float z)
			{
				try_sample(m, { x, y, z }, out);
			};
		};
	}
}

fn void try_sample(Map* m, Vec3 p, List{NavNode}* out) @local
{
	Vec3? spot = fit_spot(m, p);
	if (catch spot) return;
	if (near_trigger(m, spot)) return;
	out.push({ .pos = spot, .kind = GROUND, .ref = -1 });
}

<*
 p itself if the hull fits there, else the first nudged spot that fits and has ground.
*>
fn Vec3? fit_spot(Map* m, Vec3 p) @local
{
	if (hull_fits(m, p)) return p;
	foreach (dist : NUDGE_DIST)
	{
		foreach (d : NUDGES)
		{
			Vec3 q = p + d * dist;
			if (hull_fits(m, q) && has_ground(m, q)) return q;
		}
	}
	return NO_SPOT~;
}

fn bool near_trigger(Map* m, Vec3 p) @local
{
	Vec3 margin = { TRIGGER_MARGIN, 0, TRIGGER_MARGIN };
	Aabb body = { p + defs::PLAYER_MINS - margin, p + defs::PLAYER_MAXS + margin };
	for (int i = 0; i < m.pad_count; i++)
	{
		if (body.overlaps(m.pads[i].trigger)) return true;
	}
	for (int i = 0; i < m.teleport_count; i++)
	{
		if (body.overlaps(m.teleports[i].trigger)) return true;
	}
	return false;
}

fn bool is_dup(Vec3 a, Vec3 b) @local => hlen(a - b) < MERGE_DIST && math::abs(a.y - b.y) < MERGE_HEIGHT;

<*
 Drops samples that repeat an earlier one (overlapping brushes, nudges). Returns a heap array.
*>
fn NavNode[] dedupe(Map* m, NavNode[] samples) @local
{
	CellIndex idx;
	defer idx.release();
	idx.build(m.bounds, samples);
	bool[] keep = mem::new_array(bool, (sz)samples.len + 1);
	defer free(keep);
	int kept = 0;
	foreach (i, &s : samples)
	{
		bool dup = false;
		idx.@each_near(s.pos, MERGE_DIST; int j)
		{
			if (j < (int)i && keep[j] && is_dup(s.pos, samples[j].pos)) dup = true;
		};
		keep[i] = !dup;
		if (!dup) kept++;
	}
	NavNode[] out = mem::new_array(NavNode, (sz)kept);
	int k = 0;
	foreach (i, &s : samples)
	{
		if (keep[i]) out[k++] = *s;
	}
	return out;
}

// ---------------------------------------------------------------- parallel link jobs

<*
 Runs `worker` over all nodes (interleaved per thread). Returns the summed `rejected` counts.
*>
fn int run_jobs(NavGraph* g, LinkTable* t, Verify verify, ThreadFn worker) @local
{
	int workers = g.stats.workers;
	LinkJob[MAX_WORKERS] jobs;
	Thread[MAX_WORKERS] threads;
	bool[MAX_WORKERS] started;
	for (int w = 0; w < workers; w++) jobs[w] = { g, t, verify, w, workers, 0 };
	for (int w = 1; w < workers; w++)
	{
		if (catch threads[w].create(worker, &jobs[w]))
		{
			worker(&jobs[w]);
			continue;
		}
		started[w] = true;
	}
	worker(&jobs[0]);
	int rejected = 0;
	for (int w = 0; w < workers; w++)
	{
		if (started[w]) (void)threads[w].join();
		rejected += jobs[w].rejected;
	}
	return rejected;
}

fn int walk_worker(void* arg) @local
{
	LinkJob* job = (LinkJob*)arg;
	NavGraph* g = job.g;
	for (int a = job.offset; a < (int)g.nodes.len; a += job.stride)
	{
		if (g.nodes[a].kind == GROUND) walk_links(g, job.table, a);
	}
	return 0;
}

fn int special_worker(void* arg) @local
{
	LinkJob* job = (LinkJob*)arg;
	NavGraph* g = job.g;
	for (int a = job.offset; a < (int)g.nodes.len; a += job.stride)
	{
		if (g.nodes[a].kind == GROUND) job.rejected += special_links(g, job.table, a, job.verify);
	}
	return 0;
}

// ---------------------------------------------------------------- walk links

// Highest rise a walk of horizontal length dh can climb, one step per sub-step.
fn float max_rise(float dh) @local => defs::STEP_HEIGHT * math::max(1.0f, math::ceil(dh / WALK_SUBSTEP));

fn void walk_links(NavGraph* g, LinkTable* t, int a) @local
{
	Vec3 pa = g.nodes[a].pos;
	g.index.@each_near(pa, TRIGGER_RADIUS; int b)
	{
		if (wants_walk(g, a, b) && walkable(g.map, pa, g.nodes[b].pos) && !crosses_trigger(g.map, pa, &g.nodes[b]))
		{
			t.add(a, { b, (g.nodes[b].pos - pa).length(), WALK, 0 });
		}
	};
}

fn bool wants_walk(NavGraph* g, int a, int b) @local
{
	if (a == b) return false;
	NavNode* nb = &g.nodes[b];
	// Ground pairs are checked once, by the lower index, and mirrored afterwards.
	if (nb.kind == GROUND && b < a) return false;
	Vec3 d = nb.pos - g.nodes[a].pos;
	float dh = hlen(d);
	if (dh > (nb.kind == GROUND ? WALK_RADIUS : TRIGGER_RADIUS)) return false;
	return math::abs(d.y) <= max_rise(dh);
}

fn bool walkable(Map* m, Vec3 a, Vec3 b) @local
{
	float dh = hlen(b - a);
	if (math::abs(b.y - a.y) < 0.01f && flat_walk(m, a, b, dh)) return true;
	return step_walk(m, a, b, dh);
}

<*
 Same height: one hull sweep plus ground probes (holes narrower than the hull are fine).
*>
fn bool flat_walk(Map* m, Vec3 a, Vec3 b, float dh) @local
{
	if (!clear(m, a + UP_LIFT, b + UP_LIFT)) return false;
	int probes = (int)math::ceil(dh / PROBE_STEP);
	Vec3 down = { 0, defs::STEP_HEIGHT, 0 };
	for (int k = 1; k < probes; k++)
	{
		Vec3 p = a + (b - a) * ((float)k / (float)probes);
		if (hull_trace(m, p + UP_LIFT, p - down).fraction == 1.0f) return false;
	}
	return true;
}

<*
 Walks in sub-steps like pmove's step_slide_move: up one step, across, down to the floor.
*>
fn bool step_walk(Map* m, Vec3 a, Vec3 b, float dh) @local
{
	int steps = math::max(1, (int)math::ceil(dh / WALK_SUBSTEP));
	Vec3 step = { 0, defs::STEP_HEIGHT, 0 };
	Vec3 cur = a;
	for (int k = 1; k <= steps; k++)
	{
		Vec3 next = a + (b - a) * ((float)k / (float)steps);
		Vec3 top = hull_trace(m, cur + UP_LIFT, cur + step + UP_LIFT).endpos;
		Trace across = hull_trace(m, top, { next.x, top.y, next.z });
		if (across.startsolid || across.fraction < 1.0f) return false;
		Trace down = hull_trace(m, across.endpos, { next.x, cur.y - defs::STEP_HEIGHT, next.z });
		if (down.startsolid || down.fraction == 1.0f) return false;
		cur = down.endpos;
	}
	return math::abs(cur.y - b.y) < 0.1f;
}

<*
 True if the hull, walking a→target, would touch a pad or teleporter other than the target's own.
*>
fn bool crosses_trigger(Map* m, Vec3 a, NavNode* target) @local
{
	Vec3 from = a + UP_LIFT;
	Vec3 to = target.pos + UP_LIFT;
	for (int i = 0; i < m.pad_count; i++)
	{
		if (target.kind == PAD && target.ref == i) continue;
		if (segment_hits(from, to, m.pads[i].trigger.expand(defs::PLAYER_MINS, defs::PLAYER_MAXS))) return true;
	}
	for (int i = 0; i < m.teleport_count; i++)
	{
		if (target.kind == TELEPORT && target.ref == i) continue;
		if (segment_hits(from, to, m.teleports[i].trigger.expand(defs::PLAYER_MINS, defs::PLAYER_MAXS))) return true;
	}
	return false;
}

fn bool segment_hits(Vec3 a, Vec3 b, Aabb box) @local
{
	float t0 = 0;
	float t1 = 1;
	Vec3 d = b - a;
	for (int axis = 0; axis < 3; axis++)
	{
		if (math::abs(d[axis]) < 1e-6f)
		{
			if (a[axis] < box.min[axis] || a[axis] > box.max[axis]) return false;
			continue;
		}
		float inv = 1.0f / d[axis];
		float near = (box.min[axis] - a[axis]) * inv;
		float far = (box.max[axis] - a[axis]) * inv;
		if (near > far) @swap(near, far);
		t0 = math::max(t0, near);
		t1 = math::min(t1, far);
		if (t0 > t1) return false;
	}
	return true;
}

fn void mirror_walks(NavGraph* g, LinkTable* t) @local
{
	int count = (int)g.nodes.len;
	// Snapshot first: links mirrored in this pass must not be mirrored again.
	for (int a = 0; a < count; a++) t.walk_count[a] = t.count[a];
	for (int a = 0; a < count; a++)
	{
		for (int k = 0; k < t.walk_count[a]; k++)
		{
			NavLink l = t.slots[a * MAX_LINKS + k];
			if (g.nodes[l.to].kind == GROUND) t.add(l.to, { a, l.cost, WALK, 0 });
		}
	}
	for (int a = 0; a < count; a++) t.walk_count[a] = t.count[a];
}

// ---------------------------------------------------------------- jump and drop links

<*
 Adds up to MAX_SPECIAL jump/drop links from node a, nearest first, skipping targets the
 walk links already cover. Returns how many links the pmove check rejected.
*>
fn int special_links(NavGraph* g, LinkTable* t, int a, Verify verify) @local
{
	Map* m = g.map;
	Vec3 pa = g.nodes[a].pos;
	Candidate[MAX_CANDIDATES] cands;
	int n = 0;
	g.index.@each_near(pa, GAP_RADIUS; int b)
	{
		if (n < MAX_CANDIDATES && classify(g, t, a, b, &cands[n])) n++;
	};
	sort_candidates(cands[:n]);

	int[MAX_SPECIAL] accepted;
	int count = 0;
	int tries = 0;
	int rejected = 0;
	for (int i = 0; i < n && count < MAX_SPECIAL && tries < MAX_SPECIAL_TRIES; i++)
	{
		Candidate* c = &cands[i];
		Vec3 pb = g.nodes[c.node].pos;
		if (covered(g, accepted[:count], pb) || two_hop(t, a, c.node)) continue;
		tries++;
		NavLink link = { c.node, (pb - pa).length() * c.kind.cost_factor, c.kind, 0 };
		if (!ballistic(m, pa, pb, &link)) continue;
		if (verify == PMOVE && !simulate_link(m, pa, pb, link))
		{
			rejected++;
			continue;
		}
		t.add(a, link);
		accepted[count++] = c.node;
	}
	return rejected;
}

fn bool classify(NavGraph* g, LinkTable* t, int a, int b, Candidate* out) @local
{
	if (a == b) return false;
	NavNode* nb = &g.nodes[b];
	if (nb.kind != GROUND) return false;
	Vec3 pa = g.nodes[a].pos;
	Vec3 d = nb.pos - pa;
	float dh = hlen(d);
	float step = defs::STEP_HEIGHT + 0.02f;
	*out = { b, dh, JUMP };
	if (d.y < -step)
	{
		out.kind = DROP;
		return d.y >= -MAX_DROP && dh <= DROP_RADIUS && !t.has(a, b);
	}
	if (d.y > step) return d.y <= JUMP_UP_PMOVE && dh <= JUMP_RADIUS && !t.has(a, b);
	return dh <= GAP_RADIUS && !t.has(a, b) && gap_between(g.map, pa, nb.pos);
}

fn bool gap_between(Map* m, Vec3 a, Vec3 b) @local
{
	Vec3 mid = (a + b) * 0.5f;
	mid.y = math::max(a.y, b.y);
	Trace tr = hull_trace(m, mid + UP_LIFT, mid - (Vec3){ 0, defs::STEP_HEIGHT, 0 });
	return !tr.startsolid && tr.fraction == 1.0f;
}

fn void sort_candidates(Candidate[] c) @local
{
	for (int i = 1; i < (int)c.len; i++)
	{
		Candidate k = c[i];
		int j = i - 1;
		while (j >= 0 && c[j].dist > k.dist)
		{
			c[j + 1] = c[j];
			j--;
		}
		c[j + 1] = k;
	}
}

// A target next to one already linked is reachable by walking from it.
fn bool covered(NavGraph* g, int[] accepted, Vec3 p) @local
{
	foreach (n : accepted)
	{
		if ((g.nodes[n].pos - p).length() < SPACING * 1.2f) return true;
	}
	return false;
}

// b is two walk links away from a (stairs): no need to jump or drop there.
fn bool two_hop(LinkTable* t, int a, int b) @local
{
	for (int i = 0; i < t.walk_count[a]; i++)
	{
		int c = t.slots[a * MAX_LINKS + i].to;
		if (c == b) return true;
		for (int j = 0; j < t.walk_count[c]; j++)
		{
			if (t.slots[c * MAX_LINKS + j].to == b) return true;
		}
	}
	return false;
}

<*
 Hull-sweeps the flight of a jump or drop link and fills in its take-off speed.
*>
fn bool ballistic(Map* m, Vec3 a, Vec3 b, NavLink* link) @local
{
	float dy = b.y - a.y;
	if (link.kind == DROP) return drop_arc(m, a, b, link);
	if (dy > defs::STEP_HEIGHT) return jump_up(m, a, b, link);
	return jump_arc(m, a, b, link);
}

<*
 Onto a ledge: room to rise at a, then a clear sweep across just above b's floor.
*>
fn bool jump_up(Map* m, Vec3 a, Vec3 b, NavLink* link) @local
{
	float dy = b.y - a.y;
	if (dy > JUMP_UP) return false;
	float secs = jump_land_time(dy + LIFT);
	float dh = hlen(b - a);
	if (secs < 0 || dh > defs::RUN_SPEED * secs) return false;
	Vec3 up = { a.x, b.y + LIFT, a.z };
	if (!clear(m, a + UP_LIFT, up)) return false;
	if (!clear(m, up, b + UP_LIFT)) return false;
	link.speed = takeoff_speed(dh, secs);
	return true;
}

<*
 Across a hole: sweep the actual jump parabola.
*>
fn bool jump_arc(Map* m, Vec3 a, Vec3 b, NavLink* link) @local
{
	float secs = jump_land_time(b.y - a.y);
	float dh = hlen(b - a);
	if (secs < 0 || dh > defs::RUN_SPEED * secs) return false;
	float speed = dh / secs;
	Vec3 dir = flat(b - a) / dh;
	Vec3 prev = a + UP_LIFT;
	for (int k = 1; k <= ARC_SEGMENTS; k++)
	{
		float t = secs * (float)k / (float)ARC_SEGMENTS;
		float y = defs::JUMP_VELOCITY * t - 0.5f * defs::GRAVITY * t * t;
		Vec3 p = a + dir * (speed * t) + (Vec3){ 0, y + LIFT, 0 };
		if (!clear(m, prev, p)) return false;
		prev = p;
	}
	link.speed = takeoff_speed(dh, secs);
	return true;
}

<*
 Walk to the ledge at a's height, then fall onto b.
*>
fn bool drop_arc(Map* m, Vec3 a, Vec3 b, NavLink* link) @local
{
	Vec3 over = { b.x, a.y + LIFT, b.z };
	if (!clear(m, a + UP_LIFT, over)) return false;
	float dh = hlen(b - a);
	Vec3 dir = flat(b - a) / dh;
	// Find the ledge: the first point along a→b without floor within a step below.
	Vec3 down = { 0, defs::STEP_HEIGHT, 0 };
	float edge = -1;
	for (float s = EDGE_STEP; s < dh + EDGE_STEP; s += EDGE_STEP)
	{
		Vec3 p = a + dir * math::min(s, dh) + UP_LIFT;
		if (hull_trace(m, p, p - down).fraction == 1.0f)
		{
			edge = math::min(s, dh);
			break;
		}
	}
	if (edge < 0) return false;
	float fall = a.y - b.y;
	float secs = math::sqrt(2.0f * fall / defs::GRAVITY);
	float rest = dh - edge;
	if (rest > defs::RUN_SPEED * secs) return false;
	float speed = rest / secs;
	Vec3 start = a + dir * edge + UP_LIFT;
	Vec3 prev = start;
	for (int k = 1; k <= ARC_SEGMENTS; k++)
	{
		float t = secs * (float)k / (float)ARC_SEGMENTS;
		Vec3 p = start + dir * (speed * t) - (Vec3){ 0, 0.5f * defs::GRAVITY * t * t, 0 };
		if (k == ARC_SEGMENTS) p = b + UP_LIFT;
		if (!clear(m, prev, p)) return false;
		prev = p;
	}
	link.speed = takeoff_speed(rest, secs);
	return true;
}

<*
 Replays a jump/drop link with pmove, driving like a bot: approach at the link's take-off
 speed, jump once at a, steer toward b in the air. True if it ends up standing at b.
*>
fn bool simulate_link(Map* m, Vec3 a, Vec3 b, NavLink link)
{
	Vec3 dir = flat(b - a);
	float dh = dir.length();
	if (dh < 0.01f) return false;
	dir /= dh;
	float speed = link.speed > 0 ? link.speed : defs::RUN_SPEED;
	PlayerState ps = { .origin = a + (Vec3){ 0, map::SURFACE_EPSILON, 0 }, .velocity = dir * speed };
	bool airborne = false;
	bool jumped = false;
	for (int tick = 0; tick < SIM_TICKS; tick++)
	{
		Vec3 to = flat(b - ps.origin);
		float dist = to.length();
		if (ps.flags.on_ground && dist < SIM_REACH && math::abs(ps.origin.y - b.y) < SIM_LEVEL) return true;
		UserCmd cmd = { .yaw = dist > 0.01f ? math::atan2(to.x, to.z) : ps.yaw };
		cmd.forward = (ichar)(127.0f * speed / defs::RUN_SPEED);
		if (airborne)
		{
			Vec3 wish = air_wish(ps.origin, ps.velocity, b);
			cmd.forward = wish.length_sq() > 0 ? 127 : 0;
			if (wish.length_sq() > 0) cmd.yaw = math::atan2(wish.x, wish.z);
		}
		bool takeoff = link.kind == JUMP && !jumped && hlen(ps.origin - a) < SIM_TAKEOFF;
		cmd.buttons.jump = takeoff;
		if (takeoff) jumped = true;
		PmEvents ev = pmove::move(&ps, cmd, m, defs::TICK_DT);
		if (ev.jumppad || ev.teleported) return false;
		if (!ps.flags.on_ground)
		{
			airborne = true;
			continue;
		}
		if (airborne && math::abs(ps.origin.y - b.y) > SIM_LEVEL) return false;
	}
	return false;
}

// ---------------------------------------------------------------- pads and teleporters

fn void trigger_links(NavGraph* g, LinkTable* t) @local
{
	foreach (a, &n : g.nodes)
	{
		if (n.kind == GROUND) continue;
		float secs;
		Vec3? land = sim_trigger(g.map, n.pos, &secs);
		if (catch land) continue;
		int b = g.nearest_ground(land, LANDING_RADIUS);
		if (b < 0) continue;
		if (n.kind == TELEPORT)
		{
			t.add((int)a, { b, TELEPORT_COST, TELEPORT, 0 });
			continue;
		}
		float cost = math::max(secs * defs::RUN_SPEED, (g.nodes[b].pos - n.pos).length());
		t.add((int)a, { b, cost, LinkKind.PAD, 0 });
	}
}

<*
 Drops a player at `start` (inside a trigger) and lets pmove fly it. Returns where it lands.
*>
fn Vec3? sim_trigger(Map* m, Vec3 start, float* secs) @local
{
	PlayerState ps = { .origin = start + (Vec3){ 0, map::SURFACE_EPSILON, 0 } };
	bool fired = false;
	for (int tick = 0; tick < TRIGGER_TICKS; tick++)
	{
		PmEvents ev = pmove::move(&ps, {}, m, defs::TICK_DT);
		if (ev.jumppad || ev.teleported) fired = true;
		if (fired && ps.flags.on_ground)
		{
			*secs = (float)(tick + 1) * defs::TICK_DT;
			return ps.origin;
		}
	}
	return NO_SPOT~;
}

// ---------------------------------------------------------------- pruning and packing

fn int find_root(int[] parent, int i) @local
{
	int r = i;
	while (parent[r] != r)
	{
		parent[r] = parent[parent[r]];
		r = parent[r];
	}
	return r;
}

<*
 Undirected components (union-find over the links). Returns a heap array of roots.
*>
fn int[] components(LinkTable* t, int count) @local
{
	int[] parent = mem::new_array(int, (sz)count + 1);
	for (int i = 0; i < count; i++) parent[i] = i;
	for (int a = 0; a < count; a++)
	{
		foreach (&l : t.of(a))
		{
			int ra = find_root(parent, a);
			int rb = find_root(parent, l.to);
			if (ra != rb) parent[ra] = rb;
		}
	}
	for (int i = 0; i < count; i++) parent[i] = find_root(parent, i);
	return parent;
}

<*
 Nodes reachable (following link directions) from the nodes nearest to the spawn points.
*>
fn bool[] NavGraph.spawn_reach(&self, LinkTable* t)
{
	int count = (int)self.nodes.len;
	bool[] reach = mem::new_array(bool, (sz)count + 1);
	int[] queue = mem::new_array(int, (sz)count + 1);
	defer free(queue);
	int head = 0;
	int tail = 0;
	Map* m = self.map;
	for (int s = 0; s < m.spawn_count; s++)
	{
		int n = self.nearest_ground(m.spawns[s].pos, SPAWN_RADIUS);
		if (n < 0 || reach[n]) continue;
		reach[n] = true;
		queue[tail++] = n;
	}
	while (head < tail)
	{
		int a = queue[head++];
		foreach (&l : t.of(a))
		{
			if (reach[l.to]) continue;
			reach[l.to] = true;
			queue[tail++] = l.to;
		}
	}
	return reach;
}

<*
 Keeps the islands a spawned player can reach (and that aren't tiny), then packs the links
 CSR-style and readies the search scratch.
*>
fn void NavGraph.compact(&self, LinkTable* t)
{
	int count = (int)self.nodes.len;
	int[] comp = components(t, count);
	defer free(comp);
	bool[] reach = self.spawn_reach(t);
	defer free(reach);
	int[] size = mem::new_array(int, (sz)count + 1);
	defer free(size);
	bool[] comp_reach = mem::new_array(bool, (sz)count + 1);
	defer free(comp_reach);
	for (int i = 0; i < count; i++)
	{
		size[comp[i]]++;
		if (reach[i]) comp_reach[comp[i]] = true;
	}
	bool reachable = false;
	for (int i = 0; i < count; i++)
	{
		if (comp_reach[comp[i]] && size[comp[i]] >= MIN_ISLAND) reachable = true;
	}

	int[] remap = mem::new_array(int, (sz)count + 1);
	defer free(remap);
	int kept = 0;
	int total = 0;
	for (int i = 0; i < count; i++)
	{
		bool keep = size[comp[i]] >= MIN_ISLAND && (comp_reach[comp[i]] || !reachable);
		remap[i] = keep ? kept++ : -1;
		if (keep) total += t.count[i];
	}

	NavNode[] nodes = mem::new_array(NavNode, (sz)kept + 1);
	NavLink[] links = mem::new_array(NavLink, (sz)total + 1);
	int l = 0;
	for (int i = 0; i < count; i++)
	{
		if (remap[i] < 0) continue;
		NavNode n = self.nodes[i];
		n.first = l;
		n.reach = reach[i];
		foreach (link : t.of(i))
		{
			if (remap[link.to] < 0) continue;
			link.to = remap[link.to];
			links[l++] = link;
			self.stats.by_kind[link.kind.ordinal]++;
		}
		n.count = l - n.first;
		nodes[remap[i]] = n;
	}
	@release(self.nodes);
	self.nodes = nodes[:kept];
	self.links = links[:l];
	self.stats.nodes = kept;
	self.stats.links = l;
	self.stats.pruned = count - kept;
	self.label_islands();
	self.index.build(self.map.bounds, self.nodes);
	self.collect_warps();

	self.cost = mem::new_array(float, (sz)kept + 1);
	self.parent = mem::new_array(int, (sz)kept + 1);
	self.seen = mem::new_array(uint, (sz)kept + 1);
	self.closed = mem::new_array(uint, (sz)kept + 1);
}

fn void NavGraph.label_islands(&self)
{
	int count = (int)self.nodes.len;
	int[] parent = mem::new_array(int, (sz)count + 1);
	defer free(parent);
	for (int i = 0; i < count; i++) parent[i] = i;
	foreach (a, &n : self.nodes)
	{
		foreach (&l : self.links[n.first:n.count])
		{
			int ra = find_root(parent, (int)a);
			int rb = find_root(parent, l.to);
			if (ra != rb) parent[ra] = rb;
		}
	}
	foreach (i, &n : self.nodes) n.island = find_root(parent, (int)i);
}

fn void NavGraph.collect_warps(&self)
{
	self.warp_count = 0;
	foreach (&n : self.nodes)
	{
		if (n.kind != TELEPORT || n.count == 0 || self.warp_count >= map::MAX_TELEPORTS) continue;
		self.warps[self.warp_count++] = { n.pos, self.nodes[self.links[n.first].to].pos };
	}
}

// ---------------------------------------------------------------- queries

fn bool NavGraph.visible(&self, Vec3 a, Vec3 b)
{
	Vec3 lift = { 0, EYE_LIFT, 0 };
	return self.map.trace_ray(a + lift, b + lift, PLAYER).fraction >= 1.0f;
}

// Ground node closest to p within radius that p can see, or -1.
fn int NavGraph.nearest_ground(&self, Vec3 p, float radius)
{
	int best = -1;
	float best_d = radius;
	self.index.@each_near(p, radius; int i)
	{
		NavNode* n = &self.nodes[i];
		float d = (n.pos - p).length();
		if (n.kind == GROUND && d < best_d && self.visible(p, n.pos))
		{
			best = i;
			best_d = d;
		}
	};
	return best;
}

// Distance-like score: climbing is expensive, standing above a node is cheap.
fn float near_score(Vec3 p, Vec3 q) @local
{
	float dy = q.y - p.y;
	float v = dy > defs::STEP_HEIGHT ? dy * 3.0f : math::abs(dy) * 1.5f;
	return hlen(q - p) + v;
}

// Inserts (id, s) into the ascending top-k arrays holding n entries. Returns the new count.
fn int insert_best(int[] ids, float[] scores, int n, int id, float s) @local
{
	int cap = (int)ids.len;
	if (n == cap && s >= scores[n - 1]) return n;
	int k = n < cap ? n : cap - 1;
	while (k > 0 && scores[k - 1] > s)
	{
		ids[k] = ids[k - 1];
		scores[k] = scores[k - 1];
		k--;
	}
	ids[k] = id;
	scores[k] = s;
	return n < cap ? n + 1 : n;
}

<*
 The ground node a player at p should head for first: the best scored one p can see,
 else the best scored one nearby, else the best anywhere. -1 only if the graph is empty.
*>
fn int NavGraph.nearest(&self, Vec3 p)
{
	int[NEAR_CHECKS] best;
	float[NEAR_CHECKS] score;
	int n = 0;
	self.index.@each_near(p, NEAR_RADIUS; int i)
	{
		NavNode* node = &self.nodes[i];
		if (node.kind == GROUND) n = insert_best(&best, &score, n, i, near_score(p, node.pos));
	};
	for (int k = 0; k < n; k++)
	{
		if (self.visible(p, self.nodes[best[k]].pos)) return best[k];
	}
	if (n > 0) return best[0];
	int fallback = -1;
	float fallback_score = math::FLOAT_MAX;
	foreach (i, &node : self.nodes)
	{
		if (node.kind != GROUND) continue;
		float s = near_score(p, node.pos);
		if (s >= fallback_score) continue;
		fallback = (int)i;
		fallback_score = s;
	}
	return fallback;
}

fn LinkKind? NavGraph.link_kind(&self, int from, int to) => self.link(from, to).kind;

fn NavLink? NavGraph.link(&self, int from, int to)
{
	NavNode* n = &self.nodes[from];
	foreach (&l : self.links[n.first:n.count])
	{
		if (l.to == to) return *l;
	}
	return NO_LINK~;
}

fn NavLink[] NavGraph.links_of(&self, int n) => self.links[self.nodes[n].first:self.nodes[n].count];

// ---------------------------------------------------------------- A*

fn void NavGraph.next_search(&self)
{
	self.search++;
	if (self.search != 0) return;
	self.seen[..] = 0;
	self.closed[..] = 0;
	self.search = 1;
}

// Straight-line distance, or via a teleporter if that is shorter (keeps A* admissible).
fn float NavGraph.heuristic(&self, Vec3 p, Vec3 goal, float[] exit_cost)
{
	float h = (goal - p).length();
	for (int k = 0; k < self.warp_count; k++) h = math::min(h, (self.warps[k].entry - p).length() + exit_cost[k]);
	return h;
}

<*
 A* from `from` to `to` over the links. On success `out` holds the node indices, both ends
 included. `out` keeps its own allocator (an uninitialized List uses the temp allocator).
 @require out != null
*>
fn bool NavGraph.path(&self, int from, int to, List{int}* out)
{
	out.clear();
	int count = (int)self.nodes.len;
	if (from < 0 || to < 0 || from >= count || to >= count) return false;
	if (self.nodes[from].island != self.nodes[to].island) return false;
	// Whatever a spawn can reach, it reaches from every reachable node.
	if (self.nodes[from].reach && !self.nodes[to].reach) return false;
	if (from == to)
	{
		out.push(from);
		return true;
	}
	self.next_search();
	Vec3 goal = self.nodes[to].pos;
	float[map::MAX_TELEPORTS] exit_cost;
	for (int k = 0; k < self.warp_count; k++) exit_cost[k] = (self.warps[k].exit - goal).length();

	self.open.heap.clear();
	self.seen[from] = self.search;
	self.cost[from] = 0;
	self.parent[from] = -1;
	self.open.push({ self.heuristic(self.nodes[from].pos, goal, &exit_cost), from });
	while (try e = self.open.pop())
	{
		int n = e.node;
		if (self.closed[n] == self.search) continue;
		self.closed[n] = self.search;
		if (n == to)
		{
			for (int k = to; k >= 0; k = self.parent[k]) out.push(k);
			out.reverse();
			return true;
		}
		foreach (&l : self.links_of(n))
		{
			float g = self.cost[n] + l.cost;
			if (self.seen[l.to] == self.search && g >= self.cost[l.to]) continue;
			self.seen[l.to] = self.search;
			self.cost[l.to] = g;
			self.parent[l.to] = n;
			self.open.push({ g + self.heuristic(self.nodes[l.to].pos, goal, &exit_cost), l.to });
		}
	}
	return false;
}
