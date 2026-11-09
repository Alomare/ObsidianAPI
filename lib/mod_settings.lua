-- Mod Settings: a row of the game's pause menu that opens a list of mods, and a page of settings for
-- each, drawn and driven by the game's own Settings screen (MenuScreenOptions), so they look and handle
-- like the game's. A mod asks for its page and adds rows to it; the values are kept for the next launch.
--
-- These are a mod's in-game settings. A row made with `option = true` is instead one of the options in
-- the mod's obsidian.json, under the same id: it starts from the value set in Obsidian, and a change in
-- game is kept as `option/<mod id>/<option id>` until Obsidian takes it into the profile (it does that
-- while the game is closed, and removes the key: core/src/game_options.rs in Obsidian). The pending value wins over the app's at the next
-- launch, so a change made in game isn't lost when Obsidian wasn't open.
--
-- Values live in this library's storage. obsidian.storage writes to the mod whose code is running: a
-- change from the menu (this library's code) is written at once, one from a mod's own code waits in
-- `dirty` for this library's frame callback. The menu's hooks are wraps, never gated, so a client
-- mod's page opens in any lobby.
--
-- Words (a title, label, info or choice label) are a string or a table by language,
-- { en = ..., fr = ..., es = ..., ["pt-BR"] = ... }, read when drawn, since pages are made at boot
-- before the game knows its language.
local game = obsidian.module("lib/game")
local pack = game.pack
local ui = obsidian.module("lib/ui")
local menu = obsidian.module("lib/menu")

-- BINDS: rows can be bound to the mod's options (`option = true`), and words can be tables by language.
local M = { pages = {}, order = {}, BINDS = true }

local ENTRY = "obsidian_mod_settings"
local TITLE_KEY = "menu_options_title"
local LIST, PAGE = "obsidian_mod_list", "obsidian_mod_page"
local WORDS = {
	en = "Mods", fr = "Mods", es = "Mods", bp = "Mods",
}

local SELF = obsidian.caller()
local saved = {}
local dirty = {}

-- Rows of the pause menu that mods add under the Mods row, in the order they asked: { id, owner, label,
-- fn, when, run }. A chosen one closes the pause menu, then its fn runs as its mod, from this library's
-- frame, outside the menu's own input.
M.rows = {}
local chosen = nil -- { row, screen } between the menu's input and the frame

-- The storage key of a row: its own, or the pending value of the mod's option.
local function key(page, row) return (row.option and "option/" or "mod_settings/") .. page.owner .. "/" .. row.id end

-- The game's language codes; Brazilian Portuguese is "bp" there and "pt-BR" in Obsidian.
local function language()
	local lm = game.global("LocalizationManager")
	local code = type(lm) == "table" and lm.current_language or "en"
	return code == "bp" and "pt-BR" or code
end

-- Words as shown: a string, or the table's entry for the game's language, else English.
local function say(w)
	if type(w) ~= "table" then return tostring(w) end
	local s = w[language()] or w.en
	if s == nil then
		for _, v in pairs(w) do return tostring(v) end
	end
	return tostring(s or "")
end

-- The game writes its menus in capitals, in the texts themselves, so ours are too. Help lines aren't.
-- string.upper leaves letters outside ASCII alone: the accented ones of the game's languages are two
-- bytes in UTF-8, the capital 32 below the small one (à to þ, but ÷), and œ.
local function caps(s)
	s = s:upper():gsub("\195([\160-\190])", function(c)
		return c == "\183" and "\195\183" or "\195" .. string.char(c:byte() - 32)
	end)
	return (s:gsub("\197\147", "\197\146"))
end

local function words()
	local lm = game.global("LocalizationManager")
	return caps(WORDS[type(lm) == "table" and lm.current_language or "en"] or WORDS.en)
end

local function check_words(w, what)
	if type(w) == "table" then
		for k, v in pairs(w) do
			if type(k) ~= "string" or type(v) ~= "string" then error("mod_settings: " .. what .. " by language maps codes to strings", 4) end
		end
	end
	return w
end

local Page = {}
Page.__index = Page

local function check_id(id)
	if type(id) ~= "string" or id == "" then error("mod_settings: an id is a non-empty string", 3) end
end

local function add(page, row)
	for i, r in ipairs(page.rows) do
		if r.id ~= nil and r.id == row.id then
			page.rows[i] = row
			return row
		end
	end
	page.rows[#page.rows + 1] = row
	return row
end

-- A stored value, if it still fits the row; else the row's default.
local function fits(row, v)
	if row.kind == "toggle" then return type(v) == "boolean" end
	if row.kind == "number" then return type(v) == "number" and v >= row.min and v <= row.max end
	if row.kind == "choice" then
		for _, c in ipairs(row.choices) do
			if c.id == v then return true end
		end
	end
	return false
end

-- The pending value from a change in game, else for an option row the value set in Obsidian (read
-- while the mod's own code runs, as obsidian.settings.get answers for the running mod).
local function start_value(page, row)
	local v = saved[key(page, row)]
	if v == nil and row.option then
		local ok, s = pcall(obsidian.settings.get, row.id)
		if ok then v = s end
		if v == nil then obsidian.log("mod_settings: " .. page.owner .. "." .. row.id .. " is bound to an option, but obsidian.json has no such option") end
	end
	if v ~= nil and fits(row, v) then row.value = v else row.value = row.default end
end

-- The parts every row with a value has.
local function new_row(kind, id, opts)
	check_id(id)
	return { kind = kind, id = id, option = opts.option == true, label = check_words(opts.label or id, "a label"),
		info = check_words(opts.info, "info"), on_change = opts.on_change }
end

-- opts: label, info (a line under the rows while it's selected), default, on_change(value), option
-- (true: the row is the mod's obsidian.json option with this id).
function Page:toggle(id, opts)
	opts = opts or {}
	local row = new_row("toggle", id, opts)
	row.default = opts.default == true
	add(self, row)
	start_value(self, row)
	return row.value
end

-- opts.choices: { { id = "...", label = "..." }, ... }; default: one of the ids, else the first.
function Page:choice(id, opts)
	opts = opts or {}
	local row = new_row("choice", id, opts)
	row.choices = {}
	for _, c in ipairs(opts.choices or {}) do
		if type(c) == "table" and c.id ~= nil then row.choices[#row.choices + 1] = { id = c.id, label = check_words(c.label or tostring(c.id), "a choice label") } end
	end
	if #row.choices == 0 then error("mod_settings: a choice needs choices", 2) end
	row.default = row.choices[1].id
	if fits(row, opts.default) then row.default = opts.default end
	add(self, row)
	start_value(self, row)
	return row.value
end

-- opts: min, max, step (each step is a stop on the row's arrows, 100 at most), default, format(value)
-- for the words shown.
function Page:number(id, opts)
	opts = opts or {}
	local min, max, step = tonumber(opts.min) or 0, tonumber(opts.max) or 10, tonumber(opts.step) or 1
	if max < min or step <= 0 or (max - min) / step > 100 then error("mod_settings: a number needs min <= max and at most 100 steps", 2) end
	local row = new_row("number", id, opts)
	row.min, row.max, row.step, row.format = min, max, step, opts.format
	row.default = math.min(math.max(tonumber(opts.default) or min, min), max)
	add(self, row)
	start_value(self, row)
	return row.value
end

-- A row that does something when pressed. Nothing is kept.
function Page:button(label, fn, opts)
	if type(fn) ~= "function" then error("mod_settings: a button needs a function", 2) end
	add(self, { kind = "button", label = check_words(label, "a label"), info = check_words(opts and opts.info, "info"), fn = fn })
end

function Page:get(id)
	for _, row in ipairs(self.rows) do
		if row.id == id then return row.value end
	end
	return nil
end

local function changed(page, row, value)
	if row.value == value then return end
	row.value = value
	local k = key(page, row)
	if obsidian.caller() == SELF then
		saved[k] = value
		obsidian.storage.set(k, value)
	else
		dirty[k] = value
	end
	if row.on_change then
		local ok, err = pcall(row.on_change, value)
		if not ok then obsidian.log("mod_settings: " .. page.owner .. "." .. row.id .. ": " .. tostring(err)) end
	end
end

-- Sets a value as the page would; false when there's no such row or the value doesn't fit it.
function Page:set(id, value)
	for _, row in ipairs(self.rows) do
		if row.id == id and row.kind ~= "button" then
			if not fits(row, value) then return false end
			changed(self, row, value)
			return true
		end
	end
	return false
end

-- The calling mod's page, titled for the list of mods. Asking again gives the same page.
function M.page(title)
	local owner = obsidian.caller() or "?"
	local page = M.pages[owner]
	if not page then
		page = setmetatable({ owner = owner, rows = {} }, Page)
		M.pages[owner] = page
		M.order[#M.order + 1] = owner
	end
	page.title = check_words(title, "a title") or page.title or owner
	return page
end

-- Pages that have a row, in the order the mods asked for them.
local function shown()
	local out = {}
	for _, owner in ipairs(M.order) do
		if #M.pages[owner].rows > 0 then out[#out + 1] = M.pages[owner] end
	end
	return out
end

-- From this library's frame callback, where obsidian.storage is this library's.
function M.tick()
	if next(dirty) == nil then return end
	for k, v in pairs(dirty) do
		saved[k] = v
		obsidian.storage.set(k, v)
	end
	dirty = {}
end

-- The game's Settings screen with this library's rows. Each row's words are a text key of our own.

local function format(row, v)
	if row.format then
		local ok, s = pcall(row.format, v)
		if ok and s ~= nil then return tostring(s) end
	end
	if v == math.floor(v) then return tostring(v) end
	return string.format("%.2f", v):gsub("0+$", "")
end

local function game_row(row, n, texts)
	local name = "obsidian_ms_row_" .. n
	texts[name] = caps(say(row.label))
	local out = { name = name }
	if row.info then
		out.info = name .. "_info"
		texts[out.info] = say(row.info)
	end
	if row.kind == "toggle" then
		out.options = { { name = "options_no", value = false }, { name = "options_yes", value = true }, selected_index = row.value and 2 or 1 }
	elseif row.kind == "choice" then
		out.options, out.ignore_loc_option_names = { selected_index = 1 }, true
		for i, c in ipairs(row.choices) do
			out.options[i] = { name = caps(say(c.label)), value = c.id }
			if c.id == row.value then out.options.selected_index = i end
		end
	elseif row.kind == "number" then
		out.options, out.ignore_loc_option_names = { selected_index = 1 }, true
		local count = math.floor((row.max - row.min) / row.step + 0.5)
		for i = 0, count do
			local v = math.min(row.min + i * row.step, row.max)
			out.options[i + 1] = { name = caps(format(row, v)), value = v }
			if math.abs(v - row.value) < row.step / 2 then out.options.selected_index = i + 1 end
		end
	end
	return out
end

local function open_screen(screen, rows, title)
	screen.user_pad_number = screen.parent.user_pad_number
	screen.options, screen.texts = {}, { [TITLE_KEY] = caps(say(title)) }
	for n, row in ipairs(rows) do screen.options[n] = game_row(row, n, screen.texts) end
	screen.rows = rows
	screen.selected_option = 1
	screen.cursor_selection_direction = nil
end

local function make_screen(main, kind)
	local Options = game.global("MenuScreenOptions")
	local screen = Options(main)
	screen.update = function(self, dt, t)
		return ui.with_texts(self.texts or {}, Options.update, self, dt, t)
	end
	if kind == LIST then
		screen.on_enter = function(self)
			local rows = {}
			for _, page in ipairs(shown()) do
				rows[#rows + 1] = { kind = "button", label = page.title, fn = function()
					self:play_sound_accept(nil, self.user_pad_number)
					self.parent:push_menu(PAGE, { page = page })
				end }
			end
			open_screen(self, rows, words())
			for n, row in ipairs(rows) do self.options[n].on_pressed = row.fn end
		end
	else
		screen.on_enter = function(self, args)
			-- Coming back from a screen above, args is that screen: the page stays.
			local page = type(args) == "table" and args.page or self.page
			self.page = page
			open_screen(self, page and page.rows or {}, page and page.title or words())
			for n, row in ipairs(self.rows) do
				if row.kind == "button" then
					self.options[n].on_pressed = function()
						local ok, err = pcall(row.fn)
						if not ok then obsidian.log("mod_settings: " .. page.owner .. " button: " .. tostring(err)) end
					end
				end
			end
		end
		-- The game applies its own rows by name. Ours are read back after its input.
		screen.handle_input = function(self, input)
			local r = pack(Options.handle_input(self, input))
			for n, row in ipairs(self.rows or {}) do
				local o = self.options[n] and self.options[n].options
				if o and o[o.selected_index] then changed(self.page, row, o[o.selected_index].value) end
			end
			return unpack(r, 1, r.n)
		end
	end
	return screen
end

local function screens(main)
	if type(main.states) ~= "table" then return false end
	if not main.states[LIST] then
		main.states[LIST] = make_screen(main, LIST)
		main.states[PAGE] = make_screen(main, PAGE)
	end
	return true
end

local function row_key(row) return "obsidian_pause_row_" .. row.n end

-- The pause rows to show on this pause menu: those whose when(screen) agrees, screen being the menu's
-- state, "game" in a mission and "menu" on the ship.
local function pause_rows(main)
	local out = {}
	for _, row in ipairs(M.rows) do
		local yes = true
		if row.when then
			local ok, v = row.run(row.when, main.state_name)
			yes = ok and v == true
		end
		if yes then out[#out + 1] = row end
	end
	return out
end

local function insert_row(main, at, name)
	table.insert(main.options, at, { name = name })
	if (main.selected_option or 1) >= at then main.selected_option = (main.selected_option or 1) + 1 end
end

-- The Mods row goes under the game's Settings, and only where a page has rows. The mods' own rows go
-- under it, or under Settings without it.
local function add_entry(main)
	if type(main.options) ~= "table" then return end
	local at = #main.options + 1
	for i, o in ipairs(main.options) do
		if o.name == "menu_settings" then at = i + 1 end
	end
	if #shown() > 0 and screens(main) then
		insert_row(main, at, ENTRY)
		at = at + 1
	end
	for _, row in ipairs(pause_rows(main)) do
		insert_row(main, at, row_key(row))
		at = at + 1
	end
end

-- A row of the pause menu, under the Mods row, that closes the pause menu and runs fn() when chosen.
-- label: words, or a table by language. opts.when(screen): true where the row shows, screen being
-- "game" in a mission or "menu" on the ship; without it the row shows on every pause menu. Asking again
-- with the same id replaces the row.
function M.pause_row(id, label, fn, opts)
	check_id(id)
	if type(fn) ~= "function" then error("mod_settings: a pause row needs a function", 2) end
	opts = opts or {}
	local owner = obsidian.caller() or "?"
	local row = { id = id, owner = owner, label = check_words(label, "a label"), fn = fn,
		when = type(opts.when) == "function" and opts.when or nil, run = menu.runner() }
	for i, r in ipairs(M.rows) do
		if r.owner == owner and r.id == id then
			row.n = r.n
			M.rows[i] = row
			return true
		end
	end
	M.next_row = (M.next_row or 0) + 1
	row.n = M.next_row
	M.rows[#M.rows + 1] = row
	return true
end

-- Takes a pause row away.
function M.remove_pause_row(id)
	local owner = obsidian.caller() or "?"
	for i, r in ipairs(M.rows) do
		if r.owner == owner and r.id == id then
			table.remove(M.rows, i)
			return true
		end
	end
	return false
end

-- The words of the rows, as the pause menu writes them.
local function entry_words()
	local texts = { [ENTRY] = words() }
	for _, row in ipairs(M.rows) do texts[row_key(row)] = caps(say(row.label)) end
	return texts
end

local function row_named(name)
	for _, row in ipairs(M.rows) do
		if row_key(row) == name then return row end
	end
	return nil
end

-- From the frame: a chosen pause row closes the menu, as Resume does, then runs.
function M.run_chosen()
	local c = chosen
	if not c then return end
	chosen = nil
	local parent = c.screen and c.screen.parent
	-- A mission keeps one open screen; the ship keeps a stack of them (state_menu.lua:2941), closed all
	-- at once as its Resume does.
	local stack = rawget(_G, "stack")
	local screens = type(parent) == "table" and parent.active_screens
	local on_top = type(screens) == "table" and type(stack) == "table" and not stack.empty(screens) and stack.top(screens) == c.screen
	if type(parent) == "table" and type(parent.pop_menu) == "function" and (parent.active_screen == c.screen or on_top) then
		local ok, err = pcall(parent.pop_menu, parent, on_top or nil)
		if not ok then obsidian.log("mod_settings: closing the pause menu: " .. tostring(err)) end
	end
	local ok, err = c.row.run(c.row.fn)
	if not ok and err ~= "off" then obsidian.log("mod_settings: " .. c.row.owner .. " pause row: " .. tostring(err)) end
end

function M.install()
	saved = {}
	for k, v in pairs(obsidian.storage.all()) do
		if type(k) == "string" and (k:match("^mod_settings/.") or k:match("^option/.")) then saved[k] = v end
	end
	obsidian.wrap("MenuScreenMain", "on_enter", function(original, self, ...)
		local r = pack(original(self, ...))
		local ok, err = pcall(add_entry, self)
		if not ok then obsidian.log("mod_settings: " .. tostring(err)) end
		return unpack(r, 1, r.n)
	end)
	obsidian.wrap("MenuScreenMain", "update", function(original, self, ...)
		return ui.with_texts(entry_words(), original, self, ...)
	end)
	-- Choosing our row: the pause menu asks MenuScreenBase.was_option_selected about itself, and gets
	-- false after our screen opens, so none of its own rows acts.
	obsidian.wrap("MenuScreenMain", "handle_input", function(original, self, ...)
		local base = game.global("MenuScreenBase")
		local real = base and base.was_option_selected
		if type(real) ~= "function" or #(self.state_stack or {}) > 0 then return original(self, ...) end
		base.was_option_selected = function(s, ...)
			local yes = real(s, ...)
			if yes and s == self then
				local o = self.options and self.options[self.selected_option]
				if o and o.name == ENTRY then
					self:play_sound_accept(nil, self.user_pad_number)
					self:push_menu(LIST, {})
					return false
				end
				local row = o and row_named(o.name)
				if row then
					self:play_sound_accept(nil, self.user_pad_number)
					chosen = { row = row, screen = self }
					return false
				end
			end
			return yes
		end
		local r = pack(pcall(original, self, ...))
		base.was_option_selected = real
		if not r[1] then error(r[2], 0) end
		return unpack(r, 2, r.n)
	end)
end

return M
