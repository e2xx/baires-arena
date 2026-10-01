module arena::textures_test;
import std::math, arena::textures, arena::defs;

const int S = textures::TEX_SIZE;
// Euclidean RGB distance (0..1 units) allowed between a texture's mean and its Material.base:
// grout, gaps and hazard stripes pull the mean away from the flat base colour by design.
const float BASE_TOLERANCE = 0.2f;

fn char[] make(Material m)
{
	char[] px = mem::new_array(char, textures::TEX_BYTES);
	textures::generate(m, px);
	return px;
}

// Mean absolute RGB difference (0..255) between columns a and b.
fn float col_diff(char[] px, int a, int b)
{
	long sum;
	for (int y = 0; y < S; y++)
	{
		for (int c = 0; c < 3; c++)
		{
			sum += math::abs((int)px[(y * S + a) * 4 + c] - (int)px[(y * S + b) * 4 + c]);
		}
	}
	return (float)sum / (S * 3);
}

// Mean absolute RGB difference (0..255) between rows a and b.
fn float row_diff(char[] px, int a, int b)
{
	long sum;
	for (int x = 0; x < S; x++)
	{
		for (int c = 0; c < 3; c++)
		{
			sum += math::abs((int)px[(a * S + x) * 4 + c] - (int)px[(b * S + x) * 4 + c]);
		}
	}
	return (float)sum / (S * 3);
}

fn void generate_is_deterministic() @test
{
	foreach (m : Material::values)
	{
		char[] a = make(m);
		defer free(a);
		char[] b = make(m);
		defer free(b);
		assert(mem::equals(a, b), "%s differs between runs", m.id);
	}
}

fn void mean_color_matches_base() @test
{
	foreach (m : Material::values)
	{
		if (m.surface == INVISIBLE)
		{
			continue;
		}
		char[] px = make(m);
		defer free(px);
		double[<3>] sum;
		for (int i = 0; i < px.len; i += 4)
		{
			sum += (double[<3>]){ px[i], px[i + 1], px[i + 2] };
		}
		Vec3 mean = (Vec3)(sum / (double)(S * S * 255));
		float dist = (mean - m.base).length();
		assert(dist < BASE_TOLERANCE, "%s mean %s is %f away from base %s", m.id, mean, dist, m.base);
	}
}

// The wrap-around step (last column -> first, last row -> first) must look like any other step
// between neighbours: no worse than the largest step inside the texture.
fn void textures_tile_seamlessly() @test
{
	foreach (m : Material::values)
	{
		char[] px = make(m);
		defer free(px);
		float max_x;
		float max_y;
		for (int i = 0; i < S - 1; i++)
		{
			max_x = math::max(max_x, col_diff(px, i, i + 1));
			max_y = math::max(max_y, row_diff(px, i, i + 1));
		}
		float seam_x = col_diff(px, S - 1, 0);
		float seam_y = row_diff(px, S - 1, 0);
		assert(seam_x <= max_x + 1.0f, "%s: horizontal seam %f > max step %f", m.id, seam_x, max_x);
		assert(seam_y <= max_y + 1.0f, "%s: vertical seam %f > max step %f", m.id, seam_y, max_y);
	}
}

fn void textures_are_opaque() @test
{
	foreach (m : Material::values)
	{
		char[] px = make(m);
		defer free(px);
		for (int i = 3; i < px.len; i += 4)
		{
			assert(px[i] == 255, "%s pixel %d has alpha %d", m.id, i / 4, px[i]);
		}
	}
}

// Opaque albedo stays mid-range: no pure black or pure white pixels.
fn void opaque_albedo_mid_range() @test
{
	foreach (m : Material::values)
	{
		if (m.surface != OPAQUE)
		{
			continue;
		}
		char[] px = make(m);
		defer free(px);
		for (int i = 0; i < px.len; i++)
		{
			if (i % 4 == 3)
			{
				continue;
			}
			assert(px[i] > 0 && px[i] < 255, "%s byte %d = %d", m.id, i, px[i]);
		}
	}
}

// White-box: the toolkit primitives must be periodic over the texture, which is what makes every
// material tile. Reopens the module to reach its @private helpers.
module arena::textures;
import std::math, arena::defs;

const Uv[*] PROBES @private = { { 0.013f, 0.71f }, { 0.5f, 0.25f }, { 0.97f, 0.003f }, { 0.31f, 0.999f } };
const Uv[*] SHIFTS @private = { { 1, 0 }, { 0, 1 }, { -1, 0 }, { 0, -1 }, { 1, 1 } };
const float[*] ACROSS @private = { 0.13f, 0.42f, 0.71f, 0.9f };
const float EDGE @private = 1e-5f;   // uv distance to the texture border
const float EPS @private = 1e-2f;

fn bool near(float a, float b) @private => math::abs(a - b) < EPS;

// Sum of every primitive at `p`: any one of them jumping makes the sum jump.
fn float primitives(Uv p) @private
{
	return gnoise(p, { 7, 3 }, 11) + vnoise(p, { 5, 9 }, 12) + fbm(p, { 3, 2 }, 5, 13)
		+ scratches(p, 10, 40.0f, 0.4f, 0.5f, 14) + worley(p, { 6, 4 }, 0.9f, 15).f1;
}

fn void noise_is_continuous_across_border() @test
{
	foreach (c : ACROSS)
	{
		assert(near(primitives({ 1.0f - EDGE, c }), primitives({ EDGE, c })), "left/right at v=%f", c);
		assert(near(primitives({ c, 1.0f - EDGE }), primitives({ c, EDGE })), "top/bottom at u=%f", c);
	}
}

fn void noise_is_periodic() @test
{
	foreach (p : PROBES)
	{
		foreach (s : SHIFTS)
		{
			Uv q = p + s;
			assert(near(primitives(p), primitives(q)), "%s shifted by %s", p, s);
			assert(worley(p, { 6, 4 }, 0.9f, 15).cell == worley(q, { 6, 4 }, 0.9f, 15).cell);
		}
	}
}

fn void grid_is_periodic() @test
{
	foreach (p : PROBES)
	{
		foreach (s : SHIFTS)
		{
			GridCell a = grid(p, 13, 26, 0.5f);
			GridCell b = grid(p + s, 13, 26, 0.5f);
			assert(a.id == b.id && near(a.local.x, b.local.x) && near(a.local.y, b.local.y), "grid %s %s", p, s);
		}
	}
}

fn void every_visible_material_has_a_shader() @test
{
	foreach (m : Material::values)
	{
		assert((SHADERS[m] == null) == (m.surface == INVISIBLE), "%s", m.id);
	}
}
