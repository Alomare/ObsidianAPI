-- Messages and map marks, through the game's own HUD.
local game = obsidian.module("lib/game")
local map = obsidian.module("lib/map")

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
	elseif obsidian.capabilities.notify then
		-- The loader's own box for a mod's words, where Obsidian's messages go first and a mod can only
		-- have so many waiting.
		return obsidian.notify(text, seconds)
	else
		hints:add_hint(CARRIER, true, { WHOLE_TEXT, (string.gsub(text, "%%", "%%%%")) }, nil, seconds, true)
	end
	return true
end

-- A menu of the ship by name, as a terminal opens it: "armory", "encyclopedia", "training", "main",
-- "loadout" and so on. A menu reads the player who opened it, and Loadout and the briefing read the
-- mission, so opts.seed gives them one. opts.pad is a pad number, nil for the main player's.
function M.open(name, opts)
	local st = game.state()
	if type(st) ~= "table" or type(st.show_menu) ~= "function" or type(st.screens) ~= "table" then return false, "not_on_ship" end
	if not st.screens[name] then return false, "unknown" end
	opts = opts or {}
	if opts.seed ~= nil and type(opts.seed) ~= "number" then return false, "bad_type" end
	local settings = game.global("GameSettings")
	local params = { user_pad_number = opts.pad or settings.get_main_pad_number() }
	if opts.seed then
		st.mission_seed = opts.seed
		params.mission_seed = opts.seed
		game.global("SaveManager"):set("next_mission_seed", opts.seed)
	end
	st:show_menu(name, params)
	return true
end

-- Closes the top menu.
function M.close()
	local st = game.state()
	if type(st) ~= "table" or type(st.pop_menu) ~= "function" then return false, "not_on_ship" end
	if not (type(st.active_screens) == "table" and #st.active_screens > 0) then return false, "out_of_range" end
	st:pop_menu()
	return true
end

-- The name of every menu this state can open.
function M.menus()
	local st = game.state()
	local out = {}
	for name in pairs(type(st) == "table" and type(st.screens) == "table" and st.screens or {}) do out[#out + 1] = name end
	table.sort(out)
	return out
end

local NO_PING = map.NO_PING

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
	local x, y = map.to_map(pos, level)
	record.player_go:set("map_ping", { clamp(x), clamp(y) })
	return true
end

-- A line in the game's text chat from this player, as if typed: every player sees it under this
-- player's name, players without the mod too. Answers false, "not_available" where the game has no
-- chat (the main menu, a game with no player of this machine).
function M.chat(text)
	if type(text) ~= "string" or text == "" then return false, "bad_type" end
	if #text > 200 then return false, "out_of_range" end
	local st = game.state()
	local chat = type(st) == "table" and st.text_chat
	if type(chat) ~= "table" or not chat.network_router then return false, "not_available" end
	local ok, player = pcall(chat.get_typing_player, chat)
	if not (ok and type(player) == "table" and player.player_index) then return false, "not_available" end
	local sent, err = pcall(chat.network_router.transmit_to_all, chat.network_router, "rpc_text_chat", player.player_index, text)
	if not sent then return false, tostring(err) end
	return true
end

local function pack(...) return { n = select("#", ...), ... } end

-- Runs fn with some of the game's text keys showing other words, as LocalizationManager gives them:
-- texts is { key = words }. Only while fn runs, so a screen of the game can be reused with a mod's
-- words and nothing else changes. Answers what fn answers; an error in fn is raised again after.
function M.with_texts(texts, fn, ...)
	if type(texts) ~= "table" or type(fn) ~= "function" then error("with_texts(texts, fn): bad_type", 2) end
	local lm = game.global("LocalizationManager")
	if type(lm) ~= "table" or type(lm.string) ~= "function" then return fn(...) end
	local real = lm.string
	lm.string = function(self, key, ...)
		local own = texts[key]
		if own ~= nil then return own end
		return real(self, key, ...)
	end
	local r = pack(pcall(fn, ...))
	lm.string = real
	if not r[1] then error(r[2], 0) end
	return unpack(r, 2, r.n)
end

-- Speech over a Helldiver: the words the game shows over a player who uses a quick message (Yes, No,
-- Wait, Move). The game keeps the one showing in the customization component's state of each unit
-- (current_communication_event = { time, duration, event_info = { text = <text key> } }) and draws it
-- in CustomizationComponent.draw_ui, through LocalizationManager:string. A mod's words go under a key of
-- the API's own, which shows them while draw_ui runs.
local SPEECH_KEY = "obsidian_speech_"
local speech = { texts = {}, n = 0, hooked = false }

local function hook_speech()
	if speech.hooked then return end
	speech.hooked = true
	obsidian.hook("CustomizationComponent", "draw_ui", function(original, ...)
		if next(speech.texts) == nil then return original(...) end
		return M.with_texts(speech.texts, original, ...)
	end)
end

-- Shows `text` over the Helldiver `unit` (any player's, this machine only, with no voice or gesture) for
-- `seconds` (the game's 3 when nil), in the look of the game's quick messages, replacing one that shows.
-- Answers false and "no_avatar" for a unit without the game's customization state.
function M.speech(unit, text, seconds)
	if type(text) ~= "string" or text == "" then return false, "bad_type" end
	if seconds ~= nil and not (type(seconds) == "number" and seconds > 0 and seconds <= 30) then return false, "out_of_range" end
	local ctx = unit and game.slaves("customization")[unit]
	local state = type(ctx) == "table" and ctx.state
	if type(state) ~= "table" then return false, "no_avatar" end
	hook_speech()
	-- One key per unit, so words over two players don't overwrite each other.
	local key = state.obsidian_speech_key
	if not key then
		speech.n = speech.n + 1
		key = SPEECH_KEY .. speech.n
		state.obsidian_speech_key = key
	end
	speech.texts[key] = text
	state.current_communication_event = { time = 0, duration = seconds or 3, event_info = { text = key } }
	return true
end

return M
