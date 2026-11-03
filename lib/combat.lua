-- Damage by who takes it. Every hit asks HealthComponent or ShieldComponent what it costs, so a hook
-- there reaches them all, and the game still makes the guarded write with the answer. No attacker is
-- passed in, so a scale goes by victim. Each player's game works out its own hits, so everyone in a
-- lobby should use the same numbers.
local game = obsidian.module("lib/game")
local effects = obsidian.module("lib/effects")

local M = {}

local MOST = 100

-- Read inside the hooks, which the session gate turns off, so there's nothing to undo.
local function nothing() end

effects.define({ id = "damage_to_players", remove = nothing })
effects.define({ id = "damage_to_enemies", remove = nothing })

local function scale_of(unit)
	local aux = game.global("EntityAux")
	if aux.has_component(unit, "character") then return effects.get("damage_to_players") end
	if aux.has_component(unit, "enemy") then return effects.get("damage_to_enemies") end
	return false
end

-- Hits the players of this machine land, and hits that would kill one of them. A player's game works
-- out its players' hits: HealthComponent.command_master when this machine runs the victim,
-- filter_slave_command when another one does. Each asks calculate_damage once, first, so the hook
-- there knows which hit it's pricing (`current`), and the listeners hear of it once the command is done.
local hit_list, fatal_list = {}, {}
local current = nil

local function noop() end

-- As events do it: each function a hook on a table of its own, so it runs as its mod, and not at all
-- once that mod is off.
local function listen(list, fn)
	if type(fn) ~= "function" then return false, "bad_type" end
	local entry = { fn = fn, run = noop }
	obsidian.hook(entry, "run", function(_, ...) return fn(...) end)
	list[#list + 1] = entry
	return true
end

local function unlisten(list, fn)
	for i = #list, 1, -1 do
		if list[i].fn == fn then table.remove(list, i) end
	end
	return true
end

local function own_player(unit)
	local aux = game.global("EntityAux")
	return unit ~= nil and game.global("Unit").alive(unit) and aux.owned(unit) and aux.has_component(unit, "character")
end

local SLOTS = { "primary_weapon", "sidearm_weapon", "support_weapon" }

local function slot_of(owner, weapon)
	local inv = game.master(owner, "inventory")
	for _, slot in ipairs(SLOTS) do
		if inv and weapon ~= nil and inv[slot] == weapon then return slot end
	end
	return nil
end

-- The hit that kills is cut to what kills: hitpoints travel as a small integer, and nothing in the
-- game expects a hit far past the end.
function M.health(original, unit, ...)
	local scale = scale_of(unit)
	local here = current
	if here and (here.unit ~= unit or here.priced) then here = nil end
	if not (scale or here) then return original(unit, ...) end
	local damage, zone, kills = original(unit, ...)
	if here then here.priced = true end
	if damage <= 0 then return damage, zone, kills end
	local state = game.global("EntityAux").state(unit, "health")
	if scale then
		local most = math.max(damage, state.hitpoints - state.constitution + 1)
		damage = math.min(damage * scale, most)
		kills = state.hitpoints - damage <= state.constitution
	end
	-- The master's own count: hitpoints catches up with it a frame later, and a volley lands in one.
	if here and here.fatal then
		local hp = state.hitpoints_real or state.hitpoints
		if hp - damage <= state.constitution then
			for _, entry in ipairs(fatal_list) do
				local ok, spare = pcall(entry.run, unit, damage)
				if ok and spare then
					damage, kills = math.max(hp - 1, 0), false
					break
				end
			end
		end
	end
	if here then here.damage = damage end
	return damage, zone, kills
end

local function command(master)
	return function(original, self, unit, ctx, name, data, ...)
		if name ~= "do_damage" or type(data) ~= "table" or (#hit_list == 0 and #fatal_list == 0)
			or (game.session_mode and not obsidian.session.cleared()) then
			return original(self, unit, ctx, name, data, ...)
		end
		local hitter = #hit_list > 0 and own_player(data.owner_unit)
		local fatal = master and #fatal_list > 0 and own_player(unit)
		if not (hitter or fatal) then return original(self, unit, ctx, name, data, ...) end
		local outer = current
		current = { unit = unit, fatal = fatal }
		local a, b, c = original(self, unit, ctx, name, data, ...)
		local done = current
		current = outer
		if hitter and done.damage and done.damage > 0 then
			local hit = { damage = done.damage, owner_unit = data.owner_unit, attacker_unit = data.attacker_unit,
				slot = slot_of(data.owner_unit, data.attacker_unit) }
			for _, entry in ipairs(hit_list) do
				local ok, err = pcall(entry.run, unit, hit)
				if not ok then obsidian.log("combat on_hit: " .. tostring(err)) end
			end
		end
		return a, b, c
	end
end
M.command_master = command(true)
M.filter_slave_command = command(false)

-- fn(victim, hit) for every hit a player of this machine lands that costs health, whichever machine
-- runs the victim. hit: damage, owner_unit (the player), attacker_unit (a weapon, a grenade, a
-- projectile...) and slot (primary_weapon, sidearm_weapon or support_weapon when attacker_unit is a
-- weapon in the player's inventory, else nil). Teammates and the player's own body count as victims too.
function M.on_hit(fn) return listen(hit_list, fn) end
function M.off_hit(fn) return unlisten(hit_list, fn) end

-- fn(unit, damage) for a hit that would kill a player of this machine. Answering true spares them: the
-- hit leaves them 1 hitpoint, or a downed player where they were. The first true wins.
function M.on_fatal(fn) return listen(fatal_list, fn) end
function M.off_fatal(fn) return unlisten(fatal_list, fn) end

function M.shield(original, unit, ...)
	local scale = scale_of(unit)
	if not scale then return original(unit, ...) end
	local damage, broken, extra = original(unit, ...)
	if damage <= 0 then return damage, broken, extra end
	damage = damage * scale
	local state = game.global("EntityAux").state(unit, "shield")
	return damage, state.shieldpoints - damage <= 0, extra
end

local function usable(value)
	return value == nil or value == false or (type(value) == "number" and value == value and value >= 0 and value <= MOST)
end

-- t: players, enemies. A multiplier from 0 to 100; 1 or false leaves that side alone, and a side
-- left out stays as it is.
function M.scale(t)
	if not (usable(t.players) and usable(t.enemies)) then return false, "out_of_range" end
	if t.players ~= nil then effects.set("damage_to_players", t.players ~= 1 and t.players) end
	if t.enemies ~= nil then effects.set("damage_to_enemies", t.enemies ~= 1 and t.enemies) end
	return true
end

return M
