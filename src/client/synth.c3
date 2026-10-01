// Procedural audio DSP: oscillators, noise, envelopes, filters, effects, a layered
// voice renderer for sound effects and the menu-music sequencer.
// Pure C3 (no raylib): everything renders into float buffers at RATE, mono or
// interleaved stereo. Deterministic: all randomness comes from seeded xorshift.
module arena::synth;
import std::math, arena::mathx;

const int RATE = 44100;
const float DT = 1.0f / (float)RATE;
const float TAU = (float)math::PI * 2.0f;
const float PEAK = 0.9f;                    // normalization target for every sfx
const float SILENCE @private = 1e-6f;
const float FADE_OUT @private = 0.005f;     // anti-click ramp at the end of every sfx (s)
const float DEFAULT_Q = 0.7071f;            // Butterworth
const float MAX_CUTOFF @private = 0.45f;    // filter cutoff limit, fraction of RATE
const float DC_POLE @private = 0.999f;      // DC blocker, ~7 Hz
const float PCM_MAX @private = 32767.0f;

// ---------------------------------------------------------------------------
// Generic helpers (macros work for floats and float vectors alike)
// ---------------------------------------------------------------------------

macro lerp(a, b, t) @private => a + (b - a) * t;

macro frac(x) @private => x - math::floor(x);

fn float lfo(float rate, float t) @private => math::sin(TAU * rate * t);

fn float midi_hz(int key) @private => 440.0f * math::exp2((float)(key - 69) / 12.0f);

fn sz frames(float seconds) => (sz)math::ceil(seconds * (float)RATE);

// ---------------------------------------------------------------------------
// Randomness and noise
// ---------------------------------------------------------------------------

// Stateless white noise in [-1, 1) from an integer (lowbias32 hash): random access
// by frame number, used by the music. Stateful noise uses mathx::Rng (xorshift32).
fn float hash_noise(uint n)
{
	n ^= n >> 16;
	n *= 0x7feb352d;
	n ^= n >> 15;
	n *= 0x846ca68b;
	n ^= n >> 16;
	return (float)(n >> 8) * (2.0f / 16777216.0f) - 1.0f;
}

const float[<3>] PINK_POLE @private = { 0.99765f, 0.96300f, 0.57000f };
const float[<3>] PINK_GAIN @private = { 0.0990460f, 0.2965164f, 1.0526913f };
const float PINK_DIRECT @private = 0.1848f;
const float PINK_SCALE @private = 0.22f;
const float BROWN_LEAK @private = 0.02f;
const float BROWN_SCALE @private = 3.5f;

// Colored noise: white, pink (Paul Kellet's 3-pole economy filter) and brown.
struct Noise
{
	Rng rng;
	float[<3>] pink_z;
	float brown_z;
}

fn Noise noise(uint seed) => { .rng = mathx::rng(seed) };

fn float Noise.white(&self) => self.rng.signed();

fn float Noise.pink(&self)
{
	float w = self.rng.signed();
	self.pink_z = self.pink_z * PINK_POLE + w * PINK_GAIN;
	return (self.pink_z.sum() + w * PINK_DIRECT) * PINK_SCALE;
}

fn float Noise.brown(&self)
{
	self.brown_z = (self.brown_z + BROWN_LEAK * self.rng.signed()) / (1.0f + BROWN_LEAK);
	return self.brown_z * BROWN_SCALE;
}

// ---------------------------------------------------------------------------
// Oscillators
// ---------------------------------------------------------------------------

enum Wave : char
{
	SINE,
	SQUARE,
	SAW,
	TRIANGLE,
	WHITE,
	PINK,
	BROWN,
	FM,         // sine carrier, sine modulator at fm_ratio (bells, metal)
}

// PolyBLEP residual: rounds off saw/square edges to tame aliasing.
fn float blep(float t, float dt) @local
{
	if (t < dt)
	{
		float x = t / dt;
		return x + x - x * x - 1.0f;
	}
	if (t > 1.0f - dt)
	{
		float x = (t - 1.0f) / dt;
		return x * x + x + x + 1.0f;
	}
	return 0.0f;
}

fn float pulse(float phase, float dt, float duty) @local
{
	float edge = phase - duty;
	if (edge < 0.0f) edge += 1.0f;
	float v = phase < duty ? 1.0f : -1.0f;
	return v + blep(phase, dt) - blep(edge, dt);
}

<*
 Periodic waveform at `phase` in [0, 1); `dt` = freq / RATE (for the BLEP edges).
 Noise and FM are not periodic shapes and give 0 here.
 @require phase >= 0.0f && phase < 1.0f
*>
fn float shape(Wave w, float phase, float dt, float duty = 0.5f)
{
	switch (w)
	{
		case SINE: return math::sin(TAU * phase);
		case SAW: return 2.0f * phase - 1.0f - blep(phase, dt);
		case SQUARE: return pulse(phase, dt, duty);
		case TRIANGLE: return 1.0f - 4.0f * math::abs(phase - 0.5f);
		default: return 0.0f;
	}
}

// Phase accumulator.
struct Osc
{
	float phase;
}

// Returns the phase for this frame and advances by `dt` cycles.
fn float Osc.advance(&self, float dt)
{
	float p = self.phase;
	self.phase = frac(self.phase + dt);
	return p;
}

// ---------------------------------------------------------------------------
// Envelopes and sweeps
// ---------------------------------------------------------------------------

struct Adsr
{
	float attack;
	float decay;
	float sustain;
	float release;
}

<*
 Level while the gate is held: linear attack, quadratic decay to sustain.
 @require self.sustain >= 0.0f && self.sustain <= 1.0f
*>
fn float Adsr.held(&self, float t)
{
	if (t < self.attack) return t / self.attack;
	float d = t - self.attack;
	if (d >= self.decay) return self.sustain;
	float k = 1.0f - d / self.decay;
	return self.sustain + (1.0f - self.sustain) * k * k;
}

<*
 Envelope level at `t` for a note held `gate` seconds. Starts at 0 (when there is
 an attack) and is 0 from gate + release on.
 @require self.attack >= 0.0f && self.decay >= 0.0f && self.release >= 0.0f
 @ensure return >= 0.0f && return <= 1.0f
*>
fn float Adsr.at(&self, float t, float gate)
{
	if (t < 0.0f) return 0.0f;
	if (t < gate) return self.held(t);
	float r = t - gate;
	if (r >= self.release) return 0.0f;
	float k = 1.0f - r / self.release;
	return self.held(gate) * k * k;
}

<*
 Exponential glide from `from` to `to` over `dur` seconds, then holds `to`.
 @require from > 0.0f && to > 0.0f
*>
fn float sweep(float from, float to, float t, float dur)
{
	if (t <= 0.0f) return from;
	if (dur <= 0.0f || t >= dur) return to;
	return from * math::pow(to / from, t / dur);
}

// ---------------------------------------------------------------------------
// Filters
// ---------------------------------------------------------------------------

enum Filter : char
{
	NONE,
	LOWPASS,
	BANDPASS,
	HIGHPASS,
}

// Topology-preserving state-variable filter (Simper): stable under fast sweeps.
struct Svf
{
	float ic1;
	float ic2;
}

<*
 Filter one sample. BANDPASS is normalized to unity gain at the center.
 @require cutoff > 0.0f && q > 0.0f
*>
fn float Svf.tick(&self, float x, Filter mode, float cutoff, float q)
{
	float fc = math::min(cutoff, (float)RATE * MAX_CUTOFF);
	float g = math::tan((float)math::PI * fc * DT);
	float k = 1.0f / q;
	float a1 = 1.0f / (1.0f + g * (g + k));
	float a2 = g * a1;
	float a3 = g * a2;
	float v3 = x - self.ic2;
	float v1 = a1 * self.ic1 + a2 * v3;
	float v2 = self.ic2 + a2 * self.ic1 + a3 * v3;
	self.ic1 = 2.0f * v1 - self.ic1;
	self.ic2 = 2.0f * v2 - self.ic2;
	switch (mode)
	{
		case LOWPASS: return v2;
		case BANDPASS: return k * v1;
		case HIGHPASS: return x - k * v1 - v2;
		default: return x;
	}
}

// One-pole smoother; the highpass is its complement.
struct OnePole @private
{
	float z;
}

fn float OnePole.lowpass(&self, float x, float cutoff)
{
	float a = 1.0f - math::exp(-TAU * cutoff * DT);
	self.z += a * (x - self.z);
	return self.z;
}

fn float OnePole.highpass(&self, float x, float cutoff) => x - self.lowpass(x, cutoff);

// Soft saturation; `drive` 0 = clean.
fn float saturate(float x, float drive) @private => drive <= 0.0f ? x : math::tanh(x * (1.0f + drive));

// ---------------------------------------------------------------------------
// Delay and reverb
// ---------------------------------------------------------------------------

// Fixed-length circular delay line.
struct Delay @private
{
	float[] line;
	sz pos;
}

<*
 @require len > 0
*>
fn void Delay.init(&self, Allocator a, sz len)
{
	self.line = alloc::new_array(a, float, len);
	self.pos = 0;
}

fn void Delay.free(&self, Allocator a) => alloc::free(a, self.line.ptr);

fn float Delay.out(&self) => self.line[self.pos];

fn void Delay.push(&self, float x)
{
	self.line[self.pos] = x;
	self.pos = (self.pos + 1) % self.line.len;
}

const sz[4] COMB_LEN @private = { 1116, 1188, 1277, 1356 };     // Freeverb tunings at 44.1 kHz
const sz[2] ALLPASS_LEN @private = { 556, 441 };
const float ALLPASS_GAIN @private = 0.5f;
const float REVERB_DAMP @private = 0.3f;
const float REVERB_INPUT @private = 0.12f;

// Freeverb-lite: four damped combs processed as one float[<4>], two allpasses.
struct Reverb @private
{
	Delay[4] comb;
	Delay[2] allpass;
	float[<4>] damp;
	float[<4>] feedback;
}

<*
 @param tail : "decay time to -60 dB (RT60), seconds"
 @require tail > 0.0f
*>
fn void Reverb.init(&self, Allocator a, float tail)
{
	*self = {};
	foreach (i, &d : self.comb)
	{
		d.init(a, COMB_LEN[i]);
		self.feedback[i] = math::pow(10.0f, -3.0f * (float)COMB_LEN[i] / ((float)RATE * tail));
	}
	foreach (i, &d : self.allpass) d.init(a, ALLPASS_LEN[i]);
}

fn void Reverb.free(&self, Allocator a)
{
	foreach (&d : self.comb) d.free(a);
	foreach (&d : self.allpass) d.free(a);
}

fn float Reverb.tick(&self, float x)
{
	float[<4>] y;
	foreach (i, &d : self.comb) y[i] = d.out();
	self.damp = lerp(y, self.damp, REVERB_DAMP);
	float[<4>] back = x * REVERB_INPUT + self.damp * self.feedback;
	foreach (i, &d : self.comb) d.push(back[i]);
	float s = y.sum() * 0.25f;
	foreach (&d : self.allpass)
	{
		float held = d.out();
		d.push(s + held * ALLPASS_GAIN);
		s = held - s;
	}
	return s;
}

<*
 Add a reverb tail in place (the buffer must already have room for it).
 @require mix >= 0.0f && tail > 0.0f
*>
fn void reverb(float[] buf, float mix, float tail)
{
	@pool()
	{
		Reverb r;
		r.init(tmem, tail);
		foreach (&s : buf) *s += r.tick(*s) * mix;
	};
}

const int PHASER_STAGES @private = 4;
const float PHASER_RATE @private = 1.3f;    // LFO Hz
const float PHASER_LO @private = 250.0f;
const float PHASER_HI @private = 3500.0f;

<*
 Sweeping notches: dry + a chain of first-order allpasses whose corner rides an LFO.
 @require depth >= 0.0f && depth <= 1.0f
*>
fn void phaser(float[] buf, float depth)
{
	float[PHASER_STAGES] x1;
	float[PHASER_STAGES] y1;
	foreach (i, &s : buf)
	{
		float t = (float)i * DT;
		float fc = sweep(PHASER_LO, PHASER_HI, 0.5f + 0.5f * lfo(PHASER_RATE, t), 1.0f);
		float w = math::tan((float)math::PI * fc * DT);
		float a = (w - 1.0f) / (w + 1.0f);
		float v = *s;
		for (int k = 0; k < PHASER_STAGES; k++)
		{
			float y = a * v + x1[k] - a * y1[k];
			x1[k] = v;
			y1[k] = y;
			v = y;
		}
		*s += v * depth;
	}
}

// ---------------------------------------------------------------------------
// Buffer utilities
// ---------------------------------------------------------------------------

fn float peak(float[] buf)
{
	float p = 0.0f;
	foreach (s : buf) p = math::max(p, math::abs(s));
	return p;
}

fn float rms(float[] buf)
{
	if (buf.len == 0) return 0.0f;
	double acc = 0;
	foreach (s : buf) acc += (double)(s * s);
	return (float)math::sqrt(acc / (double)buf.len);
}

fn bool has_nan(float[] buf)
{
	foreach (s : buf)
	{
		if (!math::is_finite(s)) return true;
	}
	return false;
}

<*
 Scale so the loudest sample hits `target`. Silent buffers are left alone.
 @require target > 0.0f && target <= 1.0f
*>
fn void normalize(float[] buf, float target = PEAK)
{
	float p = peak(buf);
	if (p < SILENCE) return;
	float k = target / p;
	foreach (&s : buf) *s *= k;
}

// Remove DC offset (noise integrators and asymmetric clipping drift).
fn void dc_block(float[] buf) @private
{
	float x1 = 0.0f;
	float y1 = 0.0f;
	foreach (&s : buf)
	{
		float y = *s - x1 + DC_POLE * y1;
		x1 = *s;
		y1 = y;
		*s = y;
	}
}

// Linear ramp to zero over the last `n` frames.
fn void fade_out(float[] buf, sz n) @private
{
	sz len = math::min(n, buf.len);
	for (sz i = 0; i < len; i++)
	{
		buf[buf.len - 1 - i] *= (float)i / (float)len;
	}
}

<*
 Float [-1, 1] to signed 16-bit PCM, clamping overs.
 @require dst.len >= src.len
*>
fn void to_pcm16(float[] src, short[] dst)
{
	foreach (i, s : src) dst[i] = (short)(math::clamp(s, -1.0f, 1.0f) * PCM_MAX);
}

// ---------------------------------------------------------------------------
// Layered sound effects
// ---------------------------------------------------------------------------

// One voice of a sound: source → pitch glide/vibrato → filter sweep → drive → envelope.
// Zero means "off / default" for every optional field.
struct Layer
{
	Wave wave;
	float at;           // start offset (s)
	float len;          // gate time (s); the envelope release follows
	float f0;           // start pitch (Hz); unused by noise
	float f1;           // end pitch (Hz); 0 = hold f0
	float glide;        // pitch glide time (s); 0 = the whole gate
	float duty;         // SQUARE pulse width; 0 = 0.5
	float fm_ratio;     // FM modulator/carrier frequency ratio
	float fm_index;     // FM depth (radians), follows the envelope
	float vib_rate;     // LFO rate (Hz), shared by vibrato and filter wobble
	float vib_depth;    // vibrato depth (fraction of pitch)
	float wobble;       // cutoff LFO depth (fraction of cutoff, < 1)
	Adsr env;
	Filter filter;
	float cut0;         // cutoff at start (Hz)
	float cut1;         // cutoff at end (Hz), swept over the whole layer; 0 = hold
	float q;            // resonance; 0 = Butterworth
	float drive;        // saturation; 0 = clean
	float gain;
}

// Post effects for the mixed layers of one sound.
struct Post
{
	float reverb;       // wet mix
	float tail;         // reverb RT60 (s)
	float phaser;       // phaser depth 0..1
}

fn float Layer.end(&self) => self.at + self.len + self.env.release;

fn float Layer.pitch_at(&self, float t)
{
	float f = self.f0;
	if (self.f1 > 0.0f) f = sweep(self.f0, self.f1, t, self.glide > 0.0f ? self.glide : self.len);
	if (self.vib_depth > 0.0f) f *= 1.0f + self.vib_depth * lfo(self.vib_rate, t);
	return f;
}

fn float Layer.cutoff_at(&self, float t)
{
	float c = self.cut0;
	if (self.cut1 > 0.0f) c = sweep(self.cut0, self.cut1, t, self.len + self.env.release);
	if (self.wobble > 0.0f) c *= 1.0f + self.wobble * lfo(self.vib_rate, t);
	return c;
}

// Running state of one Layer while it renders.
struct Voice @private
{
	Layer layer;
	Osc osc;
	Osc mod;
	Noise noise;
	Svf filt;
}

fn float Voice.fm(&self, float dt, float env)
{
	float m = math::sin(TAU * self.mod.advance(dt * self.layer.fm_ratio));
	return math::sin(TAU * self.osc.advance(dt) + self.layer.fm_index * env * m);
}

fn float Voice.source(&self, float freq, float env)
{
	float dt = freq * DT;
	switch (self.layer.wave)
	{
		case WHITE: return self.noise.white();
		case PINK: return self.noise.pink();
		case BROWN: return self.noise.brown();
		case FM: return self.fm(dt, env);
		default:
			float duty = self.layer.duty > 0.0f ? self.layer.duty : 0.5f;
			return shape(self.layer.wave, self.osc.advance(dt), dt, duty);
	}
}

fn float Voice.tick(&self, float t)
{
	Layer* l = &self.layer;
	float env = l.env.at(t, l.len);
	float x = self.source(l.pitch_at(t), env);
	if (l.filter != NONE) x = self.filt.tick(x, l.filter, l.cutoff_at(t), l.q > 0.0f ? l.q : DEFAULT_Q);
	return saturate(x, l.drive) * env * l.gain;
}

// Mix one layer into `out` at its start offset (clipped to the buffer).
fn void mix_layer(float[] out, Layer* l, uint seed) @private
{
	Voice v = { .layer = *l, .noise = noise(seed) };
	sz start = (sz)(l.at * (float)RATE);
	sz count = frames(l.len + l.env.release);
	for (sz i = 0; i < count && start + i < out.len; i++)
	{
		out[start + i] += v.tick((float)i * DT);
	}
}

// Length of a sound: last layer end, plus the reverb tail.
fn float duration(Layer[] layers, Post fx)
{
	float end = 0.0f;
	foreach (&l : layers) end = math::max(end, l.end());
	if (fx.reverb > 0.0f) end += fx.tail;
	return end;
}

fn void finish(float[] buf, Post fx) @local
{
	if (fx.phaser > 0.0f) phaser(buf, fx.phaser);
	if (fx.reverb > 0.0f) reverb(buf, fx.reverb, fx.tail);
	dc_block(buf);
	fade_out(buf, frames(FADE_OUT));
	normalize(buf);
}

<*
 Render a layered sound into a new mono buffer from `a` (the caller frees it),
 post-processed and normalized to PEAK.
 @require layers.len > 0
 @require fx.reverb <= 0.0f || fx.tail > 0.0f : "reverb needs a tail"
 @ensure return.len > 0
*>
fn float[] render(Allocator a, Layer[] layers, Post fx = {}, uint seed = 1)
{
	float[] buf = alloc::new_array(a, float, frames(duration(layers, fx)));
	foreach (i, &l : layers) mix_layer(buf, l, seed * 7919 + (uint)i);
	finish(buf, fx);
	return buf;
}

// ---------------------------------------------------------------------------
// Menu music: 8 bars of A-minor tango-synthwave at 100 BPM. Notes are evaluated
// straight from the loop position (stateless), only filters and effects carry
// state, so chunks render forever and the loop point is seamless.
// ---------------------------------------------------------------------------

const int BPM @private = 100;
const int STEP @private = RATE * 60 / BPM / 4;                  // frames per 16th note (6615)
const int STEPS_PER_BAR @private = 16;
const int BARS @private = 8;
const int BAR @private = STEP * STEPS_PER_BAR;
const int LOOP = BAR * BARS;                                    // 846720 frames = 19.2 s
const float STEP_TIME @private = (float)STEP * DT;
const float BAR_TIME @private = (float)BAR * DT;
const float LOOP_TIME @private = (float)LOOP * DT;
const float MUSIC_LEVEL @private = 0.8f;
const float FADE_STEP @private = 1.0f / (0.4f * (float)RATE);   // full fade in 0.4 s

struct Note @private
{
	char step;          // 16th-note position in the loop
	char len;           // in 16ths
	char key;           // MIDI
}

// Bandoneon line over Am | F | Dm | E | Am | F | Dm | E7, A harmonic minor.
const Note[] LEAD @private = {
	{ 2, 4, 76 }, { 6, 2, 76 }, { 8, 2, 77 }, { 10, 2, 76 }, { 12, 2, 74 }, { 14, 2, 72 },
	{ 16, 6, 69 }, { 22, 2, 72 }, { 24, 4, 77 }, { 28, 2, 76 }, { 30, 2, 74 },
	{ 32, 4, 74 }, { 36, 2, 77 }, { 38, 4, 81 }, { 42, 2, 77 }, { 44, 2, 76 }, { 46, 2, 74 },
	{ 48, 6, 71 }, { 54, 2, 68 }, { 56, 2, 71 }, { 58, 2, 74 }, { 60, 4, 76 },
	{ 64, 6, 81 }, { 70, 2, 80 }, { 72, 2, 81 }, { 74, 2, 76 }, { 76, 4, 72 },
	{ 80, 4, 77 }, { 84, 2, 76 }, { 86, 2, 77 }, { 88, 4, 81 }, { 92, 2, 77 }, { 94, 2, 76 },
	{ 96, 4, 74 }, { 100, 2, 77 }, { 102, 2, 76 }, { 104, 2, 74 }, { 106, 2, 72 }, { 108, 2, 71 },
	{ 110, 2, 69 },
	{ 112, 6, 68 }, { 118, 2, 71 }, { 120, 2, 74 }, { 122, 2, 76 }, { 124, 4, 71 },
};

const char[3][BARS] CHORDS @private = {
	{ 57, 60, 64 },     // Am
	{ 57, 60, 65 },     // F
	{ 57, 62, 65 },     // Dm
	{ 56, 59, 64 },     // E
	{ 57, 60, 64 },     // Am
	{ 57, 60, 65 },     // F
	{ 57, 62, 65 },     // Dm
	{ 56, 62, 64 },     // E7
};
const char[BARS] ROOTS @private = { 45, 41, 38, 40, 45, 41, 38, 40 };

const Adsr PAD_ENV @private = { 0.35f, 0.8f, 0.7f, 0.6f };
const float PAD_DETUNE @private = 0.006f;
const float PAD_CUTOFF @private = 1100.0f;
const float PAD_SWEEP @private = 0.5f;                      // cutoff LFO depth, one cycle per loop
const float PAD_Q @private = 1.2f;
const float PAD_LEVEL @private = 0.07f;

const char[3] BASS_HIT @private = { 0, 6, 12 };                     // tango 3-3-2, in 16ths
const char[3] BASS_LEN @private = { 6, 6, 4 };
const char[3] BASS_OCTAVE @private = { 0, 0, 12 };
const Adsr BASS_ENV @private = { 0.004f, 0.25f, 0.45f, 0.06f };
const float BASS_GATE @private = 0.7f;
const float BASS_SAW @private = 0.6f;
const float BASS_CUTOFF @private = 220.0f;
const float BASS_PLUCK @private = 900.0f;                           // cutoff follows the envelope
const float BASS_Q @private = 1.5f;
const float BASS_DRIVE @private = 0.8f;
const float BASS_LEVEL @private = 0.3f;

const int KICK_EVERY @private = 8;          // steps: beats 1 and 3
const float KICK_HIGH @private = 150.0f;
const float KICK_LOW @private = 45.0f;
const float KICK_DROP @private = 0.035f;
const float KICK_DECAY @private = 0.18f;
const float KICK_LEVEL @private = 0.45f;

const int SNARE_OFFSET @private = 4;            // steps after each kick: beats 2 and 4
const float SNARE_TONE @private = 1800.0f;
const float SNARE_Q @private = 0.8f;
const float SNARE_DECAY @private = 0.07f;
const float SNARE_BODY @private = 190.0f;
const float SNARE_BODY_DECAY @private = 0.05f;
const float SNARE_LEVEL @private = 0.2f;

const float HAT_CUTOFF @private = 7000.0f;
const float HAT_DECAY @private = 0.025f;
const float HAT_LEVEL @private = 0.07f;
const float HAT_PAN @private = 0.3f;
const uint HAT_SEED @private = 0x5bd1e995;

const float[<8>] HARMONICS @private = { 1, 2, 3, 4, 5, 6, 7, 8 };
// Free-reed spectrum; even partials lifted by the bandoneon's octave reed.
const float[<8>] REED @private = { 0.8f, 1.0f, 0.7f, 0.75f, 0.45f, 0.4f, 0.28f, 0.22f };
const float REED_NORM @private = 0.22f;
const float ARRASTRE @private = 0.0561f;                                                    // start a semitone flat: 1 - 2^(-1/12)
const float ARRASTRE_TIME @private = 0.03f;
const Adsr LEAD_ENV @private = { 0.03f, 0.2f, 0.75f, 0.05f };
const float LEAD_GAP @private = 0.06f;                                                      // > release: notes never overlap (marcato)
const float LEAD_SOFT @private = 0.8f;                                                      // off-beat notes vs accented ones
const float LEAD_LEVEL @private = 0.28f;
const float LEAD_PAN @private = -0.15f;
const float BELLOWS_RATE @private = 5.5f;
const float BELLOWS_DEPTH @private = 0.06f;

const int ECHO_STEPS @private = 3;              // dotted eighth
const float ECHO_FEEDBACK @private = 0.45f;
const float ECHO_MIX @private = 0.35f;
const float ROOM_TAIL @private = 1.8f;
const float PAD_SEND @private = 0.5f;
const float LEAD_SEND @private = 0.4f;
const float SNARE_SEND @private = 0.6f;
const float ROOM_MIX @private = 0.6f;

struct Song
{
	Allocator alloc;
	sz pos;             // frame within the loop
	float gain;         // output gain, slews toward `target` (fades)
	float target;
	Svf[2] pad_filt;    // L, R
	Svf bass_filt;
	Svf snare_filt;
	OnePole hat_filt;
	Delay[2] echo;      // ping-pong L, R
	Reverb room;
}

fn void Song.init(&self, Allocator a)
{
	*self = { .alloc = a, .target = 1.0f };
	foreach (&d : self.echo) d.init(a, (sz)(ECHO_STEPS * STEP));
	self.room.init(a, ROOM_TAIL);
}

fn void Song.free(&self)
{
	foreach (&d : self.echo) d.free(self.alloc);
	self.room.free(self.alloc);
}

// Back to bar 1 with a fade-in; effect tails are kept.
fn void Song.restart(&self)
{
	self.pos = 0;
	self.gain = 0.0f;
	self.target = 1.0f;
}

fn void Song.fade_to(&self, float target) => self.target = math::clamp(target, 0.0f, 1.0f);

fn bool Song.silent(&self) => self.gain <= 0.0f && self.target <= 0.0f;

<*
 Render interleaved stereo frames (L, R, L, R...) and advance the loop.
 @require out.len % 2 == 0
*>
fn void Song.render(&self, float[] out)
{
	for (sz i = 0; i < out.len; i += 2)
	{
		float[<2>] f = self.frame();
		out[i] = f.x;
		out[i + 1] = f.y;
	}
}

fn float[<2>] Song.frame(&self)
{
	float[<2>] pad = self.pad();
	float lead = self.lead();
	float snare = self.snare();
	float send = (pad.x + pad.y) * PAD_SEND + lead * LEAD_SEND + snare * SNARE_SEND;
	float room = self.room.tick(send) * ROOM_MIX;
	float center = self.bass() + self.kick() + snare + room;
	float[<2>] mix = pad + center + pan(lead, LEAD_PAN) + pan(self.hat(), HAT_PAN) + self.echo_tick(lead) * ECHO_MIX;
	self.gain = mathx::approach(self.gain, self.target, FADE_STEP);
	self.pos = (self.pos + 1) % LOOP;
	return math::tanh(mix) * (self.gain * MUSIC_LEVEL);
}

// Small pans: -1 left .. +1 right, center = full level on both sides.
fn float[<2>] pan(float x, float p) @local => { x * (1.0f - p), x * (1.0f + p) };

fn float saw_at(float freq, float t) @local => shape(SAW, frac(freq * t), freq * DT);

// One bar's chord: a detuned saw pair per tone, L and R detuned in opposite ways.
fn float[<2>] chord(int bar, float t) @local
{
	Adsr env_shape = PAD_ENV;
	float env = env_shape.at(t, BAR_TIME);
	if (env <= 0.0f) return { 0.0f, 0.0f };
	float[<2>] s;
	foreach (key : CHORDS[bar])
	{
		float f = midi_hz(key);
		s += { saw_at(f * (1.0f + PAD_DETUNE), t), saw_at(f * (1.0f - PAD_DETUNE), t) };
	}
	return s * env;
}

fn float[<2>] Song.pad(&self)
{
	int bar = (int)(self.pos / BAR);
	float t = (float)(self.pos % BAR) * DT;
	float[<2>] s = chord(bar, t) + chord((bar + BARS - 1) % BARS, t + BAR_TIME);
	float cut = PAD_CUTOFF * (1.0f + PAD_SWEEP * lfo(1.0f / LOOP_TIME, (float)self.pos * DT));
	float[<2>] out = { self.pad_filt[0].tick(s.x, LOWPASS, cut, PAD_Q), self.pad_filt[1].tick(s.y, LOWPASS, cut, PAD_Q) };
	return out * PAD_LEVEL;
}

fn float Song.bass(&self)
{
	int bar = (int)(self.pos / BAR);
	int step = (int)((self.pos % BAR) / STEP);
	int hit = 0;
	foreach (i, h : BASS_HIT)
	{
		if (step >= h) hit = (int)i;
	}
	float t = (float)(self.pos % BAR) * DT - (float)BASS_HIT[hit] * STEP_TIME;
	Adsr env_shape = BASS_ENV;
	float env = env_shape.at(t, (float)BASS_LEN[hit] * STEP_TIME * BASS_GATE);
	float f = midi_hz(ROOTS[bar] + BASS_OCTAVE[hit]);
	float p = frac(f * t);
	float x = (shape(SAW, p, f * DT) * BASS_SAW + math::sin(TAU * p)) * env;
	float y = self.bass_filt.tick(x, LOWPASS, BASS_CUTOFF + BASS_PLUCK * env, BASS_Q);
	return saturate(y, BASS_DRIVE) * BASS_LEVEL;
}

// Sine with a fast exponential pitch drop; the phase is integrated analytically.
fn float Song.kick(&self)
{
	float t = (float)(self.pos % (STEP * KICK_EVERY)) * DT;
	float drop = (KICK_HIGH - KICK_LOW) * KICK_DROP * (1.0f - math::exp(-t / KICK_DROP));
	return math::sin(TAU * frac(KICK_LOW * t + drop)) * math::exp(-t / KICK_DECAY) * KICK_LEVEL;
}

fn float Song.snare(&self)
{
	float t = (float)((self.pos + STEP * SNARE_OFFSET) % (STEP * KICK_EVERY)) * DT;
	float n = self.snare_filt.tick(hash_noise((uint)self.pos), BANDPASS, SNARE_TONE, SNARE_Q);
	float body = math::sin(TAU * frac(SNARE_BODY * t)) * math::exp(-t / SNARE_BODY_DECAY);
	return (n * math::exp(-t / SNARE_DECAY) + body * 0.4f) * SNARE_LEVEL;
}

// Closed hat on every eighth, off-beats louder.
fn float Song.hat(&self)
{
	float t = (float)(self.pos % (STEP * 2)) * DT;
	bool offbeat = (self.pos / (STEP * 2)) % 2 == 1;
	float n = self.hat_filt.highpass(hash_noise((uint)self.pos ^ HAT_SEED), HAT_CUTOFF);
	return n * math::exp(-t / HAT_DECAY) * (offbeat ? HAT_LEVEL : HAT_LEVEL * 0.5f);
}

// Latest melody note starting at or before `step`. Before the first one it is the
// last note of the loop, whose tail ended long ago.
fn Note lead_note(int step) @local
{
	Note n = LEAD[^1];
	foreach (cand : LEAD)
	{
		if (cand.step > step) break;
		n = cand;
	}
	return n;
}

// Bandoneon-ish reed: 8 additive partials in one vector op, sliding into pitch from
// a semitone below (the tango "arrastre"). Phase integrated analytically.
fn float reed(float freq, float t) @local
{
	float phase = freq * (t - ARRASTRE * ARRASTRE_TIME * (1.0f - math::exp(-t / ARRASTRE_TIME)));
	float[<8>] partials = math::sin(HARMONICS * (TAU * frac(phase)));
	return (partials * REED).sum() * REED_NORM;
}

fn float Song.lead(&self)
{
	Note n = lead_note((int)(self.pos / STEP));
	sz since = (self.pos - (sz)n.step * STEP + LOOP) % LOOP;
	float t = (float)since * DT;
	Adsr env_shape = LEAD_ENV;
	float env = env_shape.at(t, (float)n.len * STEP_TIME - LEAD_GAP);
	if (env <= 0.0f) return 0.0f;
	float accent = n.step % 4 == 0 ? 1.0f : LEAD_SOFT;
	float bellows = 1.0f + BELLOWS_DEPTH * lfo(BELLOWS_RATE, t);
	return reed(midi_hz(n.key), t) * env * accent * bellows * LEAD_LEVEL;
}

// Ping-pong echo: input enters left, each repeat bounces to the other side.
fn float[<2>] Song.echo_tick(&self, float x)
{
	float[<2>] out = { self.echo[0].out(), self.echo[1].out() };
	self.echo[0].push(x + out.y * ECHO_FEEDBACK);
	self.echo[1].push(out.x * ECHO_FEEDBACK);
	return out;
}
