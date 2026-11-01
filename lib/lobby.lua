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

local function shared_key(name)
	return "mod:" .. tostring(obsidian.caller and obsidian.caller() or "?") .. ":" .. tostring(name)
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
	for _, peer in ipairs(ask(lobby, "members") or {}) do
		if peer ~= me then
			local ok, value = pcall(lobby.member_data, lobby, peer, key)
			if ok and type(value) == "string" and value ~= "" then out[peer] = value end
		end
	end
	return out
end

return M
