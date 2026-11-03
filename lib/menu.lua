-- The in-game window that F6 opens: a folder per mod down the left with that mod's pages in it, and the
-- open page on the right. Your pages' functions run as your mod. A session mod's pages show while the
-- lobby is cleared, a client mod's in any lobby.
local game = obsidian.module("lib/game")

-- It draws with obsidian.ui in the game's design space of 1280 by 720, so it follows the screen and the
-- player's ui_scale, and it reads the keyboard and the mouse raw. The mouse's cursor axis shares the
-- gui's origin, the bottom left of the screen: the game's menus test the raw cursor against what they
-- draw, with no flip. On a loader that has this library, obsidian.menu hands its calls here.
--
-- Client mods use it in any lobby, so nothing here waits for the session gate. It runs once a frame from
-- a wrap of the game's state machine, its hooks are wraps too, and the key ("open") asks the loader to
-- leave it alone.
--
-- One obsidian table serves every mod, and the loader knows whose code is running only from what it
-- called last. So a mod's functions here (builds, labels, get, set, actions) go through a small table of
-- this library's, wrapped while that mod's code was running: the loader runs that wrap as that mod, and
-- obsidian.text, obsidian.storage and api.edits see the right mod.

local global = game.global
local wrap = obsidian.wrap or obsidian.hook
local SELF = obsidian.caller()

local IFACE = "obsidian_api_menu"
local MENU_CURSOR = "hud/cursors/menu"
local WINDOW_KEY, FOLDERS_KEY = "menu/window", "menu/closed"
local CUT_MARK = "..."
local FIRST_REPEAT, NEXT_REPEAT = 0.4, 0.08
local CLOSED_STATES = { logos = true, cutscene = true, transition = true }
-- obsidian.ui keeps mods below 876, so the window takes the top of what's left.
local LAYER_BACK, LAYER_MARK, LAYER_TOAST = 862, 866, 872

-- In design units.
local DESIGN_W, DESIGN_H = 1280, 720
local DEFAULT_W, DEFAULT_H, MIN_W, MIN_H = 760, 540, 500, 320
local TITLE_H, NAV_W, NAV_ROW, PAGE_H, ROW_H, FOOT_H = 32, 178, 30, 36, 27, 62
local PAD, INDENT, CUT, GRIP, TRACK_W, HELP_LINES = 14, 20, 9, 16, 5, 2
local SWITCH_W, SWITCH_H, STEPPER_W, STEP_W, BUTTON_W, TOAST_H, FILTER_W = 36, 16, 88, 22, 28, 28, 190
local WHEEL_ROWS, WIDTHS_KEPT, TOAST_GAP, RESET_W, RESET_SIZE, NAV_INDENT = 3, 4096, 16, 24, 12, 12

local NAV_KEYS = {
	up = { "up", "w" }, down = { "down", "s" }, left = { "left", "a" }, right = { "right", "d" },
	select = { "enter", "e" }, back = { "esc", "q" }, filter = { "tab" }, reset = { "r" },
}
-- The key guide at the foot: keycaps, then what they do. An arrow is drawn, a name is written.
local GUIDE = {
	{ keys = { "Enter" }, text = "menu_key_select" },
	{ keys = { "Esc" }, text = "menu_key_back" },
	{ keys = { "up", "down" }, text = "menu_key_move" },
	{ keys = { "left", "right" }, text = "menu_key_change" },
	{ keys = { "Tab" }, text = "menu_key_filter" },
	{ keys = { "R" }, text = "menu_key_reset" },
}
local TYPING_GUIDE = { { keys = { "Enter" }, text = "menu_key_confirm" }, { keys = { "Esc" }, text = "menu_key_cancel" } }
local ARROWS = { up = true, down = true, left = true, right = true }
local REPEATS = { up = true, down = true, left = true, right = true }
local ADJUSTABLE = { number = true, choice = true, toggle = true }

-- Obsidian's default theme.
local GOLD, WHITE, GREY, FAINT, RED, DARK = { 240, 180, 41 }, { 236, 235, 231 }, { 180, 181, 178 }, { 158, 160, 157 }, { 255, 155, 94 }, { 15, 17, 19 }
local PANEL, HEADER, WELL, FIELD = { 41, 44, 48, 250 }, { 54, 57, 62, 255 }, { 28, 30, 33, 200 }, { 21, 23, 25, 255 }
local HOVER, SELECTED, FOCUS, DIVIDER, RESTING = { 255, 255, 255, 13 }, { 255, 255, 255, 20 }, { 240, 180, 41, 40 }, { 255, 255, 255, 26 }, { 255, 255, 255, 46 }

-- Saira for names and Barlow for reading, which the loader ships. This is the one place that picks them.
local TITLE = { font = "ui_heading", size = 21, tracking = 0.5 }
local PAGE = { font = "ui_heading", size = 21 }
local HEADING = { font = "ui_heading", size = 16, tracking = 0.5 }
local FOLDER = { font = "ui_heading", size = 16, tracking = 0.5 }
local BODY = { font = "ui", size = 18 }
local SMALL = { font = "ui", size = 15 }

local M = {
	shown = false, roots = {}, owners = {}, closed = {}, root = nil, folder = nil, nav = true, stack = {}, toasts = {}, keys = {},
	kit = nil, widths = {}, width_count = 0, field = nil, state_name = nil, hits = nil, win = nil, drag = nil, hold = nil,
	cursor = nil, closing = false, frames = 0, toggled = nil, status = {}, names = {}, save = {},
}

local function pack(...) return { n = select("#", ...), ... } end

-- Calls as each mod. A runner is made while its mod's code runs, so the loader takes the wrap as that
-- mod's. A mod that has been switched off gets the wrap skipped, and its runner refuses.
local runners = {}

local logged = {}

-- A log line at most three times per kind, in this library's log whoever called.
local function limited(key, text)
	local n = (logged[key] or 0) + 1
	logged[key] = n
	if n > 3 then return end
	if obsidian.caller() ~= SELF and runners[SELF] then
		runners[SELF].call(obsidian.log, text)
	else
		obsidian.log(text)
	end
end

local function make_runner(owner)
	local r = {}
	function r.call(fn, ...)
		if obsidian.caller() ~= owner then return false, "off" end
		return pcall(fn, ...)
	end
	wrap(r, "call", function(original, ...) return original(...) end)
	return r
end

local function call_as(owner, fn, ...)
	local r = owner and runners[owner]
	if not r then return pcall(fn, ...) end
	return r.call(fn, ...)
end

-- A mod's function, as that mod. An error is a log line and false: a failing row never counts against
-- the mod, as a failing hook would.
local function run(owner, what, fn, ...)
	local r = pack(call_as(owner, fn, ...))
	if not r[1] then
		limited("run " .. tostring(owner) .. " " .. what, "menu: " .. tostring(owner) .. ", " .. what .. ": " .. tostring(r[2]))
		return false, r[2]
	end
	return unpack(r, 1, r.n)
end

-- The window's own words, from this library's locales.
local function word(key)
	if obsidian.caller() == SELF or not runners[SELF] then return obsidian.text(key) end
	local ok, s = runners[SELF].call(obsidian.text, key)
	return ok and s or key
end

local function check_scope()
	local scope = obsidian.scope and obsidian.scope() or "session"
	return scope == "client" or obsidian.session.cleared() == true
end

-- Whether the loader would run a mod's code now: a client mod's always, a session mod's in a cleared
-- lobby. Worked out once a frame.
local function allowed(owner)
	if owner == nil or owner == SELF then return true end
	local known = M.status[owner]
	if known == nil then
		local ok, yes = call_as(owner, check_scope)
		known = ok and yes == true
		M.status[owner] = known
	end
	return known
end

local function language()
	local lm = global("LocalizationManager")
	return type(lm) == "table" and lm.current_language or "en"
end

-- A mod's name from its obsidian.json, in the game's language. A loader from before obsidian.info knows
-- only the id, so the id is written out: "obsidian.trainer" reads "Obsidian Trainer".
local function name_of(owner)
	local key = language() .. "\0" .. owner
	local known = M.names[key]
	if known then return known end
	local info = obsidian.info and obsidian.info(owner)
	local name = type(info) == "table" and type(info.name) == "string" and info.name ~= "" and info.name or nil
	if not name then
		name = (owner:gsub("[._%-]+", " "):gsub("(%a)(%w*)", function(a, b) return a:upper() .. b end))
	end
	M.names[key] = name
	return name
end

local function color(c, alpha)
	return global("Color")(alpha or 255, c[1], c[2], c[3])
end

-- Text for a label that may be a function, so a mod can show live values.
local function text_of(owner, value, what)
	if type(value) == "function" then
		local ok, s = run(owner, what, value)
		return ok and tostring(s) or "?"
	end
	return tostring(value)
end

local Page = {}
Page.__index = Page

local function add_item(page, kind, label, opts)
	local it = opts or {}
	it.kind, it.label = kind, label
	page.items[#page.items + 1] = it
	return it
end

-- A heading over the rows after it.
function Page:header(label) return add_item(self, "header", label) end
-- A line of text.
function Page:label(label, opts) return add_item(self, "label", label, opts) end
-- On or off. opts: get(), set(value), default.
function Page:toggle(label, opts) return add_item(self, "toggle", label, opts) end
-- A number. opts: get(), set(value), min, max, step (Shift takes ten), format, default.
function Page:number(label, opts) return add_item(self, "number", label, opts) end
-- One of opts.choices, a list of { id, label }. opts: get(), set(id), default.
function Page:choice(label, opts) return add_item(self, "choice", label, opts) end

-- A row that calls fn(). A string it returns becomes a toast.
function Page:action(label, fn, opts)
	local it = add_item(self, "action", label, opts)
	it.run = fn
	return it
end

-- A row that asks for a line of text, then calls fn(text). A string it returns becomes a toast. With
-- opts.code, it takes arrows instead: the arrow keys, W A S D and a pad's directions, handed over as
-- words, "up down left".
function Page:input(label, fn, opts)
	local it = add_item(self, "input", label, opts)
	it.run = fn
	return it
end

-- A row that opens a page inside this one. build(page) runs each time it opens.
function Page:page(label, build, opts)
	local it = add_item(self, "page", label, opts)
	it.build = build
	return it
end

-- Builds the page again after the current action, as an action can change what it lists.
function Page:refresh()
	self.dirty = true
end

local function selectable(it)
	return it.kind ~= "header" and it.kind ~= "label"
end

local function rows(frame)
	if not frame.filter or frame.filter == "" then return frame.page.items end
	local want, out = frame.filter:lower(), {}
	for _, it in ipairs(frame.page.items) do
		if selectable(it) and string.find(text_of(it.owner or frame.owner, it.label, "label"):lower(), want, 1, true) then
			out[#out + 1] = it
		end
	end
	return out
end

local function settle(frame, list)
	if #list == 0 then
		frame.selected = 1
		return
	end
	frame.selected = math.max(1, math.min(frame.selected or 1, #list))
	if selectable(list[frame.selected]) then return end
	for i = frame.selected, #list do
		if selectable(list[i]) then
			frame.selected = i
			return
		end
	end
	for i = frame.selected, 1, -1 do
		if selectable(list[i]) then
			frame.selected = i
			return
		end
	end
end

local function build(frame)
	frame.page = setmetatable({ items = {}, dirty = false }, Page)
	local ok, err = run(frame.owner, "build", frame.build, frame.page)
	if not ok then
		frame.page.items = { { kind = "label", label = word("menu_failed") } }
		limited("build", "menu: a page failed: " .. tostring(err))
	end
	settle(frame, rows(frame))
end

local function push(title, the_build, owner)
	local frame = { title = title, build = the_build, owner = owner, selected = 1, top = 1, follow = true }
	build(frame)
	M.stack[#M.stack + 1] = frame
end

-- The pages a player can open now: a session mod's wait for a cleared lobby.
local function listed_roots()
	local out = {}
	for _, root in ipairs(M.roots) do
		if allowed(root.owner) then out[#out + 1] = root end
	end
	return out
end

-- The rows down the left: a folder for each mod with a page listed, in the order the mods added their
-- first page, and the pages under it while it's open.
local function nav_entries()
	local out, by_owner = {}, {}
	for _, root in ipairs(listed_roots()) do
		local list = by_owner[root.owner]
		if not list then
			list = {}
			by_owner[root.owner] = list
		end
		list[#list + 1] = root
	end
	for _, owner in ipairs(M.owners) do
		local list = by_owner[owner]
		if list then
			out[#out + 1] = { folder = owner }
			if not M.closed[owner] then
				for _, root in ipairs(list) do out[#out + 1] = { root = root } end
			end
		end
	end
	return out
end

-- Where the keys are in the list: on a folder, or on the page that's open.
local function cursor_at(entries)
	for i, e in ipairs(entries) do
		if M.folder ~= nil then
			if e.folder == M.folder then return i end
		elseif e.root ~= nil and e.root == M.root then
			return i
		end
	end
	return nil
end

local function empty_page(page)
	page:label(word("menu_empty"))
end

local function open_root(root)
	M.root, M.folder, M.stack = root, nil, {}
	push(text_of(root.owner, root.title, "title"), root.build, root.owner)
end

-- A folder's own view: its pages, to open from there.
local function open_folder(owner)
	M.root, M.folder, M.stack = nil, owner, {}
	push(name_of(owner), function(page)
		for _, root in ipairs(listed_roots()) do
			if root.owner == owner then
				local it = page:page(root.title, root.build)
				it.owner, it.go = root.owner, root
			end
		end
	end, nil)
end

local function open_empty()
	M.root, M.folder, M.stack = nil, nil, {}
	push(word("menu_title"), empty_page, nil)
end

local function go(entry)
	if not entry then return open_empty() end
	if entry.folder then return open_folder(entry.folder) end
	return open_root(entry.root)
end

local function step(direction)
	local entries = nav_entries()
	if #entries == 0 then return end
	local at = cursor_at(entries)
	if not at then return go(entries[direction > 0 and 1 or #entries]) end
	go(entries[(at - 1 + direction) % #entries + 1])
end

-- Opens or closes a folder, kept for the next launch. Closing the folder of the open page moves the keys
-- to the folder.
local function set_closed(owner, closed)
	if (M.closed[owner] == true) == closed then return end
	M.closed[owner] = closed or nil
	M.save.folders = true
	if closed and M.root and M.root.owner == owner then open_folder(owner) end
end

local function users()
	local out = { global("KEYBOARD_MOUSE_USER_NAME") }
	local pads = global("PadManager")
	for _, u in ipairs(pads and pads.users or {}) do out[#out + 1] = u.name end
	return out
end

local function ensure_interfaces()
	local im, pads = global("InputManager"), global("PadManager")
	local keyboard = global("KEYBOARD_MOUSE_USER_NAME")
	if im:has_interface(keyboard, IFACE) then return end
	im:create_controller_interface(keyboard, IFACE, {}, {})
	pads:create_rebindable_interface(IFACE, global("ControllerSettings").pad)
end

-- Every frame while open: nothing can hold focus by priority, and the game takes focus itself.
local function hold_focus()
	local im = global("InputManager")
	for _, u in ipairs(users()) do im:take_focus(u, IFACE) end
end

local function drop_focus()
	local im = global("InputManager")
	for _, u in ipairs(users()) do
		if im:has_interface(u, IFACE) then im:release_focus(u, IFACE) end
	end
end

local function state_name()
	local boot = global("Boot")
	local sm = type(boot) == "table" and boot.state_machine
	if not sm then return nil end
	local ok, name = pcall(sm.get_current_state_name, sm)
	return ok and name or nil
end

local function can_open()
	local name = state_name()
	if not name or CLOSED_STATES[name] then return false end
	local sm = global("Boot").state_machine
	local ok, st = pcall(sm.get_current_state, sm)
	return not (ok and type(st) == "table" and st.text_chat and st.text_chat.active)
end

-- The game's cursors nearly vanish away from the aim, so the window asks for the system arrow, which an
-- empty path gives. The path has to be a string: with none the engine reads through a null and the
-- game crashes, past any pcall. The pause menu's cursor stays set for a call that fails.
local function show_cursor()
	local cursors = global("CursorManager")
	cursors:set_cursor(MENU_CURSOR)
	cursors:set_show_cursor(true)
	cursors:set_clip_cursor(false)
	local ok, err = pcall(global("Window").set_cursor, "")
	if not ok then limited("cursor", "menu: no system cursor: " .. tostring(err)) end
end

local function open_cursor()
	local cursors = global("CursorManager")
	M.cursor = { name = cursors:get_current_cursor(), shown = cursors:is_shown(), state = state_name() }
	show_cursor()
end

-- Every frame while open: the game may hide or swap the cursor behind the window.
local function hold_cursor()
	local cursors = global("CursorManager")
	if not cursors:is_shown() or cursors:get_current_cursor() ~= MENU_CURSOR then show_cursor() end
end

-- Puts back what the state had. A state that came up meanwhile set its own cursor, so only the system
-- arrow has to go.
local function close_cursor()
	local c, cursors = M.cursor, global("CursorManager")
	M.cursor = nil
	if not c then return end
	local same = c.state == state_name()
	local name, shown = c.name, c.shown
	if not same then name, shown = cursors:get_current_cursor(), cursors:is_shown() end
	cursors:set_cursor(name)
	cursors:set_show_cursor(shown)
	if same then cursors:set_clip_cursor(name ~= MENU_CURSOR) end
end

-- Closes the window and gives the input and the cursor back to the game.
function M.close()
	if not M.shown then return end
	M.shown, M.closing, M.nav = false, false, true
	M.field, M.drag, M.hold, M.hits = nil, nil, nil, nil
	M.mouse_x, M.mouse_y = nil, nil
	M.stack = {}
	local ok, err = pcall(drop_focus)
	if not ok then limited("focus", "menu: could not release input: " .. tostring(err)) end
	ok, err = pcall(close_cursor)
	if not ok then limited("cursor back", "menu: could not restore the cursor: " .. tostring(err)) end
end

-- Opens the window where it was left, or on the first page. false during logos, cutscenes, screen
-- changes and while the chat is typing.
function M.open()
	if M.shown then return true end
	if not can_open() then return false end
	local ok, err = pcall(function()
		ensure_interfaces()
		hold_focus()
	end)
	if not ok then
		limited("open", "menu: could not take input: " .. tostring(err))
		pcall(drop_focus)
		return false
	end
	ok, err = pcall(open_cursor)
	if not ok then
		M.cursor = nil
		limited("cursor", "menu: could not show the cursor: " .. tostring(err))
	end
	M.shown, M.nav = true, true
	M.state_name = state_name()
	M.status = {}
	local entries = nav_entries()
	local at = cursor_at(entries)
	if at then
		go(entries[at])
	else
		-- The first page of an open folder, else the first folder.
		local first = nil
		for _, e in ipairs(entries) do
			if e.root and not first then first = e end
		end
		go(first or entries[1])
	end
	return true
end

-- Opens or closes it. A second toggle in the same frame does nothing, so two keys bound to it, such as
-- an older Trainer's beside this library's, don't cancel out.
function M.toggle()
	if M.toggled == M.frames then return end
	M.toggled = M.frames
	if M.shown then M.close() else M.open() end
end

-- Whether the window is open.
function M.is_open()
	return M.shown
end

-- A short message at the top left of the screen, or beside the window while it's open.
function M.toast(text, seconds)
	M.toasts[#M.toasts + 1] = { text = tostring(text), left = tonumber(seconds) or 4 }
end

-- A page in the list down the left, in the folder of the mod that adds it. title: text, or a function
-- that answers it. build(page) runs each time the page opens. opts.icon: one of obsidian.ui.glyphs().
function M.add(title, build, opts)
	if type(build) ~= "function" then return end
	local owner = obsidian.caller() or SELF
	if not runners[owner] then runners[owner] = make_runner(owner) end
	local known = false
	for _, o in ipairs(M.owners) do
		if o == owner then known = true end
	end
	if not known then M.owners[#M.owners + 1] = owner end
	M.roots[#M.roots + 1] = { title = title, build = build, owner = owner, icon = type(opts) == "table" and opts.icon or nil }
end

local function shift_held()
	local kb = global("Keyboard")
	local ok, i = pcall(kb.button_index, "left shift")
	if not ok or not i then return false end
	local ok2, v = pcall(kb.button, i)
	return ok2 and type(v) == "number" and v > 0.5
end

local function write(frame, it, value)
	if it.set then
		local ok, err = run(frame.owner, "set", it.set, value)
		if not ok then M.toast(tostring(err)) end
	end
end

local function step_number(frame, it, direction)
	local ok, value = run(frame.owner, "get", it.get)
	if not ok or type(value) ~= "number" then return end
	local n = value + (it.step or 1) * (shift_held() and 10 or 1) * direction
	if it.min and n < it.min then n = it.min end
	if it.max and n > it.max then n = it.max end
	write(frame, it, n)
end

local function step_choice(frame, it, direction)
	local choices = it.choices or {}
	if #choices == 0 then return end
	local ok, value = run(frame.owner, "get", it.get)
	local at = 1
	for i, c in ipairs(choices) do
		if ok and c.id == value then at = i end
	end
	write(frame, it, choices[(at - 1 + direction) % #choices + 1].id)
end

local function check_enabled(frame, it)
	if not it.enabled then return true end
	local ok, on, why = run(frame.owner, "enabled", it.enabled)
	if ok and on then return true end
	M.toast(why or word("menu_unavailable"))
	return false
end

local function begin_number_entry(frame, it)
	if not global("GuiItems") then return end
	M.field = { text = "", state = {}, max = 16, prompt = text_of(frame.owner, it.label, "label"), numeric = true, item = it,
		done = function(text)
			local n = tonumber(text)
			if not n then return end
			if it.min and n < it.min then n = it.min end
			if it.max and n > it.max then n = it.max end
			write(frame, it, n)
		end }
end

local function begin_text_entry(frame, it)
	if not global("GuiItems") then return end
	M.field = { text = "", state = {}, max = 48, prompt = text_of(frame.owner, it.label, "label"), item = it,
		code = it.code == true or nil, arrows = {},
		done = function(text)
			local ok, result = run(frame.owner, "input", it.run, text)
			if not ok then
				M.toast(tostring(result))
			elseif type(result) == "string" then
				M.toast(result)
			end
		end }
end

local function begin_filter(frame)
	if not global("GuiItems") then return end
	M.field = { text = frame.filter or "", state = {}, max = 24, prompt = word("menu_filter"),
		change = function(text)
			frame.filter = text
			frame.selected, frame.top, frame.follow = 1, 1, true
			settle(frame, rows(frame))
		end,
		done = function() end }
end

local function activate(frame, it)
	if not check_enabled(frame, it) then return end
	if it.kind == "toggle" then
		local ok, value = run(frame.owner, "get", it.get)
		if ok then write(frame, it, not value) end
	elseif it.kind == "number" then
		begin_number_entry(frame, it)
	elseif it.kind == "input" then
		begin_text_entry(frame, it)
	elseif it.kind == "choice" then
		step_choice(frame, it, 1)
	elseif it.kind == "action" then
		local ok, result = run(frame.owner, "action", it.run)
		if not ok then
			M.toast(tostring(result))
		elseif type(result) == "string" then
			M.toast(result)
		end
	elseif it.kind == "page" then
		if it.go then
			-- A page in a folder's view: the same as choosing it in the list.
			set_closed(it.go.owner, false)
			open_root(it.go)
			M.nav = false
		else
			push(text_of(it.owner or frame.owner, it.label, "label"), it.build, it.owner or frame.owner)
		end
		return
	end
	if frame.page.dirty then build(frame) end
end

-- A row's way back to where it started: a default the window writes, or a reset of its own.
local function resettable(it)
	return it.default ~= nil or it.reset ~= nil
end

local function same(a, b)
	if type(a) == "number" and type(b) == "number" then return math.abs(a - b) < 1e-6 end
	return a == b
end

local function changed(frame, it)
	if it.changed then
		local ok, value = run(frame.owner, "changed", it.changed)
		return ok and value and true or false
	end
	if it.default == nil then return it.reset ~= nil end
	local ok, value = run(frame.owner, "get", it.get)
	return ok and not same(value, it.default)
end

local function reset_row(frame, it)
	if not (resettable(it) and changed(frame, it) and check_enabled(frame, it)) then return end
	if it.reset then
		local ok, err = run(frame.owner, "reset", it.reset)
		if not ok then M.toast(tostring(err)) end
	else
		write(frame, it, it.default)
	end
end

local function adjust(frame, it, direction)
	if not check_enabled(frame, it) then return end
	if it.kind == "number" then
		step_number(frame, it, direction)
	elseif it.kind == "choice" then
		step_choice(frame, it, direction)
	elseif it.kind == "toggle" then
		activate(frame, it)
	end
end

local function move(frame, list, direction)
	if #list == 0 then return end
	local i = frame.selected
	for _ = 1, #list do
		i = (i - 1 + direction) % #list + 1
		if selectable(list[i]) then
			frame.selected, frame.follow = i, true
			return
		end
	end
end

local function read_key(name, dt)
	local st = M.keys[name]
	local kb = global("Keyboard")
	if not st then
		st = { index = {}, wait = 0 }
		for _, key in ipairs(NAV_KEYS[name]) do
			local ok, i = pcall(kb.button_index, key)
			if ok and i then st.index[#st.index + 1] = i end
		end
		M.keys[name] = st
	end
	local pressed, held = false, false
	for _, i in ipairs(st.index) do
		pressed = pressed or kb.pressed(i) == true
		local level = kb.button(i)
		held = held or (type(level) == "number" and level > 0.5)
	end
	if pressed then
		st.wait = FIRST_REPEAT
		return true
	end
	if held and REPEATS[name] then
		st.wait = st.wait - dt
		if st.wait <= 0 then
			st.wait = NEXT_REPEAT
			return true
		end
	end
	return false
end

local function read_nav(dt)
	local ev = {}
	for name in pairs(NAV_KEYS) do ev[name] = read_key(name, dt) end
	local pads = global("PadManager")
	for i = 1, #(pads and pads.users or {}) do
		local ok, d = pcall(pads.get_inputs, pads, IFACE, i)
		if ok and type(d) == "table" then
			for name in pairs(NAV_KEYS) do
				if d[name] then ev[name] = true end
			end
		end
	end
	return ev
end

-- A code field (Page:input with opts.code): the arrow keys, W A S D and a pad's directions add arrows,
-- Backspace takes the last off, and Enter hands them over as words, "up down left". Letters typed are
-- dropped: the directions come from the window's own keys, so W isn't counted twice.
local CODE_MAX, DIRECTIONS = 10, { "up", "down", "left", "right" }

local function read_code_field(f)
	f.state.marker = 0
	local _, _, finished, cancelled = global("GuiItems").InputField.do_input("", f.state, 1)
	local ev = read_nav(0)
	for _, dir in ipairs(DIRECTIONS) do
		if ev[dir] and #f.arrows < CODE_MAX then f.arrows[#f.arrows + 1] = dir end
	end
	local kb = global("Keyboard")
	local ok, i = pcall(kb.button_index, "backspace")
	if ok and i and kb.pressed(i) == true then table.remove(f.arrows) end
	f.text = table.concat(f.arrows, " ")
	if finished then
		M.field = nil
		if not cancelled then f.done(f.text) end
	end
end

local function read_field()
	local f = M.field
	if f.code then return read_code_field(f) end
	local before = f.text
	local text, _, finished, cancelled = global("GuiItems").InputField.do_input(f.text, f.state, f.max)
	f.text = text
	if f.numeric then
		f.text = f.text:gsub("[^%d%.%-]", "")
		if type(f.state.marker) == "number" and f.state.marker > #f.text then f.state.marker = #f.text end
	end
	if f.change and f.text ~= before then f.change(f.text) end
	if finished then
		M.field = nil
		if not cancelled then f.done(f.text) end
	end
end

-- From the top of a page the keys go to the list, and a click, whose button is still down, closes the
-- window through its own close.
local function go_back(frame, close)
	if frame.filter and frame.filter ~= "" then
		frame.filter = nil
		settle(frame, rows(frame))
	elseif #M.stack > 1 then
		table.remove(M.stack)
		build(M.stack[#M.stack])
	elseif close then
		close()
	elseif not M.nav then
		M.nav = true
	else
		M.close()
	end
end

-- With the keys on the list, the page beside it follows. On a folder, Enter opens or closes it, right
-- opens it and then goes to its first page, and left closes it. On a page, left goes up to its folder.
local function handle_nav(ev)
	local entries = nav_entries()
	local at = cursor_at(entries)
	local here = at and entries[at]
	if ev.back then
		M.close()
	elseif ev.up then
		step(-1)
	elseif ev.down then
		step(1)
	elseif ev.filter then
		M.nav = false
		begin_filter(M.stack[#M.stack])
	elseif here and here.folder then
		if ev.select then
			set_closed(here.folder, not M.closed[here.folder])
		elseif ev.right then
			if M.closed[here.folder] then set_closed(here.folder, false) else step(1) end
		elseif ev.left then
			set_closed(here.folder, true)
		end
	elseif ev.select or ev.right then
		M.nav = false
	elseif ev.left and here and here.root then
		open_folder(here.root.owner)
	end
end

local function handle(ev)
	if M.nav then return handle_nav(ev) end
	local frame = M.stack[#M.stack]
	local list = rows(frame)
	settle(frame, list)
	local it = list[frame.selected]
	if ev.back then
		go_back(frame)
	elseif ev.up then
		move(frame, list, -1)
	elseif ev.down then
		move(frame, list, 1)
	elseif ev.filter then
		begin_filter(frame)
	elseif ev.reset then
		if it and selectable(it) then reset_row(frame, it) end
	elseif ev.left and #M.stack == 1 and not (it and ADJUSTABLE[it.kind]) then
		M.nav = true
	elseif it and selectable(it) then
		if ev.select then
			activate(frame, it)
		elseif ev.left then
			adjust(frame, it, -1)
		elseif ev.right then
			adjust(frame, it, 1)
		end
	end
end

-- What a row shows on its right: a control's kind, and its value.
local function control_of(frame, it)
	if it.kind == "action" then return "run" end
	if it.kind == "input" then return "input" end
	if it.kind == "page" then return "open" end
	if it.kind == "label" or it.kind == "header" then return nil end
	local ok, value = run(frame.owner, "get", it.get)
	if not ok then return "error" end
	if it.kind == "toggle" then return "switch", value and true or false end
	if it.kind == "number" then
		if type(value) ~= "number" then return "stepper", "-" end
		return "stepper", string.format(it.format or "%g", value)
	end
	for _, c in ipairs(it.choices or {}) do
		if c.id == value then return "stepper", tostring(c.label) end
	end
	return "stepper", tostring(value)
end

local function put(s, x, y, style, c, align)
	style.color, style.align = c, align
	M.kit:text(s, x, y, style)
end

-- The baseline that centers a line of text in a band.
local function mid(y, h, style)
	return y + (h - style.size * 0.7) / 2
end

local function width_of(s, style)
	local key = style.font .. style.size .. "/" .. (style.tracking or 0) .. "\0" .. s
	local w = M.widths[key]
	if not w then
		w = M.kit:measure(s, style)
		if M.width_count >= WIDTHS_KEPT then M.widths, M.width_count = {}, 0 end
		-- Nothing can be measured until the gui exists, and a width of 0 would stick.
		if w > 0 then M.widths[key], M.width_count = w, M.width_count + 1 end
	end
	return w
end

-- Cut to a width, by measure: the game's fonts aren't monospaced. Their ~ is missing, so dots mark it.
local function fit(s, width, style)
	if width_of(s, style) <= width then return s end
	local chars = {}
	for ch in s:gmatch("[%z\1-\127\192-\255][\128-\191]*") do chars[#chars + 1] = ch end
	local low, high = 0, #chars
	while low < high do
		local at = math.floor((low + high + 1) / 2)
		if width_of(table.concat(chars, "", 1, at) .. CUT_MARK, style) <= width then low = at else high = at - 1 end
	end
	return table.concat(chars, "", 1, low) .. CUT_MARK
end

local function wrap_text(text, width, style)
	local lines, line = {}, ""
	for w in text:gmatch("%S+") do
		if line == "" then
			line = w
		elseif width_of(line .. " " .. w, style) <= width then
			line = line .. " " .. w
		else
			lines[#lines + 1] = line
			line = w
		end
	end
	if line ~= "" then lines[#lines + 1] = line end
	return lines
end

local function inside(area, x, y)
	return area ~= nil and x >= area.x and x < area.x + area.w and y >= area.y and y < area.y + area.h
end

-- What the screen shows, in the kit's units.
local function visible()
	local w, h = global("Application").resolution()
	local left, bottom = M.kit:point(0, 0)
	local right, top = M.kit:point(w, h)
	return left, bottom, right, top
end

-- The window as the player left it, or near the top left corner on first use. Always on screen.
local function place_window()
	local left, bottom, right, top = visible()
	local win = M.win
	if not win then
		local saved = {}
		for n in tostring(obsidian.storage.get(WINDOW_KEY) or ""):gmatch("%S+") do saved[#saved + 1] = tonumber(n) end
		win = { x = saved[1] or left + 40, top = saved[2] or top - 40, w = saved[3] or DEFAULT_W, h = saved[4] or DEFAULT_H }
		M.win = win
	end
	win.w = math.max(MIN_W, math.min(win.w, right - left))
	win.h = math.max(MIN_H, math.min(win.h, top - bottom))
	win.x = math.max(left, math.min(win.x, right - win.w))
	win.top = math.max(bottom + win.h, math.min(win.top, top))
	return win
end

-- A triangle pointing `dir`, centred on cx, cy, `r` from the middle to the tip. y runs up.
local function arrow_points(dir, cx, cy, r)
	if dir == "up" then return { cx - r, cy - r / 2, cx + r, cy - r / 2, cx, cy + r } end
	if dir == "down" then return { cx - r, cy + r / 2, cx, cy - r, cx + r, cy + r / 2 } end
	if dir == "left" then return { cx + r / 2, cy - r, cx + r / 2, cy + r, cx - r, cy } end
	return { cx - r / 2, cy - r, cx + r, cy, cx - r / 2, cy + r }
end

-- The title bar: the name of the mod whose page is open, or Obsidian on a folder and with no page.
local function draw_title(win, mx, my)
	local kit, hits = M.kit, M.hits
	local x, top, w = win.x, win.top, win.w
	local y = top - TITLE_H
	kit:layer(LAYER_BACK + 1)
	kit:panel({ x, y, w, TITLE_H, cut = CUT, corners = "tl", fill = HEADER })
	kit:layer(LAYER_MARK)
	kit:rect(x + CUT, top - 2, w - CUT, 2, GOLD)
	kit:glyph("shield", x + 13, y + 7, 17, GOLD)
	hits.title = { x = x, y = y, w = w, h = TITLE_H }

	local function button(area_x, area_w, glyph, label)
		local area = { x = area_x, y = y, w = area_w, h = TITLE_H }
		local over = inside(area, mx, my)
		kit:layer(LAYER_MARK)
		if over then kit:rect(area_x, y, area_w, TITLE_H - 2, HOVER) end
		local c = over and GOLD or GREY
		kit:layer(LAYER_MARK + 1)
		kit:glyph(glyph, area_x + 11, y + (TITLE_H - 12) / 2, 12, c)
		if label then put(label, area_x + 30, mid(y, TITLE_H, SMALL), SMALL, c) end
		return area
	end
	hits.close = button(x + w - TITLE_H, TITLE_H, "close")
	local frame = M.stack[#M.stack]
	local filter = word("menu_filter")
	if frame.filter and frame.filter ~= "" then filter = fit(filter .. ": " .. frame.filter, FILTER_W, SMALL) end
	local filter_w = width_of(filter, SMALL) + 42
	hits.filter = button(x + w - TITLE_H - filter_w, filter_w, "search", filter)
	local title = M.root and name_of(M.root.owner) or word("menu_title")
	kit:layer(LAYER_MARK)
	put(fit(title, w - TITLE_H - filter_w - 46, TITLE), x + 38, mid(y, TITLE_H, TITLE), TITLE, WHITE)
end

local function draw_nav(win, bottom, mx, my)
	local kit, hits = M.kit, M.hits
	local x, top = win.x, win.top - TITLE_H
	kit:layer(LAYER_BACK + 1)
	kit:rect(x, bottom, NAV_W, top - bottom, WELL)
	local entries = nav_entries()
	local at = cursor_at(entries)
	local row_h = math.min(NAV_ROW, math.floor((top - bottom - 8) / math.max(1, #entries)))
	hits.nav = {}
	for i, e in ipairs(entries) do
		local y = top - 6 - i * row_h
		local area = { x = x, y = y, w = NAV_W, h = row_h, root = e.root, folder = e.folder }
		hits.nav[i] = area
		local on = i == at
		kit:layer(LAYER_BACK + 2)
		if on then
			kit:rect(x, y, NAV_W, row_h, M.nav and FOCUS or SELECTED)
		elseif inside(area, mx, my) then
			kit:rect(x, y, NAV_W, row_h, HOVER)
		end
		kit:layer(LAYER_MARK)
		if on then kit:rect(x, y, 3, row_h, GOLD) end
		if e.folder then
			kit:poly(arrow_points(M.closed[e.folder] and "right" or "down", x + 18, y + row_h / 2, 4), on and GOLD or FAINT)
			put(fit(name_of(e.folder), NAV_W - 40, FOLDER), x + 30, mid(y, row_h, FOLDER), FOLDER, on and WHITE or GREY)
		else
			local left = x + NAV_INDENT
			kit:glyph(e.root.icon or "page", left + 14, y + (row_h - 15) / 2, 15, on and GOLD or GREY)
			put(fit(text_of(e.root.owner, e.root.title, "title"), NAV_W - 50 - NAV_INDENT, BODY), left + 39, mid(y, row_h, BODY), BODY, on and WHITE or GREY)
		end
	end
end

local function draw_switch(right, y, on)
	local kit, inset = M.kit, 3
	local knob = SWITCH_W / 2 - inset
	kit:layer(LAYER_MARK)
	kit:rect(right - SWITCH_W, y, SWITCH_W, SWITCH_H, on and GOLD or FIELD)
	kit:layer(LAYER_MARK + 1)
	kit:rect(on and right - inset - knob or right - SWITCH_W + inset, y + inset, knob, SWITCH_H - inset * 2, on and DARK or GREY)
end

local function draw_stepper(right, y, row, value, mx, my)
	local kit = M.kit
	local w = math.max(width_of(value, BODY) + STEP_W * 2 + 10, STEPPER_W)
	local left = right - w
	kit:layer(LAYER_MARK)
	kit:panel({ left, y + 3, w, ROW_H - 6, cut = 4, corners = "br", fill = FIELD })
	row.minus = { x = left, y = y, w = STEP_W, h = ROW_H }
	row.plus = { x = right - STEP_W, y = y, w = STEP_W, h = ROW_H }
	kit:layer(LAYER_MARK + 1)
	kit:glyph("back", left + 5, y + (ROW_H - 11) / 2, 11, inside(row.minus, mx, my) and GOLD or GREY)
	kit:glyph("forward", right - STEP_W + 5, y + (ROW_H - 11) / 2, 11, inside(row.plus, mx, my) and GOLD or GREY)
	put(value, left + w / 2, mid(y, ROW_H, BODY), BODY, WHITE, "center")
	return w
end

local function draw_button(right, y, over)
	local kit = M.kit
	kit:layer(LAYER_MARK)
	kit:panel({ right - BUTTON_W, y + 4, BUTTON_W, ROW_H - 8, cut = 4, corners = "br", fill = over and GOLD or HEADER })
	kit:layer(LAYER_MARK + 1)
	kit:glyph("run", right - BUTTON_W + 9, y + (ROW_H - 10) / 2, 10, over and DARK or WHITE)
	return BUTTON_W
end

-- Draws what a row shows on its right, and answers how wide that is.
local function draw_control(frame, row, right, mx, my, lit)
	local kit, y, it = M.kit, row.y, row.it
	local control, value = control_of(frame, it)
	if control == "switch" then
		draw_switch(right, y + (ROW_H - SWITCH_H) / 2, value)
		return SWITCH_W
	elseif control == "stepper" then
		return draw_stepper(right, y, row, value, mx, my)
	elseif control == "run" then
		return draw_button(right, y, lit)
	elseif control == "open" or control == "input" then
		kit:layer(LAYER_MARK)
		kit:glyph(control == "open" and "forward" or "edit", right - 13, y + (ROW_H - 12) / 2, 12, lit and GOLD or GREY)
		return 13
	elseif control == "error" then
		kit:layer(LAYER_MARK)
		put("?", right - 8, mid(y, ROW_H, BODY), BODY, RED)
		return 8
	end
	return 0
end

-- Always there on a row that has a way back, so the column reads as one, and lit once there's something
-- to go back from.
local function draw_reset(frame, row, right, mx, my)
	if not resettable(row.it) then return end
	row.reset = { x = right - RESET_W, y = row.y, w = RESET_W, h = ROW_H }
	local c = RESTING
	if changed(frame, row.it) then c = inside(row.reset, mx, my) and GOLD or WHITE end
	M.kit:layer(LAYER_MARK)
	M.kit:glyph("reset", right - RESET_SIZE, row.y + (ROW_H - RESET_SIZE) / 2, RESET_SIZE, c)
end

local function draw_scroll(frame, list, shown, right, top, mx, my)
	if #list <= shown then return end
	local kit, track_h = M.kit, shown * ROW_H
	local track_x, track_y = right - TRACK_W - 4, top - track_h
	local thumb = math.max(ROW_H, math.floor(track_h * shown / #list))
	local span = #list - shown
	local thumb_y = track_y + track_h - thumb - math.floor((track_h - thumb) * (frame.top - 1) / span)
	M.hits.track = { x = track_x - 3, y = track_y, w = TRACK_W + 6, h = track_h, thumb = thumb, span = span }
	local lit = inside(M.hits.track, mx, my) or (M.drag and M.drag.kind == "scroll")
	kit:layer(LAYER_BACK + 2)
	kit:rect(track_x, track_y, TRACK_W, track_h, HOVER)
	kit:layer(LAYER_MARK)
	kit:rect(track_x, thumb_y, TRACK_W, thumb, lit and GOLD or GREY)
end

local KEYCAP_H = 17

local function keycap_w(key)
	if ARROWS[key] then return KEYCAP_H end
	return math.max(width_of(key, SMALL) + 10, KEYCAP_H)
end

-- A keycap at x, y: a box with the key's name, or an arrow for an arrow key. Answers its width.
local function keycap(x, y, key)
	local kit, w = M.kit, keycap_w(key)
	kit:layer(LAYER_MARK)
	kit:panel({ x, y, w, KEYCAP_H, cut = 3, corners = "br", fill = HEADER })
	kit:layer(LAYER_MARK + 1)
	if ARROWS[key] then
		kit:poly(arrow_points(key, x + w / 2, y + KEYCAP_H / 2, 4), WHITE)
	else
		put(key, x + w / 2, mid(y, KEYCAP_H, SMALL), SMALL, WHITE, "center")
	end
	return w
end

-- The guide from x, as many entries as fit before `right`. Answers where it stopped.
local function draw_guide(guide, x, y, right)
	for _, entry in ipairs(guide) do
		local label = word(entry.text)
		local need = width_of(label, SMALL) + 3
		for _, key in ipairs(entry.keys) do need = need + keycap_w(key) + 3 end
		if x + need > right then break end
		for _, key in ipairs(entry.keys) do x = x + keycap(x, y, key) + 3 end
		M.kit:layer(LAYER_MARK)
		put(label, x + 2, mid(y, KEYCAP_H, SMALL), SMALL, FAINT)
		x = x + width_of(label, SMALL) + 18
	end
	return x
end

-- What a row being typed into shows on its right: the text so far and a caret. Answers how wide.
local function draw_field(row, right, left)
	local kit = M.kit
	local w = math.max(STEPPER_W, math.min(260, math.floor((right - left) * 0.55)))
	kit:layer(LAYER_MARK)
	kit:panel({ right - w, row.y + 3, w, ROW_H - 6, cut = 4, corners = "br", fill = FIELD })
	kit:rect(right - w, row.y + 3, 2, ROW_H - 6, GOLD)
	kit:layer(LAYER_MARK + 1)
	if M.field.code then
		-- The arrows so far, then the caret.
		local x, cy = right - w + 12, row.y + ROW_H / 2
		for _, dir in ipairs(M.field.arrows) do
			kit:poly(arrow_points(dir, x, cy, 5), GOLD)
			x = x + 14
		end
		put("_", x - 4, mid(row.y, ROW_H, BODY), BODY, GOLD)
		return w
	end
	put(fit(M.field.text .. "_", w - 14, BODY), right - w + 8, mid(row.y, ROW_H, BODY), BODY, GOLD)
	return w
end

local function draw_foot(frame, list, shown, left, right, bottom)
	local kit, hits = M.kit, M.hits
	local foot_y = bottom + FOOT_H
	kit:layer(LAYER_BACK + 2)
	kit:rect(left, foot_y, right - left, 1, DIVIDER)
	local width = right - left - PAD * 2
	local selected = list[frame.selected]
	kit:layer(LAYER_MARK)
	if selected and selected.help then
		local lines = wrap_text(text_of(selected.owner or frame.owner, selected.help, "help"), width, SMALL)
		if #lines > HELP_LINES then lines[HELP_LINES] = fit(lines[HELP_LINES] .. " " .. lines[HELP_LINES + 1], width, SMALL) end
		local y = foot_y - SMALL.size - 5
		for i = 1, math.min(HELP_LINES, #lines) do
			put(lines[i], left + PAD, y, SMALL, GREY)
			y = y - SMALL.size - 1
		end
	end
	local guide_y = bottom + 4
	if M.field and M.field.item then
		-- The row shows what's typed; the foot, the keys that end it.
		draw_guide(TYPING_GUIDE, left + PAD, guide_y, right - CUT - PAD)
	elseif M.field then
		put(fit(M.field.prompt .. ": " .. M.field.text .. "_", width - CUT, SMALL), left + PAD, bottom + 7, SMALL, GOLD)
	else
		local more = #list > shown and string.format("%d/%d", frame.selected, #list) or ""
		local count_w = more ~= "" and width_of(more, SMALL) + 8 or 0
		draw_guide(GUIDE, left + PAD, guide_y, right - CUT - PAD - count_w)
		kit:layer(LAYER_MARK)
		if more ~= "" then put(more, right - CUT - PAD, bottom + 7, SMALL, FAINT, "right") end
	end

	-- The grip that resizes the window, along the folded corner.
	hits.grip = { x = right - GRIP, y = bottom, w = GRIP, h = GRIP }
	local grip = (inside(hits.grip, M.mouse_x or -1, M.mouse_y or -1) or (M.drag and M.drag.kind == "size")) and GOLD or GREY
	kit:layer(LAYER_MARK)
	for row_at = 0, 2 do
		for dot = 0, 2 - row_at do
			kit:rect(right - 6 - dot * 4, bottom + CUT - 3 + row_at * 4, 2, 2, grip)
		end
	end
end

local function any_resettable(list)
	for _, it in ipairs(list) do
		if resettable(it) then return true end
	end
	return false
end

local function draw_rows(frame, list, shown, left, right, top, mx, my)
	local kit, hits = M.kit, M.hits
	local row_right = right - PAD - TRACK_W
	local control_right = any_resettable(list) and row_right - RESET_W or row_right
	local y = top
	for i = frame.top, math.min(#list, frame.top + shown - 1) do
		y = y - ROW_H
		local it = list[i]
		local row = { x = left, y = y, w = right - left - TRACK_W - 8, h = ROW_H, it = it, index = i }
		hits.rows[#hits.rows + 1] = row
		local active = i == frame.selected and selectable(it) and not M.nav
		local over = inside(row, mx, my) and selectable(it)
		kit:layer(LAYER_BACK + 3)
		if active then
			kit:rect(left, y, row.w, ROW_H, SELECTED)
			kit:layer(LAYER_MARK)
			kit:rect(left, y, 3, ROW_H, GOLD)
		elseif over then
			kit:rect(left, y, row.w, ROW_H, HOVER)
		end
		local label = text_of(it.owner or frame.owner, it.label, "label")
		if it.kind == "header" then
			local text = fit(label, row.w - PAD * 2, HEADING)
			kit:layer(LAYER_MARK)
			put(text, left + PAD, y + 7, HEADING, GOLD)
			kit:layer(LAYER_BACK + 3)
			local after = left + PAD + width_of(text, HEADING) + 10
			if after < row_right then kit:rect(after, y + 11, row_right - after, 1, DIVIDER) end
		elseif it.kind == "label" then
			kit:layer(LAYER_MARK)
			put(fit(label, row.w - PAD * 2, BODY), left + PAD, mid(y, ROW_H, BODY), BODY, GREY)
		else
			local typing = M.field and M.field.item == it
			local used = typing and draw_field(row, control_right, left + INDENT) or draw_control(frame, row, control_right, mx, my, active or over)
			draw_reset(frame, row, row_right, mx, my)
			-- An icon of the game's HUD before the words, such as a stratagem's.
			local text_x = left + INDENT
			if it.icon then
				kit:layer(LAYER_MARK)
				local size = ROW_H - 6
				if kit:icon(it.icon, text_x, y + 3, size, size, { 255, 255, 255 }) ~= false then text_x = text_x + size + 7 end
			end
			kit:layer(LAYER_MARK)
			put(fit(label, control_right - used - 12 - text_x, BODY), text_x, mid(y, ROW_H, BODY), BODY, typing and GOLD or WHITE)
		end
	end
end

local function draw_page(win, bottom, mx, my)
	local kit, hits = M.kit, M.hits
	local left, right, top = win.x + NAV_W, win.x + win.w, win.top - TITLE_H
	local frame = M.stack[#M.stack]
	local list = rows(frame)
	settle(frame, list)

	local head_y = top - PAGE_H
	local title_x = left + PAD
	if #M.stack > 1 then
		local area = { x = left, y = head_y, w = PAGE_H, h = PAGE_H }
		hits.back = area
		local over = inside(area, mx, my)
		kit:layer(LAYER_BACK + 2)
		if over then kit:rect(left, head_y, PAGE_H, PAGE_H, HOVER) end
		kit:layer(LAYER_MARK)
		kit:glyph("back", left + 11, head_y + (PAGE_H - 13) / 2, 13, over and GOLD or GREY)
		title_x = left + PAGE_H
	end
	local titles = {}
	for i, f in ipairs(M.stack) do titles[i] = f.title end
	kit:layer(LAYER_MARK)
	put(fit(table.concat(titles, " / "), right - title_x - PAD, PAGE), title_x, mid(head_y, PAGE_H, PAGE), PAGE, WHITE)
	kit:layer(LAYER_BACK + 2)
	kit:rect(left, head_y, right - left, 1, DIVIDER)

	local view = head_y - (bottom + FOOT_H) - 4
	local shown = math.max(1, math.floor(view / ROW_H))
	if frame.follow then
		if frame.selected < frame.top then frame.top = frame.selected end
		if frame.selected >= frame.top + shown then frame.top = frame.selected - shown + 1 end
		frame.follow = false
	end
	frame.top = math.max(1, math.min(frame.top, #list - shown + 1))
	draw_rows(frame, list, shown, left, right, head_y - 2, mx, my)
	draw_scroll(frame, list, shown, right, head_y - 2, mx, my)
	draw_foot(frame, list, shown, left, right, bottom)
end

local function draw_menu()
	local kit = M.kit
	local win = place_window()
	local bottom = win.top - win.h
	local mx, my = M.mouse_x or -1, M.mouse_y or -1
	M.hits = { rows = {}, nav = {} }
	kit:layer(LAYER_BACK)
	kit:panel({ win.x, bottom, win.w, win.h, cut = CUT, corners = "tl br", fill = PANEL })
	draw_title(win, mx, my)
	draw_nav(win, bottom, mx, my)
	draw_page(win, bottom, mx, my)
end

local function draw_toasts(dt)
	for i = #M.toasts, 1, -1 do
		local t = M.toasts[i]
		t.left = t.left - dt
		if t.left <= 0 then table.remove(M.toasts, i) end
	end
	local kit = M.kit
	local left, _, right, top = visible()
	local x, y = left + TOAST_GAP, top - TOAST_GAP - TOAST_H
	-- The window opens in the same corner, and a message shouldn't cover what it's about.
	if M.shown and M.win then x, y = M.win.x + M.win.w + TOAST_GAP, M.win.top - TOAST_H end
	for _, t in ipairs(M.toasts) do
		local s = fit(t.text, right - left - 80, BODY)
		local w = width_of(s, BODY) + 26
		x = math.min(x, right - w - TOAST_GAP)
		kit:opacity(math.min(t.left * 2, 1))
		kit:layer(LAYER_TOAST)
		kit:panel({ x, y, w, TOAST_H, cut = 6, corners = "br", fill = PANEL })
		kit:layer(LAYER_TOAST + 1)
		kit:rect(x, y, 3, TOAST_H, GOLD)
		put(s, x + 13, mid(y, TOAST_H, BODY), BODY, WHITE)
		y = y - TOAST_H - 4
	end
	kit:opacity(1)
end

-- The mouse this frame, or nil where the engine has none: the window then runs on the keyboard alone.
local function read_mouse()
	local mouse = global("Mouse")
	if not mouse or M.no_mouse then return nil end
	local ok, m = pcall(function()
		local ids = M.mouse_ids
		if not ids then
			ids = { cursor = mouse.axis_index("cursor"), wheel = mouse.axis_index("wheel"), left = mouse.button_index("left"), right = mouse.button_index("right") }
			M.mouse_ids = ids
		end
		local at, wheel = mouse.axis(ids.cursor), mouse.axis(ids.wheel)
		return { x = at.x, y = at.y, wheel = wheel.y, held = mouse.button(ids.left) > 0.5, right_held = mouse.button(ids.right) > 0.5,
			left = mouse.pressed(ids.left) == true, right = mouse.pressed(ids.right) == true }
	end)
	if ok then return m end
	M.no_mouse = true
	limited("mouse", "menu: no mouse: " .. tostring(m))
	return nil
end

local function scroll_to(frame, y)
	local track = M.hits.track
	local room = track.h - track.thumb
	if room <= 0 then return end
	local at = (track.y + track.h - track.thumb / 2 - y) / room
	frame.top = 1 + math.floor(math.max(0, math.min(at, 1)) * track.span + 0.5)
end

local function click_row(frame, row, x, y)
	local it = row.it
	if not selectable(it) then return end
	M.nav = false
	frame.selected = row.index
	if inside(row.reset, x, y) then return reset_row(frame, it) end
	local direction = inside(row.minus, x, y) and -1 or (inside(row.plus, x, y) and 1 or nil)
	if direction then
		adjust(frame, it, direction)
		M.hold = { it = it, direction = direction, wait = FIRST_REPEAT }
	else
		activate(frame, it)
	end
end

-- Closing gives the game its input back, so a click that closes the window waits for the button to come
-- up. Otherwise the game gets the rest of the click: a shot in a mission.
local function close_after_click()
	M.closing = true
end

local function press(frame, x, y)
	local hits = M.hits
	if inside(hits.close, x, y) then
		close_after_click()
	elseif inside(hits.back, x, y) then
		go_back(frame)
	elseif inside(hits.filter, x, y) then
		begin_filter(frame)
	elseif inside(hits.grip, x, y) then
		M.drag = { kind = "size", x = x - M.win.w, y = y + M.win.h }
	elseif inside(hits.track, x, y) then
		M.drag = { kind = "scroll" }
		scroll_to(frame, y)
	elseif inside(hits.title, x, y) then
		M.drag = { kind = "move", x = x - M.win.x, y = y - M.win.top }
	else
		for _, area in ipairs(hits.nav) do
			if inside(area, x, y) then
				-- A click on a folder opens or closes it, and leaves the keys where they are.
				if area.folder then return set_closed(area.folder, not M.closed[area.folder]) end
				M.nav = false
				return open_root(area.root)
			end
		end
		for _, row in ipairs(hits.rows) do
			if inside(row, x, y) then return click_row(frame, row, x, y) end
		end
	end
end

local function follow_drag(frame, drag, m)
	if not m.held then
		M.drag = nil
		if drag.kind ~= "scroll" then M.save.window = true end
	elseif drag.kind == "move" then
		M.win.x, M.win.top = m.x - drag.x, m.y - drag.y
	elseif drag.kind == "size" then
		M.win.w, M.win.h = m.x - drag.x, drag.y - m.y
	else
		scroll_to(frame, m.y)
	end
end

local function mouse_input(dt)
	local m = read_mouse()
	if not m then return end
	m.x, m.y = M.kit:point(m.x, m.y)
	local moved = M.mouse_x ~= nil and (m.x ~= M.mouse_x or m.y ~= M.mouse_y)
	M.mouse_x, M.mouse_y = m.x, m.y
	if M.closing then
		if not m.held and not m.right_held then M.close() end
		return
	end
	-- A click elsewhere ends typing, as Enter does.
	if M.field then
		if m.left then
			local field = M.field
			M.field = nil
			field.done(field.text)
		end
		return
	end
	local frame = M.stack[#M.stack]
	if M.drag then return follow_drag(frame, M.drag, m) end
	if M.hold then
		if not m.held then
			M.hold = nil
			return
		end
		M.hold.wait = M.hold.wait - dt
		if M.hold.wait <= 0 then
			M.hold.wait = NEXT_REPEAT
			adjust(frame, M.hold.it, M.hold.direction)
		end
		return
	end
	if not M.hits then return end
	if m.wheel > 0 then
		frame.top = frame.top - WHEEL_ROWS
	elseif m.wheel < 0 then
		frame.top = frame.top + WHEEL_ROWS
	end
	-- Only a moving mouse selects, so a resting cursor doesn't fight the keys.
	if moved then
		for _, row in ipairs(M.hits.rows) do
			if selectable(row.it) and inside(row, m.x, m.y) then
				frame.selected, M.nav = row.index, false
			end
		end
	end
	if m.right then
		go_back(frame, close_after_click)
	elseif m.left then
		press(frame, m.x, m.y)
	end
end

-- The window's place and the closed folders go to this library's storage from the frame, where this
-- library's code is the code running.
local function flush_saves()
	if M.save.window and M.win then
		obsidian.storage.set(WINDOW_KEY, string.format("%.14g %.14g %.14g %.14g", M.win.x, M.win.top, M.win.w, M.win.h))
	end
	if M.save.folders then
		local list = {}
		for owner in pairs(M.closed) do list[#list + 1] = owner end
		table.sort(list)
		obsidian.storage.set(FOLDERS_KEY, table.concat(list, " "))
	end
	M.save = {}
end

-- Once a frame, from the game's state machine: input, then drawing.
function M.frame()
	M.frames = M.frames + 1
	M.status = {}
	if M.shown then
		local name = state_name()
		if name ~= M.state_name then M.close() end
		M.state_name = name
	else
		M.state_name = state_name()
	end
	if not M.kit or (not M.shown and #M.toasts == 0) then return flush_saves() end
	local script = global("Script")
	local vectors, quaternions, matrices = script.temp_count()
	local dt = global("ENGINE_DT") or 0
	if M.shown then
		hold_focus()
		if M.cursor then pcall(hold_cursor) end
		if M.field then
			read_field()
		else
			handle(read_nav(dt))
		end
		if M.shown then mouse_input(dt) end
	end
	if M.shown then
		local frame = M.stack[#M.stack]
		if not allowed(frame.owner or M.folder) then
			M.close()
		else
			draw_menu()
		end
	end
	if #M.toasts > 0 then draw_toasts(dt) end
	script.set_temp_count(vectors, quaternions, matrices)
	flush_saves()
end

local function protected_frame()
	local ok, err = pcall(M.frame)
	if not ok then
		limited("frame", "menu: " .. tostring(err))
		if M.shown then pcall(M.close) end
	end
end

-- From main.lua, while this library starts.
function M.install()
	runners[SELF] = make_runner(SELF)
	for owner in tostring(obsidian.storage.get(FOLDERS_KEY) or ""):gmatch("%S+") do M.closed[owner] = true end
	if type(obsidian.ui) == "table" and type(obsidian.ui.canvas) == "function" then
		obsidian.ui.frame(DESIGN_W, DESIGN_H)
		M.kit = obsidian.ui.canvas("menu", { over_fades = true })
	end
	-- The boot script ends every frame with the state machine's post_update, in every state.
	wrap("StateMachine", "post_update", function(original, self, ...)
		local r = pack(original(self, ...))
		local boot = global("Boot")
		if type(boot) == "table" and rawget(boot, "state_machine") == self then protected_frame() end
		return unpack(r, 1, r.n)
	end)
	-- Hooks may run later than the frame, so a chat opened with the window's select key is refused here
	-- rather than noticed afterwards.
	wrap("TextChat", "start_typing", function(original, self, ...)
		if M.shown then return end
		return original(self, ...)
	end)
	-- The key opens the window once a page is listed, and closes it. The loader before obsidian.keybind's
	-- opts.always gates it as it gates this library.
	obsidian.keybind("open", function()
		if M.shown or #listed_roots() > 0 then M.toggle() end
	end, { always = true })
end

return M
