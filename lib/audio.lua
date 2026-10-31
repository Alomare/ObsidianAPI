-- Sound. All of it is local: other players hear their own game.
local game = obsidian.module("lib/game")
local effects = obsidian.module("lib/effects")

local M = {}

-- Every bus a game script sets. The mix states write the second group as they blend, Boot writes
-- music_master each frame and the options write the other masters, so a volume repeats every frame.
-- "master" is left out: the game only ever adds to it, so it has no value to give back.
local MASTERS = { sfx_master = true, vo_master = true, intro_master = true }
M.BUSES = { "sfx_master", "vo_master", "music_master", "intro_master", "ambient_base", "ambient_top", "combat_effects", "combat_enemy",
	"combat_player", "combat_player_extra", "misc_weapons", "music", "music_event", "reflections", "stinger", "vo", "vo_pain", "wep_casing", "wep_rattle" }

local known = {}
for _, name in ipairs(M.BUSES) do known[name] = true end

local function set_bus(name, db)
	game.global("Timpani").set_bus_volume(name, db)
end

local function give_back(name)
	if MASTERS[name] then
		local boot = game.global("Boot")
		if boot and boot.update_volume then boot.update_volume() end
	elseif name ~= "music_master" then
		local st = game.state()
		local machine = type(st) == "table" and st.audio_state_machine
		set_bus(name, machine and machine.bus_volumes and machine.bus_volumes[name] or 0)
	end
end

local function bus_effect(name)
	local id = "bus_" .. name
	if not effects.defs[id] then
		effects.define({ id = id,
			frame = function(_, db) set_bus(name, db) end,
			remove = function() give_back(name) end,
		})
	end
	return id
end

-- name: one of BUSES. db: a volume in decibels, 0 is as mixed and -60 silent; nil or false gives the
-- bus back to the game.
function M.bus(name, db)
	if not known[name] then return false, "unknown_bus" end
	if db and not (type(db) == "number" and db >= -100 and db <= 24) then return false, "out_of_range" end
	return effects.set(bus_effect(name), db or false)
end

local function sound_world()
	local st = game.state()
	local proxy = type(st) == "table" and st.world_proxy
	if not proxy then return nil end
	return proxy:get_timpani_world()
end

-- An event the game doesn't have may not fail politely, so it's asked first, as the game does before
-- a voice line (customization_component.lua:314).
local function has_event(world, event)
	return type(event) == "string" and game.global("TimpaniWorld").has_event(world, event)
end

-- event: a sound event such as "ui_select". pos: where it plays, nil for everywhere.
function M.play(event, pos)
	local world = sound_world()
	if not world then return false, "no_world" end
	if not has_event(world, event) then return false, "unknown_event" end
	local timpani = game.global("TimpaniWorld")
	if pos then
		timpani.trigger_event(world, event, pos)
	else
		timpani.trigger_event(world, event)
	end
	return true
end

-- A music sting, through the game's own cooldown of 5 s. Mission only.
function M.stinger(name)
	local st = game.state()
	local machine = type(st) == "table" and st.audio_state_machine
	if not machine then return false, "not_in_mission" end
	if not has_event(sound_world(), name) then return false, "unknown_event" end
	machine:play_stinger(name)
	return true
end

return M
