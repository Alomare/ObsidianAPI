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

local function my_unit()
	local unit = game.my_unit()
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
function M.refill()
	local unit, why = my_unit()
	if not unit then return false, why end
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

function M.refill_grenades()
	local unit, why = my_unit()
	if not unit then return false, why end
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
-- upgrade: a value from 0 to 15, or nil for what the player owns for that weapon. A weapon the
-- player hasn't unlocked is refused.
function M.give_weapon(slot, path, upgrade)
	local unit, why = my_unit()
	if not unit then return false, why end
	local name = catalog.item_name(path)
	if not name then return false, "not_available" end
	local value, problem = upgrade_value(unit, name, upgrade)
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
function M.give_perk(name)
	local unit, why = my_unit()
	if not unit then return false, why end
	if not catalog.unlocked(name) then return false, "not_available" end
	if name == "perk_lasersight" and not game.alone() then return false, "alone_only" end
	for id, perk in ipairs(game.global("LoadoutSettings").perks) do
		if perk.name == name then return change_perk(unit, id, name) end
	end
	return false, "not_available"
end

function M.remove_perk()
	local unit, why = my_unit()
	if not unit then return false, why end
	return change_perk(unit, 0, nil)
end

-- path: a backpack_path from catalog.backpacks. The game reads settings no other path has, outside
-- any pcall, so a path from elsewhere is refused. upgrade as in give_weapon. The old pack drops.
function M.give_backpack(path, upgrade)
	local unit, why = my_unit()
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

return M
