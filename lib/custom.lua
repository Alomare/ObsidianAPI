-- Custom stratagems: new entries in the game's stratagem list, each made from one of the game's own,
-- its base. A custom stratagem has its own name, words, code, icon, type, numbers and upgrades, and
-- can run a mod's function when it's called down, beside or instead of what the base would drop.
--
-- No other game has it, so on the wire it is always the base, as the LAS-288 Pitchfork and Gyro's
-- Steel Balls do it: the stratagem ids in the game's messages and in the fields it copies to other
-- machines are swapped for the base's as they're written. Other players see and hear the base; the
-- thrower's game does the rest, and what lands is a unit every game has. Those swaps protect the
-- other players, so they hold in any lobby, and they replace the game's functions directly: two of
-- them run for every field read and every message, too often for the protected hook path, and a hook
-- the loader switched off would stop them. In a lobby that isn't cleared, a custom stratagem is its
-- base: its numbers, its call-in, and no mod function.
--
-- The Loadout screen offers it to whoever has its base, by rank, reward or DLC. The save keeps its
-- upgrades under its name, like any stratagem's, and a saved loadout naming a stratagem the game no
-- longer has gets the default in its place (Boot.ensure_loadout), so taking a mod off leaves a save
-- that works.
local game = obsidian.module("lib/game")
local catalog = obsidian.module("lib/catalog")

local M = {}

local defs = {}      -- by name, in the order they were made
local by_id = {}     -- the entry's index in LoadoutSettings.stratagems -> def
local texts = {}     -- game text key -> words, a string or { en = ..., fr = ... }
local order = {}
local installed = {}
-- Defs made before the game has its stratagem list, in the order they came: { def, entry }.
local pending = {}
-- The materials a def's icon_material named and the loader accepted, in the order they came. Every gui
-- that lists hud/hud lists them too, as a stratagem's icon is drawn wherever the game's are.
local art, art_listed = {}, {}

-- The catalog answers unlocked() for a custom stratagem as for its base. It can't load this file, which
-- needs it, so the answer is handed to it here.
function catalog.base_of(name)
	local r = defs[name]
	return r and r.base or name
end

-- How a custom stratagem is unlocked, apart from its base (def.unlock): "base" or nil goes by the base,
-- "free" is open from the start, { rank = n } from that rank on, and "manual" once a mod calls
-- unlock(name). What mods unlock is kept in this library's storage as one list of names, never in the
-- game's save. Storage is the running mod's, so an unlock from a mod's own code waits for this library's
-- frame callback, as Mod Settings' changes do.
local UNLOCKS = { base = true, free = true, manual = true }
local SELF = obsidian.caller and obsidian.caller()
local KEY = "stratagem_unlocks"
local opened = {}
local unsaved = false

for name in tostring(obsidian.storage.get(KEY) or ""):gmatch("[%w_]+") do opened[name] = true end

local function save()
	local names = {}
	for name in pairs(opened) do names[#names + 1] = name end
	table.sort(names)
	obsidian.storage.set(KEY, table.concat(names, ","))
	unsaved = false
end

local function changed()
	if obsidian.caller and obsidian.caller() == SELF then save() else unsaved = true end
end

-- True or false by the stratagem's own unlock, or nil where it goes by the base. xp: the player's, or
-- read from the save when nil.
local function own_unlock(name, xp)
	local r = defs[name]
	local rule = r and r.unlock
	if rule == nil or rule == "base" then return nil end
	if rule == "free" or opened[name] then return true end
	if type(rule) == "table" then
		local ranks = game.global("ProgressionSettings")
		local rank = type(ranks) == "table" and ranks.ranks and ranks.ranks[rule.rank]
		if xp == nil then xp = catalog.xp_and_rewards() end
		return rank ~= nil and type(xp) == "number" and xp >= rank.required_xp
	end
	return false
end
catalog.own_unlock = own_unlock

-- From this library's frame callback, where obsidian.storage is this library's.
function M.tick()
	if unsaved then save() end
end

local ARROWS = { up = true, down = true, left = true, right = true }
local TYPES = { supply = true, offensive = true, defensive = true, special = true }
-- What a def sets through its own fields, so stats can't.
local OWN = { name = true, id = true, description = true, combo = true, icon = true, unit = true, stratagem_type = true,
	stratagem_subtypes = true, attributes = true, upgrades = true, group = true }
-- Messages that carry a stratagem id, and its place among their arguments (lua/generated/network_messages.lua).
local MESSAGES = { rpc_activate_stratagem = 2, rpc_stratagem_info = 3, rpc_give_stratagem = 2 }
-- Game object fields that hold one: the loadout's slots (menu_screen_loadout.lua:617) and a flare's.
local FIELDS = { stratagem_id = true }
for i = 1, 16 do FIELDS["stratagem" .. i .. "_index"] = true end

local LANGUAGES = { en = "en", fr = "fr", es = "es", bp = "pt-BR" }

local function settings()
	local s = game.global("LoadoutSettings")
	if type(s) == "table" and type(s.stratagems) == "table" then return s end
	return nil
end

local function clone(t)
	if type(t) ~= "table" then return t end
	local out = {}
	for k, v in pairs(t) do out[k] = clone(v) end
	return setmetatable(out, getmetatable(t))
end

local function cleared()
	local session = obsidian.session
	return not (session and session.cleared) or session.cleared()
end

-- The id other games know: the base's for a custom stratagem.
local function wire(id)
	local def = by_id[id]
	return def and def.base_id or id
end

local function words(value)
	if type(value) == "string" then return value end
	local lm = game.global("LocalizationManager")
	local lang = LANGUAGES[type(lm) == "table" and lm.current_language or "en"] or "en"
	return value[lang] or value.en
end

-- A level's name from the stratagem's: "Pitchfork" becomes "Pitchfork Mk2", in each language given.
local function level_title(title, n)
	if type(title) == "string" then return title .. " Mk" .. n end
	local out = {}
	for lang, s in pairs(title) do out[lang] = s .. " Mk" .. n end
	return out
end

-- Words: a string, or a table of them by language with English in it.
local function is_words(v)
	if type(v) == "string" then return v ~= "" and #v <= 200 end
	if type(v) ~= "table" or type(v.en) ~= "string" then return false end
	for _, s in pairs(v) do
		if type(s) ~= "string" or #s > 200 then return false end
	end
	return true
end

local function is_list_of_strings(v, max)
	if type(v) ~= "table" or #v > max then return false end
	for _, s in ipairs(v) do
		if type(s) ~= "string" then return false end
	end
	return true
end

-- Plain values only, of the type the base has where it has the field.
local function check_stats(stats, base)
	if stats == nil then return true end
	if type(stats) ~= "table" then return false end
	for k, v in pairs(stats) do
		local kind = type(v)
		if type(k) ~= "string" or OWN[k] or not (kind == "number" or kind == "boolean" or kind == "string") then return false end
		if kind == "number" and (v ~= v or v < 0 or v > 100000) then return false end
		if base[k] ~= nil and type(base[k]) ~= kind then return false end
	end
	return true
end

-- s: the game's settings, or nil before it has them, when only the def itself is checked.
local function check(def, s)
	if type(def) ~= "table" then return "bad_type" end
	if type(def.name) ~= "string" or not def.name:match("^[%w_]+$") or #def.name > 64 then return "bad_name" end
	for _, e in ipairs(s and s.stratagems or {}) do
		if e.name == def.name then return "taken" end
	end
	for _, p in ipairs(pending) do
		if p.def.name == def.name then return "taken" end
	end
	-- A base has to be a stratagem every game has.
	if defs[def.base] then return "not_available" end
	if not is_words(def.title) or (def.description ~= nil and not is_words(def.description)) then return "bad_type" end
	if def.code ~= nil then
		if type(def.code) ~= "table" or #def.code < 1 or #def.code > 10 then return "bad_code" end
		for _, arrow in ipairs(def.code) do
			if not ARROWS[arrow] then return "bad_code" end
		end
	end
	if def.type ~= nil and not TYPES[def.type] then return "bad_type" end
	if def.subtypes ~= nil and not is_list_of_strings(def.subtypes, 8) then return "bad_type" end
	if def.icon ~= nil and type(def.icon) ~= "string" then return "bad_type" end
	if def.icon_material ~= nil and (type(def.icon_material) ~= "string" or def.icon == nil) then return "bad_type" end
	if def.unit ~= nil and type(def.unit) ~= "string" then return "bad_type" end
	if def.attributes ~= nil and type(def.attributes) ~= "table" then return "bad_type" end
	if def.on_activate ~= nil and type(def.on_activate) ~= "function" then return "bad_type" end
	if def.unlock ~= nil and not UNLOCKS[def.unlock] then
		local rank = type(def.unlock) == "table" and def.unlock.rank
		if not (type(rank) == "number" and rank == math.floor(rank) and rank >= 1 and rank <= 100) then return "bad_type" end
	end
	if def.upgrades ~= nil then
		if type(def.upgrades) ~= "table" or #def.upgrades > 6 then return "bad_type" end
		for _, u in ipairs(def.upgrades) do
			if type(u) ~= "table" then return "bad_type" end
			if u.title ~= nil and not is_words(u.title) then return "bad_type" end
			if u.description ~= nil and not is_words(u.description) then return "bad_type" end
			if u.cost ~= nil and not (type(u.cost) == "number" and u.cost >= 0 and u.cost <= 100) then return "out_of_range" end
		end
	end
	return nil
end

-- The game's functions, replaced once, when the first custom stratagem is made. Each does nothing for
-- the game's own stratagems.
local function install_direct()
	local go = game.global("GameObject")
	if not installed.game_object and type(go) == "table" and type(go.set) == "function" and type(go.get) == "function" then
		installed.game_object = true
		-- What this machine set, by object and field: { real id, base id }. Its own reads get the real one.
		local real = setmetatable({}, { __mode = "k" })
		local set, get = go.set, go.get
		go.set = function(self, field, value, ...)
			if FIELDS[field] then
				local mine = real[self]
				local base = by_id[value] and wire(value)
				if base then
					if not mine then
						mine = {}
						real[self] = mine
					end
					mine[field] = { value, base }
					return set(self, field, base, ...)
				elseif mine then
					mine[field] = nil
				end
			end
			return set(self, field, value, ...)
		end
		go.get = function(self, field, ...)
			local v = get(self, field, ...)
			local mine = real[self]
			local m = mine and mine[field]
			if m and v == m[2] then return m[1] end
			return v
		end
	end

	local router = game.global("NetworkRouter")
	if not installed.router and type(router) == "table" and type(router.write_message_params) == "function" and type(router.transmit_to) == "function" then
		installed.router = true
		local write, transmit, to_all, to_others = router.write_message_params, router.transmit_to, router.transmit_to_all, router.transmit_to_all_others
		-- A message to this machine itself keeps the real id.
		local to_self = false
		router.write_message_params = function(self, name, ...)
			local at = MESSAGES[name]
			if not at or to_self then return write(self, name, ...) end
			local n = select("#", ...)
			local args = { ... }
			if by_id[args[at]] then
				args[at] = wire(args[at])
				return write(self, name, unpack(args, 1, n))
			end
			return write(self, name, ...)
		end
		router.transmit_to = function(self, peer, name, ...)
			if MESSAGES[name] and peer == game.global("Network").peer_id() then
				to_self = true
				local ok, err = pcall(transmit, self, peer, name, ...)
				to_self = false
				if not ok then error(err, 0) end
				return
			end
			return transmit(self, peer, name, ...)
		end
		-- Everyone else gets the base and this machine the real one, so one message goes as two.
		if type(to_all) == "function" and type(to_others) == "function" then
			router.transmit_to_all = function(self, name, ...)
				if not MESSAGES[name] then return to_all(self, name, ...) end
				to_others(self, name, ...)
				return self:transmit_to(game.global("Network").peer_id(), name, ...)
			end
		end
	end

	local lm = game.global("LocalizationManager")
	if not installed.texts and type(lm) == "table" and type(lm.string) == "function" then
		installed.texts = true
		local string_of = lm.string
		lm.string = function(self, key, ...)
			local own = texts[key]
			if own ~= nil then return words(own) end
			return string_of(self, key, ...)
		end
	end

	local s = settings()
	if not installed.upgraded and s and type(s.get_upgraded_stratagem) == "function" then
		installed.upgraded = true
		local upgraded = s.get_upgraded_stratagem
		s.get_upgraded_stratagem = function(id, upgrade, ...)
			if by_id[id] and not cleared() then return upgraded(wire(id), upgrade, ...) end
			return upgraded(id, upgrade, ...)
		end
	end
	return installed.game_object and installed.router and installed.texts and installed.upgraded
end

local make

-- The def to make: with an icon from a mod's own material when the loader has that material, else
-- without one, so the base's is used. A gui that lists hud/hud and not the material can't draw the
-- icon, and a name a gui doesn't have is assumed fatal: the material is taken before any gui is made
-- for the icon, in the mod's main chunk, and kept for good.
local function with_art(def)
	if def.icon_material == nil then return def end
	local ui = obsidian.ui
	local ok = type(ui) == "table" and type(ui.art) == "function" and ui.art(def.icon, { path = def.icon_material }) == true
	if ok then
		if not art_listed[def.icon_material] then
			art_listed[def.icon_material] = true
			art[#art + 1] = def.icon_material
		end
		return def
	end
	obsidian.log("custom stratagem " .. def.name .. ": no material " .. def.icon_material .. ", so the base's icon")
	local out = clone(def)
	out.icon, out.icon_material = nil, nil
	return out
end

-- A gui's arguments with the art materials after hud/hud, each once; nil when it doesn't list hud/hud.
local function gui_args(n, args)
	if #art == 0 then return nil end
	local hud, have = false, {}
	for i = 1, n - 1 do
		if args[i] == "material" and type(args[i + 1]) == "string" then
			have[args[i + 1]] = true
			if args[i + 1] == "hud/hud" then hud = true end
		end
	end
	if not hud then return nil end
	local out, k = {}, 0
	for i = 1, n do
		k = k + 1
		out[k] = args[i]
		if args[i] == "hud/hud" and args[i - 1] == "material" then
			for _, m in ipairs(art) do
				if not have[m] then
					have[m] = true
					out[k + 1], out[k + 2] = "material", m
					k = k + 2
				end
			end
		end
	end
	return out, k
end

-- Puts each custom stratagem in list right after its base, in the order they were made. key(item): the
-- name an item is listed under; holds(item, name): whether it is, or holds, that stratagem. Customs
-- whose base isn't in the list stay where they are.
local function beside_bases(list, key, holds)
	if #order == 0 or type(list) ~= "table" then return end
	local moved, after = {}, {}
	for _, r in ipairs(order) do
		local own, base
		for _, item in ipairs(list) do
			if key(item) == r.name then own = item end
			if not base and holds(item, r.base) then base = item end
		end
		if own and base and own ~= base then
			moved[own] = true
			after[base] = after[base] or {}
			after[base][#after[base] + 1] = own
		end
	end
	if next(moved) == nil then return end
	local out = {}
	for _, item in ipairs(list) do
		if not moved[item] then
			out[#out + 1] = item
			for _, own in ipairs(after[item] or {}) do out[#out + 1] = own end
		end
	end
	for i = 1, #out do list[i] = out[i] end
end

local function named(item) return type(item) == "table" and item.name or nil end

local function is_named(item, name) return named(item) == name end

-- A Loadout group: { name, items }, one per stratagem unless the game groups some.
local function group_holds(group, name)
	if type(group) ~= "table" then return false end
	if group.name == name then return true end
	for _, item in ipairs(type(group.items) == "table" and group.items or {}) do
		if named(item) == name then return true end
	end
	return false
end

-- The def's on_activate as a hook of the mod calling define: made now, so it's that mod's even when
-- the stratagem is made later.
local function entry_of(def)
	if not def.on_activate then return nil end
	local fn = def.on_activate
	local entry = { run = function() end }
	obsidian.hook(entry, "run", function(_, ctx) return fn(ctx) end)
	return entry
end

-- Makes the pending defs, once the game has its stratagem list.
local function drain()
	if #pending == 0 then return end
	local s = settings()
	if not s then return end
	local list = pending
	pending = {}
	for _, p in ipairs(list) do
		local why = check(p.def, s)
		local made
		if not why then made, why = make(p.def, p.entry, s) end
		if not made then obsidian.log("custom stratagem " .. p.def.name .. " not made: " .. tostring(why)) end
	end
end

-- The hooks that can go through the loader: paid packs, ranks, the call-in, and a flare's id as it's
-- first copied out. From main.lua, so they're the library's and not the first mod's that makes one.
function M.install()
	if installed.hooks then return end
	installed.hooks = true
	local wrap = obsidian.wrap or obsidian.hook
	-- Each new replicator gets its fields' write functions; a stratagem_id one goes out as the base's.
	wrap("GameObjectFieldsReplicator", "init", function(original, self, ...)
		local r = { original(self, ...) }
		for _, field in ipairs(type(self.fields) == "table" and self.fields or {}) do
			local write = field.write
			if field.name == "stratagem_id" and type(write) == "function" then
				field.write = function(value, ...) return write(wire(value), ...) end
			end
		end
		return unpack(r)
	end)
	-- A paid pack's stratagem stays paid when it's a base.
	wrap("DlcSettings", "is_item_dlc", function(original, name, ...)
		local def = defs[name]
		return original(def and def.base or name, ...)
	end)
	wrap("DlcSettings", "can_use", function(original, name, ...)
		local def = defs[name]
		return original(def and def.base or name, ...)
	end)
	-- Only in a cleared lobby does the Loadout screen offer one: by its own unlock, or to a player who
	-- has its base.
	obsidian.hook("ProgressionSettings", "can_use", function(original, name, kind, xp, ...)
		local def = defs[name]
		if not def then return original(name, kind, xp, ...) end
		local own = own_unlock(name, xp)
		if own ~= nil then return own end
		return original(def.base, kind, xp, ...) or catalog.unlocked(def.base)
	end)
	obsidian.hook("StratagemComponent", "spawn_stratagem_hellpod", function(original, self, peer, pos, dir, id, upgrade, owner, ...)
		local def = by_id[id]
		if def and def.entry then
			local result = def.entry.run({ name = def.name, position = pos, owner = owner, upgrade = upgrade or 0 })
			if result == false then return end
		end
		return original(self, peer, pos, dir, id, upgrade, owner, ...)
	end)
	-- A stratagem defined before the game had its list is made before the save's loadout is read, so a
	-- saved loadout naming it keeps it. A wrap, so it runs in any lobby.
	wrap("Boot", "ensure_loadout", function(original, ...)
		drain()
		return original(...)
	end)
	-- Every gui that lists hud/hud lists the icons' materials too: the game's, through WorldProxy.new_gui,
	-- and the loader's for kit:icon. A wrap, as the icons are there in any lobby.
	for _, make_gui in ipairs({ "create_screen_gui", "create_world_gui" }) do
		wrap("World", make_gui, function(original, world, ...)
			local out, n = gui_args(select("#", ...), { ... })
			if out then return original(world, unpack(out, 1, n)) end
			return original(world, ...)
		end)
	end
	-- The Arsenal and the Loadout screen list a custom stratagem right after its base, where the game
	-- would put it at the end. Both lists are made in one call and read later, by name.
	obsidian.hook("MenuScreenArmoryUnlocks", "on_enter", function(original, self, ...)
		local r = { original(self, ...) }
		local items = type(self.available_items) == "table" and self.available_items.stratagems
		for _, group in ipairs(type(items) == "table" and type(items.groups) == "table" and items.groups or {}) do
			beside_bases(group.items, named, is_named)
		end
		return unpack(r)
	end)
	obsidian.hook("MenuScreenLoadout", "setup_loadout", function(original, self, slot, ...)
		local r = { original(self, slot, ...) }
		local players = type(self.parent) == "table" and self.parent.players
		local player = type(players) == "table" and players[slot]
		local items = type(player) == "table" and type(player.available_items) == "table" and player.available_items.stratagems
		if type(items) == "table" then beside_bases(items.groups, named, group_holds) end
		return unpack(r)
	end)
	-- The game's functions go in once a custom stratagem is made and they all exist, and the pending ones
	-- are made once the list is there. true stops the calls.
	obsidian.on_frame(function()
		drain()
		if #order == 0 then return false end
		return install_direct() and #pending == 0
	end)
end

-- Makes a custom stratagem. def:
--   name         its key, letters, digits and _ ("mymod_pitchfork"); must be new
--   base         a stratagem of the game's: copied, and what other players see
--   title        its name: a string, or { en = ..., fr = ..., es = ..., ["pt-BR"] = ... }
--   description  words under it; the base's if nil
--   code         the arrows, { "down", "left", "up", ... }, 1 to 10; the base's if nil
--   icon         an icon the HUD has, as a stratagem's icon field; the base's if nil
--   icon_material  with icon: a material the mod ships in the boot bundle, whose sub-material icon is.
--                Every gui listing hud/hud lists it too. The base's icon when the deploy hasn't got it
--   type         "supply", "offensive", "defensive" or "special"; subtypes, a list as the game's
--   unit         what it calls down: a unit every game has; the base's if nil
--   stats        fields of the entry: num_uses, cooldown_time, activation_time, despawn_time, ...
--   attributes   the bars the Loadout screen shows, as the game's attr_ fields
--   upgrades     its levels, Mk2 and on: { title, description, cost, stats, attributes, upgrade_attributes,
--                icon }; the base's, renamed, if nil
--   on_activate  function(ctx) on the thrower's machine when it's called down. ctx: name, position (the
--                game's vector, good for this frame: copy it to keep it), owner (the thrower's unit),
--                upgrade. Answer false to drop nothing.
--   unlock       "base" (with its base, as when nil), "free" (from the start), { rank = n } (from rank n)
--                or "manual" (once api.stratagems.unlock(name) is called)
-- Answers { name, id }, or nil and a reason. Before the game has its stratagem list, as in a mod's
-- main chunk, it answers { name, pending = true } and makes the stratagem once the list is there,
-- before the save's loadout is read. A pending one that can't be made then is logged. The Arsenal and
-- the Loadout screen list a custom stratagem right after its base.
function M.define(def)
	local s = settings()
	local why = check(def, s)
	if why then return nil, why end
	def = with_art(def)
	if not s then
		pending[#pending + 1] = { def = clone(def), entry = entry_of(def) }
		return { name = def.name, pending = true }
	end
	return make(def, entry_of(def), s)
end

make = function(def, entry, s)
	local base, base_id
	for i, e in ipairs(s.stratagems) do
		if e.name == def.base then base, base_id = e, i end
	end
	if not base then return nil, "not_available" end
	if not check_stats(def.stats, base) then return nil, "bad_type" end
	for _, u in ipairs(def.upgrades or {}) do
		if not check_stats(u.stats, base) then return nil, "bad_type" end
	end

	local e = clone(base)
	local name = def.name
	e.name = name
	e.group = nil
	texts[name] = def.title
	if def.description then
		e.description = name .. "_d"
		texts[e.description] = def.description
	end
	if def.code then e.combo = clone(def.code) end
	e.icon = def.icon or base.icon
	e.unit = def.unit or base.unit
	e.stratagem_type = def.type or base.stratagem_type
	if def.subtypes then e.stratagem_subtypes = clone(def.subtypes) end
	if def.attributes then e.attributes = clone(def.attributes) end
	for k, v in pairs(def.stats or {}) do e[k] = v end
	if def.upgrades then
		e.upgrades = {}
		for i, u in ipairs(def.upgrades) do
			local key = name .. "_mk" .. (i + 1)
			local from = base.upgrades and base.upgrades[i] or {}
			local level = { cost = u.cost or from.cost or 2, upgrade_name = key, upgrade_description = name .. "_d_mk" .. (i + 1),
				upgrade_icon = u.icon or from.upgrade_icon, attributes = clone(u.attributes), upgrade_attributes = clone(u.upgrade_attributes) }
			for k, v in pairs(u.stats or {}) do level[k] = v end
			e.upgrades[i] = level
			texts[key] = u.title or level_title(def.title, i + 1)
			texts[level.upgrade_description] = u.description or def.description or ""
		end
	else
		-- The base's levels with the stratagem's name. Their order of purchase is their own.
		for i, level in ipairs(e.upgrades or {}) do
			level.upgrade_name = name .. "_mk" .. (i + 1)
			level.dependencies = nil
			texts[level.upgrade_name] = level_title(def.title, i + 1)
		end
	end
	local id = #s.stratagems + 1
	e.id = id
	s.stratagems[id] = e

	-- entry runs as the mod that made it, and not at all once that mod is off, as events are.
	local record = { name = name, base = def.base, base_id = base_id, id = id, unlock = def.unlock, entry = entry }
	defs[name], by_id[id] = record, record
	order[#order + 1] = record
	install_direct()
	return { name = name, id = id }
end

-- The custom stratagems made so far: { name, base, id }.
function M.list()
	local out = {}
	for i, r in ipairs(order) do out[i] = { name = r.name, base = r.base, id = r.id } end
	return out
end

-- The custom stratagem by its name, or nil.
function M.get(name)
	local r = defs[name]
	return r and { name = r.name, base = r.base, id = r.id } or nil
end

-- Opens a custom stratagem, kept for the next launch: the Loadout screen offers it from now on, whatever
-- its unlock says. For a mod's own progression, such as a mission done or a goal reached.
function M.unlock(name)
	if not defs[name] then return false, "not_available" end
	if not opened[name] then
		opened[name] = true
		changed()
	end
	return true
end

-- Takes back what unlock(name) gave. A "free" stratagem or one opened by rank stays open.
function M.lock(name)
	if not defs[name] then return false, "not_available" end
	if opened[name] then
		opened[name] = nil
		changed()
	end
	return true
end

-- Whether the Loadout screen offers a custom stratagem to this player now: by its unlock, or its base.
function M.is_unlocked(name)
	if not defs[name] then return false, "not_available" end
	return catalog.unlocked(name)
end

return M
