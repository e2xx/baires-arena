// Procedural textures, one per Material: tileable TEX_SIZE² RGBA8 albedo with baked micro-relief.
// World-space UVs, 1 repeat = 2 m (128 px = 1 m). Every pattern has a whole number of periods per
// texture and every noise lattice wraps, so all textures tile seamlessly.
module arena::textures;
import std::math, std::thread, std::os, arena::defs, raylib6::rl;

const int TEX_SIZE = 256;
const int TEX_BYTES = TEX_SIZE * TEX_SIZE * 4;

const int TEX_PIXELS @private = TEX_SIZE * TEX_SIZE;
const int TEX_MASK @private = TEX_SIZE - 1;
const float PX @private = (float)TEX_SIZE;
const float TAU @private = (float)math::PI * 2.0f;
const float ALBEDO_MIN @private = 0.03f;
const float ALBEDO_MAX @private = 0.96f;
const int MAX_BANDS @private = 8;   // threads per texture

$assert (TEX_SIZE & TEX_MASK) == 0;

alias Rgb @private = float[<3>];
alias Uv @private = float[<2>];
alias Lattice @private = int[<2>];

// What a material shader returns for one point.
struct Texel @private
{
	Rgb albedo;
	float height;   // relief in pixels; only its slope matters (lit by RELIEF_LIGHT)
}

alias Shader @private = fn Texel(Uv uv);

// ---------------------------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------------------------

<*
 Fill `out` with the RGBA8 pixels (row-major, top row first) of material `m`.
 Deterministic and CPU only: needs no window. INVISIBLE materials come out magenta.

 @require out.len == TEX_BYTES : "out must hold TEX_SIZE * TEX_SIZE RGBA8 pixels"
 @require m.surface == INVISIBLE || SHADERS[m] != null : "material has no shader"
*>
fn void generate(Material m, char[] out)
{
	if (m.surface == INVISIBLE)
	{
		fill(out, { 255, 0, 255, 255 });
		return;
	}
	@pool()
	{
		Texel[] texels = mem::talloc_array(Texel, TEX_PIXELS);
		shade_all(SHADERS[m], texels);
		bake(texels, out, m.surface);
	};
}

RLTexture2D[Material::len] loaded @private;

<*
 Generate every visible material and upload it with mipmaps, trilinear filtering and REPEAT wrap.
 Calling it again reloads everything.
 @require rl::is_window_ready() : "load_all needs an OpenGL context"
*>
fn void load_all()
{
	unload_all();
	char[] pixels = mem::new_array(char, TEX_BYTES);
	defer free(pixels);
	foreach (m : Material::values)
	{
		if (m.surface == INVISIBLE)
		{
			continue;
		}
		generate(m, pixels);
		RLImage img = { pixels.ptr, TEX_SIZE, TEX_SIZE, 1, UNCOMPRESSED_R8G8B8A8 };
		RLTexture2D tex = rl::load_texture_from_image(img);
		rl::gen_texture_mipmaps(&tex);
		tex.set_filter(TRILINEAR);
		tex.set_wrap(REPEAT);
		loaded[m] = tex;
	}
}

// Texture of `m`; a zero texture (id 0) for INVISIBLE materials or before load_all().
fn RLTexture2D get(Material m) => loaded[m];

fn void unload_all()
{
	foreach (&tex : loaded)
	{
		if (tex.id == 0)
		{
			continue;
		}
		rl::unload_texture(*tex);
		*tex = {};
	}
}

// ---------------------------------------------------------------------------------------------
// Generator table, threaded shading and baking
// ---------------------------------------------------------------------------------------------

const Shader[Material::len] SHADERS @private = {
	[Material.TILE_WHITE] = &shade_tile_white,
	[Material.TILE_BAND] = &shade_tile_band,
	[Material.CONCRETE] = &shade_concrete,
	[Material.COBBLE] = &shade_cobble,
	[Material.STONE] = &shade_stone,
	[Material.METAL] = &shade_metal,
	[Material.CONTAINER_RED] = &shade_container_red,
	[Material.CONTAINER_BLUE] = &shade_container_blue,
	[Material.WOOD] = &shade_wood,
	[Material.BRICK] = &shade_brick,
	[Material.TRIM] = &shade_trim,
	[Material.GRASS] = &shade_grass,
	[Material.LIGHT] = &shade_light,
	[Material.JUMPPAD] = &shade_jumppad,
	[Material.CLIP] = null,
};

struct Band @private
{
	Shader shade;
	Texel[] texels;
	int y0;
	int y1;
}

fn int shade_band(void* arg) @private
{
	Band* b = arg;
	for (int y = b.y0; y < b.y1; y++)
	{
		for (int x = 0; x < TEX_SIZE; x++)
		{
			b.texels[y * TEX_SIZE + x] = b.shade({ (x + 0.5f) / PX, (y + 0.5f) / PX });
		}
	}
	return 0;
}

// Shade every pixel, split in horizontal bands over up to MAX_BANDS threads. Pixels are
// independent, so the result does not depend on the thread count.
fn void shade_all(Shader shade, Texel[] texels) @private
{
	int bands = math::clamp(os::num_cpu(), 1, MAX_BANDS);
	Band[MAX_BANDS] jobs;
	Thread[MAX_BANDS] threads;
	bool[MAX_BANDS] spawned;
	for (int i = 0; i < bands; i++)
	{
		jobs[i] = { shade, texels, i * TEX_SIZE / bands, (i + 1) * TEX_SIZE / bands };
	}
	for (int i = 1; i < bands; i++)
	{
		if (catch threads[i].create(&shade_band, &jobs[i]))
		{
			shade_band(&jobs[i]);
			continue;
		}
		spawned[i] = true;
	}
	shade_band(&jobs[0]);
	for (int i = 1; i < bands; i++)
	{
		if (spawned[i])
		{
			(void)threads[i].join();
		}
	}
}

// Baked light for the relief: from the top-left of the image.
const Vec3 RELIEF_LIGHT @private = { -0.45f, -0.55f, 0.703f };
const float RELIEF_MIN @private = 0.45f;
const float RELIEF_MAX @private = 1.6f;

fn void fill(char[] out, char[<4>] color) @private
{
	for (int i = 0; i < out.len; i += 4)
	{
		out[i] = color.r;
		out[i + 1] = color.g;
		out[i + 2] = color.b;
		out[i + 3] = color.a;
	}
}

fn float height_at(Texel[] texels, int x, int y) @private @inline
{
	return texels[(y & TEX_MASK) * TEX_SIZE + (x & TEX_MASK)].height;
}

// Shade the height field with RELIEF_LIGHT and quantize. The shading is linear in the slope, so
// over a periodic height field it averages to 1 and the mean colour stays the albedo's.
fn void bake(Texel[] texels, char[] out, Surface surface) @private
{
	float top = surface == EMISSIVE ? 1.0f : ALBEDO_MAX;
	for (int y = 0; y < TEX_SIZE; y++)
	{
		for (int x = 0; x < TEX_SIZE; x++)
		{
			Uv slope = { height_at(texels, x + 1, y) - height_at(texels, x - 1, y),
				height_at(texels, x, y + 1) - height_at(texels, x, y - 1) };
			float light = 1.0f - (slope * 0.5f).dot(RELIEF_LIGHT.xy) / RELIEF_LIGHT.z;
			Rgb c = texels[y * TEX_SIZE + x].albedo * light.clamp(RELIEF_MIN, RELIEF_MAX);
			Rgb q = c.clamp((Rgb)ALBEDO_MIN, (Rgb)top) * 255.0f + 0.5f;
			int o = (y * TEX_SIZE + x) * 4;
			out[o] = (char)q.x;
			out[o + 1] = (char)q.y;
			out[o + 2] = (char)q.z;
			out[o + 3] = 255;
		}
	}
}

// ---------------------------------------------------------------------------------------------
// Toolkit: hashing, periodic noise, cells, patterns
// ---------------------------------------------------------------------------------------------

fn uint mix32(uint h) @private @inline
{
	h ^= h >> 16;
	h *= 0x7FEB352D;
	h ^= h >> 15;
	h *= 0x846CA68B;
	h ^= h >> 16;
	return h;
}

fn uint hash(int x, int y, uint seed) @private @inline
{
	return mix32((uint)x * 0x8DA6B343 + mix32((uint)y * 0xD8163841 + seed));
}

// Uniform in [0, 1) from a hash.
fn float unit(uint h) @private @inline => (float)(h >> 8) * (1.0f / 16777216.0f);

// k-th independent uniform derived from one hash.
fn float hrand(uint h, uint k) @private @inline => unit(mix32(h + k * 0x9E3779B9));

fn float rand01(int x, int y, uint seed) @private @inline => unit(hash(x, y, seed));

// Wrap a lattice index into [0, n).
fn int wrap(int i, int n) @private @inline
{
	if (i >= 0 && i < n)
	{
		return i;
	}
	return (i % n + n) % n;
}

fn Lattice wrap2(Lattice i, Lattice n) @private @inline => { wrap(i.x, n.x), wrap(i.y, n.y) };

const Uv[8] GRADS @private = {
	{ 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 },
	{ 0.7071f, 0.7071f }, { -0.7071f, 0.7071f }, { 0.7071f, -0.7071f }, { -0.7071f, -0.7071f },
};

<*
 Periodic gradient noise, about [-1, 1]. `period` = lattice cells across the texture per axis.
 @require period.x > 0 && period.y > 0
*>
fn float gnoise(Uv uv, Lattice period, uint seed) @private
{
	Uv p = uv * (Uv)period;
	Uv f = p.floor();
	Uv t = p - f;
	Uv s = t * t * t * (t * (t * 6.0f - 15.0f) + 10.0f);
	Lattice i0 = wrap2((Lattice)f, period);
	Lattice i1 = wrap2(i0 + 1, period);
	float a = GRADS[hash(i0.x, i0.y, seed) & 7].dot(t);
	float b = GRADS[hash(i1.x, i0.y, seed) & 7].dot(t - (Uv){ 1, 0 });
	float c = GRADS[hash(i0.x, i1.y, seed) & 7].dot(t - (Uv){ 0, 1 });
	float d = GRADS[hash(i1.x, i1.y, seed) & 7].dot(t - (Uv){ 1, 1 });
	return lerp(lerp(a, b, s.x), lerp(c, d, s.x), s.y) * 1.4142f;
}

<*
 Periodic value noise in [0, 1).
 @require period.x > 0 && period.y > 0
*>
fn float vnoise(Uv uv, Lattice period, uint seed) @private
{
	Uv p = uv * (Uv)period;
	Uv f = p.floor();
	Uv t = p - f;
	Uv s = t * t * (3.0f - 2.0f * t);
	Lattice i0 = wrap2((Lattice)f, period);
	Lattice i1 = wrap2(i0 + 1, period);
	float a = rand01(i0.x, i0.y, seed);
	float b = rand01(i1.x, i0.y, seed);
	float c = rand01(i0.x, i1.y, seed);
	float d = rand01(i1.x, i1.y, seed);
	return lerp(lerp(a, b, s.x), lerp(c, d, s.x), s.y);
}

<*
 Fractal sum of gradient noise; each octave doubles the lattice period. About [-1, 1].
 @require octaves > 0 && octaves <= 8
*>
fn float fbm(Uv uv, Lattice period, int octaves, uint seed) @private
{
	float sum;
	float norm;
	float amp = 1.0f;
	for (int o = 0; o < octaves; o++)
	{
		sum += amp * gnoise(uv, period, seed + (uint)o * 0x51ED);
		norm += amp;
		period *= 2;
		amp *= 0.5f;
	}
	return sum / norm;
}

struct Worley @private
{
	float f1;       // distance to the nearest feature point, in cells
	float f2;       // distance to the second nearest
	Lattice cell;   // wrapped index of the nearest cell
}

<*
 Periodic cellular (Worley) noise: one jittered feature point per lattice cell.
 @require period.x > 0 && period.y > 0
 @require jitter >= 0.0f && jitter <= 1.0f
*>
fn Worley worley(Uv uv, Lattice period, float jitter, uint seed) @private
{
	Uv p = uv * (Uv)period;
	Lattice base = (Lattice)p.floor();
	Worley w = { 9.0f, 9.0f, {} };
	for (int dy = -1; dy <= 1; dy++)
	{
		for (int dx = -1; dx <= 1; dx++)
		{
			Lattice c = base + (Lattice){ dx, dy };
			Lattice cw = wrap2(c, period);
			uint h = hash(cw.x, cw.y, seed);
			Uv feature = (Uv)c + 0.5f + ((Uv){ hrand(h, 1), hrand(h, 2) } - 0.5f) * jitter;
			float d = (p - feature).length();
			if (d < w.f1)
			{
				w.f2 = w.f1;
				w.f1 = d;
				w.cell = cw;
				continue;
			}
			if (d < w.f2)
			{
				w.f2 = d;
			}
		}
	}
	return w;
}

struct GridCell @private
{
	Uv local;     // pixels from the cell centre
	Uv half;      // half the cell size, in pixels
	Lattice id;   // wrapped cell index
}

fn int row_of(float v, int rows) @private @inline => (int)(v * rows);

<*
 Brick-style grid of `cols` x `rows` cells over the texture; the point's row is shifted right by
 `shift` cells (pass a per-row value for running bond).
 @require cols > 0 && rows > 0
 @require shift >= 0.0f && shift < 1.0f
*>
fn GridCell grid(Uv uv, int cols, int rows, float shift) @private
{
	Uv g = uv * (Uv){ (float)cols, (float)rows } + (Uv){ shift, 0 };
	Uv f = g.floor();
	Uv size = { PX / cols, PX / rows };
	return { (g - f - 0.5f) * size, size * 0.5f, wrap2((Lattice)f, { cols, rows }) };
}

// Signed distance to a rounded box centred at the origin (negative inside).
fn float sd_box(Uv p, Uv half, float radius) @private
{
	Uv q = math::abs(p) - half + radius;
	return math::max(q, (Uv){ 0, 0 }).length() + math::min(math::max(q.x, q.y), 0.0f) - radius;
}

// Distance from p to segment ab; `t` receives the position along it (0 at a, 1 at b).
fn float sd_segment(Uv p, Uv a, Uv b, float* t) @private
{
	Uv pa = p - a;
	Uv ba = b - a;
	*t = (pa.dot(ba) / ba.dot(ba)).clamp(0.0f, 1.0f);
	return (pa - ba * *t).length();
}

// Distance in pixels from coordinate `t` (0..1) to the nearest of `n` evenly spaced lines.
fn float line_dist(float t, int n) @private
{
	float f = t * n;
	return math::abs(f - math::round(f)) * PX / n;
}

fn float sat(float x) @private @inline => x.clamp(0.0f, 1.0f);

fn float lerp(float a, float b, float t) @private @inline => a + (b - a) * t;

fn float smoothstep(float e0, float e1, float x) @private
{
	float t = sat((x - e0) / (e1 - e0));
	return t * t * (3.0f - 2.0f * t);
}

// Anti-aliased coverage of a shape from its inside distance in pixels (> 0 inside).
fn float coverage(float inside) @private @inline => sat(inside + 0.5f);

// Rounded bevel: 0 at the edge, `height` once `inside` reaches `width` pixels.
fn float bevel(float inside, float width, float height) @private @inline
{
	float t = sat(inside / width);
	return height * (1.0f - (1.0f - t) * (1.0f - t));
}

// One colour of a constant palette chosen by hash, brightness varied by +-`spread`.
macro Rgb @pick(#palette, uint h, float spread)
{
	return #palette[h % #palette.len] * (1.0f + spread * (hrand(h, 17) * 2.0f - 1.0f));
}

<*
 Short random scratches, at most one per cell of a `cells` x `cells` grid, around `angle`.
 Returns 0..1 coverage of the strongest scratch.
 @require cells > 0 && max_len > 0.0f
*>
fn float scratches(Uv uv, int cells, float max_len, float angle, float spread, uint seed) @private
{
	float cell_px = PX / cells;
	Uv g = uv * (float)cells;
	Lattice base = (Lattice)g.floor();
	Uv p = g * cell_px;
	float best;
	for (int dy = -1; dy <= 1; dy++)
	{
		for (int dx = -1; dx <= 1; dx++)
		{
			Lattice c = base + (Lattice){ dx, dy };
			Lattice cw = wrap2(c, { cells, cells });
			uint h = hash(cw.x, cw.y, seed);
			if (hrand(h, 1) < 0.35f)
			{
				continue;
			}
			float a = angle + spread * (hrand(h, 2) * 2.0f - 1.0f);
			Uv start = ((Uv)c + (Uv){ hrand(h, 3), hrand(h, 4) }) * cell_px;
			Uv end = start + (Uv){ math::cos(a), math::sin(a) } * (max_len * (0.3f + 0.7f * hrand(h, 5)));
			float t;
			float d = sd_segment(p, start, end, &t);
			float width = 0.35f + 0.5f * hrand(h, 6) * (1.0f - t);
			best = math::max(best, coverage(width - d) * (0.4f + 0.6f * hrand(h, 7)));
		}
	}
	return best;
}

// ---------------------------------------------------------------------------------------------
// Materials
// ---------------------------------------------------------------------------------------------

// Subway tiles: 13 x 26 per texture = 15.4 x 7.7 cm, bevelled, running bond.
const int TILE_COLS @private = 13;
const int TILE_ROWS @private = 26;
const float GROUT_PX @private = 1.2f;
const float TILE_BEVEL_PX @private = 1.8f;
const float TILE_BEVEL_H @private = 0.9f;
const int LISTEL_EVERY @private = 13;   // TILE_BAND: decorative row every 1 m
const int LISTEL_ROW @private = 6;
const Rgb GRIME @private = { 0.40f, 0.37f, 0.30f };

enum TileStyle : char @private
{
	PLAIN,
	BANDED,
}

// Decorative listel: navy strip with a cream centre line and a diamond on every piece.
fn Rgb listel(GridCell cell) @private
{
	Rgb navy = { 0.10f, 0.20f, 0.46f };
	Rgb cream = { 0.93f, 0.88f, 0.72f };
	Uv a = math::abs(cell.local);
	float motif = math::max(coverage(3.8f - (a.x + a.y * 1.2f)), coverage(0.7f - a.y));
	float rim = 1.0f - coverage(cell.half.y - 1.7f - a.y);
	return navy.lerp(cream, motif).lerp(cream * 0.85f, rim * 0.7f);
}

fn Texel tiles(Uv uv, Rgb glaze, TileStyle style, uint seed) @private
{
	int row = row_of(uv.y, TILE_ROWS);
	bool is_listel = style == BANDED && row % LISTEL_EVERY == LISTEL_ROW;
	float shift = is_listel ? 0.25f : (float)(row & 1) * 0.5f;
	GridCell cell = grid(uv, TILE_COLS, TILE_ROWS, shift);
	uint h = hash(cell.id.x, cell.id.y, seed);
	float inside = -sd_box(cell.local, cell.half - GROUT_PX * 0.5f, 1.3f);

	Rgb tile = glaze * (0.965f + 0.06f * hrand(h, 1)) + (Rgb){ 0.012f, 0.0f, -0.012f } * (hrand(h, 2) - 0.5f);
	if (is_listel)
	{
		tile = listel(cell);
	}
	tile *= 1.0f + 0.02f * gnoise(uv, { 24, 24 }, seed + 1);

	// Grime: towards the bottom of the texture (per row, so the seam falls on a grout line),
	// in vertical streaks, and collected on the lower lip of every tile.
	float low = smoothstep(0.55f, 1.0f, (row + 0.5f) / TILE_ROWS);
	float streak = sat(fbm(uv, { 14, 2 }, 3, seed + 2) * 1.2f + 0.5f);
	float lip = smoothstep(0.3f, 1.0f, cell.local.y / cell.half.y);
	float grime = sat(low * streak * 0.45f + lip * 0.08f + 0.06f * gnoise(uv, { 48, 48 }, seed + 3));
	tile = tile.lerp(GRIME, grime * 0.4f);

	Rgb grout = (Rgb){ 0.45f, 0.44f, 0.41f } * (0.9f + 0.2f * vnoise(uv, { 128, 128 }, seed + 4));
	grout = grout.lerp(GRIME * 0.6f, low * 0.5f);

	Uv n = cell.local / cell.half;
	float pillow = 0.35f * (1.0f - n.x * n.x) * (1.0f - n.y * n.y);
	float cover = coverage(inside);
	return { grout.lerp(tile, cover), (bevel(inside, TILE_BEVEL_PX, TILE_BEVEL_H) + pillow) * cover };
}

fn Texel shade_tile_white(Uv uv) @private => tiles(uv, { 0.94f, 0.94f, 0.91f }, PLAIN, 0x711E);

fn Texel shade_tile_band(Uv uv) @private => tiles(uv, { 0.39f, 0.77f, 0.93f }, BANDED, 0xBA4D);

// Formed concrete: 1 m panels with seams and tie holes, stains, aggregate and bug holes.
fn Texel shade_concrete(Uv uv) @private
{
	const uint SEED = 0xC0C0;
	const int PANELS = 2;
	const int TIE_HOLES = 4;   // per texture side, 50 cm apart

	Lattice panel = (Lattice)(uv * (float)PANELS).floor();
	float tone = 0.09f * fbm(uv, { 3, 3 }, 5, SEED)
		+ 0.03f * (rand01(panel.x, panel.y, SEED + 1) * 2.0f - 1.0f)
		+ 0.035f * gnoise(uv, { 128, 128 }, SEED + 2)
		+ 0.03f * (vnoise(uv, { 256, 256 }, SEED + 3) * 2.0f - 1.0f);
	// Water drips running down from every horizontal seam, fading out below it.
	float below = uv.y * PANELS - math::floor(uv.y * PANELS);
	float drips = sat(fbm(uv, { 32, 2 }, 3, SEED + 4) * 2.0f + 0.1f) * math::exp(-below * 2.5f);
	tone -= 0.16f * drips * sat(fbm(uv, { 4, 4 }, 2, SEED + 5) * 2.0f + 0.6f);

	Worley agg = worley(uv, { 40, 40 }, 0.9f, SEED + 6);
	float pick = rand01(agg.cell.x, agg.cell.y, SEED + 7);
	tone += smoothstep(0.2f, 0.12f, agg.f1) * (pick < 0.5f ? -0.06f : 0.04f);

	Worley pits = worley(uv, { 24, 24 }, 0.8f, SEED + 8);
	bool is_pit = rand01(pits.cell.x, pits.cell.y, SEED + 9) < 0.15f;
	float pit = is_pit ? smoothstep(0.08f, 0.045f, pits.f1) : 0.0f;

	Uv tie = uv * (float)TIE_HOLES;
	float hole_r = ((tie - tie.floor() - 0.5f) * (PX / TIE_HOLES)).length();
	float plug = coverage(3.6f - hole_r) - coverage(1.8f - hole_r);
	float hole = coverage(1.8f - hole_r);

	float seam = math::min(line_dist(uv.x, PANELS), line_dist(uv.y, PANELS));
	float fin = coverage(1.0f - seam);

	Rgb c = (Rgb){ 0.565f, 0.565f, 0.545f } * (1.0f + tone);
	c *= 1.0f - 0.08f * fin - 0.35f * pit - 0.08f * plug - 0.5f * hole;
	float height = 0.12f * gnoise(uv, { 96, 96 }, SEED + 10) + 0.25f * gnoise(uv, { 32, 32 }, SEED + 11)
		- 1.2f * pit + 0.7f * fin
		- 0.5f * plug - 1.2f * hole;
	return { c, height };
}

// Granite setts ("adoquines"): 20 x 12.5 cm in rows with random offsets, rounded tops, dark gaps.
const int COBBLE_COLS @private = 10;
const int COBBLE_ROWS @private = 16;
const float COBBLE_GAP_PX @private = 2.2f;

const Rgb[*] GRANITE @private = {
	{ 0.56f, 0.55f, 0.53f }, { 0.58f, 0.53f, 0.49f }, { 0.50f, 0.51f, 0.53f },
	{ 0.45f, 0.44f, 0.42f }, { 0.53f, 0.51f, 0.49f },
};

fn Texel shade_cobble(Uv uv) @private
{
	const uint SEED = 0xADC0;
	int row = row_of(uv.y, COBBLE_ROWS);
	GridCell cell = grid(uv, COBBLE_COLS, COBBLE_ROWS, rand01(row, 0, SEED));
	uint h = hash(cell.id.x, cell.id.y, SEED + 1);

	Uv warp = (Uv){ gnoise(uv, { 20, 20 }, SEED + 2), gnoise(uv, { 20, 20 }, SEED + 3) } * 1.3f;
	Uv off = ((Uv){ hrand(h, 1), hrand(h, 2) } - 0.5f) * 1.2f;
	Uv half = cell.half - COBBLE_GAP_PX * 0.5f - (Uv){ hrand(h, 3), hrand(h, 4) } * 0.6f;
	float inside = -sd_box(cell.local + warp - off, half, 2.5f + 2.0f * hrand(h, 5));

	Rgb stone = @pick(GRANITE, h, 0.08f);
	Worley grain = worley(uv, { 96, 96 }, 1.0f, SEED + 4);
	float g = rand01(grain.cell.x, grain.cell.y, SEED + 5);
	float crystal = g < 0.15f ? 0.68f : (g > 0.85f ? 1.22f : 0.93f + 0.14f * g);
	stone *= lerp(1.0f, crystal, 0.55f);
	stone *= 0.94f + 0.1f * smoothstep(2.0f, 7.0f, inside);
	stone = stone.lerp({ 0.26f, 0.23f, 0.20f }, 0.3f * (1.0f - smoothstep(0.0f, 1.6f, inside)));

	Rgb gap = (Rgb){ 0.16f, 0.145f, 0.13f } * (0.8f + 0.4f * vnoise(uv, { 128, 128 }, SEED + 6));
	float cover = coverage(inside);
	float height = bevel(inside, 5.0f, 2.2f) + 0.2f * gnoise(uv, { 64, 64 }, SEED + 7);
	return { gap.lerp(stone, cover), height * cover };
}

// Limestone ashlar (Obelisco): 1 m x 0.5 m blocks, thin joints, fine speckle, weathering.
fn Texel shade_stone(Uv uv) @private
{
	const uint SEED = 0x0BE1;
	const int COLS = 2;
	const int ROWS = 4;
	int row = row_of(uv.y, ROWS);
	GridCell cell = grid(uv, COLS, ROWS, (float)(row & 1) * 0.5f);
	uint h = hash(cell.id.x, cell.id.y, SEED);
	float inside = -sd_box(cell.local, cell.half - 0.7f, 0.6f);

	Rgb stone = (Rgb){ 0.87f, 0.85f, 0.80f } * (0.97f + 0.06f * hrand(h, 1))
		+ (Rgb){ 0.012f, 0.0f, -0.015f } * (hrand(h, 2) * 2.0f - 1.0f);
	float tone = 0.03f * fbm(uv, { 6, 6 }, 4, SEED + 1) + 0.02f * gnoise(uv, { 128, 128 }, SEED + 2);
	Worley spk = worley(uv, { 160, 160 }, 1.0f, SEED + 3);
	float s = rand01(spk.cell.x, spk.cell.y, SEED + 4);
	float speck = smoothstep(0.32f, 0.18f, spk.f1) * (s < 0.25f ? -0.13f : (s > 0.85f ? 0.04f : 0.0f));
	float rain = sat(fbm(uv, { 32, 3 }, 3, SEED + 5) * 2.0f - 0.2f) * sat(fbm(uv, { 3, 3 }, 2, SEED + 6) + 0.3f);
	stone *= 1.0f + tone + speck - 0.06f * rain;

	Rgb joint = { 0.70f, 0.68f, 0.64f };
	float cover = coverage(inside);
	float height = bevel(inside, 2.0f, 1.2f) + 0.2f * gnoise(uv, { 128, 128 }, SEED + 7);
	return { joint.lerp(stone, cover), height * cover };
}

// Steel tread plate ("semilla de melón"): lens-shaped lugs at alternating 45°, scuffs, rust.
const int PLATE_CELLS @private = 24;   // 8.3 cm lug pitch

fn Texel shade_metal(Uv uv) @private
{
	const uint SEED = 0x3E7A;
	GridCell cell = grid(uv, PLATE_CELLS, PLATE_CELLS, 0.0f);
	Uv dir = ((cell.id.x + cell.id.y) & 1) == 1 ? (Uv){ 0.7071f, 0.7071f } : (Uv){ 0.7071f, -0.7071f };
	Uv q = { cell.local.dot(dir), cell.local.dot({ -dir.y, dir.x }) };
	float lug = (1.0f - (q / (Uv){ 4.4f, 1.7f }).length()) * 1.7f;   // ~px inside the lug
	float lug_cover = coverage(lug);

	Rgb steel = (Rgb){ 0.52f, 0.54f, 0.57f }
		* (1.0f + 0.1f * fbm(uv, { 2, 2 }, 5, SEED) + 0.03f * gnoise(uv, { 96, 96 }, SEED + 1));
	Rgb c = steel.lerp({ 0.68f, 0.70f, 0.72f }, smoothstep(0.2f, 1.4f, lug) * 0.75f);
	c *= 1.0f - 0.12f * (1.0f - lug_cover) * smoothstep(-2.5f, 0.0f, lug);

	float rust = smoothstep(0.3f, 0.6f, fbm(uv, { 6, 6 }, 4, SEED + 2)) * (1.0f - lug_cover);
	c = c.lerp({ 0.44f, 0.30f, 0.20f }, rust * 0.55f);
	float scuff = scratches(uv, 10, 40.0f, 0.4f, 0.5f, SEED + 3);
	c = c.lerp({ 0.74f, 0.75f, 0.76f }, scuff * 0.45f);

	float height = 1.4f * smoothstep(-0.4f, 1.2f, lug) + 0.15f * gnoise(uv, { 128, 128 }, SEED + 4);
	return { c, height };
}

// Corrugated container wall: 25 cm trapezoidal corrugation, rust streaks, chipped paint.
const int CORRUGATIONS @private = 8;

fn float corrugation(float u) @private
{
	float t = u * CORRUGATIONS;
	t -= math::floor(t);
	return smoothstep(0.02f, 0.16f, t) * (1.0f - smoothstep(0.48f, 0.62f, t));
}

fn Texel container(Uv uv, Rgb paint, uint seed) @private
{
	float ridge = corrugation(uv.x);
	float flank = 1.0f - math::abs(ridge * 2.0f - 1.0f);

	Rgb c = paint * (1.0f + 0.07f * fbm(uv, { 4, 4 }, 4, seed) + 0.025f * gnoise(uv, { 64, 64 }, seed + 1));
	c = c.lerp(c * 1.1f + 0.02f, ridge * 0.35f);

	// Rust bleeding down in long vertical streaks, denser where the paint is damaged.
	float damage = fbm(uv, { 12, 12 }, 4, seed + 5) + 0.2f * flank;
	float streak = smoothstep(0.06f, 0.3f, fbm(uv, { 48, 2 }, 3, seed + 2));
	streak *= sat(fbm(uv, { 3, 2 }, 2, seed + 3) * 2.5f + 0.25f);
	c = c.lerp({ 0.45f, 0.24f, 0.12f }, streak * 0.65f);
	c = c.lerp({ 0.30f, 0.27f, 0.23f }, 0.18f * sat(fbm(uv, { 2, 4 }, 3, seed + 4) + 0.3f));

	float chip = smoothstep(0.34f, 0.38f, damage);
	Rgb bare = (Rgb){ 0.42f, 0.25f, 0.14f } * (0.75f + 0.5f * vnoise(uv, { 128, 128 }, seed + 6));
	c = c.lerp(bare, chip);
	float scratch = scratches(uv, 8, 30.0f, 0.1f, 0.6f, seed + 7);
	c = c.lerp(bare * 1.2f, scratch * 0.5f);

	float height = 2.6f * ridge - 0.4f * chip + 0.5f * fbm(uv, { 6, 6 }, 2, seed + 8);
	return { c, height };
}

fn Texel shade_container_red(Uv uv) @private => container(uv, { 0.66f, 0.19f, 0.13f }, 0xC0A1);

fn Texel shade_container_blue(Uv uv) @private => container(uv, { 0.16f, 0.33f, 0.60f }, 0xB10E);

// Worn planks: 16.7 cm boards along U, 1 or 2 boards per row, grain, knots, nails, wear.
const int PLANK_ROWS @private = 12;

const Rgb[*] WOODS @private = {
	{ 0.58f, 0.40f, 0.24f }, { 0.53f, 0.36f, 0.21f }, { 0.62f, 0.44f, 0.27f }, { 0.55f, 0.38f, 0.25f },
};

fn Texel shade_wood(Uv uv) @private
{
	const uint SEED = 0x300D;
	int row = row_of(uv.y, PLANK_ROWS);
	uint rh = hash(row, 0, SEED);
	int boards = 1 + (int)(rh & 1);
	GridCell cell = grid(uv, boards, PLANK_ROWS, hrand(rh, 1));
	uint h = hash(cell.id.x, cell.id.y, SEED + 1 + rh);
	float inside = -sd_box(cell.local, cell.half - (Uv){ 0.6f, 0.8f }, 1.0f);

	float warp = fbm(uv, { 2, 6 }, 3, h) * 2.0f + 0.35f * gnoise(uv, { 6, 48 }, h + 1);
	Uv knot_at = { (hrand(h, 2) - 0.5f) * (cell.half.x * 1.6f), (hrand(h, 3) - 0.5f) * cell.half.y };
	float knot_d = ((cell.local - knot_at) / (Uv){ 5.0f, 2.6f }).length();
	bool has_knot = hrand(h, 4) < 0.45f;
	if (has_knot)
	{
		warp += 1.2f * math::exp(-knot_d * knot_d * 0.15f);
	}
	float rings = 0.5f + 0.5f * math::sin((uv.y * 56.0f + warp) * TAU);
	float late = smoothstep(0.55f, 0.95f, rings);
	float fibers = gnoise(uv, { 8, 192 }, h + 2);

	Rgb wood = @pick(WOODS, h, 0.1f) * (1.0f - 0.2f * late + 0.06f * fibers);
	if (has_knot)
	{
		wood *= 1.0f - 0.45f * smoothstep(1.0f, 0.4f, knot_d);
	}
	float wear = smoothstep(0.0f, 0.6f, fbm(uv, { 3, 3 }, 3, SEED + 2));
	wood = wood.lerp({ 0.64f, 0.54f, 0.42f }, wear * 0.25f);
	wood *= 0.85f + 0.15f * smoothstep(0.0f, 4.0f, inside);

	Uv nail = math::abs(cell.local) - (Uv){ cell.half.x - 5.0f, cell.half.y * 0.45f };
	float nails = coverage(1.1f - nail.length());
	wood = wood.lerp({ 0.15f, 0.13f, 0.12f }, nails * 0.85f);

	Rgb gap = { 0.16f, 0.11f, 0.07f };
	float cover = coverage(inside);
	float height = bevel(inside, 2.5f, 1.2f) + 0.25f * fibers - 0.5f * nails;
	return { gap.lerp(wood, cover), height * cover };
}

// Old red bricks: 25 x 7.1 cm courses, recessed mortar, chipped edges, soot and efflorescence.
const int BRICK_COLS @private = 8;
const int BRICK_ROWS @private = 28;

const Rgb[*] BRICKS @private = {
	{ 0.64f, 0.26f, 0.17f }, { 0.57f, 0.22f, 0.14f }, { 0.70f, 0.32f, 0.20f },
	{ 0.48f, 0.20f, 0.14f }, { 0.67f, 0.29f, 0.19f }, { 0.60f, 0.27f, 0.19f },
};

fn Texel shade_brick(Uv uv) @private
{
	const uint SEED = 0xB41C;
	int row = row_of(uv.y, BRICK_ROWS);
	GridCell cell = grid(uv, BRICK_COLS, BRICK_ROWS, (float)(row & 1) * 0.5f);
	uint h = hash(cell.id.x, cell.id.y, SEED);
	float erode = 1.0f * sat(fbm(uv, { 24, 24 }, 3, SEED + 1) * 1.6f);
	float inside = -sd_box(cell.local, cell.half - 0.75f - 0.3f * hrand(h, 1), 0.8f) - erode;

	Rgb brick = @pick(BRICKS, h, 0.08f);
	brick *= 1.0f + 0.08f * fbm(uv, { 32, 32 }, 3, SEED + 2 + h) + 0.04f * gnoise(uv, { 128, 128 }, SEED + 3);
	Worley pits = worley(uv, { 64, 64 }, 0.9f, SEED + 4);
	if (rand01(pits.cell.x, pits.cell.y, SEED + 5) < 0.3f)
	{
		brick *= 1.0f - 0.35f * smoothstep(0.14f, 0.08f, pits.f1);
	}

	float soot = smoothstep(0.1f, 0.6f, fbm(uv, { 6, 2 }, 4, SEED + 6));
	float salt = smoothstep(0.35f, 0.7f, fbm(uv, { 4, 4 }, 4, SEED + 7));

	Rgb mortar = (Rgb){ 0.56f, 0.52f, 0.46f } * (0.88f + 0.24f * vnoise(uv, { 128, 128 }, SEED + 8));
	float cover = coverage(inside);
	Rgb c = mortar.lerp(brick, cover);
	c *= 1.0f - 0.16f * soot;
	c = c.lerp({ 0.78f, 0.75f, 0.70f }, salt * 0.15f);
	float height = bevel(inside, 2.0f, 1.4f) + 0.2f * gnoise(uv, { 96, 96 }, SEED + 9);
	return { c, height * cover };
}

// Platform edge: yellow paint with black diagonal hazard stripes, worn through to concrete.
fn Texel shade_trim(Uv uv) @private
{
	const uint SEED = 0x7121;
	const int STRIPES = 8;           // diagonal repeats per texture: 25 cm along each axis
	const float BLACK = 0.22f;       // fraction of each period painted black
	float period_px = PX / STRIPES * 0.7071f;
	float s = (uv.x + uv.y) * STRIPES - BLACK * 0.5f;
	float black = coverage((BLACK * 0.5f - math::abs(s - math::round(s))) * period_px);

	Rgb paint = ((Rgb){ 1.0f, 0.83f, 0.08f }).lerp({ 0.10f, 0.10f, 0.09f }, black);
	paint *= 0.97f + 0.06f * fbm(uv, { 8, 8 }, 3, SEED) + 0.025f * gnoise(uv, { 128, 128 }, SEED + 1);
	float scuff = scratches(uv, 12, 36.0f, 0.0f, 0.3f, SEED + 2);
	paint = paint.lerp({ 0.25f, 0.23f, 0.20f }, scuff * 0.3f);

	float wear_n = fbm(uv, { 8, 8 }, 5, SEED + 3) + 0.12f * gnoise(uv, { 64, 64 }, SEED + 4);
	float worn = smoothstep(0.36f, 0.41f, wear_n);
	Rgb concrete = (Rgb){ 0.56f, 0.55f, 0.52f } * (0.9f + 0.2f * vnoise(uv, { 256, 256 }, SEED + 5));

	float height = 0.6f * (1.0f - worn) + 0.25f * gnoise(uv, { 128, 128 }, SEED + 6);
	return { paint.lerp(concrete, worn), height };
}

// Patchy plaza grass: individual blades over dark undergrowth, bare soil and dry patches.
const int BLADE_CELLS @private = 64;   // 4 px cells
const int BLADES_PER_CELL @private = 3;

fn Texel shade_grass(Uv uv) @private
{
	const uint SEED = 0x6A55;
	Uv warp = (Uv){ gnoise(uv, { 6, 6 }, SEED + 10), gnoise(uv, { 6, 6 }, SEED + 11) } * 0.03f;
	float patch = fbm(uv + warp, { 5, 5 }, 4, SEED);
	float dry = smoothstep(-0.05f, 0.4f, fbm(uv + warp, { 2, 2 }, 4, SEED + 1));
	float bare = smoothstep(-0.2f, -0.36f, patch);

	Rgb soil = (Rgb){ 0.36f, 0.29f, 0.20f } * (0.8f + 0.4f * vnoise(uv, { 128, 128 }, SEED + 2));
	Rgb under = (Rgb){ 0.16f, 0.29f, 0.10f } * (0.85f + 0.3f * gnoise(uv, { 64, 64 }, SEED + 3));
	under = under.lerp({ 0.33f, 0.31f, 0.17f }, dry * 0.5f);
	Rgb c = under.lerp(soil, bare);
	float height;

	float cell_px = PX / BLADE_CELLS;
	Uv g = uv * (float)BLADE_CELLS;
	Lattice base = (Lattice)g.floor();
	Uv p = g * cell_px;
	float best = -1.0f;
	for (int dy = -1; dy <= 1; dy++)
	{
		for (int dx = -1; dx <= 1; dx++)
		{
			Lattice cl = base + (Lattice){ dx, dy };
			Lattice cw = wrap2(cl, { BLADE_CELLS, BLADE_CELLS });
			for (uint k = 0; k < BLADES_PER_CELL; k++)
			{
				uint h = hash(cw.x, cw.y, SEED + 4 + k);
				float z = hrand(h, 1);
				if (z <= best || hrand(h, 2) < bare * 1.15f)
				{
					continue;
				}
				Uv root = ((Uv)cl + (Uv){ hrand(h, 3), hrand(h, 4) }) * cell_px;
				Uv dir = ((Uv){ hrand(h, 5), hrand(h, 6) } - 0.5f + (Uv){ 0.0f, -0.25f }).normalize();
				float t;
				float d = sd_segment(p, root, root + dir * (3.0f + 5.0f * hrand(h, 7)), &t);
				if (d > 0.95f * (1.0f - 0.6f * t))
				{
					continue;
				}
				best = z;
				Rgb blade = ((Rgb){ 0.22f, 0.44f, 0.13f }).lerp({ 0.40f, 0.60f, 0.21f }, hrand(h, 8));
				blade = blade.lerp({ 0.60f, 0.56f, 0.30f }, dry * hrand(h, 9));
				c = blade * (0.8f + 0.35f * t);
				height = 0.6f + z + 0.4f * t;
			}
		}
	}
	return { c, height };
}

// Warm fluorescent panel: diffuser lit by tubes every 50 cm, faint prismatic texture.
fn Texel shade_light(Uv uv) @private
{
	const int TUBES = 4;
	const int PRISMS = 64;
	float tubes = 0.5f + 0.5f * math::cos(uv.y * TUBES * TAU);
	Uv f = uv * (float)PRISMS;
	Uv prism = math::abs(f - f.floor() - 0.5f);
	Rgb c = (Rgb){ 1.0f, 0.955f, 0.86f } * (0.95f + 0.05f * tubes);
	return { c, 0.25f * (0.5f - math::max(prism.x, prism.y)) };
}

// Jump pad: glowing tech grid with concentric rings and outward chevrons, centred on the texture.
fn Texel shade_jumppad(Uv uv) @private
{
	const uint SEED = 0x1A3D;
	const int GRID = 16;
	const float RING_STEP = 24.0f;   // px between rings
	const float OUTER = 108.0f;      // px; beyond this only the seamless grid remains

	Rgb c = (Rgb){ 0.17f, 0.88f, 0.60f } * (0.96f + 0.06f * gnoise(uv, { 8, 8 }, SEED));
	float grid_d = math::min(line_dist(uv.x, GRID), line_dist(uv.y, GRID));
	c = c.lerp({ 0.07f, 0.55f, 0.36f }, coverage(0.7f - grid_d) * 0.6f);

	Uv d = (uv - 0.5f) * PX;
	float r = d.length();
	float fade = 1.0f - smoothstep(OUTER - 6.0f, OUTER, r);

	float rr = r / RING_STEP;
	float ring_d = math::abs(rr - math::round(rr)) * RING_STEP;
	float ring = r > RING_STEP * 0.5f ? coverage(1.6f - ring_d) : 0.0f;
	float glow = math::exp(-ring_d * 0.3f) * 0.4f;

	// Chevrons on the four axes, between the rings, pointing outwards.
	Uv a = math::abs(d);
	float along = math::max(a.x, a.y);
	float across = math::min(a.x, a.y);
	float cd = (along + 0.8f * across) / RING_STEP - 0.5f;
	float chev_d = math::abs(cd - math::round(cd)) * RING_STEP;
	float on_axis = 1.0f - smoothstep(0.32f, 0.42f, across / math::max(along, 1.0f));
	float chevron = r > RING_STEP ? coverage(2.4f - chev_d) * on_axis : 0.0f;

	float core = coverage(9.0f - r);
	c = c.lerp({ 0.60f, 1.0f, 0.85f }, sat(ring + glow) * fade);
	c = c.lerp({ 0.85f, 1.0f, 0.55f }, chevron * fade);
	c = c.lerp({ 0.90f, 1.0f, 0.95f }, core);
	return { c, 0.0f };
}
