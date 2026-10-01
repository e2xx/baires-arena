// Baires Arena — entry point and application flow (menu ⇄ game, dedicated server).
module arena;
import std::io, std::math, std::thread, std::time::clock, raylib6;
import arena::defs, arena::cvar, arena::console, arena::audio, arena::hud, arena::menu, arena::textures;
import arena::session, arena::server, arena::client, arena::udp, arena::map, arena::world, arena::bots;

const String VERSION = "Baires Arena 0.1 · C3";
const String DEFAULT_MAP = "subte";
const String[*] MAP_IDS = { "subte", "obelisco", "puerto", "dev" };
const int MAX_LAN = 16;
const float LAN_REFRESH = 3.0f;

struct App
{
	Session* game;
	Session* attract;
	bool quit;
	bool dedicated;
	Server* dedicated_server;
	Map* dedicated_map;
	Bots* dedicated_bots;
	Options opt;

	UdpSock lan_sock;
	bool lan_open;
	LanInfo[MAX_LAN] lan_info;
	int lan_count;
	float lan_timer;

	Cvar* name;
	Cvar* color;
	Cvar* sensitivity;
	Cvar* fov;
	Cvar* volume;
	Cvar* fraglimit;
	Cvar* timelimit;
	Cvar* port;
	Cvar* hostname;
	Cvar* exposure;
	Cvar* bot_count;
	Cvar* bot_skill;
	Cvar* last_server;
}

App app;

extern fn uint time_begin_period(uint ms) @cname("timeBeginPeriod") @feat(WIN32);

// ---------------------------------------------------------------- options ⇄ cvars

fn void options_from_cvars()
{
	Options* o = &app.opt;
	*o = menu::default_options();
	o.name_len = hud::copy_text(&o.name, app.name.str());
	o.color = (char)math::clamp(app.color.integer(), 0, (int)PlayerColor::len - 1);
	o.sensitivity = app.sensitivity.num();
	o.fov = app.fov.num();
	o.volume = app.volume.num();
	o.bots = app.bot_count.integer();
	o.bot_skill = app.bot_skill.num();
	o.fraglimit = app.fraglimit.integer();
	o.timelimit = app.timelimit.integer();
	o.address_len = hud::copy_text(&o.address, app.last_server.str());
}

fn void options_to_cvars() => @pool()
{
	Options* o = &app.opt;
	app.name.set(o.player_name());
	app.color.set_int(o.color);
	app.sensitivity.set_float(o.sensitivity);
	app.fov.set_float(o.fov);
	app.volume.set_float(o.volume);
	app.bot_count.set_int(o.bots);
	app.bot_skill.set_float(o.bot_skill);
	app.fraglimit.set_int(o.fraglimit);
	app.timelimit.set_int(o.timelimit);
	app.last_server.set(o.server_address());
	audio::set_master(o.volume);
}

// ---------------------------------------------------------------- sessions

fn ServerConfig server_config()
{
	return {
		.name = app.hostname.str(),
		.port = (ushort)app.port.integer(),
		.fraglimit = app.fraglimit.integer() == 0 ? -1 : app.fraglimit.integer(),
		.timelimit_min = app.timelimit.integer() == 0 ? -1 : app.timelimit.integer(),
	};
}

fn void end_game()
{
	if (app.game == null) return;
	app.game.free();
	app.game = null;
}

fn void end_attract()
{
	if (app.attract == null) return;
	app.attract.free();
	app.attract = null;
}

fn void start_game(Session* s)
{
	end_game();
	end_attract();
	app.game = s;
	app.game.printer = &console::print;
	menu::close();
	audio::music(false);
	hud::reset();
	rl::disable_cursor();
	// Bots join games we own (offline or hosting).
	World* w = s.authority();
	if (w == null) return;
	if (s.mode == OFFLINE)
	{
		w.fraglimit = app.fraglimit.integer() <= 0 ? 1000 : app.fraglimit.integer();
		w.timelimit = (float)math::max(app.timelimit.integer(), 0) * 60.0f;
	}
	bots::attach(s, app.bot_count.integer(), app.bot_skill.num());
}

// Runs a session constructor and switches to it, or reports why it failed.
macro void @launch(#make)
{
	Session*? s = #make;
	if (catch err = s)
	{
		cvar::printf("no se pudo iniciar: %s", err);
		return;
	}
	start_game(s);
}

fn void back_to_menu()
{
	end_game();
	rl::enable_cursor();
	menu::open(MAIN);
	audio::music(true);
	if (app.attract != null) return;
	Session*? a = session::start_attract(DEFAULT_MAP);
	if (catch a) return;
	app.attract = a;
	app.attract.printer = &console::print;
	bots::attach(a, 6, 0.6f);
}

// ---------------------------------------------------------------- console commands

fn String map_arg(String[] args) => args.len > 1 ? args[1] : DEFAULT_MAP;

// map <id>: change map if hosting, otherwise start an offline game there.
fn void cmd_map(String[] args, void* ctx)
{
	if (app.dedicated)
	{
		Map*? m = session::load_map(map_arg(args));
		if (catch m) return;
		app.dedicated_server.change_map(m, map_arg(args));
		app.dedicated_map.free();
		app.dedicated_map = m;
		bots::readd(app.dedicated_bots, app.dedicated_server.world(), m);
		return;
	}
	if (app.game != null && app.game.mode != REMOTE)
	{
		if (catch err = app.game.change_map(map_arg(args)))
		{
			cvar::printf("no se pudo cargar '%s'", map_arg(args));
			return;
		}
		bots::attach(app.game, app.bot_count.integer(), app.bot_skill.num());
		return;
	}
	@launch(session::start_offline(map_arg(args), app.name.str(), (char)app.color.integer()));
}

fn void cmd_host(String[] args, void* ctx)
{
	@launch(session::start_host(map_arg(args), app.name.str(), (char)app.color.integer(), server_config()));
}

fn void cmd_connect(String[] args, void* ctx)
{
	if (args.len < 2)
	{
		cvar::print("uso: connect <ip[:puerto]>");
		return;
	}
	app.last_server.set(args[1]);
	@launch(session::start_remote(args[1], app.name.str(), (char)app.color.integer()));
}

fn void cmd_disconnect(String[] args, void* ctx)
{
	if (app.dedicated) return;
	back_to_menu();
}

fn void cmd_addbot(String[] args, void* ctx)
{
	int n = args.len > 1 ? (int)args[1].to_int() ?? 1 : 1;
	if (app.dedicated)
	{
		bots::add(app.dedicated_bots, app.dedicated_server.world(), n, app.bot_skill.num());
		return;
	}
	if (app.game == null || app.game.authority() == null)
	{
		cvar::print("solo el anfitrión puede agregar bots");
		return;
	}
	bots::attach(app.game, n + bots::count(app.game), app.bot_skill.num());
}

fn void cmd_say(String[] args, void* ctx) => @pool()
{
	if (app.game == null || app.game.net == null || args.len < 2) return;
	DString msg;
	foreach (i, a : args[1..])
	{
		if (i > 0) msg.append(" ");
		msg.append(a);
	}
	(void)app.game.net.say(msg.str_view());
}

fn void cmd_quit(String[] args, void* ctx) => app.quit = true;

fn void register_all()
{
	cvar::init();
	CvarFlags keep = { .archive = true };
	CvarFlags srv = { .archive = true, .server = true };
	app.name = cvar::register("name", "Jugador", "tu nombre", keep);
	app.color = cvar::register("color", "0", "color del jugador (0-7)", keep);
	app.sensitivity = cvar::register("sensitivity", "3", "sensibilidad del mouse (escala Quake III)", keep);
	app.fov = cvar::register("fov", "100", "campo visual horizontal (grados)", keep);
	app.volume = cvar::register("s_volume", "0.8", "volumen general", keep);
	app.exposure = cvar::register("r_exposure", "1.35", "brillo general de la escena", keep);
	app.fraglimit = cvar::register("fraglimit", "20", "frags para ganar (0 = sin límite)", srv);
	app.timelimit = cvar::register("timelimit", "10", "minutos por partida (0 = sin límite)", srv);
	app.port = cvar::register("port", "27960", "puerto UDP del servidor", srv);
	app.hostname = cvar::register("hostname", "Baires Arena", "nombre del servidor en la LAN", srv);
	app.bot_count = cvar::register("bot_count", "5", "bots al iniciar una partida", srv);
	app.bot_skill = cvar::register("bot_skill", "0.5", "habilidad de los bots (0-1)", srv);
	app.last_server = cvar::register("cl_lastserver", "", "último servidor al que te conectaste", keep);
	cvar::add_command("map", &cmd_map, "map <id>: jugar (o cambiar de mapa si sos anfitrión)");
	cvar::add_command("host", &cmd_host, "host <id>: crear partida LAN");
	cvar::add_command("connect", &cmd_connect, "connect <ip[:puerto]>: unirse a una partida");
	cvar::add_command("disconnect", &cmd_disconnect, "volver al menú");
	cvar::add_command("addbot", &cmd_addbot, "addbot [n]: sumar bots");
	cvar::add_command("say", &cmd_say, "say <texto>: chat");
	cvar::add_command("quit", &cmd_quit, "salir del juego");
}

<*
 Quake-style command line: "+map subte +set fraglimit 30" runs each "+" group as a command.
*>
fn void exec_plus_args(String[] argv) => @pool()
{
	DString line;
	foreach (a : argv[1..])
	{
		if (a.starts_with("--")) continue;
		if (a.starts_with("+"))
		{
			if (line.len() > 0) cvar::exec(line.str_view());
			line.clear();
			line.append(a[1..]);
			continue;
		}
		line.append(" ");
		line.append(a);
	}
	if (line.len() > 0) cvar::exec(line.str_view());
}

fn bool has_flag(String[] argv, String flag)
{
	foreach (a : argv)
	{
		if (a == flag) return true;
	}
	return false;
}

// ---------------------------------------------------------------- LAN browser

fn void lan_refresh()
{
	if (!app.lan_open)
	{
		UdpSock? s = udp::open(0, true);
		if (catch s) return;
		app.lan_sock = s;
		app.lan_open = true;
	}
	app.lan_count = 0;
	app.lan_timer = LAN_REFRESH;
	client::lan_query(&app.lan_sock);
}

fn int lan_poll(LanServer[] out, float dt)
{
	if (!app.lan_open) return 0;
	app.lan_count = client::lan_collect(&app.lan_sock, app.lan_info[..], app.lan_count);
	app.lan_timer -= dt;
	if (app.lan_timer <= 0) lan_refresh();
	int n = math::min(app.lan_count, (int)out.len);
	for (int i = 0; i < n; i++)
	{
		LanInfo* in = &app.lan_info[i];
		out[i] = { in.name, in.map, in.address, in.players, in.max_players, in.ping_ms };
	}
	return n;
}

// ---------------------------------------------------------------- menu

fn void play_menu_sound()
{
	switch (menu::take_sound())
	{
		case MOVE: audio::play(MENU_MOVE, 0.5f);
		case SELECT: audio::play(MENU_SELECT, 0.7f);
		case NONE: break;
	}
}

fn void on_menu_action(Action a)
{
	options_to_cvars();
	String map_id = MAP_IDS[math::clamp(app.opt.map_index, 0, (int)MAP_IDS.len - 1)];
	switch (a)
	{
		case START_OFFLINE:
			@launch(session::start_offline(map_id, app.name.str(), (char)app.color.integer()));
		case HOST_GAME:
			@launch(session::start_host(map_id, app.name.str(), (char)app.color.integer(), server_config()));
		case JOIN_GAME:
			app.last_server.set(app.opt.server_address());
			@launch(session::start_remote(app.opt.server_address(), app.name.str(), (char)app.color.integer()));
		case REFRESH_LAN:
			lan_refresh();
		case RESUME:
			menu::close();
			rl::disable_cursor();
		case DISCONNECT:
			back_to_menu();
		case QUIT:
			app.quit = true;
		case NONE:
			break;
	}
}

// ---------------------------------------------------------------- dedicated server

fn int run_dedicated(String[] argv)
{
	app.dedicated = true;
	$if env::WIN32:
		time_begin_period(1);
	$endif
	cvar::exec_file("server.cfg");
	String id = DEFAULT_MAP;
	for (sz i = 1; i + 1 < argv.len; i++)
	{
		if (argv[i] == "+map") id = argv[i + 1];
	}
	Map*? m = session::load_map(id);
	if (catch m) return 1;
	app.dedicated_map = m;
	ServerConfig cfg = server_config();
	cfg.map_id = id;
	Server*? srv = server::start(cfg, m);
	if (catch err = srv)
	{
		io::eprintfn("no se pudo abrir el puerto: %s", err);
		return 1;
	}
	app.dedicated_server = srv;
	app.dedicated_bots = bots::create(m);
	srv.set_tick_hook(&bots::tick, app.dedicated_bots);
	io::printfn("%s · servidor dedicado · mapa %s · puerto %d", VERSION, id, srv.port());
	bots::add(app.dedicated_bots, srv.world(), app.bot_count.integer(), app.bot_skill.num());

	Clock clk = clock::now();
	while (!app.quit)
	{
		float dt = (float)clk.mark().to_sec();
		app.dedicated_server.frame(dt);
		thread::sleep_ms(1);
	}
	app.dedicated_server.stop();
	bots::destroy(app.dedicated_bots);
	app.dedicated_map.free();
	return 0;
}

// ---------------------------------------------------------------- client

fn void draw_status(Session* s, int w, int h)
{
	String status = s.status();
	if (status.len == 0) return;
	ZString z = string::tformat_zstr("%s", status);
	hud::text(z, (float)w / 2.0f, (float)h / 2.0f, 40, rl::RAYWHITE, CENTER);
}

fn void clear_to_sky(Session* s)
{
	if (s == null || !s.loaded) return;
	Vec3 sky = s.map.sky;
	rl::clear_background({ (char)(sky.x * 255), (char)(sky.y * 255), (char)(sky.z * 255), 255 });
}

fn void run_session(Session* s, float dt, bool input, int w, int h)
{
	if (s.loaded) s.gfx.exposure = app.exposure.num();
	s.cg.sensitivity = app.sensitivity.num();
	s.cg.fov = app.fov.num();
	s.cg.show_scores = input && rl::is_key_down(RLKeyboardKey.TAB);
	s.frame(dt, input, w, h);
}

fn int main(String[] argv)
{
	register_all();
	defer cvar::shutdown();
	if (has_flag(argv, "--dedicated")) return run_dedicated(argv);

	rl::set_config_flags(RLConfigFlag.MSAA_4X_HINT | RLConfigFlag.VSYNC_HINT | RLConfigFlag.WINDOW_RESIZABLE);
	rl::set_trace_log_level(RLTraceLogLevel.WARNING);
	rl::init_window(1600, 900, "Baires Arena");
	defer rl::close_window();
	rl::set_exit_key(NONE);
	rl::init_audio_device();
	defer rl::close_audio_device();

	console::init();
	defer console::shutdown();
	cvar::exec_file("autoexec.cfg");
	audio::init();
	defer audio::shutdown();
	textures::load_all();
	defer textures::unload_all();
	hud::init();
	cvar::print(VERSION);
	options_from_cvars();
	audio::set_master(app.opt.volume);

	exec_plus_args(argv);
	if (app.game == null) back_to_menu();
	defer
	{
		end_game();
		end_attract();
		if (app.lan_open) app.lan_sock.close();
	}

	LanServer[MAX_LAN] lan;
	String[MAP_IDS.len] maps;
	foreach (i, id : MAP_IDS) maps[i] = id;

	while (!rl::window_should_close() && !app.quit)
	{
		@pool()
		{
			float dt = math::min(rl::get_frame_time(), 0.1f);
			console::update(dt);
			audio::update();
			int w = rl::get_screen_width();
			int h = rl::get_screen_height();
			bool typing = console::wants_keyboard();

			// Esc in game opens the pause menu (the menu handles Esc itself once open).
			if (app.game != null && !menu::is_open() && !typing && rl::is_key_pressed(RLKeyboardKey.ESCAPE))
			{
				menu::open(PAUSE);
				rl::enable_cursor();
			}
			if (app.game != null && app.game.dead_link())
			{
				cvar::printf("desconectado: %s", app.game.status());
				back_to_menu();
			}

			bool input = !typing && !menu::is_open() && rl::is_window_focused();
			Session* s = app.game != null ? app.game : app.attract;

			rl::begin_drawing();
			rl::clear_background({ 6, 8, 12, 255 });
			clear_to_sky(s);
			if (s != null)
			{
				run_session(s, dt, input && s == app.game, w, h);
				if (s == app.game) draw_status(s, w, h);
			}
			if (menu::is_open())
			{
				int lan_n = lan_poll(lan[..], dt);
				Action a = menu::update_draw(&app.opt, lan[:lan_n], maps[..], w, h);
				play_menu_sound();
				if (a != NONE) on_menu_action(a);
			}
			console::draw_notify(w, (float)rl::get_time());
			console::draw(w, h);
			rl::end_drawing();
		};
	}
	options_to_cvars();
	(void)cvar::save_archived("autoexec.cfg");
	return 0;
}
