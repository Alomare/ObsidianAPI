-- Obsidian API: a runtime other mods build on. Nothing here does anything by itself. A mod lists
-- "obsidian.api" in requires and asks for it with obsidian.import("obsidian.api").
local game = obsidian.module("lib/game")
local effects = obsidian.module("lib/effects")
local edits = obsidian.module("lib/edits")
local console = obsidian.module("lib/console")
local data = obsidian.module("lib/data")
local catalog = obsidian.module("lib/catalog")
local world = obsidian.module("lib/world")
local player = obsidian.module("lib/player")
local gear = obsidian.module("lib/gear")
local stratagems = obsidian.module("lib/stratagems")
local enemies = obsidian.module("lib/enemies")
local mission = obsidian.module("lib/mission")
local progress = obsidian.module("lib/progress")
local events = obsidian.module("lib/events")
local combat = obsidian.module("lib/combat")
local vehicles = obsidian.module("lib/vehicles")
local lobby = obsidian.module("lib/lobby")
local audio = obsidian.module("lib/audio")
local music = obsidian.module("lib/music")
local ui = obsidian.module("lib/ui")
local map = obsidian.module("lib/map")
local bots = obsidian.module("lib/bots")
local mod_settings = obsidian.module("lib/mod_settings")
local custom = obsidian.module("lib/custom")
local menu = obsidian.module("lib/menu")
local capture = obsidian.module("lib/capture")

local gear_failed, bots_failed, music_failed = false, false, false
local last_state = nil

obsidian.on_frame(function()
	local dt = rawget(_G, "ENGINE_DT") or 0.016
	game.tick()
	effects.tick(dt)
	events.tick()
	enemies.tick()
	local st = game.state()
	if st ~= last_state then
		last_state = st
		map.reset()
	end
	pcall(mod_settings.tick)
	local ran, why = pcall(mod_settings.run_chosen)
	if not ran then obsidian.log("mod_settings: " .. tostring(why)) end
	pcall(custom.tick, dt)
	pcall(world.tick)
	-- Other machines' api.player.damage on this machine's players.
	ran, why = pcall(player.tick)
	if not ran then obsidian.log("player damage: " .. tostring(why)) end
	ran, why = pcall(capture.tick)
	if not ran then obsidian.log("capture: " .. tostring(why)) end
	local ok, err = pcall(music.tick)
	if not ok and not music_failed then
		music_failed = true
		obsidian.log("music: " .. tostring(err))
	end
	if game.session_mode then
		local ok, err = pcall(gear.tick)
		if not ok and not gear_failed then
			gear_failed = true
			obsidian.log("drones: " .. tostring(err))
		end
		ok, err = pcall(bots.tick)
		if not ok and not bots_failed then
			bots_failed = true
			obsidian.log("bots: " .. tostring(err))
		end
	end
end)

-- The map's hooks belong to this library, not to the first mod that asks for the map.
map.install()
-- The pause menu's Mod Settings: only this player's own settings, so it runs in every session.
mod_settings.install()
-- The in-game window, for any mod's pages, in any lobby. It runs from wraps, never gated.
menu.install()
-- A camera a mod takes (api.world.camera.take), in any lobby: only this player sees it.
world.install()
-- A drop from api.mission.drop leaves the campaign alone at the mission's end, whoever started it.
mission.install()

-- Where a hit is worked out: what it costs (scaled only while api.combat.scale's effects are on, which
-- an uncleared lobby takes off), and which player of this machine landed it, for api.combat.on_hit in
-- any lobby. on_fatal checks the session itself. Wraps, so the session gate never skips them.
do
	local wrap = obsidian.wrap or obsidian.hook
	wrap("HealthComponent", "calculate_damage", combat.health)
	wrap("HealthComponent", "command_master", combat.command_master)
	wrap("HealthComponent", "filter_slave_command", combat.filter_slave_command)
end

obsidian.hook("AudioStateMachine", "on_enter_state", function(original, ...)
	local a, b = original(...)
	music.after_machine_enter()
	return a, b
end)

-- Everything that can change the shared game is set up only when a session mod needs this library.
if game.session_mode then
	obsidian.on_require("foundation/lua/debug/debug", console.install)
	bots.install()
	combat.spare_with(bots.spares)
	custom.install()
	obsidian.on_frame(console.install)

	-- Effects and edits come off when the session stops being cleared, and go back when it clears.
	obsidian.on_session(function(on)
		if on then
			effects.resume()
			edits.resume()
		else
			effects.pause()
			edits.pause()
			-- The input hook stops here, so each bot gets a still input of its own.
			bots.rest_all()
		end
	end)

	obsidian.hook("CameraManager", "add_shake", function(original, ...)
		if effects.is_on("no_camera_shake") then return end
		return original(...)
	end)

	obsidian.hook("LoadoutSettings", "find_stratagem", function(original, queue, ...)
		return stratagems.find(function(q) return original(q) end, queue, ...)
	end)

	obsidian.hook("ShieldComponent", "calculate_damage", combat.shield)

	obsidian.hook("StratagemsDisabledAreaComponent", "is_unit_inside_any_area", function(original, ...)
		if effects.is_on("ignore_jammers") then return false end
		return original(...)
	end)

	obsidian.hook("StateMissionStart", "update", function(original, self, ...)
		mission.on_mission_start_update(self)
		return original(self, ...)
	end)
end

-- A loader from before obsidian.session.guard runs an update of this mod as a session mod, where
-- the mods calling it are already gated, so it hands out the real tables.
local guard = obsidian.session.guard or function(t) return t end

-- What a client mod may call: reading, undoing, and changes only this player sees or hears. A function
-- not listed here needs a session mod and a cleared session.
return {
	version = 1,
	game = guard(game, { "state", "state_name", "in_mission", "on_ship", "is_host", "lobby", "alone", "me", "avatar", "my_unit", "component",
		"all_avatars", "box", "unbox", "master", "masters", "slaves", "forfeit_progress", "hold_progress", "after", "global" }),
	effects = guard(effects, { "define", "get", "is_on", "clear", "active" }),
	edits = guard(edits, { "value", "table_value", "original", "list", "count", "revert", "revert_where", "table_changed", "revert_table", "revert_all" }),
	console = guard(console, { "denied", "commands" }),
	data = data,
	catalog = catalog,
	world = guard(world, { "shading", "flash", "cursor", "to_screen", "ahead", "raycast", "clear_decals", "light", "time_scale", "time_now", "visible",
		"flashlight", "time_of_day", "sun", "parts_of", "cape_of", "hidden", "detail", "planet_shading", "placement", "part_units", "part_hidden",
		"arc", "attach_effect", "detach_effect" }),
	player = guard(player, { "lives" }),
	gear = guard(gear),
	stratagems = guard(stratagems),
	enemies = guard(enemies, { "available", "list", "count", "carried", "room", "info", "charging", "nearest", "near", "chain", "max_enemies", "waves" }),
	mission = guard(mission, { "objectives", "params", "drop_offs", "extraction", "aboard", "areas" }),
	progress = guard(progress, { "samples", "max_samples", "loadout", "upgrades", "upgrade_limit", "rank", "owned_cosmetics" }),
	events = guard(events, { "on", "off" }),
	combat = guard(combat, { "on_hit", "off_hit" }),
	vehicles = vehicles,
	lobby = lobby,
	ui = guard(ui, { "hint", "open", "close", "menus" }),
	map = map,
	bots = guard(bots, { "all", "dead", "hazards" }),
	audio = audio,
	music = music,
	mod_settings = mod_settings,
	menu = guard(menu, { "add", "open", "close", "toggle", "is_open", "toast", "panel" }),
	capture = capture,
}
