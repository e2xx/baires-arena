// Menus: main, bots/LAN setup, LAN browser, options and pause. Immediate-mode widgets drawn
// over the app's 3D flyby (panels stay semi-transparent). Navigation, text editing and value
// stepping are pure and tested; every widget shares the `@focusable` macro for id, hover,
// focus and activation.
module arena::menu;
import std::math, raylib6, arena::defs, arena::hud;

const int MAX_DEPTH = 4;
const int MAX_LAN_ROWS = 6;
const float ROW_H = 62.0f;
const float SCREEN_SLIDE = 0.25f;
const String DEFAULT_NAME = "Jugador";
const String VERSION = "v0.1 · C3 0.8.4 + raylib 6";
const String[5] SKILL_NAMES = { "Turista", "Aprendiz", "Habitué", "Capo", "Leyenda" };

const RLColor INK @local = hud::INK;
const RLColor DIM @local = hud::DIM;
const RLColor CELESTE @local = hud::CELESTE;
const RLColor SOL @local = hud::SOL;
const RLColor PANEL @local = { 8, 14, 30, 200 };
const RLColor FIELD @local = { 0, 0, 0, 120 };

// ---------------------------------------------------------------- public types

enum Screen : char (String title, String hint)
{
	MAIN { "BAIRES ARENA", "" },
	PLAY { "JUGAR CONTRA BOTS", "Práctica offline: vos contra la máquina" },
	HOST { "CREAR PARTIDA LAN", "Armá el server y que caigan los pibes" },
	JOIN { "UNIRSE A PARTIDA", "Partidas encontradas en la red local" },
	OPTIONS { "OPCIONES", "Tu nombre, tu color, tu mouse" },
	PAUSE { "PAUSA", "" },
}

enum Action : char (String label)
{
	NONE { "" },
	START_OFFLINE { "¡A jugar!" },
	HOST_GAME { "Crear partida" },
	JOIN_GAME { "Conectar" },
	REFRESH_LAN { "Actualizar" },
	RESUME { "Volver al juego" },
	DISCONNECT { "Desconectar" },
	QUIT { "Salir" },
}

enum MenuSound : char
{
	NONE,
	MOVE,
	SELECT,
}

struct Options
{
	char[24] name;
	usz name_len;
	char color;          // PlayerColor index
	float sensitivity;
	float fov;
	float volume;
	int bots;
	float bot_skill;     // 0..1
	int map_index;
	int fraglimit;       // 0 = none
	int timelimit;       // minutes, 0 = none
	char[64] address;
	usz address_len;
}

// Strings are zero-terminated unless they fill the whole array.
struct LanServer
{
	char[48] name;
	char[24] map;
	char[24] address;
	int players;
	int max_players;
	int ping_ms;
}

fn Options default_options()
{
	Options o = {
		.sensitivity = 3.0f,
		.fov = 90.0f,
		.volume = 0.8f,
		.bots = 5,
		.bot_skill = 0.5f,
		.fraglimit = defs::DEFAULT_FRAGLIMIT,
		.timelimit = defs::DEFAULT_TIMELIMIT_MIN,
	};
	o.name_len = hud::copy_text(&o.name, DEFAULT_NAME);
	return o;
}

fn String Options.player_name(&self) => (String)self.name[:self.name_len];
fn String Options.server_address(&self) => (String)self.address[:self.address_len];

fn String cstr(char[] buf) @local
{
	foreach (i, c : buf)
	{
		if (c == 0) return (String)buf[:i];
	}
	return (String)buf;
}

fn String LanServer.title(&self) => cstr(&self.name);
fn String LanServer.map_name(&self) => cstr(&self.map);
fn String LanServer.addr(&self) => cstr(&self.address);

// ---------------------------------------------------------------- settings (pure)

enum Setting : char (String label, float min, float max, float step)
{
	SENSITIVITY { "Sensibilidad del mouse", 0.5f, 10.0f, 0.1f },
	FOV { "Campo visual", 60.0f, 130.0f, 1.0f },
	VOLUME { "Volumen", 0.0f, 1.0f, 0.05f },
	BOTS { "Bots", 0.0f, (float)(defs::MAX_PLAYERS - 1), 1.0f },
	BOT_SKILL { "Habilidad de los bots", 0.0f, 1.0f, 0.05f },
	FRAGLIMIT { "Límite de frags", 0.0f, 100.0f, 5.0f },
	TIMELIMIT { "Límite de tiempo", 0.0f, 60.0f, 1.0f },
}

// Nearest value on the setting's grid, inside its range.
fn float Setting.snap(self, float v)
{
	float steps = math::round((v - self.min) / self.step);
	return math::clamp(self.min + steps * self.step, self.min, self.max);
}

fn float Setting.nudge(self, float v, int dir) => self.snap(v + dir * self.step);

fn float Setting.fraction(self, float v) => math::clamp((v - self.min) / (self.max - self.min), 0.0f, 1.0f);

fn float Setting.at(self, float t) => self.snap(self.min + math::clamp(t, 0.0f, 1.0f) * (self.max - self.min));

fn String skill_name(float skill) => SKILL_NAMES[math::clamp((int)(skill * SKILL_NAMES.len), 0, (int)SKILL_NAMES.len - 1)];

fn String Setting.describe(self, float v)
{
	int n = (int)math::round(v);
	switch (self)
	{
		case SENSITIVITY: return string::tformat("%.1f", v);
		case FOV: return string::tformat("%d°", n);
		case VOLUME: return string::tformat("%d%%", (int)math::round(v * 100.0f));
		case BOTS:
			if (n == 0) return "Ninguno";
			return n == 1 ? "1 bot" : string::tformat("%d bots", n);
		case BOT_SKILL: return skill_name(v);
		case FRAGLIMIT: return n == 0 ? "Sin límite" : string::tformat("%d frags", n);
		case TIMELIMIT: return n == 0 ? "Sin límite" : string::tformat("%d min", n);
	}
}

// ---------------------------------------------------------------- text editing (pure)

// `allowed` empty = any printable Latin-1 (what the font draws).
enum FieldKind : char (String allowed, String placeholder)
{
	NAME { "", "Escribí tu nombre" },
	ADDRESS { "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.:-", "192.168.0.10" },
}

fn bool FieldKind.accepts(self, int cp)
{
	if (cp < 32 || cp > 255 || (cp >= 127 && cp < 160)) return false;
	if (!self.allowed.len) return true;
	return cp < 128 && self.allowed.contains_char((char)cp);
}

fn bool is_cont(char c) @local => (c & 0xC0) == 0x80;

// UTF-8 editing over a fixed buffer, caret in bytes (always on a character boundary).
struct TextEdit
{
	char[] buf;
	usz len;
	usz caret;
	FieldKind kind;
}

fn String TextEdit.str(&self) => (String)self.buf[:self.len];

<*
 @require self.len <= self.buf.len && self.caret <= self.len
*>
fn bool TextEdit.insert(&self, int cp)
{
	if (!self.kind.accepts(cp)) return false;
	char[2] enc;
	usz n = 1;
	enc[0] = (char)cp;
	if (cp >= 0x80)
	{
		enc = { (char)(0xC0 | (cp >> 6)), (char)(0x80 | (cp & 0x3F)) };
		n = 2;
	}
	if (self.len + n > self.buf.len) return false;
	for (usz i = self.len; i > self.caret; i--) self.buf[i - 1 + n] = self.buf[i - 1];
	self.buf[self.caret:n] = enc[:n];
	self.len += n;
	self.caret += n;
	return true;
}

fn usz TextEdit.prev(&self)
{
	usz i = self.caret;
	if (i == 0) return 0;
	i--;
	while (i > 0 && is_cont(self.buf[i])) i--;
	return i;
}

fn usz TextEdit.next(&self)
{
	usz i = self.caret;
	if (i >= self.len) return self.len;
	i++;
	while (i < self.len && is_cont(self.buf[i])) i++;
	return i;
}

fn void TextEdit.cut(&self, usz from, usz to)
{
	usz n = to - from;
	for (usz i = to; i < self.len; i++) self.buf[i - n] = self.buf[i];
	self.len -= n;
	self.caret = from;
}

fn bool TextEdit.backspace(&self)
{
	if (self.caret == 0) return false;
	self.cut(self.prev(), self.caret);
	return true;
}

fn bool TextEdit.delete(&self)
{
	if (self.caret >= self.len) return false;
	usz caret = self.caret;
	self.cut(caret, self.next());
	return true;
}

fn void TextEdit.left(&self) => self.caret = self.prev();
fn void TextEdit.right(&self) => self.caret = self.next();
fn void TextEdit.home(&self) => self.caret = 0;
fn void TextEdit.end(&self) => self.caret = self.len;

// ---------------------------------------------------------------- navigation (pure)

enum NavKey : char
{
	NONE,
	UP,
	DOWN,
	LEFT,
	RIGHT,
	ACCEPT,
	BACK,
}

// Entries of the link screens: open a screen, or commit an action when `action` is set.
enum Link : char (String label, String hint, Screen target, Action action)
{
	PLAY_BOTS { "Jugar contra bots", "Práctica offline contra la máquina", PLAY, NONE },
	HOST_LAN { "Crear partida LAN", "Armá el server y que caigan los pibes", HOST, NONE },
	JOIN_LAN { "Unirse a partida", "Buscá partidas en la red local", JOIN, NONE },
	SETTINGS { "Opciones", "Nombre, color, mouse y sonido", OPTIONS, NONE },
	EXIT { "Salir", "Cerrar el juego. ¡Nos vemos en la próxima LAN!", MAIN, QUIT },
	BACK_TO_GAME { "Volver", "Seguir jugando", PAUSE, RESUME },
	LEAVE { "Desconectar", "Dejar la partida y volver al menú principal", PAUSE, DISCONNECT },
}

const Link[5] MAIN_LINKS = { PLAY_BOTS, HOST_LAN, JOIN_LAN, SETTINGS, EXIT };
const Link[4] PAUSE_LINKS = { BACK_TO_GAME, LEAVE, SETTINGS, EXIT };

fn int wrap(int i, int n) => n <= 0 ? 0 : (i % n + n) % n;

struct MenuState
{
	bool open;
	Screen[MAX_DEPTH] stack;
	int[MAX_DEPTH] saved_focus;   // focus to restore when coming back to a screen
	int depth;
	int focus;
	int count;          // focusable widgets on the current screen (last frame)
	bool editing;       // focus is on a text field: hover doesn't steal it
	int caret_owner;    // widget id the caret belongs to
	usz caret;
	int dragging;       // slider grabbed with the mouse, -1 = none
	int lan_selected;
	float anim;         // seconds since the current screen opened
	MenuSound sound;
	Action pending;     // action to report on the next update (e.g. refresh when opening JOIN)
}

fn void MenuState.reset(&self, Screen s)
{
	*self = { .open = true, .depth = 1, .lan_selected = -1 };
	self.stack[0] = s;
	self.enter_screen();
}

fn Screen MenuState.screen(&self) => self.stack[self.depth - 1];

fn void MenuState.enter_screen(&self)
{
	self.focus = 0;
	self.count = 0;
	self.anim = 0;
	self.editing = false;
	self.caret_owner = -1;
	self.dragging = -1;
	if (self.screen() == JOIN) self.pending = REFRESH_LAN;
}

fn void MenuState.push(&self, Screen s)
{
	self.sound = SELECT;
	if (self.depth >= MAX_DEPTH) return;
	self.saved_focus[self.depth - 1] = self.focus;
	self.stack[self.depth++] = s;
	self.enter_screen();
}

<*
 Esc: pops a screen. Out of the pause root it resumes (and closes); on the main menu it
 walks to "Salir" instead of quitting outright.
*>
fn Action MenuState.back(&self)
{
	if (self.depth > 1)
	{
		self.depth--;
		self.enter_screen();
		self.focus = self.saved_focus[self.depth - 1];
		self.sound = SELECT;
		return NONE;
	}
	if (self.screen() == PAUSE)
	{
		self.open = false;
		self.sound = SELECT;
		return RESUME;
	}
	self.set_focus(self.count - 1);
	return NONE;
}

fn void MenuState.set_focus(&self, int id)
{
	if (id < 0 || id == self.focus) return;
	self.focus = id;
	self.sound = MOVE;
}

// Screen-level keys; LEFT/RIGHT/ACCEPT belong to the focused widget.
fn Action MenuState.navigate(&self, NavKey key)
{
	switch (key)
	{
		case UP: self.set_focus(wrap(self.focus - 1, self.count));
		case DOWN: self.set_focus(wrap(self.focus + 1, self.count));
		case BACK: return self.back();
		default:
	}
	return NONE;
}

// ---------------------------------------------------------------- module state & API

MenuState menu @private;

fn void open(Screen s) => menu.reset(s);

fn void close() => menu.open = false;

fn bool is_open() => menu.open;

fn MenuSound take_sound()
{
	MenuSound s = menu.sound;
	menu.sound = NONE;
	return s;
}

// ---------------------------------------------------------------- immediate-mode widgets

struct MenuUi @local
{
	MenuState* st;
	Options* opt;
	float w;
	float h;
	float k;
	float t;
	NavKey key;
	bool key_used;
	RLVector2 mouse;
	bool mouse_moved;
	bool clicked;
	bool mouse_down;
	bool editing;
	int next;        // id of the next focusable widget
	Action action;
	float x;         // row layout cursor
	float y;
	float row_w;
}

<*
 Shared behaviour of every focusable widget: takes the next id, hover/click moves the focus,
 and returns true when activated (Enter while focused, or click). The body draws it.
*>
macro bool @focusable(MenuUi* ui, Rect r; @body(int id, bool focused, bool hover))
{
	int id = ui.next++;
	bool hover = r.contains_point(ui.mouse);
	if (hover && (ui.clicked || (ui.mouse_moved && !ui.st.editing))) ui.st.set_focus(id);
	bool focused = ui.st.focus == id;
	@body(id, focused, hover);
	if (!focused) return false;
	bool hit = (ui.key == ACCEPT && !ui.key_used) || (hover && ui.clicked);
	if (hit)
	{
		ui.key_used = true;
		ui.st.sound = SELECT;
	}
	return hit;
}

// LEFT/RIGHT for the focused widget: -1, +1 or 0. Consumes the key.
fn int side_key(MenuUi* ui, bool focused) @local
{
	if (!focused || ui.key_used) return 0;
	if (ui.key != LEFT && ui.key != RIGHT) return 0;
	ui.key_used = true;
	return ui.key == LEFT ? -1 : 1;
}

fn Rect MenuUi.next_row(&self, float height = ROW_H)
{
	Rect r = hud::rect(self.x, self.y, self.row_w, height * self.k - 6 * self.k);
	self.y += height * self.k;
	return r;
}

fn float MenuUi.mid(&self, Rect r, float size) => r.y + (r.height - hud::font_px(size * self.k)) / 2;

fn void row_frame(MenuUi* ui, Rect r, bool focused, bool hover, String label) @local
{
	float k = ui.k;
	if (focused)
	{
		rl::draw_rectangle_gradient_h((int)r.x, (int)r.y, (int)r.width, (int)r.height, hud::with_alpha(CELESTE, 0.32f), hud::with_alpha(CELESTE, 0.06f));
		hud::fill(r.x, r.y, 5 * k, r.height, CELESTE);
	}
	else if (hover)
	{
		hud::fill(r.x, r.y, r.width, r.height, { 255, 255, 255, 14 });
	}
	if (label.len) hud::text(label.zstr_tcopy(), r.x + 22 * k, ui.mid(r, 26), 26 * k, focused ? INK : DIM);
}

// Right-hand control area of a row.
fn Rect control(MenuUi* ui, Rect r) @local => hud::rect(r.x + r.width * 0.46f, r.y, r.width * 0.54f - 20 * ui.k, r.height);

enum ButtonStyle : char
{
	NORMAL,
	PRIMARY,
	DISABLED,
}

fn bool button(MenuUi* ui, Rect r, String label, ButtonStyle style = NORMAL) @local
{
	bool hit = @focusable(ui, r; int id, bool focused, bool hover)
	{
		float k = ui.k;
		RLColor bg = focused ? hud::with_alpha(CELESTE, 0.55f) : hud::PANEL_LIGHT;
		RLColor fg = INK;
		switch (style)
		{
			case PRIMARY:
				bg = hud::with_alpha(SOL, focused ? 1.0f : 0.7f);
				fg = { 20, 16, 8, 255 };
			case DISABLED:
				bg = hud::with_alpha(hud::PANEL_LIGHT, 0.6f);
				fg = hud::with_alpha(DIM, 0.6f);
			case NORMAL:
		}
		if (hover && !focused) bg = hud::with_alpha(bg, 0.85f);
		hud::panel(r.x, r.y, r.width, r.height, bg, 0.3f);
		if (focused) rl::draw_rectangle_rounded_lines_ex(r, 0.3f, 8, 2 * k, INK);
		hud::text(label.zstr_tcopy(), r.x + r.width / 2, ui.mid(r, 26), 26 * k, fg, CENTER, style != PRIMARY);
	};
	return hit && style != DISABLED;
}

fn float slider(MenuUi* ui, Setting s, float v) @local
{
	Rect r = ui.next_row();
	float nv = v;
	@focusable(ui, r; int id, bool focused, bool hover)
	{
		float k = ui.k;
		row_frame(ui, r, focused, hover, s.label);
		Rect c = control(ui, r);
		float tx = c.x + 10 * k;
		float tw = c.width * 0.62f;
		float ty = r.y + r.height / 2;
		int dir = side_key(ui, focused);
		if (dir) nv = s.nudge(v, dir);
		if (hover && ui.clicked && ui.mouse.x >= tx - 12 * k && ui.mouse.x <= tx + tw + 12 * k) ui.st.dragging = id;
		if (ui.st.dragging == id)
		{
			if (ui.mouse_down) nv = s.at((ui.mouse.x - tx) / tw);
			if (!ui.mouse_down) ui.st.dragging = -1;
		}
		float f = s.fraction(nv);
		hud::panel(tx, ty - 4 * k, tw, 8 * k, FIELD, 1.0f);
		hud::panel(tx, ty - 4 * k, math::max(tw * f, 8 * k), 8 * k, focused ? CELESTE : hud::with_alpha(CELESTE, 0.6f), 1.0f);
		rl::draw_circle_v({ tx + tw * f, ty }, (focused ? 12 : 9) * k, focused ? INK : DIM);
		hud::text(s.describe(nv).zstr_tcopy(), c.x + c.width, ui.mid(r, 24), 24 * k, focused ? INK : DIM, RIGHT);
	};
	if (nv != v) ui.st.sound = MOVE;
	return nv;
}

<*
 Slider over any numeric option (int or float), e.g. `@setting(ui, BOTS, opt.bots)`.
*>
macro void @setting(MenuUi* ui, Setting s, #value)
{
	float nv = slider(ui, s, (float)#value);
	#value = ($Typeof(#value))nv;
}

fn void arrow(RLVector2 c, float s, int dir, RLColor color) @local
{
	hud::tri({ c.x - s * dir * 0.5f, c.y - s * 0.6f }, { c.x - s * dir * 0.5f, c.y + s * 0.6f }, { c.x + s * dir * 0.5f, c.y }, color);
}

fn void choice(MenuUi* ui, String label, int* index, String[] values) @local
{
	Rect r = ui.next_row();
	bool hit = @focusable(ui, r; int id, bool focused, bool hover)
	{
		float k = ui.k;
		row_frame(ui, r, focused, hover, label);
		Rect c = control(ui, r);
		float cy = r.y + r.height / 2;
		float aw = 36 * k;
		Rect left = hud::rect(c.x, r.y, aw, r.height);
		Rect right = hud::rect(c.x + c.width - aw, r.y, aw, r.height);
		int dir = side_key(ui, focused);
		if (ui.clicked && left.contains_point(ui.mouse)) dir = -1;
		if (ui.clicked && right.contains_point(ui.mouse)) dir = 1;
		if (values.len)
		{
			*index = wrap(*index + dir, (int)values.len);
			if (dir) ui.st.sound = MOVE;
		}
		RLColor ac = focused ? CELESTE : DIM;
		arrow({ left.x + aw / 2, cy }, 14 * k, -1, ac);
		arrow({ right.x + aw / 2, cy }, 14 * k, 1, ac);
		String name = values.len ? values[wrap(*index, (int)values.len)] : "(sin mapas)";
		hud::text(name.zstr_tcopy(), c.x + c.width / 2, ui.mid(r, 26), 26 * k, focused ? INK : DIM, CENTER);
		if (values.len > 1)
		{
			ZString pos = string::tformat_zstr("%d/%d", wrap(*index, (int)values.len) + 1, values.len);
			hud::text(pos, c.x + c.width / 2, r.y + r.height - 14 * k, 12 * k, DIM, CENTER, false);
		}
	};
	// Enter / click on the name cycles forward.
	if (hit && values.len && !ui.clicked) *index = wrap(*index + 1, (int)values.len);
}

fn void color_picker(MenuUi* ui, char* color) @local
{
	Rect r = ui.next_row();
	@focusable(ui, r; int id, bool focused, bool hover)
	{
		float k = ui.k;
		row_frame(ui, r, focused, hover, "Color");
		Rect c = control(ui, r);
		int n = PlayerColor::len;
		int dir = side_key(ui, focused);
		if (dir)
		{
			*color = (char)wrap(*color + dir, n);
			ui.st.sound = MOVE;
		}
		float sw = 30 * k;
		float gap = 9 * k;
		float x = c.x + 10 * k;
		float y = r.y + (r.height - sw) / 2;
		for (int i = 0; i < n; i++)
		{
			Rect sq = hud::rect(x, y, sw, sw);
			if (ui.clicked && sq.contains_point(ui.mouse) && *color != i)
			{
				*color = (char)i;
				ui.st.sound = MOVE;
			}
			bool sel = *color == i;
			float grow = sel ? 4 * k : 0;
			if (sel) hud::panel(x - grow - 2 * k, y - grow - 2 * k, sw + 2 * grow + 4 * k, sw + 2 * grow + 4 * k, focused ? INK : DIM, 0.35f);
			hud::panel(x - grow, y - grow, sw + 2 * grow, sw + 2 * grow, hud::player_color((char)i), 0.3f);
			x += sw + gap;
		}
		PlayerColor pc = *color < n ? (PlayerColor)*color : CELESTE;
		hud::text(pc.name.zstr_tcopy(), c.x + c.width, ui.mid(r, 22), 22 * k, focused ? INK : DIM, RIGHT);
	};
}

fn void edit_keys(MenuUi* ui, TextEdit* e) @local
{
	for (int cp = rl::get_char_pressed(); cp > 0; cp = rl::get_char_pressed()) e.insert(cp);
	if (rl::is_key_pressed(RLKeyboardKey.BACKSPACE) || rl::is_key_pressed_repeat(RLKeyboardKey.BACKSPACE)) e.backspace();
	if (rl::is_key_pressed(RLKeyboardKey.DELETE) || rl::is_key_pressed_repeat(RLKeyboardKey.DELETE)) e.delete();
	if (rl::is_key_pressed(RLKeyboardKey.HOME)) e.home();
	if (rl::is_key_pressed(RLKeyboardKey.END)) e.end();
	int dir = side_key(ui, true);
	if (dir < 0) e.left();
	if (dir > 0) e.right();
}

fn void text_field(MenuUi* ui, String label, char[] buf, usz* len, FieldKind kind) @local
{
	Rect r = ui.next_row();
	int self_id;
	bool hit = @focusable(ui, r; int id, bool focused, bool hover)
	{
		self_id = id;
		float k = ui.k;
		row_frame(ui, r, focused, hover, label);
		Rect c = control(ui, r);
		Rect box = hud::rect(c.x, r.y + 8 * k, c.width, r.height - 16 * k);
		if (focused)
		{
			ui.editing = true;
			if (ui.st.caret_owner != id)
			{
				ui.st.caret_owner = id;
				ui.st.caret = *len;
			}
			TextEdit e = { buf, *len, ui.st.caret < *len ? ui.st.caret : *len, kind };
			edit_keys(ui, &e);
			*len = e.len;
			ui.st.caret = e.caret;
		}
		hud::panel(box.x, box.y, box.width, box.height, FIELD, 0.2f);
		rl::draw_rectangle_rounded_lines_ex(box, 0.2f, 8, 2 * k, focused ? CELESTE : hud::with_alpha(DIM, 0.4f));
		float tx = box.x + 12 * k;
		float ty = ui.mid(box, 24);
		rl::begin_scissor_mode((int)box.x, (int)box.y, (int)box.width, (int)box.height);
		String value = (String)buf[:*len];
		if (*len == 0 && !focused) hud::text(kind.placeholder.zstr_tcopy(), tx, ty, 24 * k, hud::with_alpha(DIM, 0.5f), LEFT, false);
		hud::text(value.zstr_tcopy(), tx, ty, 24 * k, INK);
		if (focused && ui.t - math::floor(ui.t) < 0.55f)
		{
			float cx = tx + hud::text_width(value[:ui.st.caret].zstr_tcopy(), 24 * k) + 2 * k;
			hud::fill(cx, ty - 2 * k, 3 * k, hud::font_px(24 * k) + 4 * k, CELESTE);
		}
		rl::end_scissor_mode();
	};
	// Enter jumps to the next widget, like a form.
	if (hit && !ui.clicked) ui.st.set_focus(self_id + 1);
}

fn void link_item(MenuUi* ui, Link l, float x, float y, float w, float size) @local
{
	float k = ui.k;
	float h = hud::font_px(size * k) + 26 * k;
	Rect r = hud::rect(x, y, w, h);
	bool hit = @focusable(ui, r; int id, bool focused, bool hover)
	{
		if (focused)
		{
			rl::draw_rectangle_gradient_h((int)x, (int)y, (int)w, (int)h, hud::with_alpha(CELESTE, 0.4f), hud::with_alpha(CELESTE, 0));
			hud::fill(x, y, 6 * k, h, CELESTE);
		}
		float slide = focused ? 34 * k : (hover ? 26 * k : 22 * k);
		hud::text(l.label.zstr_tcopy(), x + slide, y + (h - hud::font_px(size * k)) / 2, size * k, focused ? INK : DIM);
	};
	if (!hit) return;
	if (l.action == NONE)
	{
		ui.st.push(l.target);
		return;
	}
	ui.action = l.action;
	if (l.action == RESUME) ui.st.open = false;
}

// ---------------------------------------------------------------- decoration

fn RLVector2 polar(float a, float d) @local => { math::cos(a) * d, math::sin(a) * d };

// Sol de Mayo: 32 alternating rays around a face, slowly turning.
fn void draw_sun(RLVector2 c, float r, float t, float glow) @local
{
	int rays = 32;
	for (int i = 0; i < rays; i++)
	{
		float a = t * 0.15f + (float)i * (float)math::PI * 2.0f / rays;
		bool straight = i % 2 == 0;
		float len = straight ? r * 2.05f : r * 1.7f;
		float half = straight ? 0.07f : 0.045f;
		hud::tri(c + polar(a - half, r * 0.9f), c + polar(a, len), c + polar(a + half, r * 0.9f), hud::with_alpha(SOL, straight ? 0.95f : 0.75f));
	}
	rl::draw_circle_v(c, r * 1.3f, hud::with_alpha(SOL, 0.18f * glow));
	rl::draw_circle_v(c, r, SOL);
	rl::draw_circle_v(c, r * 0.84f, { 255, 206, 72, 255 });
	RLColor face = { 160, 96, 10, 255 };
	rl::draw_circle_v(c + (RLVector2){ -r * 0.3f, -r * 0.14f }, r * 0.09f, face);
	rl::draw_circle_v(c + (RLVector2){ r * 0.3f, -r * 0.14f }, r * 0.09f, face);
	rl::draw_ring(c + (RLVector2){ 0, r * 0.02f }, r * 0.4f, r * 0.48f, 30, 150, 16, face);
}

fn void draw_title(MenuUi* ui, float x, float y) @local
{
	float k = ui.k;
	float size = 120 * k;
	float px = hud::font_px(size);
	ZString a = "BAIRES ";
	ZString b = "ARENA";
	float wa = hud::text_width(a, size);
	float wb = hud::text_width(b, size);
	float pulse = 0.5f + 0.5f * math::sin(ui.t * 2.2f);

	draw_sun({ x + wa + wb + 120 * k, y + px * 0.45f }, 46 * k, ui.t, pulse);
	for (int i = 0; i < 8; i++)
	{
		RLVector2 o = polar((float)i * (float)math::PI / 4.0f, 5 * k);
		hud::text(a, x + o.x, y + o.y, size, hud::with_alpha(CELESTE, 0.10f + 0.12f * pulse), LEFT, false);
		hud::text(b, x + wa + o.x, y + o.y, size, hud::with_alpha(SOL, 0.10f + 0.12f * pulse), LEFT, false);
	}
	hud::text(a, x, y, size, INK);
	hud::text(b, x + wa, y, size, SOL);

	// Celeste-white-celeste rule under the title.
	float ry = y + px + 14 * k;
	float rw = wa + wb;
	hud::fill(x, ry, rw, 5 * k, CELESTE);
	hud::fill(x, ry + 5 * k, rw, 5 * k, INK);
	hud::fill(x, ry + 10 * k, rw, 5 * k, CELESTE);
	hud::text("LAN party porteña · hecho en C3", x + 4 * k, ry + 30 * k, 30 * k, CELESTE);
}

fn void backdrop(MenuUi* ui, Screen s) @local
{
	int w = (int)ui.w;
	int h = (int)ui.h;
	if (s == PAUSE)
	{
		hud::fill(0, 0, ui.w, ui.h, { 0, 0, 0, 150 });
		return;
	}
	rl::draw_rectangle_gradient_h(0, 0, w, h, { 4, 8, 18, 215 }, { 4, 8, 18, 40 });
	rl::draw_rectangle_gradient_v(0, h - h / 4, w, h / 4, { 0, 0, 0, 0 }, { 0, 0, 0, 120 });
}

fn void footer(MenuUi* ui, String hint) @local
{
	float k = ui.k;
	float y = ui.h - 46 * k;
	if (hint.len) hud::text(hint.zstr_tcopy(), 120 * k, y - 44 * k, 22 * k, CELESTE);
	hud::text("Flechas: elegir · Enter: aceptar · Esc: volver", 120 * k, y, 18 * k, DIM);
	hud::text(VERSION.zstr_tcopy(), ui.w - 40 * k, y, 18 * k, hud::with_alpha(DIM, 0.7f), RIGHT);
}

fn void player_badge(MenuUi* ui) @local
{
	float k = ui.k;
	ZString name = ui.opt.player_name().zstr_tcopy();
	float size = 24 * k;
	float w = hud::text_width(name, size) + 150 * k;
	float h = 52 * k;
	float x = ui.w - w - 40 * k;
	float y = 40 * k;
	hud::panel(x, y, w, h, PANEL, 0.3f);
	hud::text("Jugás como", x + 16 * k, y + (h - hud::font_px(15 * k)) / 2, 15 * k, DIM);
	hud::panel(x + 112 * k, y + h / 2 - 9 * k, 18 * k, 18 * k, hud::player_color(ui.opt.color), 0.3f);
	hud::text(name, x + 138 * k, y + (h - hud::font_px(size)) / 2, size, INK);
}

// Panel of a form screen: title, hint, and the row cursor set below them.
fn void begin_panel(MenuUi* ui, Screen s, float rows) @local
{
	float k = ui.k;
	float ease = 1.0f - math::pow(1.0f - math::min(ui.st.anim / SCREEN_SLIDE, 1.0f), 3.0f);
	float x = 110 * k - (1.0f - ease) * 60 * k;
	float y = 110 * k;
	float w = math::min(900 * k, ui.w - 2 * x);
	float h = 150 * k + rows * ROW_H * k + 30 * k;
	hud::panel(x, y, w, h, PANEL, 0.04f);
	hud::fill(x, y, w, 5 * k, CELESTE);
	hud::text(s.title.zstr_tcopy(), x + 40 * k, y + 38 * k, 50 * k, INK);
	hud::text(s.hint.zstr_tcopy(), x + 42 * k, y + 100 * k, 22 * k, CELESTE);
	ui.x = x + 20 * k;
	ui.y = y + 150 * k;
	ui.row_w = w - 40 * k;
}

// Two buttons sharing one row: the primary action and "Volver".
fn void action_row(MenuUi* ui, String label, Action action, bool enabled = true) @local
{
	ui.y += 14 * ui.k;
	Rect r = ui.next_row(ROW_H + 6);
	float gap = 16 * ui.k;
	float bw = (r.width - gap) / 2;
	if (button(ui, hud::rect(r.x, r.y, bw, r.height), label, true) && enabled) ui.action = action;
	if (button(ui, hud::rect(r.x + bw + gap, r.y, bw, r.height), "Volver")) ui.action = ui.st.back();
}

// ---------------------------------------------------------------- screens

fn void screen_main(MenuUi* ui) @local
{
	float k = ui.k;
	draw_title(ui, 120 * k, 130 * k);
	float y = 440 * k;
	foreach (l : MAIN_LINKS)
	{
		link_item(ui, l, 100 * k, y, 640 * k, 44);
		y += 80 * k;
	}
	player_badge(ui);
	footer(ui, MAIN_LINKS[wrap(ui.st.focus, MAIN_LINKS.len)].hint);
}

fn void screen_pause(MenuUi* ui) @local
{
	float k = ui.k;
	float w = 560 * k;
	float h = 480 * k;
	float x = (ui.w - w) / 2;
	float y = (ui.h - h) / 2;
	hud::panel(x, y, w, h, PANEL, 0.05f);
	hud::fill(x, y, w, 5 * k, CELESTE);
	hud::text("PAUSA", ui.w / 2, y + 40 * k, 60 * k, INK, CENTER);
	float ly = y + 140 * k;
	foreach (l : PAUSE_LINKS)
	{
		link_item(ui, l, x + 40 * k, ly, w - 80 * k, 36);
		ly += 76 * k;
	}
	footer(ui, PAUSE_LINKS[wrap(ui.st.focus, PAUSE_LINKS.len)].hint);
}

fn void screen_setup(MenuUi* ui, String[] maps, bool host) @local
{
	Options* o = ui.opt;
	begin_panel(ui, host ? HOST : PLAY, host ? 7 : 6);
	if (maps.len) o.map_index = wrap(o.map_index, (int)maps.len);
	choice(ui, "Mapa", &o.map_index, maps);
	@setting(ui, BOTS, o.bots);
	@setting(ui, BOT_SKILL, o.bot_skill);
	@setting(ui, FRAGLIMIT, o.fraglimit);
	@setting(ui, TIMELIMIT, o.timelimit);
	if (host)
	{
		Rect r = ui.next_row();
		ZString info = string::tformat_zstr("Se anuncia en la LAN como «%s» · puerto %d", o.player_name(), defs::DEFAULT_PORT);
		hud::text(info, r.x + 22 * ui.k, ui.mid(r, 20), 20 * ui.k, DIM);
	}
	Action a = host ? HOST_GAME : START_OFFLINE;
	action_row(ui, a.label, a);
	footer(ui, "");
}

fn RLColor ping_color(int ms) @local
{
	if (ms < 50) return { 120, 230, 130, 255 };
	if (ms < 120) return hud::ARMOR_GOLD;
	return hud::DANGER;
}

fn void server_list(MenuUi* ui, LanServer[] lan) @local
{
	float k = ui.k;
	int n = math::min((int)lan.len, MAX_LAN_ROWS);
	if (ui.st.lan_selected >= n) ui.st.lan_selected = -1;
	Rect head = ui.next_row(36);
	float c_map = head.x + head.width * 0.5f;
	float c_players = head.x + head.width * 0.8f;
	float c_ping = head.x + head.width - 20 * k;
	hud::text("PARTIDA", head.x + 22 * k, ui.mid(head, 15), 15 * k, DIM);
	hud::text("MAPA", c_map, ui.mid(head, 15), 15 * k, DIM);
	hud::text("JUGADORES", c_players, ui.mid(head, 15), 15 * k, DIM, RIGHT);
	hud::text("PING", c_ping, ui.mid(head, 15), 15 * k, DIM, RIGHT);
	if (n == 0)
	{
		Rect r = ui.next_row(ROW_H * MAX_LAN_ROWS);
		int dots = (int)(ui.t * 2.0f) % 4;
		ZString msg = string::tformat_zstr("Buscando partidas en la red local%s", "..."[:dots]);
		hud::text(msg, r.x + r.width / 2, r.y + r.height / 2 - 30 * k, 24 * k, DIM, CENTER);
		hud::text("¿Nadie armó server? Creá uno desde el menú principal.", r.x + r.width / 2, r.y + r.height / 2 + 10 * k, 18 * k, hud::with_alpha(DIM, 0.7f), CENTER);
		return;
	}
	for (int i = 0; i < n; i++)
	{
		LanServer* srv = &lan[i];
		Rect r = ui.next_row();
		bool selected = ui.st.lan_selected == i;
		bool hit = @focusable(ui, r; int id, bool focused, bool hover)
		{
			if (selected) hud::fill(r.x, r.y, r.width, r.height, hud::with_alpha(SOL, 0.16f));
			row_frame(ui, r, focused, hover, "");
			float ty = ui.mid(r, 24);
			hud::text(srv.title().zstr_tcopy(), r.x + 22 * k, ty, 24 * k, focused || selected ? INK : DIM);
			hud::text(srv.map_name().zstr_tcopy(), c_map, ty, 22 * k, DIM);
			bool full = srv.players >= srv.max_players;
			hud::text(string::tformat_zstr("%d/%d", srv.players, srv.max_players), c_players, ty, 22 * k, full ? hud::DANGER : INK, RIGHT);
			hud::text(string::tformat_zstr("%d ms", srv.ping_ms), c_ping, ty, 22 * k, ping_color(srv.ping_ms), RIGHT);
		};
		if (!hit) continue;
		// First click selects (and fills the address), Enter or a second click connects.
		ui.opt.address_len = hud::copy_text(&ui.opt.address, srv.addr());
		if (selected || !ui.clicked) ui.action = JOIN_GAME;
		ui.st.lan_selected = i;
	}
	ui.y += (float)(MAX_LAN_ROWS - n) * ROW_H * k;
}

fn void screen_join(MenuUi* ui, LanServer[] lan) @local
{
	Options* o = ui.opt;
	begin_panel(ui, JOIN, MAX_LAN_ROWS + 4.6f);
	server_list(ui, lan);
	Rect r = ui.next_row();
	if (button(ui, hud::rect(r.x, r.y, 260 * ui.k, r.height), Action.REFRESH_LAN.label)) ui.action = REFRESH_LAN;
	text_field(ui, "Dirección IP", &o.address, &o.address_len, ADDRESS);
	action_row(ui, Action.JOIN_GAME.label, JOIN_GAME, o.address_len > 0);
	footer(ui, "");
}

fn void name_preview(MenuUi* ui) @local
{
	float k = ui.k;
	Rect r = ui.next_row();
	float x = r.x + 22 * k;
	float y = ui.mid(r, 22);
	ZString lead = "Así te ven:  ";
	hud::text(lead, x, y, 22 * k, DIM);
	x += hud::text_width(lead, 22 * k);
	ZString name = ui.opt.player_name().zstr_tcopy();
	hud::text(name, x, y, 22 * k, hud::player_color(ui.opt.color));
	x += hud::text_width(name, 22 * k);
	ZString tail = " [Railgun] Colo";
	hud::text(tail, x, y, 22 * k, DIM);
}

fn void screen_options(MenuUi* ui) @local
{
	Options* o = ui.opt;
	begin_panel(ui, OPTIONS, 7.4f);
	text_field(ui, "Nombre", &o.name, &o.name_len, NAME);
	color_picker(ui, &o.color);
	name_preview(ui);
	@setting(ui, SENSITIVITY, o.sensitivity);
	@setting(ui, FOV, o.fov);
	@setting(ui, VOLUME, o.volume);
	ui.y += 14 * ui.k;
	Rect r = ui.next_row(ROW_H + 6);
	if (button(ui, hud::rect(r.x, r.y, (r.width - 16 * ui.k) / 2, r.height), "Volver")) ui.action = ui.st.back();
	footer(ui, "");
}

// ---------------------------------------------------------------- frame

fn NavKey read_key() @local
{
	if (rl::is_key_pressed(RLKeyboardKey.ESCAPE)) return BACK;
	if (rl::is_key_pressed(RLKeyboardKey.ENTER) || rl::is_key_pressed(RLKeyboardKey.KP_ENTER)) return ACCEPT;
	bool shift = rl::is_key_down(RLKeyboardKey.LEFT_SHIFT) || rl::is_key_down(RLKeyboardKey.RIGHT_SHIFT);
	if (rl::is_key_pressed(RLKeyboardKey.TAB)) return shift ? UP : DOWN;
	if (rl::is_key_pressed(RLKeyboardKey.UP) || rl::is_key_pressed_repeat(RLKeyboardKey.UP)) return UP;
	if (rl::is_key_pressed(RLKeyboardKey.DOWN) || rl::is_key_pressed_repeat(RLKeyboardKey.DOWN)) return DOWN;
	if (rl::is_key_pressed(RLKeyboardKey.LEFT) || rl::is_key_pressed_repeat(RLKeyboardKey.LEFT)) return LEFT;
	if (rl::is_key_pressed(RLKeyboardKey.RIGHT) || rl::is_key_pressed_repeat(RLKeyboardKey.RIGHT)) return RIGHT;
	return NONE;
}

RLVector2 last_mouse @private;

<*
 Runs and draws one frame of the open menu. Returns the action the user committed, if any;
 everything else (settings, name, address) is edited in place in `opt`.
*>
fn Action update_draw(Options* opt, LanServer[] lan, String[] maps, int screen_w, int screen_h) => @pool()
{
	if (!menu.open) return NONE;
	MenuUi ui = {
		.st = &menu,
		.opt = opt,
		.w = screen_w,
		.h = screen_h,
		.k = screen_h / hud::REF_HEIGHT,
		.t = (float)rl::get_time(),
		.key = read_key(),
		.mouse = rl::get_mouse_position(),
		.clicked = rl::is_mouse_button_pressed(LEFT),
		.mouse_down = rl::is_mouse_button_down(LEFT),
	};
	ui.mouse_moved = ui.mouse != last_mouse;
	last_mouse = ui.mouse;
	menu.anim += rl::get_frame_time();

	Screen before = menu.screen();
	Action action = menu.navigate(ui.key);
	if (ui.key == UP || ui.key == DOWN || ui.key == BACK) ui.key_used = true;

	Screen s = menu.screen();
	backdrop(&ui, s);
	switch (s)
	{
		case MAIN: screen_main(&ui);
		case PLAY: screen_setup(&ui, maps, false);
		case HOST: screen_setup(&ui, maps, true);
		case JOIN: screen_join(&ui, lan);
		case OPTIONS: screen_options(&ui);
		case PAUSE: screen_pause(&ui);
	}
	if (s == menu.screen())
	{
		menu.count = ui.next;
		menu.editing = ui.editing;
	}

	// Never leave the options with an empty name.
	if (before == OPTIONS && (!menu.open || menu.screen() != OPTIONS) && opt.name_len == 0)
	{
		opt.name_len = hud::copy_text(&opt.name, DEFAULT_NAME);
	}
	if (ui.action != NONE) return ui.action;
	if (action != NONE) return action;
	Action pending = menu.pending;
	menu.pending = NONE;
	return pending;
}
