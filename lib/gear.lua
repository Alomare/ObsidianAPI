-- Weapons, ammunition, grenades, perks, backpacks and vehicles of the local player.
local game = obsidian.module("lib/game")
local effects = obsidian.module("lib/effects")

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

-- slot: primary_weapon, sidearm_weapon or support_weapon. The old weapon drops as a pickup.
function M.give_weapon(slot, path)
	local unit, why = my_unit()
	if not unit then return false, why end
	game.command(unit, "inventory", "set_weapon", { weapon_slot = slot, weapon_path = path, upgrade_value = 0, infinite_mags = false, ignore_set_ammo = true })
	return true
end

function M.give_perk(name)
	local unit, why = my_unit()
	if not unit then return false, why end
	game.command(unit, "inventory", "set_perk", name)
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
