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

local M = { list = {} }

local HELLDIVER = "characters/helldiver_private_01/helldiver_private_01"

-- What the input code reads besides the pad mapping: a vehicle seat reads these two.
local EXTRA_NUMBERS = { "fire_button_primary_vehicle", "fire_button_secondary_vehicle" }
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
	local b = setmetatable({ kind = kind, name = name, state = game.state(), input = input, vectors = vectors, axes = { move = { 0, 0 }, aim = { 0, 0 } }, presses = {}, goals = {} }, Bot)
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
	self.goals.follow = nil
	self.axes.move[1], self.axes.move[2] = direction(dir)
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
	return self
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
	self.goals.follow = { unit = unit, distance = distance or 6 }
	return self
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
		local enemies = obsidian.module("lib/enemies")
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
	think(b, unit)
	local t = b.input
	for field, left in pairs(b.presses) do
		t[field] = left > 0
		b.presses[field] = left > 0 and left - 1 or nil
	end
	if b.throw_frames then
		t.throw = b.throw_frames > 1 and 1 or 0
		b.throw_frames = b.throw_frames > 1 and b.throw_frames - 1 or nil
	end
	for field in pairs(b.vectors) do t[field] = v3(0, 0, 0) end
	local mx, my = to_stick(b.axes.move[1], b.axes.move[2])
	t.move = v3(mx, my, 0)
	local ax, ay = to_stick(b.axes.aim[1], b.axes.aim[2])
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

-- Right before the game's input component reads its players' input.
function M.drive_all()
	for _, b in ipairs(M.all()) do
		local unit = b:unit()
		if unit then drive(b, unit) end
	end
end

-- A bare bot has no player record, so the HUD draws no name over it. This draws one the way the HUD
-- draws a player's: projected through the game's viewport, centred, a little above, in the body font.
-- The projection is x, depth, y: the height on the screen is its z, as the HUD reads it.
local NAME_COLOR = { 255, 200, 200, 200 }
local NAME_LAYER = 5

function M.draw_names(hud)
	local gui = hud and hud.hd_gui
	local cm = game.global("CameraManager")
	local viewport = cm and cm:get_viewport()
	if not (gui and viewport and hud.gui_metrics_cacher) then return end
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
