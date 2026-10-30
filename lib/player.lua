-- The local player: staying alive, moving, getting around, looking the part.
-- Avatar health and status belong to the avatar's owner, so all of this works as a client too.
local game = obsidian.module("lib/game")
local effects = obsidian.module("lib/effects")
local world = obsidian.module("lib/world")

local M = {}

local function aux()
	return game.global("EntityAux")
end

local function my_unit()
	local unit = game.my_unit()
	if not unit then return nil, "no_avatar" end
	return unit
end

local function set_flag(component, field, value)
	local c = game.component(component)
	if c then c[field] = value end
end

local function character_settings(unit)
	local lsm = game.global("LuaSettingsManager")
	local s = lsm and lsm:get_settings_by_unit(unit)
	return s and s.character_info
end

-- god: the flags stop ordinary damage, and the frame function catches what goes around them, such
-- as a seat destroyed under the player, which sets hitpoints directly.
effects.define({ id = "god",
	apply = function(ctx)
		set_flag("health", "player_invincibility", true)
		set_flag("status", "status_immune", true)
		if ctx.unit then
			game.command(ctx.unit, "health", "set_invincible", true)
			game.command(ctx.unit, "health", "set_ignore_death_plane", true)
		end
	end,
	frame = function(ctx)
		if not ctx.unit then return end
		local health = aux().state(ctx.unit, "health")
		if health and health.is_downed and not health.is_dead then game.command(ctx.unit, "health", "reset") end
	end,
	remove = function(ctx)
		set_flag("health", "player_invincibility", false)
		set_flag("status", "status_immune", effects.is_on("no_status"))
		if ctx.unit then
			game.command(ctx.unit, "health", "set_invincible", false)
			game.command(ctx.unit, "health", "set_ignore_death_plane", false)
		end
	end,
})

effects.define({ id = "no_status",
	apply = function() set_flag("status", "status_immune", true) end,
	remove = function() set_flag("status", "status_immune", effects.is_on("god")) end,
})

-- The stamina value is a plain field. The command only freezes it, so it's filled as well.
effects.define({ id = "infinite_stamina",
	apply = function(ctx)
		if ctx.unit then game.command(ctx.unit, "character", "infinite_stamina", true) end
	end,
	frame = function(ctx)
		local state = game.master(ctx.unit, "character")
		if not state then return end
		local info = character_settings(ctx.unit)
		state.sprint_stamina = info and info.sprint_stamina or 5
	end,
	remove = function(ctx)
		if ctx.unit then game.command(ctx.unit, "character", "infinite_stamina", false) end
	end,
})

-- A multiplier the mover reads for every state, unlike the speeds in the settings.
effects.define({ id = "speed",
	apply = function(ctx, value)
		local state = game.master(ctx.unit, "mover")
		if state then state.velocity_scale = value end
	end,
	remove = function(ctx)
		local state = game.master(ctx.unit, "mover")
		if state then state.velocity_scale = nil end
	end,
})

effects.define({ id = "regen",
	apply = function(ctx, value)
		if ctx.unit then game.command(ctx.unit, "health", "set_health_decay", -value) end
	end,
	remove = function(ctx)
		if ctx.unit then game.command(ctx.unit, "health", "set_health_decay", nil) end
	end,
})

effects.define({ id = "shield",
	apply = function(ctx, value)
		if not ctx.unit then return end
		game.command(ctx.unit, "shield", "set_shield_info", { shield = value, shield_regen = value / 10, shield_regen_delay = 1, armor_min = 0, armor_max = 0 })
		game.command(ctx.unit, "shield", "set_shieldpoints", value)
		game.command(ctx.unit, "shield", "set_shield_activated", true)
	end,
	remove = function(ctx)
		if not ctx.unit then return end
		game.command(ctx.unit, "shield", "reset_shield_info")
		game.command(ctx.unit, "shield", "set_shield_activated", false)
	end,
})

-- Enemies stop targeting this player. Seats and cutscenes turn targeting back on, so it's repeated.
local hide_timer = 0
effects.define({ id = "hidden",
	apply = function(ctx)
		if ctx.unit then game.command(ctx.unit, "enemy_target", "disable") end
	end,
	frame = function(ctx, _, dt)
		hide_timer = hide_timer + dt
		if hide_timer >= 1 and ctx.unit then
			hide_timer = 0
			game.command(ctx.unit, "enemy_target", "disable")
		end
	end,
	remove = function(ctx)
		if ctx.unit then game.command(ctx.unit, "enemy_target", "enable") end
	end,
})

-- The way a vehicle seat works: with no physics mover, the position is written directly.
effects.define({ id = "noclip",
	apply = function(ctx)
		if not ctx.unit then return end
		game.command(ctx.unit, "health", "set_ignore_death_plane", true)
		game.command(ctx.unit, "mover", "destroy")
	end,
	frame = function(ctx, value, dt)
		local character, mover = game.master(ctx.unit, "character"), game.master(ctx.unit, "mover")
		if not (character and mover and character.input and character.input.movement) then return end
		local speed = value == true and 12 or value
		game.command(ctx.unit, "mover", "position", game.box(game.unbox(mover.position) + game.unbox(character.input.movement) * speed * dt))
	end,
	remove = function(ctx)
		local mover = game.master(ctx.unit, "mover")
		if not mover then return end
		local at = game.unbox(mover.position)
		game.command(ctx.unit, "mover", "enable")
		game.command(ctx.unit, "mover", "position", game.box(at))
		if not effects.is_on("god") then game.command(ctx.unit, "health", "set_ignore_death_plane", false) end
	end,
})

function M.heal()
	local unit, why = my_unit()
	if not unit then return false, why end
	game.command(unit, "health", "reset")
	game.command(unit, "status", "remove_all")
	return true
end

-- Downed players get up with a heal. A dead avatar has no way back but a respawn.
function M.revive()
	local unit, why = my_unit()
	if not unit then return false, why end
	game.command(unit, "health", "reset")
	return true
end

function M.respawn()
	local st = game.state()
	local record = game.me(st)
	if not record or not game.in_mission() then return false, "not_in_mission" end
	local unit = game.avatar(record)
	if unit then
		local health = aux().state(unit, "health")
		if health and not health.is_dead then return false, "alive" end
	end
	record.spawn_timer = 0.01
	return true
end

-- Helping teammates goes through the owner, with the game's own requests.
function M.heal_everyone()
	local st = game.state()
	if not game.in_mission() then return false, "not_in_mission" end
	for _, p in ipairs(game.all_avatars()) do
		if p.owned then
			game.command(p.unit, "health", "reset")
		else
			st.network_router:transmit_to(aux().owner(p.unit), "rpc_heal_request", p.unit, 9999)
		end
	end
	return true
end

function M.revive_everyone()
	local st = game.state()
	if not game.in_mission() then return false, "not_in_mission" end
	for _, p in ipairs(game.all_avatars()) do
		if p.owned then
			game.command(p.unit, "health", "reset")
		else
			st.network_router:transmit_to(aux().owner(p.unit), "rpc_set_hitpoints_request", p.unit, nil, nil, 75)
		end
	end
	return true
end

function M.lives()
	local record = game.me()
	return record and record.extra_lives
end

-- Only through the game's setter: the value is under the tamper check. Lives count only alone.
function M.set_lives(n)
	local st = game.state()
	local record = game.me(st)
	if not (record and game.in_mission()) then return false, "not_in_mission" end
	st:set_extra_lives(record, n)
	return true
end

local function teleport(pos)
	local unit, why = my_unit()
	if not unit then return false, why end
	if not pos then return false, "no_position" end
	local units = game.global("Unit")
	if not (game.master(unit, "mover") and units.mover(unit)) then return false, "seated" end
	local v3 = game.global("Vector3")
	local p = pos
	for _ = 1, 30 do
		if units.mover_fits_at(unit, 1, p) then break end
		p = p + v3(0, 0, 0.1)
	end
	game.command(unit, "mover", "position_teleport", game.box(p))
	return true
end
M.teleport = teleport

function M.teleport_cursor()
	return teleport(world.cursor())
end

function M.teleport_ahead(metres)
	return teleport(world.ahead(metres or 10))
end

function M.teleport_spawn()
	local st = game.state()
	if not (type(st) == "table" and st.respawn_position) then return false, "not_in_mission" end
	return teleport(game.unbox(st.respawn_position))
end

local function objective_position(wanted)
	local st = game.state()
	local mm = type(st) == "table" and st.mission_manager
	if not mm then return nil end
	for _, o in ipairs(mm:get_objectives()) do
		local open = o.state ~= "complete" and o.state ~= "failed"
		if open and wanted(o) and o.position and o.position[1] then return game.unbox(o.position[1]) end
	end
	return nil
end

function M.teleport_objective()
	return teleport(objective_position(function(o) return o.name ~= "mission_objective_extract" end))
end

function M.teleport_extraction()
	local pos = objective_position(function(o) return o.name == "mission_objective_extract" end)
	if not pos then
		for unit in pairs(game.slaves("objective_extract_lz")) do
			pos = game.global("Unit").world_position(unit, 0)
			break
		end
	end
	return teleport(pos)
end

-- Back on the map from wherever the player got stuck.
function M.unstick()
	local unit, why = my_unit()
	if not unit then return false, why end
	local st = game.state()
	if not st.generated_level then return false, "not_in_mission" end
	return teleport(st.generated_level:get_closest_position_on_level(game.global("Unit").world_position(unit, 0)))
end

-- slot: helmet, body or cape, with an index from catalog.cosmetics. Comes back on respawn.
function M.set_cosmetic(slot, index)
	local unit, why = my_unit()
	if not unit then return false, why end
	game.command(unit, "customization", "set_customization", { [slot] = index })
	return true
end

function M.taunt()
	local unit, why = my_unit()
	if not unit then return false, why end
	game.command(unit, "customization", "communication_event", { event = "taunt" })
	return true
end

return M
