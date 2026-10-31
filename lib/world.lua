-- Time, camera, HUD, the look of the world, and finding a place in it.
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
