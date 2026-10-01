// Bit-level packing for network messages over a caller-provided buffer (no allocation).
// Bit order is little-endian: stream bit i lives in byte i / 8 at bit i % 8, values go LSB
// first. Running out of space never crashes: the overflow flag latches, writes are dropped
// and reads return 0, so callers check `overflowed()` once at the end.
module arena::bitbuf;
import std::math;

const usz MAX_STR = 255;
const double TAU @local = math::PI * 2.0;

struct BitWriter
{
	char[] buf;
	usz pos;        // bits written
	bool overflow;
}

struct BitReader
{
	char[] buf;
	usz pos;        // bits read
	bool overflow;
}

macro ulong mask(int count) @local => (1UL << count) - 1;

<* Largest code for an n-bit quantized value (2^bits - 1). *>
macro double steps(int bits) @local => (double)mask(bits);

<*
 Latches the overflow flag of a BitWriter* or BitReader* when `count` more bits don't fit.
*>
macro bool no_room(s, usz count) @local
{
	if (!s.overflow && s.pos + count <= (usz)s.buf.len * 8) return false;
	s.overflow = true;
	return true;
}

<* Wraps to [-pi, pi). Non-finite input maps to 0. *>
fn double wrap_pi(double a) @local
{
	if (!math::is_finite(a)) return 0;
	return a - TAU * math::floor((a + math::PI) / TAU);
}

// ---------------------------------------------------------------- writer

fn BitWriter writer(char[] buf) => { .buf = buf };

<*
 Appends the low `count` bits of `value`.
 @require count >= 1 && count <= 32 : "count must be 1..32"
 @require count == 32 || (ulong)value <= mask(count) : "value does not fit in count bits"
*>
fn void BitWriter.bits(&self, uint value, int count)
{
	if (no_room(self, (usz)count)) return;
	ulong v = value;
	while (count > 0)
	{
		usz byte = self.pos / 8;
		int shift = (int)(self.pos % 8);
		int take = math::min(8 - shift, count);
		// A fresh byte may hold stale data from the caller's buffer.
		if (shift == 0) self.buf[byte] = 0;
		self.buf[byte] |= (char)((v & mask(take)) << shift);
		v >>= take;
		count -= take;
		self.pos += (usz)take;
	}
}

fn void BitWriter.flag(&self, bool v) => self.bits(v ? 1 : 0, 1);

fn void BitWriter.u8(&self, char v) => self.bits(v, 8);

fn void BitWriter.u16(&self, ushort v) => self.bits(v, 16);

fn void BitWriter.u32(&self, uint v) => self.bits(v, 32);

<* Raw IEEE-754 bits: exact round trip. *>
fn void BitWriter.f32(&self, float v) => self.bits(bitcast(v, uint), 32);

<*
 Clamps `v` to [min, max] (NaN -> min) and stores it in `bits` bits.
 Max error after a round trip: (max - min) / (2^bits - 1) / 2.
 @require bits >= 1 && bits <= 32 : "bits must be 1..32"
 @require max > min : "empty range"
*>
fn void BitWriter.quant(&self, float v, float min, float max, int bits)
{
	if (!(v >= min)) v = min;
	if (v > max) v = max;
	double t = ((double)v - min) / ((double)max - min);
	self.bits((uint)math::round(t * steps(bits)), bits);
}

<*
 Stores an angle wrapped to [-pi, pi) in `bits` bits. Max error: pi / 2^bits.
 @require bits >= 1 && bits <= 32 : "bits must be 1..32"
*>
fn void BitWriter.angle(&self, float radians, int bits)
{
	double t = (wrap_pi(radians) + math::PI) / TAU;
	ulong code = (ulong)math::round(t * (double)(1UL << bits)) & mask(bits);
	self.bits((uint)code, bits);
}

<*
 Each component clamped to [-range, range].
 @require range > 0 : "range must be positive"
 @require bits >= 1 && bits <= 32 : "bits must be 1..32"
*>
fn void BitWriter.vec3(&self, Vec3 v, float range, int bits)
{
	self.quant(v.x, -range, range, bits);
	self.quant(v.y, -range, range, bits);
	self.quant(v.z, -range, range, bits);
}

<* u8 length (truncated to 255 bytes) followed by the bytes. *>
fn void BitWriter.str(&self, String s)
{
	usz len = math::min((usz)s.len, MAX_STR);
	self.u8((char)len);
	foreach (c : s[:len]) self.u8(c);
}

<* Bytes used so far, rounded up. *>
fn usz BitWriter.bytes(&self) => (self.pos + 7) / 8;

fn bool BitWriter.overflowed(&self) => self.overflow;

// ---------------------------------------------------------------- reader

fn BitReader reader(char[] data) => { .buf = data };

<*
 Reads `count` bits (0 once overflowed).
 @require count >= 1 && count <= 32 : "count must be 1..32"
*>
fn uint BitReader.bits(&self, int count)
{
	if (no_room(self, (usz)count)) return 0;
	ulong v;
	int got;
	while (got < count)
	{
		usz byte = self.pos / 8;
		int shift = (int)(self.pos % 8);
		int take = math::min(8 - shift, count - got);
		v |= (((ulong)self.buf[byte] >> shift) & mask(take)) << got;
		got += take;
		self.pos += (usz)take;
	}
	return (uint)v;
}

fn bool BitReader.flag(&self) => self.bits(1) != 0;

fn char BitReader.u8(&self) => (char)self.bits(8);

fn ushort BitReader.u16(&self) => (ushort)self.bits(16);

fn uint BitReader.u32(&self) => self.bits(32);

fn float BitReader.f32(&self) => bitcast(self.bits(32), float);

<*
 @require bits >= 1 && bits <= 32 : "bits must be 1..32"
 @require max > min : "empty range"
*>
fn float BitReader.quant(&self, float min, float max, int bits)
{
	double t = (double)self.bits(bits) / steps(bits);
	return (float)(min + ((double)max - min) * t);
}

<*
 @require bits >= 1 && bits <= 32 : "bits must be 1..32"
*>
fn float BitReader.angle(&self, int bits)
{
	double t = (double)self.bits(bits) / (double)(1UL << bits);
	return (float)(t * TAU - math::PI);
}

<*
 @require range > 0 : "range must be positive"
 @require bits >= 1 && bits <= 32 : "bits must be 1..32"
*>
fn Vec3 BitReader.vec3(&self, float range, int bits)
{
	float x = self.quant(-range, range, bits);
	float y = self.quant(-range, range, bits);
	float z = self.quant(-range, range, bits);
	return { x, y, z };
}

<*
 Copies the string into `scratch` and returns a view of it. A string longer than `scratch`
 is truncated (the stream still skips all of it). Returns "" once overflowed.
*>
fn String BitReader.str(&self, char[] scratch)
{
	usz len = self.u8();
	usz kept = math::min(len, (usz)scratch.len);
	for (usz i = 0; i < len; i++)
	{
		char c = self.u8();
		if (i < kept) scratch[i] = c;
	}
	if (self.overflow) return "";
	return (String)scratch[:kept];
}

fn bool BitReader.overflowed(&self) => self.overflow;

fn usz BitReader.bits_left(&self) => self.overflow ? 0 : (usz)self.buf.len * 8 - self.pos;
