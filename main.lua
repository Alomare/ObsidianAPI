-- Obsidian API: a runtime other mods build on. Nothing here does anything by itself. A mod lists
-- "obsidian.api" in requires and asks for it with obsidian.import("obsidian.api").
-- Everything goes through the game's own paths: see docs/superpowers/specs/2026-10-30-obsidian-api-design.md.
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

obsidian.on_frame(function()
	local dt = rawget(_G, "ENGINE_DT") or 0.016
	game.tick()
	effects.tick(dt)
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

obsidian.hook("StateMissionStart", "update", function(original, self, ...)
	mission.on_mission_start_update(self)
	return original(self, ...)
end)

return {
	version = 1,
	game = game,
	effects = effects,
	edits = edits,
	console = console,
	data = data,
	catalog = catalog,
	world = world,
	player = player,
	gear = gear,
	stratagems = stratagems,
	enemies = enemies,
	mission = mission,
	progress = progress,
}
