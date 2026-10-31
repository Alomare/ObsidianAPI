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
local ui = obsidian.module("lib/ui")

obsidian.on_frame(function()
	local dt = rawget(_G, "ENGINE_DT") or 0.016
	game.tick()
	effects.tick(dt)
	events.tick()
	enemies.tick()
end)

-- Everything that can change the shared game is set up only when a session mod needs this library.
if game.session_mode then
	obsidian.on_require("foundation/lua/debug/debug", console.install)
	obsidian.on_frame(console.install)

	-- Effects and edits come off when the session stops being cleared, and go back when it clears.
	obsidian.on_session(function(on)
		if on then
			effects.resume()
			edits.resume()
		else
			effects.pause()
			edits.pause()
		end
	end)

	-- Stat-changed play earns no Steam achievements. The hook is the mod's, so it's off when the mod is.
	obsidian.hook("UserManager", "unlock_trophy", function()
		obsidian.log("achievement held back while Obsidian API is on")
	end)

	obsidian.hook("CameraManager", "add_shake", function(original, ...)
		if effects.is_on("no_camera_shake") then return end
		return original(...)
	end)

	obsidian.hook("LoadoutSettings", "find_stratagem", function(original, queue, ...)
		return stratagems.find(function(q) return original(q) end, queue, ...)
	end)

	obsidian.hook("HealthComponent", "calculate_damage", combat.health)
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
	world = guard(world, { "shading", "flash", "cursor", "ahead", "clear_decals" }),
	player = guard(player, { "lives" }),
	gear = guard(gear),
	stratagems = guard(stratagems),
	enemies = guard(enemies, { "available", "list", "count", "carried", "room", "info", "nearest", "near", "max_enemies", "waves" }),
	mission = guard(mission, { "objectives", "params" }),
	progress = guard(progress, { "samples", "max_samples", "loadout", "upgrades", "upgrade_limit", "rank", "owned_cosmetics" }),
	events = guard(events, { "on", "off" }),
	combat = guard(combat),
	vehicles = vehicles,
	lobby = lobby,
	ui = guard(ui, { "hint", "open", "close", "menus" }),
	audio = audio,
}
