-- Custom cosmetics: helmets, armour and capes, each made from one of the game's own, its base, with its
-- own name and model. Other players always get the base, unless they have the same mod.

-- How it works. The game keeps a Helldiver's helmet, body and cape as indexes into CustomizationSettings
-- lists: in the save ("customization"), in the customization component's state, and on the network
-- (uint8 fields helmet, body and cape). Every machine spawns the units from those indexes, each frame
-- that one changes (CustomizationComponent.update_unit).
--
-- So a custom cosmetic is an entry appended to its base's list, and its index never leaves this
-- machine's memory:
-- - the network fields carry the base's index (GameObjectFieldsReplicator), so a game without the mod
--   draws the base;
-- - the save holds the base's index, and the custom choice is kept by this library (obsidian.save_data,
--   key "worn"): the game reads it back as the custom index while the cosmetic exists, and as the base
--   once the mod is gone, so a save never names an index the game doesn't have;
-- - each machine shares its main player's custom cosmetics through the lobby; update_unit draws a
--   player's custom index where this machine knows the name, on any machine, the owner's included.
-- A cosmetic changes nothing in the game, so all of it runs in any lobby. Look only: a def has room for a
-- later passive.
local game = obsidian.module("lib/game")
local pack = game.pack
local custom = obsidian.module("lib/custom")
local lobby = obsidian.module("lib/lobby")

local M = {}

local SLOTS = { "helmet", "body", "cape" }
local IS_SLOT = { helmet = true, body = true, cape = true }
local GENDERS = { "male", "female" }
local SHARE = "wear"
local KEY = "worn"
local LANGUAGES = { en = "en", fr = "fr", es = "es", bp = "pt-BR" }

local defs, order, pending, texts, installed = {}, {}, {}, {}, {}
local by_index = { helmet = {}, body = {}, cape = {} } -- an entry's index in its list -> def

-- The custom cosmetics this player wears, slot -> name, kept with the save.
local store = obsidian.save_data or obsidian.storage
local worn = {}
for slot, name in tostring(store.get(KEY) or ""):gmatch("([%w_]+)=([%w_]+)") do
	if IS_SLOT[slot] then worn[slot] = name end
end
local unsaved = false
local SELF = obsidian.caller and obsidian.caller()

local function save_worn()
	local parts = {}
	for _, slot in ipairs(SLOTS) do
		if worn[slot] then parts[#parts + 1] = slot .. "=" .. worn[slot] end
	end
	store.set(KEY, table.concat(parts, ";"))
	unsaved = false
end

local function changed()
	if obsidian.caller and obsidian.caller() == SELF then save_worn() else unsaved = true end
end

local function clone(t)
	if type(t) ~= "table" then return t end
	local out = {}
	for k, v in pairs(t) do out[k] = clone(v) end
	return setmetatable(out, getmetatable(t))
end

local function settings()
	local s = game.global("CustomizationSettings")
	if type(s) == "table" and type(s.helmet) == "table" and type(s.body) == "table" and type(s.cape) == "table" then return s end
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

local function find_base(s, name)
	for _, slot in ipairs(SLOTS) do
		for i, e in ipairs(s[slot]) do
			if e.name == name then return slot, e, i end
		end
	end
	return nil
end

local function taken(s, name)
	if defs[name] or custom.get(name) then return true end
	for _, p in ipairs(pending) do
		if p.name == name then return true end
	end
	return s ~= nil and find_base(s, name) ~= nil
end

-- model: a unit path, or for armour { male = path, female = path } (a string serves both).
local function good_model(model)
	if model == nil then return true end
	if type(model) == "string" then return model ~= "" end
	if type(model) ~= "table" then return false end
	for k, v in pairs(model) do
		if (k ~= "male" and k ~= "female") or type(v) ~= "string" or v == "" then return false end
	end
	return true
end

local function check(def, s)
	if type(def) ~= "table" then return "bad_type" end
	if type(def.name) ~= "string" or not def.name:match("^[%w_]+$") or #def.name > 64 then return "bad_name" end
	if taken(s, def.name) then return "taken" end
	if type(def.base) ~= "string" or defs[def.base] then return "not_available" end
	if not is_words(def.title) or (def.description ~= nil and not is_words(def.description, 600)) then return "bad_type" end
	if not good_model(def.model) then return "bad_type" end
	if def.passive ~= nil then return "not_available" end -- kept for later: armour passives
	return custom.bad_unlock(def.unlock)
end

-- The index another game knows: the base's for a custom entry.
local function wire(slot, index)
	local def = by_index[slot] and by_index[slot][index]
	return def and def.base_index or index
end

-- The index this machine draws for a slot: the custom one when `names` (slot -> name) names one of this
-- slot made from the base that came, else what came.
local function local_index(slot, index, names)
	local name = names and names[slot]
	local def = name and defs[name]
	if def and def.slot == slot and def.base_index == index then return def.index end
	return index
end

-- "helmet=a;cape=b" -> { helmet = "a", cape = "b" }, slots and names checked: what another machine shares.
function M.parse(text)
	local out = {}
	for slot, name in tostring(text or ""):gmatch("([%w_]+)=([%w_]+)") do
		if IS_SLOT[slot] then out[slot] = name end
	end
	return out
end

local function worn_text()
	local parts = {}
	for _, slot in ipairs(SLOTS) do
		if worn[slot] and defs[worn[slot]] then parts[#parts + 1] = slot .. "=" .. worn[slot] end
	end
	return #parts > 0 and table.concat(parts, ";") or nil
end

-- The game's customization table as the save should keep it: custom indexes become their base's, and
-- `worn` remembers them. Answers the copy for the save.
local function to_save(t)
	if type(t) ~= "table" then return t end
	local out, any = clone(t), false
	for _, slot in ipairs(SLOTS) do
		local def = by_index[slot][t[slot]]
		local before = worn[slot]
		if def then
			out[slot] = def.base_index
			worn[slot] = def.name
		elseif t[slot] ~= nil then
			worn[slot] = nil
		end
		if worn[slot] ~= before then any = true end
	end
	if any then changed() end
	return out
end

-- The save's table as the game should see it: a base index worn as a custom cosmetic becomes the custom
-- index, while that cosmetic exists and its base is what the save holds.
local function from_save(t)
	if type(t) ~= "table" then return t end
	local out = nil
	for _, slot in ipairs(SLOTS) do
		local i = local_index(slot, t[slot], worn)
		if i ~= t[slot] then
			out = out or clone(t)
			out[slot] = i
		end
	end
	return out or t
end

-- Each player's avatar -> the names to draw on it: this machine's own players get `worn`, the others what
-- their machine shares. Made once a second.
local drawn_for = setmetatable({}, { __mode = "k" })

local function install_direct()
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
	local sm = game.global("SaveManager")
	if not installed.save and type(sm) == "table" and type(sm.user_get) == "function" and type(sm.user_set) == "function" then
		installed.save = true
		local get, set = sm.user_get, sm.user_set
		sm.user_get = function(self, key, ...)
			local v = get(self, key, ...)
			if key == "customization" then return from_save(v) end
			return v
		end
		sm.user_set = function(self, key, value, ...)
			if key == "customization" then value = to_save(value) end
			return set(self, key, value, ...)
		end
	end
	return installed.texts and installed.save
end

local function make(def, s)
	local slot, base, base_index = find_base(s, def.base)
	if not slot then return nil, "not_available" end
	local e = clone(base)
	e.name = def.name
	texts[def.name] = def.title
	if def.description then texts[def.name .. "_d"] = def.description end
	local model = def.model
	if slot == "body" then
		for _, g in ipairs(GENDERS) do
			local path = type(model) == "string" and model or (type(model) == "table" and model[g])
			if path then
				e[g] = clone(e[g]) or {}
				e[g].unit_path = path
			end
		end
	elseif type(model) == "string" then
		e.unit_path = model
	end
	local list = s[slot]
	local index = #list + 1
	list[index] = e
	local record = { name = def.name, base = def.base, slot = slot, index = index, base_index = base_index, unlock = def.unlock }
	defs[def.name] = record
	by_index[slot][index] = record
	order[#order + 1] = record
	custom.add_item(record)
	install_direct()
	return { name = def.name, slot = slot, index = index }
end

local function drain()
	local s = settings()
	if not s or #pending == 0 then return end
	local list = pending
	pending = {}
	for _, def in ipairs(list) do
		local made, why = make(def, s)
		if not made then obsidian.log("cosmetics: " .. tostring(def.name) .. " not made: " .. tostring(why)) end
	end
end

-- Makes a custom helmet, armour or cape. def:
--   name         its key, letters, digits and _ ("mymod_visor"); must be new
--   base         a cosmetic of the game's ("cus_helmet_tactical", "cus_body_default", "cus_cape_default"):
--                copied, and what other players see. The slot is the base's
--   title        its name: a string, or { en = ..., fr = ..., es = ..., ["pt-BR"] = ... }
--   model        the unit it spawns: for a helmet or cape a path, for armour { male = path, female = path }
--                or one path for both. A mod's own (built with Minediver) or any the game has. The base's
--                if nil
--   unlock       "base" (with its base, as when nil), "free", { rank = n } or "manual" (once
--                api.cosmetics.unlock(name) is called), as a custom stratagem's
-- Answers { name, slot, index }, or nil and a reason. Before the game has its lists, as in a mod's main
-- chunk, it answers { name, pending = true } and makes it once they're there.
function M.define(def)
	local s = settings()
	local why = check(def, s)
	if why then return nil, why end
	if not s then
		pending[#pending + 1] = clone(def)
		return { name = def.name, pending = true }
	end
	return make(def, s)
end

-- The custom cosmetics made so far: { name, base, slot }.
function M.list()
	local out = {}
	for i, r in ipairs(order) do out[i] = { name = r.name, base = r.base, slot = r.slot } end
	return out
end

-- The custom cosmetic by its name, or nil: { name, base, slot }.
function M.get(name)
	local r = defs[name]
	return r and { name = r.name, base = r.base, slot = r.slot } or nil
end

-- What this player wears of the custom cosmetics: slot -> name.
function M.worn()
	local out = {}
	for slot, name in pairs(worn) do
		if defs[name] then out[slot] = name end
	end
	return out
end

M.unlock, M.lock, M.is_unlocked = custom.unlock, custom.lock, custom.is_unlocked

function M.install()
	if installed.hooks then return end
	installed.hooks = true
	local wrap = obsidian.wrap or obsidian.hook
	-- The network fields go out as the base's index.
	wrap("GameObjectFieldsReplicator", "init", function(original, self, ...)
		local r = pack(original(self, ...))
		for _, field in ipairs(type(self.fields) == "table" and self.fields or {}) do
			local write, slot = field.write, field.name
			if IS_SLOT[slot] and type(write) == "function" then
				field.write = function(value, ...) return write(wire(slot, value), ...) end
			end
		end
		return unpack(r, 1, r.n)
	end)
	-- Each Helldiver draws the custom index where this machine knows the name, its own players included:
	-- their own copy of the state comes from the network too, and so holds the base.
	wrap("CustomizationComponent", "update_unit", function(original, self, state, unit, ...)
		local names = unit ~= nil and drawn_for[unit]
		if names and type(state) == "table" then
			for _, slot in ipairs(SLOTS) do
				local i = state[slot]
				if i ~= nil then state[slot] = local_index(slot, i, names) end
			end
		end
		return original(self, state, unit, ...)
	end)
end

-- Each frame, in any lobby: keep `worn`, and once a second share it and work out whose avatar wears what.
local since = 0
function M.tick(dt)
	drain()
	if unsaved then save_worn() end
	if #order == 0 then return end
	install_direct()
	since = since + (tonumber(dt) or 0.016)
	if since < 1 then return end
	since = 0
	local shared = {}
	if game.lobby() then
		lobby.share(SHARE, worn_text())
		shared = lobby.shared(SHARE)
	end
	for _, p in ipairs(game.all_avatars()) do
		if p.owned then
			drawn_for[p.unit] = worn
		else
			local ok, peer = pcall(function() return p.record.player_go:owner() end)
			drawn_for[p.unit] = ok and peer and M.parse(shared[peer]) or nil
		end
	end
end

-- For tests: the save's table as the game sees it, and as the save keeps it.
M.from_save, M.to_save = from_save, to_save

return M
