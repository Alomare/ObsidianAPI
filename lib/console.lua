-- The developers' console commands. In a release build Debug.console is a dummy that throws away
-- what each game script registers, but the scripts still build their command tables. Putting a
-- collector in the dummy's place keeps those tables, with no debug world, no hotkeys and no writes
-- to the user settings. The stock console itself stays off.
local game = obsidian.module("lib/game")

local M = { plugins = {}, installed = false }

-- Commands that reach the shared backend, destroy saves, spend paid content, or have no use outside
-- a developer's desk. run() refuses them, whatever a mod or a typed line asks for.
local DENIED = {}
for word in string.gmatch([[
	push_planet push_defend_event push_attack_event push_bogus_statistics debug_get_usernames
	season_end set_race_status send_message_test
	clear_save_and_tus clear_achievemenets unlock_dlc unlock_all upgrade_all
	console console_command toggle_debug toggle_title_safe show_spawn_validity picker
	set_color_blindness_none set_color_blindness_protanopia set_color_blindness_protanomaly
	set_color_blindness_deuteranopia set_color_blindness_deuteranomaly
	set_color_blindness_tritanopia set_color_blindness_tritanomaly set_color_blindness_complete
]], "%S+") do DENIED[word] = true end

-- These load a race package on this peer alone, and a peer without it can't mirror the unit.
local ALONE_ONLY = { spawn_enemy = true }

local function noop() end

local function split(line)
	local helper = rawget(string, "split_command")
	local parts = helper and helper(line)
	if parts then return parts end
	parts = {}
	for word in string.gmatch(line, "%S+") do parts[#parts + 1] = word end
	return parts
end

local function collector()
	return setmetatable({
		register_plugin = function(_, name, map, complete, docs)
			if map then M.plugins[name] = { map = map, complete = complete, docs = docs } end
		end,
		unregister_plugin = function(_, name) M.plugins[name] = nil end,
		clear = function() M.plugins = {} end,
		is_active = function() return false end,
		do_multiple_commands_string = function(_, text)
			for command in string.gmatch(text, "[^,]+") do M.run(command) end
		end,
	}, { __index = function() return noop end })
end

-- Replaces the dummy once the game has loaded its debug module. On a build where Debug is real,
-- this leaves it alone. Returns true once there's nothing left to wait for.
function M.install()
	if M.installed then return true end
	local debug_table = game.global("Debug")
	if type(debug_table) ~= "table" then return false end
	M.installed = true
	local build = game.global("Application")
	if build and build.build and build.build() ~= "release" then return true end
	debug_table.console = collector()
	debug_table.set_picker = function(picker) debug_table.picker = picker end
	return true
end

function M.denied(name)
	return DENIED[name] == true
end

-- Every command the game has registered right now, sorted, without the denied ones.
function M.commands()
	local seen, out = {}, {}
	for _, p in pairs(M.plugins) do
		for name in pairs(p.map) do
			if not seen[name] and not DENIED[name] then
				seen[name] = true
				out[#out + 1] = name
			end
		end
	end
	table.sort(out)
	return out
end

-- Runs one command line. As in the game's own dispatch, every plugin with that command runs.
-- Returns ok and a message.
function M.run(line)
	if not obsidian.session.cleared() then return false, "not_cleared" end
	local args = split(line)
	local name = args and args[1]
	if not name then return false, "unknown" end
	if DENIED[name] then return false, "denied" end
	if ALONE_ONLY[name] and not game.alone() then return false, "alone_only" end
	local ran, message = false, nil
	for _, p in pairs(M.plugins) do
		local fn = p.map[name]
		if fn then
			ran = true
			local ok, result = pcall(fn, args, line)
			if not ok then return false, tostring(result) end
			if type(result) == "table" then
				if result.error then return false, result.message end
				message = result.message or message
			elseif result ~= nil then
				message = tostring(result)
			end
		end
	end
	if not ran then return false, "unknown" end
	return true, message
end

return M
