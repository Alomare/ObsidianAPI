-- Events: hearing what happens in a mission, without polling. The game tells its listeners through
-- an event delegate, a new one per game state. It has no pcall, and the loader's session gate doesn't
-- reach it, so both are done here. Each function a mod gives is a hook on a small table of its own:
-- the loader then runs it protected, as that mod, and not at all once the mod is off.
local game = obsidian.module("lib/game")

local M = { delegate = nil }

-- The game's own names. What each one carries is in the wiki.
M.NAMES = { "on_enemy_killed", "on_enemy_spawned", "on_player_death", "on_objective_completed", "on_stratagem_activated", "on_avatar_extract" }

local lists = {}
local listener = {}
local wanted = false

local function noop() end

local function dispatch(name, ...)
	if not obsidian.session.cleared() then return end
	for _, entry in ipairs(lists[name]) do
		local ok, err = pcall(entry.run, ...)
		if not ok then obsidian.log("event " .. name .. ": " .. tostring(err)) end
	end
end

for _, name in ipairs(M.NAMES) do
	lists[name] = {}
	listener[name] = function(_, ...) dispatch(name, ...) end
end

function M.on(name, fn)
	if not lists[name] then return false, "unknown_event" end
	if type(fn) ~= "function" then return false, "bad_type" end
	local entry = { fn = fn, run = noop }
	obsidian.hook(entry, "run", function(_, ...) return fn(...) end)
	local list = lists[name]
	list[#list + 1] = entry
	wanted = true
	return true
end

-- A new list each time, so a function can take itself off while its event is going round.
function M.off(name, fn)
	if not lists[name] then return false, "unknown_event" end
	local kept = {}
	for _, entry in ipairs(lists[name]) do
		if entry.fn ~= fn then kept[#kept + 1] = entry end
	end
	lists[name] = kept
	return true
end

-- Registering twice on one delegate fails an assert, so this remembers the one it joined. Nothing
-- joins until a mod has asked for an event.
function M.tick()
	if not wanted then return end
	local st = game.state()
	local delegate = type(st) == "table" and st.event_delegate
	if delegate and delegate ~= M.delegate then
		M.delegate = delegate
		delegate:register(listener, unpack(M.NAMES))
	end
end

return M
