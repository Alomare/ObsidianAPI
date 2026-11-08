-- Walking routes for bots and mods. The game has no walking search that Lua can use: enemies walk
-- straight at what they want and only lean away from what is in front (EnemyComponent's feelers). So
-- this finds a way with rays: a grid of cells 1.5 metres across, each tested once with a ray down
-- (the game's own spawn_check ground test: the hit must be a unit with surface_properties, near the height
-- the walker stands at, and above -0.6, under which the map is lava or water that swallows bodies) and each
-- step between cells with a ray across (mover_blocker, what stops a body), kept for a few seconds so a path
-- costs few new rays. What it can't know: paths past about 36 metres (it goes as near as it can then
-- plans again), moving bodies and vehicles (they are stepped around when one gets stuck) and level
-- triggers with no ground shape of their own. Spends no ray beyond the frame budget.
local game = obsidian.module("lib/game")

local M = {}

-- Metres across a grid cell, and how far from the start a search looks.
M.CELL = 1.5
M.RANGE = 36
-- A step: at most this up or down from the walker's height; lower than MIN_Z is deadly ground.
M.STEP_UP = 0.7
M.DROP = 0.85
M.MIN_Z = -0.6
M.WALL_HEIGHT = 0.8
-- Rays for all searches in one frame, and for one api.nav.path call (which stops the frame budget for no one).
M.RAYS_PER_FRAME = 60
M.SYNC_RAYS = 400
-- Cells and steps kept this many seconds. A cell a bot failed on stays blocked this long.
M.TTL = 12
M.STUCK_TTL = 9
M.GROUND = "spawn_check"
M.WALL = "mover_blocker"

M.now = 0

local world = { cells = {}, edges = {}, blocked = {}, points = {}, state = nil, rays = M.RAYS_PER_FRAME }
local zones_fn, zones, zones_at = nil, {}, -1

local function dist(ax, ay, bx, by)
	local dx, dy = ax - bx, ay - by
	return math.sqrt(dx * dx + dy * dy)
end

local function key(cx, cy)
	return (cx + 30000) * 100000 + (cy + 30000)
end

local function cell_of(x, y)
	return math.floor(x / M.CELL), math.floor(y / M.CELL)
end

local function centre(cx, cy)
	return (cx + 0.5) * M.CELL, (cy + 0.5) * M.CELL
end

-- The physics to cast with, or nil when the game offers none.
local function physics()
	local st = game.state()
	if type(st) ~= "table" or not st.world_proxy or not st.world_proxy.get_physics_world then return nil end
	local phys, v3 = game.global("PhysicsWorld"), game.global("Vector3")
	if not (phys and phys.immediate_raycast and v3) then return nil end
	local ok, pw = pcall(st.world_proxy.get_physics_world, st.world_proxy)
	if not ok or pw == nil then return nil end
	return pw, phys, v3
end

-- Each frame, from the bots' driver.
function M.frame(dt)
	M.now = M.now + (tonumber(dt) or 0)
	world.rays = M.RAYS_PER_FRAME
	local st = game.state()
	if st ~= world.state then
		world.state = st
		world.cells, world.edges, world.blocked, world.points = {}, {}, {}, {}
		zones_at = -1
	end
end

local function spend(n)
	world.rays = world.rays - (n or 1)
end

local function has_ray()
	return world.rays > 0
end

-- Lets the bots' zones feed this: fn() answers the danger zones as a list of { x, y, radius, kind }.
function M.set_zones(fn)
	zones_fn = fn
end

local function zone_list()
	if M.now - zones_at > 0.4 or zones_at < 0 then
		zones_at = M.now
		zones = {}
		if zones_fn then
			local ok, list = pcall(zones_fn)
			if ok and type(list) == "table" then zones = list end
		end
	end
	return zones
end

-- The danger zone holding a point, or nil. The zones are mines, burning ground and armed hellbombs from
-- api.bots.hazards and the Impaler tentacles.
local function in_zone(x, y, margin)
	for _, z in ipairs(zone_list()) do
		local dx, dy = x - z.x, y - z.y
		local r = (z.radius or 1) + (margin or 0)
		if dx * dx + dy * dy < r * r then return z end
	end
	return nil
end

-- One ray down at a point: "ok", "pit" (no ground, or lower than walkable, or a sheer drop) or "wall"
-- (a shape with no walking surface, or standing higher than a step). z: the height of the ground near there. Answers
-- the kind and the ground height.
local function ground_ray(pw, phys, v3, x, y, z)
	local ok, hit, pos, _, normal, actor = pcall(phys.immediate_raycast, pw, v3(x, y, z + 3), v3(0, 0, -1), 10, "closest", "collision_filter", M.GROUND)
	if not ok then return nil end
	spend()
	if not hit then return "pit" end
	local h = pos and tonumber(pos.z)
	if not h then return nil end
	if h < M.MIN_Z or h < z - M.DROP then return "pit", h end
	if h > z + M.STEP_UP then return "wall", h end
	if normal and tonumber(normal.z) and normal.z < 0.5 then return "wall", h end
	if actor ~= nil then
		local actors, units = game.global("Actor"), game.global("Unit")
		local got, data = pcall(function() local u = actors.unit(actor) return units.alive(u) and units.has_data(u, "surface_properties") end)
		if got and data == false then return "wall", h end
	end
	return "ok", h
end

-- The state of a cell: "ok", "pit", "wall", "blocked" (a walker stuck on it, for a while) or nil with no rays
-- left to test it or no physics. z: the height of the walker near there. Reads the cache first.
local function cell_state(cx, cy, z, force)
	local k = key(cx, cy)
	local stuck = world.blocked[k]
	if stuck then
		if stuck > M.now then return "blocked" end
		world.blocked[k] = nil
	end
	local c = world.cells[k]
	if c and M.now - c.at < M.TTL then return c.kind, c.z end
	if not has_ray() and not force then return nil end
	local pw, phys, v3 = physics()
	if not pw then return nil end
	local x, y = centre(cx, cy)
	local kind, h = ground_ray(pw, phys, v3, x, y, z)
	if not kind then return nil end
	world.cells[k] = { kind = kind, z = h or z, at = M.now }
	return kind, h or z
end

local function edge_key(ax, ay, bx, by)
	local a, b = key(ax, ay), key(bx, by)
	if a > b then a, b = b, a end
	return a .. "-" .. b
end

-- Whether a body can cross between the middles of two cells: nothing that stops a body along the way, by
-- the game's own mover_blocker filter, among fixed shapes. nil with no rays left or no physics.
local function edge_clear(ax, ay, bx, by, z)
	local k = edge_key(ax, ay, bx, by)
	local e = world.edges[k]
	if e and M.now - e.at < M.TTL then return e.clear end
	if not has_ray() then return nil end
	local pw, phys, v3 = physics()
	if not pw then return nil end
	local x1, y1 = centre(ax, ay)
	local x2, y2 = centre(bx, by)
	local h = z + M.WALL_HEIGHT
	local len = dist(x1, y1, x2, y2)
	local ok, hit = pcall(phys.immediate_raycast, pw, v3(x1, y1, h), v3((x2 - x1) / len, (y2 - y1) / len, 0), len, "closest", "types", "statics", "collision_filter", M.WALL)
	if not ok then return nil end
	spend()
	local clear = not hit
	world.edges[k] = { clear = clear, at = M.now }
	return clear
end

-- A little binary heap of { f, n }, smallest f first.
local function heap_push(h, f, n)
	local i = #h + 1
	h[i] = { f = f, n = n }
	while i > 1 do
		local p = math.floor(i / 2)
		if h[p].f <= h[i].f then break end
		h[p], h[i] = h[i], h[p]
		i = p
	end
end

local function heap_pop(h)
	local top = h[1]
	local last = h[#h]
	h[#h] = nil
	if #h > 0 then
		h[1] = last
		local i = 1
		while true do
			local l, r, s = i * 2, i * 2 + 1, i
			if h[l] and h[l].f < h[s].f then s = l end
			if h[r] and h[r].f < h[s].f then s = r end
			if s == i then break end
			h[s], h[i] = h[i], h[s]
			i = s
		end
	end
	return top and top.n
end

local NEIGHBOURS = { { 1, 0, 1 }, { -1, 0, 1 }, { 0, 1, 1 }, { 0, -1, 1 }, { 1, 1, 1.414 }, { 1, -1, 1.414 }, { -1, 1, 1.414 }, { -1, -1, 1.414 } }

local function new_plan(sx, sy, sz, gx, gy)
	local cx, cy = cell_of(sx, sy)
	local tx, ty = cell_of(gx, gy)
	local start = { cx = cx, cy = cy, z = sz, g = 0 }
	start.key = key(cx, cy)
	local p = { open = {}, seen = { [start.key] = start }, closed = {}, tx = tx, ty = ty, sx = cx, sy = cy, sz = sz, best = start,
		best_h = dist(cx, cy, tx, ty), steps = 0, done = false, escape = in_zone(sx, sy) ~= nil }
	heap_push(p.open, start.g, start)
	return p
end

-- The points of a finished search, from start to goal, the start skipped.
local function trace(p, n)
	local cells = {}
	while n do
		table.insert(cells, 1, n)
		n = n.parent
	end
	local path = {}
	for i = 2, #cells do
		local x, y = centre(cells[i].cx, cells[i].cy)
		path[#path + 1] = { x = x, y = y, z = cells[i].z }
	end
	return path
end

local MAX_NODES = 700

-- Advances a search within the rays left. Answers "working", "full", "partial" (as far as it could get toward
-- the goal) or "none".
local function step_plan(p)
	while #p.open > 0 do
		if not has_ray() then return "working" end
		if p.steps >= MAX_NODES then break end
		local n = heap_pop(p.open)
		if not p.closed[n.key] then
			p.closed[n.key] = true
			p.steps = p.steps + 1
			local h = dist(n.cx, n.cy, p.tx, p.ty)
			if h <= 1 then
				p.done, p.path, p.status = true, trace(p, n), "full"
				return p.status
			end
			if h < p.best_h then p.best, p.best_h = n, h end
			for _, d in ipairs(NEIGHBOURS) do
				local nx, ny = n.cx + d[1], n.cy + d[2]
				local k = key(nx, ny)
				if not p.closed[k] and dist(nx, ny, p.sx, p.sy) * M.CELL <= M.RANGE then
					local kind, z = cell_state(nx, ny, n.z)
					if kind == nil and has_ray() then
						-- Physics not there: leave the search to the caller.
						p.closed[k] = true
					elseif kind == nil then
						-- Out of rays this frame: back on the heap, to take up next time.
						p.closed[n.key] = nil
						heap_push(p.open, n.g, n)
						return "working"
					elseif kind == "ok" then
						local zx, zy = centre(nx, ny)
						local danger = in_zone(zx, zy)
						if not danger or p.escape then
							-- Corners are not cut: both sides of a diagonal must be standable.
							local corner_ok = true
							if d[3] > 1 then
								local a = cell_state(n.cx + d[1], n.cy, n.z)
								local b = cell_state(n.cx, n.cy + d[2], n.z)
								if a == nil or b == nil then
									p.closed[n.key] = nil
									heap_push(p.open, n.g, n)
									return "working"
								end
								corner_ok = a == "ok" and b == "ok"
							end
							if corner_ok then
								local clear = edge_clear(n.cx, n.cy, nx, ny, n.z)
								if clear == nil then
									p.closed[n.key] = nil
									heap_push(p.open, n.g, n)
									return "working"
								end
								if clear then
									local g = n.g + d[3] * (danger and 8 or 1)
									local have = p.seen[k]
									if not have or g < have.g then
										local m = have or { cx = nx, cy = ny, key = k }
										m.g, m.z, m.parent = g, z or n.z, n
										p.seen[k] = m
										heap_push(p.open, g + dist(nx, ny, p.tx, p.ty), m)
									end
								end
							end
						end
					end
				end
			end
		end
	end
	p.done = true
	if p.best and p.best ~= p.seen[key(p.sx, p.sy)] then
		p.path, p.status = trace(p, p.best), "partial"
	else
		p.path, p.status = {}, "none"
	end
	return p.status
end

local function point_safe(x, y, z, force)
	if in_zone(x, y) then return false, "hazard" end
	local kx, ky = math.floor(x * 2), math.floor(y * 2)
	local k = kx * 1000003 + ky
	local c = world.points[k]
	if c and M.now - c.at < 1.5 then return c.kind ~= "pit", c.kind end
	if not has_ray() and not force then return true end
	local pw, phys, v3 = physics()
	if not pw then return true end
	local kind = ground_ray(pw, phys, v3, x, y, z)
	if not kind then return true end
	world.points[k] = { kind = kind, at = M.now }
	return kind ~= "pit", kind
end

-- Whether the game gives rays to search with.
function M.available()
	return physics() ~= nil
end

-- What a point on the ground is, by the search's own test: true and the height of the ground for a place a
-- Helldiver can stand, or false and "pit" (no ground, or ground below the walkable height: lava or deep water
-- among them), "wall" (a shape there or a ledge too high to step on), "hazard" (inside a danger zone of
-- api.nav.zones) or "unknown" (the game has no physics to ask). pos: { x, y, z }; z may be left out (0).
function M.walkable(pos)
	local x, y, z = pos.x, pos.y, tonumber(pos.z) or 0
	if type(x) ~= "number" or type(y) ~= "number" then return false, "unknown" end
	if in_zone(x, y) then return false, "hazard" end
	local pw, phys, v3 = physics()
	if not pw then return false, "unknown" end
	local kind, h = ground_ray(pw, phys, v3, x, y, z)
	if kind == "ok" then return true, h end
	return false, kind or "unknown"
end

-- The danger zones the searches keep out of, as a list of { x, y, radius, kind }: "mine", "fire", "hellbomb" and
-- "tentacle". Refreshed about twice a second.
function M.zones()
	local out = {}
	for i, z in ipairs(zone_list()) do out[i] = z end
	return out
end

-- Whether a body can walk straight from one point to another: each metre of the way stands on safe ground and
-- no fixed shape blocks the line, by the search's own tests. from, to: { x, y, z }. Answers true, or false and
-- "pit", "wall", "hazard" or "unknown". Costs a handful of rays.
function M.walk_clear(from, to)
	local dx, dy = to.x - from.x, to.y - from.y
	local d = math.sqrt(dx * dx + dy * dy)
	local z = tonumber(from.z) or 0
	if d < 0.01 then return true end
	local n = math.max(1, math.ceil(d))
	local bad = nil
	for i = 1, n do
		local t = i / n
		local x, y = from.x + dx * t, from.y + dy * t
		local ok, kind = point_safe(x, y, z, true)
		if not ok then bad = kind break end
		if kind == "wall" then bad = "wall" break end
	end
	if not bad then
		local pw, phys, v3 = physics()
		if pw then
			local ok, hit = pcall(phys.immediate_raycast, pw, v3(from.x, from.y, z + M.WALL_HEIGHT), v3(dx / d, dy / d, 0), d, "closest", "types", "statics", "collision_filter", M.WALL)
			if ok and hit then bad = "wall" end
		end
	end
	if bad then return false, bad end
	return true
end

-- A route over safe ground from one point to another, around walls, pits, lava and the danger zones, up to
-- about 36 metres ahead. from, to: { x, y, z }. Answers a list of { x, y, z } points and "full", or the list and
-- "partial" for a way toward it that gets as close as it can, or nil and "none" (no way out), "unknown" (no
-- physics to ask) or "far" (the goal is too far for one search: ask for a nearer point). Spends up to a few
-- hundred rays in one frame, so call it when a bot needs a plan, not every frame; a bot:navigate() order
-- runs the searches in small steps by itself.
function M.path(from, to)
	if not M.available() then return nil, "unknown" end
	if dist(from.x, from.y, to.x, to.y) > M.RANGE * 1.5 then return nil, "far" end
	local p = new_plan(from.x, from.y, tonumber(from.z) or 0, to.x, to.y)
	p.sync = true
	local rays = world.rays
	world.rays = M.SYNC_RAYS
	local status
	repeat
		status = step_plan(p)
	until status ~= "working" or world.rays <= 0
	world.rays = rays
	if status == "working" then
		-- Out of rays: as far as the search got.
		p.done = true
		if p.best and p.best.parent then p.path, status = trace(p, p.best), "partial" end
	end
	if not p.path or #p.path == 0 then return nil, status == "working" and "none" or status end
	return p.path, status
end

-- A plain search over a grid a mod supplies, for testing or a map a mod keeps: blocked(cx, cy) says a cell is
-- impassable, cells are whole numbers. Answers a list of { x, y } cells from after the start to the goal, or
-- nil. limit: nodes to look at at most (2000).
function M.search_grid(sx, sy, tx, ty, blocked, limit)
	local open, seen, closed = {}, {}, {}
	local start = { cx = sx, cy = sy, g = 0, key = key(sx, sy) }
	seen[start.key] = start
	heap_push(open, 0, start)
	limit = limit or 2000
	local n = 0
	while #open > 0 and n < limit do
		local cur = heap_pop(open)
		if not closed[cur.key] then
			closed[cur.key] = true
			n = n + 1
			if cur.cx == tx and cur.cy == ty then
				local out = {}
				while cur.parent do
					table.insert(out, 1, { x = cur.cx, y = cur.cy })
					cur = cur.parent
				end
				return out
			end
			for _, d in ipairs(NEIGHBOURS) do
				local nx, ny = cur.cx + d[1], cur.cy + d[2]
				local k = key(nx, ny)
				local diag_ok = d[3] == 1 or (not blocked(cur.cx + d[1], cur.cy) and not blocked(cur.cx, cur.cy + d[2]))
				if not closed[k] and not blocked(nx, ny) and diag_ok then
					local g = cur.g + d[3]
					local have = seen[k]
					if not have or g < have.g then
						local m = have or { cx = nx, cy = ny, key = k }
						m.g, m.parent = g, cur
						seen[k] = m
						heap_push(open, g + dist(nx, ny, tx, ty), m)
					end
				end
			end
		end
	end
	return nil
end

-- A bot's route state: new_route() once, then route() each frame.
function M.new_route()
	return { i = 1 }
end

-- Marks the way ahead as failed for a while, so the next search goes around.
local function mark_stuck(s)
	local p = s.path and s.path[s.i]
	if p then
		local cx, cy = cell_of(p.x, p.y)
		world.blocked[key(cx, cy)] = M.now + M.STUCK_TTL
	end
end

-- Where to walk now toward a goal, for route state s. here: { x, y, z }; gx, gy: the goal. Answers the point to
-- head for, and the state: "direct" (close, or nothing to search with), "route" (following a found way),
-- "search" (still looking: head for the goal for now), "stuck" (given up on a way, try something else).
local STUCK_AFTER = 1.1
local GOAL_MOVES = 3
local REFRESH = 2.2

function M.route(s, here, gx, gy, dt)
	if dist(here.x, here.y, gx, gy) < 2.5 or not M.available() then
		s.plan, s.path, s.fails = nil, nil, 0
		return gx, gy, "direct"
	end
	s.since = (s.since or 0) - dt
	-- Watching for no progress along the way: a body in the way, or a shape the rays missed.
	s.watch = (s.watch or 0) + dt
	if s.watch > STUCK_AFTER then
		local moved = s.mx and dist(here.x, here.y, s.mx, s.my) or 100
		s.watch, s.mx, s.my = 0, here.x, here.y
		if moved < 0.4 and s.path then
			mark_stuck(s)
			s.path, s.plan = nil, nil
			s.fails = (s.fails or 0) + 1
			if s.fails >= 3 then
				s.fails = 0
				s.pause = M.now + 0.8
				return gx, gy, "stuck"
			end
		elseif moved >= 0.4 then
			s.fails = 0
		end
	end
	if s.pause then
		if M.now < s.pause then return gx, gy, "stuck" end
		s.pause = nil
	end
	local stale = s.gx == nil or dist(s.gx, s.gy, gx, gy) > GOAL_MOVES or s.since <= 0
	if stale and not s.plan then
		s.plan = new_plan(here.x, here.y, tonumber(here.z) or 0, gx, gy)
		s.gx, s.gy = gx, gy
		s.since = REFRESH
	end
	if s.plan then
		local status = step_plan(s.plan)
		if status ~= "working" then
			if status == "none" then
				s.path = nil
			else
				s.path, s.i = s.plan.path, 1
			end
			s.plan = nil
		end
	end
	local path = s.path
	if not path or #path == 0 then return gx, gy, "search" end
	-- Past the waypoints already reached, and any that a straight walk from here reaches; the path is a
	-- grid's, so this is what makes the walk look like one line.
	while path[s.i] and dist(here.x, here.y, path[s.i].x, path[s.i].y) < 1.2 do s.i = s.i + 1 end
	if s.i > #path then
		s.path = nil
		return gx, gy, "search"
	end
	s.pull = (s.pull or 0) - dt
	if s.pull <= 0 and has_ray() then
		s.pull = 0.25
		local j = s.i
		for tries = 1, 3 do
			local nxt = path[j + 1]
			if not nxt then break end
			local before = world.rays
			local clear = M.walk_clear(here, nxt)
			world.rays = before - 2
			if not clear then break end
			j = j + 1
		end
		s.i = j
	end
	local p = path[s.i]
	return p.x, p.y, "route"
end

-- The direction to walk instead of (x, y) to keep clear of deadly ground, from here: (x, y) itself when ahead is
-- safe, else the closest safe turn of up to 150 degrees, or nil when every way is unsafe. ahead: metres
-- looked ahead. Costs a few rays at most, and they are remembered a moment.
local TURNS = { 0, 25, -25, 50, -50, 80, -80, 110, -110, 150, -150 }

function M.safe_heading(here, x, y, ahead)
	local z = tonumber(here.z) or 0
	local function ok(px, py)
		local good, why = point_safe(px, py, z, true)
		if good then return true end
		-- Already inside a zone: only the ways out are refused.
		if why == "hazard" and in_zone(here.x, here.y) and not in_zone(here.x + (px - here.x) * 0.5, here.y + (py - here.y) * 0.5) then return true end
		return false
	end
	for _, deg in ipairs(TURNS) do
		local a = math.rad(deg)
		local c, s = math.cos(a), math.sin(a)
		local dx, dy = x * c - y * s, x * s + y * c
		if ok(here.x + dx * ahead, here.y + dy * ahead) then return dx, dy end
	end
	-- Every way reads unsafe. If the bot's own spot does too, the test is wrong here, not the ground: leave the step.
	if not point_safe(here.x, here.y, z, true) then return x, y end
	return nil
end

-- Whether a straight jump or dive of metres from here along (x, y) ends on safe ground.
function M.dive_safe(here, x, y, metres)
	local good = point_safe(here.x + x * metres, here.y + y * metres, tonumber(here.z) or 0, true)
	return good
end

return M
