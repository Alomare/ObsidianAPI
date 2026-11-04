-- Time, camera, HUD, the look of the world, and finding a place in it. The camera and the look are
-- this player's alone: nobody else sees them.
local game = obsidian.module("lib/game")
local effects = obsidian.module("lib/effects")

local M = {}

local function camera()
	return game.global("CameraManager")
end

local function viewport()
	local st = game.state()
	return type(st) == "table" and st.viewport or nil
end

-- Time. Host speed changes everyone's game; a client's only its own simulation.
effects.define({ id = "time_scale",
	apply = function(_, value) rawset(_G, "TIME_SCALE", value) end,
	remove = function() rawset(_G, "TIME_SCALE", 1) end,
})

effects.define({ id = "pause",
	apply = function() rawset(_G, "PAUSED", true) end,
	remove = function() rawset(_G, "PAUSED", false) end,
})

-- Camera. change_settings has to be used: follow_distance alone is rewritten every frame. Each screen
-- sets the camera up its own way (a mission at 60 degrees and 17 m, the ship at 52 degrees and 10 m:
-- state_game.lua:196, state_menu.lua:295), so what the game set is kept the first time one of these
-- effects changes it on a screen, and given back when they come off.
local camera_kept = nil

local function kept(ctx)
	local cm = camera()
	if not camera_kept or camera_kept.state ~= ctx.state then
		camera_kept = { state = ctx.state, fov = cm.fov, distance = cm.follow_distance, max = cm.max_follow_distance,
			min = cm.min_follow_distance, angle = cm.follow_angle }
	end
	return camera_kept
end

effects.define({ id = "camera_distance",
	apply = function(ctx, value)
		kept(ctx)
		camera():change_settings(nil, value, nil, nil)
	end,
	remove = function(ctx)
		local k, cm = kept(ctx), camera()
		cm.follow_distance, cm.max_follow_distance, cm.min_follow_distance = k.distance, k.max, k.min
	end,
})

effects.define({ id = "camera_angle",
	apply = function(ctx, value)
		kept(ctx)
		camera():change_settings(nil, nil, value, nil)
	end,
	remove = function(ctx) camera().follow_angle = kept(ctx).angle end,
})

effects.define({ id = "free_camera_bounds",
	apply = function() camera():set_ignore_level_bounds(true) end,
	remove = function() camera():set_ignore_level_bounds(false) end,
})

-- Checked inside the hook on add_shake in main.lua, since shakes aren't state to set or clear.
effects.define({ id = "no_camera_shake" })

-- The manager is one table that each state sets up again, so these go back on after a change of
-- state. A spin of -45 is what a mission starts with (state_game.lua:196).
effects.define({ id = "camera_fov",
	apply = function(ctx, value)
		kept(ctx)
		camera():set_fov(math.rad(value))
	end,
	remove = function(ctx) camera():set_fov(kept(ctx).fov) end,
})

effects.define({ id = "camera_spin",
	apply = function(ctx, value)
		if ctx.name == "game" then camera():change_settings(nil, nil, nil, value) end
	end,
	remove = function(ctx)
		if ctx.name == "game" then camera():change_settings(nil, nil, nil, -45) end
	end,
})

-- The camera follows whatever is in its target map. The game adds a unit once, when it spawns, so a
-- swap holds until a respawn, and the frame function covers that.
local function watch(unit)
	local cam = camera()
	for target in pairs(cam.targets) do
		if target ~= unit then cam:remove_target(target) end
	end
	if not cam.targets[unit] then cam:add_target(unit) end
end

local function watch_own()
	local cam = camera()
	for target in pairs(cam.targets) do cam:remove_target(target) end
	for _, p in ipairs(game.all_avatars()) do
		if p.owned then cam:add_target(p.unit) end
	end
end

effects.define({ id = "camera_spectate",
	apply = function(_, unit)
		if game.global("Unit").alive(unit) then watch(unit) end
	end,
	frame = function(_, unit)
		if game.global("Unit").alive(unit) then
			watch(unit)
		elseif next(camera().targets) == nil then
			watch_own()
		end
	end,
	remove = watch_own,
})

-- The camera stays where it is and the screen clears. The hint box and the objective list have
-- switches of their own, which the HUD effect doesn't reach.
local photo_hid_hud = false

local function photo_screen(st, on)
	if st.hint_manager and st.hint_manager.set_active then st.hint_manager:set_active(on) end
	if st.mission_manager and st.mission_manager.set_display_objectives then st.mission_manager:set_display_objectives(on) end
end

-- Missions and the ship. The camera goes back to the state it had: "follow" in a mission,
-- "follow_menu" on the ship.
local PHOTO_SCREENS = { game = true, menu = true }
local photo_state_before = nil

effects.define({ id = "photo_mode",
	apply = function(ctx)
		if not PHOTO_SCREENS[ctx.name] then return end
		local cm = camera()
		if cm.state ~= "fully_static" then photo_state_before = cm.state end
		cm:set_state("fully_static")
		photo_screen(ctx.state, false)
		if not effects.is_on("hide_hud") then
			photo_hid_hud = true
			effects.set("hide_hud", true)
		end
	end,
	remove = function(ctx)
		if PHOTO_SCREENS[ctx.name] then
			camera():set_state(photo_state_before or (ctx.name == "menu" and "follow_menu" or "follow"))
			photo_state_before = nil
			photo_screen(ctx.state, true)
		end
		if photo_hid_hud then
			photo_hid_hud = false
			effects.set("hide_hud", false)
		end
	end,
})

local function ranged(id, low, high)
	return function(value)
		if value and not (type(value) == "number" and value >= low and value <= high) then return false, "out_of_range" end
		return effects.set(id, value or false)
	end
end

M.camera = {
	-- Degrees from 10 to 120. nil gives it back.
	fov = ranged("camera_fov", 10, 120),
	-- Degrees around the player, from -360 to 360.
	spin = ranged("camera_spin", -360, 360),
}

-- The camera the game set on this screen, before any effect changed it: { fov, distance, angle }, the
-- field of view and the angle in degrees, the distance in metres. A mission starts at 60, 17 and 65;
-- the ship has its own.
function M.camera.defaults()
	local cm = camera()
	if type(cm) ~= "table" then return nil end
	local st = game.state()
	local k = (camera_kept and camera_kept.state == st) and camera_kept
		or { fov = cm.fov, distance = cm.min_follow_distance or cm.follow_distance, angle = cm.follow_angle }
	return { fov = k.fov and math.deg(k.fov), distance = k.min or k.distance, angle = k.angle and math.deg(k.angle) }
end

-- unit: another player's avatar, from game.all_avatars. nil comes back to this player.
function M.camera.spectate(unit)
	if unit == nil then return effects.set("camera_spectate", false) end
	for _, p in ipairs(game.all_avatars()) do
		if p.unit == unit then return effects.set("camera_spectate", unit) end
	end
	return false, "no_avatar"
end

-- Freezes the camera and clears the screen. In a mission or on the ship.
function M.camera.photo(on)
	if on and not (game.in_mission() or game.on_ship()) then return false, "not_in_mission" end
	return effects.set("photo_mode", on and true or false)
end

-- Where the frozen camera sits. pos is a Vector3, rotation a Quaternion, nil to leave it.
function M.camera.place(pos, rotation)
	if not effects.is_on("photo_mode") then return false, "not_photo_mode" end
	if pos then camera():set_position(pos) end
	if rotation then camera():set_rotation(rotation) end
	return true
end


-- HUD
local function hud()
	local st = game.state()
	return type(st) == "table" and st.hud or nil
end

effects.define({ id = "hide_hud",
	apply = function()
		rawset(_G, "DISABLE_INGAME_HUD", true)
		local h = hud()
		if h then h.enabled, h.plugins_enabled = false, false end
	end,
	remove = function()
		rawset(_G, "DISABLE_INGAME_HUD", false)
		local h = hud()
		if h then h.enabled, h.plugins_enabled = true, true end
	end,
})

effects.define({ id = "show_patrols",
	apply = function()
		local h = hud()
		if h and h.set_show_all_patrols then h:set_show_all_patrols(true) end
	end,
	remove = function()
		local h = hud()
		if h and h.set_show_all_patrols then h:set_show_all_patrols(false) end
	end,
})

effects.define({ id = "test_info",
	apply = function(ctx)
		if type(ctx.state) == "table" then ctx.state.show_test_info = true end
	end,
	remove = function(ctx)
		if type(ctx.state) == "table" then ctx.state.show_test_info = false end
	end,
})

-- Look. These are local to this player: shading isn't shared.
local function shading(name, kind, value)
	local v = viewport()
	if not v then return false end
	if value == nil then
		v:remove_shading_environment_variable(name)
	else
		v:set_shading_environment_variable(name, kind, value)
	end
	return true
end

-- Names found in the planets' shading resources, by kind (campaign.md 4.4). The viewport hands the
-- name to the engine every frame, so anything else stays out. Reading the kinds from the same list
-- keeps a name from going to the engine as the wrong type. The second line of each kind was named in
-- 1.23.0 from the strings of the game's shaders, matched to the resources' hashes and types.
local SHADING = {
	scalar = { "exposure", "dof_amount", "ambient_camera_falloff", "sun_enabled", "ssao_radius", "ssao_strength", "vignette_opacity", "color_grading_enabled",
		"cloud_shadow_opacity", "dust_opacity", "emissive_material_intensity", "emissive_particle_intensity", "cube_environment_intensity_sun", "cube_environment_intensity_shadow" },
	vector2 = { "fog_depth_range", "dof_near_setting", "dof_far_setting", "bloom_threshold_offset",
		"cloud_shadow_movement", "cloud_shadow_scale", "dust_scale0", "dust_scale1", "dust_scale2", "dust_speed0", "dust_speed1", "dust_speed2" },
	vector3 = { "fog_color", "fog_sun_blend", "sun_color", "sun_direction", "ambient_top_color", "ambient_bottom_color",
		"dust_color", "vignette" },
}
local SIZES = { vector2 = 2, vector3 = 3 }

local function shading_kind(name)
	for kind, names in pairs(SHADING) do
		for _, known in ipairs(names) do
			if known == name then return kind end
		end
	end
	return nil
end

local function finite(n)
	return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

local function good_value(kind, value)
	if kind == "scalar" then return finite(value) end
	if type(value) ~= "table" or #value ~= SIZES[kind] then return false end
	for _, n in ipairs(value) do
		if not finite(n) then return false end
	end
	return true
end

M.SHADING = SHADING

-- A value of the look of the mission. kind: scalar, vector2 or vector3. value: a number, or a list
-- of 2 or 3. nil gives it back to the planet. It goes on again in each new mission.
function M.shading(name, kind, value)
	local known = shading_kind(name)
	if not known then return false, "unknown_shading" end
	if kind ~= known then return false, "bad_type" end
	local id = "shading_" .. name
	if not effects.defs[id] then
		effects.define({ id = id,
			apply = function(_, v) shading(name, kind, v) end,
			remove = function() shading(name) end,
		})
	end
	if value == nil then return effects.set(id, false) end
	if not good_value(kind, value) then return false, "bad_value" end
	return effects.set(id, value)
end

-- A lightning flash. Only forest planets have the setting it fades to, and not the illuminates' ones
-- (campaign.md 4.4). A name the resource lacks is left to no chance, so it's refused.
function M.flash(seconds)
	local st = game.state()
	local manager = type(st) == "table" and st.environment_area_manager
	local level = type(st) == "table" and st.generated_level
	if not (manager and level and game.in_mission()) then return false, "not_in_mission" end
	if level.environment_name ~= "forest" or level.enemy == "illuminates" then return false, "wrong_environment" end
	if seconds ~= nil and not (finite(seconds) and seconds > 0 and seconds <= 10) then return false, "out_of_range" end
	manager:set_shading_environment_event({ shading_environment = "lightning", fade_in_time = 0.1, hold_time = seconds or 0.2, fade_out_time = 0.5, target_value = 1 })
	return true
end

effects.define({ id = "no_fog",
	apply = function() shading("fog_depth_range", "vector2", { 5000, 5001 }) end,
	remove = function() shading("fog_depth_range") end,
})

effects.define({ id = "no_dof",
	apply = function() shading("dof_amount", "scalar", 0) end,
	remove = function() shading("dof_amount") end,
})

effects.define({ id = "exposure",
	apply = function(_, value) shading("exposure", "scalar", value) end,
	remove = function() shading("exposure") end,
})

-- dawn, day, dusk, night, as the shading environments of the planets name them.
effects.define({ id = "time_of_day",
	apply = function(_, value)
		local v = viewport()
		if v then v:set_shading_environment_settings(value, 1) end
	end,
	remove = function(ctx)
		local v = viewport()
		local level = type(ctx.state) == "table" and ctx.state.generated_level
		if v and level and level.shading_environment_setting then v:set_shading_environment_settings(level.shading_environment_setting, 1) end
	end,
})

effects.define({ id = "gravity",
	apply = function(ctx, value)
		local proxy = type(ctx.state) == "table" and ctx.state.world_proxy
		if proxy then game.global("PhysicsWorld").set_gravity(proxy:get_physics_world(), game.global("Vector3")(0, 0, value)) end
	end,
	remove = function(ctx)
		local proxy = type(ctx.state) == "table" and ctx.state.world_proxy
		if proxy then game.global("PhysicsWorld").set_gravity(proxy:get_physics_world(), game.global("Vector3")(0, 0, -18)) end
	end,
})

-- Boot rewrites the music volume each frame, so it's set again after that.
effects.define({ id = "mute_music",
	frame = function() game.global("Timpani").set_bus_volume("music_master", -60) end,
})

-- The point of the level under the mouse: the ray from the camera through the cursor, or where
-- that ray meets the ground plane when it hits nothing.
function M.cursor()
	local st = game.state()
	if type(st) ~= "table" or not st.viewport or not st.world_proxy then return nil end
	local mouse, v3 = game.global("Mouse"), game.global("Vector3")
	local c = mouse.axis(mouse.axis_index("cursor"))
	local from = game.global("Camera").world_position(st.viewport:get_camera())
	local dir = v3.normalize(st.viewport:screen_to_world(c.x, c.y, 500) - from)
	local hit, pos = game.global("PhysicsWorld").immediate_raycast(st.world_proxy:get_physics_world(), from, dir, 500, "closest", "collision_filter", "default")
	if hit then return pos end
	if dir.z < 0 then return from + dir * (-from.z / dir.z) end
	return nil
end

-- Where a point of the level is on the screen: pixels from the bottom left, as kits draw without a
-- frame, and whether it's in view. pos: a vector or { x, y, z }.
function M.to_screen(pos)
	local cam, app, v3 = game.global("CameraManager"), game.global("Application"), game.global("Vector3")
	if not (cam and app and pos) then return nil end
	local ok, s = pcall(cam.world_to_screen, cam, v3(pos.x, pos.y, pos.z or 0))
	if not ok or not s then return nil end
	local w, h = app.resolution()
	return s.x, s.y, s.z > 0 and s.x >= 0 and s.x <= w and s.y >= 0 and s.y <= h
end

-- A position some metres in front of the avatar.
function M.ahead(metres)
	local unit = game.my_unit()
	if not unit then return nil end
	local units, q = game.global("Unit"), game.global("Quaternion")
	return units.world_position(unit, 0) + q.forward(units.local_rotation(unit, 0)) * metres
end

-- Props: a unit of the game that exists on this machine only, for what a mod shows in the level.
-- Nothing goes over the network and no game system knows it, so it does nothing but be seen, with
-- whatever glow and highlight the unit has. The unit has to be in a package the level has loaded: the
-- engine stops the game for one it can't find (a mission's research samples, gameobjects/flare_01 and
-- the enemies of a loaded faction are). pos: a vector or { x, y, z }. opts.scale: a size, 1 as made.
-- Answers a prop with :move(pos), :scale(size), :flow(event) and :remove(), or nil and a reason.
local Prop = {}
Prop.__index = Prop

local function vector(pos)
	if pos == nil then return nil end
	local ok, x, y, z = pcall(function() return pos.x, pos.y, pos.z end)
	if not ok or type(x) ~= "number" or type(y) ~= "number" then return nil end
	return game.global("Vector3")(x, y, type(z) == "number" and z or 0)
end

-- The first thing on the straight line from one point to another: true, where and how far along, or
-- false. filter: the game's collision filter, "default" when left out; "mover_blocker" is what stops a
-- body walking, the one to ask before moving a player. from, to: vectors or { x, y, z }.
function M.raycast(from, to, filter)
	local a, b = vector(from), vector(to)
	if not (a and b) then return false, "bad_type" end
	local st = game.state()
	if type(st) ~= "table" or not st.world_proxy then return false, "not_in_mission" end
	local v3 = game.global("Vector3")
	local length = v3.length(b - a)
	if length <= 0.0001 then return false end
	local ok, hit, pos, distance = pcall(game.global("PhysicsWorld").immediate_raycast, st.world_proxy:get_physics_world(), a,
		v3.normalize(b - a), length, "closest", "collision_filter", type(filter) == "string" and filter or "default")
	-- A filter the game doesn't know.
	if not ok then return false, "bad_type" end
	if hit then return true, pos, distance end
	return false
end

function M.prop(unit_name, pos, opts)
	if type(unit_name) ~= "string" or unit_name == "" then return nil, "bad_type" end
	local at = vector(pos)
	if not at then return nil, "bad_type" end
	local st = game.state()
	local proxy = type(st) == "table" and st.world_proxy
	if not (proxy and game.in_mission()) then return nil, "not_in_mission" end
	local world = proxy:get_world()
	local ok, unit = pcall(game.global("World").spawn_unit, world, unit_name, at)
	if not ok or not unit then return nil, "unknown" end
	local p = setmetatable({ unit = unit, world = world }, Prop)
	if opts and type(opts.scale) == "number" then p:scale(opts.scale) end
	return p
end

-- false once its level is gone, or it was removed.
function Prop:alive()
	if not self.unit then return false end
	local ok, alive = pcall(game.global("Unit").alive, self.unit)
	return ok and alive == true
end

-- Moves it, at once even in a stopped world.
function Prop:move(pos)
	local at = vector(pos)
	if not at or not self:alive() then return false end
	game.global("Unit").teleport_local_position(self.unit, 0, at)
	pcall(game.global("World").update_unit, self.world, self.unit)
	return true
end

function Prop:scale(size)
	if type(size) ~= "number" or not self:alive() then return false end
	game.global("Unit").set_local_scale(self.unit, 0, game.global("Vector3")(size, size, size))
	return true
end

-- Runs one of the unit's own flow events, the way the game makes a unit play its sounds and effects:
-- "on_picked_up" on a research sample plays the pickup.
function Prop:flow(event)
	if type(event) ~= "string" or not self:alive() then return false end
	return (pcall(game.global("Unit").flow_event, self.unit, event))
end

function Prop:remove()
	if self:alive() then pcall(game.global("World").destroy_unit, self.world, self.unit) end
	self.unit = nil
end

-- An explosion at a position. The game's own manager does the damage and the push.
function M.explode(pos, power, radius)
	local st = game.state()
	if not (type(st) == "table" and st.explosion_manager and pos) then return false, "not_in_mission" end
	local unit = game.my_unit()
	local info = { force = 10, center_radius = radius / 3, blast_radius = radius, center_power = power, blast_power = power / 2,
		armorpiercing = false, ignore_shields = false, ignore_armor = false }
	st.explosion_manager:do_explosion(nil, game.box(pos), info, unit, unit)
	return true
end

function M.clear_decals()
	local manager = game.global("SurfaceEffectManager")
	if not (manager and manager.clear) then return false, "not_in_mission" end
	manager:clear()
	return true
end

-- The taken camera's pose, and what of it reached the engine.
local held = nil

local function finite_or(n, default)
	if finite(n) then return n end
	return default
end

local function viewport_camera(cm)
	local vp = cm and cm.viewport
	if not vp then return nil end
	return vp, vp:get_camera(), vp.camera_unit
end

local function rotation_of(yaw, pitch, roll)
	local Q, V3 = game.global("Quaternion"), game.global("Vector3")
	local q = Q(V3(0, 0, 1), math.rad(yaw))
	q = Q.multiply(q, Q(V3(1, 0, 0), math.rad(pitch)))
	if roll ~= 0 then q = Q.multiply(q, Q(V3(0, 1, 0), math.rad(roll))) end
	return q
end

-- The way a yaw and a pitch look, as { x, y, z }.
function M.camera.forward(yaw, pitch)
	local y, p = math.rad(yaw or 0), math.rad(pitch or 0)
	return { x = -math.sin(y) * math.cos(p), y = math.cos(y) * math.cos(p), z = math.sin(p) }
end

-- Where the camera is now, as set() takes it: { position, yaw, pitch, roll, fov }. Roll reads 0.
function M.camera.get()
	local cm = camera()
	local _, cam = viewport_camera(cm)
	if not cam then return nil, "not_in_mission" end
	if held then
		return { position = { x = held.position.x, y = held.position.y, z = held.position.z }, yaw = held.yaw, pitch = held.pitch,
			roll = held.roll, fov = held.fov, ortho = held.ortho, far = held.far }
	end
	local C, Q = game.global("Camera"), game.global("Quaternion")
	local pos, rot = C.world_position(cam), C.world_rotation(cam)
	local f = Q.forward(rot)
	return { position = { x = pos.x, y = pos.y, z = pos.z }, yaw = math.deg(math.atan2(-f.x, f.y)),
		pitch = math.deg(math.asin(math.max(-1, math.min(1, f.z)))), roll = 0, fov = math.deg(C.vertical_fov(cam)) }
end

-- Takes the camera where it is: the game stops moving it, and it goes where set() puts it, every frame,
-- until release() or a change of screen. This player's only, in a mission. Poses are plain numbers, kept
-- from frame to frame (the engine's vectors last a frame): position { x, y, z } in metres, and angles in
-- degrees. yaw turns about the up axis, 0 looking along +y, the level's north, and grows turning left
-- seen from above; pitch looks up when positive and down when negative; roll tips the picture. fov is
-- the vertical field of view. ortho, a width in metres, draws without perspective, as a plan does; far
-- is how far the camera sees, in metres. In a mission or on the ship. Answers true, or false and why not.
function M.camera.take()
	if not (game.in_mission() or game.on_ship()) then return false, "not_in_mission" end
	if held then return true end
	local cm = camera()
	local _, cam = viewport_camera(cm)
	if not cam then return false, "not_in_mission" end
	local pose = M.camera.get()
	local C = game.global("Camera")
	local ok, far = pcall(C.far_range, cam)
	held = { state = game.state(), position = pose.position, yaw = pose.yaw, pitch = pose.pitch, roll = 0, fov = pose.fov,
		game_far = ok and far or nil, applied = {} }
	return true
end

-- Where the taken camera goes. pose: any of position, yaw, pitch, roll, fov (from 5 to 150), ortho
-- (false or nil for perspective) and far, as get() answers them.
function M.camera.set(pose)
	if not held then return false, "not_available" end
	if type(pose) ~= "table" then return false, "bad_type" end
	local p = pose.position
	if type(p) == "table" and finite(p.x) and finite(p.y) and finite(p.z) then held.position = { x = p.x, y = p.y, z = p.z } end
	held.yaw = finite_or(pose.yaw, held.yaw)
	held.pitch = math.max(-89.9, math.min(89.9, finite_or(pose.pitch, held.pitch)))
	held.roll = finite_or(pose.roll, held.roll)
	held.fov = math.max(5, math.min(150, finite_or(pose.fov, held.fov)))
	if pose.ortho ~= nil then held.ortho = finite(pose.ortho) and pose.ortho > 0 and pose.ortho or nil end
	if pose.far ~= nil then held.far = finite(pose.far) and pose.far > 1 and pose.far or nil end
	return true
end

-- Whether a mod has the camera.
function M.camera.taken()
	return held ~= nil
end

local function give_back(cm)
	local h = held
	held = nil
	if not h then return end
	local _, cam = viewport_camera(cm)
	if not cam then return end
	local C = game.global("Camera")
	if h.applied.ortho then pcall(C.set_projection_type, cam, C.PERSPECTIVE) end
	if h.applied.far and h.game_far then pcall(C.set_far_range, cam, h.game_far) end
	-- The game sets the field of view only when its own changes.
	if cm.fov then pcall(C.set_vertical_fov, cam, cm.fov) end
end

-- Gives the camera back to the game, which goes on from where it left it.
function M.camera.release()
	if not held then return true end
	local ok, err = pcall(give_back, camera())
	held = nil
	if not ok then obsidian.log("camera: " .. tostring(err)) end
	return true
end

-- In place of the game's camera update while the camera is taken: the pose, the grass and the like
-- around what the camera sees, and the camera's own scene node.
local function drive(cm)
	local vp, cam, unit = viewport_camera(cm)
	local C, V3, W = game.global("Camera"), game.global("Vector3"), game.global("World")
	local h = held
	local pos = V3(h.position.x, h.position.y, h.position.z)
	C.set_local_position(cam, unit, pos)
	C.set_local_rotation(cam, unit, rotation_of(h.yaw, h.pitch, h.roll))
	if h.applied.fov ~= h.fov then
		C.set_vertical_fov(cam, math.rad(h.fov))
		h.applied.fov = h.fov
	end
	if (h.ortho ~= nil) ~= (h.applied.ortho == true) then
		C.set_projection_type(cam, h.ortho and C.ORTHOGRAPHIC or C.PERSPECTIVE)
		h.applied.ortho = h.ortho ~= nil
	end
	if h.ortho then
		local w, hh = game.global("Application").resolution()
		local half = h.ortho / 2
		local tall = half * hh / math.max(1, w)
		C.set_orthographic_view(cam, -half, half, -tall, tall)
	end
	local far = h.far or h.game_far
	if far and h.applied.far ~= far then
		C.set_far_range(cam, far)
		h.applied.far = far
	end
	local proxy = vp:get_world_proxy()
	if vp:is_active() and proxy:is_active() then W.update_unit(proxy:get_world(), unit) end
	local scatter = game.global("ScatterSystem")
	if scatter and cm.scatter_system and cm.observer_id then
		local f = M.camera.forward(h.yaw, h.pitch)
		local ground = h.position
		if f.z < -0.05 then
			local d = math.min(h.position.z / -f.z, 200)
			ground = { x = h.position.x + f.x * d, y = h.position.y + f.y * d, z = h.position.z + f.z * d }
		end
		scatter.move_observer(cm.scatter_system, cm.observer_id, V3(ground.x, ground.y, ground.z + 10))
	end
end

-- The unit a light is made of, a beacon flare in every mission's packages, and the name of its light.
M.LIGHT_UNIT = "gameobjects/flare_01"
M.LIGHT_NAME = "red_light"
local LightHandle = {}
LightHandle.__index = LightHandle

-- A light in the level that only this player sees: a beacon flare, hidden, with no physics, and its light
-- taken over. pos: { x, y, z } or a vector. opts: color { r, g, b } from 0 to 1, intensity, range (metres
-- the light reaches), shadows (true casts them), spot (an angle in degrees makes it a spotlight, nil an
-- all-round light) with yaw and pitch for where a spotlight points. Answers a light with :set(opts),
-- :move(pos), :alive() and :remove(), or nil and a reason.
function M.light(pos, opts)
	local at = vector(pos)
	if not at then return nil, "bad_type" end
	local st = game.state()
	local proxy = type(st) == "table" and st.world_proxy
	if not (proxy and game.in_mission()) then return nil, "not_in_mission" end
	local U, W = game.global("Unit"), game.global("World")
	local world = proxy:get_world()
	local ok, unit = pcall(W.spawn_unit, world, M.LIGHT_UNIT, at)
	if not ok or not unit then return nil, "unknown" end
	pcall(U.set_unit_visibility, unit, false)
	pcall(U.disable_physics, unit)
	local light = nil
	local found, has = pcall(U.has_light, unit, M.LIGHT_NAME)
	if found and has then
		light = U.light(unit, M.LIGHT_NAME)
	else
		local counted, n = pcall(U.num_lights, unit)
		if counted and type(n) == "number" and n > 0 then
			local got, l = pcall(U.light, unit, 0)
			if got then light = l end
		end
	end
	if not light then
		pcall(W.destroy_unit, world, unit)
		return nil, "no_light"
	end
	local h = setmetatable({ unit = unit, world = world, light = light, opts = {} }, LightHandle)
	pcall(game.global("Light").set_enabled, light, true)
	h:set(opts or {})
	-- A stopped world never places a new unit's scene node, and the light would stay where the unit's
	-- own space starts until the first move.
	h:settle()
	return h
end

function LightHandle:alive()
	if not self.unit then return false end
	local ok, alive = pcall(game.global("Unit").alive, self.unit)
	return ok and alive == true
end

-- Changes any of the light's opts, as M.light takes them.
function LightHandle:set(opts)
	if type(opts) ~= "table" or not self:alive() then return false end
	local L, V3 = game.global("Light"), game.global("Vector3")
	local o = self.opts
	for k, v in pairs(opts) do o[k] = v end
	local c = type(o.color) == "table" and o.color or { 1, 1, 1 }
	local r, g, b = finite_or(c[1] or c.r, 1), finite_or(c[2] or c.g, 1), finite_or(c[3] or c.b, 1)
	pcall(L.set_color, self.light, V3(r, g, b))
	pcall(L.set_intensity, self.light, math.max(0, finite_or(o.intensity, 1)))
	pcall(L.set_falloff_start, self.light, 0)
	pcall(L.set_falloff_end, self.light, math.max(0.5, finite_or(o.range, 8)))
	pcall(L.set_casts_shadows, self.light, o.shadows == true)
	local spot = finite(o.spot) and o.spot > 0 and o.spot or nil
	if (spot ~= nil) ~= (self.spot_set == true) then
		pcall(L.set_type, self.light, spot and L.SPOT or L.OMNI)
		self.spot_set = spot ~= nil
	end
	if spot then
		pcall(L.set_spot_angle_start, self.light, 0)
		pcall(L.set_spot_angle_end, self.light, math.rad(math.min(spot, 170) / 2))
		local U = game.global("Unit")
		pcall(U.teleport_local_rotation, self.unit, 0, rotation_of(finite_or(o.yaw, 0), finite_or(o.pitch, -45), 0))
		self:settle()
	end
	return true
end

-- The unit's scene node at once, as a stopped world doesn't move it. move() and set() do it themselves.
function LightHandle:settle()
	pcall(game.global("World").update_unit, self.world, self.unit)
end

function LightHandle:move(pos)
	local at = vector(pos)
	if not at or not self:alive() then return false end
	game.global("Unit").teleport_local_position(self.unit, 0, at)
	self:settle()
	return true
end

function LightHandle:remove()
	if self:alive() then pcall(game.global("World").destroy_unit, self.world, self.unit) end
	self.unit = nil
end

local slowed = nil

-- How fast this player's game runs: 0 stops it, 1 is normal speed, anything between is slow motion. Only
-- with nobody else in the lobby, as another player's game would part from this one. A change of screen
-- sets it back to 1.
function M.time_scale(scale)
	if not finite(scale) or scale < 0 or scale > 1 then return false, "out_of_range" end
	if scale < 1 and not game.alone() then return false, "solo_only" end
	if scale >= 1 then
		if slowed then
			rawset(_G, "PAUSED", false)
			rawset(_G, "TIME_SCALE", 1)
		end
		slowed = nil
		return true
	end
	slowed = { state = game.state(), scale = scale }
	rawset(_G, "PAUSED", scale == 0)
	rawset(_G, "TIME_SCALE", scale == 0 and 1 or scale)
	return true
end

-- 1 unless time_scale changed it.
function M.time_now()
	return slowed and slowed.scale or 1
end

-- What a Helldiver is drawn with. The avatar's own unit is never drawn (customization_component.lua:34):
-- the armour, helmet, cape and boots are units of their own, linked to it, and so are the weapons and
-- the backpack it carries (equipment_component.lua:94).
M.AVATAR_PARTS = { "heavy_armor_unit", "all_terrain_boots_unit", "helmet_unit", "cape_unit", "body_unit" }

local function linked_units(unit, out, seen)
	local U = game.global("Unit")
	if seen[unit] then return end
	seen[unit] = true
	out[#out + 1] = unit
	if type(U.children) == "function" then
		local list = {}
		if pcall(U.children, unit, list) then
			for _, child in ipairs(list) do linked_units(child, out, seen) end
		end
	end
end

-- The unit and every unit linked to it that draws as part of it: children, and for a Helldiver the
-- armour parts and what it carries.
function M.parts_of(unit)
	local out, seen = {}, {}
	linked_units(unit, out, seen)
	local custom = game.slaves("customization")[unit]
	local state = type(custom) == "table" and custom.state
	if type(state) == "table" then
		for _, key in ipairs(M.AVATAR_PARTS) do
			if state[key] then linked_units(state[key], out, seen) end
		end
	end
	for item, ctx in pairs(game.slaves("equipment")) do
		if type(ctx) == "table" and type(ctx.state) == "table" and ctx.state.wielder == unit then linked_units(item, out, seen) end
	end
	return out
end

-- Hidden Helldivers: unit -> the size it had.
local shrunk = setmetatable({}, { __mode = "k" })
M.SHRUNK = 1e-4

local function settle_parts(unit)
	local st = game.state()
	local proxy = type(st) == "table" and st.world_proxy
	local world = proxy and proxy:get_world()
	if not world then return end
	local W = game.global("World")
	for _, part in ipairs(M.parts_of(unit)) do pcall(W.update_unit, world, part) end
end

-- A Helldiver's cape: cloth, which doesn't follow a change of size, so it's hidden on its own.
function M.cape_of(unit)
	local custom = game.slaves("customization")[unit]
	local state = type(custom) == "table" and custom.state
	return type(state) == "table" and state.cape_unit or nil
end

-- Whether a unit is drawn, on this machine only: false hides it, shadow and all. Nothing else about it
-- changes. A Helldiver hides whole, armour and what it carries too, by shrinking to nothing and growing
-- back to the size it had: making a unit visible again would also show the meshes the game keeps
-- hidden, such as the stratagem radio. Its cape is cloth and hides on its own.
function M.visible(unit, on)
	local U, V3 = game.global("Unit"), game.global("Vector3")
	local ok, alive = pcall(U.alive, unit)
	if not (ok and alive) then return false, "no_target" end
	if not game.slaves("customization")[unit] then
		return (pcall(U.set_unit_visibility, unit, on ~= false))
	end
	local cape = M.cape_of(unit)
	if on == false then
		if not shrunk[unit] then
			local got, s = pcall(U.local_scale, unit, 0)
			if not got then return false, "no_target" end
			shrunk[unit] = { x = s.x, y = s.y, z = s.z }
		end
		pcall(U.set_local_scale, unit, 0, V3(M.SHRUNK, M.SHRUNK, M.SHRUNK))
		if cape then pcall(U.set_unit_visibility, cape, false) end
	else
		local s = shrunk[unit]
		shrunk[unit] = nil
		if s then pcall(U.set_local_scale, unit, 0, V3(s.x, s.y, s.z)) end
		if cape then pcall(U.set_unit_visibility, cape, true) end
	end
	settle_parts(unit)
	return true
end

-- Whether visible() has a Helldiver hidden.
function M.hidden(unit)
	return shrunk[unit] ~= nil
end

-- How far the engine keeps the most detailed models, as a multiple of the game's own (lod_object_
-- multiplier, a renderer setting). A camera further out than the game's own would see units drop their
-- models, and some vanish. nil gives the game's back. This player's only, and back at a change of screen.
effects.define({ id = "detail",
	apply = function(_, value)
		local app = game.global("Application")
		pcall(app.set_renderer_setting, "lod_object_multiplier", tostring(value))
	end,
	remove = function()
		local app = game.global("Application")
		local ok, own = pcall(app.user_setting, "render_settings", "lod_object_multiplier")
		pcall(app.set_renderer_setting, "lod_object_multiplier", tostring(ok and own or 1))
	end,
})

function M.detail(multiplier)
	if multiplier == nil then return effects.set("detail", false) end
	if not (finite(multiplier) and multiplier >= 1 and multiplier <= 100) then return false, "out_of_range" end
	return effects.set("detail", multiplier)
end

-- A value of the planet's look as the mission set it, before any change through shading(): a number, or
-- a list of 2 or 3. nil where it can't be read.
function M.planet_shading(name)
	local kind = shading_kind(name)
	if not kind then return nil, "unknown_shading" end
	local v = viewport()
	local SE = game.global("ShadingEnvironment")
	local env = v and type(v.get_shading_environment) == "function" and v:get_shading_environment() or nil
	if not (SE and env and SE[kind]) then return nil end
	local set = type(v.variable_values) == "table" and v.variable_values[name]
	if set then
		-- What shading() set is in the environment now: the planet's comes back for a frame without it.
		return nil, "changed"
	end
	local ok, value = pcall(SE[kind], env, name)
	if not ok or value == nil then return nil end
	if kind == "scalar" then return tonumber(value) end
	local out = { tonumber(value.x) or tonumber(value[1]), tonumber(value.y) or tonumber(value[2]) }
	if kind == "vector3" then out[3] = tonumber(value.z) or tonumber(value[3]) end
	if not (out[1] and out[2]) then return nil end
	return out
end

-- A Helldiver's flashlight, on this machine only, as the game lights it on a night mission.
function M.flashlight(unit, on)
	local U = game.global("Unit")
	local ok, alive = pcall(U.alive, unit)
	if not (ok and alive) then return false, "no_target" end
	return (pcall(U.flow_event, unit, on and "flashlight_on" or "flashlight_off"))
end

-- Which way the sunlight comes from in this player's view, as a unit vector pointing at the sun, or
-- nil where there's no sun to read: a sun_direction set through shading() first, else the planet's.
function M.sun()
	local v = viewport()
	if not v then return nil end
	local dir = nil
	-- What shading() set waits in the viewport's own list until the next frame (viewport_proxy.lua:104).
	local set = type(v.variable_values) == "table" and v.variable_values.sun_direction
	if type(set) == "table" and tonumber(set[1]) and tonumber(set[2]) and tonumber(set[3]) then dir = { x = set[1], y = set[2], z = set[3] } end
	if not dir then
		local SE = game.global("ShadingEnvironment")
		local env = type(v.get_shading_environment) == "function" and v:get_shading_environment() or nil
		if not (SE and env and SE.vector3) then return nil end
		local ok, d = pcall(SE.vector3, env, "sun_direction")
		if not (ok and d) then return nil end
		dir = { x = d.x, y = d.y, z = d.z }
	end
	local len = math.sqrt(dir.x * dir.x + dir.y * dir.y + dir.z * dir.z)
	if not (len > 1e-6) then return nil end
	-- The variable points the way the light travels: the sun is the other way.
	return { x = -dir.x / len, y = -dir.y / len, z = -dir.z / len }
end

local TIMES = { dawn = true, day = true, dusk = true, night = true }
local SWAMP = { swamp = true, swamp_dawn = true, swamp_day = true, swamp_dusk = true, swamp_night = true }

local function time_known(name, level)
	return TIMES[name] or (SWAMP[name] and type(level) == "table" and level.environment_name == "forest")
end

-- The time of day of the mission's look: "dawn", "day", "dusk" or "night", or nil for the mission's own.
-- blend, from 0 to 1, mixes in a second one, `towards`: dusk part way to night, say. Forest planets also
-- have "swamp", "swamp_dawn", "swamp_day", "swamp_dusk" and "swamp_night". This player's only.
function M.time_of_day(name, towards, blend)
	local st = game.state()
	local vp = type(st) == "table" and st.viewport
	local level = type(st) == "table" and st.generated_level
	if not (vp and game.in_mission()) then return false, "not_in_mission" end
	if name == nil then
		local own = type(level) == "table" and level.shading_environment_setting
		if own then vp:set_shading_environment_settings(own, 1) end
		return true
	end
	if not time_known(name, level) then return false, "wrong_environment" end
	if towards ~= nil and not time_known(towards, level) then return false, "wrong_environment" end
	local w = finite_or(blend, 0)
	w = math.max(0, math.min(1, w))
	if towards and w > 0 then
		vp:set_shading_environment_settings(name, 1, towards, w)
	else
		vp:set_shading_environment_settings(name, 1)
	end
	return true
end

-- From main.lua, once a frame: what a change of screen gives back.
function M.tick()
	local st = game.state()
	if held and held.state ~= st then
		held = nil
	end
	if slowed and slowed.state ~= st then
		slowed = nil
		rawset(_G, "PAUSED", false)
		rawset(_G, "TIME_SCALE", 1)
	end
end

-- From main.lua: the wrap that moves a taken camera. A wrap, so it runs in any lobby, for client mods.
function M.install()
	local wrap = obsidian.wrap or obsidian.hook
	wrap("CameraManager", "update", function(original, self, ...)
		if held then
			if held.state ~= game.state() then
				held = nil
			else
				local ok, err = pcall(drive, self)
				if ok then return end
				obsidian.log("camera: " .. tostring(err))
				pcall(give_back, self)
				held = nil
			end
		end
		return original(self, ...)
	end)
end

return M
