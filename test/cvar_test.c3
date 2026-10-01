module arena::cvar_test;
import std::io, std::io::file, std::io::path, arena::cvar;

// Printer capture: fixed buffer, so tests don't allocate.
char[8192] out_buf @local;
sz out_len @local;

fn void capture(String text) @local
{
	foreach (c : text) put(c);
	put('\n');
}

fn void put(char c) @local
{
	if (out_len < out_buf.len) out_buf[out_len++] = c;
}

fn String output() @local => (String)out_buf[:out_len];

fn void start() @local
{
	out_len = 0;
	cvar::set_printer(&capture);
}

// A command that records its args as "a|b|c".
char[1024] args_buf @local;
sz args_len @local;
int args_calls @local;

fn void record_args(String[] args, void* ctx) @local
{
	args_calls++;
	args_len = 0;
	foreach (i, a : args)
	{
		if (i > 0) args_buf[args_len++] = '|';
		foreach (c : a) args_buf[args_len++] = c;
	}
}

fn String recorded() @local => (String)args_buf[:args_len];

fn void register_find_set() @test
{
	start();
	defer cvar::shutdown();
	Cvar* fov = cvar::register("r_fov", "90", "field of view", { .archive });
	assert(fov.str() == "90");
	assert(fov.integer() == 90 && fov.num() == 90.0f && fov.on());
	assert(cvar::find("r_fov") == fov);
	assert(cvar::find("R_FOV") == fov, "names are case-insensitive");
	assert(cvar::find("r_nope") == null);

	cvar::set("r_fov", "110");
	assert(fov.integer() == 110 && fov.modified == 1);
	assert(cvar::register("r_fov", "75", "again") == fov, "register is idempotent");
	assert(fov.str() == "110" && fov.default_value == "90");

	cvar::set("my_thing", "hola");
	Cvar* mine = cvar::find("my_thing");
	assert(mine != null && mine.flags.user && mine.str() == "hola");

	fov.reset();
	assert(fov.str() == "90" && fov.modified == 2);
}

fn void numeric_parsing() @test
{
	start();
	defer cvar::shutdown();
	Cvar* cv = cvar::register("t_num", "0.5", "");
	assert(cv.num() == 0.5f && cv.integer() == 0 && cv.on());
	cv.set("abc");
	assert(cv.num() == 0 && cv.integer() == 0 && !cv.on());
	cv.set("-3");
	assert(cv.num() == -3.0f && cv.integer() == -3);
	cv.set("7.9");
	assert(cv.integer() == 7);
	cv.set("");
	assert(!cv.on());
	cv.set_float(0.25f);
	assert(cv.str() == "0.25", "got %s", cv.str());
	cv.set_int(42);
	assert(cv.str() == "42" && cv.integer() == 42);
}

fn void flags_protect() @test
{
	start();
	defer cvar::shutdown();
	Cvar* ver = cvar::register("version", "1.0", "", { .readonly });
	cvar::exec("version 2.0");
	assert(ver.str() == "1.0");
	assert(output().contains("read only"));
	ver.set("1.1");
	assert(ver.str() == "1.1", "code can still change readonly cvars");

	Cvar* god = cvar::register("g_god", "0", "", { .cheat });
	cvar::exec("g_god 1");
	assert(!god.on());
	assert(output().contains("cheat protected"));
	cvar::exec("sv_cheats 1; g_god 1");
	assert(god.on());
}

fn void register_adopts_user_value() @test
{
	start();
	defer cvar::shutdown();
	cvar::exec("seta cl_name Fede; set version hacked");
	Cvar* name = cvar::register("cl_name", "jugador", "player name");
	assert(name.str() == "Fede", "user value survives registration");
	assert(!name.flags.user && name.flags.archive);
	assert(name.default_value == "jugador" && name.help == "player name");
	Cvar* ver = cvar::register("version", "1.0", "", { .readonly });
	assert(ver.str() == "1.0", "readonly cvars ignore earlier user values");
}

fn void exec_parsing() @test
{
	start();
	defer cvar::shutdown();
	cvar::add_command("rec", &record_args, "record args");

	cvar::exec("rec a \"b c\"   d");
	assert(recorded() == "rec|a|b c|d", "got %s", recorded());

	cvar::exec("rec \"x;y\" z");
	assert(recorded() == "rec|x;y|z", "quoted ';' does not split");

	cvar::exec("set a 1; set b 2;set c 3");
	assert(cvar::find("a").integer() == 1 && cvar::find("b").integer() == 2 && cvar::find("c").integer() == 3);

	args_calls = 0;
	cvar::exec("set d 4 // set d 5; rec nope\n// whole line\n  \n;;\nrec \"unclosed quote");
	assert(cvar::find("d").integer() == 4);
	assert(args_calls == 1 && recorded() == "rec|unclosed quote", "got %s", recorded());

	cvar::exec("set \"e f\" 1");
	assert(output().contains("invalid cvar name"));

	cvar::exec("banana 3");
	assert(output().contains("unknown command \"banana\""));

	out_len = 0;
	cvar::exec("echo hola   che \"y vos\"");
	assert(output() == "hola che y vos\n", "got [%s]", output());

	out_len = 0;
	cvar::exec("d");
	assert(output().contains("d is \"4\""), "naming a cvar prints it");
}

fn void toggle_values() @test
{
	start();
	defer cvar::shutdown();
	Cvar* fly = cvar::register("cl_fly", "0", "");
	cvar::exec("toggle cl_fly");
	assert(fly.on());
	cvar::exec("toggle cl_fly");
	assert(!fly.on());

	Cvar* map = cvar::register("sv_map", "subte", "");
	cvar::exec("toggle sv_map subte obelisco puerto");
	assert(map.str() == "obelisco");
	cvar::exec("toggle sv_map subte obelisco puerto; toggle sv_map subte obelisco puerto");
	assert(map.str() == "subte", "wraps around");
	cvar::exec("toggle nada");
	assert(output().contains("unknown cvar"));
}

fn void complete_names() @test
{
	start();
	defer cvar::shutdown();
	cvar::register("sensitivity", "3", "");
	cvar::register("sv_gravity", "25", "");
	cvar::register("S_volume", "0.8", "");
	cvar::add_command("say", &record_args, "chat");

	String[] m = cvar::complete("s", tmem);
	String[*] want = { "S_volume", "say", "sensitivity", "set", "seta", "sv_cheats", "sv_gravity" };
	assert(m.len == want.len, "got %d matches", m.len);
	foreach (i, w : want) assert(m[i] == w, "match %d: %s", i, m[i]);

	assert(cvar::complete("SE", tmem).len == 3, "case-insensitive prefix");
	assert(cvar::complete("zzz", tmem).len == 0);
	assert(cvar::complete("", tmem).len == cvar::all().len + 9, "empty prefix = everything");
}

fn void save_and_exec_round_trip() @test
{
	start();
	defer cvar::shutdown();
	String cfg = path::temp_directory(tmem)!!.tappend("arena_cvar_test.cfg")!!;
	defer (void)file::delete(cfg);

	cvar::register("cl_name", "jugador", "", { .archive });
	cvar::register("r_fov", "90", "", { .archive });
	cvar::register("r_debug", "0", "");
	cvar::exec("cl_name \"El Fede\"; r_fov 105; r_debug 1; seta bind_x salto");
	cvar::save_archived(cfg)!!;
	String text = (String)file::load_temp(cfg)!!;
	assert(text.contains("seta cl_name \"El Fede\""));
	assert(text.contains("seta bind_x \"salto\""));
	assert(!text.contains("r_debug"), "not archived");

	cvar::shutdown();
	start();
	assert(cvar::exec_file(cfg));
	assert(cvar::find("cl_name").str() == "El Fede");
	assert(cvar::find("r_fov").integer() == 105);
	assert(cvar::find("bind_x").flags.archive);
	assert(cvar::register("r_fov", "90", "").integer() == 105);

	assert(!cvar::exec_file("no_such_file_arena.cfg"), "missing file is fine");
	cvar::exec("exec no_such_file_arena.cfg");
	assert(output().contains("couldn't exec"));
}

fn void recursive_exec_stops() @test
{
	start();
	defer cvar::shutdown();
	String cfg = path::temp_directory(tmem)!!.tappend("arena_cvar_loop.cfg")!!;
	defer (void)file::delete(cfg);
	file::save(cfg, string::tformat("set n 1\nexec \"%s\"\n", cfg))!!;
	cvar::exec_file(cfg);
	assert(output().contains("nested too deep"));
}

fn void builtins_print() @test
{
	start();
	defer cvar::shutdown();
	cvar::register("r_fov", "90", "field of view", { .archive });
	cvar::exec("cvarlist r_; cmdlist se; help r_fov; help echo; help zz");
	String out = output();
	assert(out.contains("A     r_fov \"90\""), "got [%s]", out);
	assert(out.contains("1 cvars"));
	assert(out.contains("set - ") && out.contains("seta - ") && out.contains("2 commands"));
	assert(out.contains("r_fov is \"90\" (default \"90\") - field of view"));
	assert(out.contains("echo - echo <text...>"));
	assert(out.contains("nothing named \"zz\""));
}

fn void remove_command_works() @test
{
	start();
	defer cvar::shutdown();
	cvar::add_command("rec", &record_args, "record");
	assert(cvar::is_command("REC"));
	cvar::remove_command("rec");
	assert(!cvar::is_command("rec"));
	cvar::exec("rec");
	assert(output().contains("unknown command"));
}

// ---------------------------------------------------------------------------
// Console logic (no window needed).
module arena::console_test;
import arena::cvar, arena::console;

fn void scrollback_ring() @test
{
	Scrollback* sb = mem::new(Scrollback);
	defer free(sb);
	for (int i = 0; i < 600; i++) sb.add(string::tformat("line %d", i), 0);
	assert(sb.count == console::SCROLLBACK);
	assert(sb.line(0) == "line 599");
	assert(sb.line(console::SCROLLBACK - 1) == "line 88");

	sb.clear();
	DString long_text = dstring::temp();
	long_text.append_char_repeat('x', 400);
	sb.add(long_text.str_view(), 0);
	assert(sb.count == 3 && sb.line(2).len == console::LINE_CAP && sb.line(0).len == 80);

	sb.clear();
	DString accents = dstring::temp("a");
	for (int i = 0; i < 100; i++) accents.append("ñ");
	sb.add(accents.str_view(), 0);
	assert(sb.line(1).len == console::LINE_CAP - 1, "wrap must not split UTF-8");
	assert(sb.line(1).len + sb.line(0).len == 201);
}

fn void input_editing() @test
{
	InputLine in;
	in.insert("hola");
	in.left();
	in.left();
	in.insert_codepoint(0xF1);   // ñ
	assert(in.str() == "hoñla" && in.cursor == 4);
	in.left();
	assert(in.cursor == 2, "left skips the whole UTF-8 sequence");
	in.right();
	in.backspace();
	assert(in.str() == "hola" && in.cursor == 2);
	in.delete();
	assert(in.str() == "hoa");
	in.move_to(99);
	assert(in.cursor == 3);
	in.backspace();
	in.backspace();
	in.backspace();
	in.backspace();
	assert(in.str() == "" && in.cursor == 0);

	DString big = dstring::temp();
	big.append_char_repeat('z', 300);
	in.set(big.str_view());
	assert(in.len == console::INPUT_CAP && in.buf[in.len] == 0);
}

fn void history_browse() @test
{
	History h;
	InputLine in;
	h.add("map subte");
	h.add("name Fede");
	h.add("name Fede");
	h.add("");
	assert(h.count == 2, "skips empty lines and repeats");
	in.set("unfinished");
	h.older(&in);
	assert(in.str() == "name Fede");
	h.older(&in);
	h.older(&in);
	assert(in.str() == "map subte", "stays at the oldest");
	h.newer(&in);
	assert(in.str() == "name Fede");
	h.newer(&in);
	assert(in.str() == "unfinished", "back to the draft");
	h.newer(&in);
	assert(in.str() == "unfinished");
}

fn void completion_cycles() @test
{
	defer cvar::shutdown();
	cvar::register("r_fov", "90", "");
	cvar::register("r_fullbright", "0", "");
	cvar::register("sensitivity", "3", "");
	InputLine in;
	Completion c;

	in.set("echo x; set r_f");
	assert(c.begin(&in) && c.typed() == "r_f");
	c.apply(&in, cvar::complete(c.typed(), tmem), 1);
	assert(in.str() == "echo x; set r_fov", "got %s", in.str());
	assert(!c.begin(&in), "second Tab keeps cycling");
	c.apply(&in, cvar::complete(c.typed(), tmem), 1);
	assert(in.str() == "echo x; set r_fullbright");
	c.begin(&in);
	c.apply(&in, cvar::complete(c.typed(), tmem), 1);
	assert(in.str() == "echo x; set r_fov", "wraps");
	c.begin(&in);
	c.apply(&in, cvar::complete(c.typed(), tmem), -1);
	assert(in.str() == "echo x; set r_fullbright", "Shift+Tab goes back");

	in.set("SENS");
	assert(c.begin(&in), "editing starts over");
	c.apply(&in, cvar::complete(c.typed(), tmem), 1);
	assert(in.str() == "sensitivity ", "unique match completes with a space");
	assert(!c.active);

	in.set("zzz");
	c.begin(&in);
	c.apply(&in, cvar::complete(c.typed(), tmem), 1);
	assert(in.str() == "zzz");
}

fn void console_print_and_commands() @test
{
	defer cvar::shutdown();
	defer console::shutdown();
	console::init();
	assert(cvar::find("con_speed") != null && cvar::is_command("clear"));
	console::print("uno\ndos\r\n");
	assert(console::line_count() == 2 && console::line(0) == "dos");
	console::submit("/echo hola che");
	assert(console::line(1) == "]/echo hola che" && console::line(0) == "hola che");
	console::submit("clear");
	assert(console::line_count() == 0);
	cvar::exec("toggleconsole");
	assert(console::is_open() && console::wants_keyboard());
}
