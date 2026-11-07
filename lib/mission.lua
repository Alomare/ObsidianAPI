-- The mission: objectives, extraction, waits, samples, and choosing what to play.
-- Objectives and the end of a mission belong to the host. The objective commands walk the entities
-- this peer owns, so an object a client is using can be missed; each action says what it reached.
local game = obsidian.module("lib/game")
local effects = obsidian.module("lib/effects")
local catalog = obsidian.module("lib/catalog")
local stratagems = obsidian.module("lib/stratagems")

local M = {}

local OBJECTIVES = {
	"objective_destroy_object", "objective_defend_object", "objective_interact_object", "objective_hold_object",
	"objective_carry_object", "objective_convoy", "objective_assassinate", "objective_escort", "objective_exterminate",
	"objective_genocide", "objective_sweep_and_find", "hidden_sweep_object", "objective_fortify_object",
}

local function mission_state()
	if not game.in_mission() then return nil end
	return (game.state())
end

local function each_objective(command)
	local done = 0
	for _, name in ipairs(OBJECTIVES) do
		local c = game.component(name)
		-- One failing objective mustn't stop the rest, as it does in the game's console.
		if c and next(game.masters(name)) ~= nil then
			local ok, err = pcall(game.plugin, c, command)
			if ok then done = done + 1 else obsidian.log(name .. " " .. command .. ": " .. tostring(err)) end
		end
	end
	return done
end

-- The fortify command only changes this peer's table, so its waves are finished too.
local function finish_fortify()
	for _, ctx in pairs(game.masters("objective_fortify_object")) do
		local state = ctx.state
		state.capture_time_left = 0.01
		if state.waves then game.protected("objective_fortify_object", state, "current_wave", #state.waves) end
	end
end

local function finish_escort()
	for _, ctx in pairs(game.masters("objective_escort")) do ctx.state.full_escort = true end
end

-- A boss has no command. It spawns only near players, so it's spawned, then killed a moment later.
local function finish_boss()
	local component = game.component("objective_boss")
	if not component then return end
	local units = game.global("Unit")
	for unit, ctx in pairs(game.masters("objective_boss")) do
		local boss = ctx.state.boss_unit
		if not boss or not units.alive(boss) then
			component:spawn_boss(unit, ctx)
		elseif game.global("EntityAux").owned(boss) then
			game.global("EntityAux").queue_command_master(boss, "health", "set_hitpoints", 0)
		end
	end
end

-- Every objective of this mission: { name, text, type, state, group, done, total, position }. state:
-- pending, complete or failed. done and total: the count the objective list shows, where it has one.
-- position: a plain copy of the first marker, or nil.
function M.objectives()
	local st = mission_state()
	local out = {}
	if not (st and st.mission_manager) then return out end
	for _, o in ipairs(st.mission_manager:get_objectives()) do
		local params = o.params or {}
		local at = o.position and o.position[1]
		out[#out + 1] = { name = o.name, text = (string.gsub(catalog.text(o.name), "#AMOUNT", tostring(params[2]))), type = o.type, state = o.state,
			group = o.group, done = params[1], total = params[2], position = at and { x = at.x, y = at.y, z = at.z } or nil }
	end
	return out
end

local function plain(v)
	return { x = v.x, y = v.y, z = v.z }
end

local function alive(unit)
	return unit ~= nil and game.global("Unit").alive(unit)
end

-- The state of a component on a unit: this peer's master copy when it owns the unit, else the shared one.
local function state_of(unit, name)
	local ctx = game.masters(name)[unit] or game.slaves(name)[unit]
	return ctx and ctx.state or nil, ctx
end

local function node_position(unit, node)
	local units = game.global("Unit")
	local ok, pos = pcall(function() return units.world_position(unit, units.node(unit, node)) end)
	if ok and pos then return pos end
	return units.world_position(unit, 0)
end

-- Where the things objectives ask to carry count as delivered: { position, unit, kind, ready } each. kind is
-- "objective", the drop-off of the terminal the thing belongs to (the artillery's missiles), or "droppoint",
-- a drop point of the level. The game counts a thing that lies on the ground within 3 metres of one, and a
-- thing that belongs to a terminal only at that terminal, while the terminal asks for them (ready).
-- carry: one carried thing, for the drop-offs of that thing, or nil for all of them.
function M.drop_offs(carry)
	local out, seen = {}, {}
	if not game.in_mission() then return out end
	local lsm = game.global("LuaSettingsManager")
	local function intended(unit)
		local st = state_of(unit, "objective_carry_object")
		local target = st and st.intended_drop_off_unit
		return alive(target) and target or nil
	end
	local function add_objective(target)
		if seen[target] then return end
		seen[target] = true
		local ok, s = pcall(function() return lsm:get_settings_by_unit(target) end)
		local info = ok and type(s) == "table" and s.objective_info
		local node = info and info.drop_off_node
		local st = state_of(target, "objective_interact_object")
		local stage = st and st.stages and st.current_stage_index and st.stages[st.current_stage_index]
		out[#out + 1] = { position = plain(node and node_position(target, node) or game.global("Unit").world_position(target, 0)), unit = target,
			kind = "objective", ready = stage ~= nil and stage.interact_type == "carry_units" }
	end
	local function add_droppoints()
		for unit, ctx in pairs(game.slaves("droppoint")) do
			local info = ctx.settings and ctx.settings.droppoint_info
			for _, joint in ipairs(info and info.droppoint_joints or {}) do
				out[#out + 1] = { position = plain(node_position(unit, joint)), unit = unit, kind = "droppoint", ready = true }
			end
		end
	end
	if carry ~= nil then
		local target = intended(carry)
		if target then add_objective(target) else add_droppoints() end
		return out
	end
	for unit in pairs(game.slaves("objective_carry_object")) do
		local target = intended(unit)
		if target then add_objective(target) end
	end
	add_droppoints()
	return out
end

-- The extraction as it stands, or nil before there is any: { beacon, shuttle }. beacon, once the extraction
-- beacon is down: { unit, position, enabled, activated, progress, code_length, countdown, too_far }. activated is
-- true once the code is in and the shuttle is called; countdown the seconds until the shuttle comes, on the
-- host; too_far the seconds left before the beacon resets because the squad stands more than 25 metres from it,
-- or nil. shuttle: { unit, state, landed, position, door, time_left, aboard }. state is the game's number for the
-- landing zone: 1 waiting for the beacon, 4 coming, 5 landing, 6 landed, 7 leaving with the ones aboard, 0 gone
-- with none. door: where a Helldiver walks to get in (the game boards every live Helldiver within 1.9 metres of
-- it). time_left: the seconds before the shuttle leaves once landed. aboard: how many got in.
function M.extraction()
	if not game.in_mission() then return nil end
	local out = {}
	local units = game.global("Unit")
	for unit, ctx in pairs(game.slaves("extract_beacon")) do
		local st = game.masters("extract_beacon")[unit]
		st = st and st.state or ctx.state or {}
		out.beacon = { unit = unit, position = plain(units.world_position(unit, 0)), enabled = st.enabled ~= false, activated = st.activated == true,
			progress = tonumber(st.progress) or 0, code_length = st.combo and #st.combo or tonumber(st.target_interacts),
			countdown = st.activated and tonumber(st.extraction_timer) or nil, too_far = tonumber(st.too_far_away_timer) }
		break
	end
	local lz = game.component("objective_extract_lz")
	for unit, ctx in pairs(game.slaves("objective_extract_lz")) do
		local st = (game.masters("objective_extract_lz")[unit] or ctx).state or {}
		local active = st.active_lz == unit or (lz and lz.active_lz == unit)
		if active or (tonumber(st.shuttle_state) or 0) >= 4 then
			local s = { unit = st.shuttle, state = tonumber(st.shuttle_state) or 0, aboard = tonumber(st.avatars_in_dropship) or 0 }
			s.landed = s.state == 6
			if st.shuttle_position and s.state >= 4 then
				local at = game.unbox(st.shuttle_position)
				s.position = plain(at)
				local ok, door = pcall(function()
					local q, v3 = game.global("Quaternion"), game.global("Vector3")
					return at + q.forward(q(v3(0, 0, 1), math.rad(90))) * 1.5
				end)
				s.door = ok and door and plain(door) or s.position
			end
			if s.landed then s.time_left = tonumber(st.abandon_timer) end
			out.shuttle = s
			break
		end
	end
	if not (out.beacon or out.shuttle) then return nil end
	return out
end

-- Whether the shuttle took this Helldiver aboard.
function M.aboard(unit)
	local lz = game.component("objective_extract_lz")
	return lz ~= nil and type(lz.extracted_units) == "table" and lz.extracted_units[unit] == true
end

-- The areas objectives ask Helldivers to stand in: { kind, unit, position, radius, state, done, inside, total }
-- each. kind: "hold" (stand inside until done reaches 1; enemies inside slow it to a tenth) or "fortify"
-- (capture_radius, the area to take, comes too). Every Helldiver counts, bots and bare bots among them: the
-- game moves done along by the share of the squad inside, so one who stays out slows it. state: "pending",
-- "complete" or "failed". done, inside and total are the host's.
function M.areas()
	local out = {}
	if not game.in_mission() then return out end
	local units = game.global("Unit")
	for unit, ctx in pairs(game.slaves("objective_hold_object")) do
		local st = state_of(unit, "objective_hold_object") or ctx.state or {}
		local stage = st.current_stage
		out[#out + 1] = { kind = "hold", unit = unit, position = plain(units.world_position(unit, 0)), radius = stage and tonumber(stage.hold_radius),
			state = st.mission_state, done = tonumber(st.percent_done), inside = tonumber(st.num_characters_in_radius), total = tonumber(st.num_characters) }
	end
	for unit, ctx in pairs(game.slaves("objective_fortify_object")) do
		local st = state_of(unit, "objective_fortify_object") or ctx.state or {}
		out[#out + 1] = { kind = "fortify", unit = unit, position = plain(units.world_position(unit, 0)), radius = tonumber(st.hold_radius),
			capture_radius = tonumber(st.capture_radius), state = st.mission_state, inside = tonumber(st.num_characters_in_radius) }
	end
	return out
end

-- Convoys and escorted people can't die. The game switches them on and off as they move, so this
-- repeats, and on the way out gives them what the game would have set by then. Masters only: a
-- client holding one of these keeps it mortal.
local protect_timer = 0

local function convoy_safe(state)
	return state.mission_state ~= "pending" or state.enabled == true
end

local function each_protected(fn)
	for unit, ctx in pairs(game.masters("objective_convoy")) do fn(unit, convoy_safe(ctx.state)) end
	for unit, ctx in pairs(game.masters("npc_escort")) do fn(unit, ctx.state.in_goal == true) end
end

local function protect(unit)
	local health = game.master(unit, "health")
	if health and not health.invincible then game.command(unit, "health", "set_invincible", true) end
end

effects.define({ id = "protect_objectives",
	apply = function() each_protected(protect) end,
	frame = function(_, _, dt)
		protect_timer = protect_timer + dt
		if protect_timer >= 1 then
			protect_timer = 0
			each_protected(protect)
		end
	end,
	remove = function()
		each_protected(function(unit, safe) game.command(unit, "health", "set_invincible", safe) end)
	end,
})

-- The console leaves a player standing in a terminal it has finished. Only this peer's own avatar
-- can be told, so a client in a terminal has to step out by hand.
local function leave_terminal()
	local unit = game.my_unit()
	local character = game.master(unit, "character")
	if character and character.current_interact_objective_unit then
		game.command(unit, "character", "exit_interact_objective")
	end
end

function M.finish_objectives()
	if not mission_state() then return false, "not_in_mission" end
	if not game.is_host() then return false, "host_only" end
	leave_terminal()
	each_objective("complete_objectives")
	finish_fortify()
	finish_escort()
	finish_boss()
	game.after(30, finish_boss)
	return true
end

function M.restart_objectives()
	if not mission_state() then return false, "not_in_mission" end
	if not game.is_host() then return false, "host_only" end
	each_objective("restart_objectives")
	return true
end

-- Win now, with no shuttle. The score pays for extracted players, so they're marked extracted.
function M.win()
	local st = mission_state()
	if not st then return false, "not_in_mission" end
	if not game.is_host() then return false, "host_only" end
	for _, p in ipairs(st.players) do
		if p.player_go:exists() and p.player_go:owned() then p.player_go:set("has_extracted", true) end
	end
	st.mission_manager:set_mission_completed()
	st.mission_manager:set_extraction_done()
	return true
end

-- Back to the ship, as the pause menu does it.
function M.abort()
	local st = mission_state()
	if not st then return false, "not_in_mission" end
	if not game.is_host() then return false, "host_only" end
	st:do_abort_mission()
	return true
end

-- Runs the real extraction at speed: beacon, shuttle, boarding. Needs the objectives done first.
local function extract_step()
	local st = game.state()
	local beacon = game.component("extract_beacon")
	if beacon then beacon.instant_extraction = true end
	for _, ctx in pairs(game.masters("extract_beacon")) do
		if ctx.state.enabled then
			ctx.state.enabled = false
			ctx.state.activated = true
		end
	end
	for _, ctx in pairs(game.masters("objective_extract_lz")) do
		local state = ctx.state
		if state.shuttle_state and state.shuttle_state >= 3 and state.shuttle_state <= 5 then state.hax_timer = 0 end
		if state.shuttle_state == 6 and (state.avatars_in_dropship or 0) > 0 then
			state.abandon_timer = 0
			state.dirty = true
		end
	end
	local lz = game.component("objective_extract_lz")
	if not lz then return end
	for unit, ctx in pairs(game.slaves("objective_extract_lz")) do
		local state = ctx.state
		if state.shuttle_state == 6 and state.shuttle then
			for _, p in ipairs(st.players) do
				local avatar = p.player_go:owned() and game.avatar(p)
				if avatar and not lz.extracted_units[avatar] and not game.global("EntityAux").state(avatar, "health").is_dead then
					lz.extracted_units[avatar] = true
					lz:trigger_rpc_event_to_host("rpc_extract_avatar_enter", unit)
					lz:trigger_event("on_avatar_extract", avatar, state.shuttle)
					state.player_boarding_timer = 1
				end
			end
		end
	end
end

effects.define({ id = "fast_extract",
	frame = function(ctx)
		if ctx.name == "game" then
			extract_step()
		end
	end,
	remove = function()
		local beacon = game.component("extract_beacon")
		if beacon then beacon.instant_extraction = false end
	end,
})

-- Timers an object runs while players wait. Each writes only plain fields; timers under the tamper
-- check go through game.protected.
local function skip_interact(state)
	local stage = state.current_stage
	if state.mission_state ~= "pending" or not stage then return end
	if type(state.event_duration) == "number" and state.event_duration > 0 then state.event_duration = 0 end
	if stage.interact_type == "countdown" and type(state.event_countdown) == "number" and state.event_countdown > 0.001 then
		state.event_countdown = 0.001
		state.dirty = true
	end
end

effects.define({ id = "skip_waits",
	apply = function()
		local beacon = game.component("extract_beacon")
		if beacon then beacon.instant_extraction = true end
	end,
	frame = function(ctx)
		if ctx.name ~= "game" then return end
		for _, c in pairs(game.masters("objective_interact_object")) do skip_interact(c.state) end
		for _, c in pairs(game.masters("objective_hold_object")) do
			if type(c.state.event_duration) == "number" then c.state.event_duration = 0 end
		end
		for _, c in pairs(game.masters("objective_genocide")) do
			if type(c.state.initial_wait_time) == "number" and c.state.initial_wait_time > 0.01 then c.state.initial_wait_time = 0.01 end
		end
		for _, c in pairs(game.masters("objective_fortify_object")) do
			local s = c.state
			if type(s.time_until_next_wave) == "number" then s.time_until_next_wave = 0 end
			if type(s.autodrop_time_left) == "number" and s.autodrop_time_left > 0.01 then s.autodrop_time_left = 0.01 end
		end
		for _, c in pairs(game.masters("objective_extract_lz")) do
			local s = c.state
			if s.shuttle_state and s.shuttle_state >= 3 and s.shuttle_state <= 5 then s.hax_timer = 0 end
		end
		if ctx.record and type(ctx.record.spawn_timer) == "number" and ctx.record.spawn_timer > 0.01 then ctx.record.spawn_timer = 0.01 end
		if type(ctx.state.game_over_timer) == "number" and ctx.state.game_state == "game_over" then ctx.state.exit_timer = -1 end
		local character = game.master(ctx.unit, "character")
		if character and type(character.cutscene_timer) == "number" and character.cutscene_timer > 0 then character.cutscene_timer = 0 end
	end,
	remove = function()
		local beacon = game.component("extract_beacon")
		if beacon then beacon.instant_extraction = false end
	end,
})

-- Skips the minimum load time before a drop. Applied through the hook in main.lua.
effects.define({ id = "fast_mission_start" })

function M.on_mission_start_update(state)
	if effects.is_on("fast_mission_start") and type(state.start_timer) == "number" then state.start_timer = 0 end
end

-- Lives count only when alone, as in the game.
effects.define({ id = "infinite_respawns",
	apply = function(ctx)
		if type(ctx.state) == "table" and ctx.name == "game" then ctx.state.infinite_respawns = true end
	end,
	remove = function(ctx)
		if type(ctx.state) == "table" and ctx.name == "game" then ctx.state.infinite_respawns = false end
	end,
})

-- A wipe doesn't end the mission, so everyone gets to respawn.
effects.define({ id = "no_game_over",
	frame = function(ctx)
		if ctx.name == "game" and game.is_host() then ctx.state.game_over_timer = 999 end
	end,
})

-- The game's proving ground modifiers, in any mission. One at a time, as the game has them. Two are
-- read live from the level's params, a field that's empty in a normal mission. Level generation reads
-- it too, so it's set only with an avatar on the map, and a real proving ground keeps its own. The
-- other two are timers: flares near a player, every drop_interval, as the proving grounds drop them.
M.MUTATORS = { "super_boots", "what_goes_around", "orbital_support", "orbital_bombardments" }

local READ_LIVE = { super_boots = true, what_goes_around = true }
local TIMED = {
	orbital_support = { interval = 20, subtypes = { "support", "support_weapon" } },
	orbital_bombardments = { interval = 15, subtypes = { "strike" }, gives_warning = true },
}
local live_params = {}
local mutator_timer = 0

local function set_params(ctx, name)
	local level = ctx.name == "game" and type(ctx.state) == "table" and ctx.state.generated_level
	if not level then return end
	if not READ_LIVE[name] then
		if level.provinggrounds_params == live_params then level.provinggrounds_params = nil end
	elseif ctx.unit and (level.provinggrounds_params == nil or level.provinggrounds_params == live_params) then
		live_params.sub_modifier = name
		level.provinggrounds_params = live_params
	end
end

-- One flare 4 to 10 m from a player. Answers the extra wait until the next one.
local function drop_near(ctx, timed)
	local names = {}
	for _, subtype in ipairs(timed.subtypes) do
		for _, item in ipairs(catalog.by_subtype(subtype)) do names[#names + 1] = item.name end
	end
	local avatars = game.all_avatars()
	if #names == 0 or #avatars == 0 then return 0 end
	local s = catalog.stratagem(names[math.random(#names)])
	local at = game.global("Unit").world_position(avatars[math.random(#avatars)].unit, 0)
	local points = game.global("SpatialSpawnUtlity").generate_points_in_donut(at, 4, 10, 360, game.global("Quaternion").identity(), 1, 1, ctx.state.world_proxy:get_world())
	local activation = s.activation_time or 0
	if not timed.gives_warning then
		stratagems.call_unowned(s, points[1], 0)
		return 0
	end
	stratagems.call_unowned(s, points[1], math.max(activation, 2))
	return activation
end

effects.define({ id = "mutator",
	apply = function(ctx, name)
		mutator_timer = 0
		set_params(ctx, name)
	end,
	frame = function(ctx, name, dt)
		set_params(ctx, name)
		local timed = TIMED[name]
		if not (timed and ctx.name == "game" and ctx.unit and game.is_host()) then return end
		mutator_timer = mutator_timer + dt
		if mutator_timer >= timed.interval then
			-- Zero first: a drop that fails waits for its turn, rather than trying every frame.
			mutator_timer = 0
			mutator_timer = -drop_near(ctx, timed)
		end
	end,
	remove = function(ctx)
		local level = type(ctx.state) == "table" and ctx.state.generated_level
		if level and level.provinggrounds_params == live_params then level.provinggrounds_params = nil end
	end,
})

-- name: one of MUTATORS, or nil or false for none.
function M.mutator(name)
	if not name then return effects.set("mutator", false) end
	for _, known in ipairs(M.MUTATORS) do
		if known == name then return effects.set("mutator", name) end
	end
	return false, "unknown_mutator"
end

function M.spawn_samples()
	local st = mission_state()
	if not st then return false, "not_in_mission" end
	if not game.is_host() then return false, "host_only" end
	st:spawn_research_samples_on_all_markers()
	return true
end

function M.collect_samples()
	if not mission_state() then return false, "not_in_mission" end
	if not game.is_host() then return false, "host_only" end
	local unit = game.my_unit()
	if not unit then return false, "no_avatar" end
	for sample in pairs(game.masters("research_sample_pickup")) do
		game.command(sample, "research_sample_pickup", "interact", unit)
	end
	return true
end

function M.reveal_map()
	if not mission_state() then return false, "not_in_mission" end
	if not game.is_host() then return false, "host_only" end
	for unit in pairs(game.masters("show_on_map")) do game.command(unit, "show_on_map", "show") end
	return true
end

-- What the current mission's seed says, or nil: the game's names for its parts, with layout (1 to
-- LAYOUTS) added, and the seed.
function M.params()
	local st = mission_state()
	local settings = game.global("DifficultySettings")
	if not (st and settings) then return nil end
	local ok, params = pcall(settings.get_lookup_mission_params, st.mission_seed)
	if not ok or type(params) ~= "table" then return nil end
	if type(st.mission_seed) == "number" then params.layout = math.floor(st.mission_seed / 10000000) + 1 end
	return params, st.mission_seed
end

M.TIMES = { "dawn", "day", "dusk", "night" }
M.ENVIRONMENTS = { "desert", "forest", "snow", "lava", "city" }
M.FACTIONS = { "bugs", "cyborgs", "illuminates" }
M.TYPES = { "mission", "boss", "genocide" }

-- How a planet looks: one of its three terrain sets, or the look of a faction's world, which the game
-- gives only event planets, each on one planet type. Pairs the game never draws may have no art.
M.LOOKS = { "terrain_1", "terrain_2", "terrain_3", "bug_world", "cyborg_world", "illuminate_world" }
-- Each faction look: the planet type it exists on (an index in ENVIRONMENTS) and its light and
-- terrain digits, as the game's attack events have them.
local FACTION_LOOKS = { [4] = { environment = 1, digit = 3 }, [5] = { environment = 3, digit = 4 }, [6] = { environment = 2, digit = 5 } }
-- City planets come only from defend events, with the first two terrain sets.
local CITY = 5
-- How many layouts each set of parts has: the seed holds the layout above its seven digits of parts,
-- and the game sends it as a 31-bit number.
M.LAYOUTS = 215

-- A mission seed from chosen parts, or false and a reason.
-- choice: { time, environment, enemy, kind, difficulty, look, layout }: 1-based indexes in TIMES,
-- ENVIRONMENTS, FACTIONS, TYPES and LOOKS, a difficulty from 1 to 15, and a layout from 1 to LAYOUTS.
-- look and layout are random when left out. Reasons: bad_choice, look_not_here.
function M.seed(choice)
	local settings = game.global("DifficultySettings")
	if not settings then return false, "not_available" end
	local function index(v, list)
		return type(v) == "number" and v == math.floor(v) and v >= 1 and v <= #list
	end
	if not (index(choice.time, M.TIMES) and index(choice.environment, M.ENVIRONMENTS) and index(choice.enemy, M.FACTIONS)
		and index(choice.kind, M.TYPES) and type(choice.difficulty) == "number" and choice.difficulty >= 1 and choice.difficulty <= 15) then
		return false, "bad_choice"
	end
	if choice.look ~= nil and not index(choice.look, M.LOOKS) then return false, "bad_choice" end
	if choice.layout ~= nil and not (type(choice.layout) == "number" and choice.layout == math.floor(choice.layout) and choice.layout >= 1 and choice.layout <= M.LAYOUTS) then
		return false, "bad_choice"
	end
	local shading, variant
	local faction = choice.look and FACTION_LOOKS[choice.look]
	if faction then
		if faction.environment ~= choice.environment then return false, "look_not_here" end
		shading, variant = faction.digit, faction.digit
	else
		local sets = choice.environment == CITY and 2 or 3
		if choice.look and choice.look > sets then return false, "look_not_here" end
		shading, variant = math.random(0, 2), choice.look and choice.look - 1 or math.random(0, sets - 1)
	end
	local layout = choice.layout and choice.layout - 1 or math.random(0, M.LAYOUTS - 1)
	return settings.modulate_seed(choice.time - 1, shading, choice.environment - 1, variant, choice.enemy - 1, choice.kind - 1,
		math.floor(choice.difficulty), layout * 10000000)
end

-- What a mission's end changes in the shared campaign: the save's campaign keys and the war reports
-- waiting in it, and the player's leaderboard rows and boss influence. The account (XP, samples,
-- unlocks, lifetime stats) isn't here, so it counts.
local CAMPAIGN = { "current_planet", "available_planets", "last_planet", "boss_planets", "dropzone_position",
	"next_mission_seed", "mission_stats", "mission_stats_to_upload", "completed_planets" }
local BOARDS = { "boss_influence", "leaderboard_stats", "leaderboard_stats_to_upload",
	"leaderboard_provinggrounds_stats", "leaderboard_provinggrounds_stats_to_upload" }

-- The drop under way: its seed and the copies from before it.
local drop, hooked = nil, false

local function copy(v)
	if type(v) ~= "table" then return v end
	local out = {}
	for k, x in pairs(v) do out[k] = copy(x) end
	return out
end

-- Copies of those keys now. The game changes the save's tables in place, so they're copied.
local function keep()
	local save = game.global("SaveManager")
	local user = game.global("UserManager"):get_user_id()
	local kept = { user = user, common = {}, own = {} }
	for _, key in ipairs(CAMPAIGN) do kept.common[key] = copy(save:get(key)) end
	for _, key in ipairs(BOARDS) do kept.own[key] = copy(save:user_get(key, user)) end
	return kept
end

local function put_back(kept)
	local save = game.global("SaveManager")
	for _, key in ipairs(CAMPAIGN) do save:set(key, copy(kept.common[key])) end
	for _, key in ipairs(BOARDS) do save:user_set(key, copy(kept.own[key]), kept.user) end
end

local function is_drop(seed)
	return drop ~= nil and seed ~= nil and seed == drop.seed
end

local function start(choice, training)
	if not game.on_ship() then return false, "not_on_ship" end
	local save, menu = game.global("SaveManager"), game.state()
	if #menu:get_active_players() > 1 then return false, "solo_only" end
	local seed, why = M.seed(choice)
	if not seed then return false, why end
	local params = {
		wanted_state = "mission_start", is_training = training, mission_seed = seed, planet_name = tostring(seed),
		active_players = menu:get_active_players(), reserved_slots = {}, is_last_mission = false,
		game_id = math.create_weak_unique_identifier(), host_name = game.global("UserManager"):get_name(),
	}
	if not training then
		local ok, host = pcall(function() return game.global("NetworkGlobal").lobby:lobby_host() end)
		if ok then params.initial_host = host end
		drop = { seed = seed, kept = keep() }
	end
	-- A drop zone picked on a campaign planet would be read for this map.
	save:set("dropzone_position", nil)
	menu.state_machine:change_state("transition", params)
	return true
end

-- Starts a solo practice mission from the ship with chosen parts. As in the game's own training
-- menu, it pays no XP or samples and touches no campaign. Proving ground types need a second seed,
-- so they aren't offered.
-- choice: as for seed: { time, environment, enemy, kind, difficulty, look, layout }.
function M.practice(choice)
	return start(choice, true)
end

-- Starts a solo mission from the ship with chosen parts, as a real mission: it pays XP and samples
-- and counts toward the account like any drop. The campaign is left as it was at the drop, win or
-- loss: no planet or mission done, no planet stats, no event or boss progress, and no Galactic War or
-- leaderboard report from it. Proving ground types aren't offered.
-- choice: as for seed: { time, environment, enemy, kind, difficulty, look, layout }.
function M.drop(choice)
	return start(choice, false)
end

-- The mission end reads the save's current planet for everything it does to the campaign, so for a
-- drop it sees none, and whatever it changes anyway goes back to the drop's copies. Installed by the
-- library at load, so the hooks are its own.
function M.install()
	if hooked then return end
	hooked = true
	obsidian.hook("StateMissionEnd", "on_enter", function(original, self, params, ...)
		if not (type(params) == "table" and is_drop(params.mission_seed)) then return original(self, params, ...) end
		params.is_last_mission = false
		game.global("SaveManager"):set("current_planet", nil)
		local ok, err = pcall(original, self, params, ...)
		put_back(drop.kept)
		if not ok then error(err, 0) end
	end)
	obsidian.hook("StateMissionEnd", "save_stats", function(original, self, ...)
		if not is_drop(self.mission_seed) then return original(self, ...) end
		self.current_planet, self.current_enemy_index, self.current_planet_index = nil, nil, nil
		local ok, err = pcall(original, self, ...)
		put_back(drop.kept)
		if not ok then error(err, 0) end
	end)
	-- Back on the ship, also after a mission left early, before the ship reads the save.
	obsidian.hook("StateMenu", "on_enter", function(original, self, ...)
		if drop then
			put_back(drop.kept)
			drop = nil
		end
		return original(self, ...)
	end)
end

return M
