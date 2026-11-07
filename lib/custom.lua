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

-- From this library's frame callback, where obsidian.storage is this library's. dt: the frame's seconds.
local watch_shared
function M.tick(dt)
	if unsaved then save() end
	if watch_shared then watch_shared(tonumber(dt) or 0.016) end
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

-- Hidden stratagems: the game's own, taken out of the Arsenal, the Loadout screen, the default and saved
-- loadouts and the inventory a player starts a mission with. A separate section: nothing above reads it.
local hidden = {}        -- name -> { replace = name or nil }
local hidden_order = {}  -- the names, in the order they were hidden
local defaults_journal = {} -- what the default loadouts held before: { list, index, old, removed }
-- Carried stratagems (further down) that are custom ones leave the menus as hidden ones do.
local carried = {}       -- name -> { upgrade = "base", a level or nil }
local carried_order = {} -- the names, in the order they were carried

-- A custom stratagem every player carries: no menu offers it, as every mission has it anyway.
local function carried_custom(name)
	return carried[name] ~= nil and defs[name] ~= nil
end

local function carrying_customs()
	for _, name in ipairs(carried_order) do
		if defs[name] then return true end
	end
	return false
end

local function is_static(name)
	local s = settings()
	for _, n in ipairs(s and type(s.static_stratagems) == "table" and s.static_stratagems or {}) do
		if n == name then return true end
	end
	return false
end

local function shares_subtype(a, b)
	for _, x in ipairs(type(a.stratagem_subtypes) == "table" and a.stratagem_subtypes or {}) do
		for _, y in ipairs(type(b.stratagem_subtypes) == "table" and b.stratagem_subtypes or {}) do
			if x == y then return true end
		end
	end
	return false
end

local function list_has(list, name)
	for _, n in ipairs(list) do
		if n == name then return true end
	end
	return false
end

-- The stratagem that takes a hidden one's place in a loadout's list: the mod's choice, else the first of
-- the game's the player has that isn't in the list yet, one of the same kind first. nil when none.
local function replacement_for(list, name, preferred)
	if preferred and not hidden[preferred] and not list_has(list, preferred) then return preferred end
	local s = settings()
	if not s then return nil end
	local original = catalog.stratagem(name)
	local second
	for _, item in ipairs(s.stratagems) do
		local n = item.name
		if n and not hidden[n] and not defs[n] and not is_static(n) and not list_has(list, n) and catalog.unlocked(n) then
			if original and shares_subtype(original, item) then return n end
			second = second or n
		end
	end
	return second
end

-- Swaps every hidden name in a list of stratagem names. journal: where to record what was there, or nil.
-- customs: also the carried custom stratagems, which a saved loadout may still name.
local function swap_hidden(list, journal, customs)
	if type(list) ~= "table" then return end
	local i = 1
	while i <= #list do
		local name = list[i]
		local h = hidden[name] or (customs and carried_custom(name) and {}) or nil
		if h and not is_static(name) then
			local into = replacement_for(list, name, h.replace)
			if into then
				if journal then journal[#journal + 1] = { list = list, index = i, old = name } end
				list[i] = into
				i = i + 1
			else
				if journal then journal[#journal + 1] = { list = list, index = i, old = name, removed = true } end
				table.remove(list, i)
			end
		else
			i = i + 1
		end
	end
end

local function each_default(fn)
	local s = settings()
	if not s then return end
	if type(s.default_loadout) == "table" then fn(s.default_loadout.stratagems) end
	for _, l in ipairs(type(s.default_loadouts) == "table" and s.default_loadouts or {}) do
		if type(l) == "table" then fn(l.stratagems) end
	end
end

local function restore_defaults()
	for i = #defaults_journal, 1, -1 do
		local j = defaults_journal[i]
		if j.removed then table.insert(j.list, math.min(j.index, #j.list + 1), j.old) else j.list[j.index] = j.old end
	end
	defaults_journal = {}
end

local function apply_defaults()
	restore_defaults()
	if #hidden_order == 0 then return end
	each_default(function(list) swap_hidden(list, defaults_journal) end)
end

local function hiding()
	return #hidden_order > 0 and cleared()
end

-- Whether the menus leave anything out: hidden stratagems, or carried custom ones.
local function filtering()
	return (#hidden_order > 0 or carrying_customs()) and cleared()
end

local function left_out(name)
	return hidden[name] ~= nil or carried_custom(name)
end

-- A loadout as the game saves it, { stratagems = { name, ... }, ... }: only the hidden entries swapped.
-- The Loadout screen resets a whole loadout that holds a stratagem it doesn't list, so this runs first.
local function clean_loadout(loadout)
	if filtering() and type(loadout) == "table" then swap_hidden(loadout.stratagems, nil, true) end
	return loadout
end

local function clean_saved_loadouts(screen, slot)
	if not filtering() then return end
	local players = type(screen.parent) == "table" and screen.parent.players
	local player = type(players) == "table" and players[slot]
	local save, users = game.global("SaveManager"), game.global("UserManager")
	if type(player) ~= "table" or not save or not users then return end
	local pad = player.pad_number
	local ok, uid = pcall(users.get_user_id, users, pad)
	if not ok then return end
	local reads = { function(k) return save:user_get(k, uid) end }
	if type(pad) == "number" then
		reads[#reads + 1] = function(k) return save:get(k .. "_" .. tostring(pad)) end
	end
	for _, read in ipairs(reads) do
		for _, key in ipairs({ "loadout", "loadouts" }) do
			local fine, value = pcall(read, key)
			if fine and type(value) == "table" then
				if key == "loadout" then
					clean_loadout(value)
				else
					for _, l in ipairs(value) do clean_loadout(l) end
				end
			end
		end
	end
end

-- Takes hidden stratagems out of a list of groups ({ name, items }) in place.
local function filter_groups(groups)
	if not filtering() or type(groups) ~= "table" then return end
	local out = {}
	for _, group in ipairs(groups) do
		local keep = type(group) == "table" and not left_out(group.name)
		if keep and type(group.items) == "table" then
			local items, had = {}, #group.items
			for _, item in ipairs(group.items) do
				if not left_out(named(item)) then items[#items + 1] = item end
			end
			if had > 0 and #items == 0 then keep = false end
			if keep then
				for i = #group.items, 1, -1 do group.items[i] = nil end
				for i, item in ipairs(items) do group.items[i] = item end
			end
		end
		if keep then out[#out + 1] = group end
	end
	for i = #groups, 1, -1 do groups[i] = nil end
	for i, group in ipairs(out) do groups[i] = group end
end

-- An inventory component's state from what the component's functions get: the entity's context ({ state, ... }),
-- or the state itself.
local function inventory_state(ctx)
	if type(ctx) ~= "table" then return nil end
	if type(ctx.state) == "table" then return ctx.state end
	return ctx
end

-- A player's stratagems for the mission, off the inventory the game just built.
local function filter_inventory(state)
	if not hiding() or type(state) ~= "table" or type(state.stratagems) ~= "table" then return end
	local ids = {}
	for name in pairs(hidden) do
		local s = catalog.stratagem(name)
		if s then ids[s.id] = true end
	end
	for i = #state.stratagems, 1, -1 do
		local e = state.stratagems[i]
		if type(e) == "table" and ids[e.id] then table.remove(state.stratagems, i) end
	end
end

-- Takes a stratagem of the game's out of the Arsenal, the Loadout screen, the default loadouts, and a
-- player's saved loadouts and mission inventory, until unhide(name). Only a session mod in a cleared
-- session can. A saved loadout holding it gets another stratagem in that one slot, not a reset.
--   name   the stratagem's name ("stratagem_resupply")
--   opts   { replace = "stratagem_mortar" }: what takes the hidden one's place in a loadout. By default the first
--          stratagem the player has that the loadout doesn't hold, one of the same kind where there is
--          one; an entry with no such stratagem is dropped.
-- Returns true, or false and why: "not_available" (the game has no such stratagem, or replace isn't
-- one), "static" (the always-present stratagems, such as Reinforce, can't go), "not_cleared".
function M.hide(name, opts)
	if type(name) ~= "string" then return false, "bad_type" end
	if opts ~= nil and type(opts) ~= "table" then return false, "bad_type" end
	local replace = opts and opts.replace
	if replace ~= nil and type(replace) ~= "string" then return false, "bad_type" end
	if not catalog.stratagem(name) or defs[name] then return false, "not_available" end
	if replace and (not catalog.stratagem(replace) or hidden[replace] or replace == name or is_static(replace)) then return false, "not_available" end
	if is_static(name) then return false, "static" end
	if not cleared() then return false, "not_cleared" end
	if not hidden[name] then hidden_order[#hidden_order + 1] = name end
	hidden[name] = { replace = replace }
	apply_defaults()
	return true
end

-- Brings a hidden stratagem back to the Arsenal, the Loadout screen and the default loadouts. A saved
-- loadout whose entry was swapped keeps the swap. Returns true, also when it wasn't hidden.
function M.unhide(name)
	if type(name) ~= "string" then return false, "bad_type" end
	if hidden[name] then
		hidden[name] = nil
		for i, n in ipairs(hidden_order) do
			if n == name then table.remove(hidden_order, i) break end
		end
		apply_defaults()
	end
	return true
end

-- Whether hide(name) is in effect.
function M.is_hidden(name)
	return hidden[name] ~= nil
end

-- Carried stratagems: one more entry in every player's mission inventory, right after the
-- always-present ones (Reinforce, SOS Beacon, Hellbomb, Metal Detector), so the HUD lists it with them.
-- The game builds the inventory in InventoryComponent.set_loadout, and the "loadout" command that calls
-- it sends every entry to the other machines right after (broadcast_stratagem_cooldown), so they see it
-- too. A respawn copies the old entries back by index over a new list built the same way, so the
-- carried one keeps the same place and cooldown; an old list without it gets it in the same place first.

-- Whether a name is a stratagem now, or a custom one waiting for the game's list.
local function known(name)
	if defs[name] or catalog.stratagem(name) then return true end
	for _, p in ipairs(pending) do
		if p.def.name == name then return true end
	end
	return false
end

local function holds(entries, id)
	for _, e in pairs(entries) do
		if type(e) == "table" and e.id == id then return true end
	end
	return false
end

-- The level a carried entry has: what the player bought of the stratagem or of the base, or the one
-- the mod named, within the levels the stratagem has.
local function carried_level(name, entry, upgrades)
	local rule = carried[name] and carried[name].upgrade
	local level
	if type(rule) == "number" then
		level = rule
	else
		local key = name
		if rule == "base" and defs[name] then key = defs[name].base end
		level = upgrades and tonumber(upgrades[key]) or 0
	end
	local max = type(entry.upgrades) == "table" and #entry.upgrades or 0
	return math.max(0, math.min(math.floor(level), max))
end

-- After the game built a player's list from a loadout. The level goes into this inventory's copy of
-- the player's upgrades too, as the call-in and the cooldown read it there by the stratagem's name.
-- The place after the last always-present stratagem in a player's list.
local function after_statics(entries)
	local s = settings()
	local ids = {}
	for _, name in ipairs(s and type(s.static_stratagems) == "table" and s.static_stratagems or {}) do
		local e = catalog.stratagem(name)
		if e then ids[e.id] = true end
	end
	local at = 0
	for i, e in ipairs(entries) do
		if type(e) == "table" and ids[e.id] then at = i end
	end
	return at + 1
end

-- id -> name for the carried stratagems the game has.
local function carried_ids()
	local out = {}
	for _, name in ipairs(carried_order) do
		local e = catalog.stratagem(name)
		if e then out[e.id] = name end
	end
	return out
end

local function add_carried(state)
	if #carried_order == 0 or not cleared() or type(state) ~= "table" or type(state.stratagems) ~= "table" then return end
	local s = settings()
	if not s or type(s.get_upgraded_stratagem) ~= "function" then return end
	local upgrades = type(state.item_upgrades) == "table" and state.item_upgrades or nil
	local at = after_statics(state.stratagems)
	for _, name in ipairs(carried_order) do
		local e = catalog.stratagem(name)
		if e and not holds(state.stratagems, e.id) then
			local level = carried_level(name, e, upgrades)
			if upgrades then upgrades[name] = level end
			local info = s.get_upgraded_stratagem(e.id, level)
			table.insert(state.stratagems, math.min(at, #state.stratagems + 1), { id = e.id, cooldown_timer = 0,
				uses_left = info and info.num_uses, upgrade_value = level, loadout_info = info })
			at = at + 1
		end
	end
end

-- The respawn's "stratagems" command copies a dead player's old entries by index onto the new list. An
-- old list without a carried entry (carried after that player spawned) gets it in the new list's place,
-- so the entries after it keep theirs. Answers the list to copy.
local function align_restore(state, old)
	if #carried_order == 0 or not cleared() or type(old) ~= "table" or type(state) ~= "table" or type(state.stratagems) ~= "table" then return old end
	local ids = carried_ids()
	local out
	for i, e in ipairs(state.stratagems) do
		if type(e) == "table" and ids[e.id] and not holds(out or old, e.id) then
			if not out then
				out = {}
				for k, v in ipairs(old) do out[k] = v end
			end
			table.insert(out, math.min(i, #out + 1), { id = e.id, cooldown_timer = e.cooldown_timer, uses_left = e.uses_left,
				upgrade_value = e.upgrade_value, loadout_info = e.loadout_info })
		end
	end
	return out or old
end

-- Another machine's player, as this one sees them: a custom stratagem arrives as the base, so the
-- carried entry shows the base's icon and words. The carried one sits right after the always-present
-- stratagems, before every slot of the loadout, so of the entries holding a carried custom's base, the
-- first goes back to the custom, and any after it stay the base. Customs carried on one base take the
-- first places in the order they were carried. The entries arrive in order, so the first one is known
-- as soon as it comes.
local function relabel(state)
	if #carried_order == 0 or not cleared() or type(state) ~= "table" or type(state.stratagems) ~= "table" then return end
	local s = settings()
	if not s or type(s.get_upgraded_stratagem) ~= "function" then return end
	local groups = {}
	for _, name in ipairs(carried_order) do
		local d = defs[name]
		if d then
			groups[d.base_id] = groups[d.base_id] or {}
			table.insert(groups[d.base_id], d)
		end
	end
	for base_id, list in pairs(groups) do
		local ids = { [base_id] = true }
		for _, d in ipairs(list) do ids[d.id] = true end
		local at = {}
		for i, e in pairs(state.stratagems) do
			if type(i) == "number" and type(e) == "table" and ids[e.id] then at[#at + 1] = i end
		end
		table.sort(at)
		for k, i in ipairs(at) do
			local d = list[k]
			local want = d and d.id or base_id
			local e = state.stratagems[i]
			if e.id ~= want then
				local ok, info = pcall(s.get_upgraded_stratagem, want, e.upgrade_value or 0)
				e.id = want
				if ok and info then e.loadout_info = info end
			end
		end
	end
end

-- Every player carries a stratagem in every mission, as one more entry beside the always-present ones
-- (Reinforce and the like), until uncarry(name). The HUD lists it with them. A player whose loadout already holds it gets no second one. Every
-- player in the session needs the same call, so make it from a mod every player runs. It takes effect
-- at each player's next spawn, and in a lobby that isn't cleared nothing is added. A carried custom
-- stratagem leaves the Arsenal and the Loadout screen, and a saved loadout naming it gets another
-- stratagem in that slot; one of the game's stays in both, where the player buys the upgrades.
--   name   a stratagem of the game's, or a custom one (also one still pending)
--   opts   { upgrade = "base" }: a custom stratagem goes at the level the player owns of the base, for
--          one that keeps the base's levels. A number: that level for everyone. By default, the level
--          the player owns of the stratagem itself.
-- Returns true, or false and why: "not_available", "static" (always in every loadout), "not_cleared".
function M.carry(name, opts)
	if type(name) ~= "string" then return false, "bad_type" end
	if opts ~= nil and type(opts) ~= "table" then return false, "bad_type" end
	local upgrade = opts and opts.upgrade
	if upgrade ~= nil and upgrade ~= "base" and not (type(upgrade) == "number" and upgrade >= 0 and upgrade <= 15 and upgrade == math.floor(upgrade)) then
		return false, "bad_type"
	end
	if settings() and not known(name) then return false, "not_available" end
	if is_static(name) then return false, "static" end
	if not cleared() then return false, "not_cleared" end
	if not carried[name] then carried_order[#carried_order + 1] = name end
	carried[name] = { upgrade = upgrade }
	return true
end

-- Stops carrying a stratagem from the next mission on: a player in a mission keeps the entry until
-- then. Returns true, also when it wasn't carried.
function M.uncarry(name)
	if type(name) ~= "string" then return false, "bad_type" end
	if carried[name] then
		carried[name] = nil
		for i, n in ipairs(carried_order) do
			if n == name then table.remove(carried_order, i) break end
		end
	end
	return true
end

-- Whether carry(name) is in effect.
function M.is_carried(name)
	return carried[name] ~= nil
end

-- Shared cooldowns: one throw starts the cooldown for the whole squad. Each machine looks after the
-- players it runs: a throw here is seen in the throw command, a throw on another machine as that player's
-- entry going from ready to a long cooldown, through the game's own messages. Either way, every player
-- of this machine whose entry is shorter gets the same time, through the game's set_stratagem_info and
-- a broadcast, as reset_cooldowns does. Those broadcasts look like a throw to the others, but they find
-- their players' entries as long already and send nothing back.
local shared = {}        -- name -> true
local shared_order = {}
local SLACK = 2          -- seconds a player's entry may be short of the squad's before being set
local SETTLE = 4         -- seconds an entry is watched before a jump counts: a respawn copies old times in
local READY = 1          -- an entry this close to ready could have been thrown
local JUMP = 5           -- and one that is now this long was
local ADOPT = 6          -- seconds a new entry of this machine takes on the squad's remaining time
local thrown = {}        -- id -> the longest time thrown on this machine since the last frame
local watched = setmetatable({}, { __mode = "k" }) -- an entry -> { time, age, set }

-- id -> true for the shared stratagems the game has.
local function shared_ids()
	local out
	for _, name in ipairs(shared_order) do
		local e = catalog.stratagem(name)
		if e then
			out = out or {}
			out[e.id] = true
		end
	end
	return out
end

local function cooldown_of(e)
	local t = tonumber(e.cooldown_timer)
	if t == nil or t ~= t then return 0 end
	return t
end

-- From the throw command on this machine: the entries it just started.
local function note_throw(state, id)
	if #shared_order == 0 or not cleared() or type(state) ~= "table" or type(state.stratagems) ~= "table" then return end
	local ids = shared_ids()
	if not (ids and ids[id]) then return end
	for _, e in pairs(state.stratagems) do
		if type(e) == "table" and e.id == id then
			local t = cooldown_of(e)
			if t > 0 and t > (thrown[id] or 0) then thrown[id] = t end
		end
	end
end

-- Whether an entry of another machine just went from ready to a long cooldown.
local function jumped(before, now, age)
	return age >= SETTLE and before <= READY and now >= JUMP
end

-- Whether this machine's entry, at `now`, is to be set to the squad's `squad`.
local function behind_of(now, squad)
	return now < squad - SLACK
end

local function set_time(unit, id, time)
	if game.command(unit, "inventory", "set_stratagem_info", { id = id, cooldown_timer = time }) then
		game.command(unit, "inventory", "broadcast_stratagem_cooldown")
	end
end

-- Sets the entry on every player of this machine that is short of the squad's time, and tells the
-- other machines.
local function catch_up(id, time)
	for unit, ctx in pairs(game.masters("inventory")) do
		local state = inventory_state(ctx)
		local behind = false
		for _, e in pairs(state and type(state.stratagems) == "table" and state.stratagems or {}) do
			if type(e) == "table" and e.id == id and behind_of(cooldown_of(e), time) then
				behind = true
				local w = watched[e]
				if w then w.set = time end
			end
		end
		if behind then set_time(unit, id, time) end
	end
end

-- Each entry of a shared stratagem, with the unit holding it: fn(unit, entry). mine: this machine's players.
local function each_entry(ids, mine, fn)
	for unit, ctx in pairs(game[mine and "masters" or "slaves"]("inventory")) do
		local state = (mine or not game.master(unit, "inventory")) and inventory_state(ctx)
		for _, e in pairs(state and type(state.stratagems) == "table" and state.stratagems or {}) do
			if type(e) == "table" and ids[e.id] then fn(unit, e) end
		end
	end
end

-- Two things are told apart here. A throw on another machine is an entry going from ready to a long
-- time, once that entry has been watched a while. A new entry of this machine (a player joining, a
-- respawn) takes the squad's remaining time at once: the longest of every entry this machine knows,
-- of the players here and on the other machines, and tells the others. A player joining another machine
-- gets the time there the same way, from this machine's players as that machine sees them.
watch_shared = function(dt)
	if #shared_order == 0 or not cleared() then
		thrown = {}
		return
	end
	local ids = shared_ids()
	if not ids then return end
	local times = thrown
	thrown = {}
	local squad, fresh = {}, {}
	local function seen(e, now)
		if now > (squad[e.id] or 0) then squad[e.id] = now end
		local w = watched[e]
		if not w then
			w = { time = now, age = 0 }
			watched[e] = w
		end
		return w
	end
	each_entry(ids, false, function(_, e)
		local now = cooldown_of(e)
		local w = seen(e, now)
		if jumped(w.time, now, w.age) and now > (times[e.id] or 0) then times[e.id] = now end
		w.time, w.age = now, w.age + dt
	end)
	each_entry(ids, true, function(unit, e)
		local now = cooldown_of(e)
		local w = seen(e, now)
		if w.age < ADOPT then fresh[#fresh + 1] = { unit = unit, entry = e, w = w } end
		w.time, w.age = now, w.age + dt
	end)
	for id, time in pairs(times) do catch_up(id, time) end
	for _, f in ipairs(fresh) do
		local id, target = f.entry.id, squad[f.entry.id] or 0
		if not times[id] and behind_of(cooldown_of(f.entry), target) and not (f.w.set and f.w.set >= target - SLACK) then
			f.w.set = target
			set_time(f.unit, id, target)
		end
	end
end

-- Makes a stratagem's cooldown the squad's: when any player throws it, every player's entry for it
-- waits the same time, until unshare_cooldown(name). Every player in the session needs the same call,
-- so make it from a mod every player runs. Players on one machine share it too. A player who joins
-- during a mission, or spawns again, takes the squad's remaining time at once. In a lobby that isn't
-- cleared each player's cooldown is their own. A custom stratagem is recognised on other machines
-- when it is carried (carry), since a custom one travels as the base; a game's one always is.
-- Returns true, or false and why: "not_available", "not_cleared".
function M.share_cooldown(name)
	if type(name) ~= "string" then return false, "bad_type" end
	if settings() and not known(name) then return false, "not_available" end
	if not cleared() then return false, "not_cleared" end
	if not shared[name] then shared_order[#shared_order + 1] = name end
	shared[name] = true
	return true
end

-- Each player's cooldown for the stratagem is their own again. Returns true, also when it wasn't shared.
function M.unshare_cooldown(name)
	if type(name) ~= "string" then return false, "bad_type" end
	if shared[name] then
		shared[name] = nil
		for i, n in ipairs(shared_order) do
			if n == name then table.remove(shared_order, i) break end
		end
	end
	return true
end

-- Whether share_cooldown(name) is in effect.
function M.is_shared(name)
	return shared[name] == true
end

-- A code two stratagems have: the game's find_stratagem answers the first in the game's list, and the player
-- may hold only the other. Of the stratagems whose code is the arrows in `queue`, the one the player
-- holds and can call now wins, then one the player holds, then the game's answer `id`. The player is the
-- one whose character keeps that queue.
local function same_code(combo, queue)
	if type(combo) ~= "table" or #combo ~= #queue then return false end
	for i = 1, #queue do
		if combo[i] ~= queue[i] then return false end
	end
	return true
end

function M.prefer_held(id, queue)
	local s = settings()
	if not s or type(queue) ~= "table" or #queue == 0 then return id end
	local order = { id }
	for i, e in ipairs(s.stratagems) do
		if i ~= id and type(e) == "table" and same_code(e.combo, queue) then order[#order + 1] = i end
	end
	if #order == 1 then return id end
	local inv
	for unit, ctx in pairs(game.masters("character")) do
		local state = inventory_state(ctx)
		if state and state.stratagems_queue == queue then inv = game.master(unit, "inventory") end
	end
	if not (inv and type(inv.stratagems) == "table") then return id end
	local held, ready = {}, {}
	for _, e in pairs(inv.stratagems) do
		if type(e) == "table" and e.id ~= nil then
			held[e.id] = true
			if cooldown_of(e) <= 0 and not e.blocked and (e.uses_left == nil or e.uses_left > 0) then ready[e.id] = true end
		end
	end
	for _, c in ipairs(order) do
		if c and ready[c] then return c end
	end
	for _, c in ipairs(order) do
		if c and held[c] then return c end
	end
	return id
end

-- The proving grounds draw a random loadout from the game's list: not a hidden stratagem, a carried
-- one, nor a custom one nobody has unlocked.
local function keep_out_of_pool(list)
	if type(list) ~= "table" or not cleared() then return end
	for i = #list, 1, -1 do
		local name = list[i]
		local d = defs[name]
		if (hiding() and hidden[name]) or carried[name] or (d and d.unlock == "manual" and not opened[name]) then table.remove(list, i) end
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
		return clean_loadout(original(...))
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
		if type(items) == "table" then filter_groups(items.groups) end
		return unpack(r)
	end)
	obsidian.hook("MenuScreenLoadout", "setup_loadout", function(original, self, slot, ...)
		clean_saved_loadouts(self, slot)
		local r = { original(self, slot, ...) }
		-- The screen keeps each player's lists in option_menus[slot] (menu_screen_loadout.lua:142, 441),
		-- which every later read of the screen uses: the selection, the random loadout and the drawing.
		local menus = type(self.option_menus) == "table" and self.option_menus[slot]
		if type(menus) ~= "table" or type(menus.available_items) ~= "table" then
			local players = type(self.parent) == "table" and self.parent.players
			menus = type(players) == "table" and players[slot]
		end
		local items = type(menus) == "table" and type(menus.available_items) == "table" and menus.available_items.stratagems
		if type(items) == "table" then
			beside_bases(items.groups, named, group_holds)
			filter_groups(items.groups)
		end
		return unpack(r)
	end)
	-- A hidden stratagem is not in the inventory a mission starts with, whatever loadout named it, and a
	-- carried one is added after the rest. `from` is the player the loadout is read for; the tutorial's
	-- and the game's fixed loadouts ("loadout_override") have none and get nothing added.
	obsidian.hook("InventoryComponent", "set_loadout", function(original, self, unit, ctx, from, ...)
		local r = { original(self, unit, ctx, from, ...) }
		local state = inventory_state(ctx)
		filter_inventory(state)
		if from ~= nil then add_carried(state) end
		return unpack(r)
	end)
	-- Another machine's entry for a carried custom stratagem shows as the custom one, and a throw of a
	-- shared stratagem here starts the squad's cooldown.
	obsidian.hook("InventoryComponent", "command_slave", function(original, self, unit, ctx, name, data, ...)
		local r = { original(self, unit, ctx, name, data, ...) }
		if name == "stratagem_cooldown" then relabel(inventory_state(ctx)) end
		return unpack(r)
	end)
	obsidian.hook("InventoryComponent", "command_master", function(original, self, unit, ctx, name, data, ...)
		if name == "stratagems" then data = align_restore(inventory_state(ctx), data) end
		local r = { original(self, unit, ctx, name, data, ...) }
		if name == "throw_stratagem" then note_throw(inventory_state(ctx), data) end
		return unpack(r)
	end)
	obsidian.hook("ProvinggroundsConditions", "remove_blacklisted_strats", function(original, list, ...)
		local r = { original(list, ...) }
		keep_out_of_pool(r[1])
		return unpack(r)
	end)
	-- Hides come off the default loadouts when the session stops being cleared, and go back with it.
	obsidian.on_session(function(on)
		if on then apply_defaults() else restore_defaults() end
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
