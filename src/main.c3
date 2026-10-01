// Baires Arena — entry point.
module arena;
import std::io, std::math, raylib6;
import arena::defs, arena::cvar, arena::console, arena::audio, arena::hud, arena::textures, arena::session;

const String VERSION = "Baires Arena 0.1 · C3";

struct Args
{
	String map;
}

fn Args parse_args(String[] argv)
{
	Args a = { .map = "dev" };
	for (sz i = 1; i < argv.len; i++)
	{
		if (argv[i] == "--map" && i + 1 < argv.len) a.map = argv[++i];
	}
	return a;
}

bool quit_requested;

fn void cmd_quit(String[] args, void* ctx) => quit_requested = true;

fn int main(String[] argv)
{
	Args args = parse_args(argv);
	cvar::init();
	defer cvar::shutdown();
	Cvar* sens = cvar::register("sensitivity", "1.0", "sensibilidad del mouse", { .archive = true });
	Cvar* fov = cvar::register("fov", "100", "campo visual horizontal (grados)", { .archive = true });
	Cvar* name = cvar::register("name", "Jugador", "tu nombre", { .archive = true });
	cvar::add_command("quit", &cmd_quit, "salir del juego");

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

	Session*? s = session::start_offline(args.map, name.str(), 0);
	if (catch err = s)
	{
		io::eprintfn("no se pudo cargar el mapa '%s': %s", args.map, err);
		return 1;
	}
	defer s.free();
	rl::disable_cursor();

	while (!rl::window_should_close() && !quit_requested)
	{
		@pool()
		{
			float dt = math::min(rl::get_frame_time(), 0.1f);
			console::update(dt);
			bool input = !console::wants_keyboard() && rl::is_window_focused();
			if (input && rl::is_key_pressed(RLKeyboardKey.ESCAPE)) quit_requested = true;
			s.cg.sensitivity = sens.num();
			s.cg.fov = fov.num();
			s.cg.show_scores = input && rl::is_key_down(RLKeyboardKey.TAB);

			int w = rl::get_screen_width();
			int h = rl::get_screen_height();
			Vec3 sky = s.map.sky;
			rl::begin_drawing();
			rl::clear_background({ (char)(sky.x * 255), (char)(sky.y * 255), (char)(sky.z * 255), 255 });
			s.frame(dt, input, w, h);
			console::draw_notify(w, (float)rl::get_time());
			console::draw(w, h);
			rl::end_drawing();
		};
	}
	(void)cvar::save_archived("autoexec.cfg");
	return 0;
}
