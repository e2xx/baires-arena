module arena::hud_test;
import std::math, arena::defs, arena::snap, arena::world;
import arena::hud @public, arena::menu @public;

fn void add(Snapshot* s, int slot, String name, int frags, int deaths, char color = 0) @local
{
	PlayerSnap* p = &s.players[slot];
	p.active = true;
	p.name_len = (char)name.len;
	p.name_buf[:name.len] = name[..];
	p.frags = (short)frags;
	p.deaths = (short)deaths;
	p.color = color;
}

fn GameEvent event(EventKind kind, int a, int b = 0, int c = 0) @local => { 1, kind, (char)a, (char)b, (char)c, {}, {} };

// ---------------------------------------------------------------- hud: pure logic

fn void killfeed_ring_keeps_newest_five() @test
{
	KillFeed f;
	for (int i = 0; i < 7; i++) f.push({ .age = (float)i });
	assert(f.count == hud::KILLFEED_LINES);
	for (int i = 0; i < f.count; i++) assert(f.line(i).age == (float)(i + 2), "line %d is push #%d", i, i + 2);
}

fn void killfeed_expires_oldest_first() @test
{
	KillFeed f;
	f.push({});
	f.tick(2.0f);
	f.push({});
	f.tick(hud::KILLFEED_TIME - 1.0f);
	assert(f.count == 1, "the first line expired");
	assert(f.line(0).age == hud::KILLFEED_TIME - 1.0f);
	assert(f.line(0).alpha() == 1.0f);
	f.tick(0.5f);
	assert(f.line(0).alpha() > 0.4f && f.line(0).alpha() < 0.6f, "fades in its last second");
	f.tick(1.0f);
	assert(f.count == 0);
}

fn void kill_line_copies_names_and_spots_suicides() @test
{
	Snapshot s;
	add(&s, 0, "Fede", 0, 0, 2);
	add(&s, 3, "Pity", 0, 0, 1);
	GameEvent e = event(DEATH, 0, 3, Weapon.RAILGUN.ordinal);
	KillLine l = hud::kill_line(&e, &s, 0);
	assert(l.killer() == "Pity" && l.victim() == "Fede");
	assert(l.killer_color == 1 && l.victim_color == 2);
	assert(l.weapon == RAILGUN && !l.suicide && l.mine);

	e = event(DEATH, 3, defs::NO_PLAYER, Weapon.ROCKET.ordinal);
	l = hud::kill_line(&e, &s, 0);
	assert(l.suicide && !l.mine && l.killer_len == 0 && l.victim() == "Pity");

	e = event(DEATH, 3, 3, 200);
	l = hud::kill_line(&e, &s, 0);
	assert(l.suicide && l.weapon == MACHINEGUN, "bad weapon index falls back");
}

fn void ranking_sorts_and_shares_tied_ranks() @test
{
	Snapshot s;
	add(&s, 0, "Fede", 7, 4);
	add(&s, 2, "Pity", 9, 2);
	add(&s, 5, "Colo", 7, 6);
	add(&s, 6, "Nacho", 3, 8);
	add(&s, 9, "Tincho", 7, 1);
	ScoreRow[defs::MAX_PLAYERS] rows;
	int n = hud::rank_players(&s, &rows);
	assert(n == 5);
	char[5] slots = { 2, 9, 0, 5, 6 };
	int[5] ranks = { 1, 2, 2, 2, 5 };
	for (int i = 0; i < n; i++)
	{
		assert(rows[i].slot == slots[i], "row %d slot %d", i, rows[i].slot);
		assert(rows[i].rank == ranks[i], "row %d rank %d", i, rows[i].rank);
	}
	assert(hud::is_tied(rows[:n], 2) && !hud::is_tied(rows[:n], 1));
	assert(hud::find_row(rows[:n], 5).rank == 2);
	assert(hud::find_row(rows[:n], 4) == null);
}

fn void ranking_respects_output_size() @test
{
	Snapshot s;
	for (int i = 0; i < 6; i++) add(&s, i, "x", i, 0);
	ScoreRow[3] rows;
	assert(hud::rank_players(&s, &rows) == 3);
	assert(rows[0].frags == 2, "only the first three fit");
}

fn void clock_and_ordinals() @test
{
	assert(hud::fmt_clock(600.0f) == "10:00");
	assert(hud::fmt_clock(599.2f) == "10:00", "rounds up");
	assert(hud::fmt_clock(59.0f) == "0:59");
	assert(hud::fmt_clock(0.3f) == "0:01");
	assert(hud::fmt_clock(-4.0f) == "0:00");
	assert(hud::ordinal(1) == "1º" && hud::ordinal(12) == "12º");
	assert(hud::frag_sub(2, false, 7) == "2º con 7");
	assert(hud::frag_sub(1, true, 7) == "Empatado 1º con 7");
}

fn void copy_text_never_cuts_utf8() @test
{
	char[4] buf;
	assert(hud::copy_text(&buf, "ab") == 2);
	usz n = hud::copy_text(&buf, "abcñ");   // 'ñ' is 2 bytes: doesn't fit whole
	assert(n == 3 && (String)buf[:n] == "abc");
	n = hud::copy_text(&buf, "ñaña");
	assert(n == 3 && (String)buf[:n] == "ña");
}

fn void screen_angle_follows_view() @test
{
	Vec3 me = { 0, 0, 0 };
	float eps = 0.001f;
	assert(math::abs(hud::screen_angle(me, { 0, 0, 5 }, 0)) < eps, "ahead");
	assert(math::abs(hud::screen_angle(me, { -5, 0, 0 }, 0) - (float)math::PI / 2) < eps, "right of +Z is -X");
	assert(math::abs(math::abs(hud::screen_angle(me, { 0, 0, -5 }, 0)) - (float)math::PI) < eps, "behind");
	float yaw = (float)math::PI / 2;   // now looking at +X
	assert(math::abs(hud::screen_angle(me, { 5, 0, 0 }, yaw)) < eps);
}

fn void frag_alerts_fire_once_each() @test
{
	assert(hud::frags_alert(20, 14, 0) == 0);
	assert(hud::frags_alert(20, 15, 0) == 5);
	assert(hud::frags_alert(20, 15, 5) == 0, "already shown");
	assert(hud::frags_alert(20, 17, 5) == 3);
	assert(hud::frags_alert(20, 19, 3) == 1);
	assert(hud::frags_alert(20, 17, 1) == 0, "never goes back up");
	assert(hud::frags_alert(0, 99, 0) == 0, "no fraglimit");
}

// ---------------------------------------------------------------- hud: events

fn void frag_messages_name_both_sides() @test
{
	hud::init();
	Snapshot s;
	s.fraglimit = 20;
	s.local.slot = 0;
	add(&s, 0, "Fede", 7, 1);
	add(&s, 1, "Pity", 9, 0);
	add(&s, 2, "Colo", 7, 3);
	GameEvent e = event(DEATH, 2, 0, Weapon.ROCKET.ordinal);
	hud::on_event(&e, &s);
	assert(hud::state.feed.count == 1 && hud::state.feed.line(0).mine);
	assert(hud::state.center.main() == "Fragueaste a Colo", "got [%s]", hud::state.center.main());
	assert(hud::state.center.main()[hud::state.center.accent_from..] == "Colo");
	assert(hud::state.center.sub() == "Empatado 2º con 7");

	e = event(DEATH, 0, 1, Weapon.RAILGUN.ordinal);
	hud::on_event(&e, &s);
	assert(hud::state.center.main() == "Te fragueó Pity");
	assert(hud::state.flash == 1.0f);
	assert(hud::state.feed.count == 2);
}

fn void frag_alert_announces_leader() @test
{
	hud::init();
	Snapshot s;
	s.fraglimit = 10;
	s.local.slot = 0;
	add(&s, 0, "Fede", 0, 0);
	add(&s, 1, "Pity", 9, 0);
	GameEvent e = event(DEATH, 0, 1, 0);
	hud::on_event(&e, &s);
	assert(hud::state.announce.main() == "¡Queda 1 frag!");
}

fn void hits_accumulate_while_marker_shows() @test
{
	hud::init();
	Snapshot s;
	s.local.slot = 0;
	add(&s, 0, "Fede", 0, 0);
	for (int i = 0; i < 11; i++)
	{
		GameEvent e = event(HIT_CONFIRM, 0, 10);
		hud::on_event(&e, &s);
	}
	assert(hud::state.hit_damage == 110, "shotgun pellets add up");
	GameEvent other = event(HIT_CONFIRM, 3, 100);
	hud::on_event(&other, &s);
	assert(hud::state.hit_damage == 110, "someone else's hit");
}

fn void pain_pairs_with_nearby_blast() @test
{
	hud::init();
	Snapshot s;
	s.local.slot = 0;
	add(&s, 0, "Fede", 0, 0);
	GameEvent pain = event(PAIN, 0, 60);
	hud::on_event(&pain, &s);
	GameEvent far = event(EXPLOSION, 1);
	far.pos = { 40, 0, 0 };
	hud::on_event(&far, &s);
	assert(hud::state.arcs[0].left == 0, "a far blast isn't the source");
	GameEvent near = event(EXPLOSION, 1);
	near.pos = { -2, 1, 0 };
	hud::on_event(&near, &s);
	bool found;
	foreach (a : hud::state.arcs)
	{
		if (a.left > 0 && a.src == near.pos) found = true;
	}
	assert(found);
}

fn void pickup_shows_item_name() @test
{
	hud::init();
	Snapshot s;
	s.local.slot = 0;
	GameEvent e = event(PICKUP, 0, ItemKind.MEGA.ordinal);
	hud::on_event(&e, &s);
	assert(hud::state.pickup.main() == "Mega salud");
	hud::center_print("Quedan 5 frags", 2.0f);
	assert(hud::state.center.main() == "Quedan 5 frags");
}

fn void crosshair_style_is_clamped() @test
{
	hud::init();
	hud::set_crosshair(99);
	assert(hud::state.crosshair == CIRCLE);
	hud::set_crosshair(-3);
	assert(hud::state.crosshair == CROSS);
	hud::set_crosshair(2);
	hud::reset();
	assert(hud::state.crosshair == DOT, "reset keeps the player's crosshair");
}

// ---------------------------------------------------------------- menu: settings & text fields

fn void settings_snap_and_describe() @test
{
	assert(Setting.VOLUME.nudge(0.8f, 1) == Setting.VOLUME.snap(0.85f));
	assert(Setting.VOLUME.nudge(1.0f, 1) == 1.0f, "clamped");
	assert(Setting.FRAGLIMIT.nudge(20, -1) == 15.0f);
	assert(Setting.FRAGLIMIT.at(0.5f) == 50.0f);
	assert(Setting.FOV.snap(90.4f) == 90.0f);
	assert(Setting.BOTS.max == (float)(defs::MAX_PLAYERS - 1));
	assert(Setting.BOTS.describe(0) == "Ninguno" && Setting.BOTS.describe(1) == "1 bot" && Setting.BOTS.describe(4) == "4 bots");
	assert(Setting.FRAGLIMIT.describe(0) == "Sin límite");
	assert(Setting.TIMELIMIT.describe(10) == "10 min");
	assert(Setting.VOLUME.describe(0.8f) == "80%");
	assert(Setting.FOV.describe(90) == "90°");
	assert(Setting.BOT_SKILL.describe(0) == "Turista" && Setting.BOT_SKILL.describe(1) == "Leyenda");
}

fn void text_edit_inserts_at_caret_within_capacity() @test
{
	char[6] buf;
	TextEdit e = { &buf, 0, 0, NAME };
	assert(e.insert('P') && e.insert('t') && e.insert('y'));
	e.left();
	e.left();
	assert(e.insert('i'));
	assert(e.str() == "Pity" && e.caret == 2);
	e.end();
	assert(e.insert(0xF1), "ñ");
	assert(e.str() == "Pityñ" && e.len == 6);
	assert(!e.insert('x'), "full");
	assert(!e.insert(0x263A), "outside the font");
	assert(!e.insert('\n'));
}

fn void text_edit_removes_whole_characters() @test
{
	char[16] buf;
	TextEdit e = { &buf, 0, 0, NAME };
	foreach (cp : (int[*]){ 'a', 0xF1, 'o' }) e.insert(cp);
	assert(e.str() == "año");
	e.left();
	assert(e.caret == 3, "skips 'o'");
	e.left();
	assert(e.caret == 1, "steps over the two bytes of ñ");
	assert(e.delete() && e.str() == "ao");
	e.end();
	e.left();
	assert(e.backspace() && e.str() == "o" && e.caret == 0);
	assert(!e.backspace());
	e.home();
	assert(e.delete() && e.len == 0 && !e.delete());
}

fn void address_field_filters_characters() @test
{
	char[64] buf;
	TextEdit e = { &buf, 0, 0, ADDRESS };
	foreach (c : "10.0.0.7:27960 x") e.insert(c);
	assert(e.str() == "10.0.0.7:27960x");
	assert(!e.insert(0xF1), "no ñ in addresses");
}

fn void default_options_are_sane() @test
{
	Options o = menu::default_options();
	assert(o.player_name() == "Jugador");
	assert(o.fraglimit == defs::DEFAULT_FRAGLIMIT && o.timelimit == defs::DEFAULT_TIMELIMIT_MIN);
	assert(o.server_address() == "");
	LanServer l;
	l.name[:4] = "Pity"[..];
	assert(l.title() == "Pity");
}

// ---------------------------------------------------------------- menu: navigation

fn void navigation_wraps() @test
{
	MenuState m;
	m.reset(MAIN);
	m.count = 5;
	assert(m.navigate(UP) == NONE && m.focus == 4, "wraps to the bottom");
	m.navigate(DOWN);
	assert(m.focus == 0);
	m.navigate(DOWN);
	m.navigate(DOWN);
	assert(m.focus == 2 && m.sound == MOVE);
	assert(menu::wrap(-1, 0) == 0);
}

fn void sub_screens_restore_focus() @test
{
	MenuState m;
	m.reset(MAIN);
	m.count = 5;
	m.focus = 3;
	m.push(OPTIONS);
	assert(m.screen() == OPTIONS && m.focus == 0 && m.sound == SELECT);
	m.count = 7;
	m.navigate(DOWN);
	assert(m.navigate(BACK) == NONE);
	assert(m.screen() == MAIN && m.focus == 3, "back where we left");
	assert(m.open);
}

fn void escape_on_roots() @test
{
	MenuState m;
	m.reset(MAIN);
	m.count = 5;
	assert(m.navigate(BACK) == NONE && m.focus == 4 && m.open, "main menu: walk to Salir");

	m.reset(PAUSE);
	m.push(OPTIONS);
	assert(m.navigate(BACK) == NONE && m.screen() == PAUSE);
	assert(m.navigate(BACK) == RESUME && !m.open, "pause root resumes");
}

fn void join_screen_asks_for_refresh() @test
{
	MenuState m;
	m.reset(MAIN);
	assert(m.pending == NONE);
	m.push(JOIN);
	assert(m.pending == REFRESH_LAN);
	for (int i = 0; i < menu::MAX_DEPTH + 2; i++) m.push(PLAY);
	assert(m.depth == menu::MAX_DEPTH, "stack is bounded");
}

fn void module_api_and_sound_queue() @test
{
	menu::open(PAUSE);
	assert(menu::is_open());
	menu::menu.count = 4;
	menu::menu.navigate(DOWN);
	assert(menu::take_sound() == MOVE);
	assert(menu::take_sound() == NONE, "taken once");
	menu::close();
	assert(!menu::is_open());
}
