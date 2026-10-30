-- The mission: objectives, extraction, waits, samples, and choosing what to play.
-- Objectives and the end of a mission belong to the host. The objective commands walk the entities
-- this peer owns, so an object a client is using can be missed; each action says what it reached.
local game = obsidian.module("lib/game")
local effects = obsidian.module("lib/effects")

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

function M.finish_objectives()
	if not mission_state() then return false, "not_in_mission" end
	if not game.is_host() then return false, "host_only" end
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
		if ctx.name == "game" then extract_step() end
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

-- What the current mission's seed says, or nil.
function M.params()
	local st = mission_state()
	local settings = game.global("DifficultySettings")
	if not (st and settings) then return nil end
	local ok, params = pcall(settings.get_lookup_mission_params, st.mission_seed)
	if not ok then return nil end
	return params, st.mission_seed
end

M.TIMES = { "dawn", "day", "dusk", "night" }
M.ENVIRONMENTS = { "desert", "forest", "snow", "lava", "city" }
M.FACTIONS = { "bugs", "cyborgs", "illuminates" }
M.TYPES = { "mission", "boss", "genocide" }

-- Starts a solo practice mission from the ship with chosen parts. As in the game's own training
-- menu, it pays no XP or samples and touches no campaign. Proving ground types need a second seed,
-- so they aren't offered.
-- choice: { time, environment, enemy, kind, difficulty } as 1-based indexes in the lists above.
function M.practice(choice)
	if not game.on_ship() then return false, "not_on_ship" end
	local settings = game.global("DifficultySettings")
	local save, menu = game.global("SaveManager"), game.state()
	if #menu:get_active_players() > 1 then return false, "solo_only" end
	local shading = math.random(0, 2)
	local variant = math.random(0, 2)
	local seed = settings.modulate_seed(choice.time - 1, shading, choice.environment - 1, variant, choice.enemy - 1, choice.kind - 1, choice.difficulty, math.random(1, 9))
	save:set("dropzone_position", nil)
	menu.state_machine:change_state("transition", {
		wanted_state = "mission_start", is_training = true, mission_seed = seed, planet_name = tostring(seed),
		active_players = menu:get_active_players(), reserved_slots = {},
		game_id = math.create_weak_unique_identifier(), host_name = game.global("UserManager"):get_name(),
	})
	return true
end

return M
