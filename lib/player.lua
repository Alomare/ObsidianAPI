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

-- What a perk or the settings had before an effect changed it, per unit, to give back. A new avatar
-- starts clean, and the effect goes on it again.
local held = setmetatable({}, { __mode = "k" })

local function remember(unit, key, value)
	local old = held[unit]
	if not old then
		old = {}
		held[unit] = old
	end
	if old[key] == nil then old[key] = value end
end

local function recall(unit, key)
	local old = unit and held[unit]
	local value = old and old[key]
	if old then old[key] = nil end
	return value
end

-- Armor lives twice: the guarded copy on the master, and the copy the damage sums read. The perk
-- that sets it sends both (perk_settings.lua:166,173).
local function set_armor(unit, low, high)
	local data = { armor_min = low, armor_max = high }
	game.command(unit, "health", "armor", data)
	aux().queue_command_slave(unit, "health", "armor", data)
end

effects.define({ id = "armor",
	apply = function(ctx, value)
		local health = game.master(ctx.unit, "health")
		if not health then return end
		remember(ctx.unit, "armor_min", health.armor_min or 0)
		remember(ctx.unit, "armor_max", health.armor_max or 0)
		set_armor(ctx.unit, value, value)
	end,
	remove = function(ctx)
		local low, high = recall(ctx.unit, "armor_min"), recall(ctx.unit, "armor_max")
		if low then set_armor(ctx.unit, low, high) end
	end,
})

-- A value on a plain field, set by the component's command, with what was there given back.
local function field_effect(id, component, command, field)
	effects.define({ id = id,
		apply = function(ctx, value)
			local state = game.master(ctx.unit, component)
			if not state then return end
			remember(ctx.unit, id, state[field])
			game.command(ctx.unit, component, command, value)
		end,
		remove = function(ctx)
			local old = recall(ctx.unit, id)
			if old ~= nil then game.command(ctx.unit, component, command, old) end
		end,
	})
end

field_effect("sprint_speed", "character", "move_speed_sprint_max", "move_speed_sprint_max")
field_effect("throw_range", "character", "set_throw_range_multiplier", "throw_range_multiplier")
field_effect("acceleration", "mover", "acceleration", "acceleration")
field_effect("deceleration", "mover", "deceleration", "deceleration")

-- An on and off pair of one command.
local function switch_effect(id, component, command, on, off)
	effects.define({ id = id,
		apply = function(ctx)
			if ctx.unit then game.command(ctx.unit, component, command, on) end
		end,
		remove = function(ctx)
			if ctx.unit then game.command(ctx.unit, component, command, off) end
		end,
	})
end

switch_effect("ignore_slow", "mover", "ignore_slow", true, false)
-- Off, the camera stops holding the player inside the screen.
switch_effect("no_screen_leash", "mover", "keep_inside_screen", false, true)

-- Getting out of a seat shows the model again, so the frame function looks.
effects.define({ id = "hide_model",
	apply = function(ctx)
		if ctx.unit then game.command(ctx.unit, "customization", "set_visible", false) end
	end,
	frame = function(ctx)
		local state = game.master(ctx.unit, "customization")
		if state and state.visible ~= false then game.command(ctx.unit, "customization", "set_visible", false) end
	end,
	remove = function(ctx)
		if ctx.unit then game.command(ctx.unit, "customization", "set_visible", true) end
	end,
})

-- The look only: armor values are the armor effect's. A player with the perk keeps it on the way out.
effects.define({ id = "heavy_armor_look",
	apply = function(ctx)
		local state = game.master(ctx.unit, "customization")
		if not state then return end
		remember(ctx.unit, "heavy_armor", state.heavy_armor or 1)
		game.command(ctx.unit, "customization", "enable_heavy_armor")
	end,
	remove = function(ctx)
		if recall(ctx.unit, "heavy_armor") == 1 then game.command(ctx.unit, "customization", "disable_heavy_armor") end
	end,
})

local function boxed_color(c)
	return game.global("QuaternionAux").box_elements({}, 255, c[1], c[2], c[3])
end

-- The outline a player shows through walls. value: { r, g, b }.
effects.define({ id = "outline_color",
	apply = function(ctx, value)
		if ctx.unit then game.command(ctx.unit, "customization", "set_silhouette_color", boxed_color(value)) end
	end,
	remove = function(ctx)
		local go = ctx.record and ctx.record.player_go
		local colors = game.global("GameSettings").player_colors
		local own = go and (not go.has or go:has("index")) and colors and colors[go:get("index")]
		if ctx.unit and own then game.command(ctx.unit, "customization", "set_silhouette_color", own) end
	end,
})

function M.set_outline(r, g, b)
	if r == nil then return effects.set("outline_color", false) end
	for _, n in ipairs({ r, g or false, b or false }) do
		if not (type(n) == "number" and n >= 0 and n <= 255) then return false, "out_of_range" end
	end
	return effects.set("outline_color", { r, g, b })
end

local function status_settings(name)
	local templates = game.global("StatusTemplateSettings")
	return templates and templates[name]
end

local function known_element(name)
	for _, template in pairs(game.global("StatusTemplateSettings") or {}) do
		if template.element == name then return true end
	end
	return false
end

-- The game indexes its template table with this name outside any pcall, so an unknown one is refused.
-- name: a status template or an element such as "fire".
function M.clear_status(name)
	local unit, why = my_unit()
	if not unit then return false, why end
	if status_settings(name) then
		game.command(unit, "status", "remove_status", name)
	elseif known_element(name) then
		game.command(unit, "status", "remove_statuses_by_element", name)
	else
		return false, "unknown_status"
	end
	return true
end

local function immunity_effect(name)
	local id = "immune_" .. name
	if effects.defs[id] then return id end
	local element = not status_settings(name)
	effects.define({ id = id,
		apply = function(ctx)
			if ctx.unit then game.command(ctx.unit, "status", element and "add_immunity_element" or "add_immunity_status", name) end
		end,
		-- The game only adds these, so they come off the plain table.
		remove = function(ctx)
			local state = game.master(ctx.unit, "status")
			local list = state and state[element and "immunities_elements" or "immunities_statuses"]
			if list then list[name] = nil end
		end,
	})
	return id
end

-- name as in clear_status. Stays on across respawns, until on is false.
function M.immune(name, on)
	if not (status_settings(name) or known_element(name)) then return false, "unknown_status" end
	return effects.set(immunity_effect(name), on ~= false)
end

function M.knockdown()
	local unit, why = my_unit()
	if not unit then return false, why end
	game.command(unit, "character", "do_knockdown")
	return true
end

-- Drops what the player carries, such as a hard drive.
function M.drop_carried()
	local unit, why = my_unit()
	if not unit then return false, why end
	game.command(unit, "character", "drop_carry")
	return true
end

-- Adds hitpoints, past the maximum if asked to: the game doesn't stop it here.
function M.heal_by(amount)
	local unit, why = my_unit()
	if not unit then return false, why end
	if not (type(amount) == "number" and amount > 0 and amount < 1000000) then return false, "out_of_range" end
	game.command(unit, "health", "do_heal", amount)
	return true
end

function M.set_health(hitpoints)
	local unit, why = my_unit()
	if not unit then return false, why end
	if not (type(hitpoints) == "number" and hitpoints > 0 and hitpoints < 1000000) then return false, "out_of_range" end
	game.command(unit, "health", "set_hitpoints", hitpoints)
	return true
end

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
