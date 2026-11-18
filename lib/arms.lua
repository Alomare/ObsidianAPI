-- Custom weapons: new primaries and sidearms, each made from one of the game's own, its base, with its own
-- name, words, icon, numbers and model. Other players always get the base, unless they have the same mod.

-- How it works. On the wire a custom weapon is always the base. Its entry's unit_path is the base's, so
-- the weapon spawned for it is the base's network object, and the loadout's primary_weapon_index goes out
-- as the base's: a machine without the mod sees, hears and simulates the base. An index or unit path
-- another game doesn't know would hit an assert there (EntitySpawner.mirror_entity).
--
-- The numbers: every weapon reads its settings through LuaSettingsManager.get_modified_settings(unit,
-- upgrade), with the weapon's unit. The weapon this machine spawns for a custom entry is bound to it as
-- it spawns (EntitySpawner.create_entity, before its components read their settings), and from then on
-- reads the custom numbers. Only in a cleared lobby: elsewhere a custom weapon has the base's numbers.
--
-- The look: the base's meshes are hidden and the model unit is spawned and linked to the weapon. On the
-- owner's machine, and on every machine that has the same custom weapon: each machine shares the names of
-- its players' custom weapons through the lobby (api.lobby.share), and a machine that knows a name draws
-- that look on the player's weapon. A machine that doesn't keeps the base. The look is the player's own
-- view of a weapon and changes nothing in the game, so it is drawn in any lobby.
local game = obsidian.module("lib/game")
local pack = game.pack
local catalog = obsidian.module("lib/catalog")
local custom = obsidian.module("lib/custom")
local lobby = obsidian.module("lib/lobby")

local M = {}

local SLOTS = { "primary_weapon", "sidearm_weapon" }
local IS_SLOT = { primary_weapon = true, sidearm_weapon = true }
-- The loadout's field for a slot (network_object_settings.lua: primary_weapon_index, uint8). A sidearm
-- has no field: the inventory spawns it straight from the saved loadout.
local FIELDS = { primary_weapon_index = "primary_weapon" }
local SHARE = "weapons"
local LANGUAGES = { en = "en", fr = "fr", es = "es", bp = "pt-BR" }

local defs = {}       -- by name
local order = {}      -- in the order they were made
local by_index = { primary_weapon = {}, sidearm_weapon = {} } -- an entry's index in its list -> def
local pending = {}    -- defs made before the game had its lists
local texts = {}      -- text key -> words
local installed = {}
-- The weapon units bound to a custom weapon: unit -> { def, stats }. stats: whether it reads the custom
-- numbers (made in a cleared lobby).
local instances = setmetatable({}, { __mode = "k" })
-- Drawn looks: weapon unit -> { model, world, def }.
local looks = {}
-- While InventoryComponent.set_loadout runs: the custom weapons it asked for, waiting for their unit.
local arming, armed = false, {}
local failed_models = {}

local function cleared()
	local session = obsidian.session
	return not (session and session.cleared) or session.cleared()
end

local function clone(t)
	if type(t) ~= "table" then return t end
	local out = {}
	for k, v in pairs(t) do out[k] = clone(v) end
	return setmetatable(out, getmetatable(t))
end

local function settings()
	local s = game.global("LoadoutSettings")
	if type(s) == "table" and type(s.primary_weapon) == "table" then return s end
	return nil
end

local function words(value)
	if type(value) == "string" then return value end
	local lm = game.global("LocalizationManager")
	local lang = LANGUAGES[type(lm) == "table" and lm.current_language or "en"] or "en"
	return value[lang] or value.en
end

-- A string, or a table of them by language with English in it, each at most max characters.
local function is_words(v, max)
	max = max or 200
	if type(v) == "string" then return v ~= "" and #v <= max end
	if type(v) ~= "table" or type(v.en) ~= "string" then return false end
	for _, s in pairs(v) do
		if type(s) ~= "string" or #s > max then return false end
	end
	return true
end

-- Plain numbers and booleans, of the type the base has where it has the field.
local function check_values(values, base)
	if values == nil then return true end
	if type(values) ~= "table" then return false end
	for k, v in pairs(values) do
		local kind = type(v)
		if type(k) ~= "string" or not (kind == "number" or kind == "boolean") then return false end
		if kind == "number" and (v ~= v or v < 0 or v > 100000) then return false end
		if base and base[k] ~= nil and type(base[k]) ~= kind then return false end
	end
	return true
end

-- The base's entry: its slot, the entry and its index.
local function find_base(s, name)
	for _, slot in ipairs(SLOTS) do
		for i, e in ipairs(type(s[slot]) == "table" and s[slot] or {}) do
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

local function check(def, s)
	if type(def) ~= "table" then return "bad_type" end
	if type(def.name) ~= "string" or not def.name:match("^[%w_]+$") or #def.name > 64 then return "bad_name" end
	if taken(s, def.name) then return "taken" end
	if type(def.base) ~= "string" or defs[def.base] then return "not_available" end
	if not is_words(def.title) or (def.description ~= nil and not is_words(def.description, 600)) then return "bad_type" end
	if def.model ~= nil and (type(def.model) ~= "string" or def.model == "") then return "bad_type" end
	if def.icon ~= nil and type(def.icon) ~= "string" then return "bad_type" end
	if def.icon_small ~= nil and type(def.icon_small) ~= "string" then return "bad_type" end
	if not check_values(def.stats) or not check_values(def.attributes) then return "bad_type" end
	return custom.bad_unlock(def.unlock)
end

-- The base's settings with the custom weapon's numbers and icons over them: a copy where the game can
-- list the table, and the base's for anything else. One per base table, so a weapon keeps the same table.
local function merged(def, base)
	if type(base) ~= "table" then return base end
	local hit = def.cache[base]
	if hit then return hit end
	local out = {}
	for k, v in pairs(base) do out[k] = v end
	setmetatable(out, { __index = base })
	if def.stats then
		local from = base.weapon_info
		local info = {}
		for k, v in pairs(type(from) == "table" and from or {}) do info[k] = v end
		for k, v in pairs(def.stats) do info[k] = v end
		out.weapon_info = setmetatable(info, { __index = from })
	end
	if def.icon then
		local from = base.hud_info
		local hud = {}
		for k, v in pairs(type(from) == "table" and from or {}) do hud[k] = v end
		hud.weapon_icon = def.icon
		hud.weapon_icon_small = def.icon_small or def.icon
		out.hud_info = setmetatable(hud, { __index = from })
	end
	def.cache[base] = out
	return out
end

-- The custom weapon a unit reads its numbers from, or nil.
local function numbers_of(unit)
	if type(unit) == "string" then return nil end
	local bound = instances[unit]
	return bound and bound.stats and bound.def or nil
end

-- The id other games know: the base's index for a custom entry.
local function wire(slot, index)
	local def = by_index[slot] and by_index[slot][index]
	return def and def.base_index or index
end

-- Weapon units of a player's inventory, on any machine: { primary_weapon = unit, ... }.
local function weapons_of(avatar)
	local aux = game.global("EntityAux")
	if not avatar or type(aux) ~= "table" then return nil end
	local state
	local ok, has = pcall(aux.has_component_master, avatar, "inventory")
	if ok and has then
		state = aux.state_master(avatar, "inventory")
	else
		-- Another machine's player: the slave's copy, which the game fills from the avatar's fields.
		local got, slave = pcall(aux.state, avatar, "inventory")
		if got then state = slave end
	end
	return type(state) == "table" and state or nil
end

local function alive(unit)
	local U = game.global("Unit")
	local ok, yes = pcall(U.alive, unit)
	return ok and yes == true
end

local set_visibility -- Unit.set_unit_visibility as the game has it, before the wrap

-- Draws a custom weapon's model on a weapon unit, and hides the base's meshes.
local function draw(unit, def)
	if not def.model or looks[unit] or failed_models[def.model] or not alive(unit) then return end
	local W = game.global("World")
	local st = game.state()
	local proxy = type(st) == "table" and st.world_proxy
	local ok, world = pcall(function() return proxy:get_world() end)
	if not ok or not world then return end
	local made, model = pcall(W.spawn_unit, world, def.model)
	if not made or not model then
		failed_models[def.model] = true
		obsidian.log("weapons: can't spawn the model of " .. def.name .. ": " .. tostring(def.model) .. " (" .. tostring(model) .. ")")
		return
	end
	local linked, why = pcall(W.link_unit, world, model, 0, unit, 0)
	if not linked then
		obsidian.log("weapons: can't link the model of " .. def.name .. ": " .. tostring(why))
		pcall(W.destroy_unit, world, model)
		failed_models[def.model] = true
		return
	end
	looks[unit] = { model = model, world = world, def = def }
	if set_visibility then pcall(set_visibility, unit, false) end
end

local function undraw(unit)
	local look = looks[unit]
	if not look then return end
	looks[unit] = nil
	if alive(look.model) then pcall(game.global("World").destroy_unit, look.world, look.model) end
	if alive(unit) and set_visibility then pcall(set_visibility, unit, true) end
end

local function bind(unit, def)
	instances[unit] = { def = def, stats = cleared() }
	draw(unit, def)
end

-- What this machine's main player carries, as the lobby text: "primary_weapon=name;sidearm_weapon=name".
local function my_text()
	local inv = weapons_of(game.my_unit())
	if not inv then return nil end
	local parts = {}
	for _, slot in ipairs(SLOTS) do
		local bound = inv[slot] and instances[inv[slot]]
		if bound then parts[#parts + 1] = slot .. "=" .. bound.def.name end
	end
	return #parts > 0 and table.concat(parts, ";") or nil
end

-- "primary_weapon=a;sidearm_weapon=b" -> { primary_weapon = "a", sidearm_weapon = "b" }, slots and names checked.
function M.parse(text)
	local out = {}
	for slot, name in tostring(text or ""):gmatch("([%w_]+)=([%w_]+)") do
		if IS_SLOT[slot] then out[slot] = name end
	end
	return out
end

-- The game's functions, replaced once, when the first custom weapon is made: they run in any lobby, and
-- do nothing for the game's own weapons.
local function install_direct()
	local go = game.global("GameObject")
	if not installed.game_object and type(go) == "table" and type(go.set) == "function" and type(go.get) == "function" then
		installed.game_object = true
		-- What this machine set, by object and field: { real index, base index }. Its own reads get the real one.
		local real = setmetatable({}, { __mode = "k" })
		local set, get = go.set, go.get
		go.set = function(self, field, value, ...)
			local slot = FIELDS[field]
			if slot then
				local base = wire(slot, value)
				local mine = real[self]
				if base ~= value then
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

	local lsm = game.global("LuaSettingsManager")
	if not installed.settings and type(lsm) == "table" and type(lsm.get_modified_settings) == "function" then
		installed.settings = true
		local modified, by_unit = lsm.get_modified_settings, lsm.get_settings_by_unit
		lsm.get_modified_settings = function(self, unit, upgrade, ...)
			local out = modified(self, unit, upgrade, ...)
			local def = numbers_of(unit)
			if def then return merged(def, out) end
			return out
		end
		if type(by_unit) == "function" then
			lsm.get_settings_by_unit = function(self, unit, ...)
				local out = by_unit(self, unit, ...)
				local def = numbers_of(unit)
				if def then return merged(def, out) end
				return out
			end
		end
	end

	local U = game.global("Unit")
	if not installed.visibility and type(U) == "table" and type(U.set_unit_visibility) == "function" then
		installed.visibility = true
		set_visibility = U.set_unit_visibility
		-- A weapon with a look: the game's show or hide goes to the model, and the base stays hidden.
		U.set_unit_visibility = function(unit, on, ...)
			local look = looks[unit]
			if look then
				if alive(look.model) then pcall(set_visibility, look.model, on, ...) end
				return set_visibility(unit, false, ...)
			end
			return set_visibility(unit, on, ...)
		end
	end
	return installed.game_object and installed.texts and installed.settings and installed.visibility
end

local function make(def, s)
	local slot, base, base_index = find_base(s, def.base)
	if not slot then return nil, "not_available" end
	local e = clone(base)
	e.name = def.name
	texts[def.name] = def.title
	if def.description then
		e.description = def.name .. "_d"
		texts[e.description] = def.description
	end
	if def.icon then e.icon = def.icon end
	if def.attributes then
		e.attributes = clone(base.attributes) or {}
		for k, v in pairs(def.attributes) do e.attributes[k] = v end
	end
	local list = s[slot]
	local index = #list + 1
	if e.id ~= nil then e.id = index end
	list[index] = e
	local record = { name = def.name, base = def.base, slot = slot, index = index, base_index = base_index,
		base_path = base.unit_path, model = def.model, stats = clone(def.stats), icon = def.icon,
		icon_small = def.icon_small, unlock = def.unlock, cache = setmetatable({}, { __mode = "k" }) }
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
		if not made then obsidian.log("weapons: " .. tostring(def.name) .. " not made: " .. tostring(why)) end
	end
end

-- Makes a custom weapon. def:
--   name         its key, letters, digits and _ ("mymod_breaker"); must be new
--   base         a primary or sidearm of the game's ("weapon_assaultrifle"): copied, and what other players
--                see. The slot is the base's
--   title        its name: a string, or { en = ..., fr = ..., es = ..., ["pt-BR"] = ... }
--   description  words under it; the base's if nil
--   model        the unit drawn over the base's: a mod's own (built with Minediver) or any unit the game
--                has loaded in a mission ("equipment/wep_shotgun_01"); the base's look if nil
--   icon         a weapon icon the menus and the HUD have ("wepicon_shotgun_01"); icon_small for the HUD's
--                small one. The base's if nil
--   stats        the weapon's numbers over the base's, as its weapon_info fields: power, firerate,
--                magazine_capacity, magazines, reload_duration, range, spread_max, ...
--   attributes   the bars the menus show, as the game's attr_ fields (attr_power = 4)
--   unlock       "base" (with its base, as when nil), "free", { rank = n } or "manual" (once
--                api.weapons.unlock(name) is called), as a custom stratagem's
-- Answers { name, slot, index }, or nil and a reason. Before the game has its lists, as in a mod's main
-- chunk, it answers { name, pending = true } and makes the weapon once the lists are there, before the
-- save's loadout is read.
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

-- The custom weapons made so far: { name, base, slot }.
function M.list()
	local out = {}
	for i, r in ipairs(order) do out[i] = { name = r.name, base = r.base, slot = r.slot } end
	return out
end

-- The custom weapon by its name, or nil: { name, base, slot, model }.
function M.get(name)
	local r = defs[name]
	return r and { name = r.name, base = r.base, slot = r.slot, model = r.model } or nil
end

-- The custom weapon a weapon unit is, on any machine that knows it, or nil.
function M.of(unit)
	local bound = unit and instances[unit]
	if bound then return bound.def.name end
	local look = unit and looks[unit]
	return look and look.def.name or nil
end

M.unlock, M.lock, M.is_unlocked = custom.unlock, custom.lock, custom.is_unlocked

function M.install()
	if installed.hooks then return end
	installed.hooks = true
	local wrap = obsidian.wrap or obsidian.hook
	-- A weapon defined before the game had its lists is made before the save's loadout is read.
	wrap("Boot", "ensure_loadout", function(original, ...)
		drain()
		return original(...)
	end)
	-- The inventory asks for each weapon of the loadout by name, then spawns the entry's unit_path: the
	-- base's. The unit it spawns for a custom entry is bound to it before its components set up.
	wrap("InventoryComponent", "set_loadout", function(original, ...)
		arming, armed = true, {}
		local r = pack(pcall(original, ...))
		arming, armed = false, {}
		if not r[1] then error(r[2], 0) end
		return unpack(r, 2, r.n)
	end)
	wrap("LoadoutSettings", "get_item", function(original, kind, name, ...)
		local e = original(kind, name, ...)
		local def = arming and IS_SLOT[kind] and defs[name]
		if def then armed[#armed + 1] = def end
		return e
	end)
	wrap("EntitySpawner", "create_entity", function(original, self, unit, ...)
		if arming and #armed > 0 then
			local ok, path = pcall(game.global("Unit").get_data, unit, "unit_path")
			for i, def in ipairs(armed) do
				if ok and path == def.base_path then
					table.remove(armed, i)
					bind(unit, def)
					break
				end
			end
		end
		return original(self, unit, ...)
	end)
	-- The paid pack, unlock and Loadout checks go through lib/custom.lua (custom.add_item).
end

-- Each frame, in any lobby: drop looks of weapons that are gone, share this machine's custom weapons, and
-- once a second draw the looks of other players' that this machine knows.
local since = 0
function M.tick(dt)
	drain()
	if #order == 0 then return end
	install_direct()
	for unit, look in pairs(looks) do
		if not alive(unit) then
			looks[unit] = nil
			if alive(look.model) then pcall(game.global("World").destroy_unit, look.world, look.model) end
		end
	end
	since = since + (tonumber(dt) or 0.016)
	if since < 1 then return end
	since = 0
	if game.lobby() then
		lobby.share(SHARE, my_text())
		local shared = lobby.shared(SHARE)
		local st = game.state()
		for _, p in ipairs(type(st) == "table" and type(st.players) == "table" and st.players or {}) do
			local go = p.player_go
			local ok, peer = pcall(function() return not go:owned() and go:owner() or nil end)
			local names = ok and peer and M.parse(shared[peer]) or nil
			local inv = names and next(names) and weapons_of(game.avatar(p))
			for slot, name in pairs(inv and names or {}) do
				local unit, def = inv[slot], defs[name]
				if def and unit and alive(unit) and def.slot == slot and not looks[unit] then draw(unit, def) end
			end
		end
	end
end

-- For tests: the look drawn on a unit, or nil.
function M.look(unit)
	return looks[unit]
end

M.undraw = undraw

return M
