// Game-facing audio: every sound effect is synthesized at startup from the recipe
// table below (no audio files), played through round-robin raylib sound aliases
// (2D or 3D-attenuated), and the menu music is streamed from arena::synth::Song.
module arena::audio;
import std::math, raylib6::rl, arena::synth;

const int VOICES @private = 6;              // aliases per sfx: overlapping plays
const float HEARING_RANGE = 60.0f;          // m; silent from here on
const float NEAR_DIST @private = 3.0f;      // m; full volume and centered pan inside
const float ROLLOFF @private = 0.08f;       // inverse-distance rolloff per meter
const float PAN_WIDTH @private = 0.8f;      // keep some signal in the far ear
const float MIN_GAIN @private = 0.002f;     // quieter than this is not worth a voice
const int MUSIC_CHUNK @private = 4096;      // frames per stream refill (= raylib sub-buffer)
const int STREAM_BUFFERS @private = 2;      // raylib double-buffers audio streams
const float MUSIC_VOLUME @private = 0.8f;
const uint SFX_SEED @private = 0xBA05;
const uint SAMPLE_BITS @private = 16;
const uint MONO @private = 1;
const uint STEREO @private = 2;

// Notes (Hz) used by the musical sounds.
const float A1 @private = 55.0f;
const float C2 @private = 65.41f;
const float D_SHARP2 @private = 77.78f;
const float E2 @private = 82.41f;
const float A2 @private = 110.0f;
const float E4 @private = 329.63f;
const float G4 @private = 392.0f;
const float A4 @private = 440.0f;
const float C5 @private = 523.25f;
const float E5 @private = 659.26f;
const float G5 @private = 783.99f;
const float A5 @private = 880.0f;
const float C6 @private = 1046.5f;
const float E6 @private = 1318.51f;
const float G6 @private = 1567.98f;
const float A6 @private = 1760.0f;
const float E7 @private = 2637.02f;

// Shared envelopes.
const Adsr TICK @private = { 0.0005f, 0.008f, 0.0f, 0.008f };
const Adsr BLIP @private = { 0.001f, 0.05f, 0.3f, 0.06f };
const Adsr WARM @private = { 0.003f, 0.08f, 0.5f, 0.12f };
const Adsr BELL @private = { 0.001f, 0.15f, 0.2f, 0.15f };
const Adsr DING @private = { 0.001f, 0.3f, 0.3f, 0.35f };
const Adsr DING_LONG @private = { 0.001f, 0.4f, 0.3f, 0.5f };
const Adsr HORN @private = { 0.01f, 0.06f, 0.7f, 0.05f };
const Adsr HORN_LONG @private = { 0.02f, 0.2f, 0.7f, 0.35f };
const Adsr SWELL @private = { 0.15f, 0.4f, 0.7f, 0.5f };
const Adsr GROWL @private = { 0.02f, 0.3f, 0.7f, 0.3f };
const Adsr BEEP @private = { 0.003f, 0.05f, 0.8f, 0.03f };

// Recipe table: post effects + the layers each sound is built from (see synth::Layer).
enum Sfx : char (Post fx, Layer[] layers)
{
	ROCKET_FIRE {
		{ .reverb = 0.15f, .tail = 0.5f },
		{
			{ .wave = PINK, .len = 0.3f, .env = { 0.01f, 0.25f, 0.3f, 0.35f },
				.filter = BANDPASS, .cut0 = 2400, .cut1 = 450, .q = 1.2f, .gain = 0.9f },
			{ .wave = SINE, .len = 0.1f, .f0 = 110, .f1 = 38, .glide = 0.18f,
				.env = { 0.002f, 0.12f, 0.2f, 0.15f }, .drive = 0.5f, .gain = 1.0f },
			{ .wave = WHITE, .len = 0.03f, .env = { 0.001f, 0.03f, 0.0f, 0.03f },
				.filter = HIGHPASS, .cut0 = 3000, .gain = 0.4f },
		}
	},
	EXPLOSION {
		{ .reverb = 0.35f, .tail = 1.2f },
		{
			{ .wave = WHITE, .len = 0.2f, .env = { 0.002f, 0.35f, 0.35f, 0.6f },
				.filter = LOWPASS, .cut0 = 6000, .cut1 = 150, .q = 0.9f, .drive = 1.5f, .gain = 1.0f },
			{ .wave = SINE, .len = 0.25f, .f0 = 90, .f1 = 28, .glide = 0.5f,
				.env = { 0.003f, 0.3f, 0.5f, 0.5f }, .drive = 0.8f, .gain = 1.0f },
			{ .wave = BROWN, .len = 0.4f, .env = { 0.02f, 0.4f, 0.5f, 0.6f },
				.filter = LOWPASS, .cut0 = 500, .cut1 = 80, .gain = 0.8f },
		}
	},
	RAIL_FIRE {
		{ .reverb = 0.2f, .tail = 0.35f },
		{
			{ .wave = SAW, .len = 0.08f, .f0 = 300, .f1 = 3200, .glide = 0.1f,
				.env = { 0.002f, 0.08f, 0.3f, 0.1f }, .filter = BANDPASS, .cut0 = 1500, .cut1 = 6000,
				.q = 3, .drive = 0.6f, .gain = 0.6f },
			{ .wave = FM, .len = 0.12f, .f0 = 220, .f1 = 440, .glide = 0.1f, .fm_ratio = 1.414f,
				.fm_index = 4, .env = { 0.001f, 0.3f, 0.2f, 0.3f }, .gain = 0.6f },
			{ .wave = SINE, .len = 0.45f, .f0 = A5, .vib_rate = 30, .vib_depth = 0.008f,
				.env = { 0.01f, 0.1f, 0.6f, 0.25f }, .gain = 0.3f },
			{ .wave = SQUARE, .len = 0.45f, .f0 = A2, .vib_rate = 7, .wobble = 0.4f,
				.env = { 0.02f, 0.1f, 0.7f, 0.25f }, .filter = LOWPASS, .cut0 = 700, .q = 2, .gain = 0.3f },
		}
	},
	MG_FIRE {
		{},
		{
			{ .wave = WHITE, .len = 0.025f, .env = { 0.001f, 0.04f, 0.0f, 0.04f },
				.filter = LOWPASS, .cut0 = 6000, .cut1 = 1200, .drive = 1.0f, .gain = 0.9f },
			{ .wave = SQUARE, .len = 0.005f, .f0 = 1800, .env = { 0.0005f, 0.005f, 0.0f, 0.004f }, .gain = 0.35f },
			{ .wave = SINE, .len = 0.03f, .f0 = 180, .f1 = 60, .glide = 0.05f,
				.env = { 0.001f, 0.05f, 0.0f, 0.04f }, .gain = 0.8f },
		}
	},
	SHOTGUN_FIRE {
		{ .reverb = 0.18f, .tail = 0.5f },
		{
			{ .wave = WHITE, .len = 0.07f, .env = { 0.001f, 0.2f, 0.2f, 0.25f },
				.filter = LOWPASS, .cut0 = 7000, .cut1 = 350, .q = 0.8f, .drive = 2.0f, .gain = 1.0f },
			{ .wave = SINE, .len = 0.08f, .f0 = 130, .f1 = 40, .glide = 0.15f,
				.env = { 0.001f, 0.15f, 0.3f, 0.15f }, .drive = 1.0f, .gain = 1.0f },
			{ .wave = BROWN, .len = 0.12f, .env = { 0.002f, 0.15f, 0.3f, 0.2f },
				.filter = LOWPASS, .cut0 = 900, .gain = 0.6f },
		}
	},
	NOAMMO {
		{},
		{
			{ .wave = SQUARE, .len = 0.015f, .f0 = 140, .env = { 0.0005f, 0.02f, 0.0f, 0.02f },
				.filter = LOWPASS, .cut0 = 1200, .gain = 0.6f },
			{ .wave = WHITE, .len = 0.006f, .env = TICK, .filter = HIGHPASS, .cut0 = 2500, .gain = 0.5f },
			{ .wave = WHITE, .at = 0.05f, .len = 0.006f, .env = TICK, .filter = HIGHPASS, .cut0 = 3000, .gain = 0.35f },
		}
	},
	WEAPON_SWITCH {
		{},
		{
			{ .wave = WHITE, .len = 0.01f, .env = TICK, .filter = BANDPASS, .cut0 = 2500, .q = 2, .gain = 0.7f },
			{ .wave = FM, .len = 0.03f, .f0 = 900, .fm_ratio = 2.76f, .fm_index = 3,
				.env = { 0.001f, 0.06f, 0.0f, 0.05f }, .gain = 0.35f },
			{ .wave = WHITE, .at = 0.09f, .len = 0.012f, .env = TICK, .filter = BANDPASS, .cut0 = 1600, .q = 2, .gain = 0.8f },
			{ .wave = SINE, .at = 0.09f, .len = 0.03f, .f0 = 260, .f1 = 160,
				.env = { 0.001f, 0.04f, 0.0f, 0.03f }, .gain = 0.4f },
		}
	},
	JUMP {
		{},
		{
			// Two formants over one rising glottal saw: a short "hup".
			{ .wave = SAW, .len = 0.09f, .f0 = 170, .f1 = 230, .glide = 0.12f, .env = { 0.01f, 0.06f, 0.7f, 0.07f },
				.filter = BANDPASS, .cut0 = 600, .cut1 = 950, .q = 4, .gain = 0.8f },
			{ .wave = SAW, .len = 0.09f, .f0 = 170, .f1 = 230, .glide = 0.12f, .env = { 0.01f, 0.06f, 0.7f, 0.07f },
				.filter = BANDPASS, .cut0 = 1100, .cut1 = 1500, .q = 5, .gain = 0.5f },
			{ .wave = PINK, .len = 0.05f, .env = { 0.005f, 0.05f, 0.0f, 0.04f },
				.filter = BANDPASS, .cut0 = 1800, .q = 1, .gain = 0.25f },
		}
	},
	LAND {
		{},
		{
			{ .wave = SINE, .len = 0.04f, .f0 = 110, .f1 = 45, .glide = 0.08f,
				.env = { 0.001f, 0.08f, 0.0f, 0.08f }, .gain = 1.0f },
			{ .wave = BROWN, .len = 0.04f, .env = { 0.001f, 0.05f, 0.0f, 0.06f },
				.filter = LOWPASS, .cut0 = 500, .gain = 0.6f },
		}
	},
	FOOTSTEP {
		{},
		{
			{ .wave = WHITE, .len = 0.01f, .env = { 0.0005f, 0.015f, 0.0f, 0.015f },
				.filter = BANDPASS, .cut0 = 2200, .q = 1.5f, .gain = 0.6f },
			{ .wave = SINE, .len = 0.015f, .f0 = 160, .f1 = 90, .env = { 0.001f, 0.03f, 0.0f, 0.02f }, .gain = 0.5f },
		}
	},
	JUMPPAD {
		{ .reverb = 0.12f, .tail = 0.4f },
		{
			{ .wave = SINE, .len = 0.3f, .f0 = 140, .f1 = 620, .glide = 0.3f, .vib_rate = 18, .vib_depth = 0.06f,
				.env = { 0.005f, 0.2f, 0.5f, 0.2f }, .gain = 0.8f },
			{ .wave = TRIANGLE, .len = 0.25f, .f0 = 280, .f1 = 1240, .glide = 0.3f, .vib_rate = 18,
				.vib_depth = 0.06f, .env = { 0.005f, 0.2f, 0.3f, 0.15f }, .gain = 0.35f },
			{ .wave = PINK, .len = 0.2f, .env = { 0.02f, 0.15f, 0.3f, 0.15f },
				.filter = BANDPASS, .cut0 = 800, .cut1 = 3000, .q = 2, .gain = 0.3f },
		}
	},
	TELEPORT {
		{ .reverb = 0.25f, .tail = 0.8f, .phaser = 0.8f },
		{
			{ .wave = PINK, .len = 0.45f, .env = { 0.15f, 0.2f, 0.7f, 0.35f },
				.filter = BANDPASS, .cut0 = 300, .cut1 = 4000, .q = 1.5f, .gain = 0.8f },
			{ .wave = SINE, .len = 0.45f, .f0 = 200, .f1 = 1600, .glide = 0.6f, .vib_rate = 9, .vib_depth = 0.04f,
				.env = { 0.1f, 0.3f, 0.5f, 0.3f }, .gain = 0.35f },
			{ .wave = FM, .at = 0.2f, .len = 0.25f, .f0 = 1200, .fm_ratio = 1.5f, .fm_index = 2,
				.env = { 0.02f, 0.2f, 0.3f, 0.3f }, .gain = 0.2f },
		}
	},
	PAIN {
		{},
		{
			{ .wave = SAW, .len = 0.2f, .f0 = 320, .f1 = 170, .glide = 0.25f, .vib_rate = 32, .vib_depth = 0.05f,
				.env = { 0.01f, 0.1f, 0.7f, 0.1f }, .filter = LOWPASS, .cut0 = 2200, .cut1 = 900, .q = 2,
				.drive = 2.5f, .gain = 0.8f },
			{ .wave = SQUARE, .len = 0.2f, .f0 = 160, .f1 = 85, .glide = 0.25f, .duty = 0.3f,
				.env = { 0.01f, 0.1f, 0.6f, 0.1f }, .filter = LOWPASS, .cut0 = 800, .drive = 1.5f, .gain = 0.4f },
			{ .wave = PINK, .len = 0.15f, .env = { 0.01f, 0.1f, 0.3f, 0.1f },
				.filter = BANDPASS, .cut0 = 1200, .q = 1, .gain = 0.2f },
		}
	},
	DEATH {
		{ .reverb = 0.15f, .tail = 0.6f },
		{
			{ .wave = SAW, .len = 0.65f, .f0 = 380, .f1 = 90, .glide = 0.8f, .vib_rate = 26, .vib_depth = 0.07f,
				.env = GROWL, .filter = LOWPASS, .cut0 = 2500, .cut1 = 400, .q = 2.5f, .drive = 3, .gain = 0.8f },
			{ .wave = SAW, .len = 0.65f, .f0 = 190, .f1 = 45, .glide = 0.8f, .vib_rate = 20, .vib_depth = 0.05f,
				.env = GROWL, .filter = LOWPASS, .cut0 = 900, .cut1 = 200, .drive = 2, .gain = 0.6f },
			{ .wave = PINK, .len = 0.45f, .env = { 0.05f, 0.3f, 0.4f, 0.2f },
				.filter = BANDPASS, .cut0 = 1000, .cut1 = 300, .q = 1, .gain = 0.25f },
		}
	},
	GIB {
		{ .reverb = 0.12f, .tail = 0.4f },
		{
			{ .wave = WHITE, .len = 0.05f, .env = { 0.001f, 0.08f, 0.1f, 0.1f },
				.filter = BANDPASS, .cut0 = 900, .cut1 = 300, .q = 3, .drive = 3, .gain = 0.9f },
			{ .wave = BROWN, .len = 0.12f, .env = { 0.002f, 0.1f, 0.3f, 0.12f },
				.filter = LOWPASS, .cut0 = 700, .cut1 = 150, .drive = 2, .gain = 0.8f },
			{ .wave = SINE, .len = 0.08f, .f0 = 80, .f1 = 35, .env = { 0.001f, 0.1f, 0.2f, 0.08f }, .gain = 0.8f },
			// Squelches: short resonant noise bursts sweeping down, then up.
			{ .wave = WHITE, .at = 0.06f, .len = 0.03f, .env = { 0.001f, 0.04f, 0.0f, 0.04f },
				.filter = BANDPASS, .cut0 = 1500, .cut1 = 600, .q = 4, .drive = 2, .gain = 0.6f },
			{ .wave = WHITE, .at = 0.13f, .len = 0.03f, .env = { 0.001f, 0.04f, 0.0f, 0.05f },
				.filter = BANDPASS, .cut0 = 700, .cut1 = 1200, .q = 5, .drive = 2, .gain = 0.5f },
			{ .wave = SAW, .at = 0.03f, .len = 0.18f, .f0 = 90, .f1 = 50, .vib_rate = 40, .vib_depth = 0.2f,
				.env = { 0.01f, 0.1f, 0.4f, 0.08f }, .filter = LOWPASS, .cut0 = 500, .q = 2, .gain = 0.4f },
		}
	},
	PICKUP_WEAPON {
		{ .reverb = 0.1f, .tail = 0.3f },
		{
			{ .wave = WHITE, .len = 0.006f, .env = TICK, .filter = HIGHPASS, .cut0 = 3000, .gain = 0.4f },
			{ .wave = SQUARE, .len = 0.04f, .f0 = A5, .duty = 0.25f, .env = BLIP, .filter = LOWPASS, .cut0 = 5000, .gain = 0.45f },
			{ .wave = SQUARE, .at = 0.05f, .len = 0.04f, .f0 = E6, .duty = 0.25f, .env = BLIP,
				.filter = LOWPASS, .cut0 = 5000, .gain = 0.45f },
			{ .wave = SQUARE, .at = 0.1f, .len = 0.06f, .f0 = A6, .duty = 0.25f, .env = BLIP,
				.filter = LOWPASS, .cut0 = 6000, .gain = 0.45f },
			{ .wave = FM, .at = 0.1f, .len = 0.05f, .f0 = A6, .fm_ratio = 1.41f, .fm_index = 2,
				.env = { 0.001f, 0.1f, 0.0f, 0.1f }, .gain = 0.2f },
		}
	},
	PICKUP_HEALTH {
		{ .reverb = 0.12f, .tail = 0.4f },
		{
			{ .wave = TRIANGLE, .len = 0.06f, .f0 = C5, .env = WARM, .gain = 0.5f },
			{ .wave = TRIANGLE, .at = 0.06f, .len = 0.06f, .f0 = E5, .env = WARM, .gain = 0.5f },
			{ .wave = TRIANGLE, .at = 0.12f, .len = 0.06f, .f0 = G5, .env = WARM, .gain = 0.5f },
			{ .wave = TRIANGLE, .at = 0.18f, .len = 0.1f, .f0 = C6, .env = WARM, .gain = 0.5f },
		}
	},
	PICKUP_ARMOR {
		{ .reverb = 0.1f, .tail = 0.4f },
		{
			{ .wave = WHITE, .len = 0.008f, .env = TICK, .filter = BANDPASS, .cut0 = 3000, .q = 1.5f, .gain = 0.5f },
			{ .wave = FM, .len = 0.08f, .f0 = E4, .fm_ratio = 2, .fm_index = 2.5f, .env = BELL, .gain = 0.4f },
			{ .wave = FM, .at = 0.06f, .len = 0.08f, .f0 = A4, .fm_ratio = 2, .fm_index = 2.5f, .env = BELL, .gain = 0.4f },
			{ .wave = FM, .at = 0.12f, .len = 0.1f, .f0 = E5, .fm_ratio = 2, .fm_index = 2.5f, .env = BELL, .gain = 0.4f },
			{ .wave = SQUARE, .len = 0.15f, .f0 = 165, .env = BELL, .filter = LOWPASS, .cut0 = 800, .gain = 0.3f },
		}
	},
	PICKUP_MEGA {
		{ .reverb = 0.2f, .tail = 0.7f },
		{
			{ .wave = SAW, .len = 0.07f, .f0 = G4, .env = HORN, .filter = LOWPASS, .cut0 = 3500, .gain = 0.4f },
			{ .wave = SAW, .at = 0.08f, .len = 0.07f, .f0 = C5, .env = HORN, .filter = LOWPASS, .cut0 = 3500, .gain = 0.4f },
			{ .wave = SAW, .at = 0.16f, .len = 0.07f, .f0 = E5, .env = HORN, .filter = LOWPASS, .cut0 = 3500, .gain = 0.4f },
			{ .wave = SAW, .at = 0.24f, .len = 0.45f, .f0 = C5, .vib_rate = 5.5f, .vib_depth = 0.004f,
				.env = HORN_LONG, .filter = LOWPASS, .cut0 = 3500, .gain = 0.3f },
			{ .wave = SAW, .at = 0.24f, .len = 0.45f, .f0 = E5, .vib_rate = 5.5f, .vib_depth = 0.004f,
				.env = HORN_LONG, .filter = LOWPASS, .cut0 = 3500, .gain = 0.3f },
			{ .wave = SAW, .at = 0.24f, .len = 0.45f, .f0 = G5, .vib_rate = 5.5f, .vib_depth = 0.004f,
				.env = HORN_LONG, .filter = LOWPASS, .cut0 = 3500, .gain = 0.3f },
			{ .wave = SAW, .at = 0.24f, .len = 0.45f, .f0 = C6, .vib_rate = 5.5f, .vib_depth = 0.004f,
				.env = HORN_LONG, .filter = LOWPASS, .cut0 = 3500, .gain = 0.3f },
		}
	},
	QUAD_PICKUP {
		{ .reverb = 0.35f, .tail = 1.0f },
		{
			// A-C-D#: a deep diminished chord whose filter slowly opens, over a gong.
			{ .wave = SAW, .len = 0.8f, .f0 = A1, .vib_rate = 5, .vib_depth = 0.006f, .env = SWELL,
				.filter = LOWPASS, .cut0 = 200, .cut1 = 1400, .q = 2, .drive = 1.5f, .gain = 0.6f },
			{ .wave = SAW, .len = 0.8f, .f0 = C2, .vib_rate = 5, .vib_depth = 0.006f, .env = SWELL,
				.filter = LOWPASS, .cut0 = 200, .cut1 = 1400, .q = 2, .drive = 1.5f, .gain = 0.5f },
			{ .wave = SAW, .len = 0.8f, .f0 = D_SHARP2, .vib_rate = 5, .vib_depth = 0.006f, .env = SWELL,
				.filter = LOWPASS, .cut0 = 200, .cut1 = 1400, .q = 2, .drive = 1.5f, .gain = 0.5f },
			{ .wave = SINE, .len = 0.8f, .f0 = A1, .env = SWELL, .gain = 0.7f },
			{ .wave = FM, .len = 0.1f, .f0 = A2, .fm_ratio = 1.41f, .fm_index = 4,
				.env = { 0.002f, 0.8f, 0.0f, 0.8f }, .gain = 0.5f },
		}
	},
	QUAD_FIRE {
		{ .reverb = 0.15f, .tail = 0.4f },
		{
			{ .wave = SAW, .len = 0.2f, .f0 = 55, .f1 = 50, .vib_rate = 12, .wobble = 0.5f,
				.env = { 0.01f, 0.15f, 0.4f, 0.25f }, .filter = LOWPASS, .cut0 = 500, .q = 3, .drive = 1.5f, .gain = 0.8f },
			{ .wave = SQUARE, .len = 0.2f, .f0 = E2, .env = { 0.01f, 0.15f, 0.4f, 0.25f },
				.filter = LOWPASS, .cut0 = 400, .gain = 0.4f },
			{ .wave = FM, .len = 0.05f, .f0 = A2, .fm_ratio = 1.41f, .fm_index = 4,
				.env = { 0.002f, 0.3f, 0.0f, 0.3f }, .gain = 0.4f },
		}
	},
	HIT_CONFIRM {
		{},
		{
			{ .wave = FM, .len = 0.015f, .f0 = E7, .fm_ratio = 3.5f, .fm_index = 1.5f,
				.env = { 0.0005f, 0.1f, 0.0f, 0.1f }, .gain = 0.7f },
			{ .wave = SINE, .len = 0.01f, .f0 = 3520, .env = { 0.0005f, 0.03f, 0.0f, 0.03f }, .gain = 0.3f },
		}
	},
	FRAG {
		{ .reverb = 0.15f, .tail = 0.5f },
		{
			{ .wave = FM, .len = 0.08f, .f0 = E6, .fm_ratio = 2, .fm_index = 1.2f, .env = DING, .gain = 0.6f },
			{ .wave = SINE, .len = 0.08f, .f0 = E5, .env = DING, .gain = 0.3f },
			{ .wave = FM, .at = 0.12f, .len = 0.1f, .f0 = A6, .fm_ratio = 2, .fm_index = 1.2f, .env = DING_LONG, .gain = 0.6f },
			{ .wave = SINE, .at = 0.12f, .len = 0.1f, .f0 = A5, .env = DING_LONG, .gain = 0.3f },
		}
	},
	RESPAWN {
		{ .reverb = 0.3f, .tail = 0.8f, .phaser = 0.5f },
		{
			{ .wave = TRIANGLE, .len = 0.4f, .f0 = 220, .f1 = 880, .glide = 0.4f,
				.env = { 0.05f, 0.2f, 0.6f, 0.3f }, .gain = 0.4f },
			{ .wave = PINK, .len = 0.35f, .env = { 0.05f, 0.2f, 0.4f, 0.25f },
				.filter = BANDPASS, .cut0 = 500, .cut1 = 6000, .q = 2, .gain = 0.3f },
			{ .wave = FM, .at = 0.3f, .len = 0.15f, .f0 = A6, .fm_ratio = 1.5f, .fm_index = 1.5f,
				.env = { 0.005f, 0.2f, 0.2f, 0.25f }, .gain = 0.2f },
		}
	},
	ITEM_RESPAWN {
		{ .reverb = 0.2f, .tail = 0.5f },
		{
			{ .wave = SINE, .len = 0.1f, .f0 = 300, .f1 = 900, .glide = 0.15f,
				.env = { 0.01f, 0.1f, 0.4f, 0.15f }, .gain = 0.5f },
			{ .wave = TRIANGLE, .at = 0.1f, .len = 0.04f, .f0 = 1200, .env = { 0.002f, 0.06f, 0.2f, 0.1f }, .gain = 0.25f },
		}
	},
	MENU_MOVE {
		{},
		{
			{ .wave = SINE, .len = 0.006f, .f0 = 1400, .f1 = 1100, .env = { 0.0005f, 0.02f, 0.0f, 0.02f }, .gain = 0.5f },
			{ .wave = WHITE, .len = 0.003f, .env = TICK, .filter = BANDPASS, .cut0 = 4000, .q = 1, .gain = 0.2f },
		}
	},
	MENU_SELECT {
		{ .reverb = 0.1f, .tail = 0.3f },
		{
			{ .wave = SINE, .len = 0.03f, .f0 = A5, .env = { 0.001f, 0.04f, 0.3f, 0.04f }, .gain = 0.5f },
			{ .wave = TRIANGLE, .at = 0.04f, .len = 0.05f, .f0 = E6, .env = { 0.001f, 0.05f, 0.3f, 0.08f }, .gain = 0.5f },
			{ .wave = WHITE, .len = 0.004f, .env = TICK, .filter = BANDPASS, .cut0 = 3000, .q = 1, .gain = 0.2f },
		}
	},
	CHAT {
		{},
		{
			{ .wave = SQUARE, .len = 0.05f, .f0 = C6, .env = { 0.002f, 0.04f, 0.4f, 0.03f },
				.filter = LOWPASS, .cut0 = 3000, .gain = 0.35f },
			{ .wave = SQUARE, .at = 0.07f, .len = 0.06f, .f0 = G6, .env = { 0.002f, 0.04f, 0.4f, 0.05f },
				.filter = LOWPASS, .cut0 = 3000, .gain = 0.35f },
		}
	},
	COUNTDOWN {
		{},
		{
			{ .wave = SQUARE, .len = 0.14f, .f0 = A5, .env = BEEP, .filter = LOWPASS, .cut0 = 4000, .gain = 0.5f },
			{ .wave = SINE, .len = 0.14f, .f0 = A5, .env = BEEP, .gain = 0.3f },
		}
	},
	MATCH_END {
		{ .reverb = 0.25f, .tail = 0.8f },
		{
			{ .wave = SAW, .len = 0.1f, .f0 = C5, .env = HORN, .filter = LOWPASS, .cut0 = 3000, .gain = 0.4f },
			{ .wave = SAW, .at = 0.15f, .len = 0.07f, .f0 = C5, .env = HORN, .filter = LOWPASS, .cut0 = 3000, .gain = 0.4f },
			{ .wave = SAW, .at = 0.25f, .len = 0.1f, .f0 = G5, .env = HORN, .filter = LOWPASS, .cut0 = 3000, .gain = 0.4f },
			{ .wave = SAW, .at = 0.38f, .len = 0.5f, .f0 = C6, .vib_rate = 5.5f, .vib_depth = 0.005f,
				.env = HORN_LONG, .filter = LOWPASS, .cut0 = 3000, .gain = 0.35f },
			{ .wave = SAW, .at = 0.38f, .len = 0.5f, .f0 = G5, .env = HORN_LONG, .filter = LOWPASS, .cut0 = 3000, .gain = 0.3f },
			{ .wave = SAW, .at = 0.38f, .len = 0.5f, .f0 = E5, .env = HORN_LONG, .filter = LOWPASS, .cut0 = 3000, .gain = 0.3f },
		}
	},
}

// The loaded sound plus its aliases, used round-robin so plays can overlap.
struct Bank @private
{
	RLSound[VOICES] voices;
	int next;
}

Bank[Sfx::len] banks @local;
bool ready @local;
float master @local = 1.0f;
RLAudioStream stream @local;
Song song @local;
int quiet_chunks @local;               // silent chunks fed since the fade-out ended
float[MUSIC_CHUNK * 2] mix_buf @local;
short[MUSIC_CHUNK * 2] pcm_buf @local;

<*
 Synthesize `s` into a new normalized mono buffer at synth::RATE; free it with `a`.
 Pure: does not need the audio device.
*>
fn float[] render_sfx(Sfx s, Allocator a) => synth::render(a, s.layers, s.fx, SFX_SEED + (uint)s.ordinal);

<*
 Distance gain: 1 within NEAR_DIST, inverse-ish rolloff, faded to exactly 0 at
 HEARING_RANGE.
 @ensure return >= 0.0f && return <= 1.0f
*>
fn float attenuation(float dist)
{
	if (dist >= HEARING_RANGE) return 0.0f;
	float far = math::max(dist - NEAR_DIST, 0.0f);
	float edge = dist / HEARING_RANGE;
	return (1.0f - edge * edge) / (1.0f + ROLLOFF * far);
}

<*
 Stereo position of a source at `offset` from the listener: -1 left .. +1 right.
 Sources within NEAR_DIST drift to the center so passing through them doesn't flip ears.
 @ensure return >= -1.0f && return <= 1.0f
*>
fn float stereo_pan(Vec3 offset, Vec3 right)
{
	float dist = offset.length();
	float r = right.length();
	if (dist < 1e-4f || r < 1e-4f) return 0.0f;
	float side = offset.dot(right) / (dist * r);
	float near = math::min(dist / NEAR_DIST, 1.0f);
	return math::clamp(side * near * PAN_WIDTH, -1.0f, 1.0f);
}

fn void load(Sfx s) @local
{
	@pool()
	{
		float[] buf = render_sfx(s, tmem);
		short[] pcm = mem::temp_array(short, buf.len);
		synth::to_pcm16(buf, pcm);
		RLWave wave = {
			.frameCount = (uint)pcm.len,
			.sample_rate = synth::RATE,
			.sample_size = SAMPLE_BITS,
			.channels = MONO,
			.data = pcm.ptr,
		};
		// raylib copies the samples: our temp buffers die with the pool.
		Bank* b = &banks[s.ordinal];
		b.voices[0] = rl::load_sound_from_wave(wave);
		for (int i = 1; i < VOICES; i++) b.voices[i] = rl::load_sound_alias(b.voices[0]);
	};
}

fn void open_music() @local
{
	song.init(mem);
	// Sub-buffer = MUSIC_CHUNK frames, so each update_audio_stream fills one exactly.
	rl::set_audio_stream_buffer_size_default(MUSIC_CHUNK);
	stream = rl::load_audio_stream(synth::RATE, SAMPLE_BITS, STEREO);
	rl::set_audio_stream_buffer_size_default(0);
	stream.set_volume(MUSIC_VOLUME);
}

<*
 Synthesize and load every sound and open the music stream. Call once, after
 rl::init_audio_device(). Without a working audio device everything stays a no-op.
*>
fn void init()
{
	if (ready || !rl::is_audio_device_ready()) return;
	foreach (s : Sfx::values) load(s);
	open_music();
	rl::set_master_volume(master);
	ready = true;
}

fn void shutdown()
{
	if (!ready) return;
	rl::stop_audio_stream(stream);
	rl::unload_audio_stream(stream);
	song.free();
	foreach (&b : banks)
	{
		for (int i = 1; i < VOICES; i++) rl::unload_sound_alias(b.voices[i]);
		rl::unload_sound(b.voices[0]);
	}
	ready = false;
}

<*
 Play `s` now. `pan`: -1 left .. +1 right. `pitch` 1 = as synthesized.
*>
fn void play(Sfx s, float volume = 1.0f, float pitch = 1.0f, float pan = 0.0f)
{
	if (!ready || volume <= 0.0f) return;
	Bank* b = &banks[s.ordinal];
	RLSound snd = b.voices[b.next];
	b.next = (b.next + 1) % VOICES;
	rl::set_sound_volume(snd, math::min(volume, 1.0f));
	rl::set_sound_pitch(snd, pitch);
	rl::set_sound_pan(snd, math::clamp(pan, -1.0f, 1.0f));
	rl::play_sound(snd);
}

<*
 Play `s` at a world position heard from the listener (distance attenuation + pan).
*>
fn void play_at(Sfx s, Vec3 pos, Vec3 listener_pos, Vec3 listener_right, float volume = 1.0f)
{
	Vec3 offset = pos - listener_pos;
	float gain = attenuation(offset.length()) * volume;
	if (gain < MIN_GAIN) return;
	play(s, gain, 1.0f, stereo_pan(offset, listener_right));
}

fn void set_master(float v)
{
	master = math::clamp(v, 0.0f, 1.0f);
	if (ready) rl::set_master_volume(master);
}

// Menu music on/off, with a short fade either way.
fn void music(bool on)
{
	if (!ready) return;
	if (!on)
	{
		song.fade_to(0.0f);
		return;
	}
	if (!rl::is_audio_stream_playing(stream))
	{
		song.restart();
		quiet_chunks = 0;
		rl::play_audio_stream(stream);
	}
	song.fade_to(1.0f);
}

fn void feed() @local
{
	song.render(&mix_buf);
	synth::to_pcm16(&mix_buf, &pcm_buf);
	rl::update_audio_stream(stream, &pcm_buf, MUSIC_CHUNK);
	quiet_chunks = song.silent() ? quiet_chunks + 1 : 0;
}

// Call once per frame: refills the music stream and stops it once faded out.
fn void update()
{
	if (!ready || !rl::is_audio_stream_playing(stream)) return;
	for (int i = 0; i < STREAM_BUFFERS && stream.is_processed(); i++) feed();
	// Both buffers hold silence by now: nothing audible is cut.
	if (quiet_chunks > STREAM_BUFFERS) rl::stop_audio_stream(stream);
}
