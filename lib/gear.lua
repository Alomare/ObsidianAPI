-- Weapons, ammunition, grenades, perks, backpacks and vehicles of the local player.
local game = obsidian.module("lib/game")
local effects = obsidian.module("lib/effects")
local catalog = obsidian.module("lib/catalog")

local M = {}

local AMMO_COMPONENTS = { "firearm", "launcher", "flameweapon", "beamweapon", "throwable_weapon" }
local RELOAD_COMPONENTS = { "firearm", "flameweapon" }
local WEAPON_SLOTS = { "primary_weapon", "sidearm_weapon", "support_weapon" }

local function aux()
	return game.global("EntityAux")
end

-- unit: a player on this machine, the main one when nil.
local function my_unit(unit)
	unit = unit or game.my_unit()
	if not unit then return nil, "no_avatar" end
	return unit
end

local function inventory(unit)
	return game.master(unit, "inventory")
end

local function alive(unit)
	return unit and game.global("Unit").alive(unit)
end

effects.define({ id = "infinite_ammo",
	apply = function()
		for _, name in ipairs(AMMO_COMPONENTS) do
			local c = game.component(name)
			if c then c.infinite_ammo = true end
		end
	end,
	remove = function()
		for _, name in ipairs(AMMO_COMPONENTS) do
			local c = game.component(name)
			if c then c.infinite_ammo = false end
		end
	end,
})

-- The reload timer is under the tamper check, so it's shortened through the game's setter, once
-- per reload. Other weapon kinds read their reload time from the settings (see edits).
effects.define({ id = "instant_reload",
	frame = function(ctx)
		local inv = inventory(ctx.unit)
		local weapon = inv and inv.current_weapon
		if not alive(weapon) then return end
		for _, name in ipairs(RELOAD_COMPONENTS) do
			local state = game.master(weapon, name)
			if state and state.is_reloading and type(state.reload_time) == "number" and state.reload_time > 0.02 then
				game.protected(name, state, "reload_time", 0.01)
			end
		end
	end,
})

-- Fills every weapon. For beam weapons the rounds value is heat, so full means zero.
function M.refill(unit)
	if not unit then
		local why
		unit, why = my_unit()
		if not unit then return false, why end
	end
	local inv = inventory(unit)
	if not inv then return false, "no_avatar" end
	for _, slot in ipairs(WEAPON_SLOTS) do
		local weapon = inv[slot]
		if alive(weapon) and aux().has_interface(weapon, "weapon") then
			local beam = aux().has_component(weapon, "beamweapon")
			aux().queue_command_master_interface(weapon, "weapon", "set_ammo", { num_rounds = beam and 0 or 1000000, num_mags = 1000000 })
		end
	end
	game.command(unit, "inventory", "set_grenades", 2)
	return true
end

function M.refill_grenades(unit)
	if not unit then
		local why
		unit, why = my_unit()
		if not unit then return false, why end
	end
	game.command(unit, "inventory", "set_grenades", 2)
	return true
end

-- grenade type: equipment/equipment_grenade_01, _incendiary, _stun or _smoke.
function M.set_grenade(path)
	local unit, why = my_unit()
	if not unit then return false, why end
	game.command(unit, "inventory", "set_grenade_path", path)
	return true
end

-- The upgrade a new item gets: the one asked for, or what the player owns for it. The game keeps
-- those by item name, and the upgradeable component asserts outside 0 to 15.
local function upgrade_value(unit, name, upgrade)
	if upgrade == nil then
		local inv = inventory(unit)
		local owned = inv and inv.item_upgrades
		return owned and name and owned[name] or 0
	end
	if type(upgrade) ~= "number" or upgrade % 1 ~= 0 or upgrade < 0 or upgrade > 15 then return nil, "out_of_range" end
	return upgrade
end

-- slot: primary_weapon, sidearm_weapon or support_weapon. The old weapon drops as a pickup.
-- upgrade: a value from 0 to 15, or nil for what the player owns for that weapon. A paid weapon the
-- player doesn't own is refused. unit: a player on this machine, the main one by default.
function M.give_weapon(slot, path, upgrade, unit)
	local unit, why = my_unit(unit)
	if not unit then return false, why end
	if catalog.unowned_path(path) then return false, "not_available" end
	local value, problem = upgrade_value(unit, catalog.item_name(path), upgrade)
	if not value then return false, problem end
	game.command(unit, "inventory", "set_weapon", { weapon_slot = slot, weapon_path = path, upgrade_value = value, infinite_mags = false, ignore_set_ammo = true })
	return true
end

-- What the game's console does to change a perk, with two differences: this also starts from no perk,
-- where the console stops on an error, and it marks the state dirty, so peers hear of it.
local function change_perk(unit, id, name)
	local c, perks = game.component("inventory"), game.global("PerkSettings")
	local master, slave = inventory(unit), aux().state(unit, "inventory")
	if not (c and perks and master) then return false, "no_avatar" end
	local list = game.global("LoadoutSettings").perks
	local old = master.perk and master.perk > 0 and perks[list[master.perk].name]
	if old and old.remove_master then old.remove_master(unit, c, master.perk_context) end
	if old and old.remove_slave and slave then old.remove_slave(unit, c, slave.perk_context) end
	master.perk_context, master.perk = {}, id
	if slave then slave.perk_context, slave.perk = {}, id end
	local new = name and perks[name]
	if new and new.setup_master then new.setup_master(unit, c, master.perk_context) end
	if new and new.setup_slave and slave then new.setup_slave(unit, c, slave.perk_context) end
	master.dirty = true
	return true
end

-- Every other peer picks the new perk up with no setup, and laser sight's per-frame code needs its
-- setup, so that one would fail inside their update. It's kept to solo play.
function M.give_perk(name, unit)
	local unit, why = my_unit(unit)
	if not unit then return false, why end
	if not catalog.usable(name) then return false, "not_available" end
	if name == "perk_lasersight" and not game.alone() then return false, "alone_only" end
	for id, perk in ipairs(game.global("LoadoutSettings").perks) do
		if perk.name == name then return change_perk(unit, id, name) end
	end
	return false, "not_available"
end

function M.remove_perk(unit)
	local unit, why = my_unit(unit)
	if not unit then return false, why end
	return change_perk(unit, 0, nil)
end

-- Perks on top of the main one. A perk's setup runs for this unit with a context of its own. The game
-- runs per-frame perk code for the main perk alone, so a perk that has any isn't offered.
local extras = setmetatable({}, { __mode = "k" })

local function plain_perk(name)
	local perk = game.global("PerkSettings")[name]
	if not perk or not catalog.usable(name) then return nil end
	if perk.update_master or perk.update_slave or perk.remove_slave then return nil end
	return perk
end

-- unit: nil for the local player. A new body after a death starts with none.
function M.add_perk(name, unit)
	if not unit then
		local why
		unit, why = my_unit()
		if not unit then return false, why end
	end
	local c, master = game.component("inventory"), inventory(unit)
	if not (c and master) then return false, "no_avatar" end
	local perk = plain_perk(name)
	if not perk then return false, "not_available" end
	local list = game.global("LoadoutSettings").perks
	local main = master.perk and master.perk > 0 and list[master.perk]
	local mine = extras[unit] or {}
	if (main and main.name == name) or mine[name] then return true end
	local context = {}
	if perk.setup_master then perk.setup_master(unit, c, context) end
	if perk.setup_slave then perk.setup_slave(unit, c, context) end
	mine[name] = context
	extras[unit] = mine
	return true
end

function M.remove_extra_perk(name, unit)
	if not unit then
		local why
		unit, why = my_unit()
		if not unit then return false, why end
	end
	local mine = extras[unit]
	local context = mine and mine[name]
	if not context then return true end
	local perk = game.global("PerkSettings")[name]
	if perk and perk.remove_master then perk.remove_master(unit, game.component("inventory"), context) end
	mine[name] = nil
	return true
end

-- The names of the perks added on top, sorted.
function M.extra_perks(unit)
	local out = {}
	unit = unit or game.my_unit()
	for name in pairs(unit and extras[unit] or {}) do out[#out + 1] = name end
	table.sort(out)
	return out
end

-- path: a backpack_path from catalog.backpacks. The game reads settings no other path has, outside
-- any pcall, so a path from elsewhere is refused. upgrade and unit as in give_weapon. The old pack drops.
function M.give_backpack(path, upgrade, unit)
	local unit, why = my_unit(unit)
	if not unit then return false, why end
	local item = catalog.backpack(path)
	if not item then return false, "not_available" end
	local value, problem = upgrade_value(unit, item.stratagem, upgrade)
	if not value then return false, problem end
	local settings = game.global("LuaSettingsManager"):get_modified_settings(path, value)
	local info = settings and settings.backpack_info
	game.command(unit, "inventory", "set_backpack", { backpack_path = path, num_uses = info and info.num_uses or 0, upgrade_value = value })
	return true
end

-- Drones with no backpack to carry: a drone pack's station rides on a player outside the backpack slot,
-- as the game's set_backpack spawns it, with its drones. The drones need the station: they dock on it,
-- reload from it and fly around it. Every machine running this hides a station that isn't its player's
-- backpack (M.tick), so only the drones show. The station goes when its player dies, as a worn pack
-- drops, and its drones go with it.
-- path: a backpack_path from catalog.backpacks that has drones. unit: a player on this machine, the
-- main one by default. upgrade as in give_weapon. Answers a drone with :alive() and :remove(), or nil
-- and a reason.
local Drone = {}
Drone.__index = Drone
local drones = {}
local hidden = setmetatable({}, { __mode = "k" })

function M.add_drone(path, unit, upgrade)
	if type(path) ~= "string" then return nil, "bad_type" end
	if not unit then
		local why
		unit, why = my_unit()
		if not unit then return nil, why end
	end
	local health = alive(unit) and game.master(unit, "health")
	if not (health and inventory(unit)) or health.is_dead then return nil, "no_avatar" end
	local item = catalog.backpack(path)
	if not item then return nil, "not_available" end
	local value, problem = upgrade_value(unit, item.stratagem, upgrade)
	if not value then return nil, problem end
	local settings = game.global("LuaSettingsManager"):get_modified_settings(path, value)
	local children = settings and settings.pickup_info and settings.pickup_info.child_unit_paths
	if not (settings and settings.drone_station_info and children) then return nil, "not_available" end
	local st = game.state()
	if not (game.in_mission() and st.entity_spawner) then return nil, "not_in_mission" end
	local spawner = st.entity_spawner
	local station = spawner:spawn_entity(path, nil, nil, nil, { upgrade_value = value, wielder_unit = unit })
	if not alive(station) then return nil, "unknown" end
	for _, child in pairs(children) do
		spawner:spawn_entity(child, nil, nil, nil, { station_unit = station, upgrade_value = value })
	end
	local info = settings.backpack_info
	aux().queue_command_interface(station, "backpack", "set_uses", info and info.num_uses or 1)
	game.command(station, "equipment", "wielder", unit)
	game.command(station, "equipment", "wield")
	local d = setmetatable({ station = station, owner = unit, docked = false }, Drone)
	drones[#drones + 1] = d
	return d
end

function Drone:alive()
	return alive(self.station) == true
end

-- Only the station goes, as when the game drops a pack: a drone without its station takes itself away.
function Drone:remove()
	local st = game.state()
	if self:alive() and type(st) == "table" and st.entity_spawner then pcall(st.entity_spawner.despawn_entity, st.entity_spawner, self.station) end
	self.station = nil
end

local function seated(unit)
	local seat = game.global("CharacterStateSeated")
	local ok, character = pcall(aux().state, unit, "character")
	return seat ~= nil and ok and type(character) == "table" and character.current_state == seat
end

-- In a vehicle the game docks a worn pack's drones, and so for these.
local function keep_drone(d)
	local health = alive(d.owner) and game.master(d.owner, "health")
	if not health or health.is_dead then
		d:remove()
		return false
	end
	local station = game.master(d.station, "drone_station")
	local sit = seated(d.owner)
	if station and alive(station.drone_unit) and sit ~= d.docked then
		d.docked = sit
		game.command(d.station, "drone_station", "set_force_dock", sit)
	end
	return true
end

function M.tick()
	if #drones > 0 then
		local kept = {}
		for _, d in ipairs(drones) do
			if d:alive() and keep_drone(d) then kept[#kept + 1] = d end
		end
		drones = kept
	end
	-- Anyone's station on anyone's player: seen only while it's that player's backpack.
	local units = game.global("Unit")
	for station, ctx in pairs(game.slaves("equipment")) do
		if aux().has_component(station, "drone_station") then
			local wielder = ctx.state and ctx.state.wielder
			local inv = alive(wielder) and aux().state(wielder, "inventory")
			local loose = type(inv) == "table" and inv.backpack ~= station
			if loose or hidden[station] then
				pcall(units.set_unit_visibility, station, not loose)
				hidden[station] = loose or nil
			end
		end
	end
end

function M.refill_backpack()
	local unit, why = my_unit()
	if not unit then return false, why end
	local inv = inventory(unit)
	local pack = inv and inv.backpack
	if not (alive(pack) and aux().has_interface(pack, "backpack")) then return false, "no_backpack" end
	local state = aux().state_master_interface(pack, "backpack")
	local most = state and state.backpack_info and state.backpack_info.num_uses_max
	if not most then return false, "no_backpack" end
	aux().queue_command_master_interface(pack, "backpack", "set_uses", most)
	return true
end

-- The vehicle under the player, once driving has made it this peer's.
local function vehicle()
	local unit = game.my_unit()
	local character = game.master(unit, "character")
	local seat = character and character.current_seat_unit
	if alive(seat) then return seat end
	return nil
end
M.current_vehicle = vehicle

function M.repair_vehicle()
	local v = vehicle()
	if not v then return false, "no_vehicle" end
	if not game.command(v, "health", "reset") then return false, "not_driving" end
	return true
end

function M.refill_vehicle()
	local v = vehicle()
	if not v then return false, "no_vehicle" end
	if aux().has_interface(v, "weapon") then
		aux().queue_command_master_interface(v, "weapon", "set_ammo", { num_rounds = 1000000, num_mags = 1000000 })
	end
	game.command(v, "exosuit_inventory", "set_full_ammo")
	-- Some vehicles carry their guns as units of their own, such as the arms of the second exosuit.
	local seat = game.master(v, "seat")
	for _, weapon in ipairs(seat and seat.seat_weapon_units or {}) do
		if weapon ~= v and alive(weapon) and aux().owned(weapon) and aux().has_interface(weapon, "weapon") then
			aux().queue_command_master_interface(weapon, "weapon", "set_ammo", { num_rounds = 1000000, num_mags = 1000000 })
		end
	end
	return true
end

-- Fields cached on live weapons take a settings change when reloaded this way. Loaded rounds stay,
-- so a bigger magazine shows after the next reload.
function M.refresh()
	for _, name in ipairs({ "firearm", "beamweapon", "flameweapon", "arcweapon", "launcher", "turret", "launcher_turret" }) do
		local c = game.component(name)
		if c then
			if c.reload_master then
				for unit, ctx in pairs(game.masters(name)) do c:reload_master(unit, ctx) end
			end
			if c.reload_slave then
				for unit, ctx in pairs(game.slaves(name)) do c:reload_slave(unit, ctx) end
			end
		end
	end
	return true
end

-- One weapon's own stats. A weapon's settings are shared by every weapon of its type on a machine, but
-- each weapon's state points at them and keeps copies of some, so a private copy changes this weapon
-- alone: another player's, or a second one of the same type, stays as it is.
local TUNED = { "firearm", "beamweapon", "arcweapon", "flameweapon", "launcher" }
local ANGLES = { spread = true, spread_min = true, spread_max = true }
local GUARDED = { magazine_capacity = true }

-- The weapons a player's unit holds: { unit, component, slot, info }, where slot is primary_weapon,
-- sidearm_weapon or support_weapon, and info the weapon's settings before any tuning. owner: nil for
-- the main player.
function M.weapons_of(owner)
	owner = owner or game.my_unit()
	local out = {}
	local inv = owner and inventory(owner)
	if not inv then return out end
	for _, slot in ipairs(WEAPON_SLOTS) do
		local weapon = inv[slot]
		if alive(weapon) then
			for _, component in ipairs(TUNED) do
				local master = game.masters(component)[weapon]
				if master then
					out[#out + 1] = { unit = weapon, component = component, slot = slot, info = master.state.tuned_base or master.state.weapon_info }
					break
				end
			end
		end
	end
	return out
end

local function copy(t)
	local out = {}
	for k, v in pairs(t or {}) do out[k] = v end
	return out
end

-- Where a component keeps the settings it reads: a weapon's weapon_info, a weapon's melee its melee_info.
local SETTINGS = { melee = "melee_info" }

local function tune_state(c, state, changes, master, field)
	if type(state[field]) ~= "table" then return false end
	-- The game can hand the weapon new settings, on an upgrade: those are the base from then on.
	if state[field] ~= state.tuned_own then state.tuned_base = state[field] end
	local base = state.tuned_base
	local own = copy(base)
	own.attributes = base.attributes and copy(base.attributes)
	-- A field its settings leave out takes the game's default, which the state holds.
	state.tuned_start = state.tuned_start or {}
	for key, value in pairs(changes) do
		if type(value) == "boolean" then
			own.attributes = own.attributes or {}
			own.attributes[key] = value
		else
			if type(base[key]) ~= "number" and not ANGLES[key] and type(state[key]) == "number" and state.tuned_start[key] == nil then
				state.tuned_start[key] = state[key]
			end
			local from = base[key]
			if type(from) ~= "number" then from = state.tuned_start[key] end
			if type(from) == "number" then own[key] = from * value end
		end
	end
	state[field], state.tuned_own = own, own
	local keys = copy(state.tuned_keys)
	for key in pairs(changes) do keys[key] = true end
	for key in pairs(keys) do
		local n = own[key]
		if type(n) ~= "number" then n = state.tuned_start[key] end
		if type(n) == "number" then
			if key == "firerate" then
				if state.round_delay ~= nil then state.round_delay = 60 / n end
			elseif ANGLES[key] then
				if state[key] ~= nil then state[key] = math.rad(n) end
			elseif GUARDED[key] then
				if state[key] ~= nil then
					n = math.ceil(n)
					if master then c:set_protected(state, key, n) else state[key] = n end
				end
			elseif state[key] ~= nil then
				state[key] = n
			end
		end
	end
	state.tuned_keys = copy(changes)
	if master then state.dirty = true end
	return true
end

-- changes: { field = factor } on a number of its settings, { attribute = true or false } on one of its
-- attributes. It replaces the tuning before; {} takes it all off. It reaches only this machine's own
-- weapons, and each player runs it for theirs. component "melee" tunes the weapon's melee attack:
-- power, and duration and delay for how soon it hits and the next can start.
function M.tune(unit, component, changes)
	if type(changes) ~= "table" then return false, "bad_type" end
	local c = game.component(component)
	local master = game.masters(component)[unit]
	if not (c and master) then return false, "unknown" end
	local field = SETTINGS[component] or "weapon_info"
	tune_state(c, master.state, changes, true, field)
	local slave = game.slaves(component)[unit]
	if slave then
		tune_state(c, slave.state, changes, false, field)
		-- The shot's hit test keeps the settings it was made with.
		if c.remake_raycast then c:remake_raycast(unit, slave) end
	end
	return true
end

return M
