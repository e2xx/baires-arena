// HUD: everything drawn over the 3D view while playing (status bar, weapon bar, crosshair,
// killfeed, messages, scoreboard). It only sees the Snapshot plus the events fed through
// on_event. The logic (killfeed ring, ranking, formatting) is pure and tested; the drawing
// code is a thin layer over it. Also hosts the small text/colour kit the menu shares.
module arena::hud;
import std::math, raylib6, arena::defs, arena::world, arena::snap, arena::mathx;

// ---------------------------------------------------------------- tuning (sizes at 1080p)

const float REF_HEIGHT = 1080.0f;
const int KILLFEED_LINES = 5;
const float KILLFEED_TIME = 6.0f;
const float KILLFEED_FADE = 1.0f;
const float CENTER_TIME = 2.6f;
const float ANNOUNCE_TIME = 3.0f;
const float PICKUP_TIME = 2.2f;
const float MESSAGE_FADE_IN = 0.12f;
const float MESSAGE_FADE_OUT = 0.5f;
const float HIT_TIME = 0.22f;
const float FLASH_DECAY = 1.6f;
const float FLASH_PER_POINT = 1.0f / 60.0f;
const float ARC_TIME = 1.2f;
const float ARC_SPAN = 24.0f;          // degrees each side of the source direction
const float THREAT_WINDOW = 0.3f;     // seconds between a shot/blast and our PAIN to pair them
const float SHOT_NEAR = 2.0f;         // a shot passing this close (m) counts as aimed at us
const int MAX_ARCS = 4;
const int LOW_HEALTH = 25;
const int CLOCK_WARN = 60;
const int[3] FRAG_ALERTS = { 5, 3, 1 };
const float NO_TIME = -1000.0f;

// ---------------------------------------------------------------- palette (shared with the menu)

const RLColor INK = { 242, 246, 252, 255 };
const RLColor DIM = { 165, 178, 198, 255 };
const RLColor SHADOW = { 0, 0, 0, 190 };
const RLColor PANEL = { 8, 14, 30, 175 };
const RLColor PANEL_SOLID = { 8, 14, 30, 225 };
const RLColor PANEL_LIGHT = { 30, 44, 70, 150 };
const RLColor CELESTE = { 117, 170, 219, 255 };
const RLColor SOL = { 246, 180, 14, 255 };
const RLColor DANGER = { 236, 58, 52, 255 };
const RLColor WARN = { 255, 150, 40, 255 };
const RLColor MEGA_BLUE = { 120, 185, 255, 255 };
const RLColor ARMOR_GOLD = { 250, 208, 92, 255 };
const RLColor ARMOR_RED = { 255, 120, 90, 255 };
const RLColor QUAD_BLUE = { 120, 110, 255, 255 };
const RLColor[Weapon::len] WEAPON_TINT = {
	{ 250, 210, 90, 255 },    // MACHINEGUN
	{ 255, 150, 60, 255 },    // SHOTGUN
	{ 240, 84, 60, 255 },     // ROCKET
	{ 80, 240, 170, 255 },    // RAILGUN
};

enum CrosshairStyle : char (String label)
{
	CROSS { "Cruz" },
	CROSS_DOT { "Cruz con punto" },
	DOT { "Punto" },
	CIRCLE { "Círculo" },
}

// ---------------------------------------------------------------- text kit

enum TextAlign : char
{
	LEFT,
	CENTER,
	RIGHT,
}

RLFont ui_font @private;
bool has_font @private;

<*
 Use a loaded TTF for every HUD/menu string (default: raylib's built-in Latin-1 bitmap font).
*>
fn void set_font(RLFont font)
{
	ui_font = font;
	has_font = font.texture.id != 0;
}

fn RLFont font() @private => has_font ? ui_font : rl::get_font_default();

<*
 Pixel size actually used for `size`. The built-in font is a 10 px bitmap: snapping to
 multiples of 5 (10 above 30) keeps its strokes even.
*>
fn float font_px(float size)
{
	if (has_font) return math::max(math::round(size), 8.0f);
	float step = size >= 30.0f ? 10.0f : 5.0f;
	return math::max(math::round(size / step) * step, 10.0f);
}

fn float spacing(float px) @private => has_font ? px * 0.02f : px / 10.0f;

fn float text_width(ZString s, float size)
{
	float px = font_px(size);
	return rl::measure_text_ex(font(), s, px, spacing(px)).x;
}

<*
 Draws `s` with its top at `y`; `x` is the left edge, centre or right edge per `align`.
 @require size > 0
*>
fn void text(ZString s, float x, float y, float size, RLColor color, TextAlign align = LEFT, bool shadow = true)
{
	float px = font_px(size);
	RLFont f = font();
	float sp = spacing(px);
	float w = rl::measure_text_ex(f, s, px, sp).x;
	if (align == CENTER) x -= w / 2;
	if (align == RIGHT) x -= w;
	x = math::round(x);
	y = math::round(y);
	if (shadow)
	{
		float off = math::max(1.0f, math::round(px / 14.0f));
		rl::draw_text_ex(f, s, { x + off, y + off }, px, sp, with_alpha(SHADOW, color.a / 255.0f));
	}
	rl::draw_text_ex(f, s, { x, y }, px, sp, color);
}

fn RLColor with_alpha(RLColor c, float a)
{
	c.a = (char)((float)c.a * math::clamp(a, 0.0f, 1.0f));
	return c;
}

fn RLColor rgb(Vec3 c, float alpha = 1.0f)
{
	return {
		(char)(math::clamp(c.x, 0.0f, 1.0f) * 255.0f),
		(char)(math::clamp(c.y, 0.0f, 1.0f) * 255.0f),
		(char)(math::clamp(c.z, 0.0f, 1.0f) * 255.0f),
		(char)(math::clamp(alpha, 0.0f, 1.0f) * 255.0f),
	};
}

fn RLColor player_color(char index, float alpha = 1.0f)
{
	PlayerColor pc = index < PlayerColor::len ? (PlayerColor)index : CELESTE;
	return rgb(pc.rgb, alpha);
}

fn Rect rect(float x, float y, float w, float h) => { .x = x, .y = y, .width = w, .height = h };

fn void fill(float x, float y, float w, float h, RLColor c) => rl::draw_rectangle_v({ x, y }, { w, h }, c);

fn void panel(float x, float y, float w, float h, RLColor c, float round = 0.3f) => rl::draw_rectangle_rounded(rect(x, y, w, h), round, 8, c);

// Filled triangle in any winding (raylib culls the clockwise ones).
fn void tri(RLVector2 a, RLVector2 b, RLVector2 c, RLColor color)
{
	RLVector2 ab = b - a;
	RLVector2 ac = c - a;
	if (ab.x * ac.y - ab.y * ac.x > 0)
	{
		rl::draw_triangle(a, c, b, color);
		return;
	}
	rl::draw_triangle(a, b, c, color);
}

// ---------------------------------------------------------------- pure logic: killfeed

struct KillLine
{
	char[snap::NAME_LEN] killer_buf;   // copies: the players may leave before the line fades
	char killer_len;
	char killer_color;
	char[snap::NAME_LEN] victim_buf;
	char victim_len;
	char victim_color;
	Weapon weapon;
	bool suicide;
	bool mine;        // the local player killed or died
	float age;
}

fn String KillLine.killer(&self) => (String)self.killer_buf[:self.killer_len];
fn String KillLine.victim(&self) => (String)self.victim_buf[:self.victim_len];
fn float KillLine.alpha(&self) => math::clamp((KILLFEED_TIME - self.age) / KILLFEED_FADE, 0.0f, 1.0f);

// Ring of the last KILLFEED_LINES frags; a new line pushes out the oldest.
struct KillFeed
{
	KillLine[KILLFEED_LINES] lines;
	int head;    // next slot to write
	int count;
}

fn void KillFeed.push(&self, KillLine line)
{
	self.lines[self.head] = line;
	self.head = (self.head + 1) % KILLFEED_LINES;
	if (self.count < KILLFEED_LINES) self.count++;
}

<*
 Line `i` counting from the oldest visible one.
 @require i >= 0 && i < self.count
*>
fn KillLine* KillFeed.line(&self, int i)
{
	return &self.lines[(self.head - self.count + i + KILLFEED_LINES) % KILLFEED_LINES];
}

fn void KillFeed.tick(&self, float dt)
{
	for (int i = 0; i < self.count; i++) self.line(i).age += dt;
	// Lines expire in push order, so the expired ones are always the oldest.
	while (self.count > 0 && self.line(0).age >= KILLFEED_TIME) self.count--;
}

fn KillLine kill_line(GameEvent* e, Snapshot* s, int me)
{
	KillLine l = { .weapon = e.c < Weapon::len ? (Weapon)e.c : MACHINEGUN };
	l.suicide = e.b == defs::NO_PLAYER || e.b == e.a;
	l.mine = me >= 0 && (e.a == me || e.b == me);
	if (e.a < defs::MAX_PLAYERS)
	{
		PlayerSnap* v = &s.players[e.a];
		l.victim_len = (char)copy_text(&l.victim_buf, v.name());
		l.victim_color = v.color;
	}
	if (!l.suicide && e.b < defs::MAX_PLAYERS)
	{
		PlayerSnap* k = &s.players[e.b];
		l.killer_len = (char)copy_text(&l.killer_buf, k.name());
		l.killer_color = k.color;
	}
	return l;
}

// ---------------------------------------------------------------- pure logic: ranking & text

struct ScoreRow
{
	char slot;
	int rank;      // 1-based; ties share it (1, 2, 2, 4)
	short frags;
	short deaths;
}

fn bool ranks_before(ScoreRow* a, ScoreRow* b) @local
{
	if (a.frags != b.frags) return a.frags > b.frags;
	if (a.deaths != b.deaths) return a.deaths < b.deaths;
	return a.slot < b.slot;
}

<*
 Active players sorted by frags (then fewer deaths, then slot). Returns how many rows.
*>
fn int rank_players(Snapshot* s, ScoreRow[] out)
{
	int n;
	for (int i = 0; i < defs::MAX_PLAYERS; i++)
	{
		PlayerSnap* p = &s.players[i];
		if (!p.active || (usz)n >= out.len) continue;
		out[n++] = { .slot = (char)i, .frags = p.frags, .deaths = p.deaths };
	}
	for (int i = 1; i < n; i++)
	{
		ScoreRow r = out[i];
		int j = i - 1;
		while (j >= 0 && ranks_before(&r, &out[j]))
		{
			out[j + 1] = out[j];
			j--;
		}
		out[j + 1] = r;
	}
	for (int i = 0; i < n; i++)
	{
		out[i].rank = i > 0 && out[i].frags == out[i - 1].frags ? out[i - 1].rank : i + 1;
	}
	return n;
}

fn ScoreRow* find_row(ScoreRow[] rows, int slot)
{
	foreach (&r : rows)
	{
		if (r.slot == slot) return r;
	}
	return null;
}

fn bool is_tied(ScoreRow[] rows, int rank)
{
	int n;
	foreach (r : rows)
	{
		if (r.rank == rank) n++;
	}
	return n > 1;
}

<*
 "m:ss" for a countdown, rounding up (so 0:00 only shows when time is really over).
*>
fn String fmt_clock(float seconds)
{
	int total = (int)math::ceil(math::max(seconds, 0.0f));
	return string::tformat("%d:%02d", total / 60, total % 60);
}

<*
 @require n > 0
*>
fn String ordinal(int n) => string::tformat("%dº", n);

// Second line of "Fragueaste a Colo": "2º con 7" / "Empatado 1º con 7".
fn String frag_sub(int rank, bool tied, int frags)
{
	if (tied) return string::tformat("Empatado %dº con %d", rank, frags);
	return string::tformat("%dº con %d", rank, frags);
}

<*
 Copies as much of `src` as fits without cutting a UTF-8 sequence. Returns the length.
*>
fn usz copy_text(char[] dst, String src)
{
	usz n = src.len < dst.len ? src.len : dst.len;
	if (n < src.len)
	{
		while (n > 0 && (src[n] & 0xC0) == 0x80) n--;
	}
	dst[:n] = src[:n];
	return n;
}

<*
 Direction of `src` seen from `from` looking along `yaw`: 0 = ahead, +PI/2 = right.
*>
fn float screen_angle(Vec3 from, Vec3 src, float yaw)
{
	Vec3 d = src - from;
	return math::atan2(d.dot(mathx::flat_right(yaw)), d.dot(mathx::flat_forward(yaw)));
}

<*
 "Quedan N frags" warning due for the leader, or 0. `last` is the smallest one already shown
 this match (0 = none), so each threshold fires once even if frags go back down.
*>
fn int frags_alert(int fraglimit, int leader, int last)
{
	if (fraglimit <= 0) return 0;
	int left = fraglimit - leader;
	foreach (t : FRAG_ALERTS)
	{
		if (left == t && (last == 0 || t < last)) return t;
	}
	return 0;
}

// Distance from `p` to the ray starting at `o` along `dir` (any length).
fn float ray_distance(Vec3 o, Vec3 dir, Vec3 p) @local
{
	float len2 = dir.dot(dir);
	if (len2 < 1e-6f) return (p - o).length();
	float t = math::max((p - o).dot(dir) / len2, 0.0f);
	return (o + dir * t - p).length();
}

// ---------------------------------------------------------------- state

struct Message @private
{
	char[96] buf;
	usz len;
	usz accent_from;    // bytes [accent_from..] are drawn in `accent` (e.g. a player name)
	char[64] sub_buf;
	usz sub_len;
	RLColor color;
	RLColor accent;
	float left;
	float total;
}

fn void Message.set(&self, String main, String sub, float seconds, RLColor color, String accented = "", RLColor accent = INK)
{
	char[160] joined;
	usz n = copy_text(&joined, main);
	n += copy_text(joined[n..], accented);
	self.len = copy_text(&self.buf, (String)joined[:n]);
	self.accent_from = main.len < self.len ? main.len : self.len;
	self.sub_len = copy_text(&self.sub_buf, sub);
	self.color = color;
	self.accent = accent;
	self.left = seconds;
	self.total = seconds;
}

fn String Message.main(&self) => (String)self.buf[:self.len];
fn String Message.sub(&self) => (String)self.sub_buf[:self.sub_len];

fn float Message.alpha(&self)
{
	if (self.left <= 0) return 0;
	float shown = self.total - self.left;
	return math::min(math::min(shown / MESSAGE_FADE_IN, self.left / MESSAGE_FADE_OUT), 1.0f);
}

struct DamageArc @private
{
	Vec3 src;      // world position of what hurt us: the arc follows it as we turn
	float left;
}

struct HudState @private
{
	float clock;
	CrosshairStyle crosshair;
	KillFeed feed;
	Message center;     // frag messages and center_print
	Message announce;   // "Quedan 3 frags"
	Message pickup;
	float hit_left;
	int hit_damage;
	float flash;
	DamageArc[MAX_ARCS] arcs;
	float pain_at;      // clock of a PAIN still waiting for its source
	float threat_at;    // clock of the last shot/blast that came close
	Vec3 threat_pos;
	short last_health;
	bool last_alive;
	int last_alert;
	float match_end_at;
}

HudState state @private;

fn void init()
{
	state = {};
	reset();
}

fn void reset()
{
	CrosshairStyle style = state.crosshair;
	state = {};
	state.crosshair = style;
	state.pain_at = NO_TIME;
	state.threat_at = NO_TIME;
	state.match_end_at = NO_TIME;
}

fn void set_crosshair(int style)
{
	state.crosshair = (CrosshairStyle)math::clamp(style, 0, (int)CrosshairStyle::len - 1);
}

<*
 @require seconds > 0
*>
fn void center_print(String text, float seconds)
{
	state.center.set(text, "", seconds, INK);
}

// ---------------------------------------------------------------- events

fn int local_slot(Snapshot* s) @local => s.local.slot == defs::NO_PLAYER ? -1 : (int)s.local.slot;

fn Vec3 my_center(Snapshot* s) @local => s.local.ps.origin + (Vec3){ 0, defs::PLAYER_MAXS.y * 0.5f, 0 };

fn void on_event(GameEvent* e, Snapshot* s)
{
	int me = local_slot(s);
	switch (e.kind)
	{
		case DEATH:
			on_death(e, s, me);
		case PAIN:
			if (e.a == me) on_pain(s);
		case HIT_CONFIRM:
			if (e.a == me) on_hit(e.b);
		case PICKUP:
			if (e.a == me && e.b < ItemKind::len) on_pickup((ItemKind)e.b);
		case FIRE:
			on_fire(e, s, me);
		case EXPLOSION:
			if (me >= 0 && (e.pos - my_center(s)).length() < Weapon.ROCKET.splash_radius + 1.0f) note_threat(s, e.pos);
		case RESPAWN:
			if (e.a == me) clear_damage();
		case MATCH_END:
			state.match_end_at = state.clock;
			state.last_alert = 0;
		default:
	}
}

fn void on_death(GameEvent* e, Snapshot* s, int me) @local
{
	KillLine line = kill_line(e, s, me);
	state.feed.push(line);
	check_alert(s);
	if (me < 0) return;

	if (e.a == me)
	{
		state.flash = 1.0f;
		if (line.suicide)
		{
			state.center.set("Te suicidaste", "", CENTER_TIME, DANGER);
			return;
		}
		state.center.set("Te fragueó ", "", CENTER_TIME, INK, line.killer(), player_color(line.killer_color));
		return;
	}
	if (e.b != me || line.suicide) return;

	ScoreRow[defs::MAX_PLAYERS] rows;
	int n = rank_players(s, &rows);
	ScoreRow* mine = find_row(rows[:n], me);
	String sub = mine ? frag_sub(mine.rank, is_tied(rows[:n], mine.rank), mine.frags) : "";
	state.center.set("Fragueaste a ", sub, CENTER_TIME, INK, line.victim(), player_color(line.victim_color));
}

fn void check_alert(Snapshot* s) @local
{
	int leader = int::min;
	foreach (&p : s.players)
	{
		if (p.active) leader = math::max(leader, (int)p.frags);
	}
	int alert = frags_alert(s.fraglimit, leader, state.last_alert);
	if (!alert) return;
	state.last_alert = alert;
	String msg = alert == 1 ? "¡Queda 1 frag!" : string::tformat("Quedan %d frags", alert);
	state.announce.set(msg, "", ANNOUNCE_TIME, SOL);
}

fn void on_pain(Snapshot* s) @local
{
	state.pain_at = state.clock;
	if (state.clock - state.threat_at <= THREAT_WINDOW) add_arc(s, state.threat_pos);
}

fn void on_fire(GameEvent* e, Snapshot* s, int me) @local
{
	if (me < 0 || e.a == me || e.a >= defs::MAX_PLAYERS) return;
	if (ray_distance(e.pos, e.pos2 - e.pos, my_center(s)) > SHOT_NEAR) return;
	note_threat(s, e.pos);
}

fn void note_threat(Snapshot* s, Vec3 pos) @local
{
	state.threat_pos = pos;
	state.threat_at = state.clock;
	if (state.clock - state.pain_at <= THREAT_WINDOW) add_arc(s, pos);
}

fn void add_arc(Snapshot* s, Vec3 src) @local
{
	state.pain_at = NO_TIME;
	state.threat_at = NO_TIME;
	Vec3 d = src - my_center(s);
	if (d.x * d.x + d.z * d.z < 0.25f) return;   // right under us (own rocket jump): no direction
	int slot;
	foreach (i, &a : state.arcs)
	{
		if (a.left < state.arcs[slot].left) slot = (int)i;
	}
	state.arcs[slot] = { src, ARC_TIME };
}

fn void on_hit(int damage) @local
{
	state.hit_damage = state.hit_left > 0 ? state.hit_damage + damage : damage;
	state.hit_left = HIT_TIME;
}

fn void on_pickup(ItemKind kind) @local
{
	RLColor c;
	switch (kind.cls)
	{
		case HEALTH: c = kind == MEGA ? MEGA_BLUE : (RLColor){ 120, 235, 130, 255 };
		case ARMOR: c = kind == ARMOR_RED ? ARMOR_RED : ARMOR_GOLD;
		case WEAPON: c = WEAPON_TINT[kind.weapon.ordinal];
		case AMMO: c = DIM;
		case POWERUP: c = QUAD_BLUE;
	}
	state.pickup.set(kind.name, "", PICKUP_TIME, c);
}

fn void clear_damage() @local
{
	state.flash = 0;
	state.arcs = {};
	state.pain_at = NO_TIME;
}

// ---------------------------------------------------------------- frame update

fn void tick(Snapshot* s, float dt) @local
{
	state.clock += dt;
	state.feed.tick(dt);
	state.center.left -= dt;
	state.announce.left -= dt;
	state.pickup.left -= dt;
	state.hit_left = math::max(state.hit_left - dt, 0.0f);
	state.flash = math::max(state.flash - dt * FLASH_DECAY, 0.0f);
	foreach (&a : state.arcs) a.left = math::max(a.left - dt, 0.0f);

	// Health drops flash the screen; 1-point drops are the >100 decay, not damage.
	PlayerSnap* me = s.me();
	bool alive = me && me.alive();
	int drop = state.last_health - s.local.health;
	if (alive && state.last_alive && drop > 1) state.flash = math::min(state.flash + drop * FLASH_PER_POINT + 0.15f, 1.0f);
	state.last_health = s.local.health;
	state.last_alive = alive;
}

// ---------------------------------------------------------------- drawing

struct View @local
{
	float w;
	float h;
	float k;       // scale relative to 1080p
	ScoreRow[defs::MAX_PLAYERS] rows;
	int row_count;
	int me;
}

fn void draw(Snapshot* s, int screen_w, int screen_h, float dt, bool show_scores) => @pool()
{
	tick(s, dt);
	View v = { .w = screen_w, .h = screen_h, .k = screen_h / REF_HEIGHT, .me = local_slot(s) };
	v.row_count = rank_players(s, &v.rows);

	if (s.phase == INTERMISSION)
	{
		draw_intermission(s, &v);
		return;
	}

	PlayerSnap* me = s.me();
	draw_vignette(s, &v);
	if (me && me.alive())
	{
		draw_arcs(s, &v);
		draw_crosshair(&v);
		draw_hit_marker(&v);
	}
	if (me)
	{
		draw_status(s, &v);
		draw_weapon_bar(s, &v);
		draw_quad(s, &v);
	}
	if (me && !me.alive()) draw_respawn(s, &v);

	draw_match_info(s, &v);
	draw_killfeed(&v);
	if (!show_scores) draw_messages(&v);
	if (show_scores) draw_scoreboard(s, &v, 150 * v.k);
}

// One coloured piece of a line of text.
struct Seg @local
{
	ZString s;
	RLColor c;
}

fn float segs_width(Seg[] segs, float size) @local
{
	float w;
	foreach (sg : segs) w += text_width(sg.s, size);
	return w;
}

fn void draw_segs(Seg[] segs, float x, float y, float size) @local
{
	foreach (sg : segs)
	{
		text(sg.s, x, y, size, sg.c);
		x += text_width(sg.s, size);
	}
}

// ---- screen tints

fn void edge_glow(View* v, RLColor c, float a) @local
{
	if (a <= 0.01f) return;
	float band = v.h * 0.2f;
	RLColor on = with_alpha(c, a);
	RLColor off = with_alpha(c, 0);
	int w = (int)v.w;
	int h = (int)v.h;
	int b = (int)band;
	rl::draw_rectangle_gradient_v(0, 0, w, b, on, off);
	rl::draw_rectangle_gradient_v(0, h - b, w, b, off, on);
	rl::draw_rectangle_gradient_h(0, 0, b, h, on, off);
	rl::draw_rectangle_gradient_h(w - b, 0, b, h, off, on);
}

fn void draw_vignette(Snapshot* s, View* v) @local
{
	float pulse = 0.5f + 0.5f * math::sin(state.clock * 5.0f);
	if (s.local.quad_time > 0) edge_glow(v, QUAD_BLUE, 0.25f + 0.1f * pulse);
	PlayerSnap* me = s.me();
	bool low = me && me.alive() && s.local.health < LOW_HEALTH;
	float a = state.flash * 0.6f;
	if (low) a = math::max(a, 0.12f + 0.12f * pulse);
	edge_glow(v, DANGER, a);
}

fn void draw_arcs(Snapshot* s, View* v) @local
{
	RLVector2 c = { v.w / 2, v.h / 2 };
	float r = v.h * 0.17f;
	foreach (&a : state.arcs)
	{
		if (a.left <= 0) continue;
		float deg = screen_angle(my_center(s), a.src, s.local.ps.yaw) * rl::RAD2DEG - 90.0f;
		float alpha = a.left / ARC_TIME;
		rl::draw_ring(c, r, r + 12 * v.k, deg - ARC_SPAN, deg + ARC_SPAN, 24, with_alpha(DANGER, alpha * 0.9f));
		rl::draw_ring(c, r - 4 * v.k, r, deg - ARC_SPAN * 0.6f, deg + ARC_SPAN * 0.6f, 16, with_alpha(INK, alpha * 0.5f));
	}
}

// ---- crosshair and hit marker

fn void outlined_bar(float x, float y, float w, float h, float k) @local
{
	float o = math::max(1.0f, k);
	fill(x - o, y - o, w + 2 * o, h + 2 * o, SHADOW);
	fill(x, y, w, h, INK);
}

fn void draw_crosshair(View* v) @local
{
	float k = v.k;
	float cx = math::round(v.w / 2);
	float cy = math::round(v.h / 2);
	float t = math::max(2.0f, math::round(2 * k));
	float gap = 5 * k;
	float len = 9 * k;
	switch (state.crosshair)
	{
		case CROSS:
		case CROSS_DOT:
			outlined_bar(cx - t / 2, cy - gap - len, t, len, k);
			outlined_bar(cx - t / 2, cy + gap, t, len, k);
			outlined_bar(cx - gap - len, cy - t / 2, len, t, k);
			outlined_bar(cx + gap, cy - t / 2, len, t, k);
			if (state.crosshair == CROSS_DOT) outlined_bar(cx - t / 2, cy - t / 2, t, t, k);
		case DOT:
			rl::draw_circle_v({ cx, cy }, 4 * k + 1, SHADOW);
			rl::draw_circle_v({ cx, cy }, 3 * k, INK);
		case CIRCLE:
			rl::draw_ring({ cx, cy }, 10 * k - 1, 12 * k + 1, 0, 360, 32, SHADOW);
			rl::draw_ring({ cx, cy }, 10 * k, 12 * k, 0, 360, 32, INK);
			outlined_bar(cx - t / 2, cy - t / 2, t, t, k);
	}
}

fn void draw_hit_marker(View* v) @local
{
	if (state.hit_left <= 0) return;
	float k = v.k;
	float a = state.hit_left / HIT_TIME;
	float heavy = math::min(state.hit_damage / 100.0f, 1.5f);
	float gap = 7 * k;
	float len = (7 + 10 * heavy) * k;
	float thick = (2 + heavy) * k;
	RLColor c = state.hit_damage >= 100 ? DANGER : INK;
	RLVector2 ctr = { v.w / 2, v.h / 2 };
	RLVector2[4] dirs = { { 1, 1 }, { -1, 1 }, { 1, -1 }, { -1, -1 } };
	foreach (d : dirs)
	{
		RLVector2 n = d * 0.7071f;
		rl::draw_line_ex(ctr + n * gap, ctr + n * (gap + len), thick + 2 * k, with_alpha(SHADOW, a));
		rl::draw_line_ex(ctr + n * gap, ctr + n * (gap + len), thick, with_alpha(c, a));
	}
}

// ---- icons (primitives only)

fn void icon_cross(float cx, float cy, float s, RLColor c) @local
{
	float t = s * 0.34f;
	float o = math::max(2.0f, s * 0.06f);
	fill(cx - t / 2 - o, cy - s / 2 - o, t + 2 * o, s + 2 * o, SHADOW);
	fill(cx - s / 2 - o, cy - t / 2 - o, s + 2 * o, t + 2 * o, SHADOW);
	fill(cx - t / 2, cy - s / 2, t, s, c);
	fill(cx - s / 2, cy - t / 2, s, t, c);
}

fn void shield_shape(float cx, float cy, float s, RLColor c) @local
{
	float w = s * 0.82f;
	float top = cy - s / 2;
	float mid = top + s * 0.42f;
	fill(cx - w / 2, top, w, mid - top, c);
	rl::draw_triangle({ cx - w / 2, mid }, { cx, cy + s / 2 }, { cx + w / 2, mid }, c);
}

fn void icon_shield(float cx, float cy, float s, RLColor c) @local
{
	shield_shape(cx, cy + s * 0.02f, s * 1.14f, SHADOW);
	shield_shape(cx, cy, s, c);
	shield_shape(cx, cy - s * 0.02f, s * 0.6f, with_alpha(INK, 0.35f));
}

fn void icon_bullet(float cx, float cy, float s, RLColor c) @local
{
	float w = s * 0.36f;
	float body_top = cy - s * 0.12f;
	float o = math::max(2.0f, s * 0.05f);
	fill(cx - w / 2 - o, body_top - o, w + 2 * o, s * 0.62f + 2 * o, SHADOW);
	rl::draw_circle_v({ cx, body_top }, w / 2 + o, SHADOW);
	rl::draw_circle_v({ cx, body_top }, w / 2, { 230, 140, 80, 255 });
	fill(cx - w / 2, body_top - s * 0.12f, w, s * 0.12f, { 230, 140, 80, 255 });
	fill(cx - w / 2, body_top, w, s * 0.55f, c);
	fill(cx - w / 2 - s * 0.04f, cy + s * 0.38f, w + s * 0.08f, s * 0.08f, c);
}

<*
 Weapon silhouette centred on (cx, cy), `s` wide.
*>
fn void icon_weapon(Weapon w, float cx, float cy, float s, RLColor body, RLColor accent) @local
{
	switch (w)
	{
		case MACHINEGUN:
			fill(cx - 0.5f * s, cy - 0.08f * s, 0.16f * s, 0.2f * s, body);
			fill(cx - 0.36f * s, cy - 0.12f * s, 0.5f * s, 0.2f * s, body);
			fill(cx + 0.14f * s, cy - 0.07f * s, 0.36f * s, 0.07f * s, body);
			fill(cx - 0.08f * s, cy + 0.08f * s, 0.12f * s, 0.24f * s, accent);
		case SHOTGUN:
			fill(cx - 0.5f * s, cy - 0.06f * s, 0.28f * s, 0.18f * s, body);
			fill(cx - 0.24f * s, cy - 0.1f * s, 0.74f * s, 0.06f * s, body);
			fill(cx - 0.24f * s, cy - 0.02f * s, 0.74f * s, 0.06f * s, body);
			fill(cx + 0.06f * s, cy + 0.04f * s, 0.24f * s, 0.08f * s, accent);
		case ROCKET:
			fill(cx - 0.46f * s, cy - 0.12f * s, 0.8f * s, 0.24f * s, body);
			rl::draw_triangle({ cx + 0.34f * s, cy - 0.12f * s }, { cx + 0.34f * s, cy + 0.12f * s }, { cx + 0.5f * s, cy }, accent);
			fill(cx - 0.1f * s, cy + 0.12f * s, 0.1f * s, 0.18f * s, body);
			fill(cx - 0.3f * s, cy - 0.2f * s, 0.16f * s, 0.08f * s, accent);
		case RAILGUN:
			fill(cx - 0.5f * s, cy - 0.04f * s, s, 0.08f * s, body);
			fill(cx - 0.46f * s, cy - 0.12f * s, 0.34f * s, 0.24f * s, body);
			for (int i = 0; i < 4; i++) fill(cx - 0.06f * s + i * 0.12f * s, cy - 0.09f * s, 0.05f * s, 0.18f * s, accent);
	}
}

// ---- status bar, weapon bar, quad

fn RLColor health_color(int hp)
{
	if (hp < LOW_HEALTH) return DANGER;
	if (hp > defs::MAX_HEALTH) return MEGA_BLUE;
	return INK;
}

fn RLColor armor_color(int armor)
{
	if (armor <= 0) return with_alpha(DIM, 0.6f);
	if (armor > defs::MAX_HEALTH) return ARMOR_RED;
	return ARMOR_GOLD;
}

fn RLColor ammo_color(Weapon w, int ammo)
{
	if (ammo <= 0) return DANGER;
	if (ammo <= w.pickup_ammo / 2) return WARN;
	return INK;
}

fn void draw_status(Snapshot* s, View* v) @local
{
	float k = v.k;
	float base = v.h - 28 * k;
	rl::draw_rectangle_gradient_v(0, (int)(v.h - 190 * k), (int)v.w, (int)(190 * k), { 0, 0, 0, 0 }, { 0, 0, 0, 130 });

	float num = 80 * k;
	float icon = 54 * k;
	float y = base - font_px(num);
	float icon_y = base - font_px(num) / 2 - 2 * k;

	int hp = math::max((int)s.local.health, 0);
	RLColor hc = health_color(hp);
	if (hp < LOW_HEALTH) hc = with_alpha(hc, 0.65f + 0.35f * math::sin(state.clock * 9.0f));
	icon_cross(52 * k + icon / 2, icon_y, icon, hc);
	text(string::tformat_zstr("%d", hp), 66 * k + icon, y, num, hc);

	float ax = 330 * k;
	int armor = s.local.armor;
	RLColor ac = armor_color(armor);
	icon_shield(ax + icon / 2, icon_y, icon, ac);
	text(string::tformat_zstr("%d", armor), ax + icon + 14 * k, y, num, ac);

	Weapon w = s.local.weapon;
	int ammo = s.local.ammo[w.ordinal];
	RLColor mc = ammo_color(w, ammo);
	float right = v.w - 52 * k;
	icon_bullet(right - icon / 2, icon_y, icon, mc);
	text(string::tformat_zstr("%d", ammo), right - icon - 14 * k, y, num, mc, RIGHT);
}

fn void draw_weapon_bar(Snapshot* s, View* v) @local
{
	float k = v.k;
	float slot_w = 92 * k;
	float slot_h = 60 * k;
	float gap = 8 * k;
	float total = Weapon::len * slot_w + (Weapon::len - 1) * gap;
	float x0 = (v.w - total) / 2;
	float y = v.h - slot_h - 24 * k;
	foreach (i, w : Weapon::values)
	{
		float x = x0 + i * (slot_w + gap);
		bool owned = s.local.owned[i];
		bool current = w == s.local.weapon;
		RLColor tint = WEAPON_TINT[i];
		float sy = current ? y - 8 * k : y;
		float a = owned ? 1.0f : 0.28f;
		panel(x, sy, slot_w, slot_h, current ? with_alpha(tint, 0.3f) : with_alpha(PANEL, 0.8f), 0.25f);
		if (current) rl::draw_rectangle_rounded_lines_ex(rect(x, sy, slot_w, slot_h), 0.25f, 8, 2 * k, tint);
		text(string::tformat_zstr("%d", i + 1), x + 7 * k, sy + 5 * k, 15 * k, with_alpha(current ? tint : DIM, a));
		icon_weapon(w, x + slot_w / 2, sy + slot_h * 0.45f, slot_w * 0.62f, with_alpha(INK, a * 0.92f), with_alpha(tint, a));
		if (!owned) continue;
		int ammo = s.local.ammo[i];
		text(string::tformat_zstr("%d", ammo), x + slot_w - 6 * k, sy + slot_h - 20 * k, 15 * k, ammo_color(w, ammo), RIGHT);
	}
}

fn void draw_quad(Snapshot* s, View* v) @local
{
	if (s.local.quad_time <= 0) return;
	float k = v.k;
	float w = 190 * k;
	float h = 64 * k;
	float x = v.w - w - 40 * k;
	float y = v.h - 230 * k;
	float pulse = 0.5f + 0.5f * math::sin(state.clock * 6.0f);
	panel(x, y, w, h, with_alpha(QUAD_BLUE, 0.35f + 0.2f * pulse));
	rl::draw_rectangle_rounded_lines_ex(rect(x, y, w, h), 0.3f, 8, 2 * k, QUAD_BLUE);
	text("QUAD", x + 16 * k, y + 14 * k, 36 * k, INK);
	text(string::tformat_zstr("%d", (int)math::ceil(s.local.quad_time)), x + w - 16 * k, y + 14 * k, 36 * k, INK, RIGHT);
}

fn void draw_respawn(Snapshot* s, View* v) @local
{
	float k = v.k;
	fill(0, 0, v.w, v.h, { 60, 0, 0, 70 });
	float y = v.h * 0.6f;
	float t = s.local.respawn_in;
	if (t > 0)
	{
		text(string::tformat_zstr("Reaparecés en %.1f", t), v.w / 2, y, 40 * k, DIM, CENTER);
		return;
	}
	float pulse = 0.65f + 0.35f * math::sin(state.clock * 4.0f);
	text("Hacé click para reaparecer", v.w / 2, y, 40 * k, with_alpha(INK, pulse), CENTER);
}

// ---- match info: clock, own position, leader

fn void score_box(float x, float y, float w, float h, float k, ZString label, int frags, RLColor c) @local
{
	panel(x, y, w, h, with_alpha(c, 0.5f), 0.25f);
	rl::draw_rectangle_rounded_lines_ex(rect(x, y, w, h), 0.25f, 8, 2 * k, with_alpha(c, 0.9f));
	text(label, x + 10 * k, y + (h - font_px(20 * k)) / 2, 20 * k, INK);
	text(string::tformat_zstr("%d", frags), x + w - 10 * k, y + (h - font_px(30 * k)) / 2, 30 * k, INK, RIGHT);
}

fn void draw_match_info(Snapshot* s, View* v) @local
{
	float k = v.k;
	float cx = v.w / 2;
	float y = 14 * k;
	if (s.time_left > 0)
	{
		int secs = (int)math::ceil(s.time_left);
		RLColor c = secs <= CLOCK_WARN ? with_alpha(DANGER, 0.75f + 0.25f * math::sin(state.clock * 6.0f)) : INK;
		ZString clock = string::tformat_zstr("%s", fmt_clock(s.time_left));
		float w = math::max(text_width(clock, 44 * k) + 36 * k, 150 * k);
		panel(cx - w / 2, y, w, 56 * k, PANEL, 0.4f);
		text(clock, cx, y + (56 * k - font_px(44 * k)) / 2, 44 * k, c, CENTER);
		y += 64 * k;
	}
	if (v.row_count == 0) return;

	float bw = 130 * k;
	float bh = 40 * k;
	ScoreRow* mine = v.me >= 0 ? find_row(v.rows[:v.row_count], v.me) : null;
	if (!mine)
	{
		ScoreRow* top = &v.rows[0];
		score_box(cx - bw / 2, y, bw, bh, k, "1º", top.frags, player_color(s.players[top.slot].color));
		return;
	}
	// Ours on the left; on the right the leader, or the runner-up when we lead.
	ScoreRow* other = mine == &v.rows[0] ? (v.row_count > 1 ? &v.rows[1] : null) : &v.rows[0];
	float left = other ? cx - bw - 4 * k : cx - bw / 2;
	ZString pos = string::tformat_zstr("%s", ordinal(mine.rank));
	score_box(left, y, bw, bh, k, pos, mine.frags, player_color(s.players[v.me].color));
	if (other)
	{
		ZString lbl = string::tformat_zstr("%s", ordinal(other.rank));
		score_box(cx + 4 * k, y, bw, bh, k, lbl, other.frags, player_color(s.players[other.slot].color));
	}
	if (s.fraglimit > 0) text(string::tformat_zstr("a %d frags", s.fraglimit), cx, y + bh + 6 * k, 15 * k, DIM, CENTER);
}

// ---- killfeed and messages

fn void draw_killfeed(View* v) @local
{
	float k = v.k;
	float size = 20 * k;
	float line_h = font_px(size) + 14 * k;
	float right = v.w - 20 * k;
	float y = 16 * k;
	for (int i = 0; i < state.feed.count; i++)
	{
		KillLine* l = state.feed.line(i);
		float a = l.alpha();
		ZString tag = string::tformat_zstr(" [%s] ", l.weapon.name);
		Seg[3] segs;
		if (l.suicide)
		{
			segs = { { tag, with_alpha(DIM, a) }, { l.victim().zstr_tcopy(), player_color(l.victim_color, a) }, { " se suicidó", with_alpha(DIM, a) } };
		}
		else
		{
			segs = { { l.killer().zstr_tcopy(), player_color(l.killer_color, a) }, { tag, with_alpha(DIM, a) }, { l.victim().zstr_tcopy(), player_color(l.victim_color, a) } };
		}
		float w = segs_width(&segs, size);
		float pad = 10 * k;
		RLColor bg = l.mine ? with_alpha(CELESTE, 0.32f * a) : with_alpha(PANEL, 0.75f * a);
		panel(right - w - pad, y, w + 2 * pad, line_h - 4 * k, bg, 0.3f);
		draw_segs(&segs, right - w, y + (line_h - 4 * k - font_px(size)) / 2, size);
		y += line_h;
	}
}

fn void draw_message(Message* m, float cx, float y, float size, float sub_size) @local
{
	float a = m.alpha();
	if (a <= 0) return;
	ZString head = m.main()[:m.accent_from].zstr_tcopy();
	ZString tail = m.main()[m.accent_from..].zstr_tcopy();
	Seg[2] segs = { { head, with_alpha(m.color, a) }, { tail, with_alpha(m.accent, a) } };
	draw_segs(&segs, cx - segs_width(&segs, size) / 2, y, size);
	if (m.sub_len) text(m.sub().zstr_tcopy(), cx, y + font_px(size) + 10, sub_size, with_alpha(CELESTE, a), CENTER);
}

fn void draw_messages(View* v) @local
{
	float k = v.k;
	float cx = v.w / 2;
	draw_message(&state.announce, cx, v.h * 0.2f, 36 * k, 24 * k);
	draw_message(&state.center, cx, v.h * 0.3f, 50 * k, 30 * k);
	draw_message(&state.pickup, cx, v.h - 170 * k, 30 * k, 20 * k);
}

// ---- scoreboard and intermission

fn RLColor ping_color(int ms)
{
	if (ms < 50) return { 120, 230, 130, 255 };
	if (ms < 120) return ARMOR_GOLD;
	return DANGER;
}

fn void draw_scoreboard(Snapshot* s, View* v, float top) @local
{
	float k = v.k;
	float w = math::min(900 * k, v.w - 40 * k);
	float x = (v.w - w) / 2;
	float row_h = 44 * k;
	float head_h = 96 * k;
	float h = head_h + v.row_count * row_h + 20 * k;
	panel(x, top, w, h, PANEL_SOLID, 0.06f);
	fill(x, top, w, 4 * k, CELESTE);

	text("POSICIONES", x + 24 * k, top + 20 * k, 30 * k, INK);
	ZString info = s.time_left > 0
		? string::tformat_zstr("Límite %d frags · %s", s.fraglimit, fmt_clock(s.time_left))
		: string::tformat_zstr("Límite %d frags", s.fraglimit);
	text(info, x + w - 24 * k, top + 26 * k, 20 * k, DIM, RIGHT);

	float col_frags = x + w - 270 * k;
	float col_deaths = x + w - 150 * k;
	float col_ping = x + w - 30 * k;
	float hy = top + 66 * k;
	text("JUGADOR", x + 116 * k, hy, 15 * k, DIM);
	text("FRAGS", col_frags, hy, 15 * k, DIM, RIGHT);
	text("MUERTES", col_deaths, hy, 15 * k, DIM, RIGHT);
	text("PING", col_ping, hy, 15 * k, DIM, RIGHT);

	float y = top + head_h;
	for (int i = 0; i < v.row_count; i++)
	{
		ScoreRow* r = &v.rows[i];
		PlayerSnap* p = &s.players[r.slot];
		bool mine = r.slot == v.me;
		if (mine)
		{
			fill(x + 8 * k, y, w - 16 * k, row_h - 4 * k, with_alpha(CELESTE, 0.28f));
			fill(x + 8 * k, y, 5 * k, row_h - 4 * k, CELESTE);
		}
		else if (i % 2 == 0)
		{
			fill(x + 8 * k, y, w - 16 * k, row_h - 4 * k, { 255, 255, 255, 12 });
		}
		float ty = y + (row_h - 4 * k - font_px(24 * k)) / 2;
		RLColor rank_c = r.rank == 1 ? SOL : INK;
		text(string::tformat_zstr("%s", ordinal(r.rank)), x + 30 * k, ty, 24 * k, rank_c);
		panel(x + 80 * k, y + (row_h - 4 * k) / 2 - 12 * k, 24 * k, 24 * k, player_color(p.color), 0.35f);
		ZString name = p.name().zstr_tcopy();
		text(name, x + 116 * k, ty, 24 * k, INK);
		if (p.bot)
		{
			float bx = x + 116 * k + text_width(name, 24 * k) + 12 * k;
			float bh = font_px(15 * k) + 6 * k;
			panel(bx, y + (row_h - 4 * k - bh) / 2, text_width("BOT", 15 * k) + 12 * k, bh, PANEL_LIGHT, 0.3f);
			text("BOT", bx + 6 * k, y + (row_h - 4 * k - font_px(15 * k)) / 2, 15 * k, DIM, LEFT, false);
		}
		text(string::tformat_zstr("%d", r.frags), col_frags, ty, 24 * k, INK, RIGHT);
		text(string::tformat_zstr("%d", r.deaths), col_deaths, ty, 24 * k, DIM, RIGHT);
		ZString ping = p.bot ? "-" : string::tformat_zstr("%d", p.ping);
		text(ping, col_ping, ty, 24 * k, p.bot ? DIM : ping_color(p.ping), RIGHT);
		y += row_h;
	}
}

fn void draw_intermission(Snapshot* s, View* v) @local
{
	float k = v.k;
	fill(0, 0, v.w, v.h, { 0, 0, 0, 120 });
	float band_y = 70 * k;
	float band_h = 150 * k;
	bool has_winner = s.winner < defs::MAX_PLAYERS && s.players[s.winner].active;
	RLColor wc = has_winner ? player_color(s.players[s.winner].color) : CELESTE;
	rl::draw_rectangle_gradient_h(0, (int)band_y, (int)(v.w / 2), (int)band_h, with_alpha(wc, 0), with_alpha(wc, 0.55f));
	rl::draw_rectangle_gradient_h((int)(v.w / 2), (int)band_y, (int)(v.w / 2) + 1, (int)band_h, with_alpha(wc, 0.55f), with_alpha(wc, 0));
	fill(0, band_y, v.w, 3 * k, with_alpha(wc, 0.9f));
	fill(0, band_y + band_h - 3 * k, v.w, 3 * k, with_alpha(wc, 0.9f));

	ZString banner = "¡Fin de la partida!";
	if (has_winner)
	{
		banner = s.winner == v.me ? "¡Ganaste!" : string::tformat_zstr("¡Ganó %s!", s.players[s.winner].name());
	}
	text(banner, v.w / 2, band_y + 26 * k, 80 * k, INK, CENTER);
	if (state.match_end_at > NO_TIME)
	{
		int next = (int)math::ceil(math::max(defs::INTERMISSION_TIME - (state.clock - state.match_end_at), 0.0f));
		text(string::tformat_zstr("Siguiente partida en %d", next), v.w / 2, band_y + 112 * k, 22 * k, INK, CENTER);
	}
	draw_scoreboard(s, v, band_y + band_h + 40 * k);
}
