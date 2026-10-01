// Bot AI. A bot reads the World (never writes it) and drives its player only through the
// UserCmd returned by think(), exactly like a human client: fair and network transparent.
module arena::bot;
import std::math, std::collections::list;
import arena::mathx, arena::defs, arena::map, arena::world, arena::nav;

const int MAX_PATH = 256;
const float NODE_REACH = 0.7f;       // horizontal distance that counts as "at the node"
const float NODE_HEIGHT = 1.2f;
const float PAD_REACH = 1.3f;        // pad half size + hull: the pad fires this far out
const float PASS_RADIUS = 1.6f;      // a walk node behind us this close counts as passed
const float LOOK_AHEAD = 1.4f;       // start turning toward the next node this early
const float JUMP_TRIGGER = 0.3f;     // jump this close to the take-off node (or once past it)
const float BRAKE_DIST = 2.0f;       // slow to the take-off speed this far before a jump/drop
const float STUCK_INTERVAL = 1.0f;
const float STUCK_DIST = 0.75f;
const float UNSTICK_TIME = 0.5f;
const int STUCK_REPATH = 2;
const float GOAL_INTERVAL = 3.0f;
const float GOAL_SPREAD = 0.4f;      // rethink every GOAL_INTERVAL +-20%
const float CHASE_REPATH = 1.0f;
const float ENEMY_MEMORY = 2.5f;
const float LOST_DIST = 2.0f;
const float FOV_HALF = 1.15f;        // ~66 degrees each side
const float HEAR_DIST = 4.0f;
const float PAIN_ALERT = 1.0f;       // after taking damage, look everywhere for this long
const float STICKINESS = 6.0f;       // metres of preference for the current target
const float QUAD_THREAT = 10.0f;
const float WEAPON_THREAT = 3.0f;
const float LEDGE_PROBE = 1.0f;
const float LEDGE_DROP = 2.0f;
const float ITEM_RETRY = 10.0f;      // an unreachable item is ignored this long
const float ITEM_DIST = 15.0f;       // item value halves at this distance
const float ITEM_GONE_DIST = 3.0f;
const float ITEM_NODE_DIST = 1.5f;   // an item whose nearest node is farther is out of reach
const int ROAM_TRIES = 8;
const float ETA_MIN = 0.3f;          // guessed respawn: 30..100% of the real delay
const float GOAL_STICKINESS = 1.3f;
const float GOAL_JITTER = 0.2f;      // +-10% randomness so bots don't all pick the same item
const float ARRIVAL_SLACK = 1.0f;    // seconds an item may still be missing when we arrive
const float PATROL_RANGE = 12.0f;    // weapon choice when no enemy is around
const float SWITCH_MARGIN = 1.25f;
const float OUT_OF_RANGE = 0.3f;
const int LOW_AMMO = 3;
const float LOW_AMMO_FACTOR = 0.5f;
const float NO_AMMO_DESIRE = 0.25f;  // ammo for a weapon we don't have is worth less
const int LOW_HEALTH = 50;
const float MEGA_BONUS = 40.0f;
const float BIG_ARMOR_BONUS = 30.0f;
const int BIG_ARMOR = 50;
const float HURT_URGENCY = 3.0f;
const float AMMO_TOPUP = 25.0f;
const float AMMO_WEIGHT = 40.0f;
const float QUAD_VALUE = 150.0f;
const float TURN_BASE = 4.0f;        // rad/s at skill 0
const float TURN_SKILL = 12.0f;      // extra rad/s at skill 1
const float MAX_PITCH = 1.4f;
const float REACTION_BASE = 0.15f;
const float REACTION_SKILL = 0.45f;
const float REACTION_JITTER = 0.1f;
const float NOISE_MIN = 0.01f;       // radians
const float NOISE_SKILL = 0.12f;
const float NOISE_SETTLE = 1.0f;     // noise shrinks while tracking the same target...
const float NOISE_FLOOR = 0.5f;      // ...down to this fraction of the skill part
const float AIM_LAG = 0.15f;         // seconds the aim trails a moving target at skill 0
const float NOISE_PITCH = 0.5f;      // vertical aim error is smaller than horizontal
const float NOISE_HOLD = 0.2f;
const float NOISE_SPAN = 0.3f;
const float AIM_BODY = 0.9f;
const float MIN_AIM_DIST = 1.0f;
const float LEAD_MIN = 0.4f;
const float ROCKET_SAFE = 3.0f;      // never fire a rocket into a wall closer than this
const float STRAFE_FLIP = 0.75f;     // chance a strafe burst reverses direction
const float STRAFE_MIN = 0.4f;
const float STRAFE_SPAN = 0.8f;
const float APPROACH_FACTOR = 1.5f;  // close in beyond 1.5x the ideal range...
const float RETREAT_FACTOR = 0.5f;   // ...back off inside half of it
const float STRAFE_SKILL = 1.2f;     // better bots switch strafe direction more often
const float DODGE_JUMP = 0.012f;     // chance per tick (times skill) of a dodge jump
const float GRAB_RADIUS = 6.0f;      // mid-fight, grab worthwhile items this close
const float ITEM_VIEW_HEIGHT = 0.5f;
const float LONG_AGO = -1000.0f;

faultdef NO_ITEM;

const String[*] NAMES = {
	"Pity", "Colo", "Flaco", "Tano", "Pelado", "Toto", "Cachi", "Lucho",
	"Chiqui", "Beto", "Nacho", "Juanchi", "Mono", "Rulo", "Pocho", "Tincho"
};

enum BotState : char (String label)
{
	ROAM { "roam" },
	GET_ITEM { "item" },
	FIGHT { "fight" },
	CHASE { "chase" },
	RESPAWN { "respawn" },
}

<*
 How a bot uses each weapon (same order as Weapon): usable and preferred ranges, rank when in
 range, how big a target error still hits, where to aim, whether to lead, how much it wants it.
*>
enum Tactic : char (Weapon weapon, float min_range, float ideal_range, float max_range, float rank,
	float hit_radius, float aim_height, bool lead, float desire)
{
	SPRAY { MACHINEGUN, 0.0f, 8.0f, 40.0f, 1.0f, 0.5f, 1.0f, false, 0.0f },
	BLAST { SHOTGUN, 0.0f, 3.0f, 9.0f, 2.5f, 0.9f, 1.0f, false, 60.0f },
	SPLASH { ROCKET, 3.0f, 8.0f, 25.0f, 2.2f, 1.2f, 0.15f, true, 120.0f },
	SNIPE { RAILGUN, 6.0f, 25.0f, 300.0f, 2.0f, 0.3f, 1.1f, false, 100.0f },
}

fn Tactic tactic_of(Weapon w) => (Tactic)w.ordinal;

fn float Tactic.score(self, float dist, int ammo)
{
	if (ammo <= 0) return 0;
	float s = self.rank;
	if (dist < self.min_range || dist > self.max_range) s *= OUT_OF_RANGE;
	if (ammo < LOW_AMMO) s *= LOW_AMMO_FACTOR;
	return s;
}

// What the bot wants to do this tick, before it becomes a UserCmd.
struct Intent
{
	Vec3 move;         // flat world direction (unit or zero)
	float speed;       // 0..1 of run speed
	bool jump;
	bool aim;          // yaw/pitch is an aim at the enemy: fire when on target
	float yaw;
	float pitch;
	float tolerance;   // radians of aim error that still hits
}

struct Bot
{
	int slot;
	float skill;
	Rng rng;
	BotState state;

	// navigation
	int[MAX_PATH] path;
	LinkKind[MAX_PATH] links;   // links[k]: how path[k] is reached from path[k - 1]
	float[MAX_PATH] speeds;     // take-off speed of jump/drop links
	int path_len;
	int path_pos;
	int goal_node;
	int goal_item;              // -1 if not heading for an item
	float rethink_at;
	float repath_at;
	float[defs::MAX_ITEMS] item_eta;     // believed respawn time (0 = there)
	float[defs::MAX_ITEMS] item_block;   // unreachable until

	// stuck detection
	Vec3 stuck_ref;
	float stuck_at;
	int stuck_count;
	float unstick_until;
	float unstick_side;

	// combat
	int enemy;                  // -1 = none
	bool enemy_visible;
	float enemy_seen;
	Vec3 enemy_pos;
	float react_at;
	float track_time;
	float noise_yaw;
	float noise_pitch;
	float noise_at;
	float strafe;
	float strafe_at;
	int last_hp;
	float hurt_at;
	Weapon want;

	// view and bookkeeping
	float yaw;
	float pitch;
	bool teleport_bit;
	bool was_dead;
	bool respawn_toggle;
}

<*
 Names cycle through a fixed list of Argentine nicknames.
 @require i >= 0
*>
fn String bot_name(int i) => NAMES[i % NAMES.len];

<*
 @require slot >= 0 && slot < defs::MAX_PLAYERS
 @require skill >= 0.0f && skill <= 1.0f
*>
fn void Bot.init(&self, int slot, float skill, uint seed)
{
	*self = {};
	self.slot = slot;
	self.skill = skill;
	self.rng = mathx::rng(seed);
	self.state = ROAM;
	self.goal_node = -1;
	self.goal_item = -1;
	self.enemy = -1;
	self.strafe = 1.0f;
	self.hurt_at = LONG_AGO;
}

fn String Bot.label(&self) => self.state.label;

<*
 Decides this tick's command for the bot's player. Call once per tick per bot, feed the result
 to World.run_cmd(), then step the world.
 @require w != null && nav != null
*>
fn UserCmd Bot.think(&self, World* w, NavGraph* nav, uint seq)
{
	Player* p = &w.players[self.slot];
	UserCmd cmd = { .seq = seq, .yaw = self.yaw, .pitch = self.pitch, .weapon = self.want };
	if (!p.active || w.phase == INTERMISSION) return cmd;
	if (!p.alive()) return self.think_dead(cmd);
	if (self.was_dead || p.ps.flags.teleport_bit != self.teleport_bit) self.on_warp(w, nav, p);

	float t = w.time;
	self.sense(w, p, t);
	Intent it = { .yaw = self.yaw };
	if (self.enemy >= 0 && self.enemy_visible)
	{
		self.state = FIGHT;
		self.fight(w, nav, p, &it, t);
	}
	else
	{
		self.travel(w, nav, p, &it, t);
	}
	self.check_stuck(p, &it, t);
	self.steer_view(&it);

	cmd.yaw = self.yaw;
	cmd.pitch = self.pitch;
	cmd.weapon = self.want;
	cmd.buttons = { .attack = self.on_target(w, p, &it), .jump = it.jump };
	set_move(&cmd, it.move, it.speed);
	return cmd;
}

// Dead: tap attack to respawn as soon as the world allows it.
fn UserCmd Bot.think_dead(&self, UserCmd cmd)
{
	self.state = RESPAWN;
	self.was_dead = true;
	self.enemy = -1;
	self.path_len = 0;
	self.want = MACHINEGUN;
	self.respawn_toggle = !self.respawn_toggle;
	cmd.buttons.attack = self.respawn_toggle;
	cmd.weapon = MACHINEGUN;
	return cmd;
}

// The player jumped somewhere: respawn, or a teleporter (planned or not).
fn void Bot.on_warp(&self, World* w, NavGraph* nav, Player* p)
{
	bool respawned = self.was_dead;
	self.was_dead = false;
	self.teleport_bit = p.ps.flags.teleport_bit;
	self.yaw = p.ps.yaw;
	self.pitch = p.ps.pitch;
	if (!respawned && self.path_pos < self.path_len && nav.nodes[self.path[self.path_pos]].kind == TELEPORT)
	{
		self.path_pos++;
		return;
	}
	self.forget(p, w.time);
}

fn void Bot.forget(&self, Player* p, float t)
{
	self.path_len = 0;
	self.path_pos = 0;
	self.goal_node = -1;
	self.goal_item = -1;
	self.enemy = -1;
	self.enemy_visible = false;
	self.state = ROAM;
	self.rethink_at = t;
	self.stuck_ref = p.ps.origin;
	self.stuck_at = t + STUCK_INTERVAL;
	self.stuck_count = 0;
	self.unstick_until = 0;
	self.last_hp = p.health + p.armor;
}

// ---------------------------------------------------------------- perception

fn void Bot.sense(&self, World* w, Player* p, float t)
{
	int hp = p.health + p.armor;
	if (hp < self.last_hp) self.hurt_at = t;
	self.last_hp = hp;
	self.remember_items(w, t);
	self.find_enemy(w, p, t);
}

// Items are tracked loosely: when one is seen missing, guess when it comes back.
fn void Bot.remember_items(&self, World* w, float t)
{
	Map* m = w.map;
	for (int i = 0; i < m.item_count; i++)
	{
		if (w.items[i].available)
		{
			self.item_eta[i] = 0;
			continue;
		}
		if (self.item_eta[i] > t) continue;
		float guess = ETA_MIN + (1.0f - ETA_MIN) * self.rng.unit();
		self.item_eta[i] = t + m.items[i].kind.respawn * guess;
	}
}

fn bool can_see(Map* m, Vec3 eye, Player* q) @local
{
	if (m.trace_ray(eye, q.eye(), SHOT).fraction >= 1.0f) return true;
	return m.trace_ray(eye, q.ps.origin + (Vec3){ 0, AIM_BODY, 0 }, SHOT).fraction >= 1.0f;
}

fn bool in_fov(float yaw, Vec3 to) @local
{
	Vec3 dir = nav::flat(to);
	float len = dir.length();
	if (len < 0.01f) return true;
	return mathx::flat_forward(yaw).dot(dir / len) >= math::cos(FOV_HALF);
}

fn float threat(Player* q) @local
{
	float s = 0;
	if (q.quad_time > 0) s += QUAD_THREAT;
	if (q.weapon == ROCKET || q.weapon == RAILGUN) s += WEAPON_THREAT;
	return s;
}

<*
 Picks the closest / most threatening visible opponent in view (anywhere right after being
 hurt), preferring the current one. Remembers a lost target for a while.
*>
fn void Bot.find_enemy(&self, World* w, Player* p, float t)
{
	Vec3 eye = p.eye();
	bool alert = t - self.hurt_at < PAIN_ALERT;
	int best = -1;
	float best_score = math::FLOAT_MAX;
	for (int i = 0; i < defs::MAX_PLAYERS; i++)
	{
		Player* q = &w.players[i];
		if (i == self.slot || !q.alive()) continue;
		Vec3 to = q.eye() - eye;
		float dist = to.length();
		bool noticed = i == self.enemy || alert || dist < HEAR_DIST || in_fov(self.yaw, to);
		if (!noticed || !can_see(w.map, eye, q)) continue;
		float score = dist - threat(q) - (i == self.enemy ? STICKINESS : 0);
		if (score >= best_score) continue;
		best = i;
		best_score = score;
	}
	if (best >= 0)
	{
		if (best != self.enemy)
		{
			self.react_at = t + REACTION_BASE + REACTION_SKILL * (1.0f - self.skill) + REACTION_JITTER * self.rng.unit();
			self.track_time = 0;
			self.noise_at = t;
		}
		self.enemy = best;
		self.enemy_visible = true;
		self.enemy_seen = t;
		self.enemy_pos = w.players[best].ps.origin;
		return;
	}
	self.enemy_visible = false;
	if (self.enemy < 0) return;
	if (!w.players[self.enemy].alive() || t - self.enemy_seen > ENEMY_MEMORY) self.enemy = -1;
}

// ---------------------------------------------------------------- goals

fn float item_value(ItemKind k, Player* p) @local
{
	switch (k.cls)
	{
		case HEALTH:
			int cap = k == MEGA ? defs::MAX_MEGA_HEALTH : defs::MAX_HEALTH;
			if (p.health >= cap) return 0;
			float gain = (float)math::min(cap - p.health, k.amount);
			float urgency = p.health < LOW_HEALTH ? HURT_URGENCY : 1.0f;
			return gain * urgency + (k == MEGA ? MEGA_BONUS : 0.0f);
		case ARMOR:
			if (p.armor >= defs::MAX_ARMOR) return 0;
			float gain = (float)math::min(defs::MAX_ARMOR - p.armor, k.amount);
			return gain + (k.amount >= BIG_ARMOR ? BIG_ARMOR_BONUS : 0.0f);
		case WEAPON:
			int w = (int)k.weapon;
			if (!p.owned[w]) return tactic_of(k.weapon).desire;
			return p.ammo[w] < k.weapon.pickup_ammo ? AMMO_TOPUP : 0.0f;
		case AMMO:
			int w = (int)k.weapon;
			if (p.ammo[w] >= k.weapon.max_ammo) return 0;
			float missing = 1.0f - (float)p.ammo[w] / (float)k.weapon.max_ammo;
			return missing * AMMO_WEIGHT * (p.owned[w] ? 1.0f : NO_AMMO_DESIRE);
		case POWERUP:
			return QUAD_VALUE;
	}
}

fn float Bot.item_score(&self, World* w, Player* p, int i, float t)
{
	if (self.item_block[i] > t) return 0;
	ItemSpot* spot = &w.map.items[i];
	float value = item_value(spot.kind, p);
	if (value <= 0) return 0;
	float dist = (spot.pos - p.ps.origin).length();
	// Skip it if it won't be back by the time we get there.
	if (self.item_eta[i] > t + dist / defs::RUN_SPEED + ARRIVAL_SLACK) return 0;
	float s = value / (1.0f + dist / ITEM_DIST);
	if (i == self.goal_item) s *= GOAL_STICKINESS;
	return s * (1.0f - GOAL_JITTER * 0.5f + GOAL_JITTER * self.rng.unit());
}

<*
 Heads for the most valuable reachable item (need vs distance); roams if nothing is worth it.
*>
fn void Bot.pick_goal(&self, World* w, NavGraph* nav, Player* p, float t)
{
	self.rethink_at = t + GOAL_INTERVAL * (1.0f - GOAL_SPREAD * 0.5f + GOAL_SPREAD * self.rng.unit());
	int start = nav.nearest(p.ps.origin);
	if (start < 0) return;
	Map* m = w.map;
	bool[defs::MAX_ITEMS] tried;
	for (int attempt = 0; attempt < 3; attempt++)
	{
		int best = -1;
		float best_score = 0;
		for (int i = 0; i < m.item_count; i++)
		{
			if (tried[i]) continue;
			float s = self.item_score(w, p, i, t);
			if (s <= best_score) continue;
			best = i;
			best_score = s;
		}
		if (best < 0) break;
		tried[best] = true;
		if (self.plan(nav, start, item_node(nav, m.items[best].pos)))
		{
			self.goal_item = best;
			self.state = GET_ITEM;
			return;
		}
		self.item_block[best] = t + ITEM_RETRY;
	}
	self.goal_item = -1;
	self.state = ROAM;
	for (int attempt = 0; attempt < ROAM_TRIES; attempt++)
	{
		int goal = self.rng.range((int)nav.nodes.len);
		if (nav.nodes[goal].reach && self.plan(nav, start, goal)) return;
	}
}

// The node to stand on to pick up an item, or -1 if no reachable node is close enough.
fn int item_node(NavGraph* nav, Vec3 pos) @local
{
	int n = nav.nearest(pos);
	if (n < 0 || !nav.nodes[n].reach) return -1;
	return (nav.nodes[n].pos - pos).length() <= ITEM_NODE_DIST ? n : -1;
}

fn bool Bot.goal_gone(&self, World* w, Player* p, float t)
{
	if (self.goal_item < 0) return false;
	int i = self.goal_item;
	if (w.items[i].available) return false;
	if ((w.map.items[i].pos - p.ps.origin).length() < ITEM_GONE_DIST) return true;
	return self.item_eta[i] > t + GOAL_INTERVAL;
}

<*
 A* with a temporary route list, copied into the bot's fixed path.
*>
fn bool Bot.plan(&self, NavGraph* nav, int start, int goal)
{
	if (start < 0 || goal < 0) return false;
	bool found;
	@pool()
	{
		List{int} route;
		route.tinit();
		found = nav.path(start, goal, &route);
		if (found) self.load_route(nav, route.array_view());
	};
	if (found) self.goal_node = goal;
	return found;
}

fn void Bot.load_route(&self, NavGraph* nav, int[] route)
{
	int n = math::min((int)route.len, MAX_PATH);
	self.links[0] = WALK;
	self.speeds[0] = 0;
	self.path[0] = route[0];
	for (int k = 1; k < n; k++)
	{
		NavLink link = nav.link(route[k - 1], route[k]) ?? (NavLink){ .to = route[k], .kind = WALK };
		self.path[k] = route[k];
		self.links[k] = link.kind;
		self.speeds[k] = link.speed;
	}
	self.path_len = n;
	self.path_pos = 0;
}

// Re-plans toward a moving target at most every CHASE_REPATH seconds.
fn void Bot.head_for(&self, NavGraph* nav, Player* p, Vec3 target, float t)
{
	if (t < self.repath_at && self.path_pos < self.path_len) return;
	self.repath_at = t + CHASE_REPATH;
	int goal = nav.nearest(target);
	if (goal == self.goal_node && self.path_pos < self.path_len) return;
	self.plan(nav, nav.nearest(p.ps.origin), goal);
}

// ---------------------------------------------------------------- travel

fn void Bot.travel(&self, World* w, NavGraph* nav, Player* p, Intent* it, float t)
{
	self.want = self.best_weapon(p, PATROL_RANGE);
	if (self.enemy >= 0)
	{
		self.state = CHASE;
		self.head_for(nav, p, self.enemy_pos, t);
		bool arrived = self.path_pos >= self.path_len && nav::hlen(self.enemy_pos - p.ps.origin) < LOST_DIST;
		if (arrived) self.enemy = -1;
	}
	else
	{
		if (self.state == CHASE || self.state == FIGHT) self.rethink_at = t;
		bool done = self.path_pos >= self.path_len && !self.item_close(w, p);
		if (done || t >= self.rethink_at || self.goal_gone(w, p, t)) self.pick_goal(w, nav, p, t);
	}
	self.follow(nav, p, it);
	if (self.path_pos >= self.path_len && self.item_close(w, p)) step_onto(w.map.items[self.goal_item].pos, p, it);
}

// The goal item is still there, a step away from the end of the path.
fn bool Bot.item_close(&self, World* w, Player* p)
{
	if (self.goal_item < 0 || !w.items[self.goal_item].available) return false;
	Vec3 d = w.map.items[self.goal_item].pos - p.ps.origin;
	return nav::hlen(d) <= ITEM_NODE_DIST + NODE_REACH && math::abs(d.y) < NODE_HEIGHT;
}

// The path ends at the node nearest the item: walk the last bit straight onto it.
fn void step_onto(Vec3 target, Player* p, Intent* it) @local
{
	Vec3 to = nav::flat(target - p.ps.origin);
	float d = to.length();
	if (d < 0.05f) return;
	it.move = to / d;
	it.speed = 1.0f;
	it.yaw = math::atan2(to.x, to.z);
}

<*
 Steers along the current path: cuts corners on walks, slows before jumps and drops, jumps at
 the take-off node, and uses air control to land on the target node.
*>
fn void Bot.follow(&self, NavGraph* nav, Player* p, Intent* it)
{
	self.advance(nav, p);
	if (self.path_pos >= self.path_len) return;
	Vec3 pos = p.ps.origin;
	Vec3 target = nav.nodes[self.path[self.path_pos]].pos;
	LinkKind link = self.links[self.path_pos];
	Vec3 to = nav::flat(target - pos);
	float dist = to.length();
	Vec3 dir = dist > 0.05f ? to / dist : mathx::flat_forward(self.yaw);
	it.move = self.look_ahead(nav, pos, dir, dist);
	it.speed = 1.0f;
	it.yaw = math::atan2(it.move.x, it.move.z);
	it.pitch = 0;

	if (!p.ps.flags.on_ground)
	{
		// Same air control the nav builder assumed when it checked this link.
		it.move = nav::air_wish(pos, p.ps.velocity, target);
		it.speed = it.move.length_sq() > 0 ? 1.0f : 0.0f;
		return;
	}
	bool leap = link == JUMP || link == DROP;
	if (leap && self.speeds[self.path_pos] > 0) it.speed = self.speeds[self.path_pos] / defs::RUN_SPEED;
	if (link == JUMP && self.at_takeoff(nav, pos, target)) it.jump = true;
	// Approaching a take-off node: arrive at the take-off speed.
	int next = self.path_pos + 1;
	if (next < self.path_len && dist < BRAKE_DIST && (self.links[next] == JUMP || self.links[next] == DROP))
	{
		if (self.speeds[next] > 0) it.speed = math::min(it.speed, self.speeds[next] / defs::RUN_SPEED);
	}
}

// Blends toward the node after the target once close, so walks round corners smoothly.
fn Vec3 Bot.look_ahead(&self, NavGraph* nav, Vec3 pos, Vec3 dir, float dist)
{
	int next = self.path_pos + 1;
	if (dist >= LOOK_AHEAD || next >= self.path_len) return dir;
	if (self.links[self.path_pos] != WALK) return dir;
	LinkKind after = self.links[next];
	if (after == LinkKind.PAD || after == LinkKind.TELEPORT) return dir;
	Vec3 to = nav::flat(nav.nodes[self.path[next]].pos - pos);
	float len = to.length();
	if (len < 0.05f) return dir;
	float k = 1.0f - dist / LOOK_AHEAD;
	Vec3 blend = dir * (1.0f - k) + to / len * k;
	float bl = blend.length();
	return bl > 0.01f ? blend / bl : dir;
}

fn bool Bot.at_takeoff(&self, NavGraph* nav, Vec3 pos, Vec3 target)
{
	if (self.path_pos == 0) return true;
	Vec3 from = nav.nodes[self.path[self.path_pos - 1]].pos;
	Vec3 off = nav::flat(pos - from);
	if (off.length() < JUMP_TRIGGER) return true;
	return off.dot(nav::flat(target - from)) > 0;
}

// Pops nodes we reached (or walked past). Teleporter nodes pop in on_warp.
fn void Bot.advance(&self, NavGraph* nav, Player* p)
{
	Vec3 pos = p.ps.origin;
	bool ground = p.ps.flags.on_ground;
	while (self.path_pos < self.path_len)
	{
		NavNode* node = &nav.nodes[self.path[self.path_pos]];
		if (node.kind == TELEPORT) return;
		Vec3 d = node.pos - pos;
		float hd = nav::hlen(d);
		bool level = math::abs(d.y) < NODE_HEIGHT;
		bool reached = node.kind == PAD ? hd < PAD_REACH && level : hd < NODE_REACH && level && ground;
		if (!reached && !self.passed(nav, pos, node.pos, hd, level)) return;
		self.path_pos++;
	}
}

fn bool Bot.passed(&self, NavGraph* nav, Vec3 pos, Vec3 node, float hd, bool level)
{
	int next = self.path_pos + 1;
	if (!level || hd > PASS_RADIUS || next >= self.path_len) return false;
	if (self.links[self.path_pos] != WALK || self.links[next] != WALK) return false;
	Vec3 ahead = nav.nodes[self.path[next]].pos - node;
	return nav::flat(pos - node).dot(nav::flat(ahead)) > 0;
}

// ---------------------------------------------------------------- combat

fn Weapon Bot.best_weapon(&self, Player* p, float dist)
{
	Weapon best = p.weapon;
	float best_score = tactic_of(p.weapon).score(dist, p.ammo[(int)p.weapon]) * SWITCH_MARGIN;
	foreach (wp : Weapon::values)
	{
		if (!p.owned[(int)wp]) continue;
		float s = tactic_of(wp).score(dist, p.ammo[(int)wp]);
		if (s <= best_score) continue;
		best = wp;
		best_score = s;
	}
	return best;
}

fn void Bot.fight(&self, World* w, NavGraph* nav, Player* p, Intent* it, float t)
{
	Player* e = &w.players[self.enemy];
	float dist = (e.ps.origin - p.ps.origin).length();
	self.want = self.best_weapon(p, dist);
	Tactic tac = tactic_of(p.weapon);
	if (t >= self.react_at) self.aim_at(w, p, e, tac, dist, it, t);
	self.dodge(w, nav, p, e, tac, dist, it, t);
}

fn void Bot.roll_noise(&self, float t)
{
	self.noise_at = t + NOISE_HOLD + NOISE_SPAN * self.rng.unit();
	float settle = NOISE_FLOOR + (1.0f - NOISE_FLOOR) / (1.0f + self.track_time * NOISE_SETTLE);
	float amp = NOISE_MIN + NOISE_SKILL * (1.0f - self.skill) * settle;
	self.noise_yaw = self.rng.signed() * amp;
	self.noise_pitch = self.rng.signed() * amp * NOISE_PITCH;
}

<*
 Rockets go to the feet, ahead of a moving target (lead grows with skill); everything else
 at the body. Falls back to the body when the feet are hidden.
*>
fn Vec3 Bot.aim_point(&self, World* w, Vec3 eye, Player* e, Tactic tac, float dist)
{
	Vec3 vel = nav::flat(e.ps.velocity);
	float lag = AIM_LAG * (1.0f - self.skill);
	if (!tac.lead) return e.ps.origin - vel * lag + (Vec3){ 0, tac.aim_height, 0 };
	float flight = dist / tac.weapon.speed;
	Vec3 lead = vel * (flight * (LEAD_MIN + (1.0f - LEAD_MIN) * self.skill) - lag);
	Vec3 feet = e.ps.origin + lead + (Vec3){ 0, tac.aim_height, 0 };
	if (e.ps.flags.on_ground && w.map.trace_ray(eye, feet, SHOT).fraction >= 1.0f) return feet;
	return e.ps.origin + lead + (Vec3){ 0, AIM_BODY, 0 };
}

fn void Bot.aim_at(&self, World* w, Player* p, Player* e, Tactic tac, float dist, Intent* it, float t)
{
	self.track_time += defs::TICK_DT;
	if (t >= self.noise_at) self.roll_noise(t);
	Vec3 eye = p.eye();
	Vec3 d = self.aim_point(w, eye, e, tac, dist) - eye;
	it.yaw = math::atan2(d.x, d.z) + self.noise_yaw;
	it.pitch = math::clamp(-math::atan2(d.y, nav::hlen(d)) + self.noise_pitch, -MAX_PITCH, MAX_PITCH);
	it.aim = true;
	it.tolerance = math::atan2(tac.hit_radius, math::max(dist, MIN_AIM_DIST));
}

// True if moving along dir keeps floor within LEDGE_DROP under the next metre.
fn bool safe_ground(Map* m, Vec3 origin, Vec3 dir) @local
{
	float len = dir.length();
	if (len < 0.01f) return true;
	Vec3 probe = origin + dir / len * LEDGE_PROBE;
	Vec3 top = { probe.x, origin.y + defs::STEP_HEIGHT, probe.z };
	Vec3 bottom = { probe.x, origin.y - LEDGE_DROP, probe.z };
	Trace tr = m.trace(top, bottom, defs::PLAYER_MINS, defs::PLAYER_MAXS, PLAYER);
	return tr.startsolid || tr.fraction < 1.0f;
}

<*
 Keeps the weapon's preferred distance (walking the nav path to close in), strafes in
 alternating bursts, hops now and then, and never strafes off a ledge.
*>
fn void Bot.dodge(&self, World* w, NavGraph* nav, Player* p, Player* e, Tactic tac, float dist, Intent* it, float t)
{
	Vec3 to = nav::flat(e.ps.origin - p.ps.origin);
	float len = to.length();
	Vec3 dir = len > 0.01f ? to / len : mathx::flat_forward(self.yaw);
	Vec3 side = { dir.z, 0, -dir.x };
	if (t >= self.strafe_at)
	{
		if (self.rng.unit() < STRAFE_FLIP) self.strafe = -self.strafe;
		self.strafe_at = t + STRAFE_MIN + STRAFE_SPAN * (STRAFE_SKILL - self.skill) * self.rng.unit();
	}

	Vec3 base;
	if (dist > tac.ideal_range * APPROACH_FACTOR)
	{
		self.head_for(nav, p, e.ps.origin, t);
		Intent walk = { .yaw = self.yaw };
		self.follow(nav, p, &walk);
		base = walk.move;
		it.jump = walk.jump;
	}
	else if (dist < math::max(tac.ideal_range * RETREAT_FACTOR, tac.min_range))
	{
		base = -dir;
	}
	else if (try grab = self.grab_dir(w, p))
	{
		base = grab;
	}

	Map* m = w.map;
	Vec3 move = base + side * self.strafe;
	if (!safe_ground(m, p.ps.origin, move))
	{
		self.strafe = -self.strafe;
		move = base + side * self.strafe;
	}
	if (!safe_ground(m, p.ps.origin, move)) move = safe_ground(m, p.ps.origin, base) ? base : (Vec3){};
	float ml = move.length();
	it.move = ml > 0.01f ? move / ml : (Vec3){};
	it.speed = 1.0f;
	if (p.ps.flags.on_ground && self.rng.unit() < DODGE_JUMP * self.skill) it.jump = true;
}

// Flat direction to the best worthwhile item a few metres away on our level, if any.
fn Vec3? Bot.grab_dir(&self, World* w, Player* p)
{
	Map* m = w.map;
	Vec3 pos = p.ps.origin;
	float best = 0;
	Vec3 dir;
	for (int i = 0; i < m.item_count; i++)
	{
		if (!w.items[i].available) continue;
		Vec3 to = m.items[i].pos - pos;
		float d = nav::hlen(to);
		if (d > GRAB_RADIUS || math::abs(to.y) > NODE_HEIGHT) continue;
		float s = item_value(m.items[i].kind, p) / (1.0f + d);
		if (s <= best) continue;
		if (m.trace_ray(p.eye(), m.items[i].pos + (Vec3){ 0, ITEM_VIEW_HEIGHT, 0 }, PLAYER).fraction < 1.0f) continue;
		best = s;
		dir = nav::flat(to) / math::max(d, 0.01f);
	}
	if (best <= 0) return NO_ITEM~;
	return dir;
}

fn bool Bot.on_target(&self, World* w, Player* p, Intent* it)
{
	if (!it.aim) return false;
	float dy = mathx::wrap_angle(it.yaw - self.yaw);
	float dp = it.pitch - self.pitch;
	if (dy * dy + dp * dp > it.tolerance * it.tolerance) return false;
	if (p.weapon != ROCKET) return true;
	Vec3 eye = p.eye();
	Vec3 fwd = mathx::forward(self.yaw, self.pitch);
	return w.map.trace_ray(eye, eye + fwd * ROCKET_SAFE, SHOT).fraction >= 1.0f;
}

// ---------------------------------------------------------------- output

fn void Bot.check_stuck(&self, Player* p, Intent* it, float t)
{
	if (t < self.unstick_until)
	{
		Vec3 side = { it.move.z, 0, -it.move.x };
		Vec3 move = it.move + side * self.unstick_side;
		float ml = move.length();
		if (ml > 0.01f) it.move = move / ml;
		it.speed = 1.0f;
		it.jump = p.ps.flags.on_ground;
		return;
	}
	if (t < self.stuck_at) return;
	self.stuck_at = t + STUCK_INTERVAL;
	float moved = nav::hlen(p.ps.origin - self.stuck_ref);
	self.stuck_ref = p.ps.origin;
	bool trying = it.speed > 0 && it.move.length_sq() > 0 && self.state != FIGHT;
	if (!trying || moved >= STUCK_DIST)
	{
		self.stuck_count = 0;
		return;
	}
	self.stuck_count++;
	self.unstick_until = t + UNSTICK_TIME;
	self.unstick_side = self.rng.unit() < 0.5f ? -1.0f : 1.0f;
	it.jump = true;
	if (self.stuck_count < STUCK_REPATH) return;
	self.stuck_count = 0;
	self.path_len = 0;
	self.rethink_at = t;
}

// Turns toward the wanted view at a skill-dependent rate.
fn void Bot.steer_view(&self, Intent* it)
{
	float rate = (TURN_BASE + TURN_SKILL * self.skill) * defs::TICK_DT;
	float dyaw = mathx::wrap_angle(it.yaw - self.yaw);
	self.yaw = mathx::wrap_angle(self.yaw + math::clamp(dyaw, -rate, rate));
	self.pitch += math::clamp(it.pitch - self.pitch, -rate, rate);
}

<*
 Converts a world-space move direction into forward/side relative to the command's yaw
 (pmove applies them along flat_forward/flat_right of that same yaw).
*>
fn void set_move(UserCmd* cmd, Vec3 dir, float speed) @local
{
	if (speed <= 0 || dir.length_sq() < 1e-6f) return;
	float f = dir.dot(mathx::flat_forward(cmd.yaw));
	float s = dir.dot(mathx::flat_right(cmd.yaw));
	float most = math::max(math::abs(f), math::abs(s));
	if (most < 1e-4f) return;
	float scale = 127.0f * math::min(speed, 1.0f) / most;
	cmd.forward = (ichar)math::clamp(f * scale, -127.0f, 127.0f);
	cmd.side = (ichar)math::clamp(s * scale, -127.0f, 127.0f);
}
