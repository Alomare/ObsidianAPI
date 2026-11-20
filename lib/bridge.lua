-- Memory Bridge: Lua sent from outside the game, run on the game thread while the game runs, for making
-- and testing mods without a restart. Off unless the player switched the memory_bridge option on in
-- Obsidian; off, nothing here is installed.
--
-- The game can't compile Lua source (loadstring of text answers nothing), but it loads LuaJIT 2.0
-- bytecode. A tool (tools/bridge.py of the HD1 Lua Modding Skill) compiles the code with the LuaJIT that
-- ships beside Obsidian and writes it to the folder below; each frame this reads it, runs it and writes
-- the answer beside it.
--
-- The folder: %APPDATA%\Arrowhead\Helldivers\ObsidianLauncher\bridge\ (the tool makes it).
--   request         written by the tool (through a rename, so it is never read half written):
--                   "OBSBRIDGE 1\n<id>\n<arguments, tab separated>\n" then the bytecode
--   answer_<id>     written here: "<ok|error|refused> <id> <ms>\n" then the lines the code printed and
--                   one "= <value>" line per value it returned; for refused, why
--   running         the id of the request being run, gone when it ends: left behind, the game closed
--                   while running it (an engine assert can't be caught)
--   stream.txt      lines from emit(), and the errors of frame functions and hooks, as they come
--   status          rewritten every STATUS_EVERY frames: frame count, game state, whether code may run
--
-- Code runs only alone or in a lobby that isn't public (by the privacy its host set). When a public
-- lobby starts, everything the console left running (frame functions, hooks, writes) is undone.
-- While the option is on, Galactic War and leaderboard results of this launch are never sent, as with
-- session mods (the loader's backend_block): a console that runs any code could report anything.
local game = obsidian.module("lib/game")

local M = {
	on = false, lib = nil, frames = {}, frame_order = {}, hooks = {}, wrapped = {}, journal = {},
	keep = {}, frame = 0, ran = 0, told = false, warned = false, allowed_before = true,
}

M.VERSION = 1
M.STATUS_EVERY = 120
M.MAX_ANSWER = 256 * 1024
M.MAX_ENTRIES = 60

local function global(name) return rawget(_G, name) end

local function word(key, ...)
	local ok, s = pcall(obsidian.text, key, ...)
	return ok and type(s) == "string" and s or key
end

function M.dir()
	local appdata = os.getenv("APPDATA")
	if not appdata then return nil end
	return appdata .. "\\Arrowhead\\Helldivers\\ObsidianLauncher\\bridge\\"
end

local function read_all(path)
	local f = io.open(path, "rb")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end

-- Written beside, then renamed, so the tool never reads a file half written.
local function write_file(path, text)
	local tmp = path .. ".tmp"
	local f = io.open(tmp, "wb")
	if not f then return false end
	f:write(text)
	f:close()
	os.remove(path)
	if not os.rename(tmp, path) then
		os.remove(tmp)
		return false
	end
	return true
end

local function append(path, line)
	local f = io.open(path, "ab")
	if not f then return end
	f:write(line, "\n")
	f:close()
end

-- Showing values ---------------------------------------------------------------------------------------

local function key_text(k)
	if type(k) == "string" and string.match(k, "^[%a_][%w_]*$") then return k end
	if type(k) == "string" then return string.format("[%q]", k) end
	return "[" .. tostring(k) .. "]"
end

local function sorted_keys(t)
	local keys = {}
	for k in pairs(t) do keys[#keys + 1] = k end
	table.sort(keys, function(a, b)
		local ta, tb = type(a), type(b)
		if ta ~= tb then return ta < tb end
		if ta == "number" or ta == "string" then return a < b end
		return tostring(a) < tostring(b)
	end)
	return keys
end

-- A value as text: tables to `depth` levels (2 by default), at most MAX_ENTRIES entries each.
function M.show(v, depth, indent, seen)
	depth, indent, seen = depth or 2, indent or "", seen or {}
	local kind = type(v)
	if kind == "string" then
		if #v > 400 then return string.format("%q", string.sub(v, 1, 400)) .. " (" .. #v .. " bytes)" end
		return string.format("%q", v)
	end
	if kind ~= "table" then return tostring(v) end
	if seen[v] then return "<seen " .. tostring(v) .. ">" end
	if depth <= 0 then
		local n = 0
		for _ in pairs(v) do n = n + 1 end
		return "<" .. tostring(v) .. ", " .. n .. " entries>"
	end
	seen[v] = true
	local keys = sorted_keys(v)
	if #keys == 0 then
		seen[v] = nil
		return getmetatable(v) and "{} <with a metatable>" or "{}"
	end
	local inner = indent .. "  "
	local lines = { "{" }
	for i, k in ipairs(keys) do
		if i > M.MAX_ENTRIES then
			lines[#lines + 1] = inner .. "... " .. (#keys - M.MAX_ENTRIES) .. " more"
			break
		end
		lines[#lines + 1] = inner .. key_text(k) .. " = " .. M.show(v[k], depth - 1, inner, seen) .. ","
	end
	lines[#lines + 1] = indent .. "}"
	seen[v] = nil
	return table.concat(lines, "\n")
end

-- The names a value answers to: its own keys, then those of each __index table up its metatables, with
-- the type of each. A game class instance lists its methods this way.
function M.fields(v)
	local out, seen, level = {}, {}, 0
	while type(v) == "table" and not seen[v] and level < 8 do
		seen[v] = true
		for _, k in ipairs(sorted_keys(v)) do
			local name = tostring(k)
			if not out[name] then
				out[name] = true
				out[#out + 1] = name .. " (" .. type(v[k]) .. (level > 0 and ", from metatable " .. level or "") .. ")"
			end
		end
		local mt = getmetatable(v)
		v = type(mt) == "table" and rawget(mt, "__index") or nil
		level = level + 1
	end
	return out
end

-- Global names that hold `pattern` (a Lua pattern, matched in lower case), sorted, with the type of each.
function M.find(pattern)
	pattern = string.lower(tostring(pattern or ""))
	local out = {}
	for k, v in pairs(_G) do
		if type(k) == "string" and string.find(string.lower(k), pattern) then out[#out + 1] = k .. " (" .. type(v) .. ")" end
	end
	table.sort(out)
	return out
end

-- The upvalues of a function, name and value. Game scripts are stripped, so their names are often empty.
function M.upvalues(fn)
	local out = {}
	if type(fn) ~= "function" or not debug or not debug.getupvalue then return out end
	for i = 1, 255 do
		local name, value = debug.getupvalue(fn, i)
		if name == nil then break end
		out[#out + 1] = { i = i, name = name, value = value }
	end
	return out
end

-- Undoing ------------------------------------------------------------------------------------------------

-- t[k] = v, with the value before kept for undo(). Only the first value before is kept.
function M.set(t, k, v)
	if type(t) ~= "table" then error("set: a table first", 2) end
	local inner = M.journal[t]
	if not inner then
		inner = {}
		M.journal[t] = inner
	end
	if inner[k] == nil then inner[k] = { was = rawget(t, k) } end
	t[k] = v
	return v
end

local function count(t)
	local n = 0
	for _ in pairs(t) do n = n + 1 end
	return n
end

-- Takes back what the console left: every frame function, every hook, every write made with set().
-- Answers how many of each.
function M.undo()
	local frames, hooks, writes = count(M.frames), count(M.hooks), 0
	M.frames, M.frame_order, M.hooks = {}, {}, {}
	for t, inner in pairs(M.journal) do
		for k, entry in pairs(inner) do
			writes = writes + 1
			pcall(function() t[k] = entry.was end)
		end
	end
	M.journal = {}
	return { frames = frames, hooks = hooks, writes = writes }
end

-- Frame functions and the stream --------------------------------------------------------------------------

function M.emit(...)
	local dir = M.dir()
	if not dir then return end
	local parts = {}
	for i = 1, select("#", ...) do
		local v = (select(i, ...))
		parts[#parts + 1] = type(v) == "string" and v or M.show(v, 1)
	end
	append(dir .. "stream.txt", M.frame .. "\t" .. table.concat(parts, " "))
end

-- fn(dt, frame) runs every frame until it returns true, fails or every(name, nil). One per name: the
-- same name again replaces it.
function M.every(name, fn)
	name = tostring(name)
	if fn ~= nil and type(fn) ~= "function" then error("every: a function or nil", 2) end
	if fn and not M.frames[name] then M.frame_order[#M.frame_order + 1] = name end
	M.frames[name] = fn
	return fn ~= nil
end

local function run_frames(dt)
	local order, keep = M.frame_order, {}
	for _, name in ipairs(order) do
		local fn = M.frames[name]
		if fn then
			local ok, result = xpcall(function() return fn(dt, M.frame) end, debug and debug.traceback or tostring)
			if not ok then
				M.frames[name] = nil
				M.emit("frame function " .. name .. " stopped: " .. tostring(result))
			elseif result == true then
				M.frames[name] = nil
			else
				keep[#keep + 1] = name
			end
		end
	end
	if #keep ~= #order then M.frame_order = keep end
end

-- Hooks ----------------------------------------------------------------------------------------------------

local function pack(...) return { n = select("#", ...), ... } end

-- hook("Class", "method", function(original, ...) ... end): as obsidian.hook, live. One per method: the
-- same method again replaces it, unhook takes it off. The loader can't take a hook off, so the wrapper
-- stays and calls the game's function straight while no live hook is set. A hook that fails is taken
-- off, and the error goes to the stream.
function M.hook(target, method, fn)
	if type(fn) ~= "function" then error("hook: a function", 2) end
	local key = (type(target) == "string" and target or tostring(target)) .. "." .. tostring(method)
	M.hooks[key] = fn
	if not M.wrapped[key] then
		M.wrapped[key] = true
		local wrap = obsidian.wrap or obsidian.hook
		wrap(target, method, function(original, ...)
			local live = M.hooks[key]
			if not live then return original(...) end
			local got
			local function call(...)
				got = pack(original(...))
				return unpack(got, 1, got.n)
			end
			local r = pack(xpcall(live, debug and debug.traceback or tostring, call, ...))
			if r[1] then return unpack(r, 2, r.n) end
			M.hooks[key] = nil
			M.emit("hook " .. key .. " taken off: " .. tostring(r[2]))
			if got then return unpack(got, 1, got.n) end
			return original(...)
		end)
	end
	return true
end

function M.unhook(target, method)
	local key = (type(target) == "string" and target or tostring(target)) .. "." .. tostring(method)
	local had = M.hooks[key] ~= nil
	M.hooks[key] = nil
	return had
end

-- Where code may run ------------------------------------------------------------------------------------

-- The privacy the host of a lobby set, from the room data every member reads; nil when unknown.
local function privacy(l)
	local engine = type(l) == "table" and l.lobby or nil
	if engine == nil then return nil end
	local ok, raw = pcall(function() return engine:data("data") end)
	local network, settings = global("NetworkGlobal"), global("GameSettings")
	if not ok or type(raw) ~= "string" or type(network) ~= "table" or type(settings) ~= "table" then return nil end
	local parsed, t = pcall(network.data_string_to_table, raw, settings.room_data_values)
	return parsed and type(t) == "table" and tonumber(t.privacy) or nil
end

-- true, or false and why not: alone, or in a lobby that isn't public. Unknown privacy counts as public.
function M.allowed()
	local l = game.lobby()
	if not l or game.alone() then return true end
	local kinds = type(global("GameSettings")) == "table" and global("GameSettings").room_privacy_settings or nil
	local p = privacy(l)
	if p == nil or type(kinds) ~= "table" or p == kinds.public then return false, "public_lobby" end
	return true
end

-- Requests -------------------------------------------------------------------------------------------------

-- The environment code runs in: the helpers, then the game's globals (read raw, as the game's strict
-- globals throw on a name nobody declared). A name the code sets stays in its own environment; keep is
-- shared by every request.
local function environment(lines)
	local helpers = {
		api = M.lib, obsidian = global("obsidian"), keep = M.keep, g = global,
		print = function(...)
			local parts = {}
			for i = 1, select("#", ...) do
				local v = (select(i, ...))
				parts[#parts + 1] = type(v) == "string" and v or M.show(v)
			end
			lines[#lines + 1] = table.concat(parts, " ")
		end,
		show = function(v, depth) lines[#lines + 1] = M.show(v, depth) end,
		fields = M.fields, find = M.find, upvalues = M.upvalues,
		set = M.set, undo = M.undo, every = M.every, emit = M.emit, hook = M.hook, unhook = M.unhook,
		frame = function() return M.frame end,
		-- A screenshot of the game now, into the bridge folder: the path, or nil and why not.
		shot = function(name)
			local capture = M.lib and M.lib.capture
			if not capture then return nil, "no_capture" end
			return capture.save_now({ folder = string.gsub(M.dir(), "\\$", ""), name = name or "shot %H-%M-%S" })
		end,
	}
	return setmetatable({}, { __index = function(_, k)
		local v = helpers[k]
		if v ~= nil then return v end
		return rawget(_G, k)
	end })
end

-- One request: its id, its arguments and its code, from the file's text. nil when the file is wrong.
function M.parse(text)
	if type(text) ~= "string" then return nil end
	local magic, id, args, code = string.match(text, "^(OBSBRIDGE %d+)\n([%w_%-]+)\n([^\n]*)\n(.*)$")
	if magic ~= "OBSBRIDGE " .. M.VERSION then return nil end
	local list = {}
	for a in string.gmatch(args, "[^\t]+") do list[#list + 1] = a end
	return { id = id, args = list, code = code }
end

local function clock()
	return os.clock()
end

-- Runs a request; answers the text of the answer.
function M.run(req)
	local allowed, why = M.allowed()
	if not allowed then return "refused " .. req.id .. " 0\n" .. why .. "\n" end
	local fn = loadstring(req.code)
	if type(fn) ~= "function" then
		return "error " .. req.id .. " 0\nthe code didn't load: send LuaJIT 2.0 bytecode, as tools/bridge.py compiles it\n"
	end
	local lines = {}
	setfenv(fn, environment(lines))
	M.ran = M.ran + 1
	if not M.told then
		M.told = true
		pcall(function() M.lib.menu.toast(word("bridge_running")) end)
	end
	local dir = M.dir()
	write_file(dir .. "running", req.id .. "\n")
	obsidian.log("bridge: running " .. req.id)
	local started = clock()
	local r = pack(xpcall(function() return fn(unpack(req.args)) end, debug and debug.traceback or tostring))
	local ms = string.format("%.1f", (clock() - started) * 1000)
	os.remove(dir .. "running")
	if not r[1] then
		lines[#lines + 1] = tostring(r[2])
		return "error " .. req.id .. " " .. ms .. "\n" .. table.concat(lines, "\n") .. "\n"
	end
	for i = 2, r.n do lines[#lines + 1] = "= " .. M.show(r[i]) end
	return "ok " .. req.id .. " " .. ms .. "\n" .. table.concat(lines, "\n") .. (#lines > 0 and "\n" or "")
end

local function answer(id, text)
	if #text > M.MAX_ANSWER then text = string.sub(text, 1, M.MAX_ANSWER) .. "\n... cut at " .. M.MAX_ANSWER .. " bytes\n" end
	write_file(M.dir() .. "answer_" .. id, text)
end

function M.poll()
	local dir = M.dir()
	if not dir then return end
	local path = dir .. "request"
	local text = read_all(path)
	if not text then return end
	os.remove(path)
	local req = M.parse(text)
	if not req then
		obsidian.log("bridge: a request that isn't OBSBRIDGE " .. M.VERSION .. " was dropped")
		return
	end
	answer(req.id, M.run(req))
end

local function status()
	local dir = M.dir()
	if not dir then return end
	local allowed, why = M.allowed()
	write_file(dir .. "status", table.concat({
		"version " .. M.VERSION, "frame " .. M.frame, "time " .. os.time(), "state " .. tostring(game.state_name()),
		"allowed " .. (allowed and "yes" or ("no " .. tostring(why))), "ran " .. M.ran,
		"frames " .. count(M.frames), "hooks " .. count(M.hooks),
	}, "\n") .. "\n")
end

function M.tick(dt)
	M.frame = M.frame + 1
	local allowed = M.allowed()
	if not allowed and M.allowed_before then
		local took = M.undo()
		if took.frames + took.hooks + took.writes > 0 then M.emit("public lobby: undid " .. M.show(took, 1)) end
	end
	M.allowed_before = allowed
	if allowed then
		M.poll()
		run_frames(dt)
	end
	if M.frame % M.STATUS_EVERY == 1 then status() end
	if not M.warned and game.state_name() == "menu" then
		M.warned = true
		pcall(obsidian.notify, word("bridge_on_notice"))
	end
end

-- Results ------------------------------------------------------------------------------------------------

-- The same entry points and queues as the loader's backend_block: a call never goes out, the tables
-- handed in are emptied, and the queues the game keeps for later are dropped at every save.
M.REPORTS = {
	"upload_mission_stats", "upload_leaderboard_stats", "upload_leaderboard_provinggrounds_stats",
	"complete_planets", "complete_defend_event_mission", "complete_attack_event_mission",
}
M.COMMON_QUEUES = { "mission_stats", "mission_stats_to_upload", "completed_planets" }
M.USER_QUEUES = { "leaderboard_stats", "leaderboard_stats_to_upload", "leaderboard_provinggrounds_stats", "leaderboard_provinggrounds_stats_to_upload" }

local function empty(t)
	local keys = {}
	for k in pairs(t) do keys[#keys + 1] = k end
	for _, k in ipairs(keys) do t[k] = nil end
end

function M.hold_reports()
	local wrap = obsidian.wrap or obsidian.hook
	for _, name in ipairs(M.REPORTS) do
		wrap("CampaignManager", name, function(_, _, ...)
			for i = 1, select("#", ...) do
				local v = (select(i, ...))
				if type(v) == "table" then empty(v) end
			end
			obsidian.log("bridge: held back " .. name)
		end)
	end
	wrap("SaveManager", "save", function(original, self, ...)
		for _, key in ipairs(M.COMMON_QUEUES) do pcall(self.set, self, key, nil) end
		return original(self, ...)
	end)
	wrap("SaveManager", "user_save", function(original, self, done, fail, subtitle, details, user, ...)
		for _, key in ipairs(M.USER_QUEUES) do pcall(self.user_set, self, key, nil, user) end
		return original(self, done, fail, subtitle, details, user, ...)
	end)
end

-- From main.lua with the library's own modules, unguarded: the console is for a developer alone or in
-- a private lobby, where nothing needs the session gate.
function M.install(lib)
	local got, on = pcall(obsidian.settings.get, "memory_bridge")
	if not got or on ~= true then return false end
	M.on, M.lib = true, lib
	M.hold_reports()
	local failed = false
	obsidian.on_frame(function()
		local ok, err = pcall(M.tick, rawget(_G, "ENGINE_DT") or 0.016)
		if not ok and not failed then
			failed = true
			obsidian.log("bridge: " .. tostring(err))
		end
	end, { always = true })
	obsidian.log("bridge: the Memory Bridge is on; Galactic War and leaderboard results are held back")
	return true
end

return M
