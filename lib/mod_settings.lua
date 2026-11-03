-- Mod Settings: a row of the game's pause menu that opens a list of mods, and a page of settings for
-- each, drawn and driven by the game's own Settings screen (MenuScreenOptions), so they look and handle
-- like the game's. A mod asks for its page and adds rows to it; the values are kept for the next launch.
--
-- These are a mod's in-game settings. The options in a mod's obsidian.json are the app's, read with
-- obsidian.settings.get, and stay there.
--
-- Values live in this library's storage. obsidian.storage writes to the mod whose code is running: a
-- change from the menu (this library's code) is written at once, one from a mod's own code waits in
-- `dirty` for this library's frame callback. The menu's hooks are wraps, never gated, so a client
-- mod's page opens in any lobby.
local game = obsidian.module("lib/game")
local ui = obsidian.module("lib/ui")

local M = { pages = {}, order = {} }

local ENTRY = "obsidian_mod_settings"
local TITLE_KEY = "menu_options_title"
local LIST, PAGE = "obsidian_mod_list", "obsidian_mod_page"
local WORDS = {
	en = "Mod Settings", fr = "Paramètres des mods", es = "Ajustes de mods", bp = "Configurações de mods",
}

local SELF = obsidian.caller()
local saved = {}
local dirty = {}

local function key(owner, id) return owner .. "/" .. id end

-- The game writes its menus in capitals, in the texts themselves, so ours are too. Help lines aren't.
local function words()
	local lm = game.global("LocalizationManager")
	return (WORDS[type(lm) == "table" and lm.current_language or "en"] or WORDS.en):upper()
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

local function start_value(page, row)
	local v = saved[key(page.owner, row.id)]
	if v ~= nil and fits(row, v) then row.value = v else row.value = row.default end
end

-- opts: label, info (a line under the rows while it's selected), default, on_change(value).
function Page:toggle(id, opts)
	check_id(id)
	opts = opts or {}
	local row = add(self, { kind = "toggle", id = id, label = opts.label or id, info = opts.info, default = opts.default == true, on_change = opts.on_change })
	start_value(self, row)
	return row.value
end

-- opts.choices: { { id = "...", label = "..." }, ... }; default: one of the ids, else the first.
function Page:choice(id, opts)
	check_id(id)
	opts = opts or {}
	local choices = {}
	for _, c in ipairs(opts.choices or {}) do
		if type(c) == "table" and c.id ~= nil then choices[#choices + 1] = { id = c.id, label = tostring(c.label or c.id) } end
	end
	if #choices == 0 then error("mod_settings: a choice needs choices", 2) end
	local row = { kind = "choice", id = id, label = opts.label or id, info = opts.info, choices = choices, default = choices[1].id, on_change = opts.on_change }
	if fits(row, opts.default) then row.default = opts.default end
	add(self, row)
	start_value(self, row)
	return row.value
end

-- opts: min, max, step (each step is a stop on the row's arrows, 100 at most), default, format(value)
-- for the words shown.
function Page:number(id, opts)
	check_id(id)
	opts = opts or {}
	local min, max, step = tonumber(opts.min) or 0, tonumber(opts.max) or 10, tonumber(opts.step) or 1
	if max < min or step <= 0 or (max - min) / step > 100 then error("mod_settings: a number needs min <= max and at most 100 steps", 2) end
	local row = { kind = "number", id = id, label = opts.label or id, info = opts.info, min = min, max = max, step = step, format = opts.format, on_change = opts.on_change }
	row.default = math.min(math.max(tonumber(opts.default) or min, min), max)
	add(self, row)
	start_value(self, row)
	return row.value
end

-- A row that does something when pressed. Nothing is kept.
function Page:button(label, fn, opts)
	if type(fn) ~= "function" then error("mod_settings: a button needs a function", 2) end
	add(self, { kind = "button", label = tostring(label), info = opts and opts.info, fn = fn })
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
	local k = key(page.owner, row.id)
	if obsidian.caller() == SELF then
		saved[k] = value
		obsidian.storage.set("mod_settings/" .. k, value)
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
	page.title = tostring(title or page.title or owner)
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
		obsidian.storage.set("mod_settings/" .. k, v)
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
	texts[name] = tostring(row.label):upper()
	local out = { name = name }
	if row.info then
		out.info = name .. "_info"
		texts[out.info] = row.info
	end
	if row.kind == "toggle" then
		out.options = { { name = "options_no", value = false }, { name = "options_yes", value = true }, selected_index = row.value and 2 or 1 }
	elseif row.kind == "choice" then
		out.options, out.ignore_loc_option_names = { selected_index = 1 }, true
		for i, c in ipairs(row.choices) do
			out.options[i] = { name = c.label:upper(), value = c.id }
			if c.id == row.value then out.options.selected_index = i end
		end
	elseif row.kind == "number" then
		out.options, out.ignore_loc_option_names = { selected_index = 1 }, true
		local count = math.floor((row.max - row.min) / row.step + 0.5)
		for i = 0, count do
			local v = math.min(row.min + i * row.step, row.max)
			out.options[i + 1] = { name = format(row, v):upper(), value = v }
			if math.abs(v - row.value) < row.step / 2 then out.options.selected_index = i + 1 end
		end
	end
	return out
end

local function open_screen(screen, rows, title)
	screen.user_pad_number = screen.parent.user_pad_number
	screen.options, screen.texts = {}, { [TITLE_KEY] = tostring(title):upper() }
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
			local r = { Options.handle_input(self, input) }
			for n, row in ipairs(self.rows or {}) do
				local o = self.options[n] and self.options[n].options
				if o and o[o.selected_index] then changed(self.page, row, o[o.selected_index].value) end
			end
			return unpack(r)
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

-- The row goes under the game's Settings, and only where a page has rows.
local function add_entry(main)
	if #shown() == 0 or type(main.options) ~= "table" then return end
	local at = #main.options + 1
	for i, o in ipairs(main.options) do
		if o.name == "menu_settings" then at = i + 1 end
	end
	if not screens(main) then return end
	table.insert(main.options, at, { name = ENTRY })
	if (main.selected_option or 1) >= at then main.selected_option = (main.selected_option or 1) + 1 end
end

function M.install()
	saved = {}
	for k, v in pairs(obsidian.storage.all()) do
		local rest = type(k) == "string" and k:match("^mod_settings/(.+)$")
		if rest then saved[rest] = v end
	end
	obsidian.wrap("MenuScreenMain", "on_enter", function(original, self, ...)
		local r = { original(self, ...) }
		local ok, err = pcall(add_entry, self)
		if not ok then obsidian.log("mod_settings: " .. tostring(err)) end
		return unpack(r)
	end)
	obsidian.wrap("MenuScreenMain", "update", function(original, self, ...)
		return ui.with_texts({ [ENTRY] = words() }, original, self, ...)
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
			end
			return yes
		end
		local r = { pcall(original, self, ...) }
		base.was_option_selected = real
		if not r[1] then error(r[2], 0) end
		return unpack(r, 2)
	end)
end

return M
