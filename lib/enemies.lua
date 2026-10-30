-- Enemies: spawning them, stopping them, getting rid of them.
-- The host runs the encounter, patrol and wave managers. Enemies themselves are shared out between
-- peers, so kills go through the owner. Only units whose package is loaded can spawn: an unloaded
-- unit is a fatal engine error, so every spawn checks first.
local game = obsidian.module("lib/game")
local effects = obsidian.module("lib/effects")
local catalog = obsidian.module("lib/catalog")
local world = obsidian.module("lib/world")

local M = {}

local GROUP_LIMIT = 10
local PACKAGE_PREFIX = "resource_packages/"

local function aux()
	return game.global("EntityAux")
end

local function managers()
	local st = game.state()
	if type(st) ~= "table" or not st.encounter_manager then return nil, nil, nil end
	return st.encounter_manager, st.patrol_manager, st
end

-- Whether a unit from the catalog can spawn right now.
function M.available(enemy)
	local boot = game.global("Boot")
	local packages = type(boot) == "table" and boot.package_manager
	if not packages then return false end
	for _, name in ipairs(enemy.packages or {}) do
		local ok, online = pcall(packages.is_package_online, packages, PACKAGE_PREFIX .. name)
		if ok and online then return true end
	end
	return false
end

-- Living enemies known to this peer.
function M.list()
	local units, out = game.global("Unit"), {}
	for unit in pairs(game.slaves("enemy")) do
		if units.alive(unit) then
			local health = aux().state(unit, "health")
			if health and not health.is_dead then out[#out + 1] = unit end
		end
	end
	return out
end

function M.count()
	return #M.list()
end

local function spawn_position(where)
	if where == "cursor" then return world.cursor() end
	return world.ahead(8)
end

-- key: a catalog key or unit path. where: "cursor", or nil for in front of the player. A client's
-- single spawn goes to the host as a request; groups are the host's to make.
function M.spawn(key, count, where)
	local em = managers()
	if not em then return false, "not_in_mission" end
	local enemy = catalog.enemy(key)
	if not enemy then return false, "unknown_enemy" end
	if not M.available(enemy) then return false, "not_loaded" end
	local pos = spawn_position(where)
	if not pos then return false, "no_position" end
	count = count or 1
	if count == 1 then
		em:spawn_enemy(enemy.unit, pos, nil, nil, { spawn_event = "patrol" }, true)
		return true
	end
	if not game.is_host() then return false, "host_only" end
	if em.encounters_disabled then return false, "spawns_off" end
	while count > 0 do
		local amount = math.min(count, GROUP_LIMIT)
		em:spawn_group(pos, { units = { { unit_path = enemy.unit, amount = amount } } })
		count = count - amount
	end
	return true
end

function M.spawn_group(key, where)
	local em = managers()
	if not em then return false, "not_in_mission" end
	if not game.is_host() then return false, "host_only" end
	if em.encounters_disabled then return false, "spawns_off" end
	local groups = game.global("EnemyGroupSettings")
	local group = groups and groups[key]
	if not group then return false, "unknown_enemy" end
	for _, u in ipairs(group.units or {}) do
		local enemy = catalog.enemy(u.unit_path)
		if not enemy or not M.available(enemy) then return false, "not_loaded" end
	end
	local pos = spawn_position(where)
	if not pos then return false, "no_position" end
	em:spawn_group(pos, group)
	return true
end

-- Non-enemy things by unit path, with no package check: only paths from mission_common belong here.
function M.spawn_entity(path, pos)
	local st = game.state()
	if not (type(st) == "table" and st.entity_spawner) then return false, "not_in_mission" end
	if not pos then return false, "no_position" end
	st.entity_spawner:spawn_entity(path, pos, game.global("Quaternion").identity(), nil, {})
	return true
end

-- A unit dies at its constitution, stored negative. The owner does it, by command or by the game's
-- own request. The player gets the kill, or objectives wouldn't count it.
local function kill(unit, credit)
	local health = aux().state(unit, "health")
	if not health or health.is_dead then return end
	if aux().owned(unit) then
		aux().queue_command_master(unit, "health", "set_hitpoints",
			credit and { new_hitpoints = health.constitution, owner_unit = credit, attacker_unit = credit } or health.constitution)
	else
		game.state().network_router:transmit_to(aux().owner(unit), "rpc_set_hitpoints_request", unit, credit, credit, health.constitution)
	end
end

function M.kill_all()
	if not game.in_mission() then return false, "not_in_mission" end
	local credit = game.my_unit()
	for _, unit in ipairs(M.list()) do kill(unit, credit) end
	return true
end

function M.kill_near(radius)
	if not game.in_mission() then return false, "not_in_mission" end
	local me = game.my_unit()
	if not me then return false, "no_avatar" end
	local units, v3 = game.global("Unit"), game.global("Vector3")
	local at = units.world_position(me, 0)
	for _, unit in ipairs(M.list()) do
		if v3.distance(units.world_position(unit, 0), at) <= radius then kill(unit, me) end
	end
	return true
end

-- Gone with no corpse, no kill and no objective progress: a clean-up.
function M.despawn_all()
	local _, _, st = managers()
	if not st then return false, "not_in_mission" end
	for _, unit in ipairs(M.list()) do
		if aux().owned(unit) then
			aux().queue_command_master(unit, "enemy", "remove_from_group", unit)
			st.entity_spawner:despawn_entity(unit)
		else
			st.network_router:transmit_to(aux().owner(unit), "rpc_despawn_enemy_unit", unit)
		end
	end
	return true
end

-- The game turns encounters and patrols back on by itself as objectives start, so this holds them
-- off every second rather than once. Enemies already on the map stay.
local hold_timer = 0
local function hold_spawns(on)
	local em, pm = managers()
	if not (em and game.is_host()) then return end
	em:set_disabled(on)
	if pm then pm:set_disabled(on) end
end

effects.define({ id = "no_spawns",
	apply = function() hold_spawns(true) end,
	frame = function(_, _, dt)
		hold_timer = hold_timer + dt
		if hold_timer >= 1 then
			hold_timer = 0
			hold_spawns(true)
		end
	end,
	remove = function() hold_spawns(false) end,
})

-- Keeps every new enemy on the host, so edits made there reach all of them.
effects.define({ id = "host_owns_enemies",
	apply = function()
		local em = managers()
		if em and game.is_host() then em.get_spawner_peer = function() return game.global("Network").peer_id() end end
	end,
	remove = function()
		local em = managers()
		if em then em.get_spawner_peer = nil end
	end,
})

-- Stops the enemy and movement components on this peer, as the game's tutorial does. Resuming a
-- component that's running would run it twice per frame, so the list is read first.
local function set_frozen(on)
	local _, _, st = managers()
	local cm = st and st.component_manager
	if not cm then return end
	for _, name in ipairs({ "navmesh_mover", "enemy" }) do
		local index, running = cm.component_name_to_index[name], false
		for _, i in ipairs(cm.active_components) do
			if i == index then running = true end
		end
		if on and running then
			cm:pause_component(name)
		elseif not on and not running then
			cm:resume_component(name)
		end
	end
end

effects.define({ id = "freeze",
	apply = function() set_frozen(true) end,
	remove = function() set_frozen(false) end,
})

-- Enemies lose interest: a target's threat comes back too low to pick. Read live by each enemy.
local blinded = {}
local function no_threat() return -2 end

effects.define({ id = "blind",
	apply = function()
		local lsm = game.global("LuaSettingsManager")
		if not lsm then return end
		for _, settings in lsm:all_settings_iterator() do
			local info = settings.enemy_info
			if info and not blinded[info] then
				blinded[info] = { info.threat_calculation, info.aggro_range }
				info.threat_calculation = no_threat
				info.aggro_range = 1
			end
		end
	end,
	remove = function()
		for info, old in pairs(blinded) do
			info.threat_calculation, info.aggro_range = old[1], old[2]
		end
		blinded = {}
	end,
})

function M.call_encounter()
	local em = managers()
	if not em then return false, "not_in_mission" end
	local pos = world.ahead(10)
	if not pos then return false, "no_avatar" end
	em:start_encounter(pos)
	return true
end

function M.add_patrol()
	local _, pm = managers()
	if not pm then return false, "not_in_mission" end
	if not game.is_host() then return false, "host_only" end
	pm:add_patrol_on_spawner()
	return true
end

function M.max_enemies()
	local settings = game.global("GameSettings")
	return settings and settings.MAX_NUM_ALLOWED_ENEMIES
end

return M
