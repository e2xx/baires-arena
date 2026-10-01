// GPU rendering: baked world meshes, players, items, projectiles, viewmodel.
module arena::render;
import std::math, raylib6, arena::mathx, arena::defs, arena::map, arena::snap, arena::bake, arena::fx, arena::textures;

const float OVERBRIGHT = 2.0f;
const float ITEM_HOVER = 0.55f;
const float NEAR_PLANE = 0.03f;
const float FAR_PLANE = 600.0f;

const ZString WORLD_VS = `
#version 330
in vec3 vertexPosition;
in vec2 vertexTexCoord;
in vec3 vertexNormal;
in vec4 vertexColor;
uniform mat4 mvp;
out vec2 fragUV;
out vec3 fragLight;
out vec3 fragPos;
out vec3 fragNormal;
void main()
{
    fragUV = vertexTexCoord;
    fragLight = vertexColor.rgb * 2.0;
    fragPos = vertexPosition;
    fragNormal = vertexNormal;
    gl_Position = mvp * vec4(vertexPosition, 1.0);
}
`;

// Shared lighting tail for both shaders: dynamic lights, fog, filmic-ish rolloff.
const String SHADING_COMMON = `
uniform vec3 camPos;
uniform vec3 fogColor;
uniform float fogDensity;
uniform float time;
uniform vec4 dynPos[16];
uniform vec4 dynColor[16];
uniform int dynCount;
uniform float exposure;
vec3 dynamicLight(vec3 p, vec3 n)
{
    vec3 sum = vec3(0.0);
    for (int i = 0; i < dynCount; i++)
    {
        vec3 d = dynPos[i].xyz - p;
        float dist = length(d);
        float r = dynPos[i].w;
        if (dist >= r) continue;
        float att = 1.0 - dist / r;
        sum += dynColor[i].rgb * att * att * max(dot(n, d / max(dist, 0.001)), 0.0);
    }
    return sum;
}
vec3 finish(vec3 c, vec3 p)
{
    float dist = length(camPos - p);
    float fog = 1.0 - exp(-dist * fogDensity);
    c *= exposure;
    c = c * (1.0 + c / 6.0) / (1.0 + c);
    return mix(c, fogColor, clamp(fog, 0.0, 1.0));
}
`;

const ZString WORLD_FS = `
#version 330
in vec2 fragUV;
in vec3 fragLight;
in vec3 fragPos;
in vec3 fragNormal;
uniform sampler2D texture0;
uniform float emissive;
out vec4 finalColor;
` +++ SHADING_COMMON +++ `
void main()
{
    vec3 albedo = texture(texture0, fragUV).rgb;
    vec3 c;
    if (emissive > 0.5)
    {
        float pulse = emissive > 1.5 ? 0.75 + 0.35 * sin(time * 4.0 + fragPos.x + fragPos.z) : 1.0;
        c = albedo * 1.6 * pulse;
    }
    else
    {
        c = albedo * (fragLight + dynamicLight(fragPos, fragNormal));
    }
    finalColor = vec4(finish(c, fragPos), 1.0);
}
`;

const ZString OBJECT_VS = `
#version 330
in vec3 vertexPosition;
in vec3 vertexNormal;
uniform mat4 mvp;
uniform mat4 matModel;
uniform mat4 matNormal;
out vec3 fragPos;
out vec3 fragNormal;
void main()
{
    fragPos = vec3(matModel * vec4(vertexPosition, 1.0));
    fragNormal = normalize(vec3(matNormal * vec4(vertexNormal, 0.0)));
    gl_Position = mvp * vec4(vertexPosition, 1.0);
}
`;

const ZString OBJECT_FS = `
#version 330
in vec3 fragPos;
in vec3 fragNormal;
uniform vec4 colDiffuse;
uniform vec3 probe;
uniform float emissive;
out vec4 finalColor;
` +++ SHADING_COMMON +++ `
void main()
{
    vec3 n = normalize(fragNormal);
    vec3 toCam = normalize(camPos - fragPos);
    vec3 key = normalize(vec3(0.35, 1.0, 0.25));
    float shade = 0.45 + 0.55 * max(dot(n, key), 0.0);
    float rim = pow(1.0 - max(dot(n, toCam), 0.0), 3.0);
    vec3 c;
    if (emissive > 0.5)
    {
        c = colDiffuse.rgb * 1.7;
    }
    else
    {
        c = colDiffuse.rgb * (probe * shade * 1.25 + dynamicLight(fragPos, n)) + rim * 0.25 * probe;
    }
    finalColor = vec4(finish(c, fragPos), colDiffuse.a);
}
`;

struct WorldMesh
{
	RLMesh mesh;
	RLMaterial material;
	float emissive;
}

// Coordinate frame for building boxes: x = left, y = up, z = forward (right-handed).
struct Frame
{
	Vec3 origin;
	Vec3 x;
	Vec3 y;
	Vec3 z;
}

struct Uniforms
{
	int cam;
	int fog_color;
	int fog_density;
	int time;
	int dyn_pos;
	int dyn_color;
	int dyn_count;
	int emissive;
	int probe;
	int exposure;
}

struct Renderer
{
	Map* map;
	Baked* baked;
	RLShader world_shader;
	RLShader object_shader;
	Uniforms wu;
	Uniforms ou;
	WorldMesh[Material::len] meshes;
	int mesh_count;
	RLMaterial object_mat;
	RLMesh cube;
	RLMesh sphere;
	float[defs::MAX_PLAYERS] run_phase;
	float time;
	float exposure;
}

fn Uniforms locate(RLShader s) @local
{
	return {
		s.get_location("camPos"), s.get_location("fogColor"), s.get_location("fogDensity"), s.get_location("time"),
		s.get_location("dynPos"), s.get_location("dynColor"), s.get_location("dynCount"),
		s.get_location("emissive"), s.get_location("probe"), s.get_location("exposure"),
	};
}

fn Mat4 identity() @local
{
	Mat4 m;
	m.m = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
	return m;
}

<*
 Instance matrix in raylib layout: mesh axes X/Y/Z map to the given (scaled) world vectors.
*>
fn Mat4 basis(Vec3 pos, Vec3 x, Vec3 y, Vec3 z) @local
{
	Mat4 m;
	m.m = {
		x.x, y.x, z.x, pos.x,
		x.y, y.y, z.y, pos.y,
		x.z, y.z, z.z, pos.z,
		0, 0, 0, 1,
	};
	return m;
}

fn Frame frame_from(Vec3 origin, float yaw, float pitch)
{
	Vec3 z = mathx::forward(yaw, pitch);
	Vec3 x = { math::cos(yaw), 0, -math::sin(yaw) };
	return { origin, x, z.cross(x), z };
}

fn Vec3 Frame.at(&self, Vec3 local) => self.origin + self.x * local.x + self.y * local.y + self.z * local.z;

// Rotates the frame about its own x axis (positive tips the forward axis down).
fn Frame Frame.pitched(&self, Vec3 pivot_local, float angle)
{
	float c = math::cos(angle);
	float s = math::sin(angle);
	Vec3 y = self.y * c - self.z * s;
	Vec3 z = self.y * s + self.z * c;
	return { self.at(pivot_local), self.x, y, z };
}

fn RLColor rgb(Vec3 c, float a = 1.0f) @local
{
	Vec3 v = math::clamp(c, (Vec3){ 0, 0, 0 }, (Vec3){ 1, 1, 1 });
	return { (char)(v.x * 255), (char)(v.y * 255), (char)(v.z * 255), (char)(a * 255) };
}

// ---------------------------------------------------------------- setup

fn WorldMesh build_mesh(Material mat, VertexList* tris, RLShader shader) @local
{
	sz n = tris.len();
	float[] pos = mem::new_array(float, n * 3);
	float[] uv = mem::new_array(float, n * 2);
	float[] nrm = mem::new_array(float, n * 3);
	char[] col = mem::new_array(char, n * 4);
	foreach (i, v : tris.array_view())
	{
		Vec3 l = math::clamp(v.light / OVERBRIGHT, (Vec3){ 0, 0, 0 }, (Vec3){ 1, 1, 1 });
		for (int k = 0; k < 3; k++)
		{
			pos[i * 3 + k] = v.pos[k];
			nrm[i * 3 + k] = v.normal[k];
			col[i * 4 + k] = (char)(l[k] * 255);
		}
		col[i * 4 + 3] = 255;
		uv[i * 2] = v.u;
		uv[i * 2 + 1] = v.v;
	}
	RLMesh mesh = { .vertex_count = (int)n, .triangle_count = (int)(n / 3), .vertices = pos.ptr, .texcoords = uv.ptr, .normals = nrm.ptr, .colors = col.ptr };
	rl::upload_mesh(&mesh, false);
	// GPU has the data now; free our copies so raylib never frees memory it didn't allocate.
	free(pos);
	free(uv);
	free(nrm);
	free(col);
	mesh.vertices = null;
	mesh.texcoords = null;
	mesh.normals = null;
	mesh.colors = null;

	RLMaterial material = rl::load_material_default();
	material.shader = shader;
	material.maps[RLMaterialMapIndex.DIFFUSE].texture = textures::get(mat);
	float emissive = mat == JUMPPAD ? 2.0f : (mat.surface == EMISSIVE ? 1.0f : 0.0f);
	return { mesh, material, emissive };
}

fn Renderer* create(Map* m, Baked* baked)
{
	Renderer* r = mem::new(Renderer);
	r.map = m;
	r.baked = baked;
	r.world_shader = rl::load_shader_from_memory(WORLD_VS, WORLD_FS);
	r.object_shader = rl::load_shader_from_memory(OBJECT_VS, OBJECT_FS);
	r.object_shader.locs[(int)RLShaderLocationIndex.MATRIX_MODEL] = r.object_shader.get_location("matModel");
	r.object_shader.locs[(int)RLShaderLocationIndex.MATRIX_NORMAL] = r.object_shader.get_location("matNormal");
	r.wu = locate(r.world_shader);
	r.ou = locate(r.object_shader);

	foreach (i, &tris : baked.tris)
	{
		Material mat = (Material)i;
		if (tris.len() == 0 || mat.surface == INVISIBLE) continue;
		r.meshes[r.mesh_count++] = build_mesh(mat, tris, r.world_shader);
	}
	r.object_mat = rl::load_material_default();
	r.object_mat.shader = r.object_shader;
	r.exposure = 1.0f;
	r.cube = rl::gen_mesh_cube(1, 1, 1);
	r.sphere = rl::gen_mesh_sphere(0.5f, 12, 16);
	return r;
}

fn void Renderer.destroy(&self)
{
	for (int i = 0; i < self.mesh_count; i++) rl::unload_mesh(self.meshes[i].mesh);
	rl::unload_mesh(self.cube);
	rl::unload_mesh(self.sphere);
	rl::unload_shader(self.world_shader);
	rl::unload_shader(self.object_shader);
	free(self);
}

// ---------------------------------------------------------------- frame state

fn void Renderer.set_common(&self, RLShader s, Uniforms* u, RLCamera3D cam, DynLight[] lights)
{
	Map* m = self.map;
	Vec3 cam_pos = cam.position;
	float density = m.fog_density;
	s.set_value(u.cam, &cam_pos, VEC3);
	s.set_value(u.fog_color, &m.fog_color, VEC3);
	s.set_value(u.fog_density, &density, FLOAT);
	s.set_value(u.time, &self.time, FLOAT);
	s.set_value(u.exposure, &self.exposure, FLOAT);
	float[<4>][fx::MAX_DYN_LIGHTS] pos;
	float[<4>][fx::MAX_DYN_LIGHTS] col;
	int n = (int)math::min(lights.len, (sz)fx::MAX_DYN_LIGHTS);
	for (int i = 0; i < n; i++)
	{
		pos[i] = { lights[i].pos.x, lights[i].pos.y, lights[i].pos.z, lights[i].radius };
		col[i] = { lights[i].color.x, lights[i].color.y, lights[i].color.z, 1 };
	}
	if (n > 0)
	{
		s.set_value_v(u.dyn_pos, &pos, VEC4, n);
		s.set_value_v(u.dyn_color, &col, VEC4, n);
	}
	s.set_value(u.dyn_count, &n, INT);
}

fn void Renderer.begin_frame(&self, RLCamera3D cam, DynLight[] lights, float time)
{
	self.time = time;
	self.set_common(self.world_shader, &self.wu, cam, lights);
	self.set_common(self.object_shader, &self.ou, cam, lights);
}

fn void Renderer.draw_world(&self)
{
	Mat4 id = identity();
	for (int i = 0; i < self.mesh_count; i++)
	{
		WorldMesh* wm = &self.meshes[i];
		self.world_shader.set_value(self.wu.emissive, &wm.emissive, FLOAT);
		rl::draw_mesh(wm.mesh, wm.material, id);
	}
}

// ---------------------------------------------------------------- objects

fn void Renderer.box(&self, Mat4 m, Vec3 color, Vec3 light, bool glow = false, float alpha = 1.0f)
{
	float e = glow ? 1.0f : 0.0f;
	self.object_shader.set_value(self.ou.emissive, &e, FLOAT);
	self.object_shader.set_value(self.ou.probe, &light, VEC3);
	self.object_mat.maps[RLMaterialMapIndex.DIFFUSE].color = rgb(color, alpha);
	rl::draw_mesh(self.cube, self.object_mat, m);
}

fn void Renderer.ball(&self, Vec3 pos, float radius, Vec3 color, Vec3 light, bool glow = false)
{
	float e = glow ? 1.0f : 0.0f;
	self.object_shader.set_value(self.ou.emissive, &e, FLOAT);
	self.object_shader.set_value(self.ou.probe, &light, VEC3);
	self.object_mat.maps[RLMaterialMapIndex.DIFFUSE].color = rgb(color);
	float d = radius * 2.0f;
	rl::draw_mesh(self.sphere, self.object_mat, basis(pos, { d, 0, 0 }, { 0, d, 0 }, { 0, 0, d }));
}

// Box centred at `local` in frame f, with size along the frame axes.
fn void Renderer.part(&self, Frame* f, Vec3 local, Vec3 size, Vec3 color, Vec3 light, bool glow = false)
{
	self.box(basis(f.at(local), f.x * size.x, f.y * size.y, f.z * size.z), color, light, glow);
}

// Box from point a to point b (long axis), with a cross-section.
fn void Renderer.limb(&self, Frame* f, Vec3 a, Vec3 b, float thick, Vec3 color, Vec3 light)
{
	Vec3 pa = f.at(a);
	Vec3 pb = f.at(b);
	Vec3 axis = pb - pa;
	float len = axis.length();
	if (len < 0.001f) return;
	Vec3 y = axis / len;
	Vec3 x = f.x - y * f.x.dot(y);
	if (x.length_sq() < 0.0001f) x = f.z;
	x = x.normalize();
	Vec3 z = x.cross(y);
	self.box(basis((pa + pb) * 0.5f, x * thick, y * len, z * thick), color, light);
}

<*
 Weapon geometry in a frame whose origin is the grip and z is the barrel direction.
*>
fn void Renderer.weapon(&self, Frame* f, Weapon w, Vec3 light, float scale = 1.0f)
{
	Frame s = { f.origin, f.x * scale, f.y * scale, f.z * scale };
	switch (w)
	{
		case MACHINEGUN:
			self.part(&s, { 0, 0.02f, 0.12f }, { 0.08f, 0.1f, 0.3f }, { 0.35f, 0.36f, 0.38f }, light);
			self.part(&s, { 0, 0.045f, 0.38f }, { 0.035f, 0.035f, 0.3f }, { 0.12f, 0.12f, 0.13f }, light);
			self.part(&s, { 0, -0.07f, 0.14f }, { 0.05f, 0.12f, 0.06f }, { 0.75f, 0.6f, 0.25f }, light);
		case SHOTGUN:
			self.part(&s, { 0, 0.0f, 0.06f }, { 0.08f, 0.1f, 0.22f }, { 0.45f, 0.28f, 0.14f }, light);
			self.part(&s, { 0.022f, 0.05f, 0.34f }, { 0.04f, 0.04f, 0.42f }, { 0.15f, 0.15f, 0.16f }, light);
			self.part(&s, { -0.022f, 0.05f, 0.34f }, { 0.04f, 0.04f, 0.42f }, { 0.15f, 0.15f, 0.16f }, light);
		case ROCKET:
			self.part(&s, { 0, 0.05f, 0.18f }, { 0.13f, 0.13f, 0.62f }, { 0.35f, 0.4f, 0.28f }, light);
			self.part(&s, { 0, 0.05f, 0.5f }, { 0.155f, 0.155f, 0.06f }, { 0.75f, 0.15f, 0.1f }, light);
			self.part(&s, { 0, -0.06f, 0.02f }, { 0.05f, 0.12f, 0.06f }, { 0.15f, 0.15f, 0.15f }, light);
		case RAILGUN:
			self.part(&s, { 0, 0.03f, 0.2f }, { 0.07f, 0.08f, 0.6f }, { 0.22f, 0.24f, 0.27f }, light);
			for (int i = 0; i < 3; i++)
			{
				self.part(&s, { 0, 0.03f, 0.08f + (float)i * 0.15f }, { 0.09f, 0.1f, 0.04f }, { 0.3f, 1.0f, 0.5f }, light, true);
			}
			self.part(&s, { 0, -0.06f, 0.0f }, { 0.05f, 0.12f, 0.06f }, { 0.15f, 0.15f, 0.15f }, light);
	}
}

fn void Renderer.player(&self, PlayerSnap* p, int index, float dt, bool quad_glow)
{
	Vec3 color = ((PlayerColor)(p.color % PlayerColor::len)).rgb;
	Vec3 light = self.baked.sample(p.origin + (Vec3){ 0, 1.0f, 0 });
	if (quad_glow) light += (Vec3){ 0.3f, 0.4f, 1.4f };
	Vec3 dark = color * 0.35f + (Vec3){ 0.05f, 0.05f, 0.06f };

	Frame body = frame_from(p.origin, p.yaw, 0);
	if (p.flags.dead)
	{
		// Lying on the back.
		body = body.pitched({ 0, 0, 0 }, -(float)math::PI / 2.0f);
	}

	float speed = ((Vec3){ p.velocity.x, 0, p.velocity.z }).length();
	bool grounded = p.flags.on_ground;
	if (grounded && !p.flags.dead) self.run_phase[index] += dt * speed * 1.1f;
	float swing = grounded ? math::sin(self.run_phase[index]) * math::min(speed / defs::RUN_SPEED, 1.0f) * 0.7f : 0.35f;

	// Legs swing about the hips.
	for (int side = 0; side < 2; side++)
	{
		float sx = side == 0 ? 0.13f : -0.13f;
		float a = side == 0 ? swing : -swing;
		Frame leg = body.pitched({ sx, 0.85f, 0 }, -a);
		self.part(&leg, { 0, -0.42f, 0 }, { 0.22f, 0.85f, 0.25f }, dark, light);
	}
	self.part(&body, { 0, 1.15f, 0 }, { 0.62f, 0.62f, 0.34f }, color, light);
	self.part(&body, { 0, 1.15f, 0.17f }, { 0.3f, 0.3f, 0.02f }, color * 1.3f, light, true);

	Frame head = body.pitched({ 0, 1.47f, 0 }, p.pitch);
	self.part(&head, { 0, 0.17f, 0 }, { 0.34f, 0.34f, 0.34f }, dark, light);
	self.part(&head, { 0, 0.2f, 0.16f }, { 0.26f, 0.08f, 0.05f }, color * 1.4f, light, true);

	// Arms aim along the view pitch and hold the weapon.
	Vec3 aim = { 0, -math::sin(p.pitch), math::cos(p.pitch) };
	for (int side = 0; side < 2; side++)
	{
		float sx = side == 0 ? 0.38f : -0.38f;
		Vec3 shoulder = { sx, 1.38f, 0 };
		Vec3 hand = { sx * 0.3f, 1.38f + aim.y * 0.5f, aim.z * 0.5f };
		self.limb(&body, shoulder, hand, 0.15f, color * 0.8f, light);
	}
	Frame gun = { body.at({ 0, 1.38f + aim.y * 0.5f, aim.z * 0.5f }), body.x, body.y * aim.z - body.z * aim.y, body.z * aim.z + body.y * aim.y };
	if (!p.flags.dead) self.weapon(&gun, p.weapon, light, 1.2f);
}

fn void Renderer.draw_players(&self, Snapshot* s, int skip_slot, float dt)
{
	for (int i = 0; i < defs::MAX_PLAYERS; i++)
	{
		PlayerSnap* p = &s.players[i];
		if (!p.active || i == skip_slot) continue;
		self.player(p, i, dt, p.quad);
	}
}

fn void Renderer.draw_projectiles(&self, Snapshot* s)
{
	foreach (&pr : s.projectiles)
	{
		if (!pr.active) continue;
		Vec3 dir = pr.vel.normalize();
		Vec3 x = dir.cross({ 0, 1, 0 });
		if (x.length_sq() < 0.001f) x = { 1, 0, 0 };
		x = x.normalize();
		Vec3 y = dir.cross(x);
		Vec3 light = self.baked.sample(pr.pos);
		self.box(basis(pr.pos, x * 0.12f, y * 0.12f, dir * 0.45f), { 0.5f, 0.55f, 0.45f }, light);
		Vec3 glow = pr.quad ? (Vec3){ 0.4f, 0.6f, 1.0f } : (Vec3){ 1.0f, 0.7f, 0.3f };
		self.box(basis(pr.pos - dir * 0.3f, x * 0.14f, y * 0.14f, dir * 0.12f), glow, light, true);
	}
}

fn Vec3 item_color(ItemKind k) @local
{
	switch (k)
	{
		case HEALTH_SMALL: return { 0.95f, 0.85f, 0.2f };
		case HEALTH_BIG: return { 1.0f, 0.55f, 0.15f };
		case MEGA: return { 0.3f, 0.5f, 1.0f };
		case ARMOR_SHARD: return { 0.3f, 0.9f, 0.4f };
		case ARMOR_YELLOW: return { 1.0f, 0.85f, 0.15f };
		case ARMOR_RED: return { 0.95f, 0.15f, 0.12f };
		case QUAD: return { 0.25f, 0.45f, 1.0f };
		default: return { 0.7f, 0.7f, 0.7f };
	}
}

fn void Renderer.draw_items(&self, Snapshot* s)
{
	Map* m = self.map;
	for (int i = 0; i < m.item_count; i++)
	{
		if (!s.items[i]) continue;
		ItemKind k = m.items[i].kind;
		float spin = self.time * 1.6f + (float)i;
		float bob = math::sin(self.time * 2.2f + (float)i) * 0.1f;
		Vec3 pos = m.items[i].pos + (Vec3){ 0, ITEM_HOVER + bob, 0 };
		Vec3 light = self.baked.sample(pos);
		Frame f = frame_from(pos, spin, 0);
		Vec3 c = item_color(k);
		switch (k.cls)
		{
			case HEALTH:
				if (k == MEGA)
				{
					self.ball(pos, 0.38f, c, light, true);
					break;
				}
				float s2 = k == HEALTH_BIG ? 1.3f : 1.0f;
				self.part(&f, { 0, 0, 0 }, { 0.42f * s2, 0.14f * s2, 0.14f * s2 }, c, light, true);
				self.part(&f, { 0, 0, 0 }, { 0.14f * s2, 0.42f * s2, 0.14f * s2 }, c, light, true);
			case ARMOR:
				float a = k == ARMOR_SHARD ? 0.22f : 0.5f;
				self.part(&f, { 0, 0, 0 }, { a, a * 1.1f, a * 0.35f }, c, light);
				self.part(&f, { 0, a * 0.1f, a * 0.18f }, { a * 0.5f, a * 0.5f, 0.02f }, c * 1.3f, light, true);
			case WEAPON:
				Frame g = { pos - f.z * 0.25f, f.x, f.y, f.z };
				self.weapon(&g, k.weapon, light + (Vec3){ 0.2f, 0.2f, 0.2f }, 1.5f);
			case AMMO:
				self.part(&f, { 0, -0.1f, 0 }, { 0.32f, 0.22f, 0.32f }, { 0.3f, 0.3f, 0.28f }, light);
				Weapon w = k.weapon;
				Vec3 band = w == ROCKET ? (Vec3){ 0.8f, 0.2f, 0.1f } : (w == RAILGUN ? (Vec3){ 0.3f, 1.0f, 0.5f } : (Vec3){ 0.9f, 0.75f, 0.3f });
				self.part(&f, { 0, -0.02f, 0 }, { 0.33f, 0.05f, 0.33f }, band, light, true);
			case POWERUP:
				Frame q = frame_from(pos, spin * 1.7f, spin);
				self.part(&q, { 0, 0, 0 }, { 0.5f, 0.5f, 0.5f }, c, light, true);
				self.part(&q, { 0, 0, 0 }, { 0.62f, 0.2f, 0.2f }, c * 0.6f, light, true);
		}
	}
}

fn void Renderer.draw_teleports(&self)
{
	Map* m = self.map;
	for (int i = 0; i < m.teleport_count; i++)
	{
		Teleport* t = &m.teleports[i];
		Vec3 c = t.trigger.center();
		Vec3 h = t.trigger.size() * 0.5f;
		Vec3 glow = { 0.3f, 0.6f, 1.0f };
		Vec3 light = { 1, 1, 1 };
		float pulse = 0.08f + 0.03f * math::sin(self.time * 5.0f);
		self.box(basis(c - (Vec3){ 0, h.y - 0.03f, 0 }, { h.x * 2.2f, 0, 0 }, { 0, 0.06f, 0 }, { 0, 0, h.z * 2.2f }), glow, light, true);
		self.box(basis(c + (Vec3){ 0, h.y, 0 }, { h.x * 2.2f, 0, 0 }, { 0, pulse, 0 }, { 0, 0, h.z * 2.2f }), glow, light, true);
	}
}

<*
 First-person weapon. `kick` is recoil (0..1), `bob` the walk cycle phase, `sway` small view lag.
*>
fn void Renderer.draw_viewmodel(&self, RLCamera3D cam, float yaw, float pitch, Weapon w, float kick, float bob, float bob_amount)
{
	Frame view = frame_from(cam.position, yaw, pitch);
	float bx = math::sin(bob) * 0.012f * bob_amount;
	float by = math::abs(math::cos(bob)) * 0.01f * bob_amount;
	Vec3 grip = { -0.2f + bx, -0.22f - by + kick * 0.015f, 0.36f - kick * 0.06f };
	Frame g = view.pitched(grip, -kick * 0.25f);
	Vec3 light = self.baked.sample(cam.position) + (Vec3){ 0.15f, 0.15f, 0.15f };
	self.weapon(&g, w, light, 0.62f);
}
