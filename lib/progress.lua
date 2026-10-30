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
