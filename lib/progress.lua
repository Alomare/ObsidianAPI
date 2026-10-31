-- The player's own save: unlocks, upgrades and samples. Obsidian leaves personal progression alone,
-- with two exceptions kept here on purpose. There is no way to change XP or rank: the total stays in
-- the save and goes up with the next ordinary leaderboard upload, after any purge. And there's no
-- way to get paid content: everything that lists items goes through the DLC check.
local game = obsidian.module("lib/game")
local catalog = obsidian.module("lib/catalog")

local M = {}

local function user()
	local manager = game.global("UserManager")
	return manager and manager:get_user_id()
end

-- Armory and loadout screens hold a copy of these keys and write it back on exit, which would undo
-- a change made while they're open. So any of the ship's screens must be closed first.
local function can_edit()
	if not game.on_ship() then return false, "not_on_ship" end
	local st = game.state()
	local screens = type(st) == "table" and st.active_screens
	if screens and #screens > 0 then return false, "close_screen" end
	return true
end

local function persist()
	local helper = game.global("SaveDataHelper")
	if helper then helper:save_all() end
end

function M.samples()
	local save = game.global("SaveManager")
	return save and save:user_get("research_samples", user()) or 0
end

function M.max_samples()
	local settings = game.global("GameSettings")
	return settings and settings.MAX_NUM_RESEARCH_SAMPLES or 3168
end

function M.set_samples(n)
	local ok, why = can_edit()
	if not ok then return false, why end
	game.global("SaveManager"):user_set("research_samples", math.max(0, math.min(n, M.max_samples())), user())
	persist()
	return true
end

-- Adds every item that isn't paid content, without touching XP. Merges, never replaces.
function M.unlock_items()
	local ok, why = can_edit()
	if not ok then return false, why end
	local save, id = game.global("SaveManager"), user()
	local unlocks = save:user_get("item_unlocks", id) or {}
	local fresh = save:user_get("new_unlocks", id) or {}
	local have = {}
	for _, name in ipairs(unlocks) do have[name] = true end
	local dlc = game.global("DlcSettings")
	local function add(name)
		if name and not have[name] and name ~= "cus_cape_tutorial" and not dlc.is_item_dlc(name) then
			have[name] = true
			unlocks[#unlocks + 1] = name
			fresh[#fresh + 1] = name
		end
	end
	for _, race in pairs(game.global("PlanetRewardSettings").planet_rewards) do
		for category, list in pairs(race) do
			if category ~= "xp_boost" and category ~= "influence_boost" then
				for _, item in ipairs(list) do add(item.name) end
			end
		end
	end
	for _, rank in ipairs(game.global("ProgressionSettings").ranks) do
		for _, list in pairs(rank.unlocks) do
			for _, name in ipairs(list) do add(name) end
		end
	end
	for slot, list in pairs(game.global("CustomizationSettings")) do
		if slot ~= "gender" and type(list) == "table" then
			for _, item in ipairs(list) do add(item.name) end
		end
	end
	save:user_set("item_unlocks", unlocks, id)
	save:user_set("new_unlocks", fresh, id)
	persist()
	return true
end

-- Upgrades of paid items stay in the map but do nothing: those items stay locked.
function M.upgrade_all()
	local ok, why = can_edit()
	if not ok then return false, why end
	local save, id = game.global("SaveManager"), user()
	local map = {}
	for name, value in pairs(save:user_get("item_upgrades", id) or {}) do map[name] = value end
	game.global("LoadoutSettings").upgrade_all(map)
	save:user_set("item_upgrades", map, id)
	persist()
	return true
end

local function copy(t)
	local out = {}
	for k, v in pairs(t or {}) do out[k] = type(v) == "table" and copy(v) or v end
	return out
end

-- The set the next spawn uses: { perk, primary_weapon, sidearm_weapon, stratagems }, by name.
function M.loadout()
	local save = game.global("SaveManager")
	return save and copy(save:user_get("loadout", user())) or nil
end

-- t: any of those keys. stratagems maps the free slots, 1 to 4 after the four every player has, to
-- names. It's in the save at once and applies at the next spawn. The Loadout screen starts from the first preset, so
-- that goes along with it, and paid or unknown items go back to the default, as the game does when
-- it reads a save. The save can't get an item the player hasn't unlocked past that screen.
function M.set_loadout(t)
	local ok, why = can_edit()
	if not ok then return false, why end
	if type(t) ~= "table" then return false, "bad_type" end
	local save, id = game.global("SaveManager"), user()
	local settings = game.global("LoadoutSettings")
	local l = copy(save:user_get("loadout", id))
	if next(l) == nil then l = copy(settings.default_loadout) end
	l.perk = t.perk or l.perk
	l.primary_weapon = t.primary_weapon or l.primary_weapon
	l.sidearm_weapon = t.sidearm_weapon or l.sidearm_weapon
	if t.stratagems then
		local fixed = #settings.static_stratagems
		for i in pairs(t.stratagems) do
			if type(i) ~= "number" or i % 1 ~= 0 or i < 1 or fixed + i > settings.nr_of_stratagem_slots then return false, "out_of_range" end
		end
		for i, name in pairs(t.stratagems) do l.stratagems[fixed + i] = name end
	end
	l = game.global("Boot").ensure_loadout(id, l)
	save:user_set("loadout", l, id)
	local presets = save:user_get("loadouts", id)
	if presets and presets[1] then
		presets = copy(presets)
		presets[1] = copy(l)
		save:user_set("loadouts", presets, id)
	end
	persist()
	return true
end

function M.upgrades()
	local save = game.global("SaveManager")
	return save and copy(save:user_get("item_upgrades", user())) or {}
end

local function upgradeable(name)
	local settings = game.global("LoadoutSettings")
	for _, category in ipairs({ "primary_weapon", "sidearm_weapon", "stratagems" }) do
		for _, item in ipairs(settings[category] or {}) do
			if item.name == name and item.upgrades then return item, category end
		end
	end
	return nil
end

-- The highest value set_upgrade takes for an item, nil for one with no upgrades.
function M.upgrade_limit(name)
	local item, category = upgradeable(name)
	if not item then return nil end
	return game.global("LoadoutSettings").get_max_upgrade_value(item, category)
end

-- name: a weapon or stratagem. value: its upgrades as the game keeps them, a bit each for a weapon, a
-- level for a stratagem, from 0 to the item's most. Upgrades of paid items the player doesn't own
-- would do nothing, so they're refused here.
function M.set_upgrade(name, value)
	local ok, why = can_edit()
	if not ok then return false, why end
	if not upgradeable(name) or not catalog.usable(name) then return false, "not_available" end
	if type(value) ~= "number" or value % 1 ~= 0 or value < 0 or value > M.upgrade_limit(name) then return false, "out_of_range" end
	local save, id = game.global("SaveManager"), user()
	local map = copy(save:user_get("item_upgrades", id))
	map[name] = value
	save:user_set("item_upgrades", map, id)
	persist()
	return true
end

function M.rank()
	local save, settings = game.global("SaveManager"), game.global("ProgressionSettings")
	if not (save and settings) then return nil end
	local xp = save:user_get("player_xp", user()) or 0
	local ok, rank = pcall(settings.get_rank, xp)
	return ok and rank or nil, xp
end

function M.owned_cosmetics(slot)
	return catalog.cosmetics(slot)
end

return M
