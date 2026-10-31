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

return M
