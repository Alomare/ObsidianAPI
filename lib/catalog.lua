-- Game content by name. Lists come from the game's own tables where it has them, and paid content
-- a player doesn't own is left out: DLC stays paid.
local game = obsidian.module("lib/game")
local data = obsidian.module("lib/data")

local M = {}

local function pretty(key)
	local s = string.gsub(tostring(key), "^%a+_", "")
	s = string.gsub(s, "_", " ")
	return string.upper(string.sub(s, 1, 1)) .. string.sub(s, 2)
end

-- A display name in the game's language. The menu's font covers Latin-1, so anything beyond that
-- falls back to a readable form of the key rather than a row of boxes.
function M.text(key)
	local lm = game.global("LocalizationManager")
	if type(lm) == "table" and key and key ~= "" then
		local ok, s = pcall(lm.string, lm, key)
		if ok and type(s) == "string" and string.sub(s, 1, 4) ~= "LOC:" and not string.find(s, "[\196-\244]") then return s end
	end
	return pretty(key)
end

local function entitlements()
	local save, user = game.global("SaveManager"), game.global("UserManager")
	if not (save and user) then return {} end
	local ok, ents = pcall(function() return save:user_get("entitlements", user:get_user_id()) end)
	return ok and ents or {}
end

-- False for an item of a paid pack this player doesn't own.
function M.usable(name)
	local dlc = game.global("DlcSettings")
	if not (dlc and dlc.is_item_dlc and dlc.can_use) then return true end
	local ok, is_dlc = pcall(dlc.is_item_dlc, name)
	if not ok or not is_dlc then return true end
	local ok2, can = pcall(dlc.can_use, name, entitlements())
	return ok2 and can == true
end

local function loadout(category)
	local settings = game.global("LoadoutSettings")
	local out = {}
	for _, item in ipairs(settings and settings[category] or {}) do
		if M.usable(item.name) then out[#out + 1] = item end
	end
	return out
end

function M.primaries() return loadout("primary_weapon") end
function M.sidearms() return loadout("sidearm_weapon") end
function M.stratagems() return loadout("stratagems") end
function M.perks() return loadout("perks") end

-- Support weapons are stratagems whose crate holds the weapon: { name, unit_path }.
function M.support_weapons()
	local lsm = game.global("LuaSettingsManager")
	local out = {}
	if not lsm then return out end
	for _, s in ipairs(M.stratagems()) do
		local is_support = false
		for _, sub in ipairs(s.stratagem_subtypes or {}) do
			if sub == "support_weapon" then is_support = true end
		end
		local crate = is_support and s.unit and lsm:get_settings_by_unit_path(s.unit)
		local content = crate and crate.supply_crate_info and crate.supply_crate_info.content
		local pickup = content and content[1] and content[1].unit_path
		local path = pickup and lsm:get_settings_path_by_unit_path(pickup)
		if path then out[#out + 1] = { name = s.name, unit_path = path } end
	end
	return out
end

function M.stratagem(name)
	for _, s in ipairs(M.stratagems()) do
		if s.name == name then return s end
	end
	return nil
end

function M.cosmetics(slot)
	local settings = game.global("CustomizationSettings")
	local out = {}
	for i, item in ipairs(settings and settings[slot] or {}) do
		if not item.name or M.usable(item.name) then out[#out + 1] = { index = i, name = item.name } end
	end
	return out
end

function M.status_templates()
	local t = game.global("StatusTemplateSettings")
	local out = {}
	for name in pairs(t or {}) do out[#out + 1] = name end
	table.sort(out)
	return out
end

-- Every enemy: { key, name, loc, faction, unit, settings, boss, console, packages }.
function M.enemies(faction)
	local out = {}
	for _, e in ipairs(data.enemies) do
		if not faction or e.faction == faction then out[#out + 1] = e end
	end
	return out
end

function M.enemy(key)
	for _, e in ipairs(data.enemies) do
		if e.key == key or e.unit == key then return e end
	end
	return nil
end

function M.enemy_groups()
	local groups = game.global("EnemyGroupSettings")
	local out = {}
	for key in pairs(groups or {}) do out[#out + 1] = key end
	table.sort(out)
	return out
end

-- Editable fields of a family, as listed in data.lua.
function M.fields(family)
	local out = {}
	for _, f in ipairs(data.fields) do
		if f.family == family then out[#out + 1] = f end
	end
	return out
end

-- The families a settings table has fields for, judged by what it holds.
function M.families_of(settings)
	local out = {}
	local w = settings.weapon_info
	if w then
		if w.heat_increase then out[#out + 1] = "beam"
		elseif w.rounds_per_second then out[#out + 1] = "flame"
		elseif w.min_power then out[#out + 1] = "arc"
		elseif w.projectile then out[#out + 1] = "launcher"
		else out[#out + 1] = "firearm" end
	end
	if settings.explosive_info then out[#out + 1] = "explosive" end
	if settings.throwable_info then out[#out + 1] = "grenade" end
	if settings.melee_info then out[#out + 1] = "melee" end
	if settings.turret_info then out[#out + 1] = "turret" end
	if settings.enemy_info then out[#out + 1] = "enemy" end
	return out
end

return M
