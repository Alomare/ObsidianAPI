-- The mission map: open or closed, zoom, the view, every player's ping, and a mod's own markers.
-- The map is a character state, CharacterStateMap, which leaves on the frame its map input goes
-- false, so opening it from here holds that input until the player's own key takes over. The game
-- sends the character its input only when the input changes, so a value forced here stays until it's
-- put back, and the idle state would open the map again on it. The player's key is read from the
-- input component's own table, which the pad manager fills each frame. Zoom and
-- the view are per local player in the HUD's hud_info. Markers are drawn after the game's map, in
-- the map's own units, on the map gui of each local player.
local game = obsidian.module("lib/game")

local M = { held = {}, forced = {}, markers = {}, hooked = false, clippable = setmetatable({}, { __mode = "k" }) }

-- The map's own units, as the HUD works them out: centred, turned 45 degrees, and scaled to fit 350
-- at zoom 1. This value, the field's default, means no ping.
M.NO_PING = -1000

local function level()
	local st = game.state()
	local l = type(st) == "table" and st.generated_level
	if l and l.map_size and game.in_mission() then return l end
	return nil
end

local function scale(l)
	local size = game.global("Vector2Aux").unbox(l.map_size)
	return math.min(350 / (size.x * 48), 350 / (size.y * 48)) * 2
end

-- A world position as map units at zoom 1, or nil outside a mission.
function M.to_map(pos, l)
	l = l or level()
	if not (l and pos) then return nil end
	local v3, q = game.global("Vector3"), game.global("Quaternion")
	local turn = q(v3(0, 0, -1), math.rad(-45))
	local p = q.rotate(turn, v3(pos.x - l.width * 12, pos.y - l.height * 12, pos.z or 0))
	local s = scale(l)
	return p.x * s, p.y * s
end

-- Map units back to a world position on the ground plane (z 0).
function M.to_world(x, y, l)
	l = l or level()
	if not (l and x and y) then return nil end
	local v3, q = game.global("Vector3"), game.global("Quaternion")
	local s = scale(l)
	local back = q(v3(0, 0, -1), math.rad(45))
	local p = q.rotate(back, v3(x / s, y / s, 0))
	return v3(p.x + l.width * 12, p.y + l.height * 12, 0)
end

local function character(unit)
	local masters = game.masters("character")
	return masters[unit]
end

-- The local player's unit and HUD info: the HUD keeps one per player record on this machine.
local function mine()
	local st = game.state()
	local record, index = game.me(st)
	local unit = game.avatar(record)
	local hud = type(st) == "table" and st.hud
	local info = hud and type(hud.hud_info) == "table" and hud.hud_info[index]
	return unit, info
end

-- Whether a unit's map is open: the local player's when unit is nil.
function M.is_open(unit)
	unit = unit or game.my_unit()
	local state = unit and game.master(unit, "character")
	local current = state and state.current_state
	return current ~= nil and current == game.global("CharacterStateMap")
end

function M.install()
	if M.hooked then return end
	M.hooked = true
	obsidian.hook("CharacterStateMap", "update", function(original, unit, ctx, ...)
		if M.held[unit] and ctx and ctx.state and ctx.state.input then
			-- Once the player's own map key is down, the map is theirs, and letting go closes it.
			local input = game.master(unit, "input")
			local raw = input and input.input_data
			if raw and raw.map_pressed then
				M.held[unit] = nil
			else
				ctx.state.input.map = true
				M.forced[unit] = true
			end
		end
		return original(unit, ctx, ...)
	end)
	obsidian.hook("CharacterStateMap", "on_exit", function(original, unit, ctx, ...)
		M.held[unit] = nil
		if M.forced[unit] then
			M.forced[unit] = nil
			if ctx and ctx.state and ctx.state.input then ctx.state.input.map = false end
		end
		return original(unit, ctx, ...)
	end)
	obsidian.hook("Hud", "draw_map", function(original, self, dt, t, info, gui, ...)
		local r = { original(self, dt, t, info, gui, ...) }
		if next(M.markers) then
			local ok, err = pcall(M.draw, self, info, gui)
			if not ok then obsidian.log("map markers: " .. tostring(err)) end
		end
		return unpack(r)
	end)
end

-- Opens the local player's map, as the map key does. It stays open until the player closes it,
-- does anything else (dodge, reload, a stratagem), or close() is called.
function M.open()
	local unit = game.my_unit()
	if not unit then return false, "no_avatar" end
	local ctx = character(unit)
	if not ctx then return false, "no_avatar" end
	if M.is_open(unit) then return true end
	M.install()
	M.held[unit] = true
	game.global("CharacterStateMachine").change_state(unit, ctx, game.global("CharacterStateMap"))
	return true
end

function M.close()
	local unit = game.my_unit()
	local state = unit and game.master(unit, "character")
	if not state then return false, "no_avatar" end
	M.held[unit] = nil
	if M.is_open(unit) then state.exit_map = true end
	return true
end

-- The local player's map zoom: 1 at the start, 0.5 at the furthest.
function M.zoom()
	local _, info = mine()
	return info and info.map_zoom or nil
end

function M.set_zoom(z)
	if type(z) ~= "number" then return false, "bad_type" end
	if z < 0.5 or z > 4 then return false, "out_of_range" end
	local _, info = mine()
	if not info then return false, "not_in_mission" end
	info.map_zoom = z
	return true
end

-- The world point under the map's crosshair: the middle of the view, where a ping would go.
function M.view()
	local _, info = mine()
	if not (info and info.map_offset and info.map_zoom) then return nil end
	return M.to_world(-info.map_offset.x / info.map_zoom, -info.map_offset.y / info.map_zoom)
end
M.cursor = M.view

-- Pans the local player's map so a world position is under the crosshair.
function M.look_at(pos)
	local _, info = mine()
	local x, y = M.to_map(pos)
	if not (info and x) then return false, "not_in_mission" end
	info.map_offset.x, info.map_offset.y = -x * info.map_zoom, -y * info.map_zoom
	if info.map_pan_vel then info.map_pan_vel.x, info.map_pan_vel.y = 0, 0 end
	return true
end

-- Every player's ping as { record, owned, position }, for the players that have one.
function M.pings()
	local st = game.state()
	local out = {}
	local l = level()
	if not l then return out end
	for _, p in ipairs(st.players or {}) do
		local go = p.player_go
		if go and go:exists() and (not go.has or go:has("map_ping")) then
			local ping = go:get("map_ping")
			if ping and ping[1] > M.NO_PING then
				out[#out + 1] = { record = p, owned = go:owned(), position = M.to_world(ping[1], ping[2], l) }
			end
		end
	end
	return out
end

local Marker = {}
Marker.__index = Marker

-- A marker of the mod's own on everyone's map on this machine. pos: a world position, or opts.unit
-- to follow a unit. opts: icon (a material the map gui loaded, "icon_map_pickup_generic" by
-- default), size in map pixels (18), color { a, r, g, b }.
function M.marker(pos, opts)
	opts = opts or {}
	if pos == nil and opts.unit == nil then return nil, "bad_type" end
	if opts.icon ~= nil and type(opts.icon) ~= "string" then return nil, "bad_type" end
	if opts.size ~= nil and not (type(opts.size) == "number" and opts.size > 0) then return nil, "out_of_range" end
	M.install()
	local m = setmetatable({ icon = opts.icon or "icon_map_pickup_generic", size = opts.size or 18, color = opts.color or { 255, 255, 255, 255 }, unit = opts.unit,
		state = game.state() }, Marker)
	m:move(pos)
	M.markers[m] = true
	return m
end

function Marker:move(pos)
	if pos then self.pos = { x = pos.x, y = pos.y, z = pos.z or 0 } end
	return self
end

function Marker:set(opts)
	for _, k in ipairs({ "icon", "size", "color", "unit" }) do
		if opts[k] ~= nil then self[k] = opts[k] end
	end
	return self
end

function Marker:remove()
	M.markers[self] = nil
end

function M.clear_markers()
	M.markers = {}
end

-- Drawn in the map's units times the zoom, after the game's map, on a gui that clips to the panel.
-- The clip takes only materials it was told about, so each icon is added once per gui.
function M.draw(hud, info, gui)
	local l = hud.generated_level
	if not (l and l.map_size and info and gui) then return end
	local units = game.global("Unit")
	local v3, v2, color = game.global("Vector3"), game.global("Vector2"), game.global("Color")
	local known = M.clippable[gui]
	if not known then
		known = {}
		M.clippable[gui] = known
	end
	local st = game.state()
	for m in pairs(M.markers) do
		-- A marker belongs to the mission it was made in.
		local live = m.state == st
		if not live then M.markers[m] = nil end
		local pos = live and m.pos or nil
		if live and m.unit then
			if units.alive(m.unit) then
				local p = units.world_position(m.unit, 0)
				pos = { x = p.x, y = p.y, z = p.z }
			else
				pos = nil
			end
		end
		if pos then
			if not known[m.icon] then
				gui:add_clippable_materials(m.icon)
				known[m.icon] = true
			end
			local x, y = M.to_map(pos, l)
			local half = m.size / 2
			local c = m.color
			gui:image(m.icon, v3(x * info.map_zoom - half, y * info.map_zoom - half, 12), v2(m.size, m.size), color(c[1], c[2], c[3], c[4]))
		end
	end
end

-- A new game state: no map is held open from the last one.
function M.reset()
	M.held = {}
	M.forced = {}
end

return M
