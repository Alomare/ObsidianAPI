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

-- The game keeps to 16 enemies, and a map holding far more took a mission down with no error. The
-- Trainer stops here, though spawn doesn't: this is a chosen line, not a measured limit.
M.MAX_SAFE = 64

-- Every enemy the map is carrying: corpses count until they decay, and the queue spawns any moment.
function M.carried()
	local n = 0
	for _ in pairs(game.slaves("enemy")) do n = n + 1 end
	local em, pm = managers()
	return n + (em and em.num_queued_enemies or 0) + (pm and pm.num_queued_enemies or 0)
end

function M.room()
	return math.max(0, M.MAX_SAFE - M.carried())
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
	if not (game.in_mission() and st.entity_spawner) then return false, "not_in_mission" end
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

function M.kill(unit)
	if not game.in_mission() then return false, "not_in_mission" end
	if not game.slaves("enemy")[unit] then return false, "no_enemy" end
	kill(unit, game.my_unit())
	return true
end

local function alive_enemy(unit)
	local units = game.global("Unit")
	if not (unit and units.alive(unit) and game.slaves("enemy")[unit]) then return nil end
	local health = aux().state(unit, "health")
	return health and not health.is_dead and health or nil
end

-- What the game knows about one enemy: { key, name, faction, boss, hitpoints, max_hitpoints, owned }.
-- The catalog fields are nil for a unit it doesn't list.
function M.info(unit)
	local health = alive_enemy(unit)
	if not health then return nil end
	local path = game.global("Unit").get_data(unit, "unit_path")
	local enemy = path and catalog.enemy(path) or {}
	return { key = enemy.key, name = enemy.name, faction = enemy.faction, boss = enemy.boss,
		hitpoints = health.hitpoints, max_hitpoints = health.max_hitpoints, owned = aux().owned(unit) }
end

-- The closest living enemy to a position, or to the player, and how far it is.
function M.nearest(pos)
	local units, v3 = game.global("Unit"), game.global("Vector3")
	if not pos then
		local me = game.my_unit()
		if not me then return nil end
		pos = units.world_position(me, 0)
	end
	local best, best_distance = nil, math.huge
	for _, unit in ipairs(M.list()) do
		local distance = v3.distance(units.world_position(unit, 0), pos)
		if distance < best_distance then best, best_distance = unit, distance end
	end
	return best, best and best_distance or nil
end

-- A hit of no power that carries the status, the way weapons do it, so it reaches the owner from any
-- peer. The status command itself fails on an enemy this peer doesn't own.
function M.apply_status(unit, template)
	if not game.in_mission() then return false, "not_in_mission" end
	local templates = game.global("StatusTemplateSettings")
	if not (templates and templates[template]) then return false, "unknown_status" end
	if not alive_enemy(unit) then return false, "no_enemy" end
	local me = game.my_unit()
	aux().queue_command_interface(unit, "damageable", "do_damage",
		{ power = 0, angle_hit = 0, angle_incidence = 0, owner_unit = me, attacker_unit = me, hit_status_effects = { template } })
	return true
end

function M.stun_near(radius)
	if not game.in_mission() then return false, "not_in_mission" end
	local me = game.my_unit()
	if not me then return false, "no_avatar" end
	local units, v3 = game.global("Unit"), game.global("Vector3")
	local at = units.world_position(me, 0)
	for _, unit in ipairs(M.list()) do
		if v3.distance(units.world_position(unit, 0), at) <= radius then M.apply_status(unit, "flashbang_stun") end
	end
	return true
end

-- Living enemies within a radius of a position, or of the player, nearest first.
function M.near(radius, pos)
	local units, v3 = game.global("Unit"), game.global("Vector3")
	if not pos then
		local me = game.my_unit()
		if not me then return {} end
		pos = units.world_position(me, 0)
	end
	local found, distances = {}, {}
	for _, unit in ipairs(M.list()) do
		local distance = v3.distance(units.world_position(unit, 0), pos)
		if distance <= radius then
			found[#found + 1] = unit
			distances[unit] = distance
		end
	end
	table.sort(found, function(a, b) return distances[a] < distances[b] end)
	return found
end

-- A hit from the player, as apply_status sends it, so it reaches the owner and armor counts. statuses:
-- a list of status templates that go with it, or nil.
function M.damage(unit, power, statuses)
	if not game.in_mission() then return false, "not_in_mission" end
	if not (type(power) == "number" and power >= 0 and power < 1000000) then return false, "out_of_range" end
	if not alive_enemy(unit) then return false, "no_enemy" end
	local templates = game.global("StatusTemplateSettings")
	for _, template in ipairs(statuses or {}) do
		if not (templates and templates[template]) then return false, "unknown_status" end
	end
	local me = game.my_unit()
	aux().queue_command_interface(unit, "damageable", "do_damage",
		{ power = power, angle_hit = 0, angle_incidence = 0, owner_unit = me, attacker_unit = me, hit_status_effects = statuses })
	return true
end

-- The owner sets it, by command or by the game's own request, as a kill does.
function M.set_hitpoints(unit, hitpoints)
	if not game.in_mission() then return false, "not_in_mission" end
	if not (type(hitpoints) == "number" and hitpoints > 0 and hitpoints < 1000000) then return false, "out_of_range" end
	if not alive_enemy(unit) then return false, "no_enemy" end
	if aux().owned(unit) then
		aux().queue_command_master(unit, "health", "set_hitpoints", hitpoints)
	else
		game.state().network_router:transmit_to(aux().owner(unit), "rpc_set_hitpoints_request", unit, nil, nil, hitpoints)
	end
	return true
end

local function despawn(st, unit)
	if aux().owned(unit) then
		aux().queue_command_master(unit, "enemy", "remove_from_group", unit)
		st.entity_spawner:despawn_entity(unit)
	else
		st.network_router:transmit_to(aux().owner(unit), "rpc_despawn_enemy_unit", unit)
	end
end

-- Gone with no corpse, no kill and no objective progress: a clean-up.
function M.despawn_all()
	local _, _, st = managers()
	if not st then return false, "not_in_mission" end
	for _, unit in ipairs(M.list()) do despawn(st, unit) end
	return true
end

function M.despawn(unit)
	local _, _, st = managers()
	if not st then return false, "not_in_mission" end
	if not alive_enemy(unit) then return false, "no_enemy" end
	despawn(st, unit)
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

-- Race packages this mod loaded. The game unloads only the one it asked for.
local loaded = {}

-- Every peer needs the package to mirror a unit, so it's for solo play. The flush stops the game for
-- a moment, as the game's own console does (encounter_manager.lua:736-753).
function M.load_faction(name)
	if not game.in_mission() then return false, "not_in_mission" end
	if not game.alone() then return false, "alone_only" end
	local known = false
	for _, faction in ipairs({ "bugs", "cyborgs", "illuminates" }) do
		if faction == name then known = true end
	end
	if not known then return false, "unknown_faction" end
	local packages = game.global("Boot").package_manager
	local path = PACKAGE_PREFIX .. "race_" .. name
	if packages:is_package_online(path) then return true end
	packages:load_package(path, true)
	loaded[path] = true
	return true
end

-- From the frame callback. The units are gone with the world by the first frame off a mission.
function M.tick()
	if next(loaded) == nil or game.in_mission() then return end
	local packages = game.global("Boot").package_manager
	for path in pairs(loaded) do
		packages:unload_package(path)
		loaded[path] = nil
	end
end

function M.max_enemies()
	local settings = game.global("GameSettings")
	return settings and settings.MAX_NUM_ALLOWED_ENEMIES
end

-- Numbers the managers read all mission. init_host writes them once per mission, so an effect holds
-- each one from its frame function, and what the game had is kept per table to give back.
local held = setmetatable({}, { __mode = "k" })

local function hold(t, field, value)
	local old = held[t]
	if not old then
		old = {}
		held[t] = old
	end
	if old[field] == nil then old[field] = t[field] end
	t[field] = value
end

local function release(t, field)
	local old = held[t]
	if old and old[field] ~= nil then
		t[field] = old[field]
		old[field] = nil
	end
end

-- The most enemies at once. Waves stop at two limits: the global cap on all enemies, and the
-- encounter manager's own, 6 to 12 by difficulty. The game asks only the host.
M.MAX_CAP = 32

local function hold_cap(_, value)
	if not game.is_host() then return end
	hold(game.global("GameSettings"), "MAX_NUM_ALLOWED_ENEMIES", value)
	local em = managers()
	if em then hold(em, "max_num_enemies", value) end
end

effects.define({ id = "enemy_cap",
	apply = hold_cap,
	frame = hold_cap,
	remove = function()
		release(game.global("GameSettings"), "MAX_NUM_ALLOWED_ENEMIES")
		local em = managers()
		if em then release(em, "max_num_enemies") end
	end,
})

-- field of a manager, as an effect. which: 1 for the encounter manager, 2 for the patrol manager.
local function held_number(id, which, field)
	local function manager()
		return (select(which, managers()))
	end
	local function write(_, value)
		local m = manager()
		if m and game.is_host() then hold(m, field, value) end
	end
	effects.define({ id = id, apply = write, frame = write,
		remove = function()
			local m = manager()
			if m then release(m, field) end
		end,
	})
end

-- The budget of each encounter. The mission keeps its seed, its waves and its objectives.
held_number("enemy_difficulty", 1, "mission_difficulty")
held_number("patrol_count", 2, "max_num_patrols")
held_number("patrol_interval", 2, "patrol_spawn_interval")

local PRESSURE = {
	cap = { id = "enemy_cap", min = 1, max = M.MAX_CAP },
	difficulty = { id = "enemy_difficulty", min = 1, max = 15 },
	patrols = { id = "patrol_count", min = 0, max = 60 },
	interval = { id = "patrol_interval", min = 1, max = 120 },
}

-- Bigger fights with no change to the seed. t: cap, difficulty, patrols, interval. A number sets one,
-- false gives it back to the game, and one left out stays as it is.
function M.set_pressure(t)
	if not game.is_host() then return false, "host_only" end
	for key, rule in pairs(PRESSURE) do
		local v = t[key]
		if v ~= nil and v ~= false and not (type(v) == "number" and v >= rule.min and v <= rule.max) then return false, "out_of_range" end
	end
	for key, rule in pairs(PRESSURE) do
		if t[key] ~= nil then effects.set(rule.id, t[key]) end
	end
	return true
end

-- Names of the waves this mission's faction can have.
function M.waves()
	local em = managers()
	local out = {}
	for _, wave in ipairs(catalog.waves(em and em.mission_enemy)) do out[#out + 1] = wave.name end
	return out
end

local function wave_loaded(wave, groups)
	for _, event in ipairs(wave.events or {}) do
		for _, g in ipairs(event.groups or {}) do
			local group = groups[g.group]
			if not group then return false end
			for _, u in ipairs(group.units or {}) do
				local enemy = catalog.enemy(u.unit_path)
				if not enemy or not M.available(enemy) then return false end
			end
		end
	end
	return true
end

-- A named wave now, at a position or ten metres ahead. Its groups are spawned directly: the game only
-- runs a wave it picked itself, with bookkeeping that a forced one would break.
function M.force_wave(name, pos)
	local em = managers()
	if not em then return false, "not_in_mission" end
	if not game.is_host() then return false, "host_only" end
	if em.encounters_disabled then return false, "spawns_off" end
	local wave
	for _, w in ipairs(catalog.waves(em.mission_enemy)) do
		if w.name == name then wave = w end
	end
	if not wave then return false, "unknown_wave" end
	local groups = game.global("EnemyGroupSettings")
	if not wave_loaded(wave, groups) then return false, "not_loaded" end
	pos = pos or world.ahead(10)
	if not pos then return false, "no_position" end
	for _, event in ipairs(wave.events or {}) do
		for _, g in ipairs(event.groups or {}) do em:spawn_group(pos, groups[g.group], nil, wave.cost) end
	end
	return true
end

return M
