-- Who's in the lobby. Read only. Names live on the mission's player objects, so a teammate has one
-- only during a mission.
local game = obsidian.module("lib/game")

local M = {}

local function names()
	local out = {}
	local st = game.state()
	for _, p in ipairs(type(st) == "table" and st.players or {}) do
		local go = p.player_go
		if go and go:exists() and go.has and go:has("name") then out[go:owner()] = go:get("name") end
	end
	return out
end

-- In milliseconds. The engine has no answer for a peer it isn't connected to.
local function ping(peer)
	local network = game.global("Network")
	local ok, seconds = pcall(network.ping, peer)
	if ok and type(seconds) == "number" then return math.floor(seconds * 1000) end
	return nil
end

local function ask(lobby, method)
	if not lobby then return nil end
	local ok, answer = pcall(lobby[method], lobby)
	return ok and answer or nil
end

-- { peer, name, ping, host, me }, the local player included.
function M.players()
	local network, user = game.global("Network"), game.global("UserManager")
	local me = network.peer_id()
	local lobby = game.lobby()
	local peers = ask(lobby, "members") or { me }
	local host = ask(lobby, "lobby_host") or me
	local known = names()
	local out = {}
	for _, peer in ipairs(peers) do
		local mine = peer == me
		out[#out + 1] = { peer = peer, name = known[peer] or (mine and user:get_name()) or nil, ping = not mine and ping(peer) or nil, host = peer == host, me = mine }
	end
	return out
end

-- A value a mod shares with every machine in the lobby, through the lobby's member data, so it reaches
-- the others without a message of its own. One key per mod and name. Text up to 200 characters; Steam
-- sends a change within about a second. Without a lobby nothing is shared, and share answers not_available.
local MAX_SHARED = 200
local sent = {}

-- While a mod's on_leave function runs, the key is that mod's, though the API's frame calls it.
local acting = nil

local function shared_key(name)
	local who = acting or (obsidian.caller and obsidian.caller()) or "?"
	return "mod:" .. tostring(who) .. ":" .. tostring(name)
end

-- The last value each peer shared under a key in this game state: key -> peer -> text. A peer that left
-- keeps the value it last had, so a mod can still read what it was doing.
local last = { state = nil, keys = {} }

local function remember(key, peer, value)
	local st = game.state()
	if last.state ~= st then last.state, last.keys = st, {} end
	local map = last.keys[key]
	if not map then
		map = {}
		last.keys[key] = map
	end
	if value ~= nil then map[peer] = value end
	return map
end

function M.share(name, value)
	if type(name) ~= "string" or name == "" then return false, "bad_type" end
	if value ~= nil and type(value) ~= "string" then return false, "bad_type" end
	if value and #value > MAX_SHARED then return false, "out_of_range" end
	local lobby = game.lobby()
	if not lobby then return false, "not_available" end
	local key = shared_key(name)
	if sent[key] == value and sent[key .. "|lobby"] == lobby.lobby then return true end
	local ok, err = pcall(lobby.set_member_data, lobby, key, value or "")
	if not ok then return false, tostring(err) end
	sent[key], sent[key .. "|lobby"] = value, lobby.lobby
	return true
end

-- What each other machine shares under `name`, by peer. A machine that shares nothing is left out.
function M.shared(name)
	local out = {}
	local lobby = game.lobby()
	if not lobby or type(name) ~= "string" then return out end
	local key = shared_key(name)
	local me = game.global("Network").peer_id()
	remember(key, me)
	for _, peer in ipairs(ask(lobby, "members") or {}) do
		if peer ~= me then
			local ok, value = pcall(lobby.member_data, lobby, peer, key)
			if ok and type(value) == "string" and value ~= "" then
				out[peer] = value
				remember(key, peer, value)
			end
		end
	end
	return out
end

-- The last text a peer shared under `name` in this mission, read while that peer was still here: shared
-- reads it, and so does a look once a second at every name a mod has asked for. A peer that left keeps
-- the last value read before it went, which a peer's own member data may no longer give. nil when none
-- was read.
function M.last_shared(name, peer)
	if type(name) ~= "string" or peer == nil then return nil end
	local key = shared_key(name)
	local map = remember(key, nil)
	return map[peer]
end

-- Each peer still in the lobby, from the last look, and the functions told when one leaves.
local present, leave_fns, poll_wait = nil, {}, 0
local POLL_EVERY = 1

-- What a member list lost since the last one: the peers in `before` and not in `now`. Both are lists.
function M.departed(before, now)
	local here, out = {}, {}
	for _, peer in ipairs(now or {}) do here[peer] = true end
	for _, peer in ipairs(before or {}) do
		if not here[peer] then out[#out + 1] = peer end
	end
	return out
end

-- fn(peer) runs once for each peer that leaves the lobby, within about a second of it going. The lobby
-- is looked at once a second while the game runs. Answers true.
function M.on_leave(fn)
	if type(fn) ~= "function" then return false, "bad_type" end
	leave_fns[#leave_fns + 1] = { fn = fn, mod = obsidian.caller and obsidian.caller() or nil }
	return true
end

-- Each frame, from main.lua: once a second, the member list against the last one, and every name a mod
-- asked last_shared or shared about read again, so a value is kept from before that peer leaves.
function M.tick(dt)
	poll_wait = poll_wait - (tonumber(dt) or 0)
	if poll_wait > 0 then return end
	poll_wait = POLL_EVERY
	local lobby = game.lobby()
	local members = ask(lobby, "members")
	if type(members) ~= "table" then
		present = nil
		return
	end
	local st = game.state()
	if last.state == st then
		local me = game.global("Network").peer_id()
		for key, map in pairs(last.keys) do
			for _, peer in ipairs(members) do
				if peer ~= me then
					local ok, value = pcall(lobby.member_data, lobby, peer, key)
					if ok and type(value) == "string" and value ~= "" then map[peer] = value end
				end
			end
		end
	end
	local gone = present and M.departed(present, members) or {}
	present = {}
	for i, peer in ipairs(members) do present[i] = peer end
	for _, peer in ipairs(gone) do
		for _, entry in ipairs(leave_fns) do
			acting = entry.mod
			local ok, err = pcall(entry.fn, peer)
			acting = nil
			if not ok then obsidian.log("lobby: on_leave: " .. tostring(err)) end
		end
	end
end

return M
