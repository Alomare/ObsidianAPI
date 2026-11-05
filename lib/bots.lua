-- Bots: Helldivers this machine plays. A bot is a local co-op player on a pad nobody holds, joined
-- the way the host joins a second controller, so it has everything a player has: a HUD slot, a
-- name, revives, reinforcements. Its character reads an input table this file owns and refills
-- each frame. With every player record taken, a bot can be a bare Helldiver instead: a unit with no
-- record, no HUD and no respawn, for a body to fight beside or shoot at.
--
-- The input code skips a character with no pad, and its filter commands look the pad up in the pad
-- manager, so a pad number the game doesn't have is an error there. A bare bot takes a pad of the
-- game's that no player and no controller uses, and stands still when there's none left.
--
-- The input table copies the pad mapping in ControllerSettings, so each field has the type the
-- game's input code compares it as: an axis is a vector, a button a number from 0 to 1, a press or
-- a filter a boolean. A wrong type is an error inside the game's update, outside any pcall.
-- Vectors last one frame in this engine, so the table holds plain numbers and gets new vectors
-- right before the input component reads it, from a hook on its update: vectors made in the frame
-- callback are a frame old by then, and read as NaN.
local game = obsidian.module("lib/game")
local gear = obsidian.module("lib/gear")
local stratagems = obsidian.module("lib/stratagems")
local player = obsidian.module("lib/player")
local enemies = obsidian.module("lib/enemies")

local M = { list = {} }

local HELLDIVER = "characters/helldiver_private_01/helldiver_private_01"

-- What the input code reads besides the pad mapping: a vehicle seat reads these two, and the downed
-- states a held interact key, which only the keyboard maps (interact_button).
local EXTRA_NUMBERS = { "fire_button_primary_vehicle", "fire_button_secondary_vehicle", "interact_button" }
local VECTOR_FILTERS = { FilterVirtualAxis = true }

-- Pressing a button holds it for this many frames, so the game's update sees it whichever order it
-- runs in against this file's.
local PRESS_FRAMES = 2

local function blank_input()
	local numbers, flags, vectors = {}, {}, {}
	local settings = game.global("ControllerSettings")
	for _, entry in ipairs(settings and settings.pad or {}) do
		local name, kind = entry.output_name, entry.func
		if type(name) == "string" then
			if kind == "axis" or (kind == "filter" and VECTOR_FILTERS[entry.key]) then
				vectors[name] = true
			elseif kind == "button" then
				numbers[name] = true
			else
				flags[name] = true
			end
		end
	end
	-- A game without the mapping gets the fields its input code reads, by the same rule.
	if not next(numbers) then
		for _, n in ipairs({ "throw", "fire_button", "reload_button", "sprint_button", "dodge_button", "stratagems_button", "map_button" }) do numbers[n] = true end
		for _, n in ipairs({ "reload_pressed", "switch_weapon_down", "switch_weapon_up", "interact", "melee", "sprint_pressed", "dodge_pressed",
			"stratagems_pressed", "map_pressed", "stratagem_up", "stratagem_down", "stratagem_left", "stratagem_right" }) do flags[n] = true end
		for _, n in ipairs({ "move", "aim", "look" }) do vectors[n] = true end
	end
	for _, n in ipairs(EXTRA_NUMBERS) do numbers[n] = true end
	local t = { is_active = true }
	for n in pairs(numbers) do t[n] = 0 end
	for n in pairs(flags) do t[n] = false end
	return t, vectors
end

local Bot = {}
Bot.__index = Bot

local function v3(x, y, z)
	return game.global("Vector3")(x, y, z or 0)
end

-- The free record and pad for a new local player. A record is free when nothing owns its game
-- object and no joining player has it reserved. Pads are the game's own, minus any in use.
local function free_record(st)
	for i, r in ipairs(st.players) do
		if not r.player_go:exists() and not r.reserved and not r.occupied_time then return i end
	end
end

local function free_pad(st)
	local used = {}
	for _, r in ipairs(st.players) do
		if r.player_go:exists() and r.player_go:owned() then used[r.pad_number] = true end
	end
	for _, b in ipairs(M.list) do
		if b.kind == "bare" and b.pad and not b.removed then used[b.pad] = true end
	end
	local pads = game.global("PadManager")
	local keyboard = game.global("KEYBOARD_MOUSE_PAD_NUMBER")
	local count = type(game.global("Pads")) == "table" and #game.global("Pads") or 4
	for pad = 1, math.max(count, 4) do
		local active = pads and pads.is_pad_active and pads:is_pad_active(pad)
		if not used[pad] and pad ~= keyboard and not active then return pad end
	end
end

local function new_bot(kind, name)
	local input, vectors = blank_input()
	local b = setmetatable({ kind = kind, name = name, state = game.state(), input = input, vectors = vectors, axes = { move = { 0, 0 }, aim = { 0, 0 } }, presses = {}, goals = {},
		get_up = true, mash = 0, scan = 0 }, Bot)
	M.list[#M.list + 1] = b
	return b
end

-- A player record on the host, as the game joins a second controller. The name is what the record
-- keeps, from the user manager asked for this pad while it joins.
local function add_player(st, name)
	local index, pad = free_record(st), free_pad(st)
	if not (index and pad) then return nil end
	local um = game.global("UserManager")
	local real = um.get_name
	um.get_name = function(self, p, ...)
		if p == pad then return name end
		return real(self, p, ...)
	end
	local ok, err = pcall(st.rpc_add_local_player_accepted, st, game.global("Network").peer_id(), pad, index)
	um.get_name = real
	if not ok then
		obsidian.log("bots: join failed: " .. tostring(err))
		return nil
	end
	local b = new_bot("player", name)
	b.index, b.pad, b.record = index, pad, st.players[index]
	return b
end

-- A Helldiver with no record, from the spawn manager with a listener of its own, wearing the main
-- player's loadout.
local function add_bare(st, name, pos)
	local me = game.my_unit()
	local units = game.global("Unit")
	if not pos then
		if not me then return nil, "no_avatar" end
		local p = units.world_position(me, 0)
		-- Apart from each other, or their hellpods land in one spot.
		local others = 0
		for _, other in ipairs(M.list) do
			if other.kind == "bare" then others = others + 1 end
		end
		pos = v3(p.x + 3 + others * 3, p.y + 3, p.z)
	end
	if not st.spawn_manager then return nil, "not_in_mission" end
	local pad = free_pad(st)
	local b = new_bot("bare", name)
	b.pad = pad
	local settings = game.global("GameSettings")
	local main = settings.get_main_pad_number()
	local listener = {
		on_entity_spawned = function(_, unit)
			b.body = unit
			game.command(unit, "inventory", "loadout", { loadout_prefix = "loadout_", pad_number = main })
			local colors = settings.player_colors
			if colors and colors[2] then game.command(unit, "customization", "set_silhouette_color", colors[2]) end
		end,
		on_entity_spawn_inside_screen_failed = function()
			b.failed = true
		end,
	}
	st.spawn_manager:queue_spawn(HELLDIVER, v3(pos.x, pos.y, pos.z or 0), nil, listener, { player_index = 0 }, nil, true)
	return b
end

-- A new bot. opts: name (shown over its head and in the HUD), bare (true for a unit with no record,
-- false to refuse one when every record is taken), position (for a bare bot; next to the player by
-- default). The host or a player alone only: a client's local players join through the host.
function M.add(opts)
	opts = opts or {}
	if opts.name ~= nil and (type(opts.name) ~= "string" or opts.name == "" or #opts.name > 32) then return nil, "bad_type" end
	if not game.in_mission() then return nil, "not_in_mission" end
	if not game.is_host() then return nil, "host_only" end
	local st = game.state()
	if type(st) ~= "table" or type(st.players) ~= "table" or st.game_state == "game_over" then return nil, "not_in_mission" end
	local name = opts.name or ("Bot " .. (#M.list + 1))
	if opts.bare ~= true then
		local b = add_player(st, name)
		if b then return b end
		if opts.bare == false then return nil, "no_slot" end
	end
	return add_bare(st, name, opts.position)
end

-- The bot's unit while it's alive: a player bot has none in its hellpod or while dead.
function Bot:unit()
	if self.kind == "player" then
		local go = self.record and self.record.player_go
		if not (go and go:exists()) then return nil end
		return game.avatar(self.record)
	end
	local units = game.global("Unit")
	if self.body and units.alive(self.body) then return self.body end
	return nil
end

function Bot:alive()
	return self:unit() ~= nil
end

local function direction(dir)
	if dir == nil then return 0, 0 end
	local x, y = dir.x or dir[1] or 0, dir.y or dir[2] or 0
	local len = math.sqrt(x * x + y * y)
	if len > 1 then x, y = x / len, y / len end
	return x, y
end

-- Where to walk, as a world direction; its length is the speed, up to 1. nil stops.
function Bot:move(dir)
	self.goals.follow, self.goals.go_to = nil, nil
	self.axes.move[1], self.axes.move[2] = direction(dir)
	return self
end

-- A position kept as plain numbers: an engine vector lasts one frame.
local function point(pos)
	if pos == nil then return nil end
	return { x = pos.x or pos[1] or 0, y = pos.y or pos[2] or 0 }
end

-- Walk to a position and stop within distance (1.5 metres) of it. nil stops.
function Bot:go_to(pos, distance)
	self.goals.follow = nil
	self.goals.go_to = point(pos)
	if self.goals.go_to then self.goals.go_to.distance = distance or 1.5 end
	if not pos then self.axes.move[1], self.axes.move[2] = 0, 0 end
	return self
end

-- Stay where it stands: no following and no walking.
function Bot:hold()
	return self:move(nil)
end

-- Face a position, each frame, while fight has no target. nil stops.
function Bot:aim_at(pos)
	self.goals.aim_at = point(pos)
	return self
end

-- Where to face and shoot, as a world direction. nil lets it face where it walks.
function Bot:aim(dir)
	self.axes.aim[1], self.axes.aim[2] = direction(dir)
	return self
end

-- Holds the trigger until fire(false).
function Bot:fire(on)
	self.input.fire_button = on and 1 or 0
	self.fire_kept = nil
	return self
end

function Bot:firing()
	return self.input.fire_button == 1
end

function Bot:sprint(on)
	self.input.sprint_button = on and 1 or 0
	self.input.sprint_pressed = on and true or false
	return self
end

local function press(self, field)
	if self.input[field] == nil then return false end
	self.presses[field] = PRESS_FRAMES
	return true
end

function Bot:reload() press(self, "reload_pressed") return self end
function Bot:dodge() press(self, "dodge_pressed") return self end
function Bot:melee() press(self, "melee") return self end
function Bot:interact() press(self, "interact") return self end

-- A grenade: the throw button is held a moment and let go.
function Bot:throw()
	self.throw_frames = 10
	return self
end

-- The next weapon, as the pad's switch button does.
function Bot:switch()
	press(self, "switch_weapon_down")
	return self
end

-- Keep near a unit, a player's by default: walk to it when further than distance (6 metres).
function Bot:follow(unit, distance)
	self.goals.go_to = nil
	self.goals.follow = { unit = unit, distance = distance or 6 }
	return self
end

-- The radius it fights in, or false.
function Bot:fighting()
	return self.goals.fight and self.goals.fight.radius or false
end

-- Aim at and shoot the nearest enemy within radius (25 metres), each frame. false stops.
function Bot:fight(radius)
	if radius == false then
		self.goals.fight = nil
		self:fire(false)
	else
		self.goals.fight = { radius = radius or 25 }
	end
	return self
end

-- Gear and help, as api.gear, api.stratagems and api.player give them to the main player. Each answers
-- true, or false and a reason: "no_avatar" while the bot has no body.
-- Each of those takes the player last: n is how many arguments come before it. The modules are loaded
-- with this file: obsidian.module looks in the mod that's running, which is the caller's during a call.
local function with_unit(self, module, fn, n, ...)
	local unit = self:unit()
	if not unit then return false, "no_avatar" end
	local args = { ... }
	args[n + 1] = unit
	return module[fn](unpack(args, 1, n + 1))
end

function Bot:give_weapon(slot, path, upgrade) return with_unit(self, gear, "give_weapon", 3, slot, path, upgrade) end
function Bot:give_backpack(path, upgrade) return with_unit(self, gear, "give_backpack", 2, path, upgrade) end
function Bot:give_perk(name) return with_unit(self, gear, "give_perk", 1, name) end
function Bot:remove_perk() return with_unit(self, gear, "remove_perk", 0) end
function Bot:refill() return with_unit(self, gear, "refill", 0) end
function Bot:give_stratagem(name) return with_unit(self, stratagems, "give", 1, name) end
-- A real call-in of the bot's, at its upgrade level, as api.stratagems.call.
function Bot:call(name, pos, delay) return with_unit(self, stratagems, "call", 3, name, pos, delay) end
-- Up from downed and at full health, as api.player.heal.
function Bot:heal() return with_unit(self, player, "heal", 0) end
function Bot:teleport(pos) return with_unit(self, player, "teleport", 1, pos) end

-- The stratagems in the bot's slots: { name, id, uses_left, cooldown, ready } each. uses_left is nil
-- for one with no limit, and cooldown the seconds left before it can be called again.
function Bot:stratagems()
	local unit = self:unit()
	local inv = unit and game.master(unit, "inventory")
	local settings = game.global("LoadoutSettings")
	local out = {}
	for _, entry in ipairs(inv and inv.stratagems or {}) do
		local s = settings and settings.stratagems and settings.stratagems[entry.id]
		if s then
			local cooldown = entry.cooldown_timer or 0
			local spent = entry.uses_left ~= nil and entry.uses_left <= 0
			out[#out + 1] = { name = s.name, id = s.id, uses_left = entry.uses_left, cooldown = cooldown,
				ready = cooldown <= 0 and not spent and not entry.blocked }
		end
	end
	return out
end

-- Calling a stratagem as a player does: the stratagem button held, the code's arrows pressed one at
-- a time, then the beacon thrown. Each step waits for the character's own state, so an arrow the game
-- missed or counted twice starts the code again instead of calling something else.
local STRATAGEM_TIME = 10   -- seconds before the whole call gives up
local OPEN_TIME = 1         -- for the menu to open: a bot in a vehicle seat never opens it
local ARROW_GAP = 0.06      -- between arrows; each one is pressed for a single frame
local ARROW_WAIT = 0.4      -- for the game to count an arrow, or to act on the last one
local TURN_TIME = 0.75      -- to face the throw before throwing anyway
local TRIES = 3             -- times the code is entered before "wrong_code"
local ARROWS = { "up", "down", "left", "right" }

local function in_state(cs, ...)
	for i = 1, select("#", ...) do
		local s = game.global(select(i, ...))
		if s ~= nil and cs.current_state == s then return true end
	end
	return false
end

-- The charge a mouse player gets aiming at a point this far away, as CharacterStateStratagemsThrow
-- works it out from the cursor.
local function charge_for(distance)
	return math.max(0, math.min(1, distance * distance * 0.015))
end

-- Enters the code of a stratagem the bot holds and throws the beacon toward pos. Answers true once
-- started, or false and a reason: "no_avatar", "no_position", "not_available" (no such stratagem),
-- "not_held" (not in its slots), "cooling_down", "no_uses", "busy" (already calling one). on_done(ok,
-- reason) hears how it ended: true once the beacon is thrown, or false and "jammed" (a no-stratagem
-- zone), "refused" (the game wouldn't call it), "wrong_code", "interrupted" (downed, knocked down, or
-- a vehicle seat), "cancelled", "no_avatar" or "timeout". While it runs the bot stands, faces pos and
-- holds fire, and its other orders wait.
function Bot:use_stratagem(name, pos, on_done)
	if self.job then return false, "busy" end
	local unit = self:unit()
	if not unit then return false, "no_avatar" end
	pos = point(pos)
	if not pos then return false, "no_position" end
	local settings = game.global("LoadoutSettings")
	local held
	for _, h in ipairs(self:stratagems()) do
		if h.name == name then held = h end
	end
	if not held then
		for _, s in ipairs(settings and settings.stratagems or {}) do
			if s.name == name then return false, "not_held" end
		end
		return false, "not_available"
	end
	local s = settings.stratagems[held.id]
	if not (type(s.combo) == "table" and #s.combo > 0) then return false, "not_available" end
	if held.uses_left ~= nil and held.uses_left <= 0 then return false, "no_uses" end
	if not held.ready then return false, "cooling_down" end
	self.job = { name = s.name, id = s.id, combo = s.combo, pos = pos, on_done = on_done, phase = "open", time = 0, total = 0, step = 0, tries = 0, wait = 0 }
	return true
end

-- The stratagem the bot is calling and the step it's at ("open", "code", "throw"), or false.
function Bot:using_stratagem()
	if not self.job then return false end
	return self.job.name, self.job.phase
end

-- Stops a call. A beacon already in hand goes back, as a melee press does for a player.
function Bot:cancel_stratagem()
	if not self.job then return false end
	self.job.cancel = true
	return true
end

local function finish(b, ok, why)
	local job = b.job
	b.job = nil
	if job and type(job.on_done) == "function" then
		local fine, err = pcall(job.on_done, ok, why)
		if not fine then obsidian.log("bots: on_done: " .. tostring(err)) end
	end
end

-- One frame of a call, after think: it writes over the input table, and leaves the orders as they are.
local function stratagem_step(b, unit, t)
	local job = b.job
	local dt = rawget(_G, "ENGINE_DT") or 0.016
	job.time, job.total = job.time + dt, job.total + dt
	local cs = game.master(unit, "character") or {}
	if cs.stratagems_queue then stratagems.bot_queues[cs.stratagems_queue] = true end
	local menu = in_state(cs, "CharacterStateStratagems", "CharacterStateDownedStratagems")
	local throwing = in_state(cs, "CharacterStateStratagemsThrow", "CharacterStateDownedStratagemsThrow")

	t.fire_button, t.throw, t.stratagems_button, t.stratagems_pressed = 0, 0, 0, false
	for _, d in ipairs(ARROWS) do t["stratagem_" .. d] = false end
	t.melee = false
	b.axes.move[1], b.axes.move[2] = 0, 0
	local units = game.global("Unit")
	local here = units.world_position(unit, 0)
	local dx, dy = job.pos.x - here.x, job.pos.y - here.y
	b.axes.aim[1], b.axes.aim[2] = direction({ x = dx, y = dy })
	local function hold_menu() t.stratagems_button, t.stratagems_pressed = 1, true end

	if job.cancel then
		if throwing and not cs.has_thrown then t.melee = true end
		return finish(b, false, "cancelled")
	end
	if job.total > STRATAGEM_TIME then return finish(b, false, "timeout") end

	if job.phase == "open" then
		hold_menu()
		if menu then
			job.phase, job.time, job.step, job.wait = "code", 0, 0, ARROW_GAP
		elseif job.time > OPEN_TIME then
			return finish(b, false, "interrupted")
		end
	elseif job.phase == "code" then
		if throwing then
			job.phase, job.time = "throw", 0
			job.charge = charge_for(math.sqrt(dx * dx + dy * dy))
		elseif not menu then
			return finish(b, false, "interrupted")
		elseif cs.stratagems_disabled then
			return finish(b, false, "jammed")
		else
			hold_menu()
			local queue = cs.stratagems_queue or {}
			local wrong = #queue > job.step
			for i = 1, math.min(#queue, job.step) do
				if queue[i] ~= job.combo[i] then wrong = true end
			end
			if wrong then
				t.stratagems_button, t.stratagems_pressed = 0, false
				job.phase, job.time = "release", 0
			elseif #queue < job.step or job.step == #job.combo then
				-- Waiting for the game to count the arrow, or to call the stratagem the code makes.
				if job.time > ARROW_WAIT then
					if job.step == #job.combo then return finish(b, false, "refused") end
					t.stratagems_button, t.stratagems_pressed = 0, false
					job.phase, job.time = "release", 0
				end
			else
				job.wait = job.wait - dt
				if job.wait <= 0 then
					job.step = job.step + 1
					t["stratagem_" .. job.combo[job.step]] = true
					job.wait, job.time = ARROW_GAP, 0
				end
			end
		end
	elseif job.phase == "release" then
		-- The menu closes with the button let go, and opens with an empty code.
		if not menu then
			job.tries = job.tries + 1
			if job.tries >= TRIES then return finish(b, false, "wrong_code") end
			job.phase, job.time = "open", 0
		elseif job.time > OPEN_TIME then
			return finish(b, false, "interrupted")
		end
	elseif job.phase == "throw" then
		if not throwing then
			if job.thrown then return finish(b, true) end
			return finish(b, false, "interrupted")
		end
		if cs.has_thrown then
			job.thrown = true
		elseif not job.held then
			-- The throw goes where the body faces, so the bot turns first.
			local faced = true
			local quat = game.global("Quaternion")
			if units.world_rotation and quat and quat.forward then
				local f = quat.forward(units.world_rotation(unit, 0))
				local len = math.sqrt(dx * dx + dy * dy)
				faced = len < 0.5 or (f.x * dx + f.y * dy) / len > 0.97
			end
			if faced or job.time > TURN_TIME then
				job.held = true
				t.throw = 1
			end
		elseif (cs.grenade_charge or 0) < job.charge then
			t.throw = 1
		end
	end
end

-- The weapons it holds, as api.gear.weapons_of.
function Bot:weapons()
	local unit = self:unit()
	if not unit then return {} end
	return gear.weapons_of(unit)
end

-- Helping the squad, the game's own ways: getting up from downed, helping a downed Helldiver up, and
-- the REP-80's heal beam.
--
-- A downed Helldiver gets up after 30 presses of interact (10 with the perk that shortens it), and the
-- count goes back to 0 after a second with none. The keyboard's held key counts one press each 0.12 s.
-- The game lets a downed player up only while the body is on the screen: off it, the count stops one
-- short (CharacterComponent.update_masters).
-- Helping up: a standing Helldiver's interact looks for something to use in a short capsule 0.6 metres
-- ahead of the body, and a downed Helldiver is one; the press plays the help-up and the downed player
-- gets up at 75 hitpoints (InteractableCharacterComponent, InteractorComponent).
-- The REP-80 heals while fire is held: it locks onto a healable unit within 30 degrees of where the
-- wielder faces and within range (12 metres, 18 upgraded), along a line of sight, and stays on it while
-- the target stays within range and 30 degrees (HealbeamComponent). The heal does nothing to a downed
-- Helldiver (HealthComponent "do_heal"), so a downed one needs a help up first.
local REACH = 0.9          -- metres from a downed body to stand before pressing interact
local PRESS_WAIT = 1.5     -- seconds after a press for the help-up to play
local REVIVE_TRIES = 4     -- presses before "no_help_up"
local REVIVE_TIME = 20     -- seconds before a help up gives up
local HEAL_TIME = 30       -- seconds before a heal gives up
local SWITCH_TRIES = 4     -- times the bot takes out the REP-80 before "no_switch"
local SWITCH_GAP = 0.5
local MASH_EVERY = 6       -- frames between presses while getting up, beside the held key
local SCAN_EVERY = 0.3     -- seconds between looks for someone to help
local NEAREST = 30         -- metres revive() and heal_target() look within, given no unit
local AUTO_HEAL_BELOW = 0.8 -- the share of health under which auto_heal starts on someone
local HEAL_SLOTS = { "support_weapon", "primary_weapon", "sidearm_weapon" }

local function health(unit)
	local aux = game.global("EntityAux")
	if not (unit and aux and aux.state) then return nil end
	local ok, h = pcall(aux.state, unit, "health")
	return ok and type(h) == "table" and h or nil
end

local function alive(unit)
	return unit ~= nil and game.global("Unit").alive(unit)
end

local function is_downed(unit)
	local h = health(unit)
	return h ~= nil and h.is_downed == true and not h.is_dead
end

-- Hurt and standing: below share of the most it can have (below full when share is nil).
local function is_hurt(unit, share)
	local h = health(unit)
	if not h or h.is_dead or h.is_downed then return false end
	local hp, most = tonumber(h.hitpoints), tonumber(h.max_hitpoints)
	if not (hp and most and most > 0) then return false end
	return hp < most * (share or 1) - 0.5
end

local function flat(a, b)
	local units = game.global("Unit")
	local p, q = units.world_position(a, 0), units.world_position(b, 0)
	local dx, dy = q.x - p.x, q.y - p.y
	return dx, dy, math.sqrt(dx * dx + dy * dy)
end

-- Whether the body faces along dx, dy within the angle whose cosine is cos_min. True when the game
-- gives no rotation to read.
local function faces(unit, dx, dy, cos_min)
	local units, quat = game.global("Unit"), game.global("Quaternion")
	if not (units.world_rotation and quat and quat.forward) then return true end
	local ok, f = pcall(function() return quat.forward(units.world_rotation(unit, 0)) end)
	if not ok or type(f) ~= "table" then return true end
	local len = math.sqrt(dx * dx + dy * dy)
	return len < 0.3 or (f.x * dx + f.y * dy) / len > cos_min
end

-- Every Helldiver in the mission but `except`: players (bots on records among them), then bare bots.
local function squad(except)
	local out, seen = {}, {}
	local function add(u)
		if u and u ~= except and not seen[u] then
			seen[u] = true
			out[#out + 1] = u
		end
	end
	for _, p in ipairs(game.all_avatars()) do add(p.unit) end
	for _, b in ipairs(M.list) do
		if b.kind == "bare" then add(b:unit()) end
	end
	return out
end

local function nearest(unit, radius, wanted)
	local best, best_d = nil, radius
	for _, other in ipairs(squad(unit)) do
		if wanted(other) then
			local _, _, d = flat(unit, other)
			if d <= best_d then best, best_d = other, d end
		end
	end
	return best
end

-- The REP-80 among the bot's weapons: the slot, the weapon and the heal beam's state.
local function heal_tool(unit)
	local inv = game.master(unit, "inventory")
	if not inv then return nil end
	for _, slot in ipairs(HEAL_SLOTS) do
		local w = inv[slot]
		if alive(w) then
			local beam = game.master(w, "healbeam")
			if beam then return slot, w, beam end
		end
	end
	return nil
end

-- Takes out the weapon in a slot as the game does for a carried objective. A slot with no weapon is an
-- assert in the game, so it's checked first.
local function wield(unit, slot)
	local inv = game.master(unit, "inventory")
	if not (inv and slot and alive(inv[slot])) then return false end
	if inv.current_weapon == inv[slot] then return true end
	return game.command(unit, "inventory", "wield", { force = true, weapon = slot })
end

local function current_slot(unit)
	local inv = game.master(unit, "inventory")
	if not inv then return nil end
	for _, slot in ipairs(HEAL_SLOTS) do
		if inv[slot] ~= nil and inv[slot] == inv.current_weapon then return slot end
	end
	return nil
end

local function end_task(b, ok, why)
	local task = b.task
	b.task = nil
	if not task then return end
	-- A heal goes back to the weapon the bot held before it.
	local unit = b:unit()
	if task.before and unit then wield(unit, task.before) end
	if type(task.on_done) == "function" then
		local fine, err = pcall(task.on_done, ok, why)
		if not fine then obsidian.log("bots: on_done: " .. tostring(err)) end
	end
end

local function start_task(b, kind, target, on_done, auto)
	if b.task then end_task(b, false, "cancelled") end
	b.task = { kind = kind, unit = target, on_done = on_done, auto = auto, time = 0, wait = 0, tries = 0, turn = 0 }
	return true
end

-- Walks to a downed Helldiver and helps them up: the bot stands by the body, turns to it and presses
-- interact. unit: the downed Helldiver, or nil for the nearest one within 30 metres. Answers true once
-- started, or false and a reason: "no_avatar", "downed" (the bot is downed itself), "busy" (calling a
-- stratagem), "no_one_downed" (no one downed near), "not_downed", "self". on_done(ok, reason) hears how it
-- ended: true once they're up, or false and "dead", "downed", "no_help_up" (presses that did nothing),
-- "timeout" or "cancelled". While it runs, the bot's other orders wait.
function Bot:revive(unit, on_done)
	local me = self:unit()
	if not me then return false, "no_avatar" end
	if self.job then return false, "busy" end
	if is_downed(me) then return false, "downed" end
	if unit == nil then
		unit = nearest(me, NEAREST, is_downed)
		if not unit then return false, "no_one_downed" end
	end
	if unit == me then return false, "self" end
	if not (alive(unit) and is_downed(unit)) then return false, "not_downed" end
	return start_task(self, "revive", unit, on_done, false)
end

-- Heals a hurt Helldiver with the REP-80, as a player does: the bot takes the REP-80 out, walks within
-- range, faces the target and holds fire until they're at full health, then takes back the weapon it
-- held. unit: the Helldiver, or nil for the most hurt one within 30 metres. Answers true once started,
-- or false and a reason: "no_avatar", "downed", "busy", "no_heal_tool" (no REP-80 in the bot's slots),
-- "no_one_hurt" (no one hurt near), "not_hurt", "self". on_done(ok, reason): true at full health, or false
-- and "dead", "downed" (the target went down: help them up first), "no_ammo", "no_switch" (the REP-80
-- wouldn't come out), "timeout" or "cancelled".
function Bot:heal_target(unit, on_done)
	local me = self:unit()
	if not me then return false, "no_avatar" end
	if self.job then return false, "busy" end
	if is_downed(me) then return false, "downed" end
	if not heal_tool(me) then return false, "no_heal_tool" end
	if unit == nil then
		local worst, share = nil, 1
		for _, other in ipairs(squad(me)) do
			local h = health(other)
			local _, _, d = flat(me, other)
			if d <= NEAREST and is_hurt(other) then
				local s = h.hitpoints / h.max_hitpoints
				if s < share then worst, share = other, s end
			end
		end
		if not worst then return false, "no_one_hurt" end
		unit = worst
	end
	if unit == me then return false, "self" end
	if not (alive(unit) and is_hurt(unit)) then return false, "not_hurt" end
	return start_task(self, "heal", unit, on_done, false)
end

-- What the bot is doing for someone: "revive" or "heal" and the unit, or false.
function Bot:helping()
	if not self.task then return false end
	return self.task.kind, self.task.unit
end

function Bot:stop_helping()
	if not self.task then return false end
	end_task(self, false, "cancelled")
	return true
end

-- Downed, the bot presses interact by itself until up: true by default. false leaves it down
-- for a teammate.
function Bot:auto_get_up(on)
	self.get_up = on ~= false
	return self
end

-- Helps up downed Helldivers within radius (15 metres) by itself, between other orders, while it
-- follows or fights. false stops.
function Bot:auto_revive(radius)
	if radius == false then
		self.goals.auto_revive = nil
	else
		self.goals.auto_revive = radius or 15
	end
	return self
end

-- Heals Helldivers under 80% health within radius (20 metres) by itself with the REP-80, when it
-- carries one. false stops.
function Bot:auto_heal(radius)
	if radius == false then
		self.goals.auto_heal = nil
	else
		self.goals.auto_heal = radius or 20
	end
	return self
end

-- The radius it helps in by itself: revive's and heal's, or false for each it doesn't.
function Bot:auto_helping()
	return self.goals.auto_revive or false, self.goals.auto_heal or false
end

-- Whether the bot is downed now.
function Bot:downed()
	local unit = self:unit()
	return unit ~= nil and is_downed(unit)
end

-- Starts a help up or a heal for someone within the radii, when the bot is free.
local function look_around(b, unit, dt)
	b.scan = b.scan - dt
	if b.scan > 0 or b.task or b.job then return end
	b.scan = SCAN_EVERY
	if is_downed(unit) then return end
	local revive_r, heal_r = b.goals.auto_revive, b.goals.auto_heal
	if revive_r then
		local target = nearest(unit, revive_r, is_downed)
		if target then return start_task(b, "revive", target, nil, true) end
	end
	if heal_r and heal_tool(unit) then
		local target = nearest(unit, heal_r, function(u) return is_hurt(u, AUTO_HEAL_BELOW) end)
		if target then return start_task(b, "heal", target, nil, true) end
	end
end

-- One frame of a help up or a heal: it writes the sticks into b.axes and the buttons into the input
-- table, over what think left there.
local function task_step(b, unit, t, dt)
	local task = b.task
	task.time, task.wait = task.time + dt, task.wait - dt
	local target = task.unit
	t.fire_button = 0
	b.axes.move[1], b.axes.move[2], b.axes.aim[1], b.axes.aim[2] = 0, 0, 0, 0
	if not alive(target) then return end_task(b, false, "dead") end
	local h = health(target)
	if h and h.is_dead then return end_task(b, false, "dead") end
	if is_downed(unit) then return end_task(b, false, "downed") end
	local dx, dy, d = flat(unit, target)
	local function walk() b.axes.move[1], b.axes.move[2] = direction({ x = dx, y = dy }) end
	-- Full length: a short stick reads as none inside the dead zone.
	local function face()
		if d > 0.01 then b.axes.aim[1], b.axes.aim[2] = dx / d, dy / d end
	end

	if task.kind == "revive" then
		if not is_downed(target) then return end_task(b, true) end
		if task.time > REVIVE_TIME then return end_task(b, false, "timeout") end
		if d > REACH then
			walk()
			task.turn = 0
			return
		end
		face()
		task.turn = task.turn + dt
		if task.wait <= 0 and (faces(unit, dx, dy, 0.8) or task.turn > 0.5) then
			if task.tries >= REVIVE_TRIES then return end_task(b, false, "no_help_up") end
			task.tries = task.tries + 1
			task.wait = PRESS_WAIT
			press(b, "interact")
			t.interact = true
		end
		return
	end

	-- A heal.
	if h and h.is_downed then return end_task(b, false, "downed") end
	if not is_hurt(target) then return end_task(b, true) end
	if task.time > HEAL_TIME then return end_task(b, false, "timeout") end
	local slot, tool, beam = heal_tool(unit)
	if not slot then return end_task(b, false, "no_heal_tool") end
	local inv = game.master(unit, "inventory")
	if inv.current_weapon ~= tool then
		if task.wait <= 0 then
			if task.tries >= SWITCH_TRIES then return end_task(b, false, "no_switch") end
			if task.before == nil then task.before = current_slot(unit) or false end
			task.tries = task.tries + 1
			task.wait = SWITCH_GAP
			wield(unit, slot)
		end
		return
	end
	if beam.rounds ~= nil and beam.rounds <= 0 then
		if (beam.num_mags or 0) <= 0 then return end_task(b, false, "no_ammo") end
		press(b, "reload_pressed")
		t.reload_pressed = true
		return
	end
	local info = beam.weapon_info or {}
	local range = tonumber(info.range) or 12
	if d > range * 0.75 then walk() end
	face()
	if d <= range and faces(unit, dx, dy, math.cos(math.rad(25))) then t.fire_button = 1 end
end

-- Downed, presses interact as a player mashes it, beside the held key the keyboard has, and lies still:
-- aiming moves a downed body to a state that doesn't read interact.
local function get_up_step(b, unit, t)
	t.interact_button = 0
	if not (b.get_up and is_downed(unit)) then
		b.mash = 0
		return
	end
	t.interact_button = 1
	b.mash = b.mash + 1
	if b.mash % MASH_EVERY == 0 then t.interact = true end
	t.fire_button = 0
	b.axes.aim[1], b.axes.aim[2] = 0, 0
end

function Bot:remove()
	local st = game.state()
	if self.kind == "player" then
		local go = self.record and self.record.player_go
		if type(st) == "table" and go and go:exists() and go:owned() and self.record.pad_number == self.pad then
			pcall(st.despawn_player, st, self.pad)
			-- The game remembers a pad that leaves, to bring it back; this one was never plugged in.
			if st.dropped_pads then st.dropped_pads[self.pad] = nil end
		end
	else
		local unit = self:unit()
		if unit and type(st) == "table" and st.entity_spawner then pcall(st.entity_spawner.despawn_entity, st.entity_spawner, unit) end
	end
	self.removed = true
	if self.job then finish(self, false, "cancelled") end
	if self.task then
		local task = self.task
		self.task = nil
		if type(task.on_done) == "function" then pcall(task.on_done, false, "cancelled") end
	end
	for i, b in ipairs(M.list) do
		if b == self then
			table.remove(M.list, i)
			break
		end
	end
	return true
end

function M.all()
	local out = {}
	for i, b in ipairs(M.list) do out[i] = b end
	return out
end

function M.remove_all()
	for _, b in ipairs(M.all()) do b:remove() end
end

-- The camera turns the sticks, so a world direction becomes a stick one by turning it back.
local function to_stick(x, y)
	local cm = game.global("CameraManager")
	local spin = cm and cm.follow_spin or 0
	if spin == 0 or (x == 0 and y == 0) then return x, y end
	local c, s = math.cos(-spin), math.sin(-spin)
	return x * c - y * s, x * s + y * c
end

local function think(b, unit)
	local units = game.global("Unit")
	local here = units.world_position(unit, 0)
	local go_to = b.goals.go_to
	if go_to then
		local dx, dy = go_to.x - here.x, go_to.y - here.y
		local d = math.sqrt(dx * dx + dy * dy)
		if d > go_to.distance then
			b.axes.move[1], b.axes.move[2] = dx / d, dy / d
		else
			b.axes.move[1], b.axes.move[2] = 0, 0
			b.goals.go_to = nil
		end
	end
	local aim_at = b.goals.aim_at
	if aim_at then
		b.axes.aim[1], b.axes.aim[2] = direction({ x = aim_at.x - here.x, y = aim_at.y - here.y })
	end
	local follow = b.goals.follow
	if follow then
		local target = follow.unit or game.my_unit()
		if target and units.alive(target) then
			local there = units.world_position(target, 0)
			local dx, dy = there.x - here.x, there.y - here.y
			local d = math.sqrt(dx * dx + dy * dy)
			if d > follow.distance then
				b.axes.move[1], b.axes.move[2] = dx / d, dy / d
			else
				b.axes.move[1], b.axes.move[2] = 0, 0
			end
		end
	end
	local fight = b.goals.fight
	if fight then
		local found = enemies.near(fight.radius, here)
		local target = found[1]
		if target then
			local p = units.world_position(target, 0)
			b.axes.aim[1], b.axes.aim[2] = direction({ x = p.x - here.x, y = p.y - here.y })
			b.input.fire_button = 1
		else
			b.input.fire_button = 0
		end
	end
end

-- Hands each bot's character its input table, with this frame's vectors, and runs follow and
-- fight. The game's input component reads input_data when its player has focus.
local function drive(b, unit)
	local input = game.master(unit, "input")
	if not input then return end
	if b.kind == "bare" then
		if not b.pad then return end
		input.pad_number = b.pad
	end
	local dt = rawget(_G, "ENGINE_DT") or 0.016
	local t = b.input
	-- Fire a task or getting up let go last frame is the orders' again.
	if b.fire_kept ~= nil then
		t.fire_button, b.fire_kept = b.fire_kept, nil
	end
	think(b, unit)
	-- A stratagem call, a task and getting up hold the sticks for their frames, so the orders' own come
	-- back after them.
	local move, aim = { b.axes.move[1], b.axes.move[2] }, { b.axes.aim[1], b.axes.aim[2] }
	local fire = t.fire_button
	for field, left in pairs(b.presses) do
		t[field] = left > 0
		b.presses[field] = left > 0 and left - 1 or nil
	end
	if b.throw_frames then
		t.throw = b.throw_frames > 1 and 1 or 0
		b.throw_frames = b.throw_frames > 1 and b.throw_frames - 1 or nil
	end
	local calling = b.job ~= nil
	if not calling then
		look_around(b, unit, dt)
		if b.task then task_step(b, unit, t, dt) end
		get_up_step(b, unit, t)
		if b.task or b.mash > 0 then
			calling = true
			if t.fire_button ~= fire then b.fire_kept = fire end
		end
	else
		t.interact_button = 0
		stratagem_step(b, unit, t)
	end
	for field in pairs(b.vectors) do t[field] = v3(0, 0, 0) end
	local mx, my = to_stick(b.axes.move[1], b.axes.move[2])
	t.move = v3(mx, my, 0)
	local ax, ay = to_stick(b.axes.aim[1], b.axes.aim[2])
	t.aim = v3(ax, ay, 0)
	if calling then
		b.axes.move[1], b.axes.move[2] = move[1], move[2]
		b.axes.aim[1], b.axes.aim[2] = aim[1], aim[2]
	end
	input.input_data = t
	input.has_focus = true
end

-- Each frame, from main.lua. A new game state starts with no bots, and a mission that's over loses
-- them before its results, so a bot never reaches the end screens or anyone's save.
function M.tick()
	if #M.list == 0 then return end
	local st, name = game.state()
	if name ~= "game" then
		M.list = {}
		return
	end
	local kept = {}
	for _, b in ipairs(M.list) do
		if b.state == st then kept[#kept + 1] = b end
	end
	M.list = kept
	if st.game_state == "game_over" then M.remove_all() end
end

-- Right before the game's input component reads its players' input.
function M.drive_all()
	for _, b in ipairs(M.all()) do
		local unit = b:unit()
		if unit then
			drive(b, unit)
		else
			if b.job then finish(b, false, "no_avatar") end
			if b.task then end_task(b, false, "no_avatar") end
		end
	end
end

-- A bare bot has no player record, so the HUD draws no name over it. This draws one the way the HUD
-- draws a player's: projected through the game's viewport, centred, a little above, in the body font.
-- The projection is x, depth, y: the height on the screen is its z, as the HUD reads it. Like the HUD's
-- names, these go when its plugins are off: the hide_hud effect, a mod's full-screen menu, cutscenes.
local NAME_COLOR = { 255, 200, 200, 200 }
local NAME_LAYER = 5

function M.draw_names(hud)
	local gui = hud and hud.hd_gui
	local cm = game.global("CameraManager")
	local viewport = cm and cm:get_viewport()
	if not (gui and viewport and hud.gui_metrics_cacher and hud.plugins_enabled) then return end
	local units, v3, color = game.global("Unit"), game.global("Vector3"), game.global("Color")
	local res = gui.screen_resolution or {}
	for _, b in ipairs(M.list) do
		local unit = b.kind == "bare" and b:unit()
		if unit then
			local at = viewport:world_to_viewport(units.world_position(unit, 0))
			local x, y = at.x, at.z
			if x > 0 and y > 0 and (not res.width or x < res.width) and (not res.height or y < res.height) then
				gui:set_current_font("body")
				gui:set_ignore_position_scale(true)
				local w, h = hud.gui_metrics_cacher:get_text_extents(gui, b.name, nil, nil, true)
				local scale = gui.ui_scale or 1
				local c = NAME_COLOR
				gui:text(b.name, v3(x + (-w * 0.5 + 6) * scale, y + (-h * 0.5 - 21) * scale, NAME_LAYER), color(c[1], c[2], c[3], c[4]))
				gui:set_ignore_position_scale(false)
			end
		end
	end
end

function M.install()
	-- Another script of the game defines an early Hud with an update of its own, which lua/hud/hud then
	-- writes over. A hook made before that would go with it.
	obsidian.on_require("lua/hud/hud", function()
		obsidian.hook("Hud", "update", function(original, self, ...)
			local r = { original(self, ...) }
			if #M.list > 0 then
				local ok, err = pcall(M.draw_names, self)
				if not ok and not M.names_failed then
					M.names_failed = true
					obsidian.log("bot names: " .. tostring(err))
				end
			end
			return unpack(r)
		end)
	end)
	obsidian.hook("InputComponent", "update_masters", function(original, ...)
		if #M.list > 0 then
			local ok, err = pcall(M.drive_all)
			if not ok and not M.failed then
				M.failed = true
				obsidian.log("bots: " .. tostring(err))
			end
		end
		return original(...)
	end)
end

return M
