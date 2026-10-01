module arena::audio_test;
import std::math, arena::synth, arena::audio;

const float EPS = 1e-4f;

fn void adsr_endpoints() @test
{
	Adsr env = { 0.1f, 0.2f, 0.5f, 0.3f };
	assert(env.at(-0.1f, 1.0f) == 0.0f);
	assert(env.at(0.0f, 1.0f) == 0.0f);
	assert(math::abs(env.at(0.1f, 1.0f) - 1.0f) < EPS, "attack peak");
	assert(math::abs(env.at(0.5f, 1.0f) - 0.5f) < EPS, "sustain");
	assert(math::abs(env.at(1.0f, 1.0f) - 0.5f) < EPS, "release starts at the sustain level");
	assert(env.at(1.3f, 1.0f) < 1e-6f, "release ends at 0");
	assert(env.at(1.31f, 1.0f) == 0.0f);
	assert(env.at(5.0f, 1.0f) == 0.0f);
}

fn void adsr_short_gate() @test
{
	// Gate closes mid-attack: the release starts from the level reached, never jumps.
	Adsr env = { 0.2f, 0.1f, 0.8f, 0.1f };
	float at_gate = env.at(0.05f, 0.05f);
	assert(math::abs(at_gate - 0.25f) < EPS);
	assert(env.at(0.07f, 0.05f) < at_gate);
	assert(env.at(0.15f, 0.05f) == 0.0f);
}

fn void adsr_zero_attack() @test
{
	Adsr env = { 0.0f, 0.1f, 0.0f, 0.0f };
	assert(env.at(0.0f, 0.1f) == 1.0f);
	assert(env.at(0.1f, 0.1f) == 0.0f);
}

fn void sweep_is_exponential() @test
{
	assert(synth::sweep(100, 1000, 0, 1) == 100);
	assert(synth::sweep(100, 1000, 1, 1) == 1000);
	assert(synth::sweep(100, 1000, 2, 1) == 1000);
	assert(math::abs(synth::sweep(100, 1000, 0.5f, 1) - math::sqrt(100000.0f)) < 0.01f);
}

fn void oscillators_bounded() @test
{
	foreach (w : Wave::values)
	{
		if (w == WHITE || w == PINK || w == BROWN || w == FM) continue;
		Osc osc;
		double sum = 0;
		double sq = 0;
		for (int i = 0; i < synth::RATE; i++)
		{
			float dt = 440.0f * synth::DT;
			float x = synth::shape(w, osc.advance(dt), dt);
			assert(math::is_finite(x) && math::abs(x) <= 1.1f, "%s out of range: %f", w, x);
			sum += x;
			sq += (double)(x * x);
		}
		assert(math::abs(sum / synth::RATE) < 0.02, "%s has DC", w);
		assert(math::sqrt(sq / synth::RATE) > 0.4, "%s too weak", w);
	}
}

fn void noise_is_deterministic() @test
{
	Noise a = synth::noise(42);
	Noise b = synth::noise(42);
	Noise c = synth::noise(43);
	bool differs;
	for (int i = 0; i < 1000; i++)
	{
		float w = a.white();
		assert(w >= -1.0f && w < 1.0f);
		assert(w == b.white());
		if (w != c.white()) differs = true;
		assert(a.pink() == b.pink());
		assert(a.brown() == b.brown());
	}
	assert(differs, "different seeds must give different noise");
}

// RMS of a filtered sine, measured after the transient.
fn float filtered_rms(Filter mode, float freq, float cutoff)
{
	Svf f;
	Osc osc;
	double acc = 0;
	int n = synth::RATE / 2;
	for (int i = 0; i < n; i++)
	{
		float x = math::sin(synth::TAU * osc.advance(freq * synth::DT));
		float y = f.tick(x, mode, cutoff, synth::DEFAULT_Q);
		if (i >= n / 2) acc += (double)(y * y);
	}
	return (float)math::sqrt(acc / (double)(n / 2));
}

fn void filters_pass_and_stop() @test
{
	assert(filtered_rms(LOWPASS, 100, 1000) > 0.65f);
	assert(filtered_rms(LOWPASS, 8000, 500) < 0.02f);
	assert(filtered_rms(HIGHPASS, 8000, 500) > 0.65f);
	assert(filtered_rms(HIGHPASS, 100, 2000) < 0.02f);
	assert(filtered_rms(BANDPASS, 1000, 1000) > 0.65f, "bandpass is unity at the center");
	assert(filtered_rms(BANDPASS, 100, 3000) < 0.1f);
}

fn void svf_stable_when_resonant() @test
{
	Svf f;
	Noise n = synth::noise(7);
	for (int i = 0; i < synth::RATE; i++)
	{
		float y = f.tick(n.white(), BANDPASS, 50.0f + (float)i, 30.0f);
		assert(math::is_finite(y) && math::abs(y) < 50.0f, "unstable at %d: %f", i, y);
	}
}

fn void reverb_tail_decays() @test
{
	float[] buf = mem::new_array(float, synth::RATE * 2);
	defer free(buf);
	buf[0] = 1.0f;
	synth::reverb(buf, 1.0f, 1.0f);
	float early = synth::rms(buf[1000:4410]);
	float late = synth::rms(buf[synth::RATE:4410]);
	assert(!synth::has_nan(buf));
	assert(early > 0.001f, "no reflections");
	assert(late < early * 0.03f, "RT60 = 1 s should be far down after 1 s: %f vs %f", late, early);
}

fn void normalize_hits_target() @test
{
	float[*] buf = { 0.1f, -0.4f, 0.2f };
	synth::normalize(&buf);
	assert(math::abs(buf[1] + synth::PEAK) < EPS);
	assert(math::abs(buf[0] - synth::PEAK / 4.0f) < EPS);
	float[3] silent;
	synth::normalize(&silent);
	assert(silent[0] == 0.0f && !synth::has_nan(&silent));
}

fn void pcm_conversion_clamps() @test
{
	float[*] src = { 0.0f, 1.0f, -1.0f, 0.5f, 2.0f, -3.0f };
	short[6] dst;
	synth::to_pcm16(&src, &dst);
	assert(dst[0] == 0);
	assert(dst[1] == 32767);
	assert(dst[2] == -32767);
	assert(dst[3] == 16383);
	assert(dst[4] == 32767);
	assert(dst[5] == -32767);
}

fn void render_length_matches_layers() @test
{
	Layer[*] layers = {
		{ .wave = SINE, .len = 0.1f, .f0 = 440, .env = { 0.01f, 0.05f, 0.5f, 0.2f }, .gain = 1 },
		{ .wave = WHITE, .at = 0.25f, .len = 0.05f, .env = { 0.001f, 0.02f, 0.0f, 0.1f }, .gain = 1 },
	};
	Post fx = { .reverb = 0.2f, .tail = 0.5f };
	float[] buf = synth::render(mem, &layers, fx);
	defer free(buf);
	// The noise layer ends last: 0.25 + 0.05 + 0.1 = 0.4 s, plus the 0.5 s tail.
	assert(math::abs(synth::duration(&layers, fx) - 0.9f) < EPS);
	assert(buf.len == synth::frames(synth::duration(&layers, fx)));
	assert(math::abs((float)buf.len - 0.9f * synth::RATE) <= 2.0f);
	assert(math::abs(synth::peak(buf) - synth::PEAK) < EPS);
	assert(buf[^1] == 0.0f, "faded out to silence");
	assert(!synth::has_nan(buf));
}

fn void recipes_are_sane() @test
{
	foreach (s : Sfx::values)
	{
		assert(s.layers.len > 0, "%s has no layers", s);
		assert(s.fx.reverb <= 0.0f || s.fx.tail > 0.0f, "%s: reverb without tail", s);
		foreach (l : s.layers)
		{
			bool noisy = l.wave == WHITE || l.wave == PINK || l.wave == BROWN;
			assert(l.gain > 0.0f && l.len > 0.0f, "%s: layer without gain or length", s);
			assert(noisy || l.f0 > 0.0f, "%s: pitched layer without f0", s);
			assert(l.filter == NONE || l.cut0 > 0.0f, "%s: filter without cutoff", s);
			assert(l.wobble < 1.0f, "%s: wobble would flip the cutoff", s);
		}
	}
}

fn void every_sfx_is_audible() @test
{
	foreach (s : Sfx::values)
	{
		@pool()
		{
			float[] buf = audio::render_sfx(s, tmem);
			assert(buf.len > 0, "%s is empty", s);
			assert(!synth::has_nan(buf), "%s has NaN", s);
			float p = synth::peak(buf);
			assert(p <= 1.0f && p > 0.85f, "%s peak %f", s, p);
			assert(synth::rms(buf) > 0.02f, "%s is nearly silent", s);
		};
	}
}

fn void sfx_are_deterministic() @test
{
	@pool()
	{
		float[] a = audio::render_sfx(EXPLOSION, tmem);
		float[] b = audio::render_sfx(EXPLOSION, tmem);
		assert(a.len == b.len);
		foreach (i, x : a) assert(x == b[i], "differs at %d", i);
	};
}

fn void song_renders_a_full_loop() @test
{
	Song song;
	song.init(mem);
	defer song.free();
	float[] buf = mem::new_array(float, 8192);
	defer free(buf);
	sz rendered = 0;
	while (rendered < synth::LOOP + 8192)
	{
		song.render(buf);
		assert(!synth::has_nan(buf));
		assert(synth::peak(buf) <= 1.0f);
		rendered += buf.len / 2;
	}
	assert(song.pos == rendered % synth::LOOP, "loop position wraps");
}

fn void song_fades_out_to_silence() @test
{
	Song song;
	song.init(mem);
	defer song.free();
	float[] buf = mem::new_array(float, synth::RATE * 2);
	defer free(buf);
	song.render(buf);
	assert(synth::rms(buf) > 0.01f, "music is playing");
	song.fade_to(0.0f);
	song.render(buf);
	assert(song.silent());
	song.render(buf);
	assert(synth::peak(buf) == 0.0f);
}

fn void attenuation_curve() @test
{
	assert(audio::attenuation(0.0f) == 1.0f);
	assert(audio::attenuation(audio::HEARING_RANGE) == 0.0f);
	assert(audio::attenuation(100.0f) == 0.0f);
	assert(audio::attenuation(59.0f) < 0.02f);
	float prev = 1.0f;
	for (float d = 0.5f; d < audio::HEARING_RANGE; d += 0.5f)
	{
		float g = audio::attenuation(d);
		assert(g <= prev && g >= 0.0f, "not monotonic at %f", d);
		prev = g;
	}
}

fn void pan_follows_listener_right() @test
{
	Vec3 right = { 1, 0, 0 };
	assert(audio::stereo_pan({ 10, 0, 0 }, right) > 0.5f);
	assert(audio::stereo_pan({ -10, 0, 0 }, right) < -0.5f);
	assert(math::abs(audio::stereo_pan({ 0, 0, 10 }, right)) < EPS, "ahead = center");
	assert(audio::stereo_pan({ 0.5f, 0, 0 }, right) < audio::stereo_pan({ 10, 0, 0 }, right), "near = centered");
	assert(audio::stereo_pan({ 0, 0, 0 }, right) == 0.0f);
	assert(audio::stereo_pan({ 10, 0, 0 }, { 0, 0, 0 }) == 0.0f, "degenerate right vector");
}

fn void noop_without_device() @test
{
	audio::play(FRAG);
	audio::play_at(EXPLOSION, { 5, 0, 0 }, { 0, 0, 0 }, { 1, 0, 0 });
	audio::set_master(0.5f);
	audio::music(true);
	audio::update();
	audio::shutdown();
}
