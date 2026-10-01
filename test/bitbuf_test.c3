module arena::bitbuf_test;
import std::math, arena::bitbuf;

const uint PATTERN @local = 0xA5C3_96E1;

fn void every_width_round_trips() @test
{
	char[256] buf;
	BitWriter w = bitbuf::writer(&buf);
	for (int n = 1; n <= 32; n++)
	{
		uint max = n == 32 ? uint::max : (uint)((1UL << n) - 1);
		w.flag(true); // keep everything misaligned
		w.bits(max, n);
		w.bits(PATTERN & max, n);
		w.bits(0, n);
	}
	assert(!w.overflowed());
	usz written = w.bytes();

	BitReader r = bitbuf::reader(buf[:written]);
	for (int n = 1; n <= 32; n++)
	{
		uint max = n == 32 ? uint::max : (uint)((1UL << n) - 1);
		assert(r.flag());
		assert(r.bits(n) == max, "width %d max", n);
		assert(r.bits(n) == PATTERN & max, "width %d pattern", n);
		assert(r.bits(n) == 0, "width %d zero", n);
	}
	assert(!r.overflowed());
	assert(r.bits_left() < 8);
}

fn void bit_order_is_little_endian() @test
{
	char[4] buf;
	BitWriter w = bitbuf::writer(&buf);
	w.bits(0b11, 2);
	w.bits(0b001, 3);
	w.bits(0, 3);
	w.u16(0x1234);
	assert(buf[0] == 0b00111);
	assert(buf[1] == 0x34 && buf[2] == 0x12);
	assert(w.bytes() == 3);
}

fn void stale_buffer_is_overwritten() @test
{
	char[8] buf;
	buf[..] = 0xFF;
	BitWriter w = bitbuf::writer(&buf);
	w.bits(0b101, 3);
	w.u32(0x0102_0304);
	w.flag(false);
	BitReader r = bitbuf::reader(buf[:w.bytes()]);
	assert(r.bits(3) == 0b101);
	assert(r.u32() == 0x0102_0304);
	assert(!r.flag());
}

fn void typed_values_round_trip() @test
{
	char[64] buf;
	BitWriter w = bitbuf::writer(&buf);
	w.flag(true);
	w.u8(0xAB);
	w.u16(0xBEEF);
	w.u32(0xDEAD_BEEF);
	w.f32(-123.456f);
	w.f32(-0.0f);
	w.f32(float::nan);
	w.flag(false);

	BitReader r = bitbuf::reader(buf[:w.bytes()]);
	assert(r.flag());
	assert(r.u8() == 0xAB);
	assert(r.u16() == 0xBEEF);
	assert(r.u32() == 0xDEAD_BEEF);
	assert(r.f32() == -123.456f);
	assert(bitcast(r.f32(), uint) == bitcast(-0.0f, uint));
	assert(math::is_nan(r.f32()));
	assert(!r.flag());
	assert(!r.overflowed());
}

fn void quant_error_is_bounded() @test
{
	char[64] buf;
	int[*] widths = { 1, 4, 8, 12, 16, 24, 32 };
	float min = -50.0f;
	float max = 75.0f;
	foreach (bits : widths)
	{
		double bound = ((double)max - min) / (double)((1UL << bits) - 1) / 2.0 + 1e-4;
		for (float v = -60.0f; v <= 85.0f; v += 0.37f)
		{
			BitWriter w = bitbuf::writer(&buf);
			w.quant(v, min, max, bits);
			BitReader r = bitbuf::reader(&buf);
			float got = r.quant(min, max, bits);
			float want = math::clamp(v, min, max);
			assert(math::abs((double)got - want) <= bound, "bits %d v %f got %f", bits, v, got);
		}
	}
}

fn void quant_endpoints_and_nan() @test
{
	char[16] buf;
	BitWriter w = bitbuf::writer(&buf);
	w.quant(-2.0f, -2.0f, 3.0f, 10);
	w.quant(3.0f, -2.0f, 3.0f, 10);
	w.quant(1e30f, -2.0f, 3.0f, 10);
	w.quant(float::nan, -2.0f, 3.0f, 10);
	BitReader r = bitbuf::reader(&buf);
	assert(r.quant(-2.0f, 3.0f, 10) == -2.0f);
	assert(r.quant(-2.0f, 3.0f, 10) == 3.0f);
	assert(r.quant(-2.0f, 3.0f, 10) == 3.0f);
	assert(r.quant(-2.0f, 3.0f, 10) == -2.0f);
}

fn double angle_dist(double a, double b) @local
{
	double d = math::abs(a - b);
	return math::min(d, math::PI * 2 - d);
}

fn void angle_error_is_bounded() @test
{
	char[16] buf;
	int[*] widths = { 6, 8, 12, 16, 32 };
	foreach (bits : widths)
	{
		double bound = math::PI / (double)(1UL << bits) + 1e-5;
		for (float a = -10.0f; a <= 10.0f; a += 0.013f)
		{
			BitWriter w = bitbuf::writer(&buf);
			w.angle(a, bits);
			BitReader r = bitbuf::reader(&buf);
			float got = r.angle(bits);
			// float(pi) is a hair above pi, so the closed float interval is the honest bound.
			assert(got >= -(float)math::PI && got <= (float)math::PI, "bits %d out of range: %f", bits, got);
			assert(angle_dist(got, a) <= bound, "bits %d a %f got %f", bits, a, got);
		}
	}
}

fn void angle_wraps_pi_to_minus_pi() @test
{
	char[8] buf;
	BitWriter w = bitbuf::writer(&buf);
	w.angle((float)math::PI, 16);
	w.angle(float::inf, 16);
	BitReader r = bitbuf::reader(&buf);
	assert(math::abs(r.angle(16) + math::PI) < 1e-6);
	assert(math::abs(r.angle(16)) < 1e-4);
}

fn void vec3_round_trips_and_clamps() @test
{
	char[32] buf;
	BitWriter w = bitbuf::writer(&buf);
	Vec3 v = { 12.34f, -0.5f, 99.0f };
	w.vec3(v, 64.0f, 16);
	w.vec3({ 500.0f, -500.0f, 0.0f }, 64.0f, 16);
	assert(w.bytes() == 12);

	BitReader r = bitbuf::reader(&buf);
	Vec3 got = r.vec3(64.0f, 16);
	float bound = 128.0f / 65535.0f / 2.0f + 1e-5f;
	assert(math::abs(got.x - v.x) <= bound);
	assert(math::abs(got.y - v.y) <= bound);
	assert(got.z == 64.0f);
	Vec3 clamped = r.vec3(64.0f, 16);
	assert(clamped.x == 64.0f && clamped.y == -64.0f);
	assert(math::abs(clamped.z) <= bound);
}

fn void strings_round_trip() @test
{
	char[600] buf;
	char[300] long_src;
	long_src[..] = 'x';
	BitWriter w = bitbuf::writer(&buf);
	w.flag(true); // misaligned strings
	w.str("");
	w.str("Baires LAN");
	w.str((String)&long_src);
	w.str("truncado");
	w.u16(0xCAFE);
	assert(!w.overflowed());

	char[256] scratch;
	char[4] tiny;
	BitReader r = bitbuf::reader(buf[:w.bytes()]);
	assert(r.flag());
	assert(r.str(&scratch) == "");
	assert(r.str(&scratch) == "Baires LAN");
	String long_str = r.str(&scratch);
	assert(long_str.len == bitbuf::MAX_STR && long_str[^1] == 'x');
	assert(r.str(&tiny) == "trun");
	assert(r.u16() == 0xCAFE);
	assert(!r.overflowed());
}

fn void writer_overflow_latches() @test
{
	char[3] buf;
	BitWriter w = bitbuf::writer(&buf);
	w.u16(0x1234);
	w.bits(0x3F, 6);
	assert(!w.overflowed());
	w.u8(0xFF); // needs 8, only 2 left
	assert(w.overflowed());
	w.flag(true); // would fit, but writes stay dropped after overflow
	w.str("nope");
	assert(w.bytes() == 3);
	assert(buf[0] == 0x34 && buf[1] == 0x12 && buf[2] == 0x3F);
}

fn void reader_overflow_returns_zero() @test
{
	char[3] data = { 0xFF, 0xFF, 0x05 };
	char[16] scratch;
	BitReader r = bitbuf::reader(&data);
	assert(r.u16() == 0xFFFF);
	assert(r.bits_left() == 8);
	assert(r.u32() == 0);
	assert(r.overflowed());
	assert(r.bits_left() == 0);
	assert(r.u8() == 0);
	assert(!r.flag());

	BitReader s = bitbuf::reader(&data);
	s.u16();
	assert(s.str(&scratch) == ""); // claims 5 bytes, none present
	assert(s.overflowed());
}

fn void empty_buffers_overflow() @test
{
	BitWriter w = bitbuf::writer({});
	w.flag(true);
	assert(w.overflowed() && w.bytes() == 0);
	BitReader r = bitbuf::reader({});
	assert(r.bits_left() == 0);
	assert(r.u8() == 0 && r.overflowed());
}
