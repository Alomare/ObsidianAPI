-- Script Profiler: a panel over the game that lists every running mod with the time its scripts take
-- each frame, and what that costs in frames per second. The times come from the loader
-- (obsidian.profiler), which takes the game's own functions out of a hook's time. The F6 window has a
-- page for it: where it shows (hidden, pause menu only, always), how much it lists, and how it looks.
--
-- While the panel is not hidden it also writes to this library's log every LOG_EVERY seconds: the
-- frame time, and for each mod that costs something its time, slowest frame, calls and the hooks,
-- frame functions and measured sections the time goes to. The parts of this library's own frame are
-- measured one by one (main.lua), so its line names which of them costs.
--
-- Measuring costs a little of every call into a mod, so the loader measures only while the panel can
-- show. A loader without obsidian.profiler leaves the page with a line saying so.
local M = {}

local function global(name) return rawget(_G, name) end

local DESIGN_W, DESIGN_H = 1280, 720
local LAYER = 860 -- under the F6 window and its messages (862 and up), over the game's HUD
local MARGIN = 12
local BACK = { 0, 0, 0, 51 } -- black at 20%
local WHITE, GREY, GOLD, RED = { 236, 235, 231, 255 }, { 180, 181, 178, 255 }, { 240, 180, 41, 255 }, { 255, 155, 94, 255 }

M.SHOW = { "hidden", "pause", "always" }
M.DETAIL = { "basic", "detailed" }
M.CORNER = { "top_left", "top_right", "bottom_left", "bottom_right" }
M.SIZE = { small = 13, medium = 15, large = 18 }
M.ROWS = { 5, 10, 0 } -- 0: every mod

M.DEFAULTS = { show = "hidden", detail = "basic", corner = "top_left", size = "medium", rows = 10 }

M.NAME_EMS = 17       -- the name column, in text sizes
M.GAP_EMS = 1.4       -- between two columns, in text sizes
M.SCROLL_SPEED = 2.2  -- a long name scrolls this many text sizes a second
M.SCROLL_REST = 1.2   -- seconds a long name rests at each end
M.LOG_EVERY = 10      -- seconds between two log reports
M.LOG_MODS = 8        -- mods in a report at most
M.LOG_MIN_MS = 0.02   -- a mod below this a frame is left out of a report

local KEY = "profiler/"
M.values = {}
M.kit = nil
M.loader = nil -- obsidian.profiler, when the loader has it
M.measuring = false
M.names = {}
M.widths = {}
M.clock = 0
M.next_log = nil

function M.get(id)
	local v = M.values[id]
	if v == nil then v = M.DEFAULTS[id] end
	return v
end

-- Whether the panel may show now, by the show setting and what is on screen: in the pause menu, or
-- while the F6 window is open.
function M.wanted(show, screen, menu_open)
	if show == "always" then return true end
	if show == "pause" then return screen == "main" or menu_open == true end
	return false
end

-- Frames a second this mod costs: the rate without its time, less the rate now.
function M.fps_cost(frame_ms, ms)
	if not frame_ms or frame_ms <= 0 or not ms or ms <= 0 then return 0 end
	local without = math.max(frame_ms - ms, 0.1)
	return 1000 / without - 1000 / frame_ms
end

-- The rows the panel lists, from a loader result: the most costly first, cut to `rows` (0 for all),
-- each { name, ms, peak_ms, calls, fps }.
function M.rows(result, rows, name_of)
	local out = {}
	if type(result) ~= "table" or type(result.mods) ~= "table" then return out end
	for i, m in ipairs(result.mods) do
		if rows and rows > 0 and i > rows then break end
		out[#out + 1] = { id = m.id, name = name_of and name_of(m.id) or m.id, ms = m.ms, peak_ms = m.peak_ms, calls = m.calls,
			fps = M.fps_cost(result.frame_ms, m.ms), sites = m.sites }
	end
	return out
end

-- How far a name `over` units too long has scrolled at time `t`: rests at the start, moves at
-- `speed`, rests at the end, comes back.
function M.scroll_offset(over, t, speed, rest)
	if over <= 0 then return 0 end
	local move = over / speed
	local cycle = 2 * (rest + move)
	local u = t % cycle
	if u < rest then return 0 end
	if u < rest + move then return (u - rest) * speed end
	if u < 2 * rest + move then return over end
	return over - (u - 2 * rest - move) * speed
end

local function fmt(v, places)
	return string.format("%." .. (places or 2) .. "f", v or 0)
end

-- The report written to the log: the lines, from a loader result.
function M.report(result, name_of)
	if type(result) ~= "table" then return {} end
	local lines = {}
	local fps = 1000 / math.max(result.frame_ms or 0, 0.01)
	lines[1] = string.format("profiler: frame %s ms (%s FPS) over %d frames; all scripts %s ms, %s FPS (%s clock)",
		fmt(result.frame_ms), fmt(fps, 0), result.frames or 0, fmt(result.total_ms), fmt(M.fps_cost(result.frame_ms, result.total_ms), 1),
		tostring(result.clock or "?"))
	local n = 0
	for _, m in ipairs(result.mods or {}) do
		if m.ms >= M.LOG_MIN_MS and n < M.LOG_MODS then
			n = n + 1
			local parts = {}
			for _, s in ipairs(m.sites or {}) do
				if s.ms >= 0.01 then parts[#parts + 1] = string.format("%s %s ms x%s", s.site, fmt(s.ms), fmt(s.calls, 0)) end
			end
			lines[#lines + 1] = string.format("profiler:   %s (%s): %s ms a frame, slowest %s, %s calls, %s FPS; %s",
				name_of and name_of(m.id) or m.id, m.id, fmt(m.ms), fmt(m.peak_ms), fmt(m.calls, 0), fmt(M.fps_cost(result.frame_ms, m.ms), 1),
				#parts > 0 and table.concat(parts, ", ") or "no detail")
		end
	end
	if n == 0 then lines[#lines + 1] = "profiler:   no mod took " .. M.LOG_MIN_MS .. " ms a frame" end
	return lines
end

local function set(id, value)
	M.values[id] = value
	pcall(obsidian.storage.set, KEY .. id, value)
end

local function name_of(id)
	if id == "obsidian.loader" then return "Obsidian Loader" end
	local known = M.names[id]
	if known then return known end
	local info = obsidian.info and obsidian.info(id)
	local name = type(info) == "table" and type(info.name) == "string" and info.name ~= "" and info.name or nil
	if not name then name = (id:gsub("[._%-]+", " "):gsub("(%a)(%w*)", function(a, b) return a:upper() .. b end)) end
	M.names[id] = name
	return name
end

-- Starts or stops the loader's measuring to match whether the panel can show at all.
local function measure(on)
	local p = M.loader
	if not p or M.measuring == on then return end
	M.measuring = on
	pcall(on and p.start or p.stop)
	if on then
		M.next_log = M.clock + M.LOG_EVERY
		obsidian.log("profiler: measuring; a report every " .. M.LOG_EVERY .. " s while the panel is not hidden")
	else
		M.next_log = nil
		obsidian.log("profiler: stopped")
	end
end

-- The width of a text in the kit's units, kept: measuring asks the engine.
local function width(kit, s, size)
	local key = size .. "\0" .. s
	local w = M.widths[key]
	if not w then
		w = kit:measure(s, { font = "ui", size = size }) or 0
		M.widths[key] = w
	end
	return w
end

-- The columns: title, the widest value it shows (to size it), alignment, and the text of a row.
local function columns(detailed)
	local cols = {
		{ "ms", "000.00", function(r) return fmt(r.ms) end },
		{ "FPS cost", "000.0", function(r) return fmt(r.fps, 1) end },
	}
	if detailed then
		cols[#cols + 1] = { "Peak ms", "000.00", function(r) return fmt(r.peak_ms) end }
		cols[#cols + 1] = { "Calls", "00000", function(r) return fmt(r.calls, 0) end }
	end
	return cols
end

local function draw(kit, result, t)
	local size = M.SIZE[M.get("size")] or M.SIZE.medium
	local detailed = M.get("detail") == "detailed"
	local rows = M.rows(result, M.get("rows"), name_of)
	local cols = columns(detailed)
	local line = math.floor(size * 1.45)
	local pad = math.floor(size * 0.7)
	local gap = size * M.GAP_EMS
	local name_w = size * M.NAME_EMS
	local widths = {}
	local width_all = pad * 2 + name_w
	for i, c in ipairs(cols) do
		widths[i] = math.max(width(kit, c[1], size), width(kit, c[2], size))
		width_all = width_all + gap + widths[i]
	end
	local lines = 2 + math.max(#rows, 1) + (detailed and 1 or 0)
	local height = pad * 2 + lines * line

	local w, h = global("Application").resolution()
	local left, bottom = kit:point(0, 0)
	local right, top = kit:point(w, h)
	local corner = M.get("corner")
	local x = corner:find("right") and right - MARGIN - width_all or left + MARGIN
	local y = corner:find("bottom") and bottom + MARGIN or top - MARGIN - height

	kit:layer(LAYER)
	kit:rect(x, y, width_all, height, BACK)
	kit:layer(LAYER + 1)
	local style = { font = "ui", size = size }
	local function text(s, cx, cy, c, align)
		style.color, style.align = c, align
		kit:text(s, cx, cy, style)
	end
	local cy = y + height - pad - size
	if result then
		text("Frame " .. fmt(result.frame_ms) .. " ms, " .. fmt(1000 / math.max(result.frame_ms, 0.01), 0) .. " FPS", x + pad, cy, GOLD, "left")
	else
		text("Measuring...", x + pad, cy, GOLD, "left")
	end
	cy = cy - line
	text("Script", x + pad, cy, GREY, "left")
	local cx = x + pad + name_w
	for i, c in ipairs(cols) do
		cx = cx + gap + widths[i]
		text(c[1], cx, cy, GREY, "right")
	end
	for _, r in ipairs(rows) do
		cy = cy - line
		local hot = result and result.frame_ms > 0 and r.ms / result.frame_ms > 0.1
		local color = hot and RED or WHITE
		-- A name too long for its column scrolls inside it.
		local nw = width(kit, r.name, size)
		local over = nw - name_w
		if over > 0 then
			local shift = M.scroll_offset(over, t, size * M.SCROLL_SPEED, M.SCROLL_REST)
			kit:clip(x + pad, cy - size * 0.4, name_w, line, function()
				text(r.name, x + pad - shift, cy, color, "left")
			end)
		else
			text(r.name, x + pad, cy, color, "left")
		end
		cx = x + pad + name_w
		for i, c in ipairs(cols) do
			cx = cx + gap + widths[i]
			text(c[3](r), cx, cy, color, "right")
		end
	end
	if #rows == 0 then
		cy = cy - line
		text(result and "No script ran" or "", x + pad, cy, GREY, "left")
	end
	if detailed and result then
		cy = cy - line
		text("All scripts " .. fmt(result.total_ms) .. " ms, " .. fmt(M.fps_cost(result.frame_ms, result.total_ms), 1) .. " FPS", x + pad, cy, GREY, "left")
	end
end

-- Once a frame, from the state machine's post_update.
function M.frame(menu)
	if not M.loader or not M.kit then return end
	local dt = global("ENGINE_DT")
	M.clock = M.clock + (type(dt) == "number" and dt > 0 and math.min(dt, 0.25) or 1 / 60)
	local show = M.get("show")
	measure(show ~= "hidden")
	if show == "hidden" then return end
	local got, result = pcall(M.loader.read)
	result = got and result or nil
	if M.next_log and result and M.clock >= M.next_log then
		M.next_log = M.clock + M.LOG_EVERY
		for _, l in ipairs(M.report(result, name_of)) do obsidian.log(l) end
	end
	if menu and menu.held_back then return end -- a screenshot wants the screen clear
	local ui = obsidian.ui
	local ok, cur = pcall(ui.current)
	local screen = ok and type(cur) == "table" and cur.screen or nil
	if not M.wanted(show, screen, menu and menu.shown) then return end
	local script = global("Script")
	local vectors, quaternions, matrices = script.temp_count()
	pcall(draw, M.kit, result, M.clock)
	script.set_temp_count(vectors, quaternions, matrices)
end

-- The page in the F6 window.
local function choices(list, labels)
	local out = {}
	for _, id in ipairs(list) do out[#out + 1] = { id = id, label = labels[id] } end
	return out
end

function M.build(page)
	if not M.loader then
		page:label("The Script Profiler needs a newer Obsidian Launcher.")
		return
	end
	page:choice("Show", { choices = choices(M.SHOW, { hidden = "Hidden", pause = "Pause menu only", always = "Always" }),
		get = function() return M.get("show") end, set = function(v) set("show", v) end, default = M.DEFAULTS.show })
	page:choice("Detail", { choices = choices(M.DETAIL, { basic = "Basic", detailed = "Detailed" }),
		get = function() return M.get("detail") end, set = function(v) set("detail", v) end, default = M.DEFAULTS.detail })
	page:choice("Scripts listed", { choices = { { id = 5, label = "5" }, { id = 10, label = "10" }, { id = 0, label = "All" } },
		get = function() return M.get("rows") end, set = function(v) set("rows", v) end, default = M.DEFAULTS.rows })
	page:header("Style")
	page:choice("Position", { choices = choices(M.CORNER, { top_left = "Top left", top_right = "Top right", bottom_left = "Bottom left", bottom_right = "Bottom right" }),
		get = function() return M.get("corner") end, set = function(v) set("corner", v) end, default = M.DEFAULTS.corner })
	page:choice("Text size", { choices = choices({ "small", "medium", "large" }, { small = "Small", medium = "Medium", large = "Large" }),
		get = function() return M.get("size") end, set = function(v) set("size", v) end, default = M.DEFAULTS.size })
	page:header("About")
	page:label("ms: the time the scripts of a mod take each frame, on average. FPS cost: the frames a second the game would gain without that time.")
	page:label("Detailed adds the slowest frame of the last half second, the calls a frame, and the total of all scripts. Measuring runs only while the panel is not hidden.")
	page:label("While the panel is not hidden, a report goes to the log of Obsidian API every " .. M.LOG_EVERY .. " seconds, with the hooks and parts each mod spends its time in.")
end

-- From main.lua, after the F6 window is installed.
function M.install(menu)
	local p = obsidian.profiler
	if type(p) == "table" and type(p.start) == "function" and type(p.read) == "function" then M.loader = p end
	for id in pairs(M.DEFAULTS) do
		local ok, v = pcall(obsidian.storage.get, KEY .. id)
		if ok and v ~= nil then M.values[id] = v end
	end
	if type(obsidian.ui) == "table" and type(obsidian.ui.canvas) == "function" then
		obsidian.ui.frame(DESIGN_W, DESIGN_H)
		M.kit = obsidian.ui.canvas("profiler", { over_fades = true })
	end
	menu.add("Script Profiler", M.build)
	local wrap = obsidian.wrap or obsidian.hook
	-- The boot script ends every frame with the state machine's post_update, in every state (as the
	-- F6 window draws).
	local function pack(...) return { n = select("#", ...), ... } end
	local failed = false
	local timed = p and p.measure or function(_, fn, ...) return fn(...) end
	wrap("StateMachine", "post_update", function(original, self, ...)
		local r = pack(original(self, ...))
		local boot = global("Boot")
		if type(boot) == "table" and rawget(boot, "state_machine") == self then
			local ok, err = pcall(timed, "profiler: panel", M.frame, menu)
			if not ok and not failed then
				failed = true
				obsidian.log("profiler: " .. tostring(err))
			end
		end
		return unpack(r, 1, r.n)
	end)
end

return M
