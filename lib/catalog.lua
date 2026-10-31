-- Game content by name. Lists come from the game's own tables where it has them, and what a player
-- hasn't unlocked is left out, as the Loadout screen does: locked items stay locked, and DLC stays paid.
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

local earned = { xp = nil, count = nil, names = nil }

local function add_all(names, list)
	for _, name in ipairs(list or {}) do names[name] = true end
end

-- What this player has by rank, by reward and from the start. Looked at again when the XP or the list
-- of rewards changes. nil before there's a save to read.
local function earned_names()
	local save, users = game.global("SaveManager"), game.global("UserManager")
	if not (save and users) then return nil end
	local id = users:get_user_id()
	local xp, rewards = save:user_get("player_xp", id) or 0, save:user_get("item_unlocks", id) or {}
	if earned.names and earned.xp == xp and earned.count == #rewards then return earned.names end
	local names = {}
	add_all(names, rewards)
	local settings = game.global("LoadoutSettings")
	if settings then
		add_all(names, settings.static_stratagems)
		local first = settings.default_loadout or {}
		add_all(names, { first.perk, first.primary_weapon, first.sidearm_weapon })
		add_all(names, first.stratagems)
	end
	local progression = game.global("ProgressionSettings")
	for _, rank in ipairs(progression and progression.ranks or {}) do
		if rank.required_xp <= xp then
			for _, list in pairs(rank.unlocks) do add_all(names, list) end
		end
	end
	earned.xp, earned.count, earned.names = xp, #rewards, names
	return names
end

-- True for an item the Loadout screen would offer this player (menu_screen_loadout.lua:142): earned,
-- or in a paid pack they own.
function M.unlocked(name)
	if not M.usable(name) then return false end
	local dlc = game.global("DlcSettings")
	if dlc and dlc.is_item_dlc then
		local ok, is_dlc = pcall(dlc.is_item_dlc, name)
		if ok and is_dlc then return true end
	end
	local names = earned_names()
	return names ~= nil and names[name] == true
end

local function loadout(category)
	local settings = game.global("LoadoutSettings")
	local out = {}
	for _, item in ipairs(settings and settings[category] or {}) do
		if M.unlocked(item.name) then out[#out + 1] = item end
	end
	return out
end

function M.primaries() return loadout("primary_weapon") end
function M.sidearms() return loadout("sidearm_weapon") end
function M.stratagems() return loadout("stratagems") end
function M.perks() return loadout("perks") end

local function has_subtype(s, wanted)
	for _, sub in ipairs(s.stratagem_subtypes or {}) do
		if sub == wanted then return true end
	end
	return false
end

-- Support weapons are stratagems whose crate holds the weapon: { name, unit_path }. All of them carry
-- the subtype weapon; support_weapon leaves out the mortar, recoilless, LAW and missile launcher.
function M.support_weapons()
	local lsm = game.global("LuaSettingsManager")
	local out = {}
	if not lsm then return out end
	for _, s in ipairs(M.stratagems()) do
		local crate = has_subtype(s, "weapon") and s.unit and lsm:get_settings_by_unit_path(s.unit)
		local content = crate and crate.supply_crate_info and crate.supply_crate_info.content
		local pickup = content and content[1] and content[1].unit_path
		local path = pickup and lsm:get_settings_path_by_unit_path(pickup)
		if path then out[#out + 1] = { name = s.name, unit_path = path } end
	end
	return out
end

-- What a stratagem's crate holds, pickup by pickup: fn(pickup settings, unit path).
local function each_crate_item(s, fn)
	local lsm = game.global("LuaSettingsManager")
	local crate = lsm and s.unit and lsm:get_settings_by_unit_path(s.unit)
	local info = crate and crate.supply_crate_info
	for _, item in ipairs(info and info.content or {}) do
		local settings = item.unit_path and lsm:get_settings_by_unit_path(item.unit_path)
		if settings then fn(settings, item.unit_path) end
	end
end

-- Every pack in a crate of a stratagem this player can use: { name, unit_path, stratagem }. The path
-- is the settings' own backpack_path, the only kind the game's set_backpack can read safely.
function M.backpacks()
	local out, seen = {}, {}
	for _, s in ipairs(M.stratagems()) do
		each_crate_item(s, function(settings)
			local pickup = settings.pickup_info
			local path = pickup and pickup.backpack_path
			if path and not seen[path] then
				seen[path] = true
				out[#out + 1] = { name = pickup.item_name, unit_path = path, stratagem = s.name }
			end
		end)
	end
	return out
end

function M.backpack(path)
	for _, item in ipairs(M.backpacks()) do
		if item.unit_path == path then return item end
	end
	return nil
end

-- Crates a stratagem drops: { name, unit_path }.
function M.crates()
	local out = {}
	for _, s in ipairs(M.stratagems()) do
		local is_crate = false
		each_crate_item(s, function() is_crate = true end)
		if is_crate then out[#out + 1] = { name = s.name, unit_path = s.unit } end
	end
	return out
end

-- Everything crates hold, as pickups that can lie on the ground: { name, unit_path }.
function M.pickups()
	local out, seen = {}, {}
	for _, s in ipairs(M.stratagems()) do
		each_crate_item(s, function(settings, path)
			local pickup = settings.pickup_info
			if pickup and pickup.item_name and not seen[path] then
				seen[path] = true
				out[#out + 1] = { name = pickup.item_name, unit_path = path }
			end
		end)
	end
	return out
end

-- Stratagems of a subtype, by what they send down: { name, unit_path }.
function M.by_subtype(subtype)
	local out = {}
	for _, s in ipairs(M.stratagems()) do
		if s.unit and has_subtype(s, subtype) then out[#out + 1] = { name = s.name, unit_path = s.unit } end
	end
	return out
end

-- The seven vehicles. The mannable turret has a vehicle's settings too, but it doesn't go anywhere.
function M.vehicles()
	local lsm = game.global("LuaSettingsManager")
	local out = {}
	if not lsm then return out end
	for _, s in ipairs(M.stratagems()) do
		local settings = s.unit and lsm:get_settings_by_unit_path(s.unit)
		local info = settings and settings.vehicle_info
		if info and info.vehicle_type ~= "mannable_turret" then out[#out + 1] = { name = s.name, unit_path = s.unit } end
	end
	return out
end

-- The highest upgrade value a unit takes. Bitmask upgrades add up, and the game's limit is 15.
function M.max_upgrade(unit_path)
	local lsm = game.global("LuaSettingsManager")
	local settings = lsm and lsm:get_settings_by_unit_path(unit_path)
	local info = settings and settings.upgrade_info
	if not info then return 0 end
	if info.type == "bitmask" then return math.min(2 ^ #info - 1, 15) end
	return math.min(#info, 15)
end

function M.stratagem(name)
	for _, s in ipairs(M.stratagems()) do
		if s.name == name then return s end
	end
	return nil
end

-- The stratagem or weapon a unit path belongs to, by the name the game keeps upgrades under.
function M.item_name(unit_path)
	for _, list in ipairs({ M.primaries(), M.sidearms(), M.support_weapons() }) do
		for _, item in ipairs(list) do
			if item.unit_path == unit_path then return item.name end
		end
	end
	return nil
end

function M.cosmetics(slot)
	local settings = game.global("CustomizationSettings")
	local out = {}
	for i, item in ipairs(settings and settings[slot] or {}) do
		-- Gender isn't something a player unlocks.
		if slot == "gender" or not item.name or M.unlocked(item.name) then out[#out + 1] = { index = i, name = item.name } end
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

-- The encounter waves of a faction, as the game lists them: { name, cost, events }.
function M.waves(faction)
	local settings = game.global("EncounterSettings")
	return settings and settings[faction] or {}
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
	if w and not settings.turret_info and not settings.strafingrun_info then
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
	if settings.minedrop_info or settings.mine_info then out[#out + 1] = "mine" end
	if settings.airstrike_info then out[#out + 1] = "airstrike" end
	if settings.strafingrun_info then out[#out + 1] = "strafing" end
	if settings.artillery_info then out[#out + 1] = "artillery" end
	if settings.homing_info then out[#out + 1] = "orbital" end
	if settings.backpack_info then out[#out + 1] = "backpack" end
	if settings.vehicle_info then
		out[#out + 1] = "vehicle"
		out[#out + 1] = "toughness"
	end
	if settings.enemy_info then out[#out + 1] = "enemy" end
	return out
end

return M
