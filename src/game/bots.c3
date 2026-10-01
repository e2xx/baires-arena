// Bot roster for a World: owns the nav graph and one Bot brain per bot slot.
// Plugged into the simulation through the per-tick hook (server or offline session).
module arena::bots;
import std::math, std::io, arena::defs, arena::map, arena::world, arena::nav, arena::bot, arena::session;

struct Bots
{
	Map* map;
	NavGraph* nav;
	Bot[defs::MAX_PLAYERS] brains;
	bool[defs::MAX_PLAYERS] used;
	uint seq;
	int named;
}

fn Bots* create(Map* m)
{
	Bots* b = mem::new(Bots);
	b.map = m;
	b.nav = nav::build(m);
	return b;
}

fn void destroy(Bots* b)
{
	if (b == null) return;
	b.nav.free();
	free(b);
}

fn int Bots.count(&self)
{
	int n;
	foreach (u : self.used)
	{
		if (u) n++;
	}
	return n;
}

<*
 Adds `n` bots to the world with Argentine nicknames and rotating colours.
*>
fn void add(Bots* b, World* w, int n, float skill)
{
	for (int i = 0; i < n; i++)
	{
		int k = b.named++;
		char color = (char)((k + 1) % (int)PlayerColor::len);
		int slot = w.add_player(bot::bot_name(k), color, true);
		if (slot < 0) return;
		b.used[slot] = true;
		// Some spread in skill so every bot doesn't play the same.
		float s = math::clamp(skill + (float)((k * 37) % 21 - 10) * 0.012f, 0.0f, 1.0f);
		b.brains[slot].init(slot, s, 0xB07 + (uint)k * 7919);
	}
}

<*
 After a map change: rebuild navigation and put the same number of bots back.
*>
fn void readd(Bots* b, World* w, Map* m)
{
	int n = b.count();
	b.nav.free();
	b.map = m;
	b.nav = nav::build(m);
	b.used = {};
	b.named = 0;
	add(b, w, n, 0.5f);
}

fn void tick(World* w, void* ctx)
{
	Bots* b = ctx;
	b.seq++;
	for (int i = 0; i < defs::MAX_PLAYERS; i++)
	{
		if (!b.used[i]) continue;
		if (!w.players[i].active || !w.players[i].is_bot)
		{
			b.used[i] = false;
			continue;
		}
		w.run_cmd(i, b.brains[i].think(w, b.nav, b.seq));
	}
}

// ---------------------------------------------------------------- session glue

<*
 Makes sure the session's world has `total` bots, creating the roster on first use.
 Sessions without an authoritative world (remote clients) are left alone.
*>
fn void attach(Session* s, int total, float skill)
{
	World* w = s.authority();
	if (w == null) return;
	Bots* b = s.bot_ctx;
	Map* m = s.authority_map();
	if (b != null && b.map != m)
	{
		destroy(b);
		b = null;
	}
	if (b == null)
	{
		b = create(m);
		s.set_bot_hook(&tick, b);
		s.bot_cleanup = &release;
	}
	int missing = total - b.count();
	if (missing > 0) add(b, w, missing, skill);
}

fn void release(void* ctx) => destroy((Bots*)ctx);

fn int count(Session* s)
{
	Bots* b = s.bot_ctx;
	return b == null ? 0 : b.count();
}
