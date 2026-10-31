-- Reaching the running game: the current state, the local player, and writes the game accepts.
-- Two rules from the game's own code shape this file. A queued command with an unknown name fails
-- an assert inside the game's update, where no pcall can catch it, so command() takes only names
-- listed here. A protected value written directly trips the game's tamper check, so protected()
-- goes through the game's own setter, and data edits refuse those keys (see edits.lua).
local M = { due = {} }

local function global(name)
	return rawget(_G, name)
end
M.global = global

local function set(text)
	local out = {}
	for word in string.gmatch(text, "%S+") do out[word] = true end
	return out
end

-- Every command the runtime sends, by component. A command missing here is refused.
local COMMANDS = {
	health = set("reset do_heal set_hitpoints armor set_invincible set_ignore_death_plane set_health_decay"),
	status = set("remove_all remove_status remove_statuses_by_element add_immunity_status add_immunity_element"),
	shield = set("set_shieldpoints set_shield_activated set_shield_info reset_shield_info"),
	character = set("infinite_stamina move_speed_sprint_max do_knockdown drop_carry exit_interact_objective set_throw_range_multiplier"),
	mover = set("position position_teleport move_speed acceleration deceleration ignore_slow keep_inside_screen destroy enable"),
	inventory = set("ammo_pickup set_grenades set_grenade_path set_stratagem_info broadcast_stratagem_cooldown set_stratagem_cooldown_multiplier receive_stratagem set_weapon set_perk set_item_upgrades set_backpack"),
	customization = set("set_customization enable_heavy_armor disable_heavy_armor set_visible communication_event set_silhouette_color"),
	enemy_target = set("enable disable"),
	exosuit_inventory = set("set_full_ammo"),
	stratagem = set("set_thrown_direction"),
	objective_defend_object = set("interact"),
	research_sample_pickup = set("interact"),
	show_on_map = set("show"),
}

-- The state object and its name, in every game state once the game has booted.
function M.state()
	local boot = global("Boot")
	local sm = type(boot) == "table" and boot.state_machine
	if not sm then return nil, nil end
	return sm:get_current_state(), sm:get_current_state_name()
end

function M.state_name()
	local _, name = M.state()
	return name
end

function M.in_mission()
	return M.state_name() == "game"
end

function M.on_ship()
	return M.state_name() == "menu"
end

-- Host of the lobby, or alone with no lobby at all.
function M.is_host()
	local lobby = M.lobby()
	if not lobby then return true end
	return lobby:is_host() == true
end

function M.lobby()
	local network = global("NetworkGlobal")
	return type(network) == "table" and network.lobby or nil
end

-- Nobody else in the lobby. With no way to tell, it answers no: the callers are the risky actions.
function M.alone()
	local lobby = M.lobby()
	if not lobby then return true end
	local ok, members = pcall(lobby.members, lobby)
	return ok and type(members) == "table" and #members <= 1
end

-- The local player's record. players[1] is the first player in the lobby, not this one.
function M.me(st)
	st = st or M.state()
	if type(st) ~= "table" or type(st.players) ~= "table" then return nil end
	local settings = global("GameSettings")
	local main = settings and settings.get_main_pad_number and settings.get_main_pad_number()
	local first, first_index
	for i, p in ipairs(st.players) do
		local go = p.player_go
		if go and go:owned() then
			if p.pad_number == main then return p, i end
			if not first then first, first_index = p, i end
		end
	end
	return first, first_index
end

-- The unit of a player record, when there is one and it's alive. A record in the ship has a
-- different game object type, so the field is checked first.
function M.avatar(rec)
	local go = rec and rec.player_go
	if not go or (go.has and not go:has("avatar_unit")) then return nil end
	local unit = go:get("avatar_unit")
	local units = global("Unit")
	if unit and units.alive(unit) then return unit end
	return nil
end

function M.my_unit()
	return M.avatar((M.me()))
end

function M.component(name)
	local aux = global("EntityAux")
	if not aux or not aux.get_component then return nil end
	return aux.get_component(name)
end

-- Everyone's units in this session: the local one first.
function M.all_avatars()
	local st = M.state()
	local out = {}
	if type(st) ~= "table" or type(st.players) ~= "table" then return out end
	for _, p in ipairs(st.players) do
		local go = p.player_go
		if go and go:exists() then
			local unit = M.avatar(p)
			if unit then out[#out + 1] = { unit = unit, record = p, owned = go:owned() } end
		end
	end
	return out
end

-- A vector as a table the game keeps across frames.
function M.box(v)
	return global("Vector3Aux").box({ x = 0, y = 0, z = 0 }, v)
end

function M.unbox(t)
	return global("Vector3Aux").unbox(t)
end

-- Queues a command on a unit this peer owns. Returns false when the game would have asserted.
function M.command(unit, component, command, data)
	local known = COMMANDS[component]
	if not (known and known[command]) then return false end
	local aux, units = global("EntityAux"), global("Unit")
	if not (unit and units.alive(unit) and aux.has_component_master(unit, component)) then return false end
	aux.queue_command_master(unit, component, command, data)
	return true
end

-- Writes a protected value through the game's own setter. Components that copy state only when
-- dirty need the flag as well, or the change never reaches the slave state.
function M.protected(component, state, key, value)
	local c = M.component(component)
	if not c then return false end
	c:set_protected(state, key, value)
	state.dirty = true
	return true
end

-- The master state of a component on a unit this peer owns.
function M.master(unit, component)
	local aux = global("EntityAux")
	if not unit or not aux.has_component_master(unit, component) then return nil end
	return aux.state_master(unit, component)
end

-- Unit -> context maps for a component, master or every peer's slave copy.
function M.masters(name)
	local st = M.state()
	local em = type(st) == "table" and st.entity_manager
	return em and em:get_master_entities(name) or {}
end

function M.slaves(name)
	local st = M.state()
	local em = type(st) == "table" and st.entity_manager
	return em and em:get_slave_entities(name) or {}
end

-- The mission under way adds nothing to the save. For anything that changes how a mission plays out.
-- A loader from before this exists runs an update of this mod too, so it's asked for by name.
function M.forfeit_progress()
	local forfeit = obsidian.session.forfeit_progress
	if forfeit then forfeit() end
end

-- Runs fn after this many frames, for work the game needs spread over frames.
function M.after(frames, fn)
	M.due[#M.due + 1] = { left = frames, fn = fn }
end

function M.tick()
	for i = #M.due, 1, -1 do
		local job = M.due[i]
		job.left = job.left - 1
		if job.left <= 0 then
			table.remove(M.due, i)
			local ok, err = pcall(job.fn)
			if not ok then obsidian.log("delayed step: " .. tostring(err)) end
		end
	end
end

-- Calls a console command of a component without the console: setup_console_plugin only builds a
-- table of closures. The first argument of each is the command line, split.
function M.plugin(owner, command, ...)
	if not (owner and owner.setup_console_plugin) then return nil end
	local map = owner:setup_console_plugin()
	local fn = map and map[command]
	if not fn then return nil end
	local args = { command, ... }
	return fn(args, table.concat(args, " "))
end

return M
