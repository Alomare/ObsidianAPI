-- Decisions a bot makes while it fights and moves, as plain functions over plain tables: no game reads, so
-- a mod can call them on numbers of the mod and a test can check them. bots.lua feeds them what it reads from
-- the game. Numbers carry their units in the comments; a slot is the name inventory uses ("primary_weapon").
local M = {}

-- How much more a weapon must hurt a target before it is worth taking the support weapon out.
M.MARGIN = 1.25
-- A hit that keeps less than this share of the weapon's power past the armor counts the target as armored.
M.ARMOR_SHARE = 0.5
-- Hitpoints from which an enemy counts as big, large or not.
M.BIG_HP = 900
-- A group: this many enemies close together around the target, the target counted, for a support weapon and
-- for a heavy one (one with few rounds or a blast).
M.GROUP = 3
M.HEAVY_GROUP = 5
-- Metres around a target that hold a group.
M.GROUP_RADIUS = 6

-- Weapons with few rounds to their name or a blast: rockets, launchers, the single-shot ones. rounds: rounds in
-- the magazine; capacity: rounds to a magazine; mags: spare magazines; explosive: a blast on the hit.
function M.heavy(rounds, capacity, mags, explosive)
	if explosive then return true end
	capacity, mags = tonumber(capacity) or 0, tonumber(mags) or 0
	if capacity <= 0 then return false end
	return capacity * (mags + 1) <= 30
end

-- Whether a target's armor keeps most of a weapon's power out: hurt, what one hit does past armor; power, the
-- weapon's power.
function M.armored(hurt, power)
	hurt, power = tonumber(hurt) or 0, tonumber(power) or 0
	if power <= 0 then return false end
	return hurt < power * M.ARMOR_SHARE
end

-- How deserving of a support weapon a target is. target: { large, big, armored, group }, group being how many
-- enemies stand together with it, the target counted. Answers "heavy" for a target worth the heavy
-- weapons (armored, large, big or a big group), "support" for one worth a sustained support weapon, or
-- nil for one the rifle handles.
function M.deserves(target)
	if not target then return nil end
	local group = tonumber(target.group) or 1
	if target.armored or target.large or target.big or group >= M.HEAVY_GROUP then return "heavy" end
	if group >= M.GROUP then return "support" end
	return nil
end

-- The slot to fight a target with. slots: primary_weapon, sidearm_weapon, support_weapon, each nil or
-- { ready, reach, hurt, heavy, blast, min_range }. ready: has ammunition and isn't resting; reach: metres, nil
-- for no limit; hurt: what one hit does past armor; heavy: M.heavy; blast: metres of blast, nil for none;
-- min_range: metres the bot must keep from the target with this weapon. target: { d, large, big, armored, group,
-- friend_near }, d being metres to it and friend_near whether a friend stands inside the blast of what lands
-- on it (the caller works that out per weapon, friend_near_for(blast), or gives a single boolean).
-- A support weapon only for a target that deserves it, and a heavy one only for what deserves a heavy one,
-- only with a clear blast and the target past the weapon's minimum, else the primary, the sidearm, whatever
-- has ammunition. nil with no weapon.
function M.pick_weapon(slots, target)
	slots = slots or {}
	local in_range = function(s, d) return s and s.ready and (d == nil or s.reach == nil or d <= s.reach) end
	local d = target and target.d or nil
	local function clear_blast(s)
		if not s.blast then return true end
		if not target then return true end
		if type(target.friend_near_for) == "function" then return not target.friend_near_for(s.blast) end
		return not target.friend_near
	end
	local function past_minimum(s)
		return not s.min_range or d == nil or d > s.min_range
	end
	local support, primary = slots.support_weapon, slots.primary_weapon
	local rank = M.deserves(target)
	if target and in_range(support, d) and past_minimum(support) and clear_blast(support) and rank
		and (rank == "heavy" or not support.heavy) then
		local p = primary and primary.ready and (tonumber(primary.hurt) or 0) or 0
		local s = tonumber(support.hurt) or 0
		-- A group is what a blast or a sustained weapon is for, armor or not; a lone armored target
		-- needs the weapon that gets through.
		local good = s >= p * M.MARGIN or (s > 0 and (target.group or 1) >= M.GROUP)
		if s > 0 and good then return "support_weapon" end
	end
	for _, slot in ipairs({ "primary_weapon", "sidearm_weapon", "support_weapon" }) do
		local s = slots[slot]
		-- A heavy weapon is not for what doesn't deserve it, even with nothing else in reach.
		if in_range(s, d) and past_minimum(s) and (slot ~= "support_weapon" or (clear_blast(s) and (rank == "heavy" or not s.heavy))) then return slot end
	end
	-- With nothing in range, what has ammunition, to walk and wait with.
	for _, slot in ipairs({ "primary_weapon", "sidearm_weapon", "support_weapon" }) do
		if slots[slot] and slots[slot].ready then return slot end
	end
	return nil
end

-- Lower is a better target: the nearest, with a nod to what threatens the squad most. e: { d, large, big,
-- attacking, group }, attacking being whether this enemy is coming for the bot now.
function M.score(e)
	local s = tonumber(e.d) or 1000
	if e.attacking then s = s - 6 end
	if e.large or e.big then s = s - 4 end
	if e.group and e.group >= M.GROUP then s = s - 2 end
	return s
end

-- The candidates ordered best first, a new list.
function M.ranked(list)
	local out = {}
	for i, e in ipairs(list or {}) do out[i] = e end
	table.sort(out, function(a, b) return M.score(a) < M.score(b) end)
	return out
end

-- Whether a bot keeps shooting at the target it has: while the target lives, is within reach and the bot hasn't
-- gone blind on it for more than a moment, unless something far better is next to the bot. current: { d, large,
-- big }; reach: metres, nil for no limit; blind: seconds with no clear line to the target; best: the best other
-- candidate, as M.score takes them, or nil.
M.COMMIT_BLIND = 1.2
M.COMMIT_SWITCH_NEAR = 5
M.COMMIT_SWITCH_GAIN = 8

function M.keeps(current, reach, blind, best)
	if not current then return false end
	if (blind or 0) > M.COMMIT_BLIND then return false end
	if reach and current.d and current.d > reach then return false end
	if best and best.d and current.d then
		if best.d <= M.COMMIT_SWITCH_NEAR and current.d > best.d + M.COMMIT_SWITCH_NEAR then return false end
		if M.score(current) > M.score(best) + M.COMMIT_SWITCH_GAIN then return false end
	end
	return true
end

-- The window, in degrees either side of the line to the target, the barrel must be inside for a shot: the
-- target's size at that distance plus half the weapon's spread, kept between MIN_WINDOW and MAX_WINDOW.
-- distance: metres; spread: the weapon's spread in degrees (nil or 0 for a dead straight weapon); radius: the
-- target's half-width in metres.
M.MIN_WINDOW = 2.5
M.MAX_WINDOW = 12

function M.aim_window(distance, spread, radius)
	distance = math.max(tonumber(distance) or 1, 0.5)
	local angle = math.deg(math.atan2(math.max(tonumber(radius) or 0.6, 0.1), distance))
	local w = angle + (tonumber(spread) or 0) * 0.5
	return math.max(M.MIN_WINDOW, math.min(M.MAX_WINDOW, w))
end

-- Whether a straight shot from shooter to point keeps clear of every friend, by the width metres. shooter,
-- point and friends: { x, y }, friends a list. The shooter itself is not in the list.
function M.line_clear(shooter, point, friends, width)
	local dx, dy = point.x - shooter.x, point.y - shooter.y
	local len = math.sqrt(dx * dx + dy * dy)
	if len < 0.01 then return true end
	local ux, uy = dx / len, dy / len
	for _, f in ipairs(friends or {}) do
		local ox, oy = f.x - shooter.x, f.y - shooter.y
		local along = ox * ux + oy * uy
		if along > 0.3 and along < len + 0.5 and math.abs(ox * uy - oy * ux) < width then return false end
	end
	return true
end

-- Whether a blast of radius metres at point would touch a friend or the shooter, with margin metres to spare.
-- shooter and point: { x, y }; friends: a list of { x, y }. true when it is safe to fire.
function M.blast_clear(shooter, point, radius, friends, margin)
	radius = tonumber(radius)
	if not radius or radius <= 0 then return true end
	margin = tonumber(margin) or 1
	local reach = radius + margin
	local function near(p)
		local dx, dy = p.x - point.x, p.y - point.y
		return dx * dx + dy * dy < reach * reach
	end
	if near(shooter) then return false end
	for _, f in ipairs(friends or {}) do
		if near(f) then return false end
	end
	return true
end

-- A spot of a bot around the Helldiver it follows, in the leader's own frame: { side, back, drift } metres
-- to the left and behind, and a phase for a small wander. seed: any whole number, the same each time for a
-- given bot. distance: how far the leader is kept.
function M.slot(seed, distance)
	seed = math.floor(tonumber(seed) or 1)
	distance = tonumber(distance) or 6
	-- Seeded odd spacing: soldiers end up ahead of the leader's shoulders and behind, never in a line.
	local a = math.rad(((seed * 137) % 240) + 60)
	local r = distance * (0.8 + ((seed * 53) % 40) / 100)
	return { side = math.sin(a) * r, back = -math.cos(a) * r, drift = (seed % 7) / 7 * math.pi * 2 }
end

-- The walking decision toward a follow spot, with hysteresis: moving keeps going until within arrive metres,
-- standing starts only past start metres. d: metres to the spot; moving: boolean. Answers moving, speed
-- (0 to 1 for the move stick).
M.ARRIVE = 1.5
M.START = 3.5

function M.arrive(d, moving, arrive, start)
	arrive, start = arrive or M.ARRIVE, start or M.START
	d = tonumber(d) or 0
	if moving then
		if d <= arrive then return false, 0 end
	elseif d <= start then
		return false, 0
	end
	-- Slower close to the spot; never so small the stick falls in the dead zone.
	return true, math.max(0.55, math.min(1, d / 5))
end

-- Whether to sprint toward a follow spot. d: metres to the Helldiver followed; was: sprinting already;
-- stamina: seconds of sprint left (nil when unknown); busy: there is a target worth standing for.
M.SPRINT_AT = 13
M.SPRINT_STOP = 8
M.SPRINT_MIN = 0.5
M.SPRINT_FULL = 2
M.SPRINT_HARD = 22

function M.sprints(d, was, stamina, busy)
	d = tonumber(d) or 0
	if busy and d < M.SPRINT_HARD then return false end
	if stamina then
		if was and stamina < M.SPRINT_MIN then return false end
		if not was and stamina < M.SPRINT_FULL then return false end
	end
	if was then return d > M.SPRINT_STOP end
	return d > M.SPRINT_AT
end

-- Where to step while fighting, in the frame of the line to the target: forward (toward the target) and
-- side, each -1 to 1. s: a table the bot keeps, holding the timers; d: metres to the target; reach: the
-- weapon's reach, nil for none; dt: seconds; rand: a number 0 to 1; planted: the weapon can't be fired on the
-- move (heavy weapons with no aimed move speed), so the bot stands.
-- Gets away from what is too close, walks into reach, else moves a little from side to side and stops between.
M.BACK_OFF = 3.5
M.INTO_REACH = 0.92
M.STRAFE_TIME = 1.1
M.STAND_TIME = 1.3

function M.fight_step(s, d, reach, dt, rand, planted)
	d = tonumber(d) or 0
	if d < M.BACK_OFF then return -1, 0 end
	if reach and d > reach * M.INTO_REACH then return 1, 0 end
	if planted then return 0, 0 end
	s.wait = (s.wait or 0) - dt
	if s.wait <= 0 then
		s.moving = not s.moving
		s.wait = s.moving and M.STRAFE_TIME or M.STAND_TIME
		s.wait = s.wait * (0.7 + (rand or 0.5) * 0.6)
		if s.moving then s.side = (rand or 0.5) < 0.5 and 1 or -1 end
	end
	if s.moving then return 0, (s.side or 1) * 0.7 end
	return 0, 0
end

-- Whether, and where, to throw a grenade. kind: "frag" (an explosive or incendiary one), "stun" or "smoke".
-- f: { count, cooldown, shooter, point, d, group, big, blast, friends, under_fire, enemies }. count: grenades left;
-- cooldown: seconds before the bot may throw again; shooter and point: { x, y }, the bot and the target;
-- d: metres to it; group: enemies together around it, the target counted; big: large or big enemy; blast: metres of
-- the blast; friends: every other Helldiver, { x, y } each; under_fire: the bot or the squad is taking shots now;
-- enemies: how many are in sight. A frag or a stun goes at a group or a big enemy between GRENADE_MIN and GRENADE_MAX
-- metres off, only with no friend within the blast (GRENADE_MARGIN to spare) of where it lands or halfway there,
-- since a short throw lands short. Smoke goes down between the bot and the enemies when under fire. Answers
-- { x, y } or nil.
M.GRENADE_MIN = 7
M.GRENADE_MAX = 14
M.GRENADE_MARGIN = 2
M.SMOKE_AHEAD = 6

function M.grenade(kind, f)
	if not f or (tonumber(f.count) or 0) <= 0 or (tonumber(f.cooldown) or 0) > 0 then return nil end
	if not (f.shooter and f.point and f.d) then return nil end
	if kind == "smoke" then
		if not f.under_fire or (tonumber(f.enemies) or 0) < 2 then return nil end
		local t = math.min(M.SMOKE_AHEAD, f.d * 0.6) / math.max(f.d, 0.1)
		return { x = f.shooter.x + (f.point.x - f.shooter.x) * t, y = f.shooter.y + (f.point.y - f.shooter.y) * t }
	end
	if f.d < M.GRENADE_MIN or f.d > M.GRENADE_MAX then return nil end
	if (tonumber(f.group) or 1) < 2 and not f.big then return nil end
	local half = { x = (f.shooter.x + f.point.x) / 2, y = (f.shooter.y + f.point.y) / 2 }
	if not M.blast_clear(f.shooter, f.point, f.blast, f.friends, M.GRENADE_MARGIN) then return nil end
	if not M.blast_clear({ x = 1e6, y = 1e6 }, half, f.blast, f.friends, M.GRENADE_MARGIN) then return nil end
	return { x = f.point.x, y = f.point.y }
end

-- Pushes a bot off the bodies next to it. here: { x, y }; others: a list of { x, y } other bodies; spacing: metres
-- wanted between bodies. Answers a push { x, y } of length 0 to 1.
function M.separate(here, others, spacing)
	local px, py = 0, 0
	spacing = tonumber(spacing) or 2.5
	for _, o in ipairs(others or {}) do
		local dx, dy = here.x - o.x, here.y - o.y
		local d = math.sqrt(dx * dx + dy * dy)
		if d < spacing and d > 0.01 then
			local push = (spacing - d) / spacing
			px, py = px + dx / d * push, py + dy / d * push
		elseif d <= 0.01 then
			px = px + 0.5
		end
	end
	local len = math.sqrt(px * px + py * py)
	if len > 1 then px, py = px / len, py / len end
	return px, py
end

return M
