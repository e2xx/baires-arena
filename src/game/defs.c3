// Constants and types shared by every layer (game sim, network, client).
module arena::defs;
import std::math;

const int TICK_RATE = 60;
const float TICK_DT = 1.0f / (float)TICK_RATE;
const int MAX_PLAYERS = 16;
const int MAX_PROJECTILES = 96;
const int MAX_ITEMS = 64;
const int MAX_EVENTS = 64;
const ushort DEFAULT_PORT = 27960;
const char PROTOCOL_VERSION = 1;

// Player hull and movement: Quake III values divided by 32 (1 unit = 1 m).
const Vec3 PLAYER_MINS = { -0.45f, 0.0f, -0.45f };
const Vec3 PLAYER_MAXS = { 0.45f, 1.75f, 0.45f };
const Vec3 DEAD_MAXS = { 0.45f, 0.5f, 0.45f };
const float EYE_HEIGHT = 1.55f;
const float STEP_HEIGHT = 0.56f;
const float RUN_SPEED = 10.0f;
const float GRAVITY = 25.0f;
const float JUMP_VELOCITY = 8.44f;
const float GROUND_ACCEL = 10.0f;
const float AIR_ACCEL = 1.0f;
const float FRICTION = 6.0f;
const float STOP_SPEED = 3.125f;
const float MIN_WALK_NORMAL = 0.7f;
const float OVERCLIP = 1.001f;

// Combat
const int SPAWN_HEALTH = 125;
const int MAX_HEALTH = 100;
const int MAX_MEGA_HEALTH = 200;
const int MAX_ARMOR = 200;
const float ARMOR_PROTECTION = 0.66f;
const float RESPAWN_DELAY = 1.7f;
const float QUAD_DURATION = 20.0f;
const float QUAD_FACTOR = 3.0f;
const float SELF_DAMAGE_FACTOR = 0.5f;
const float KNOCKBACK_SCALE = 0.156f;   // m/s per damage point (Q3: 1000/200/32)

// Match
const int DEFAULT_FRAGLIMIT = 20;
const int DEFAULT_TIMELIMIT_MIN = 10;
const float INTERMISSION_TIME = 8.0f;

enum Surface : char
{
	OPAQUE,
	EMISSIVE,
	INVISIBLE,
}

// Map materials: `id` is the token used in .map files.
enum Material : char (String id, Vec3 base, Surface surface)
{
	TILE_WHITE { "tile_white", { 0.86f, 0.87f, 0.84f }, OPAQUE },
	TILE_BAND { "tile_band", { 0.35f, 0.70f, 0.85f }, OPAQUE },
	CONCRETE { "concrete", { 0.55f, 0.55f, 0.53f }, OPAQUE },
	COBBLE { "cobble", { 0.42f, 0.40f, 0.38f }, OPAQUE },
	STONE { "stone", { 0.85f, 0.83f, 0.78f }, OPAQUE },
	METAL { "metal", { 0.50f, 0.52f, 0.55f }, OPAQUE },
	CONTAINER_RED { "container_red", { 0.62f, 0.18f, 0.12f }, OPAQUE },
	CONTAINER_BLUE { "container_blue", { 0.15f, 0.30f, 0.55f }, OPAQUE },
	WOOD { "wood", { 0.50f, 0.34f, 0.20f }, OPAQUE },
	BRICK { "brick", { 0.60f, 0.30f, 0.22f }, OPAQUE },
	TRIM { "trim", { 0.90f, 0.75f, 0.10f }, OPAQUE },
	GRASS { "grass", { 0.25f, 0.45f, 0.18f }, OPAQUE },
	LIGHT { "light", { 1.00f, 0.95f, 0.85f }, EMISSIVE },
	JUMPPAD { "jumppad", { 0.20f, 0.90f, 0.60f }, EMISSIVE },
	CLIP { "clip", { 0.0f, 0.0f, 0.0f }, INVISIBLE },
}

enum FireKind : char
{
	HITSCAN,
	PELLETS,
	ROCKET,
	RAIL,
}

enum Weapon : char (String name, FireKind fire, float refire, int damage, int pellets, float spread,
	float splash_radius, int splash_damage, float speed, int start_ammo, int pickup_ammo, int max_ammo)
{
	MACHINEGUN { "Ametralladora", HITSCAN, 0.1f, 7, 1, 0.03f, 0.0f, 0, 0.0f, 100, 50, 200 },
	SHOTGUN { "Escopeta", PELLETS, 1.0f, 10, 11, 0.11f, 0.0f, 0, 0.0f, 0, 10, 50 },
	ROCKET { "Lanzacohetes", ROCKET, 0.8f, 100, 1, 0.0f, 3.75f, 100, 28.0f, 0, 10, 50 },
	RAILGUN { "Railgun", RAIL, 1.5f, 100, 1, 0.0f, 0.0f, 0, 0.0f, 0, 10, 50 },
}

enum ItemClass : char
{
	HEALTH,
	ARMOR,
	WEAPON,
	AMMO,
	POWERUP,
}

// `id` is the token used in .map files.
enum ItemKind : char (String id, String name, ItemClass cls, int amount, float respawn, Weapon weapon)
{
	HEALTH_SMALL { "health", "+25 salud", HEALTH, 25, 30.0f, MACHINEGUN },
	HEALTH_BIG { "health_big", "+50 salud", HEALTH, 50, 30.0f, MACHINEGUN },
	MEGA { "mega", "Mega salud", HEALTH, 100, 35.0f, MACHINEGUN },
	ARMOR_SHARD { "armor_shard", "+5 armadura", ARMOR, 5, 25.0f, MACHINEGUN },
	ARMOR_YELLOW { "armor_yellow", "Armadura amarilla", ARMOR, 50, 25.0f, MACHINEGUN },
	ARMOR_RED { "armor_red", "Armadura roja", ARMOR, 100, 25.0f, MACHINEGUN },
	WEAPON_SHOTGUN { "shotgun", "Escopeta", WEAPON, 0, 5.0f, SHOTGUN },
	WEAPON_ROCKET { "rocket", "Lanzacohetes", WEAPON, 0, 5.0f, ROCKET },
	WEAPON_RAIL { "rail", "Railgun", WEAPON, 0, 5.0f, RAILGUN },
	AMMO_MG { "ammo_mg", "Balas", AMMO, 50, 40.0f, MACHINEGUN },
	AMMO_SHOTGUN { "ammo_shotgun", "Cartuchos", AMMO, 10, 40.0f, SHOTGUN },
	AMMO_ROCKET { "ammo_rocket", "Cohetes", AMMO, 5, 40.0f, ROCKET },
	AMMO_RAIL { "ammo_rail", "Slugs", AMMO, 10, 40.0f, RAILGUN },
	QUAD { "quad", "QUAD DAMAGE", POWERUP, 0, 90.0f, MACHINEGUN },
}

bitstruct Buttons : char
{
	bool attack;
	bool jump;
	bool walk;
}

// One tick of player intent. Identical on client (prediction) and server.
struct UserCmd
{
	uint seq;
	float yaw;
	float pitch;
	ichar forward;   // -127..127
	ichar side;      // -127..127, positive = right
	Buttons buttons;
	Weapon weapon;   // weapon the player wants to hold
}

bitstruct PmFlags : ushort
{
	bool on_ground;
	bool jump_held;
	bool dead;
	bool teleport_bit;   // flips on every teleport: clients skip interpolation
}

// The predicted part of a player: everything pmove reads and writes.
struct PlayerState
{
	Vec3 origin;
	Vec3 velocity;
	float yaw;
	float pitch;
	PmFlags flags;
	float knockback_time;   // seconds without ground friction (rocket jumps)
}

// What happened during one pmove call (for sounds and effects).
bitstruct PmEvents : char
{
	bool jumped;
	bool landed;
	bool hard_landing;
	bool jumppad;
	bool teleported;
	bool footstep;
}

enum EventKind : char
{
	NONE,
	FIRE,          // a = player, b = weapon, pos = muzzle, pos2 = aim end
	EXPLOSION,     // a = owner, pos = center, pos2 = surface normal
	RAIL,          // a = player, pos = start, pos2 = end
	BULLET_HIT,    // pos = impact, pos2 = surface normal
	PAIN,          // a = player, b = health left
	DEATH,         // a = victim, b = killer (255 = world), c = weapon
	PICKUP,        // a = player, b = item kind
	JUMP,          // a = player
	LAND,          // a = player
	JUMPPAD,       // a = player, pos
	TELEPORT,      // a = player, pos = destination
	RESPAWN,       // a = player, pos
	HIT_CONFIRM,   // a = attacker, b = damage
	ITEM_RESPAWN,  // b = item index, pos
	MATCH_END,     // a = winner
}

const char NO_PLAYER = 255;

struct GameEvent
{
	uint id;
	EventKind kind;
	char a;
	char b;
	char c;
	Vec3 pos;
	Vec3 pos2;
}
