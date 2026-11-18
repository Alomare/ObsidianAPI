-- Custom perks: new entries in the game's perk list, each made from one of the game's own, its base, with
-- its own name, words and icon, and functions of the mod that run beside the base's. Other players always
-- get the base.

-- How it works. The game runs a perk through PerkSettings[name]: setup, update and remove, each for the
-- owner's master and for every machine's slave, the name found from the perk's index in
-- LoadoutSettings.perks. The index goes out on the network twice: the loadout's perk_index (set through
-- GameObject.set) and the avatar's perk field (GameObjectFieldsReplicator). Both go out as the base's, so
-- every slave, the owner's included, runs the base's slave functions. The owner's master runs the custom
-- perk: the base's master functions, then the mod's, as hooks of the mod that made it, so they stop
-- while that mod is off or the lobby isn't cleared, and the base's keep running.
local game = obsidian.module("lib/game")
local pack = game.pack
local custom = obsidian.module("lib/custom")

local M = {}

local LANGUAGES = { en = "en", fr = "fr", es = "es", bp = "pt-BR" }
local defs, order, pending, texts, installed = {}, {}, {}, {}, {}
local by_index = {} -- an entry's index in LoadoutSettings.perks -> def

local function clone(t)
	if type(t) ~= "table" then return t end
	local out = {}
	for k, v in pairs(t) do out[k] = clone(v) end
	return setmetatable(out, getmetatable(t))
end

local function lists()
	local L, P = game.global("LoadoutSettings"), game.global("PerkSettings")
	if type(L) == "table" and type(L.perks) == "table" and type(P) == "table" then return L, P end
	return nil
end

local function words(value)
	if type(value) == "string" then return value end
	local lm = game.global("LocalizationManager")
	local lang = LANGUAGES[type(lm) == "table" and lm.current_language or "en"] or "en"
	return value[lang] or value.en
end

local function is_words(v, max)
	max = max or 200
	if type(v) == "string" then return v ~= "" and #v <= max end
	if type(v) ~= "table" or type(v.en) ~= "string" then return false end
	for _, s in pairs(v) do
		if type(s) ~= "string" or #s > max then return false end
	end
	return true
end

local function find_base(L, name)
	for i, e in ipairs(L.perks) do
		if e.name == name then return e, i end
	end
	return nil
end

local FUNCTIONS = { "on_setup", "on_update", "on_remove" }

local function check(def, L)
	if type(def) ~= "table" then return "bad_type" end
	if type(def.name) ~= "string" or not def.name:match("^[%w_]+$") or #def.name > 64 then return "bad_name" end
	if defs[def.name] or custom.get(def.name) or (L and find_base(L, def.name)) then return "taken" end
	for _, p in ipairs(pending) do
		if p.def.name == def.name then return "taken" end
	end
	if type(def.base) ~= "string" or defs[def.base] then return "not_available" end
	if not is_words(def.title) or (def.description ~= nil and not is_words(def.description, 600)) then return "bad_type" end
	if def.icon ~= nil and type(def.icon) ~= "string" then return "bad_type" end
	for _, k in ipairs(FUNCTIONS) do
		if def[k] ~= nil and type(def[k]) ~= "function" then return "bad_type" end
	end
	return custom.bad_unlock(def.unlock)
end

-- The def's functions as hooks of the mod calling define, made now, so they're that mod's and stop with it.
local function runner_of(def)
	local r = {}
	for _, k in ipairs(FUNCTIONS) do
		local fn = def[k]
		if fn then
			r[k] = { run = function() end }
			obsidian.hook(r[k], "run", function(_, ctx) return fn(ctx) end)
		end
	end
	return r
end

local function wire(index)
	local def = by_index[index]
	return def and def.base_index or index
end

local function install_direct()
	local go = game.global("GameObject")
	if not installed.game_object and type(go) == "table" and type(go.set) == "function" and type(go.get) == "function" then
		installed.game_object = true
		local real = setmetatable({}, { __mode = "k" })
		local set, get = go.set, go.get
		go.set = function(self, field, value, ...)
			if field == "perk_index" then
				local base = wire(value)
				if base ~= value then
					real[self] = { value, base }
					return set(self, field, base, ...)
				end
				real[self] = nil
			end
			return set(self, field, value, ...)
		end
		go.get = function(self, field, ...)
			local v = get(self, field, ...)
			local m = field == "perk_index" and real[self]
			if m and v == m[2] then return m[1] end
			return v
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
	return installed.game_object and installed.texts
end

local function make(entry, L, P)
	local def = entry.def
	local base, base_index = find_base(L, def.base)
	if not base or type(P[def.base]) ~= "table" then return nil, "not_available" end
	local e = clone(base)
	e.name = def.name
	texts[def.name] = def.title
	if def.description then
		e.description = def.name .. "_d"
		texts[e.description] = def.description
	end
	if def.icon then e.icon = def.icon end
	local index = #L.perks + 1
	if e.id ~= nil then e.id = index end
	L.perks[index] = e
	local record = { name = def.name, base = def.base, index = index, base_index = base_index, unlock = def.unlock }
	-- The base's functions for everything, the master's three followed by the mod's.
	local from, run = P[def.base], entry.run
	local function after(name, kind)
		return function(unit, comp, state, ...)
			local own = from[name]
			local r = own and pack(own(unit, comp, state, ...)) or { n = 0 }
			local fn = run[kind]
			if fn then fn.run({ unit = unit, state = state, name = def.name, dt = select(1, ...) }) end
			return unpack(r, 1, r.n)
		end
	end
	P[def.name] = setmetatable({
		setup_master = after("setup_master", "on_setup"),
		update_master = after("update_master", "on_update"),
		remove_master = after("remove_master", "on_remove"),
	}, { __index = from })
	defs[def.name] = record
	by_index[index] = record
	order[#order + 1] = record
	custom.add_item(record)
	install_direct()
	return { name = def.name, index = index }
end

local function drain()
	local L, P = lists()
	if not L or #pending == 0 then return end
	local list = pending
	pending = {}
	for _, entry in ipairs(list) do
		local made, why = make(entry, L, P)
		if not made then obsidian.log("perks: " .. tostring(entry.def.name) .. " not made: " .. tostring(why)) end
	end
end

-- Makes a custom perk. def:
--   name         its key, letters, digits and _ ("mymod_steady"); must be new
--   base         a perk of the game's ("perk_cardio"): its effect runs too, and other players see it
--   title, description  its words; icon, an icon the menus have (the base's if nil)
--   on_setup     function(ctx) when the owner's Helldiver spawns with it. ctx: unit, name, state (the
--                perk's own table, kept until it's removed)
--   on_update    function(ctx) each frame of the owner's game, ctx.dt the frame's seconds
--   on_remove    function(ctx) when the Helldiver goes
--   unlock       as a custom stratagem's
-- The functions run on the owner's machine only, and only in a cleared lobby. Answers { name, index }, or
-- nil and a reason; before the game has its lists, { name, pending = true }.
function M.define(def)
	local L, P = lists()
	local why = check(def, L)
	if why then return nil, why end
	local entry = { def = clone(def), run = runner_of(def) }
	for _, k in ipairs(FUNCTIONS) do entry.def[k] = def[k] end
	if not L then
		pending[#pending + 1] = entry
		return { name = def.name, pending = true }
	end
	return make(entry, L, P)
end

-- The custom perks made so far: { name, base }.
function M.list()
	local out = {}
	for i, r in ipairs(order) do out[i] = { name = r.name, base = r.base } end
	return out
end

function M.get(name)
	local r = defs[name]
	return r and { name = r.name, base = r.base } or nil
end

M.unlock, M.lock, M.is_unlocked = custom.unlock, custom.lock, custom.is_unlocked

function M.install()
	if installed.hooks then return end
	installed.hooks = true
	local wrap = obsidian.wrap or obsidian.hook
	wrap("GameObjectFieldsReplicator", "init", function(original, self, ...)
		local r = pack(original(self, ...))
		for _, field in ipairs(type(self.fields) == "table" and self.fields or {}) do
			local write = field.write
			if field.name == "perk" and type(write) == "function" then
				field.write = function(value, ...) return write(wire(value), ...) end
			end
		end
		return unpack(r, 1, r.n)
	end)
	wrap("Boot", "ensure_loadout", function(original, ...)
		drain()
		return original(...)
	end)
end

function M.tick()
	drain()
	if #order > 0 then install_direct() end
end

return M
