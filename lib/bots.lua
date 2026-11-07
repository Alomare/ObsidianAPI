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
local vehicles = obsidian.module("lib/vehicles")

local M = { list = {} }

local HELLDIVER = "characters/helldiver_private_01/helldiver_private_01"

-- What the input code reads besides the pad mapping: the keyboard's vehicle buttons, which a pad's
-- triggers stand for, and the downed states' held interact key (interact_button), which only the
-- keyboard maps. switch_weapon_up is the pad's release of the switch button.
local EXTRA_NUMBERS = { "fire_button_primary_vehicle", "fire_button_secondary_vehicle", "interact_button" }
local EXTRA_FLAGS = { "switch_weapon_up" }
local VECTOR_FILTERS = { FilterVirtualAxis = true }

-- Weapon slots by the game's names, and the short names a mod may use.
local SLOTS = { primary_weapon = "primary_weapon", sidearm_weapon = "sidearm_weapon", support_weapon = "support_weapon",
	primary = "primary_weapon", sidearm = "sidearm_weapon", support = "support_weapon" }

-- Pressing a button holds it for this many frames, so the game's update sees it whichever order it
-- runs in against this file's.
local PRESS_FRAMES = 2

-- Seconds after a bot picks up a weapon or a backpack before it picks up another (see allow_interact).
local PICKUP_COOLDOWN = 20

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
	for _, n in ipairs(EXTRA_FLAGS) do
		if not (numbers[n] or vectors[n]) then flags[n] = true end
	end
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

-- The input table is built again each frame (see drive): orders keeps what the bot holds until told
-- otherwise, presses what it presses for a few frames.
local function new_bot(kind, name)
	local input, vectors = blank_input()
	local b = setmetatable({ kind = kind, name = name, state = game.state(), input = input, vectors = vectors,
		axes = { move = { 0, 0 }, aim = { 0, 0 } }, presses = {}, goals = {}, orders = { fire = false, fire2 = false, sprint = false },
		get_up = true, stuck = { time = 0, x = 0, y = 0, side = 1, side_time = 0 }, pickup_cd = PICKUP_COOLDOWN, pickup_until = 0 }, Bot)
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

-- A new bot. opts: name (shown over the bot's head and in the HUD), bare (true for a unit with no record,
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

-- The bot's unit while alive: a player bot has none in the hellpod or while dead.
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

-- Where to walk, as a world direction; the length is the speed, up to 1. nil stops.
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

-- Holds the trigger until fire(false). A fight order decides the trigger while there is one.
function Bot:fire(on)
	self.orders.fire = on and true or false
	self.input.fire_button = on and 1 or 0
	return self
end

function Bot:firing()
	return self.input.fire_button == 1
end

function Bot:sprint(on)
	self.orders.sprint = on and true or false
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

-- A grenade: the throw button is held a moment and let go, a short throw ahead. throw_at aims one. In a
-- vehicle seat it does nothing: that button fires the vehicle's second weapon there.
function Bot:throw()
	self.throw_frames = 10
	return self
end

-- The pad's switch button tapped: the primary weapon and the support weapon take turns, and the
-- sidearm goes back to the primary. wield(slot) takes out a chosen one.
-- The game's input reads a press with no release within 0.2 seconds as the button held, which takes
-- out the sidearm, and from the sidearm the support weapon (InputComponent.update_masters,
-- "toggle_sidearm"): a press alone swaps between those two without end. The press and the release go
-- in the same frame, which the game reads as a tap ("toggle_weapon").
function Bot:switch()
	if self.input.switch_weapon_down == nil or self.input.switch_weapon_up == nil then return self end
	self.presses.switch_weapon_down, self.presses.switch_weapon_up = 1, 1
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

-- Aim at and shoot the nearest enemy within radius (25 metres), each frame. false stops. opts, all
-- optional: weapon, a slot ("primary", "sidearm", "support" or the game's "primary_weapon" and so on) the
-- bot takes out and fights with, coming back to it after anything else it takes out; only, a function
-- given an enemy unit that answers true for the enemies to shoot (the rest are left alone); secondary,
-- true or a table to fire a vehicle seat's second weapon along with the first (the tank's machine gun,
-- the first exosuit's rockets). The rockets go only while the exosuit faces the target. As a table:
-- secondary.only, a function given an enemy unit that answers true for the enemies the second weapon is
-- for (the vehicle then also turns to them when only leaves them out); secondary.every, the seconds
-- between shots, one press each: 1 for the exosuit's rockets by default, held for the rest.
function Bot:fight(radius, opts)
	if radius == false then
		self.goals.fight = nil
		self:fire(false)
	else
		opts = type(opts) == "table" and opts or {}
		local secondary = nil
		if opts.secondary == true then
			secondary = {}
		elseif type(opts.secondary) == "table" then
			local every = tonumber(opts.secondary.every)
			secondary = { only = type(opts.secondary.only) == "function" and opts.secondary.only or nil,
				every = every and every == every and every >= 0 and every or nil }
		end
		self.goals.fight = { radius = radius or 25, weapon = SLOTS[opts.weapon], only = type(opts.only) == "function" and opts.only or nil,
			secondary = secondary }
	end
	return self
end

-- In a vehicle seat, holds the second trigger until fire_secondary(false): the tank's machine gun, an
-- exosuit's left arm, the first exosuit's grenades. On foot that button throws a grenade, so it does
-- nothing there.
function Bot:fire_secondary(on)
	self.orders.fire2 = on and true or false
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
-- The backpack's uses back to full, as api.gear.refill_backpack: the recoilless rifle's rockets, for one.
function Bot:refill_backpack() return with_unit(self, gear, "refill_backpack", 0) end
function Bot:give_stratagem(name) return with_unit(self, stratagems, "give", 1, name) end
-- A real call-in of the bot's, at the bot's upgrade level, as api.stratagems.call.
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
-- "not_held" (not in the bot's slots), "cooling_down", "no_uses", "busy" (already calling one). on_done(ok,
-- reason) hears how it ended: true once the beacon is thrown, or false and "jammed" (a no-stratagem
-- zone), "refused" (the game wouldn't call it), "wrong_code", "interrupted" (downed, knocked down, or
-- a vehicle seat), "cancelled", "no_avatar" or "timeout". While it runs the bot stands, faces pos and
-- holds fire, and the other orders wait.
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
	if not self.job or self.job.kind ~= nil then return false end
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

-- One frame of a call, after think: it writes over this frame's input table and sticks (f), and leaves
-- the orders as they are.
local function stratagem_step(b, unit, t, f, dt)
	local job = b.job
	job.time, job.total = job.time + dt, job.total + dt
	local cs = game.master(unit, "character") or {}
	if cs.stratagems_queue then stratagems.bot_queues[cs.stratagems_queue] = true end
	local menu = in_state(cs, "CharacterStateStratagems", "CharacterStateDownedStratagems")
	local throwing = in_state(cs, "CharacterStateStratagemsThrow", "CharacterStateDownedStratagemsThrow")

	t.fire_button, t.throw, t.stratagems_button, t.stratagems_pressed = 0, 0, 0, false
	for _, d in ipairs(ARROWS) do t["stratagem_" .. d] = false end
	t.melee, t.interact, t.interact_button = false, false, 0
	f.mx, f.my = 0, 0
	local units = game.global("Unit")
	local here = units.world_position(unit, 0)
	local dx, dy = job.pos.x - here.x, job.pos.y - here.y
	f.ax, f.ay = direction({ x = dx, y = dy })
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
-- count goes back to 0 after a second with none. The keyboard's held key counts one press each 0.12 s,
-- and while it's held the downed states count nothing else. The game lets a downed player up only
-- while the body is on the screen: off it, the count stops one short (CharacterComponent.update_masters).
-- Helping up: a standing Helldiver's interact looks for something to use in a short capsule 0.6 metres
-- ahead of the body, and a downed Helldiver is one; the press plays the help-up and the downed player
-- gets up at 75 hitpoints (InteractableCharacterComponent, InteractorComponent). The press goes to the
-- one thing the interactor picked ahead of the body, the highest priority and then the nearest, and an
-- item lying by the body can be that thing. Interact is read on foot (CharacterStateIdle, Walk, Aim,
-- AimWalk, Sprint, Reload), and CharacterStateInteract uses a press again while it runs.
-- The REP-80 heals while fire is held: it locks onto a healable unit within 30 degrees of where the
-- wielder faces and within range (12 metres, 18 upgraded), along a line of sight, and stays on it while
-- the target stays within range and 30 degrees (HealbeamComponent). The heal does nothing to a downed
-- Helldiver (HealthComponent "do_heal"), so a downed one needs a help up first.
-- A weapon taken out (the inventory's forced wield) while the body is downed, knocked down or in
-- another animation leaves it in a pose with no animation, so a bot changes weapons only standing calm.
local REACH = 0.9          -- metres from a downed body to stand before pressing interact
local NEAR_ENOUGH = 1.5    -- metres from which it presses anyway after a second of getting no closer
local PRESS_WAIT = 1.5     -- seconds after a press for the help-up to play
local REVIVE_TRIES = 4     -- presses before "no_help_up"
local PICK_TIME = 3        -- seconds facing the body for the interactor to pick it before "no_help_up"
local REVIVE_TIME = 20     -- seconds before a help up gives up
local HEAL_TIME = 30       -- seconds before a heal gives up
local SWITCH_TRIES = 4     -- times the bot takes out the REP-80 before "no_switch"
local SWITCH_GAP = 0.5
local REWIELD_TIME = 10    -- seconds the weapon to take back after a heal waits for the bot to stand calm
local SCAN_EVERY = 0.3     -- seconds between looks for someone to help
local NEAREST = 30         -- metres revive() and heal_target() look within, given no unit
local AUTO_HEAL_BELOW = 0.8 -- the share of health under which auto_heal starts on someone, by default
local AUTO_RETRY = 5       -- seconds after a help it started by itself failed before it tries that Helldiver again
local HELPER_NEAR = 1.6    -- metres: a downed bot with a teammate standing this close lies still
local THREAT = 10          -- metres: on the way to help, a fighting bot shoots enemies this close
local HEAL_SLOTS = { "support_weapon", "primary_weapon", "sidearm_weapon" }
local CALM = { "CharacterStateIdle", "CharacterStateWalk", "CharacterStateAim", "CharacterStateAimWalk", "CharacterStateSprint" }
-- A bot in one of these isn't free to help anyone: a seat, a carried objective, a use, the extraction.
local OCCUPIED = { "CharacterStateSeated", "CharacterStateCarry", "CharacterStateInteract", "CharacterStateInteractObjective",
	"CharacterStateExtract", "CharacterStateTeleport", "CharacterStateCutscene", "CharacterStateDialogue", "CharacterStateSleep",
	"CharacterStateDead", "CharacterStateMap" }
-- What a pickup swaps: taking one drops what the bot held in that slot, right there.
local PICKUPS = { weapon_pickup = true, backpack_pickup = true }

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

-- Where a unit's nose points on the ground, as a direction of length 1, or nil when the game gives no
-- rotation to read. The engine's type() calls a vector "vector3", so it's read by its fields.
local function forward_of(unit)
	local units, quat = game.global("Unit"), game.global("Quaternion")
	if not (units.world_rotation and quat and quat.forward) then return nil end
	local ok, x, y = pcall(function()
		local f = quat.forward(units.world_rotation(unit, 0))
		return f.x, f.y
	end)
	if not ok or type(x) ~= "number" or type(y) ~= "number" then return nil end
	local len = math.sqrt(x * x + y * y)
	if len < 1e-3 then return nil end
	return x / len, y / len
end

-- Whether the body faces along dx, dy within the angle whose cosine is cos_min. True when the game
-- gives no rotation to read.
local function faces(unit, dx, dy, cos_min)
	local fx, fy = forward_of(unit)
	if not fx then return true end
	local len = math.sqrt(dx * dx + dy * dy)
	return len < 0.3 or (fx * dx + fy * dy) / len > cos_min
end

-- The character's state, or nil when the game gives none to read (a body with no character master).
local function state_of(unit)
	local cs = game.master(unit, "character")
	if not (cs and cs.current_state ~= nil and game.global("CharacterStateIdle") ~= nil) then return nil end
	return cs
end

-- Standing calm, where a press of interact or a weapon taken out does what a player's does. True when
-- the game gives no state to read.
local function calm(unit)
	local cs = state_of(unit)
	return cs == nil or in_state(cs, unpack(CALM))
end

local function occupied(unit)
	local cs = state_of(unit)
	return cs ~= nil and in_state(cs, unpack(OCCUPIED))
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

-- The bot already helping a Helldiver in the way kind says ("revive" or "heal"), other than except.
local function helper_of(target, kind, except)
	for _, b in ipairs(M.list) do
		if b ~= except and b.task and b.task.kind == kind and b.task.unit == target then return b end
	end
	return nil
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

-- A REP-80 with something to heal with: rounds in it or a spare to reload.
local function heal_ready(unit)
	local _, _, beam = heal_tool(unit)
	if not beam then return false end
	return beam.rounds == nil or beam.rounds > 0 or (beam.num_mags or 0) > 0
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

-- The damage one hit of the weapon in a slot does to a target after armor, as api.gear.hurts answers it:
-- square, glancing and on the target's weak spot, 0 where it can't hurt it. slot: as wield takes it, or
-- nil for the weapon in hand. An enemy the rifle answers 0 for is one for the anti-tank weapon.
-- Answers the three numbers, or nil and "bad_slot", "no_avatar", "no_weapon" or "no_target".
function Bot:hurts(target, slot)
	local name = slot ~= nil and SLOTS[slot]
	if slot ~= nil and not name then return nil, "bad_slot" end
	local unit = self:unit()
	if not unit then return nil, "no_avatar" end
	local inv = game.master(unit, "inventory")
	local weapon = nil
	if inv then
		if name then weapon = inv[name] else weapon = inv.current_weapon end
	end
	if not alive(weapon) then return nil, "no_weapon" end
	return gear.hurts(weapon, target)
end

-- Takes out the weapon in a slot: "primary_weapon", "sidearm_weapon" or "support_weapon", or "primary",
-- "sidearm" or "support". The weapon comes out once the bot stands calm, within 10 seconds, and a help
-- or a use_weapon that starts meanwhile comes back to it afterwards. Answers true, or false and a reason:
-- "bad_slot", "no_avatar", "no_weapon" (nothing in that slot).
function Bot:wield(slot)
	local name = SLOTS[slot]
	if not name then return false, "bad_slot" end
	local unit = self:unit()
	if not unit then return false, "no_avatar" end
	local inv = game.master(unit, "inventory")
	if not (inv and alive(inv[name])) then return false, "no_weapon" end
	if self.task then
		self.task.after = name
	elseif self.job and self.job.kind == "weapon" then
		self.job.after = name
	elseif inv.current_weapon == inv[name] then
		self.rewield = nil
	else
		self.rewield = { slot = name, time = 0 }
	end
	return true
end

-- The slot of the weapon in the bot's hands ("primary_weapon", "sidearm_weapon" or "support_weapon"),
-- or nil.
function Bot:wielding()
	local unit = self:unit()
	return unit and current_slot(unit) or nil
end

local function end_task(b, ok, why)
	local task = b.task
	b.task = nil
	if not task then return end
	-- A heal goes back to the weapon the bot held before it, or to the one wield asked for meanwhile, once
	-- the bot stands calm (rewield_step).
	local back = task.after or task.before
	if back then b.rewield = { slot = back, time = 0 } end
	-- A help the bot started by itself that came to nothing waits before it tries that Helldiver again:
	-- an empty REP-80 or a target out of reach would otherwise take the REP-80 out and put it away
	-- again every few frames.
	if task.auto and not ok and task.unit ~= nil then
		b.blocked = b.blocked or setmetatable({}, { __mode = "k" })
		b.blocked[task.unit] = M.clock + (b.retry or AUTO_RETRY)
	end
	if type(task.on_done) == "function" then
		local fine, err = pcall(task.on_done, ok, why)
		if not fine then obsidian.log("bots: on_done: " .. tostring(err)) end
	end
end

local function start_task(b, kind, target, on_done, auto)
	if b.task then end_task(b, false, "cancelled") end
	-- A weapon still to take back from an earlier heal is the one this task goes back to. Getting into a
	-- vehicle changes no weapon, so a weapon waiting stays waiting.
	local before = nil
	if kind ~= "vehicle" then
		before = b.rewield and b.rewield.slot or nil
		b.rewield = nil
	end
	b.task = { kind = kind, unit = target, on_done = on_done, auto = auto, time = 0, wait = 0, tries = 0, turn = 0,
		near = 0, pick = 0, before = before }
	return true
end

-- Walks to a downed Helldiver and helps them up: the bot stands by the body, turns to it and presses
-- interact. unit: the downed Helldiver, or nil for the nearest one within 30 metres that no other bot is
-- helping. Answers true once started, or false and a reason: "no_avatar", "downed" (the bot is downed
-- itself), "seated" (in a vehicle seat), "busy" (calling a stratagem, throwing or using a weapon),
-- "no_one_downed" (no one downed near), "already_helped" (another bot is on the way to each one),
-- "not_downed", "self". on_done(ok, reason) hears how it ended: true once
-- they're up, or false and "dead", "downed", "no_help_up" (presses that did nothing), "timeout" or
-- "cancelled". While it runs, the bot's other orders wait, but a bot that fights shoots back at
-- enemies close by on the way.
function Bot:revive(unit, on_done)
	local me = self:unit()
	if not me then return false, "no_avatar" end
	if self.job then return false, "busy" end
	if is_downed(me) then return false, "downed" end
	if vehicles.seat_of(me) then return false, "seated" end
	if unit == nil then
		unit = nearest(me, NEAREST, function(u) return is_downed(u) and not helper_of(u, "revive", self) end)
		if not unit then
			if nearest(me, NEAREST, is_downed) then return false, "already_helped" end
			return false, "no_one_downed"
		end
	end
	if unit == me then return false, "self" end
	if not (alive(unit) and is_downed(unit)) then return false, "not_downed" end
	return start_task(self, "revive", unit, on_done, false)
end

-- Heals a hurt Helldiver with the REP-80, as a player does: the bot walks within range, takes the REP-80
-- out, faces the target and holds fire until they're at full health, then takes back the weapon it
-- held. unit: the Helldiver, or nil for the most hurt one within 30 metres that no other bot is healing.
-- Answers true once started, or false and a reason: "no_avatar", "downed", "seated", "busy", "no_heal_tool" (no
-- REP-80 in the bot's slots), "no_one_hurt" (no one hurt near), "already_helped", "not_hurt", "self".
-- on_done(ok, reason): true at full health, or false and "dead", "downed" (the target went down: help
-- them up first), "no_ammo", "no_switch" (the REP-80 wouldn't come out), "timeout" or "cancelled".
function Bot:heal_target(unit, on_done)
	local me = self:unit()
	if not me then return false, "no_avatar" end
	if self.job then return false, "busy" end
	if is_downed(me) then return false, "downed" end
	if vehicles.seat_of(me) then return false, "seated" end
	if not heal_tool(me) then return false, "no_heal_tool" end
	if unit == nil then
		local worst, share, taken = nil, 1, false
		for _, other in ipairs(squad(me)) do
			local h = health(other)
			local _, _, d = flat(me, other)
			if d <= NEAREST and is_hurt(other) then
				if helper_of(other, "heal", self) then
					taken = true
				else
					local s = h.hitpoints / h.max_hitpoints
					if s < share then worst, share = other, s end
				end
			end
		end
		if not worst then return false, taken and "already_helped" or "no_one_hurt" end
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
	if not (self.task and (self.task.kind == "revive" or self.task.kind == "heal")) then return false end
	end_task(self, false, "cancelled")
	return true
end

-- Vehicles. A Helldiver gets in when the game's interactor sends a use of the seat to the vehicle's owner,
-- which seats them if the seat is on and free (InteractorComponent.update_masters, SeatComponent "interact").
-- A press of interact picks the seat the body touches, from the right side (an exosuit only from behind);
-- a bot walks to the seat's door and asks for its seat by the interactor's "force_interaction", which
-- skips the picking and nothing else. Seated, interact asks the owner to let the Helldiver out
-- (CharacterStateSeated). A seat's guns turn to the aim stick and fire on the trigger, or on the second
-- trigger when the gun says so (StationaryWeaponComponent: fire_input_field "throw"). The driver of an
-- exosuit walks on the move stick and faces the aim stick; the APC and the bike speed up on the trigger,
-- slow on the second trigger and steer on the move stick; the tank destroyer drives a track on each stick
-- (VehicleComponent.update_masters).
local ENTER_REACH = 2.5    -- metres from a seat's door to stand before asking for the seat
local ENTER_WAIT = 3       -- seconds for the game to seat the bot after it asks
local ENTER_TRIES = 3      -- asks before "refused"
local ENTER_TIME = 30      -- seconds before an enter_vehicle gives up
local LEAVE_GAP = 1        -- seconds between presses of interact to get out
local LEAVE_TIME = 8       -- seconds of pressing before leave_vehicle gives up
local RIDE_EVERY = 0.5     -- seconds between looks at the seat of the Helldiver a bot rides along with
local RIDE_RETRY = 5       -- seconds after a ride along failed to get in before it tries again

-- The bot already on its way to a seat, other than except.
local function heading_to(vehicle, index, except)
	for _, b in ipairs(M.list) do
		if b ~= except and b.task and b.task.kind == "vehicle" and b.task.unit == vehicle and b.task.seat == index then return b end
	end
	return nil
end

-- The first free seat nobody is on the way to: one that doesn't steer, then the one that does.
local function free_seat(vehicle, except)
	local steering
	for _, s in ipairs(vehicles.seats(vehicle)) do
		if s.free and not heading_to(vehicle, s.index, except) then
			if not s.drives then return s.index end
			steering = steering or s.index
		end
	end
	return steering
end

-- Where a Helldiver stands to get into a seat: the seat's door node, or the vehicle itself.
local function door(vehicle, index)
	local units = game.global("Unit")
	local seat = vehicles.seat_settings(vehicle, index)
	if seat and seat.enter_node and units.node then
		local ok, pos = pcall(function() return units.world_position(vehicle, units.node(vehicle, seat.enter_node)) end)
		if ok and pos then return pos end
	end
	return units.world_position(vehicle, 0)
end

-- Asks the vehicle's owner for a seat, through the bot's interactor.
local function board(unit, vehicle, index)
	local seat = vehicles.seat_settings(vehicle, index)
	local units = game.global("Unit")
	if not (seat and seat.actor and units.actor) then return false end
	local ok, actor = pcall(units.actor, vehicle, seat.actor)
	if not ok or actor == nil then return false end
	return game.command(unit, "interactor", "force_interaction", { interactable_unit = vehicle, interactable_component = "seat", interactable_actor = actor })
end

-- Gets into a vehicle seat as a player does: the bot walks to the seat's door, stands and gets in. vehicle:
-- a unit from api.vehicles.near or api.vehicles.nearest. seat: the seat's index (api.vehicles.seats), or nil
-- for the first free seat no other bot is on the way to, a seat that doesn't steer before the one that
-- does. Answers true once started, or false and a reason: "no_avatar", "busy" (calling a stratagem,
-- throwing or using a weapon), "downed", "seated" (in a seat already: leave_vehicle first), "no_vehicle"
-- (a unit with no seats), "no_seat" (no such seat, or none free), "taken". on_done(ok, reason): true once
-- seated, or false and "taken" (someone else got in), "destroyed", "no_vehicle", "refused" (the game
-- wouldn't seat the bot), "downed", "timeout", "cancelled" or "no_avatar". While it runs the bot's other
-- orders wait, but a bot that fights shoots back at enemies close by on the way.
function Bot:enter_vehicle(vehicle, seat, on_done)
	if type(seat) == "function" and on_done == nil then seat, on_done = nil, seat end
	local me = self:unit()
	if not me then return false, "no_avatar" end
	if self.job then return false, "busy" end
	if is_downed(me) then return false, "downed" end
	if vehicles.seat_of(me) then return false, "seated" end
	local seats = vehicles.seats(vehicle)
	if #seats == 0 then return false, "no_vehicle" end
	if seat == nil then
		seat = free_seat(vehicle, self)
		if not seat then return false, "no_seat" end
	elseif not seats[seat] then
		return false, "no_seat"
	elseif not seats[seat].free or heading_to(vehicle, seat, self) then
		return false, "taken"
	end
	self.leaving = nil
	start_task(self, "vehicle", vehicle, on_done, false)
	self.task.seat = seat
	return true
end

-- Gets out of the seat it sits in, with the interact press a player gets out with, again each second
-- until out (a seat lets no one out in its first moment). Answers true, or false and "no_avatar" or
-- "not_seated".
function Bot:leave_vehicle()
	local unit = self:unit()
	if not unit then return false, "no_avatar" end
	if self.task and self.task.kind == "vehicle" then end_task(self, false, "cancelled") end
	if not vehicles.seat_of(unit) then return false, "not_seated" end
	self.leaving = { time = 0, wait = 0 }
	return true
end

-- The vehicle the bot sits in and the seat's index, or nil.
function Bot:seat()
	local unit = self:unit()
	if not unit then return nil end
	return vehicles.seat_of(unit)
end

-- The vehicle and seat the bot is on its way to (enter_vehicle), or false.
function Bot:boarding()
	if not (self.task and self.task.kind == "vehicle") then return false end
	return self.task.unit, self.task.seat
end

-- Rides along with a Helldiver: when they sit in a vehicle with a seat free that doesn't steer, the bot
-- gets in (enter_vehicle), and once they're out it gets out of that vehicle too. on: true for the unit the
-- bot follows (the player when it follows no one), a unit, or false to stop (the default).
function Bot:ride_along(on)
	if on == false or on == nil then
		self.ride = nil
	else
		self.ride = { unit = on ~= true and on or nil, wait = 0, retry = 0 }
	end
	return self
end

-- Hits from the mech the bot pilots cost Helldivers no health while on is false, and for 2 seconds after
-- it gets out, for a shell still in the air. Every Helldiver counts, other players and bots alike, on any
-- machine: the game takes the lower of what the bot's machine and theirs work out. Enemies take the hits
-- as before. true, the game's own way, is the default.
function Bot:mech_friendly_fire(on)
	self.mech_spares = on == false or nil
	return self
end

-- Gets out of the line of an enemy about to shoot (api.enemies.charging: the Hunter's beam, the Cyborg
-- IFV's laser sight, the Hulk's wind-up): while the line runs within opts.width metres of the bot (2), it
-- walks straight out to the side it's on, and dives just before the shot if still in it. It looks at
-- enemies within opts.radius metres (40). opts.dodge: false to walk out only. Not in a seat, while
-- downed or while calling a stratagem or throwing. false stops (the default).
function Bot:avoid_shots(on, opts)
	if on == false or on == nil then
		self.goals.avoid = nil
	else
		opts = type(opts) == "table" and opts or {}
		local radius, width = tonumber(opts.radius), tonumber(opts.width)
		self.goals.avoid = { radius = radius and radius > 0 and radius or 40, width = width and width > 0 and width or 2,
			dodge = opts.dodge ~= false, wait = 0 }
	end
	return self
end

-- Whether the bot is getting out of a line now: true and the enemy, or false.
function Bot:avoiding()
	local a = self.goals.avoid
	if a and a.threat then return true, a.threat.enemy end
	return false
end

-- Downed, the bot holds interact by itself until up: true by default. false leaves it down for a
-- teammate, fighting from the ground with what it holds.
function Bot:auto_get_up(on)
	self.get_up = on ~= false
	return self
end

-- opts.retry of auto_revive and auto_heal: the seconds a help the bot started by itself and that came to
-- nothing waits before the bot tries that Helldiver again.
local function set_retry(b, opts)
	local retry = type(opts) == "table" and tonumber(opts.retry)
	if retry and retry >= 0 then b.retry = retry end
end

-- Helps up downed Helldivers within radius (15 metres) by itself, between other orders, while it
-- follows or fights. Of the bots that do, only the free one nearest to a downed Helldiver goes. false
-- stops. opts.retry: seconds before it tries again someone it failed to help up (5).
function Bot:auto_revive(radius, opts)
	if radius == false then
		self.goals.auto_revive = nil
	else
		self.goals.auto_revive = radius or 15
		set_retry(self, opts)
	end
	return self
end

-- Heals hurt Helldivers within radius (20 metres) by itself with the REP-80, when it carries one with
-- ammo, then takes back the weapon it held. One bot heals each Helldiver, the nearest free one. false
-- stops. opts.below: the share of health under which it starts on someone, from 0 to 1 (0.8, so under 80%
-- health). opts.retry: seconds before it tries again someone a heal failed on (5).
function Bot:auto_heal(radius, opts)
	if radius == false then
		self.goals.auto_heal = nil
	else
		self.goals.auto_heal = radius or 20
		local below = type(opts) == "table" and tonumber(opts.below)
		if below and below > 0 and below <= 1 then self.goals.heal_below = below end
		set_retry(self, opts)
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

-- After a bot picks up a weapon or a backpack, it picks up neither for this many seconds (20 by
-- default). Taking one drops what the bot held in that slot right there, so a bot that keeps pressing
-- interact would pick the dropped one up again, and so on. 0 or false lets it pick up at any time.
function Bot:pickup_cooldown(seconds)
	if seconds == false or seconds == nil then seconds = 0 end
	if type(seconds) ~= "number" or seconds ~= seconds or seconds < 0 then return self end
	self.pickup_cd = seconds
	if seconds == 0 then self.pickup_until = 0 end
	return self
end

-- Seconds left before the bot can pick up a weapon or a backpack again: 0 when it can now.
function Bot:next_pickup()
	return math.max(0, (self.pickup_until or 0) - (M.clock or 0))
end

M.clock = 0

local function bot_of(unit)
	if unit == nil then return nil end
	for _, b in ipairs(M.list) do
		if not b.removed and b:unit() == unit then return b end
	end
	return nil
end

-- Whether a press of interact by this unit goes ahead (CharacterComponent.handle_interact). A bot
-- helping someone up uses nothing but the body, and after a pickup that swaps (a weapon, a backpack)
-- a bot picks up no other for the pickup cooldown. Players are never stopped.
function M.allow_interact(unit)
	local b = bot_of(unit)
	if not b then return true end
	local ia = game.master(unit, "interactor")
	local target, comp = ia and ia.interactable_unit, ia and ia.interactable_component
	if b.task and b.task.kind == "revive" and target ~= nil and target ~= b.task.unit then return false end
	if b.task and b.task.kind == "use" and target ~= nil then
		if target ~= b.task.unit then return false end
		if comp and PICKUPS[comp] and (b.pickup_cd or 0) > 0 then b.pickup_until = M.clock + b.pickup_cd end
		return true
	end
	if comp and PICKUPS[comp] then
		if (b.pickup_until or 0) > M.clock then return false end
		if (b.pickup_cd or 0) > 0 then b.pickup_until = M.clock + b.pickup_cd end
	end
	return true
end

-- Who helps whom, every SCAN_EVERY seconds: each downed Helldiver gets the one free bot nearest to them
-- among the bots that help up by themselves and have them within their radius, then each hurt one the
-- nearest free bot with a REP-80, the most hurt first. A Helldiver a bot already helps gets no second
-- one. A bot is free when it calls no stratagem, helps no one, stands (not downed) and isn't in a seat,
-- carrying, using something or extracting.
local function assign(dt)
	M.scan = (M.scan or 0) - dt
	if M.scan > 0 then return end
	M.scan = SCAN_EVERY
	local free = {}
	for _, b in ipairs(M.list) do
		local unit = b:unit()
		if unit and (b.goals.auto_revive or b.goals.auto_heal) and not b.task and not b.job
			and not is_downed(unit) and not occupied(unit) and not vehicles.seat_of(unit) then
			free[#free + 1] = { bot = b, unit = unit }
		end
	end
	if #free == 0 then return end
	local function take(target, radius_of)
		local best, best_d, best_i = nil, nil, nil
		for i, c in ipairs(free) do
			local r = radius_of(c)
			local wait = c.bot.blocked and c.bot.blocked[target]
			if r and c.unit ~= target and not (wait and wait > M.clock) then
				local _, _, d = flat(c.unit, target)
				if d <= r and (best_d == nil or d < best_d) then best, best_d, best_i = c, d, i end
			end
		end
		if best then table.remove(free, best_i) end
		return best
	end
	local everyone = squad(nil)
	for _, target in ipairs(everyone) do
		if #free == 0 then return end
		if is_downed(target) and not helper_of(target, "revive") then
			local c = take(target, function(c) return c.bot.goals.auto_revive end)
			if c then start_task(c.bot, "revive", target, nil, true) end
		end
	end
	local hurt = {}
	for _, target in ipairs(everyone) do
		if is_hurt(target) and not helper_of(target, "heal") then
			local h = health(target)
			hurt[#hurt + 1] = { unit = target, share = h.hitpoints / h.max_hitpoints }
		end
	end
	table.sort(hurt, function(a, b) return a.share < b.share end)
	for _, entry in ipairs(hurt) do
		if #free == 0 then return end
		local c = take(entry.unit, function(c)
			local goals = c.bot.goals
			if goals.auto_heal and entry.share < (goals.heal_below or AUTO_HEAL_BELOW) and heal_ready(c.unit) then return goals.auto_heal end
		end)
		if c then start_task(c.bot, "heal", entry.unit, nil, true) end
	end
end

-- One frame of a use (Bot:use): walking within reach, then standing, facing the thing and pressing interact
-- once the game's interactor offers it, the way a player's press goes. The press took when the bot goes into
-- a state of using something (an interaction, a terminal, carrying, a seat), when the thing is gone (a
-- sample or an ammo box picked up), or when the interactor stops offering it to the bot standing there (a
-- hellbomb armed).
local USE_REACH = 1.2      -- metres to the thing before the bot stops: the interactor's capsule reaches about that far
local USE_LIMIT = 20       -- seconds before a use gives up
local USE_SETTLE = 1.5     -- seconds after a press for the game to show it took
local USE_PICK = 2         -- seconds the interactor may offer something else before "picked_other"
local IN_USE = { "CharacterStateInteract", "CharacterStateInteractObjective", "CharacterStateCarry", "CharacterStateSeated" }

local function use_step(b, unit, t, f, dt)
	local task = b.task
	local target = task.unit
	if not alive(target) then
		if task.pressed then return end_task(b, true, "used") end
		return end_task(b, false, "gone")
	end
	if is_downed(unit) then return end_task(b, false, "downed") end
	local cs = state_of(unit)
	if task.pressed and cs and in_state(cs, unpack(IN_USE)) then return end_task(b, true, "used") end
	if task.time > task.limit then return end_task(b, false, "timeout") end
	local dx, dy, d = flat(unit, target)
	if d > task.reach + 1 then task.close = false end
	if d > task.reach and not task.close then
		f.mx, f.my = direction({ x = dx, y = dy })
		if not (b.fight_target and b.fight_near) then t.fire_button, f.ax, f.ay = 0, 0, 0 end
		return
	end
	task.close = true
	t.fire_button, f.mx, f.my = 0, 0, 0
	if d > 0.01 then f.ax, f.ay = dx / d, dy / d end
	local ia = game.master(unit, "interactor")
	local offered = ia and ia.interactable_unit
	if task.pressed then
		if task.wait > 0 then return end
		if ia and offered ~= target then return end_task(b, true, "used") end
		if task.tries >= task.presses then return end_task(b, false, "no_effect") end
		task.pressed = false
	end
	if not calm(unit) then return end
	task.turn = task.turn + dt
	if not (faces(unit, dx, dy, 0.8) or task.turn > 0.5) then return end
	if ia and offered ~= target then
		task.pick = task.pick + dt
		if task.pick > USE_PICK then return end_task(b, false, offered ~= nil and "picked_other" or "not_offered") end
		-- A step toward the thing moves the capsule onto it.
		if d > 0.01 then f.mx, f.my = dx / d * 0.6, dy / d * 0.6 end
		return
	end
	task.pick = 0
	task.tries = task.tries + 1
	task.pressed, task.wait = true, USE_SETTLE
	press(b, "interact")
	t.interact = true
end

-- One frame of getting into a vehicle: walking to the seat's door, then asking for the seat standing
-- calm, again after ENTER_WAIT while the bot isn't seated.
local function vehicle_step(b, unit, t, f, dt)
	local task = b.task
	local v = task.unit
	if not alive(v) then return end_task(b, false, "no_vehicle") end
	local h = health(v)
	if h and h.is_dead then return end_task(b, false, "destroyed") end
	local now = vehicles.seat_of(unit)
	if now == v then return end_task(b, true) end
	if now then return end_task(b, false, "seated") end
	if is_downed(unit) then return end_task(b, false, "downed") end
	if task.time > ENTER_TIME then return end_task(b, false, "timeout") end
	local seat = vehicles.seats(v)[task.seat]
	if not seat then return end_task(b, false, "no_vehicle") end
	if seat.unit ~= nil and seat.unit ~= unit then return end_task(b, false, "taken") end
	local here, there = game.global("Unit").world_position(unit, 0), door(v, task.seat)
	local dx, dy = there.x - here.x, there.y - here.y
	local d = math.sqrt(dx * dx + dy * dy)
	if d > ENTER_REACH and task.tries == 0 then
		f.mx, f.my = direction({ x = dx, y = dy })
		if not (b.fight_target and b.fight_near) then t.fire_button, f.ax, f.ay = 0, 0, 0 end
		return
	end
	t.fire_button, f.mx, f.my, f.ax, f.ay = 0, 0, 0, 0, 0
	if task.wait > 0 or not calm(unit) then return end
	if task.tries >= ENTER_TRIES then return end_task(b, false, "refused") end
	task.tries, task.wait = task.tries + 1, ENTER_WAIT
	if not board(unit, v, task.seat) then return end_task(b, false, "refused") end
end

-- One frame of a help up or a heal: it writes this frame's sticks (f) and buttons (t), over what the
-- orders left there.
local function task_step(b, unit, t, f, dt)
	local task = b.task
	task.time, task.wait = task.time + dt, task.wait - dt
	if task.kind == "vehicle" then return vehicle_step(b, unit, t, f, dt) end
	if task.kind == "use" then return use_step(b, unit, t, f, dt) end
	local target = task.unit
	if not alive(target) then return end_task(b, false, "dead") end
	local h = health(target)
	if h and h.is_dead then return end_task(b, false, "dead") end
	if is_downed(unit) then return end_task(b, false, "downed") end
	local dx, dy, d = flat(unit, target)
	local function walk() f.mx, f.my = direction({ x = dx, y = dy }) end
	-- Full length: a short stick reads as none inside the dead zone.
	local function face()
		if d > 0.01 then f.ax, f.ay = dx / d, dy / d end
	end
	-- On the way, a bot that fights shoots back at enemies close by; otherwise it faces where it walks.
	local function on_the_way()
		if not (b.fight_target and b.fight_near) then
			t.fire_button = 0
			f.ax, f.ay = 0, 0
		end
	end

	if task.kind == "revive" then
		if not is_downed(target) then return end_task(b, true) end
		if task.time > REVIVE_TIME then return end_task(b, false, "timeout") end
		-- Close, and no closer for a second (bodies push each other apart): near enough to press.
		task.near = d <= NEAR_ENOUGH and task.near + dt or 0
		if d > REACH and task.near < 1 then
			walk()
			task.turn, task.pick = 0, 0
			if d > NEAR_ENOUGH + 1 then on_the_way() else t.fire_button, f.ax, f.ay = 0, 0, 0 end
			return
		end
		t.fire_button = 0
		face()
		task.turn = task.turn + dt
		if task.wait > 0 or not calm(unit) then return end
		if not (faces(unit, dx, dy, 0.8) or task.turn > 0.5) then return end
		-- The press goes to what the interactor picked: the body, not an item lying by it.
		local ia = game.master(unit, "interactor")
		if ia and ia.interactable_unit ~= nil and ia.interactable_unit ~= target then
			task.pick = task.pick + dt
			if task.pick > PICK_TIME then return end_task(b, false, "no_help_up") end
			-- A step toward the body moves the capsule onto it.
			if d > 0.01 then f.mx, f.my = dx / d * 0.6, dy / d * 0.6 end
			return
		end
		if task.tries >= REVIVE_TRIES then return end_task(b, false, "no_help_up") end
		task.tries = task.tries + 1
		task.wait = PRESS_WAIT
		press(b, "interact")
		t.interact = true
		return
	end

	-- A heal.
	if h and h.is_downed then return end_task(b, false, "downed") end
	if not is_hurt(target) then return end_task(b, true) end
	if task.time > HEAL_TIME then return end_task(b, false, "timeout") end
	local slot, tool, beam = heal_tool(unit)
	if not slot then return end_task(b, false, "no_heal_tool") end
	local info = beam.weapon_info or {}
	local range = tonumber(info.range) or 12
	local inv = game.master(unit, "inventory")
	if inv.current_weapon ~= tool then
		-- Into range with what it holds, then the REP-80 out, standing calm.
		if d > range then
			walk()
			on_the_way()
			return
		end
		t.fire_button, f.ax, f.ay = 0, 0, 0
		if task.wait <= 0 and calm(unit) then
			if task.tries >= SWITCH_TRIES then return end_task(b, false, "no_switch") end
			if task.before == nil then task.before = current_slot(unit) or false end
			task.tries = task.tries + 1
			task.wait = SWITCH_GAP
			wield(unit, slot)
		end
		return
	end
	t.fire_button = 0
	if beam.rounds ~= nil and beam.rounds <= 0 then
		if (beam.num_mags or 0) <= 0 then return end_task(b, false, "no_ammo") end
		f.ax, f.ay = 0, 0
		if calm(unit) and not b.presses.reload_pressed then
			press(b, "reload_pressed")
			t.reload_pressed = true
		end
		return
	end
	if d > range * 0.75 then walk() end
	face()
	if d <= range and faces(unit, dx, dy, math.cos(math.rad(25))) then t.fire_button = 1 end
end

-- A standing Helldiver, other than the unit itself, within HELPER_NEAR of it.
local function teammate_close(unit)
	for _, other in ipairs(squad(unit)) do
		if not is_downed(other) then
			local _, _, d = flat(unit, other)
			if d <= HELPER_NEAR then return true end
		end
	end
	return false
end

-- Downed, the bot lies still: a crawl, which walking orders would start, moves the body away from a
-- teammate coming to help and swaps the downed animations back and forth. Getting up by itself, it
-- holds interact as the keyboard's key does and doesn't aim: aiming moves a downed body to a state that
-- counts no presses. A bot on the way to help it up comes to a body that lies still for it. Left down
-- for a teammate, it fights from the ground with what it holds until one stands close.
local function downed_step(b, unit, t, f)
	f.mx, f.my = 0, 0
	local coming = helper_of(unit, "revive", b)
	if b.get_up and not (coming and teammate_close(unit)) then
		t.interact_button = 1
		t.fire_button, f.ax, f.ay = 0, 0, 0
	elseif not b.get_up and not teammate_close(unit) then
		return
	else
		t.fire_button, f.ax, f.ay = 0, 0, 0
	end
end

-- The weapon to take back after a heal, once the bot stands calm; given up after REWIELD_TIME.
local function rewield_step(b, unit, dt)
	local r = b.rewield
	r.time = r.time + dt
	if r.time > REWIELD_TIME or current_slot(unit) == r.slot then
		b.rewield = nil
		return
	end
	if not is_downed(unit) and calm(unit) then
		wield(unit, r.slot)
		b.rewield = nil
	end
end

-- Fighting: the nearest enemy in reach that a straight line from the bot reaches, looked for again each
-- LOOK_EVERY seconds, with the trigger held only while no Helldiver stands in the line of fire, since
-- friendly fire is always on. With no clear line to any, the bot faces the nearest and holds fire. An
-- empty magazine is reloaded.
local LOOK_EVERY = 0.25
local LINE_CHECKS = 4      -- enemies tried for a clear line, nearest first
local LINE_WIDTH = 1.1     -- metres either side of the line of fire where a Helldiver blocks it
local RELOAD_GAP = 1       -- seconds between reloads it presses
local RELOAD_HOLD = 0.3    -- seconds the trigger is let go around a reload it presses

-- Whether a weapon's ray from the bot's chest reaches the enemy before anything else: the game's damage
-- ray filter, the bot's own body skipped, and in a seat the vehicle and its guns (skip). True when the
-- game gives no physics to ask.
local function line_clear(unit, enemy, skip)
	local st = game.state()
	local pw = type(st) == "table" and st.world_proxy and st.world_proxy.get_physics_world and st.world_proxy:get_physics_world()
	local physics, actor_unit, v3 = game.global("PhysicsWorld"), game.global("Actor"), game.global("Vector3")
	if not (pw and physics and physics.immediate_raycast and actor_unit and v3) then return true end
	local units = game.global("Unit")
	local p, q = units.world_position(unit, 0), units.world_position(enemy, 0)
	local from, to = v3(p.x, p.y, p.z + 1.3), v3(q.x, q.y, q.z + 1)
	local length = v3.length(to - from)
	if length < 0.5 then return true end
	local ok, hits = pcall(physics.immediate_raycast, pw, from, v3.normalize(to - from), length, "all", "collision_filter", "damage_ray")
	if not ok or type(hits) ~= "table" then return true end
	local first, first_unit = nil, nil
	for _, h in ipairs(hits) do
		local got, u = pcall(actor_unit.unit, h[4])
		u = got and u or nil
		if u ~= unit and not (skip and u ~= nil and skip[u]) and (first == nil or h[2] < first) then first, first_unit = h[2], u end
	end
	if first == nil or first_unit == enemy then return true end
	return first >= length - 0.75
end

-- No Helldiver but the bot between it and the point, within LINE_WIDTH of the line. Those sitting in the
-- bot's own vehicle (vehicle) sit beside its guns, not in front of them.
local function no_one_in_the_way(unit, here, x, y, vehicle)
	local dx, dy = x - here.x, y - here.y
	local len = math.sqrt(dx * dx + dy * dy)
	if len < 0.01 then return true end
	local ux, uy = dx / len, dy / len
	local units = game.global("Unit")
	for _, other in ipairs(squad(unit)) do
		if not (vehicle and vehicles.seat_of(other) == vehicle) then
			local o = units.world_position(other, 0)
			local ox, oy = o.x - here.x, o.y - here.y
			local along = ox * ux + oy * uy
			if along > 0.3 and along < len + 0.5 then
				local side = math.abs(ox * uy - oy * ux)
				if side < LINE_WIDTH then return false end
			end
		end
	end
	return true
end

local function weapon_state(weapon)
	local aux = game.global("EntityAux")
	if not (alive(weapon) and aux and aux.state_master_interface) then return nil end
	local ok, ws = pcall(aux.state_master_interface, weapon, "weapon")
	return ok and type(ws) == "table" and ws or nil
end

-- Whether a mod's only(enemy) picks the enemy. An error in it picks none, once in the log.
local function picks(b, only, enemy)
	local ok, yes = pcall(only, enemy)
	if not ok then
		if not b.only_failed then
			b.only_failed = true
			obsidian.log("bots: only: " .. tostring(yes))
		end
		return false
	end
	return yes and true or false
end

-- The trigger pulled as a player pulls it for the weapon in hand (t.fire_button). The game fires a
-- weapon that isn't fully automatic once as the trigger goes down (CharacterStateAimFire.on_enter), so a
-- held trigger fires it once: the bot pulls and lets go, PULL_FRAMES each. A weapon that fires on release
-- (the mortar) is held to half its charge and let go. In a seat the guns fire while it's held.
local PULL_FRAMES = 2

local function pull(b, unit, t)
	if b.in_seat then
		t.fire_button = 1
		return
	end
	local inv = game.master(unit, "inventory")
	local ws = inv and weapon_state(inv.current_weapon)
	b.pull = (b.pull or 0) + 1
	if ws and ws.fire_on_release then
		if (b.release or 0) > 0 then
			b.release = b.release - 1
			t.fire_button = 0
		elseif (tonumber(ws.shot_charge_timer) or 0) >= ((tonumber(ws.min_charge_time) or 0) + (tonumber(ws.max_charge_time) or 1)) / 2 then
			b.release = PULL_FRAMES + 1
			t.fire_button = 0
		else
			t.fire_button = 1
		end
	elseif ws and ws.fully_automatic == false then
		t.fire_button = (b.pull % (PULL_FRAMES * 2)) < PULL_FRAMES and 1 or 0
	else
		t.fire_button = 1
	end
end

-- What fight shoots at: the enemies within its radius that its only() picks, nearest first.
-- In a seat whose second weapon has a separate only(), the enemies that one picks count too.
local function targets(b, fight, here)
	local found = enemies.near(fight.radius, here)
	if not fight.only then return found end
	local seat = b.in_seat
	local second = seat and seat.secondary and fight.secondary and fight.secondary.only
	local out = {}
	for _, e in ipairs(found) do
		if picks(b, fight.only, e) or (second and picks(b, second, e)) then out[#out + 1] = e end
	end
	return out
end

-- An exosuit's rockets leave from the exosuit's front, so they go only within this of facing the target (about
-- 15 degrees), one each second unless secondary.every says otherwise. Other second weapons (the tank's
-- machine gun) turn on their own mounts.
local ROCKET_FACING = 0.966
local ROCKET_EVERY = 1

local function second_trigger(b, seat, fight, face, dx, dy, t)
	local second = fight.secondary
	if second.only and not picks(b, second.only, face) then return end
	if seat.kind == "exosuit" and not faces(seat.vehicle, dx, dy, ROCKET_FACING) then return end
	local every = second.every
	if every == nil and seat.kind == "exosuit" then every = ROCKET_EVERY end
	if not every or every == 0 then
		t.throw = 1
	elseif (b.second_wait or 0) <= 0 then
		t.throw = 1
		b.second_hold = PULL_FRAMES > 1 and PULL_FRAMES - 1 or nil
		b.second_wait = every
	end
end

-- In a seat with no gun (the APC's or the bike's driver, a passenger seat with none), the sticks and the
-- triggers drive or do nothing, so fight leaves them alone.
local function fight_step(b, unit, here, t, dt)
	local fight = b.goals.fight
	local seat = b.in_seat
	b.look = (b.look or 0) - dt
	if b.look <= 0 or (b.fight_target and not alive(b.fight_target)) then
		b.look = LOOK_EVERY
		b.fight_target, b.fight_face = nil, nil
		local found = targets(b, fight, here)
		for i = 1, math.min(#found, LINE_CHECKS) do
			if line_clear(unit, found[i], seat and seat.parts) then
				b.fight_target = found[i]
				break
			end
		end
		b.fight_face = b.fight_target or found[1]
	end
	local units = game.global("Unit")
	local face = b.fight_face
	if face and not alive(face) then face, b.fight_face = nil, nil end
	b.fight_near = false
	if seat and not seat.armed then return end
	-- A paced second weapon: one press, held a few frames, then the wait.
	b.second_wait = (b.second_wait or 0) - dt
	if b.second_hold then
		if seat then t.throw = 1 end
		b.second_hold = b.second_hold > 1 and b.second_hold - 1 or nil
	end
	t.fire_button = 0
	if face then
		local p = units.world_position(face, 0)
		b.axes.aim[1], b.axes.aim[2] = direction({ x = p.x - here.x, y = p.y - here.y })
		if b.fight_target == face then
			local dx, dy = p.x - here.x, p.y - here.y
			b.fight_near = dx * dx + dy * dy <= THREAT * THREAT
			if no_one_in_the_way(unit, here, p.x, p.y, seat and seat.vehicle) then
				if (not seat or seat.primary) and (not seat or not fight.only or picks(b, fight.only, face)) then pull(b, unit, t) end
				if seat and seat.secondary and fight.secondary then second_trigger(b, seat, fight, face, dx, dy, t) end
			end
		end
	end
end

-- The weapon fight keeps in hand (fight's opts.weapon): taken out standing calm, while nothing else
-- needs another weapon out, a second apart at most.
local KEEP_GAP = 1

local function keep_weapon(b, unit, dt)
	local slot = b.goals.fight and b.goals.fight.weapon
	if not slot or b.task or b.job or b.rewield or b.in_seat then return end
	b.keep_wait = (b.keep_wait or 0) - dt
	if b.keep_wait > 0 then return end
	local inv = game.master(unit, "inventory")
	if not (inv and alive(inv[slot])) or inv.current_weapon == inv[slot] then return end
	if is_downed(unit) or not calm(unit) then return end
	b.keep_wait = KEEP_GAP
	wield(unit, slot)
end

-- Whether a straight line from the bot's chest reaches the unit before anything else does: a wall, a
-- rock, another body. In a seat, the bot's own vehicle and its guns don't count. True when the game gives
-- no physics to ask.
function Bot:sees(target)
	local unit = self:unit()
	if not (unit and alive(target)) then return false end
	return line_clear(unit, target, self.in_seat and self.in_seat.parts)
end

-- Living enemies within radius (25 metres) that the bot sees, nearest first. only: a function given an
-- enemy unit that answers true for the ones to count, or nil for all. Each enemy costs a ray, so a mod
-- that looks every second or so rather than every frame spends little.
function Bot:enemies_in_sight(radius, only)
	local unit = self:unit()
	if not unit then return {} end
	local here = game.global("Unit").world_position(unit, 0)
	local out = {}
	for _, e in ipairs(enemies.near(radius or 25, here)) do
		if (type(only) ~= "function" or picks(self, only, e)) and line_clear(unit, e, self.in_seat and self.in_seat.parts) then out[#out + 1] = e end
	end
	return out
end

-- Whether a weapon's state wants the reload a player would press: a magazine empty with a spare one
-- left, a laser overheated with a radiator left, or an empty launcher the wielder's own backpack loads. A
-- laser's heat runs from 0 to 1, and the game marks it reloadable only at full heat with a radiator in
-- stock (BeamweaponComponent.update_masters); a firearm is always reloadable, and its rounds tell. A
-- launcher with an assisted reload (the recoilless rifle, the missile launcher) is reloadable alone while
-- its wielder wears the backpack it needs with a rocket left, and the game then keeps that backpack in
-- backpack_for_reload (LauncherComponent.update_masters); without it, the reload is a teammate's to do.
function M.wants_reload(ws)
	if type(ws) ~= "table" or ws.is_reloading or ws.reloadable ~= true then return false end
	if ws.assisted_reload then return ws.backpack_for_reload ~= nil and ws.rounds == 0 end
	if type(ws.heat) == "number" and ws.magazine_capacity == nil then return true end
	return ws.rounds == 0 and (ws.num_mags or 0) > 0
end

-- Reloading by itself (auto_reload, on by default): with the trigger let go for a moment, so the reload
-- isn't lost to a state that fires. In a seat the bot's own weapons are put away, so it waits.
local function reload_step(b, unit, t, dt)
	b.reload_wait = (b.reload_wait or 0) - dt
	if (b.reload_hold or 0) > 0 then
		b.reload_hold = b.reload_hold - dt
		t.fire_button = 0
	end
	if b.reloads == false or b.reload_wait > 0 or b.in_seat then return end
	local inv = game.master(unit, "inventory")
	if M.wants_reload(inv and weapon_state(inv.current_weapon)) then
		b.reload_wait, b.reload_hold = RELOAD_GAP, RELOAD_HOLD
		press(b, "reload_pressed")
		t.fire_button = 0
	end
end

-- A grenade thrown at a point, as a player throws one (CharacterStateThrow): the bot faces the point,
-- holds the throw button until the charge reaches the distance, and lets go. The trigger stays let go
-- all along: fire held during a throw sends it at once with no charge, at the bot's feet, and keeps the
-- state from ending after it.
local GRENADE_TIME = 4

local function grenade_step(b, unit, t, f, dt)
	local job = b.job
	job.time, job.total = job.time + dt, job.total + dt
	local cs = game.master(unit, "character") or {}
	local throwing = in_state(cs, "CharacterStateThrow", "CharacterStateDownedThrow")
	t.fire_button, t.throw, t.melee, t.interact, t.interact_button = 0, 0, false, false, 0
	f.mx, f.my = 0, 0
	local here = game.global("Unit").world_position(unit, 0)
	local dx, dy = job.pos.x - here.x, job.pos.y - here.y
	f.ax, f.ay = direction({ x = dx, y = dy })
	if job.cancel then return finish(b, false, "cancelled") end
	if job.total > GRENADE_TIME then return finish(b, false, "timeout") end
	if job.phase == "turn" then
		if faces(unit, dx, dy, 0.97) or job.time > TURN_TIME then
			job.phase, job.time = "hold", 0
			job.charge = charge_for(math.sqrt(dx * dx + dy * dy))
		end
	elseif job.phase == "hold" then
		if throwing then
			if cs.has_thrown then
				job.phase, job.time = "release", 0
			elseif (cs.grenade_charge or 0) < job.charge then
				t.throw = 1
			else
				job.phase, job.time = "release", 0
			end
		else
			t.throw = 1
			if job.time > OPEN_TIME then return finish(b, false, "interrupted") end
		end
	elseif job.phase == "release" then
		if cs.throw_done or cs.has_thrown then job.thrown = true end
		if not throwing then
			if job.thrown then return finish(b, true) end
			return finish(b, false, "interrupted")
		end
		if job.time > 1.5 then return finish(b, job.thrown == true, not job.thrown and "interrupted" or nil) end
	end
end

-- Throws a grenade at a point: the bot faces it, charges the throw to the distance and lets go, as a
-- player does. Answers true once started, or false and a reason: "no_avatar", "no_position", "busy"
-- (calling a stratagem or throwing already), "no_grenades". on_done(ok, reason): true once thrown, or
-- false and "interrupted" (downed, knocked down, a vehicle seat), "cancelled" or "timeout". While it
-- runs the bot stands and holds fire, and its other orders wait.
function Bot:throw_at(pos, on_done)
	if self.job then return false, "busy" end
	local unit = self:unit()
	if not unit then return false, "no_avatar" end
	pos = point(pos)
	if not pos then return false, "no_position" end
	local inv = game.master(unit, "inventory")
	if not (inv and (inv.num_grenades or 0) > 0) then return false, "no_grenades" end
	self.job = { kind = "grenade", pos = pos, on_done = on_done, phase = "turn", time = 0, total = 0 }
	return true
end

-- Whether the bot is throwing a grenade at a point (throw_at).
function Bot:throwing()
	return self.job ~= nil and self.job.kind == "grenade"
end

-- Stops a throw_at that hasn't let go yet.
function Bot:cancel_throw()
	if not (self.job and self.job.kind == "grenade") then return false end
	self.job.cancel = true
	return true
end

-- One weapon used on one target (use_weapon). A shot shows on the weapon's state: rounds going down, or
-- the wait for the next shot (fire_timer) going up, which still happens with infinite ammo, where the
-- rounds stay put (FirearmComponent, LauncherComponent). The EAT goes from the slot once its rocket is out.
local USE_TIME = 10        -- seconds before a use_weapon gives up
local AIM_COS = math.cos(math.rad(8)) -- how near the target the bot faces before it pulls the trigger
local EMPTY_TIME = 1.5     -- seconds an empty weapon with no reload waits before "no_ammo"

local function finish_use(b, ok, why)
	local job = b.job
	if job and not job.keep then
		local back = job.after or job.before
		if back and back ~= job.slot then b.rewield = { slot = back, time = 0 } end
	elseif job and job.after then
		b.rewield = { slot = job.after, time = 0 }
	end
	finish(b, ok, why)
end

local function weapon_step(b, unit, t, f, dt)
	local job = b.job
	job.total, job.wait = job.total + dt, job.wait - dt
	t.fire_button, t.throw, t.interact, t.interact_button = 0, 0, false, 0
	f.mx, f.my = 0, 0
	if job.cancel then return finish_use(b, false, "cancelled") end
	if is_downed(unit) then return finish_use(b, false, "downed") end
	if vehicles.seat_of(unit) then return finish_use(b, false, "seated") end
	local inv = game.master(unit, "inventory")
	if not inv then return finish_use(b, false, "no_avatar") end
	local weapon = inv[job.slot]
	-- Gone from the slot after the trigger was pulled: thrown away spent, as the EAT is.
	if weapon ~= job.weapon or not alive(weapon) then
		if job.pulled then return finish_use(b, true, "spent") end
		return finish_use(b, false, "no_weapon")
	end
	local target = job.unit
	local h = alive(target) and health(target)
	if not alive(target) or (h and h.is_dead) then return finish_use(b, true, "killed") end
	if job.total > job.limit then return finish_use(b, false, "timeout") end
	local dx, dy, d = flat(unit, target)
	if d > 0.01 then f.ax, f.ay = dx / d, dy / d end
	if inv.current_weapon ~= weapon then
		if job.wait <= 0 and calm(unit) then
			if job.tries >= SWITCH_TRIES then return finish_use(b, false, "no_switch") end
			job.tries, job.wait = job.tries + 1, SWITCH_GAP
			wield(unit, job.slot)
		end
		return
	end
	local ws = weapon_state(weapon)
	if ws then
		local rounds, timer = tonumber(ws.rounds), tonumber(ws.fire_timer)
		local shot = 0
		if job.pulled and rounds and job.rounds and rounds < job.rounds then shot = job.rounds - rounds end
		if job.pulled and shot == 0 and timer and job.timer and timer > job.timer + 1e-4 then shot = 1 end
		job.rounds, job.timer = rounds, timer
		if shot > 0 then
			job.fired = job.fired + shot
			if job.fired >= job.shots then return finish_use(b, true, "shots") end
		end
		if ws.is_reloading then
			job.empty = 0
			return
		end
		if rounds == 0 then
			job.empty = (job.empty or 0) + dt
			if not M.wants_reload(ws) and job.empty > EMPTY_TIME then return finish_use(b, false, "no_ammo") end
			return
		end
		job.empty = 0
	end
	if (b.reload_hold or 0) > 0 then return end
	local here = game.global("Unit").world_position(unit, 0)
	local there = game.global("Unit").world_position(target, 0)
	if faces(unit, dx, dy, AIM_COS) and line_clear(unit, target) and no_one_in_the_way(unit, here, there.x, there.y) then
		pull(b, unit, t)
		if t.fire_button > 0 then job.pulled = true end
	end
end

-- Takes out the weapon in a slot and fires it at a unit, then takes back the weapon the bot held before:
-- an EAT or a recoilless rifle for one heavy enemy, while fight keeps to the rifle. slot: "primary",
-- "sidearm", "support" or the game's "primary_weapon" and so on. opts, all optional: shots, how many shots
-- before it's done (1; math.huge keeps firing until the target dies); time, seconds before it gives up
-- (10); keep, true to keep the weapon out afterwards. on_done may come in place of opts. The bot stands
-- still, faces the target and pulls the trigger only facing it, along a clear line and with no Helldiver in
-- the way; it reloads as auto_reload does. Answers true once started, or false and a reason: "bad_slot",
-- "no_avatar", "busy" (calling a stratagem, throwing, using a weapon, or helping someone: stop_helping
-- first), "downed", "seated", "no_weapon" (nothing in that slot), "no_target". on_done(ok, reason): true
-- and "shots" (all fired), "killed" (the target died) or "spent" (the weapon went from the slot after
-- firing, as the EAT does), or false and "no_switch" (the weapon wouldn't come out), "no_ammo",
-- "no_weapon", "timeout", "downed", "seated", "cancelled" or "no_avatar".
function Bot:use_weapon(slot, target, opts, on_done)
	if type(opts) == "function" and on_done == nil then opts, on_done = nil, opts end
	local name = SLOTS[slot]
	if not name then return false, "bad_slot" end
	local unit = self:unit()
	if not unit then return false, "no_avatar" end
	if self.job or self.task then return false, "busy" end
	if is_downed(unit) then return false, "downed" end
	if vehicles.seat_of(unit) then return false, "seated" end
	local inv = game.master(unit, "inventory")
	local weapon = inv and inv[name]
	if not alive(weapon) then return false, "no_weapon" end
	if not alive(target) then return false, "no_target" end
	local h = health(target)
	if h and h.is_dead then return false, "no_target" end
	opts = type(opts) == "table" and opts or {}
	local shots = tonumber(opts.shots) or 1
	if shots ~= shots or shots < 1 then shots = 1 end
	local limit = tonumber(opts.time) or USE_TIME
	if limit ~= limit or limit <= 0 then limit = USE_TIME end
	-- A weapon still to take out from an earlier order is the one to come back to.
	local before = self.rewield and self.rewield.slot or current_slot(unit)
	self.rewield = nil
	self.job = { kind = "weapon", slot = name, weapon = weapon, unit = target, shots = shots, fired = 0, total = 0, limit = limit,
		keep = opts.keep == true, before = before, on_done = on_done, tries = 0, wait = 0 }
	return true
end

-- The slot and the target of the weapon the bot is using (use_weapon), or false.
function Bot:using_weapon()
	if not (self.job and self.job.kind == "weapon") then return false end
	return self.job.slot, self.job.unit
end

-- Stops a use_weapon. The weapon from before comes back, as when it ends.
function Bot:cancel_weapon()
	if not (self.job and self.job.kind == "weapon") then return false end
	self.job.cancel = true
	return true
end

-- Reloads by itself, as a player would: an empty magazine with a spare left, or an overheated laser with
-- a radiator left. true by default; false leaves reloads to the orders (reload()).
function Bot:auto_reload(on)
	self.reloads = on ~= false
	return self
end

-- Walking into a wall: with the stick held and the body nowhere near where it was a moment ago, the
-- bot steps aside for a moment, one side and then the other, before going on.
local STUCK_TIME, STUCK_MOVE, SIDESTEP_TIME, SIDESTEP_TURN = 1, 0.3, 0.6, math.rad(75)

local function unstick(b, here, mx, my, dt)
	local s = b.stuck
	if mx * mx + my * my < 0.25 then
		s.time, s.x, s.y, s.side_time = 0, here.x, here.y, 0
		return mx, my
	end
	if s.side_time > 0 then
		s.side_time = s.side_time - dt
		local a = SIDESTEP_TURN * s.side
		local c, si = math.cos(a), math.sin(a)
		return mx * c - my * si, mx * si + my * c
	end
	if s.time == 0 then s.x, s.y = here.x, here.y end
	s.time = s.time + dt
	if s.time >= STUCK_TIME then
		local dx, dy = here.x - s.x, here.y - s.y
		if dx * dx + dy * dy < STUCK_MOVE * STUCK_MOVE then
			s.side = -s.side
			s.side_time = SIDESTEP_TIME
		end
		s.time, s.x, s.y = 0, here.x, here.y
	end
	return mx, my
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
	self.rewield, self.leaving, self.ride, self.in_seat = nil, nil, nil, nil
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

-- The orders: walking to a point or after a unit, facing a point, fighting. They write the orders'
-- sticks (b.axes) and the trigger.
local function think(b, unit, t, dt)
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
	if b.goals.fight then
		fight_step(b, unit, here, t, dt)
	else
		b.fight_target, b.fight_face, b.fight_near = nil, nil, false
	end
	return here
end

-- What the seat the bot sits in does, worked out once per seat: whether its guns fire on the trigger
-- (primary) or the second trigger (secondary), whether it steers wheels or tracks, and the units a line
-- of fire from it passes through (the vehicle and every gun on it).
local function seat_view(b, unit)
	local v, index = vehicles.seat_of(unit)
	if not v then
		b.in_seat = nil
		return nil
	end
	local s = b.in_seat
	if s and s.vehicle == v and s.index == index then return s end
	s = { vehicle = v, index = index, kind = vehicles.kind(v), parts = { [v] = true }, primary = false, secondary = false, drives = false }
	for _, seat in ipairs(vehicles.seats(v)) do
		for _, w in ipairs(seat.weapons) do s.parts[w.unit] = true end
		if seat.index == index then
			s.drives = seat.drives
			for _, w in ipairs(seat.weapons) do
				if w.trigger == "secondary" then s.secondary = true else s.primary = true end
			end
		end
	end
	s.armed = s.primary or s.secondary
	s.steers = s.drives and (s.kind == "apc" or s.kind == "bike" or s.kind == "tank")
	b.in_seat = s
	return s
end

-- Driving wheels and tracks the way the orders walk (f.mx, f.my, a world direction): the angle from the
-- vehicle's nose to that way sets the steering, as a pad's driver steers. The vehicle reads the sticks as
-- they are on the pad, before the camera turns them, so these go to the sticks unturned (f.stick).
local STEER_ANGLE = math.rad(45) -- the angle off the nose at which the steering is full

local function steer(b, t, f)
	local seat = b.in_seat
	local wx, wy = f.mx, f.my
	local speed = math.min(1, math.sqrt(wx * wx + wy * wy))
	f.mx, f.my, f.ax, f.ay, f.stick = 0, 0, 0, 0, true
	t.fire_button, t.throw = 0, 0
	if speed <= 0.01 then return end
	local fx, fy = forward_of(seat.vehicle)
	if not fx then fx, fy = 0, 1 end
	-- Above 0, the way to go is to the left of the nose.
	local angle = math.atan2(fx * wy - fy * wx, fx * wx + fy * wy)
	local turn = math.max(-1, math.min(1, angle / STEER_ANGLE))
	local ahead = math.cos(angle)
	if seat.kind == "tank" then
		-- A track on each stick, left on the move stick and right on the aim stick: the same on both goes
		-- straight, apart turns, and a way behind turns on the spot.
		local go = speed * math.max(0, ahead)
		f.my = math.max(-1, math.min(1, go - turn * speed))
		f.ay = math.max(-1, math.min(1, go + turn * speed))
	else
		-- The trigger speeds up and the move stick's x steers, right for right. Wheels turn only while they
		-- roll, so a way behind is a wide turn at half speed.
		t.fire_button = speed * math.max(0.5, ahead)
		f.mx = -turn
	end
end

-- Getting out (leave_vehicle): interact pressed, again each LEAVE_GAP, until the bot is out.
local function leave_step(b, unit, t, dt)
	local l = b.leaving
	if not vehicles.seat_of(unit) then
		b.leaving = nil
		return
	end
	l.time, l.wait = l.time + dt, l.wait - dt
	if l.time > LEAVE_TIME then
		b.leaving = nil
		return
	end
	if l.wait <= 0 then
		l.wait = LEAVE_GAP
		press(b, "interact")
		t.interact = true
	end
end

-- Riding along (ride_along): into the leader's vehicle while a seat that doesn't steer is free, and out
-- of the vehicle it rode in once the leader is out of it.
local function ride_step(b, unit, dt)
	local r = b.ride
	r.wait = r.wait - dt
	if r.wait > 0 then return end
	r.wait = RIDE_EVERY
	local follow = b.goals.follow
	local leader = r.unit or (follow and follow.unit) or game.my_unit()
	local theirs = alive(leader) and vehicles.seat_of(leader) or nil
	local mine = vehicles.seat_of(unit)
	if mine then
		if mine == r.vehicle and theirs ~= mine and not b.leaving then b:leave_vehicle() end
		return
	end
	if not theirs or b.task or b.job or is_downed(unit) or r.retry > M.clock then return end
	local seat
	for _, s in ipairs(vehicles.seats(theirs)) do
		if s.free and not s.drives and not heading_to(theirs, s.index, b) then
			seat = s.index
			break
		end
	end
	if not seat then return end
	local ok = b:enter_vehicle(theirs, seat, function(done)
		if not done then r.retry = M.clock + RIDE_RETRY end
	end)
	if ok then r.vehicle = theirs else r.retry = M.clock + RIDE_RETRY end
end

-- Things a Helldiver can use with interact, by the game's name for each: samples, ammo boxes, weapons and
-- backpacks lying about, hellbombs, the extraction beacon, objective terminals and the things objectives
-- ask to carry, defend or escort.
local USABLE = { "research_sample_pickup", "ammo_pickup", "weapon_pickup", "backpack_pickup", "hellbomb", "extract_beacon",
	"objective_interact_object", "objective_defend_object", "objective_carry_object", "objective_convoy", "hidden_sweep_object", "npc_escort" }

-- Things a Helldiver can use within radius (15 metres) of a position, or of the player, nearest first:
-- { unit, kind, position, enabled } each. kind is the game's name for it, as above; enabled is false while
-- the game lets no one use it. kinds: a list of those names to keep, or nil for all.
function M.usables(pos, radius, kinds)
	local units = game.global("Unit")
	if not pos then
		local me = game.my_unit()
		if not me then return {} end
		pos = units.world_position(me, 0)
	end
	local ok, px, py = pcall(function() return pos.x, pos.y end)
	if not (ok and type(px) == "number" and type(py) == "number") then return {} end
	radius = tonumber(radius) or 15
	local want
	if type(kinds) == "table" then
		want = {}
		for _, k in ipairs(kinds) do want[k] = true end
	end
	local out, seen = {}, {}
	for _, kind in ipairs(USABLE) do
		if not want or want[kind] then
			for unit, ctx in pairs(game.slaves(kind)) do
				if not seen[unit] and alive(unit) then
					local at = units.world_position(unit, 0)
					local dx, dy = at.x - px, at.y - py
					local d = math.sqrt(dx * dx + dy * dy)
					if d <= radius then
						seen[unit] = true
						local state = type(ctx) == "table" and (ctx.state or ctx) or {}
						out[#out + 1] = { unit = unit, kind = kind, position = at, enabled = state.enabled ~= false, distance = d }
					end
				end
			end
		end
	end
	table.sort(out, function(a, b) return a.distance < b.distance end)
	for _, u in ipairs(out) do u.distance = nil end
	return out
end

-- Uses a thing the way a player does: the bot walks within reach, stands, faces it and presses interact
-- once the game offers it, the press a player's interact sends. A sample, an ammo box, a weapon or a
-- backpack lying about, a hellbomb, a terminal's first press, a thing to carry: a unit from usables, or a
-- teammate (a team reload of their launcher, from the bot's backpack). opts, all optional: reach, the
-- metres from the thing it stops at (1.2); time, the seconds before it gives up (20); presses, how many
-- presses it tries when one does nothing (1). on_done may come in place of opts. Answers true once
-- started, or false and a reason: "no_avatar", "busy" (calling a stratagem, throwing or using a weapon),
-- "downed", "seated", "no_target". on_done(ok, reason): true and "used", or false and "gone" (the thing
-- went before the bot got to it), "not_offered" (the game doesn't let this bot use it from there: an ammo
-- box with the bot's ammo full, for one), "picked_other" (something else stands in the way), "no_effect",
-- "downed", "timeout", "cancelled" or "no_avatar". A new use, revive or heal ends the one running. While it
-- runs the bot's other orders wait, but a bot that fights shoots back at enemies close by on the way.
function Bot:use(unit, opts, on_done)
	if type(opts) == "function" and on_done == nil then opts, on_done = nil, opts end
	local me = self:unit()
	if not me then return false, "no_avatar" end
	if self.job then return false, "busy" end
	if is_downed(me) then return false, "downed" end
	if vehicles.seat_of(me) then return false, "seated" end
	if not alive(unit) or unit == me then return false, "no_target" end
	opts = type(opts) == "table" and opts or {}
	start_task(self, "use", unit, on_done, false)
	local task = self.task
	local reach = tonumber(opts.reach)
	task.reach = (reach and reach > 0 and reach == reach) and reach or USE_REACH
	local limit = tonumber(opts.time)
	task.limit = (limit and limit > 0 and limit == limit) and limit or USE_LIMIT
	local presses = tonumber(opts.presses)
	task.presses = (presses and presses >= 1 and presses == presses) and math.floor(presses) or 1
	return true
end

-- The thing the bot is on the way to use (use), or false.
function Bot:using()
	if not (self.task and self.task.kind == "use") then return false end
	return self.task.unit
end

-- Stops a use that hasn't taken yet.
function Bot:cancel_use()
	if not (self.task and self.task.kind == "use") then return false end
	end_task(self, false, "cancelled")
	return true
end

-- What the bot carries (a hard drive, a missile for the artillery), or nil.
function Bot:carrying()
	local unit = self:unit()
	local cs = unit and game.master(unit, "character")
	local c = cs and cs.current_carry_unit
	return alive(c) and c or nil
end

-- Puts down what the bot carries, as api.player.drop_carried. Answers true, or false and "no_avatar" or
-- "not_carrying".
function Bot:drop()
	local unit = self:unit()
	if not unit then return false, "no_avatar" end
	if not self:carrying() then return false, "not_carrying" end
	game.command(unit, "character", "drop_carry")
	return true
end

-- A voice line with the words over the bot's head, as a player's d-pad sends them: "yes", "no", "stay",
-- "move", or "taunt". Answers true, or false and "bad_word" or "no_avatar".
local WORDS = { yes = true, no = true, stay = true, move = true, taunt = true }

function Bot:say(word)
	if not WORDS[word] then return false, "bad_word" end
	local unit = self:unit()
	if not unit then return false, "no_avatar" end
	if not game.command(unit, "customization", "communication_event", { event = word }) then return false, "no_avatar" end
	return true
end

-- A jump with a jump pack, as a player's dodge with one: along a world direction { x, y }, as far as the
-- game takes it (up to 12 metres). The game refuses a jump with less than about 4 metres clear ahead.
-- Answers true once started, or false and a reason: "no_avatar", "busy", "downed", "seated", "jumping",
-- "bad_direction", "no_jump_pack", "no_fuel". on_done(ok, reason): true and "landed", or false and
-- "refused" (the game didn't jump), "downed", "timeout" or "no_avatar".
local JUMP_START = 1       -- seconds for the jump to start after the press
local JUMP_TIME = 6        -- seconds before a jump that never lands gives up

local function jump_ready(unit)
	local inv = game.master(unit, "inventory")
	local pack = inv and inv.backpack
	if not alive(pack) then return false, "no_jump_pack" end
	local ls = game.global("LoadoutSettings")
	local ok, settings = pcall(function() return ls.get_upgraded_settings(pack) end)
	local info = ok and type(settings) == "table" and settings.backpack_info
	if not (type(info) == "table" and info.enables_jump) then return false, "no_jump_pack" end
	local fuel = game.master(pack, "ammo_backpack")
	if not (fuel and (tonumber(fuel.num_uses) or 0) > 0) then return false, "no_fuel" end
	return true
end

function Bot:jump(dir, on_done)
	local unit = self:unit()
	if not unit then return false, "no_avatar" end
	if self.job then return false, "busy" end
	if self.leap then return false, "jumping" end
	if is_downed(unit) then return false, "downed" end
	if vehicles.seat_of(unit) then return false, "seated" end
	local ok, x, y = pcall(function() return dir.x, dir.y end)
	if not (ok and type(x) == "number" and type(y) == "number") then return false, "bad_direction" end
	local len = math.sqrt(x * x + y * y)
	if len < 0.01 or len ~= len then return false, "bad_direction" end
	local ready, why = jump_ready(unit)
	if not ready then return false, why end
	self.leap = { x = x / len, y = y / len, time = 0, on_done = on_done }
	return true
end

-- Whether a jump is under way.
function Bot:jumping()
	return self.leap ~= nil
end

local function end_jump(b, ok, why)
	local j = b.leap
	b.leap = nil
	if j and type(j.on_done) == "function" then
		local fine, err = pcall(j.on_done, ok, why)
		if not fine then obsidian.log("bots: on_done: " .. tostring(err)) end
	end
end

-- One frame of a jump: the move stick along the way and one press of dodge, then the state is watched
-- until the body lands.
local function jump_step(b, unit, t, f, dt)
	local j = b.leap
	j.time = j.time + dt
	if is_downed(unit) then return end_jump(b, false, "downed") end
	local cs = state_of(unit)
	if cs and in_state(cs, "CharacterStateJump") then
		j.started = true
	elseif j.started then
		return end_jump(b, true, "landed")
	end
	if not j.started and j.time > JUMP_START then return end_jump(b, false, "refused") end
	if j.time > JUMP_TIME then return end_jump(b, false, "timeout") end
	f.mx, f.my = j.x, j.y
	t.fire_button = 0
	if not j.pressed then
		j.pressed = true
		press(b, "dodge_pressed")
		t.dodge_pressed = true
	end
end

-- How far a point stands off a line on the ground, and the way out: the side it's on. nil when the
-- point is behind the line's start or past the line's end.
local function off_line(p, from, to)
	local lx, ly = to.x - from.x, to.y - from.y
	local len2 = lx * lx + ly * ly
	if len2 < 1e-6 then return nil end
	local s = ((p.x - from.x) * lx + (p.y - from.y) * ly) / len2
	if s < 0 or s > 1 then return nil end
	local cx, cy = from.x + lx * s, from.y + ly * s
	local ox, oy = p.x - cx, p.y - cy
	local d = math.sqrt(ox * ox + oy * oy)
	if d < 0.05 then
		local len = math.sqrt(len2)
		return d, -ly / len, lx / len
	end
	return d, ox / d, oy / d
end

local AVOID_LOOK = 0.1
local DIVE_AT = 0.35

-- avoid_shots: each tenth of a second, the nearest line through the bot. While in one, the walk goes
-- straight out of it for this frame, whatever the orders say.
local function avoid_step(b, unit, here, f, dt)
	local a = b.goals.avoid
	a.wait = a.wait - dt
	if a.wait <= 0 then
		a.wait = AVOID_LOOK
		local kept = a.threat
		a.threat = nil
		for _, e in ipairs(enemies.near(a.radius, here)) do
			local c = enemies.charging(e)
			local d, sx, sy
			if c then d, sx, sy = off_line(here, c.from, c.to) end
			if d and d < a.width then
				local dove = kept and kept.enemy == e and kept.dove
				a.threat = { enemy = e, x = sx, y = sy, fire_at = M.clock + c.time, dove = dove }
				break
			end
		end
	end
	local th = a.threat
	if not th then return end
	f.mx, f.my, f.stick = th.x, th.y, nil
	if a.dodge and not th.dove and th.fire_at - M.clock <= DIVE_AT then
		th.dove = true
		press(b, "dodge_pressed")
	end
end

-- Hands each bot's character its input table, with this frame's vectors. The game's input component
-- reads input_data when its player has focus. The table is built again from rest each frame: the
-- orders' holds (fire, sprint), the presses still running, then the orders, then a stratagem call, a
-- help or the downed rules over them. A press or a held button of a call or a help that ended can't
-- stay held: a press of interact left held is the game's interact on every frame, which picks an item
-- up, swaps it back, and so on, and plays one interaction over another on a body getting up.
local function drive(b, unit, dt)
	local input = game.master(unit, "input")
	if not input then return end
	if b.kind == "bare" then
		if not b.pad then return end
		input.pad_number = b.pad
	end
	local t = b.input
	-- Every button and press back at rest, whichever code wrote it; the vectors come new below.
	for k, v in pairs(t) do
		if type(v) == "number" then
			t[k] = 0
		elseif type(v) == "boolean" then
			t[k] = false
		end
	end
	t.is_active = true
	local seat = seat_view(b, unit)
	if seat and seat.kind == "exosuit" then b.mech_at = M.clock end
	if b.orders.fire then t.fire_button = 1 end
	if b.orders.fire2 and seat then t.throw = 1 end
	if b.orders.sprint then t.sprint_button, t.sprint_pressed = 1, true end
	for field, left in pairs(b.presses) do
		if left > 0 then t[field] = true end
		b.presses[field] = left > 1 and left - 1 or nil
	end
	-- In a seat the throw button is the vehicle's second trigger: a grenade asked for there is dropped.
	if b.throw_frames and seat then b.throw_frames = nil end
	if b.throw_frames then
		if b.throw_frames > 1 then t.throw = 1 end
		b.throw_frames = b.throw_frames > 1 and b.throw_frames - 1 or nil
	end
	if b.ride then ride_step(b, unit, dt) end
	local here = think(b, unit, t, dt)
	reload_step(b, unit, t, dt)
	-- A throw, the bot's own (throw) or an order's: fire held sends the grenade at once at the bot's feet,
	-- and keeps the throw state from ending after it.
	local cs = game.master(unit, "character")
	if b.throw_frames or (cs and in_state(cs, "CharacterStateThrow", "CharacterStateDownedThrow")) then t.fire_button = 0 end
	-- This frame's sticks: the orders' own, which a call or a help writes over for this frame only.
	local f = { mx = b.axes.move[1], my = b.axes.move[2], ax = b.axes.aim[1], ay = b.axes.aim[2] }
	if b.job and b.job.kind == "grenade" then
		grenade_step(b, unit, t, f, dt)
	elseif b.job and b.job.kind == "weapon" then
		weapon_step(b, unit, t, f, dt)
	elseif b.job then
		stratagem_step(b, unit, t, f, dt)
	else
		if b.task then task_step(b, unit, t, f, dt) end
		if b.leaving then leave_step(b, unit, t, dt) end
		if is_downed(unit) then
			downed_step(b, unit, t, f)
		elseif b.rewield and not b.task then
			rewield_step(b, unit, dt)
		else
			keep_weapon(b, unit, dt)
		end
	end
	if b.goals.avoid and not seat and not b.job and not b.leap and not is_downed(unit) then avoid_step(b, unit, here, f, dt) end
	if b.leap and not seat then jump_step(b, unit, t, f, dt) end
	if seat then
		-- In a seat that steers, the orders' walking drives the vehicle.
		if seat.steers then steer(b, t, f) end
	else
		f.mx, f.my = unstick(b, here, f.mx, f.my, dt)
	end
	for field in pairs(b.vectors) do t[field] = v3(0, 0, 0) end
	local mx, my, ax, ay = f.mx, f.my, f.ax, f.ay
	if not f.stick then
		mx, my = to_stick(mx, my)
		ax, ay = to_stick(ax, ay)
	end
	t.move = v3(mx, my, 0)
	t.aim = v3(ax, ay, 0)
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

-- While session mods are off, the input hook doesn't run, and the game would go on reading each bot's
-- last input every frame: buttons held, and sticks made of engine vectors that last one frame, so they
-- read as NaN later. A table at rest instead: the game resets the character's input and skips it until
-- the next drive gives it a live one. main.lua calls this when the session stops being cleared.
function M.rest_all()
	for _, b in ipairs(M.list) do
		local unit = b:unit()
		local input = unit and game.master(unit, "input")
		if input then
			local t = blank_input()
			t.is_active = false
			input.input_data = t
		end
	end
end

local MECH_GRACE = 2

-- Whether a hit of owner on victim costs nothing (mech_friendly_fire): a Helldiver hit by a bot that
-- sits in a mech, or got out of one in the last 2 seconds. A mech's guns name the Helldiver in the seat
-- as the owner of what they fire (SeatComponent, rpc_firearm_new_owner_unit).
function M.spares(owner, victim)
	if owner == nil or #M.list == 0 then return false end
	for _, b in ipairs(M.list) do
		if b.mech_spares and b.mech_at and M.clock - b.mech_at <= MECH_GRACE and b:unit() == owner then
			return game.global("EntityAux").has_component(victim, "character") and true or false
		end
	end
	return false
end

-- Right before the game's input component reads its players' input.
function M.drive_all()
	local dt = rawget(_G, "ENGINE_DT") or 0.016
	M.clock = M.clock + dt
	local ok, err = pcall(assign, dt)
	if not ok and not M.assign_failed then
		M.assign_failed = true
		obsidian.log("bots: helping: " .. tostring(err))
	end
	for _, b in ipairs(M.all()) do
		local unit = b:unit()
		if unit then
			drive(b, unit, dt)
		else
			if b.job then finish(b, false, "no_avatar") end
			if b.leap then end_jump(b, false, "no_avatar") end
			if b.task then end_task(b, false, "no_avatar") end
			b.rewield, b.leaving, b.in_seat = nil, nil, nil
			b.fight_target, b.fight_face = nil, nil
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
	obsidian.hook("CharacterComponent", "handle_interact", function(original, self, unit, ...)
		if #M.list > 0 then
			local ok, allowed = pcall(M.allow_interact, unit)
			if ok and allowed == false then return end
		end
		return original(self, unit, ...)
	end)
end

return M
