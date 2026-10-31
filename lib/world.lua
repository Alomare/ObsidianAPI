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

-- Camera. change_settings has to be used: follow_distance alone is rewritten every frame.
effects.define({ id = "camera_distance",
	apply = function(_, value) camera():change_settings(nil, value, nil, nil) end,
	remove = function() camera():change_settings(nil, 17, nil, nil) end,
})

effects.define({ id = "camera_angle",
	apply = function(_, value) camera():change_settings(nil, nil, value, nil) end,
	remove = function() camera():change_settings(nil, nil, 65, nil) end,
})

effects.define({ id = "free_camera_bounds",
	apply = function() camera():set_ignore_level_bounds(true) end,
	remove = function() camera():set_ignore_level_bounds(false) end,
})

-- Checked inside the hook on add_shake in main.lua, since shakes aren't state to set or clear.
effects.define({ id = "no_camera_shake" })

-- The manager is one table that each state sets up again, so these go back on after a change of
-- state. 60 degrees and a spin of -45 are what a mission starts with (state_game.lua:196).
effects.define({ id = "camera_fov",
	apply = function(_, value) camera():set_fov(math.rad(value)) end,
	remove = function() camera():set_fov(math.rad(60)) end,
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

effects.define({ id = "photo_mode",
	apply = function(ctx)
		if ctx.name ~= "game" then return end
		camera():set_state("fully_static")
		photo_screen(ctx.state, false)
		if not effects.is_on("hide_hud") then
			photo_hid_hud = true
			effects.set("hide_hud", true)
		end
	end,
	remove = function(ctx)
		if ctx.name == "game" then
			camera():set_state("follow")
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

-- unit: another player's avatar, from game.all_avatars. nil comes back to this player.
function M.camera.spectate(unit)
	if unit == nil then return effects.set("camera_spectate", false) end
	for _, p in ipairs(game.all_avatars()) do
		if p.unit == unit then return effects.set("camera_spectate", unit) end
	end
	return false, "no_avatar"
end

-- Freezes the camera and clears the screen. Mission only.
function M.camera.photo(on)
	if on and not game.in_mission() then return false, "not_in_mission" end
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
-- keeps a name from going to the engine as the wrong type.
local SHADING = {
	scalar = { "exposure", "dof_amount", "ambient_camera_falloff", "sun_enabled", "ssao_radius", "ssao_strength", "vignette_opacity", "color_grading_enabled" },
	vector2 = { "fog_depth_range", "dof_near_setting", "dof_far_setting", "bloom_threshold_offset" },
	vector3 = { "fog_color", "fog_sun_blend", "sun_color", "sun_direction", "ambient_top_color", "ambient_bottom_color" },
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

-- A position some metres in front of the avatar.
function M.ahead(metres)
	local unit = game.my_unit()
	if not unit then return nil end
	local units, q = game.global("Unit"), game.global("Quaternion")
	return units.world_position(unit, 0) + q.forward(units.local_rotation(unit, 0)) * metres
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

return M
