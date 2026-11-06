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

-- Seats: every unit with a seat component, which the game shares with every peer, so these read the
-- shared state and work for any vehicle, whoever owns it. A seat's settings (seat_info) name its door
-- (enter_node) and the actor a Helldiver uses to get in; its state lists who sits where (seated_units),
-- its guns (seat_weapon_units) and the seat each gun belongs to (weapon_index_to_seat), and whether the
-- seats are on (enabled, off until a vehicle has landed). A gun fires on the second trigger when its
-- stationary_info says fire_input_field "throw" (StationaryWeaponComponent), on the trigger otherwise.
-- An exosuit's own gun is the exosuit's, and the first exosuit throws grenades on the second trigger
-- (vehicle_info.has_grenade_launcher).

local function alive(unit)
	return unit ~= nil and game.global("Unit").alive(unit)
end

local function settings_of(unit)
	local ls = game.global("LoadoutSettings")
	if not (ls and ls.get_upgraded_settings) then return nil end
	local ok, s = pcall(ls.get_upgraded_settings, unit)
	return ok and type(s) == "table" and s or nil
end

local function shared(unit, component)
	local ok, s = pcall(aux().state, unit, component)
	return ok and type(s) == "table" and s or nil
end

local function seat_state(v)
	if not alive(v) then return nil end
	return shared(v, "seat")
end

-- The settings of one seat of a vehicle (seat_info), or nil.
function M.seat_settings(v, index)
	local s = seat_state(v) and settings_of(v)
	return s and type(s.seat_info) == "table" and s.seat_info[index] or nil
end

-- What a vehicle is: "exosuit", "apc", "bike", "tank" (the tank destroyer, driven a track on each stick),
-- or "turret" (a mannable turret). nil for a unit with no seats.
function M.kind(v)
	if not seat_state(v) then return nil end
	local s = settings_of(v)
	local info = s and s.vehicle_info
	if not info then return "turret" end
	if info.input_type == "tank" then return "tank" end
	if info.vehicle_type == "mannable_turret" then return "turret" end
	return info.vehicle_type
end

-- The seats of a vehicle in the game's order: { index, name, drives, unit, free, weapons } each. drives is
-- true for the seat that steers, unit is who sits there (nil for nobody), free is true for an empty seat
-- the game lets someone into, and weapons lists the guns that seat fires: { unit, trigger } each, where
-- trigger is "primary" (the fire button) or "secondary" (the second trigger: the tank's machine gun, an
-- exosuit's left arm, the first exosuit's grenades). {} for a unit with no seats.
function M.seats(v)
	local state = seat_state(v)
	local s = state and settings_of(v)
	local info = s and s.seat_info
	if type(info) ~= "table" then return {} end
	local vinfo = s.vehicle_info
	local out = {}
	for i, seat in ipairs(info) do
		local who = state.seated_units and state.seated_units[i]
		if not alive(who) then who = nil end
		out[i] = { index = i, name = seat.name, drives = i == 1 and vinfo ~= nil, unit = who, free = state.enabled ~= false and who == nil, weapons = {} }
	end
	local weapons = state.seat_weapon_units or {}
	local function add(index, unit, trigger)
		if out[index] then
			local list = out[index].weapons
			list[#list + 1] = { unit = unit, trigger = trigger }
		end
	end
	for w, index in ipairs(state.weapon_index_to_seat or {}) do
		local unit = weapons[w]
		if alive(unit) and unit ~= v then
			local ws = settings_of(unit)
			local field = ws and ws.stationary_info and ws.stationary_info.fire_input_field
			add(index, unit, field == "throw" and "secondary" or "primary")
		end
	end
	if vinfo and vinfo.vehicle_type == "exosuit" then
		if aux().has_interface(v, "weapon") then add(1, v, "primary") end
		if vinfo.has_grenade_launcher then add(1, v, "secondary") end
	end
	return out
end

-- The vehicle a Helldiver sits in and the seat's index, or nil. unit: the player's when nil.
function M.seat_of(unit)
	unit = unit or game.my_unit()
	if not alive(unit) then return nil end
	local cs = game.master(unit, "character") or shared(unit, "character")
	local v = cs and cs.current_seat_unit
	if alive(v) then return v, cs.current_seat_index end
	return nil
end

local function standing(v)
	local h = shared(v, "health")
	return not (h and h.is_dead)
end

-- Vehicles, exosuits and mannable turrets within radius (10 metres) of a position, or of the player,
-- nearest first. A destroyed one isn't listed.
function M.near(pos, radius)
	local units, v3 = game.global("Unit"), game.global("Vector3")
	if not pos then
		local me = game.my_unit()
		if not me then return {} end
		pos = units.world_position(me, 0)
	end
	local ok, x, y, z = pcall(function() return pos.x, pos.y, pos.z end)
	if not (ok and type(x) == "number" and type(y) == "number") then return {} end
	local at = v3(x, y, type(z) == "number" and z or 0)
	radius = tonumber(radius) or 10
	local found, distances = {}, {}
	for v in pairs(game.slaves("seat")) do
		if alive(v) and standing(v) then
			local d = v3.distance(units.world_position(v, 0), at)
			if d <= radius then
				found[#found + 1] = v
				distances[v] = d
			end
		end
	end
	table.sort(found, function(a, b) return distances[a] < distances[b] end)
	return found, distances
end

-- The vehicle nearest to a position within radius (4 metres), and how far it is: the one under the
-- cursor with api.world.cursor(). nil when there's none.
function M.nearest(pos, radius)
	local found, distances = M.near(pos, radius or 4)
	local v = found[1]
	if not v then return nil end
	return v, distances[v]
end

return M
