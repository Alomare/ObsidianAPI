-- The vehicle under the player. Driving makes a vehicle this peer's, a moment after getting in, so
-- these effects wait for that, and each one takes back what it changed when the player gets out.
-- Speed goes through the mover's multiplier, as the player's own speed does. The mover's speed itself
-- is under the tamper check.
local game = obsidian.module("lib/game")
local effects = obsidian.module("lib/effects")
local gear = obsidian.module("lib/gear")

local M = {}

local function aux()
	return game.global("EntityAux")
end

function M.current()
	if not game.in_mission() then return nil end
	return gear.current_vehicle()
end

-- The vehicle this player is driving, once it's theirs.
function M.driven()
	local v = M.current()
	if v and game.master(v, "vehicle") then return v end
	return nil
end

function M.driving()
	return M.driven() ~= nil
end

-- def: id, enter(v, value) once per vehicle, frame(v, value) each frame, leave(v).
local function on_vehicle(def)
	local held = nil
	local function let_go()
		if held and def.leave then def.leave(held) end
		held = nil
	end
	effects.define({ id = def.id,
		apply = function(_, value)
			if held and def.enter then def.enter(held, value) end
		end,
		frame = function(_, value)
			local v = M.driven()
			if v ~= held then
				let_go()
				held = v
				if v and def.enter then def.enter(v, value) end
			end
			if v and def.frame then def.frame(v, value) end
		end,
		remove = let_go,
	})
end

on_vehicle({ id = "vehicle_speed",
	enter = function(v, value)
		local mover = game.master(v, "mover")
		if mover then mover.velocity_scale = value end
	end,
	leave = function(v)
		local mover = game.master(v, "mover")
		if mover then mover.velocity_scale = nil end
	end,
})

-- Walkers turn by a blend factor under 1, where less is quicker and 1 stands still. Wheels and tracks
-- turn in degrees a second, where 0 stands still. The vehicle's own states write the field as they
-- change, so it's set each frame, and left alone in the states that stand still.
local STOPPED = { exosuit = 1, apc = 0, bike = 0 }

local function turn_speed(state, value)
	local info = state.vehicle_info
	local stopped = STOPPED[info.vehicle_type]
	if stopped == nil or state.rotation_speed == stopped then return nil end
	if info.vehicle_type == "exosuit" then return info.turn_speed ^ value end
	return info.turn_speed * value
end

on_vehicle({ id = "vehicle_turn",
	frame = function(v, value)
		local state = game.master(v, "vehicle")
		local speed = state and turn_speed(state, value)
		if speed then state.rotation_speed = speed end
	end,
	leave = function(v)
		local state = game.master(v, "vehicle")
		if state and turn_speed(state, 1) then state.rotation_speed = state.vehicle_info.turn_speed end
	end,
})

-- Armor lives twice: the guarded copy on the master, and the copy the damage sums read.
local function set_armor(v, low, high)
	local data = { armor_min = low, armor_max = high }
	game.command(v, "health", "armor", data)
	aux().queue_command_slave(v, "health", "armor", data)
end

on_vehicle({ id = "vehicle_armor",
	enter = function(v, value) set_armor(v, value, value) end,
	leave = function(v)
		local settings = game.global("LoadoutSettings").get_upgraded_settings(v)
		local health = settings and settings.health_info
		if health then set_armor(v, health.armor_min, health.armor_max) end
	end,
})

on_vehicle({ id = "vehicle_god",
	enter = function(v) game.command(v, "health", "set_invincible", true) end,
	leave = function(v) game.command(v, "health", "set_invincible", false) end,
})

-- Only a refill reaches the exosuit's rockets, and the frame function repeats it.
on_vehicle({ id = "vehicle_rockets",
	frame = function(v)
		local inventory = game.master(v, "exosuit_inventory")
		if inventory and inventory.num_grenades and inventory.num_grenades < 8 then game.command(v, "exosuit_inventory", "set_full_ammo") end
	end,
})

M.repair = gear.repair_vehicle
M.refill = gear.refill_vehicle

return M
