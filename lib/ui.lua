-- Messages and map marks, through the game's own HUD.
local game = obsidian.module("lib/game")

local M = {}

-- A hint shows a text key. Its parameters are pattern and value pairs that the game's formatter runs
-- over the text, so a pattern matching all of it shows a mod's own words. The icon and the sound are
-- those of this hint.
local CARRIER = "hint_alarm"
local WHOLE_TEXT = "^.*$"

-- text: a hint name from HintSettings, or words to show. seconds: nil for the game's 7. It shows
-- with the game's hints turned off too.
function M.hint(text, seconds)
	local st = game.state()
	local hints = type(st) == "table" and st.hint_manager
	if not hints then return false, "not_in_mission" end
	if type(text) ~= "string" or text == "" then return false, "bad_type" end
	if seconds ~= nil and not (type(seconds) == "number" and seconds > 0) then return false, "out_of_range" end
	local known = game.global("HintSettings")
	if known and known[text] then
		hints:add_hint(text, true, nil, nil, seconds, true)
	else
		hints:add_hint(CARRIER, true, { WHOLE_TEXT, (string.gsub(text, "%%", "%%%%")) }, nil, seconds, true)
	end
	return true
end

-- The map's own units, as the HUD works them out: centred, turned 45 degrees, and scaled to fit 350
-- at zoom 1. This value, the field's default, means no ping.
local NO_PING = -1000

local function map_position(level, pos)
	local size = game.global("Vector2Aux").unbox(level.map_size)
	local v3, q = game.global("Vector3"), game.global("Quaternion")
	local turn = q(v3(0, 0, -1), math.rad(-45))
	local p = q.rotate(turn, v3(pos.x - level.width * 12, pos.y - level.height * 12, pos.z))
	local scale = math.min(350 / (size.x * 48), 350 / (size.y * 48)) * 2
	return p.x * scale, p.y * scale
end

local function clamp(n)
	return math.max(NO_PING + 1, math.min(n, -NO_PING - 1))
end

-- The player's map mark at a world position, or off with nil. Every player sees it.
function M.ping(pos)
	local st = game.state()
	local record = game.me(st)
	local level = type(st) == "table" and st.generated_level
	if not (record and level and level.map_size and game.in_mission()) then return false, "not_in_mission" end
	if pos == nil then
		record.player_go:set("map_ping", { NO_PING, NO_PING })
		return true
	end
	local x, y = map_position(level, pos)
	record.player_go:set("map_ping", { clamp(x), clamp(y) })
	return true
end

return M
