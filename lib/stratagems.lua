-- Stratagems: cooldowns, uses, call-in time and getting one without the arrows.
local game = obsidian.module("lib/game")
local effects = obsidian.module("lib/effects")
local edits = obsidian.module("lib/edits")
local catalog = obsidian.module("lib/catalog")

local M = { selected = nil }

local function my_unit()
	local unit = game.my_unit()
	if not unit then return nil, "no_avatar" end
	return unit
end

local function entries(unit)
	local inv = game.master(unit, "inventory")
	return inv and inv.stratagems or {}
end

effects.define({ id = "no_cooldown",
	apply = function(ctx)
		if ctx.unit then game.command(ctx.unit, "inventory", "set_stratagem_cooldown_multiplier", 0) end
	end,
	remove = function(ctx)
		if ctx.unit then game.command(ctx.unit, "inventory", "set_stratagem_cooldown_multiplier", 1) end
	end,
})

-- The inventory's own flag: no cooldowns, no uses spent, no grenades spent.
effects.define({ id = "free_stratagems",
	apply = function()
		local c = game.component("inventory")
		if c then c.infinite_ammo = true end
	end,
	remove = function()
		local c = game.component("inventory")
		if c then c.infinite_ammo = false end
	end,
})

-- The flare's flag gives a 0.01 s call-in. Never 0: at 0 the game cancels the stratagem.
effects.define({ id = "instant_call_in",
	apply = function()
		local c = game.component("stratagem")
		if c then c.infinite_ammo = true end
	end,
	remove = function()
		local c = game.component("stratagem")
		if c then c.infinite_ammo = false end
	end,
})

-- Hellpods drop only while their timer is above zero, so the shortest wait is a tiny one.
effects.define({ id = "fast_pods",
	frame = function()
		for _, ctx in pairs(game.masters("hellpod")) do
			local state = ctx.state
			if type(state.drop_time) == "number" and state.drop_time > 0.02 then state.drop_time = 0.01 end
		end
	end,
})

-- The game's one question about a no-stratagem zone. The hook in main.lua answers it, and the session
-- gate turns the hook off, so there's nothing to undo here.
effects.define({ id = "ignore_jammers", remove = function() end })

-- Any first arrow calls the chosen stratagem. The hook in main.lua reads selected.
effects.define({ id = "any_arrow" })

function M.find(original, queue)
	if effects.is_on("any_arrow") and M.selected and #queue > 0 then return M.selected end
	return original(queue)
end

-- id: the index in LoadoutSettings.stratagems.
function M.select(id)
	M.selected = id
	return true
end

function M.reset_cooldowns()
	local unit, why = my_unit()
	if not unit then return false, why end
	for _, s in ipairs(entries(unit)) do
		game.command(unit, "inventory", "set_stratagem_info", { id = s.id, cooldown_timer = 0 })
	end
	game.command(unit, "inventory", "broadcast_stratagem_cooldown")
	return true
end

function M.refill_uses()
	local unit, why = my_unit()
	if not unit then return false, why end
	for _, s in ipairs(entries(unit)) do
		if s.uses_left and s.loadout_info and s.loadout_info.num_uses then
			game.protected("inventory", s, "uses_left", s.loadout_info.num_uses)
		end
	end
	return true
end

-- Adds a stratagem to the eight slots, or gives a use back when the player has it.
function M.give(name)
	local unit, why = my_unit()
	if not unit then return false, why end
	local s = catalog.stratagem(name)
	if not s then return false, "not_available" end
	local has = false
	for _, entry in ipairs(entries(unit)) do
		if entry.id == s.id then has = true end
	end
	if has then
		game.command(unit, "inventory", "receive_stratagem", s.id)
	else
		local c = game.component("inventory")
		local map = c and c.setup_console_plugin and c:setup_console_plugin()
		if not (map and map.give_stratagem) then return false, "not_available" end
		map.give_stratagem({ "give_stratagem", name }, "give_stratagem " .. name)
	end
	return true
end

-- A field of a stratagem, at every upgrade level. Levels can set the field for themselves, and the
-- game applies them over the base, so an edit of the base alone would stop at the first of those.
function M.edit(name, field, value)
	local s = catalog.stratagem(name)
	if not s then return false, "not_available" end
	local opts = { also = {}, keep = "stratagem:" .. name }
	for _, f in ipairs(catalog.fields("stratagem")) do
		if f.path == field then
			opts.min, opts.max, opts.apply, opts.new = f.min, f.max, f.apply, f.opt
		end
	end
	for level, upgrade in ipairs(s.upgrades or {}) do
		if upgrade[field] ~= nil then opts.also[#opts.also + 1] = "upgrades." .. level .. "." .. field end
	end
	return edits.set_table(catalog.text(name), s, field, value, opts)
end

-- The flare the game's own timed drops use, in proving grounds and fortify objectives. The rest
-- follows from it as from a thrown one: the sound, the countdown, the patrol alert, and for Reinforce
-- the respawn. A stratagem refused in a no-stratagem zone goes back to its owner, if it has one.
local FLARE = "gameobjects/flare_01"

local function spawn_flare(s, pos, delay, owner, upgrade)
	local st = game.state()
	if not (game.in_mission() and st.entity_spawner) then return false, "not_in_mission" end
	local flare = st.entity_spawner:spawn_entity(FLARE, pos, game.global("Quaternion").identity(), nil,
		{ has_been_thrown = true, stratagem_id = s.id, extra_activation_time = delay, owner_unit = owner, upgrade_value = upgrade })
	game.command(flare, "stratagem", "set_thrown_direction", game.box(game.global("Vector3")(0, 0, 0)))
	return true
end

-- A real call-in at a position, delay seconds on top of its own, at the level the player owns. No
-- cooldown or use is spent.
function M.call(name, pos, delay)
	local unit, why = my_unit()
	if not unit then return false, why end
	if not pos then return false, "no_position" end
	local s = catalog.stratagem(name)
	if not s then return false, "not_available" end
	delay = delay or 0
	if type(delay) ~= "number" or delay ~= delay or delay < 0 or delay > 600 then return false, "out_of_range" end
	local inv = game.master(unit, "inventory")
	local owned = inv and inv.item_upgrades
	return spawn_flare(s, pos, delay, unit, owned and owned[s.name] or 0)
end

-- As the proving grounds do it: nobody's stratagem, at its base level.
function M.call_unowned(s, pos, delay)
	return spawn_flare(s, pos, delay or 0, nil, 0)
end

-- Sends a stratagem to a position with no flare and no call-in.
function M.drop(name, pos)
	local unit, why = my_unit()
	if not unit then return false, why end
	if not pos then return false, "no_position" end
	local s = catalog.stratagem(name)
	if not s then return false, "not_available" end
	if s.name == "stratagem_reinforce" then return false, "needs_flare" end
	local c = game.component("stratagem")
	if not c then return false, "not_in_mission" end
	local network, v3 = game.global("Network"), game.global("Vector3")
	c:spawn_stratagem_hellpod(network.peer_id(), pos, v3.forward(), s.id, 0, unit)
	c:trigger_rpc_event("rpc_activate_stratagem", pos, s.id, 0, unit)
	return true
end

return M
