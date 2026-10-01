// Baires Arena — entry point and application state.
module arena;
import std::io, std::math, std::thread, std::time::clock, raylib6;
import arena::defs, arena::cvar, arena::console, arena::audio, arena::hud, arena::textures;
import arena::session, arena::server, arena::map, arena::world;

const String VERSION = "Baires Arena 0.1 · C3";
const String DEFAULT_MAP = "dev";

struct App
{
	Session* game;
	bool quit;
	bool dedicated;
	Server* dedicated_server;
	Map* dedicated_map;
	Cvar* name;
	Cvar* color;
	Cvar* sensitivity;
	Cvar* fov;
	Cvar* fraglimit;
	Cvar* timelimit;
	Cvar* port;
	Cvar* hostname;
}

App app;

extern fn uint time_begin_period(uint ms) @cname("timeBeginPeriod") @feat(WIN32);

// ---------------------------------------------------------------- commands

fn ServerConfig server_config()
{
	return {
		.name = app.hostname.str(),
		.port = (ushort)app.port.integer(),
		.fraglimit = app.fraglimit.integer(),
		.timelimit_min = app.timelimit.integer(),
	};
}

fn void end_game()
{
	if (app.game == null) return;
	app.game.free();
	app.game = null;
}

fn void start_game(Session* s)
{
	end_game();
	app.game = s;
	app.game.printer = &console::print;
	rl::disable_cursor();
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

// map <id>: change map if hosting, otherwise start an offline game there.
fn void cmd_map(String[] args, void* ctx)
{
	if (args.len < 2)
	{
		cvar::print("uso: map <subte|obelisco|puerto|dev>");
		return;
	}
	if (app.dedicated)
	{
		Map*? m = session::load_map(args[1]);
		if (catch m) return;
		app.dedicated_server.change_map(m, args[1]);
		app.dedicated_map.free();
		app.dedicated_map = m;
		return;
	}
	if (app.game != null && app.game.mode != REMOTE)
	{
		if (catch err = app.game.change_map(args[1])) cvar::printf("no se pudo cargar '%s'", args[1]);
		return;
	}
	@launch(session::start_offline(args[1], app.name.str(), (char)app.color.integer()));
}

fn void cmd_host(String[] args, void* ctx)
{
	String id = args.len > 1 ? args[1] : DEFAULT_MAP;
	@launch(session::start_host(id, app.name.str(), (char)app.color.integer(), server_config()));
}

fn void cmd_connect(String[] args, void* ctx)
{
	if (args.len < 2)
	{
		cvar::print("uso: connect <ip[:puerto]>");
		return;
	}
	@launch(session::start_remote(args[1], app.name.str(), (char)app.color.integer()));
}

fn void cmd_disconnect(String[] args, void* ctx) => end_game();

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
	app.name = cvar::register("name", "Jugador", "tu nombre", { .archive = true });
	app.color = cvar::register("color", "0", "color del jugador (0-7)", { .archive = true });
	app.sensitivity = cvar::register("sensitivity", "1.0", "sensibilidad del mouse", { .archive = true });
	app.fov = cvar::register("fov", "100", "campo visual horizontal (grados)", { .archive = true });
	app.fraglimit = cvar::register("fraglimit", "20", "frags para ganar", { .archive = true, .server = true });
	app.timelimit = cvar::register("timelimit", "10", "minutos por partida", { .archive = true, .server = true });
	app.port = cvar::register("port", "27960", "puerto UDP del servidor", { .archive = true, .server = true });
	app.hostname = cvar::register("hostname", "Baires Arena", "nombre del servidor en la LAN", { .archive = true, .server = true });
	cvar::add_command("map", &cmd_map, "map <id>: jugar (o cambiar de mapa si sos anfitrión)");
	cvar::add_command("host", &cmd_host, "host <id>: crear partida LAN");
	cvar::add_command("connect", &cmd_connect, "connect <ip[:puerto]>: unirse a una partida");
	cvar::add_command("disconnect", &cmd_disconnect, "salir de la partida");
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
	io::printfn("%s · servidor dedicado · mapa %s · puerto %d", VERSION, id, srv.port());

	Clock clk = clock::now();
	while (!app.quit)
	{
		float dt = (float)clk.mark().to_sec();
		app.dedicated_server.frame(dt);
		thread::sleep_ms(1);
	}
	app.dedicated_server.stop();
	app.dedicated_map.free();
	return 0;
}

// ---------------------------------------------------------------- client

fn int main(String[] argv)
{
	register_all();
	defer cvar::shutdown();
	if (has_flag(argv, "--dedicated")) return run_dedicated(argv);

	rl::set_config_flags(RLConfigFlag.MSAA_4X_HINT | RLConfigFlag.VSYNC_HINT | RLConfigFlag.WINDOW_RESIZABLE);
	rl::set_trace_log_level(RLTraceLogLevel.WARNING);
	rl::init_window(1600, 900, "Baires Arena");
	defer rl::close_window();
	rl::set_exit_key((RLKeyboardKey)0);
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

	exec_plus_args(argv);
	if (app.game == null) cvar::exec(string::tformat("map %s", DEFAULT_MAP));
	defer end_game();

	while (!rl::window_should_close() && !app.quit)
	{
		@pool()
		{
			float dt = math::min(rl::get_frame_time(), 0.1f);
			console::update(dt);
			audio::update();
			bool input = !console::wants_keyboard() && rl::is_window_focused();
			if (input && rl::is_key_pressed(RLKeyboardKey.ESCAPE)) app.quit = true;

			int w = rl::get_screen_width();
			int h = rl::get_screen_height();
			rl::begin_drawing();
			rl::clear_background({ 6, 8, 12, 255 });
			Session* s = app.game;
			if (s != null)
			{
				s.cg.sensitivity = app.sensitivity.num();
				s.cg.fov = app.fov.num();
				s.cg.show_scores = input && rl::is_key_down(RLKeyboardKey.TAB);
				if (s.loaded)
				{
					Vec3 sky = s.map.sky;
					rl::clear_background({ (char)(sky.x * 255), (char)(sky.y * 255), (char)(sky.z * 255), 255 });
				}
				s.frame(dt, input, w, h);
				String status = s.status();
				if (status.len > 0)
				{
					ZString z = string::tformat_zstr("%s", status);
					rl::draw_text(z, (w - rl::measure_text(z, 32)) / 2, h / 2, 32, rl::RAYWHITE);
				}
			}
			console::draw_notify(w, (float)rl::get_time());
			console::draw(w, h);
			rl::end_drawing();
		};
	}
	(void)cvar::save_archived("autoexec.cfg");
	return 0;
}
