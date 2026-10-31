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

-- The hit that kills is cut to what kills: hitpoints travel as a small integer, and nothing in the
-- game expects a hit far past the end.
function M.health(original, unit, ...)
	local scale = scale_of(unit)
	if not scale then return original(unit, ...) end
	local damage, zone, kills = original(unit, ...)
	if damage <= 0 then return damage, zone, kills end
	local state = game.global("EntityAux").state(unit, "health")
	local most = math.max(damage, state.hitpoints - state.constitution + 1)
	damage = math.min(damage * scale, most)
	return damage, zone, state.hitpoints - damage <= state.constitution
end

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
