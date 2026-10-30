-- Effects: named switches that stay on across respawns and missions. The game rebuilds component
-- flags per mission and avatar state per spawn, so an effect is applied again whenever the state
-- or the avatar changes. An effect has a value: false when off, true or a number when on.
--
-- define{ id, apply = fn(ctx, value), remove = fn(ctx, value), frame = fn(ctx, value, dt) }
-- ctx: state, name (of the state), record (local player), unit (avatar or nil).
local game = obsidian.module("lib/game")

local M = { defs = {}, order = {}, values = {}, paused = false, last_state = nil, last_unit = nil }

local function context()
	local st, name = game.state()
	local record = game.me(st)
	return { state = st, name = name, record = record, unit = game.avatar(record) }
end

local function call(def, what, ...)
	local fn = def[what]
	if not fn then return end
	local ok, err = pcall(fn, ...)
	if not ok then obsidian.log("effect " .. def.id .. " " .. what .. ": " .. tostring(err)) end
end

function M.define(def)
	M.defs[def.id] = def
	M.order[#M.order + 1] = def.id
	return def
end

function M.get(id)
	return M.values[id] or false
end

function M.is_on(id)
	return M.values[id] and true or false
end

-- value false or nil switches it off. A changed value applies again.
function M.set(id, value)
	local def = M.defs[id]
	if not def then return false end
	if value == nil then value = false end
	local before = M.values[id] or false
	if before == value then return true end
	M.values[id] = value or nil
	if M.paused then return true end
	local ctx = context()
	if before and not value then
		call(def, "remove", ctx, before)
	elseif value then
		call(def, "apply", ctx, value)
	end
	return true
end

function M.toggle(id)
	return M.set(id, not M.is_on(id))
end

local function each_active(fn)
	for _, id in ipairs(M.order) do
		local value = M.values[id]
		if value then fn(M.defs[id], value) end
	end
end

-- From the frame callback, which the loader runs only in a cleared session.
function M.tick(dt)
	if M.paused then return end
	if next(M.values) == nil then return end
	local ctx = context()
	if ctx.state ~= M.last_state or ctx.unit ~= M.last_unit then
		M.last_state, M.last_unit = ctx.state, ctx.unit
		each_active(function(def, value) call(def, "apply", ctx, value) end)
	end
	each_active(function(def, value) call(def, "frame", ctx, value, dt) end)
end

-- The session stopped being cleared: every effect comes off, and remembers it was on.
function M.pause()
	if M.paused then return end
	local ctx = context()
	each_active(function(def, value) call(def, "remove", ctx, value) end)
	M.paused = true
end

function M.resume()
	if not M.paused then return end
	M.paused = false
	M.last_state, M.last_unit = nil, nil
end

function M.clear()
	local ctx = context()
	if not M.paused then each_active(function(def, value) call(def, "remove", ctx, value) end) end
	M.values = {}
end

function M.active()
	local out = {}
	each_active(function(def) out[#out + 1] = def.id end)
	return out
end

return M
