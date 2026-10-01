// Quake-style drop-down console (`~`, the key left of 1 on any layout, or F1).
// Scrollback, InputLine, History and Completion are plain logic (unit-tested);
// update/draw are the raylib side. Call init() after cvar::init() and
// shutdown() before cvar::shutdown().
module arena::console;
import std::io, std::math, arena::cvar, raylib6::rl;

const String VERSION = "Baires Arena · C3";
const int SCROLLBACK = 512;
const int LINE_CAP = 160;        // bytes per stored line; longer text wraps
const int INPUT_CAP = 255;
const int HISTORY = 32;
const int NOTIFY_LINES = 4;
const int MAX_LISTED = 40;       // matches printed on an ambiguous Tab
const float NOTIFY_FADE = 0.5f;  // seconds a notify line takes to fade out
const char PROMPT = ']';

const int FONT = 20;
const int SMALL_FONT = 10;
const int LINE_H = FONT + 2;
const int MARGIN = 8;
const int EDGE_H = 2;
const int CURSOR_W = 10;
const int CURSOR_H = 3;
const float BLINK_HZ = 2.0f;
const float WHEEL_LINES = 3.0f;
const String SCROLL_MARK = "^    ^    ^    ^    ^";

const RLColor PANEL = { 8, 10, 16, 255 };
const RLColor TEXT = { 214, 218, 224, 255 };
const RLColor ECHO = { 116, 190, 235, 255 };   // celeste de la línea A
const RLColor DIM = { 120, 130, 145, 255 };
const RLColor SHADOW = { 0, 0, 0, 200 };

// ---------------------------------------------------------------------------
// Scrollback: ring buffer of lines, NUL-terminated so raylib can draw them in place.

struct Line
{
	char[LINE_CAP + 1] text;
	int len;
	float time;     // when it was printed (caller's clock, see draw_notify)
}

struct Scrollback
{
	Line[SCROLLBACK] lines;
	int head;       // next slot to write
	int count;
}

<* Add one line (no '\n' inside); text longer than LINE_CAP wraps into more lines. *>
fn void Scrollback.add(&self, String text, float time)
{
	String rest = text;
	while (true)
	{
		sz n = utf8_cut(rest, LINE_CAP);
		Line* l = &self.lines[self.head];
		mem::copy(&l.text, rest.ptr, n);
		l.text[n] = 0;
		l.len = (int)n;
		l.time = time;
		self.head = (self.head + 1) % SCROLLBACK;
		if (self.count < SCROLLBACK) self.count++;
		rest = rest[n..];
		if (!rest.len) return;
	}
}

<* @require back >= 0 && back < self.count : "line out of range" *>
fn Line* Scrollback.at(&self, int back)
{
	return &self.lines[(self.head - 1 - back + SCROLLBACK) % SCROLLBACK];
}

<* Line `back` steps from the newest (0 = newest). *>
fn String Scrollback.line(&self, int back) => (String)self.at(back).text[:self.at(back).len];

fn void Scrollback.clear(&self)
{
	self.head = 0;
	self.count = 0;
}

<* Largest n <= max that doesn't split a UTF-8 sequence. *>
fn sz utf8_cut(String s, sz max)
{
	if (s.len <= max) return s.len;
	sz n = max;
	while (n > 0 && (s[n] & 0xC0) == 0x80) n--;
	return n ?: max;
}

// ---------------------------------------------------------------------------
// Input line: UTF-8 text with a cursor. Every change bumps `edits`.

struct InputLine
{
	char[INPUT_CAP + 1] buf;   // NUL-terminated
	int len;
	int cursor;                // byte offset, on a UTF-8 boundary
	int edits;
}

fn String InputLine.str(&self) => (String)self.buf[:self.len];

fn void InputLine.clear(&self)
{
	self.len = 0;
	self.cursor = 0;
	self.buf[0] = 0;
	self.edits++;
}

fn void InputLine.set(&self, String text)
{
	self.clear();
	self.insert(text);
}

<* Insert at the cursor (truncated to fit). *>
fn void InputLine.insert(&self, String text)
{
	sz n = utf8_cut(text, (sz)(INPUT_CAP - self.len));
	if (!n) return;
	mem::move(&self.buf[self.cursor + n], &self.buf[self.cursor], (sz)(self.len - self.cursor));
	mem::copy(&self.buf[self.cursor], text.ptr, n);
	self.len += (int)n;
	self.cursor += (int)n;
	self.buf[self.len] = 0;
	self.edits++;
}

fn void InputLine.insert_codepoint(&self, int cp)
{
	char[4] utf8;
	sz? n = conv::char32_to_utf8((Char32)cp, &utf8);
	if (catch n) return;
	self.insert((String)utf8[:n]);
}

<* Remove bytes [from, to). *>
fn void InputLine.remove(&self, int from, int to)
{
	if (to <= from) return;
	mem::move(&self.buf[from], &self.buf[to], (sz)(self.len - to));
	self.len -= to - from;
	self.buf[self.len] = 0;
	if (self.cursor >= to)
	{
		self.cursor -= to - from;
	}
	else if (self.cursor > from)
	{
		self.cursor = from;
	}
	self.edits++;
}

fn void InputLine.backspace(&self) => self.remove(self.prev(self.cursor), self.cursor);

fn void InputLine.delete(&self) => self.remove(self.cursor, self.next(self.cursor));

fn void InputLine.move_to(&self, int pos)
{
	self.cursor = math::clamp(pos, 0, self.len);
	self.edits++;
}

fn void InputLine.left(&self) => self.move_to(self.prev(self.cursor));
fn void InputLine.right(&self) => self.move_to(self.next(self.cursor));

<* Start of the codepoint before `pos`. *>
fn int InputLine.prev(&self, int pos)
{
	int i = pos;
	if (i > 0) i--;
	while (i > 0 && (self.buf[i] & 0xC0) == 0x80) i--;
	return i;
}

<* Start of the codepoint after the one at `pos`. *>
fn int InputLine.next(&self, int pos)
{
	int i = pos;
	if (i < self.len) i++;
	while (i < self.len && (self.buf[i] & 0xC0) == 0x80) i++;
	return i;
}

// ---------------------------------------------------------------------------
// History of submitted lines (ring). Browsing keeps the unfinished line as a draft.

struct HistEntry
{
	char[INPUT_CAP] text;
	int len;
}

fn String HistEntry.str(&self) => (String)self.text[:self.len];

fn void HistEntry.store(&self, String s)
{
	self.len = (int)s.len;
	mem::copy(&self.text, s.ptr, s.len);
}

struct History
{
	HistEntry[HISTORY] entries;
	HistEntry draft;
	int head;     // next slot to write
	int count;
	int browse;   // steps back from the newest; 0 = editing the draft
}

<* Skips empty lines and repeats of the newest entry. Ends browsing. *>
fn void History.add(&self, String line)
{
	self.browse = 0;
	if (!line.len) return;
	if (self.count > 0 && self.entry(1).str() == line) return;
	self.entries[self.head].store(line[:math::min(line.len, (sz)INPUT_CAP)]);
	self.head = (self.head + 1) % HISTORY;
	if (self.count < HISTORY) self.count++;
}

<* @require back >= 1 && back <= self.count *>
fn HistEntry* History.entry(&self, int back) => &self.entries[(self.head - back + HISTORY) % HISTORY];

fn void History.older(&self, InputLine* input)
{
	if (self.browse >= self.count) return;
	if (self.browse == 0) self.draft.store(input.str());
	self.browse++;
	input.set(self.entry(self.browse).str());
}

fn void History.newer(&self, InputLine* input)
{
	if (self.browse == 0) return;
	self.browse--;
	input.set(self.browse ? self.entry(self.browse).str() : self.draft.str());
}

// ---------------------------------------------------------------------------
// Tab completion of the word before the cursor. The first Tab remembers what was
// typed; each Tab after that puts the next match in place, until the line is edited.

struct Completion
{
	char[INPUT_CAP] prefix;
	int prefix_len;
	int word_start;
	int index;      // match currently shown, -1 = none yet
	int seen_edits; // input.edits after our last change
	bool active;
}

fn String Completion.typed(&self) => (String)self.prefix[:self.prefix_len];

<* True when this Tab starts a new completion (forgets the old one if the line changed). *>
fn bool Completion.begin(&self, InputLine* input)
{
	if (self.active && input.edits == self.seen_edits) return false;
	int start = input.cursor;
	while (start > 0 && !is_word_break(input.buf[start - 1])) start--;
	self.word_start = start;
	self.prefix_len = input.cursor - start;
	mem::copy(&self.prefix, &input.buf[start], self.prefix_len);
	self.index = -1;
	self.active = true;
	return true;
}

<* Put the next match (step -1: previous) in place of the word. A single match
   completes and adds a space; no matches does nothing. *>
fn void Completion.apply(&self, InputLine* input, String[] matches, int step)
{
	if (!matches.len)
	{
		self.active = false;
		return;
	}
	int n = (int)matches.len;
	if (self.index < 0)
	{
		self.index = step > 0 ? 0 : n - 1;
	}
	else
	{
		self.index = (self.index + step + n) % n;
	}
	input.remove(self.word_start, input.cursor);
	input.insert(matches[self.index]);
	if (n == 1 && input.cursor == input.len) input.insert(" ");
	self.seen_edits = input.edits;
	self.active = n > 1;
}

fn bool is_word_break(char c) => c == ' ' || c == ';' || c == '"';

// ---------------------------------------------------------------------------
// Console state and API

struct State @local
{
	Scrollback back;
	InputLine input;
	History history;
	Completion comp;
	Cvar* speed;
	Cvar* height;
	Cvar* alpha;
	Cvar* notify_time;
	Cvar* toggle_key;
	float frac;        // 0 closed .. 1 fully down
	float clock;       // seconds, advanced by update() (cursor blink)
	float now;         // caller's clock from draw_notify(): stamps new lines
	float wheel;       // fractional mouse-wheel lines
	int scroll;        // lines scrolled up from the newest
	int page;          // scrollback rows that fit, from the last draw()
	bool open;
	bool toggled;    // toggled this frame: the key (Esc, ~) is ours too
	bool ready;
}

State g @local;

<* Register the console cvars/commands and become the cvar printer. *>
fn void init()
{
	if (g.ready) return;
	g.ready = true;
	g.page = 1;
	g.speed = cvar::register("con_speed", "4", "console slide speed (heights per second, 0 = instant)", { .archive });
	g.height = cvar::register("con_height", "0.45", "console height (fraction of the screen)", { .archive });
	g.alpha = cvar::register("con_alpha", "0.85", "console background opacity", { .archive });
	g.notify_time = cvar::register("con_notifytime", "3", "seconds new lines stay on screen with the console closed", { .archive });
	g.toggle_key = cvar::register("con_togglekey", "0", "extra raylib key code that toggles the console", { .archive });
	cvar::add_command("clear", &cmd_clear, "clear the console");
	cvar::add_command("toggleconsole", &cmd_toggleconsole, "open/close the console");
	cvar::set_printer(&print);
}

fn void shutdown()
{
	if (!g.ready) return;
	cvar::set_printer(null);
	cvar::remove_command("clear");
	cvar::remove_command("toggleconsole");
	g = {};
}

fn bool is_open() => g.open;

<* While open (and on the frame it closes) the game must ignore the keyboard. *>
fn bool wants_keyboard() => g.open || g.toggled;

fn void toggle()
{
	g.open = !g.open;
	g.toggled = true;
	g.scroll = 0;
	// The toggle key also queued a character ('`', 'º', '|'...): drop it.
	while (rl::get_char_pressed() != 0)
	{
	}
}

fn void clear()
{
	g.back.clear();
	g.scroll = 0;
}

<* Add text to the scrollback (one line per '\n') and mirror it to stdout. *>
fn void print(String text)
{
	io::printn(text);
	String rest = text;
	while (true)
	{
		sz nl = rest.index_of_char('\n') ?? rest.len;
		g.back.add(rest[:nl].trim_right("\r"), g.now);
		if (g.scroll > 0) g.scroll++;   // keep the view still while scrolled up
		if (nl + 1 >= rest.len) return;
		rest = rest[nl + 1..];
	}
}

<* Number of scrollback lines (for tests and debug). *>
fn int line_count() => g.back.count;

<*
 Line `back` steps from the newest (0 = newest).
 @require back >= 0 && back < line_count() : "line out of range"
*>
fn String line(int back) => g.back.line(back);

<* Run what the user typed: echo it, remember it, execute it. *>
fn void submit(String text) => @pool()
{
	String line = text.tcopy();
	print(string::tformat("%c%s", PROMPT, line));
	g.history.add(line);
	g.scroll = 0;
	// Quake habit: a leading / or \ is optional.
	if (line.len && (line[0] == '/' || line[0] == '\\')) line = line[1..];
	cvar::exec(line);
}

<* Tab (step 1) / Shift+Tab (step -1); lists the matches on an ambiguous first press. *>
fn void tab(int step) => @pool()
{
	bool first = g.comp.begin(&g.input);
	String[] matches = cvar::complete(g.comp.typed(), tmem);
	if (first && matches.len > 1) list_matches(matches);
	g.comp.apply(&g.input, matches, step);
}

fn void update(float dt)
{
	if (!g.ready) return;
	g.clock += dt;
	g.toggled = false;
	if (toggle_pressed()) toggle();
	slide(dt);
	if (!g.open) return;
	handle_keys();
	handle_chars();
	handle_wheel();
}

fn void draw(int screen_w, int screen_h) => @pool()
{
	if (!g.ready || g.frac <= 0) return;
	int full_h = (int)(screen_h * g.height.num().clamp(0.1f, 1.0f));
	int h = (int)(full_h * g.frac);
	int top = h - full_h;   // the whole panel slides down from above
	rl::draw_rectangle(0, 0, screen_w, h, PANEL.fade(g.alpha.num().clamp(0.0f, 1.0f)));
	rl::draw_rectangle(0, h - EDGE_H, screen_w, EDGE_H, ECHO);

	// Input line, cursor and version.
	int input_y = top + full_h - EDGE_H - MARGIN / 2 - LINE_H;
	ZString prompt = string::tformat_zstr("%c", PROMPT);
	int text_x = MARGIN + rl::measure_text(prompt, FONT) + 2;
	rl::draw_text(prompt, MARGIN, input_y, FONT, ECHO);
	rl::draw_text((ZString)&g.input.buf, text_x, input_y, FONT, TEXT);
	if ((int)(g.clock * BLINK_HZ) % 2 == 0)
	{
		int cx = text_x + rl::measure_text(g.input.str()[:g.input.cursor].zstr_tcopy(), FONT);
		rl::draw_rectangle(cx, input_y + FONT - CURSOR_H, CURSOR_W, CURSOR_H, TEXT);
	}
	int version_w = rl::measure_text(VERSION, SMALL_FONT);
	rl::draw_text(VERSION, screen_w - version_w - MARGIN, input_y + FONT - SMALL_FONT, SMALL_FONT, DIM);

	// Scrollback, newest at the bottom.
	g.page = math::max(1, (full_h - LINE_H * 2) / LINE_H);
	clamp_scroll();
	int y = input_y - LINE_H;
	if (g.scroll > 0)
	{
		rl::draw_text(SCROLL_MARK, MARGIN, y, FONT, DIM);
		y -= LINE_H;
	}
	for (int back = g.scroll; back < g.back.count && y > -LINE_H; back++)
	{
		String text = g.back.line(back);
		RLColor color = text.len && text[0] == PROMPT ? ECHO : TEXT;
		rl::draw_text((ZString)&g.back.at(back).text, MARGIN, y, FONT, color);
		y -= LINE_H;
	}
}

<* The last few lines, top-left, for a moment after they're printed (console closed).
   `now` is any monotonic clock in seconds (e.g. rl::get_time()); it also stamps new lines. *>
fn void draw_notify(int screen_w, float now)
{
	if (!g.ready) return;
	g.now = now;
	if (g.frac > 0) return;
	float life = g.notify_time.num();
	int n = math::min(NOTIFY_LINES, g.back.count);
	int y = MARGIN;
	for (int back = n - 1; back >= 0; back--)
	{
		Line* l = g.back.at(back);
		float age = now - l.time;
		if (age < 0 || age > life) continue;
		float alpha = ((life - age) / NOTIFY_FADE).clamp(0.0f, 1.0f);
		ZString text = (ZString)&l.text;
		rl::draw_text(text, MARGIN + 1, y + 1, FONT, SHADOW.fade(alpha));
		rl::draw_text(text, MARGIN, y, FONT, TEXT.fade(alpha));
		y += LINE_H;
	}
}

// ---------------------------------------------------------------------------
// Internals

fn void slide(float dt) @local
{
	float target = g.open ? 1.0f : 0.0f;
	float speed = g.speed.num();
	if (speed <= 0)
	{
		g.frac = target;
		return;
	}
	float step = speed * dt;
	g.frac = g.frac < target ? math::min(g.frac + step, target) : math::max(g.frac - step, target);
}

fn bool toggle_pressed() @local
{
	if (rl::is_key_pressed(RLKeyboardKey.GRAVE) || rl::is_key_pressed(RLKeyboardKey.F1)) return true;
	int extra = g.toggle_key.integer();
	return extra > 0 && rl::is_key_pressed((RLKeyboardKey)extra);
}

<* Pressed now or auto-repeating. *>
fn bool pressed(RLKeyboardKey key) @local => rl::is_key_pressed(key) || rl::is_key_pressed_repeat(key);

fn void handle_keys() @local
{
	bool ctrl = rl::is_key_down(RLKeyboardKey.LEFT_CONTROL) || rl::is_key_down(RLKeyboardKey.RIGHT_CONTROL);
	bool shift = rl::is_key_down(RLKeyboardKey.LEFT_SHIFT) || rl::is_key_down(RLKeyboardKey.RIGHT_SHIFT);
	if (ctrl && rl::is_key_pressed(RLKeyboardKey.L)) clear();
	if (ctrl && rl::is_key_pressed(RLKeyboardKey.V)) paste();
	if (rl::is_key_pressed(RLKeyboardKey.ESCAPE)) toggle();
	if (rl::is_key_pressed(RLKeyboardKey.ENTER) || rl::is_key_pressed(RLKeyboardKey.KP_ENTER))
	{
		String text = g.input.str();
		submit(text);
		g.input.clear();
	}
	if (rl::is_key_pressed(RLKeyboardKey.TAB)) tab(shift ? -1 : 1);
	if (pressed(RLKeyboardKey.BACKSPACE)) g.input.backspace();
	if (pressed(RLKeyboardKey.DELETE)) g.input.delete();
	if (pressed(RLKeyboardKey.LEFT)) g.input.left();
	if (pressed(RLKeyboardKey.RIGHT)) g.input.right();
	if (rl::is_key_pressed(RLKeyboardKey.HOME)) g.input.move_to(0);
	if (rl::is_key_pressed(RLKeyboardKey.END)) g.input.move_to(g.input.len);
	if (pressed(RLKeyboardKey.UP)) g.history.older(&g.input);
	if (pressed(RLKeyboardKey.DOWN)) g.history.newer(&g.input);
	if (pressed(RLKeyboardKey.PAGE_UP)) scroll_by(g.page / 2);
	if (pressed(RLKeyboardKey.PAGE_DOWN)) scroll_by(-g.page / 2);
}

fn void handle_chars() @local
{
	for (int cp = rl::get_char_pressed(); cp != 0; cp = rl::get_char_pressed())
	{
		if (cp < ' ' || cp == 127) continue;
		g.input.insert_codepoint(cp);
	}
}

fn void handle_wheel() @local
{
	g.wheel += rl::get_mouse_wheel_move() * WHEEL_LINES;
	int lines = (int)g.wheel;
	if (!lines) return;
	g.wheel -= lines;
	scroll_by(lines);
}

fn void paste() @local
{
	ZString clip = rl::get_clipboard_text();
	if (!clip) return;
	String text = clip.str_view();
	sz nl = text.index_of_char('\n') ?? text.len;
	g.input.insert(text[:nl].trim_right("\r"));
}

fn void scroll_by(int lines) @local
{
	g.scroll += lines;
	clamp_scroll();
}

fn void clamp_scroll() @local
{
	g.scroll = math::clamp(g.scroll, 0, math::max(0, g.back.count - g.page + 1));
}

fn void list_matches(String[] matches) @local
{
	foreach (i, name : matches)
	{
		if (i == MAX_LISTED)
		{
			cvar::printf("  ... %d more", matches.len - MAX_LISTED);
			return;
		}
		Cvar* cv = cvar::find(name);
		if (cv)
		{
			cvar::printf("  %s \"%s\"", name, cv.value);
			continue;
		}
		cvar::printf("  %s", name);
	}
}

fn void cmd_clear(String[] args, void* ctx) @local
{
	clear();
}

fn void cmd_toggleconsole(String[] args, void* ctx) @local
{
	toggle();
}
