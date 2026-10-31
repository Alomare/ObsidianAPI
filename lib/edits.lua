-- Checked, recorded, reversible changes to the game's data tables.
-- Every table stays the same table: entities and shot callbacks hold direct references to them.
-- A journal keeps each old value once, so undoing is exact and tells false from absent. Weapons
-- have a deep-cloned table per upgrade, which a change to the base table would miss, so each unit
-- edit recomputes those clones in place from the edited base.
local game = obsidian.module("lib/game")

local M = { journal = {}, records = {}, paused = false, next_id = 1 }

-- Values that live in entity state under the game's tamper check. They aren't settings, and
-- nothing here should write them. game.protected and queued commands are the way to change them.
local PROTECTED = {
	hitpoints_real = true, rounds = true, num_mags = true, reload_time = true, num_grenades = true,
	cooldown_timer = true, uses_left = true, wanted_move_speed = true, enemies_killed = true,
	enemies_to_kill = true, defend_timer = true, current_wave = true, time_elapsed = true,
	extra_lives = true, extra_lives_protected = true,
	-- Switches that open paid content in the game's menus.
	unlock_all = true, is_retail = true, IncludedEntitlements = true,
}

local function raw(t)
	return rawget(t, "__protected_table") or t
end

local function write(t, k, v)
	local keys = M.journal[t]
	if not keys then
		keys = {}
		M.journal[t] = keys
	end
	if keys[k] == nil then
		local old = rawget(t, k)
		keys[k] = { had = old ~= nil, old = old }
	end
	rawset(t, k, v)
end

local function restore_journal()
	for t, keys in pairs(M.journal) do
		for k, e in pairs(keys) do
			if e.had then rawset(t, k, e.old) else rawset(t, k, nil) end
		end
	end
	M.journal = {}
end

local function locate(root, path)
	local keys = {}
	for segment in string.gmatch(path, "[^.]+") do keys[#keys + 1] = tonumber(segment) or segment end
	local t = raw(root)
	for i = 1, #keys - 1 do
		t = t[keys[i]]
		if type(t) ~= "table" then return nil end
		t = raw(t)
	end
	return t, keys[#keys]
end

local function merge_in_place(dst, src)
	for k, v in pairs(src) do
		local d = rawget(dst, k)
		if type(v) == "table" and type(d) == "table" then
			merge_in_place(d, v)
		elseif d ~= v then
			write(dst, k, v)
		end
	end
	for k in pairs(dst) do
		if rawget(src, k) == nil then write(dst, k, nil) end
	end
end

local function active_upgrades(base, mask)
	local info, out = base.upgrade_info, {}
	if not info then return out end
	if info.type == "bitmask" then
		for i = 1, #info do
			if math.floor(mask / 2 ^ (i - 1)) % 2 == 1 then out[#out + 1] = info[i] end
		end
	else
		for i = 1, math.min(mask, #info) do out[#out + 1] = info[i] end
	end
	return out
end

-- One settings file can serve several unit paths, and each owns separate upgrade tables.
local function rebuild_variants(settings_path)
	local lsm = game.global("LuaSettingsManager")
	local clone = rawget(table, "clone")
	local aux = game.global("SettingsAux")
	if not (lsm and clone and aux) then return end
	local base = raw(lsm:get_settings_by_settings_path(settings_path))
	for unit_path, sp in lsm:unit_path_to_settings_path_iterator() do
		if sp == settings_path then
			local variants = lsm.unit_path_to_modified_settings[unit_path]
			for mask, t in pairs(variants or {}) do
				local fresh = clone(base)
				for _, upgrade in ipairs(active_upgrades(base, mask)) do
					aux.recursive_override(fresh, upgrade)
				end
				merge_in_place(raw(t), fresh)
			end
		end
	end
end

local function finite(n)
	return n == n and n ~= math.huge and n ~= -math.huge
end

local function check(path, old, value, opts)
	local key = string.match(path, "([^.]+)$")
	if PROTECTED[key] then return "protected" end
	local kind = type(value)
	if kind ~= "number" and kind ~= "boolean" and kind ~= "string" then return "bad_type" end
	if old ~= nil and type(old) ~= kind then return "bad_type" end
	if kind == "number" then
		if not finite(value) then return "bad_value" end
		if opts.min and value < opts.min then return "out_of_range" end
		if opts.max and value > opts.max then return "out_of_range" end
	end
	if old == nil and not opts.new then return "no_field" end
	return nil
end

local function apply(r)
	if r.settings_path then
		local lsm = game.global("LuaSettingsManager")
		local base = lsm and lsm:get_settings_by_settings_path(r.settings_path)
		if not base then return "no_target" end
		local t, k = locate(base, r.path)
		if not t then return "no_field" end
		local problem = check(r.path, t[k], r.value, r)
		if problem then return problem end
		write(t, k, r.value)
		rebuild_variants(r.settings_path)
	else
		local t, k = locate(r.table, r.path)
		if not t then return "no_field" end
		local problem = check(r.path, t[k], r.value, r)
		if problem then return problem end
		write(t, k, r.value)
		for _, path in ipairs(r.also or {}) do
			local at, key = locate(r.table, path)
			if at then write(at, key, r.value) end
		end
	end
	return nil
end

local function same_target(a, b)
	return a.path == b.path and a.settings_path == b.settings_path and a.table == b.table
end

local function replay()
	restore_journal()
	if M.paused then return end
	for _, r in ipairs(M.records) do
		local problem = apply(r)
		if problem then obsidian.log("edit not applied (" .. problem .. "): " .. tostring(r.target) .. " " .. r.path) end
	end
end

local function record(r)
	if not obsidian.session.cleared() then return false, "not_cleared" end
	local problem = apply(r)
	if problem then return false, problem end
	for i, other in ipairs(M.records) do
		if same_target(other, r) then
			r.id = other.id
			M.records[i] = r
			obsidian.log("edit: " .. tostring(r.target) .. " " .. r.path .. " = " .. tostring(r.value) .. " by " .. tostring(r.owner))
			return true
		end
	end
	r.id = M.next_id
	M.next_id = M.next_id + 1
	M.records[#M.records + 1] = r
	obsidian.log("edit: " .. tostring(r.target) .. " " .. r.path .. " = " .. tostring(r.value) .. " by " .. tostring(r.owner))
	return true
end

-- A value in a unit's settings file, by settings path and dotted field path.
-- opts: min, max, new (the field may be absent), target (a name for the list), apply (see fields.lua).
function M.set_unit(settings_path, path, value, opts)
	opts = opts or {}
	return record({ settings_path = settings_path, path = path, value = value, min = opts.min, max = opts.max, new = opts.new,
		target = opts.target or settings_path, apply_when = opts.apply, owner = obsidian.caller() })
end

-- A value in any table the game reads: a stratagem, a status template, character_info.
-- opts as above, and also: more paths in the table that take the same value, as one change.
function M.set_table(target, t, path, value, opts)
	opts = opts or {}
	return record({ table = t, path = path, also = opts.also, value = value, min = opts.min, max = opts.max, new = opts.new,
		target = target, apply_when = opts.apply, keep = opts.keep, owner = obsidian.caller() })
end

function M.value(settings_path, path)
	local lsm = game.global("LuaSettingsManager")
	local base = lsm and lsm:get_settings_by_settings_path(settings_path)
	if not base then return nil end
	local t, k = locate(base, path)
	return t and t[k]
end

function M.table_value(t, path)
	local at, k = locate(t, path)
	return at and at[k]
end

-- Whether a field was changed, and its value before the change.
function M.original(settings_path, path)
	local lsm = game.global("LuaSettingsManager")
	local base = lsm and lsm:get_settings_by_settings_path(settings_path)
	if not base then return false end
	local t, k = locate(base, path)
	local entry = t and M.journal[t] and M.journal[t][k]
	if entry then return true, entry.old end
	return false, t and t[k]
end

function M.list()
	local out = {}
	for i, r in ipairs(M.records) do
		out[i] = { id = r.id, target = r.target, path = r.path, value = r.value, owner = r.owner, apply = r.apply_when, settings_path = r.settings_path, keep = r.keep }
	end
	return out
end

function M.count()
	return #M.records
end

function M.revert(id)
	for i, r in ipairs(M.records) do
		if r.id == id then
			table.remove(M.records, i)
			replay()
			return true
		end
	end
	return false
end

function M.revert_where(settings_path, path)
	for _, r in ipairs(M.records) do
		if r.settings_path == settings_path and r.path == path then return M.revert(r.id) end
	end
	return false
end

function M.table_changed(t, path)
	local at, k = locate(t, path)
	return at ~= nil and M.journal[at] ~= nil and M.journal[at][k] ~= nil
end

function M.revert_table(t, path)
	for _, r in ipairs(M.records) do
		if r.table == t and r.path == path then return M.revert(r.id) end
	end
	return false
end

function M.revert_all()
	M.records = {}
	restore_journal()
end

-- The session stopped being cleared: the game goes back to its own numbers until it clears again.
function M.pause()
	if M.paused then return end
	M.paused = true
	restore_journal()
end

function M.resume()
	if not M.paused then return end
	M.paused = false
	replay()
end

return M
