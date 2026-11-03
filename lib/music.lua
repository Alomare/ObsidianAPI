-- The soundtrack: what plays, holding a track of your choosing across screens, pausing and volume.
-- All of it is local, like the rest of the sound.
--
-- Each screen keeps its music in one place of its own. The main menu's music object, the ship and the
-- mission's start and end screens each hold one event id, and swap it when they change track: a held
-- track takes that id's place, so the screen's own fades go on working on it. The ship sets the volume
-- of that id every frame without asking whether there is one, so the slot never goes empty: silence
-- leaves the stopped id in it. A mission's music comes from its audio state machine instead, which
-- starts threat and action music as patrols and fights come and go. A held track there plays beside
-- them while they're kept silent through their "volume" parameter, the one the machine fades them with.
--
-- The engine pauses only a whole sound world. The main menu and the ship play their music in worlds of
-- their own, so they pause for real; anywhere else a pause is silence, and the track keeps its time.
local game = obsidian.module("lib/game")
local audio = obsidian.module("lib/audio")

local M = {}

-- Every music event the game's scripts start, menus first. A sound bank holds only some of them, so
-- tracks() says which ones the current screen has.
M.TRACKS = { "music_theme", "music_bridge", "music_credits", "music_mission_start", "music_mission_end_success",
	"music_mission_end_failed", "music_jingle", "music_threat", "music_action_bugs", "music_action_cyborgs",
	"music_action_illuminates", "music_action_plus", "music_boss_bugs", "music_boss_cyborgs", "music_boss_illuminates" }

local held = nil      -- the track asked for, or false for silence; nil leaves the music to the game
local paused = false
local current = nil   -- this screen's place, while its state lasts

local function timpani() return game.global("TimpaniWorld") end

-- Where this screen keeps its music. own: the world holds nothing but music, so it can pause.
-- mine: the held track's id here. quiet: the game's id this place stopped and left in its slot.
local function find_place(st)
	if type(st) ~= "table" then return nil end
	local daemon = st.music_daemon
	if type(daemon) == "table" and daemon.timpani_world then
		return { name = "menu", world = daemon.timpani_world, owner = daemon, field = "event_id", own = true, default = "music_theme" }
	end
	if st.music_timpani_world then
		return { name = "ship", world = st.music_timpani_world, owner = st, field = "menu_music_id", own = true, default = "music_bridge" }
	end
	local machine = st.audio_state_machine
	if type(machine) == "table" and machine.timpani_world then
		return { name = "mission", world = machine.timpani_world, machine = machine }
	end
	if st.timpani_world and st.music_event ~= nil then
		return { name = "screen", world = st.timpani_world, owner = st, field = "music_event" }
	end
	return nil
end

local function place()
	local st = game.state()
	if not (current and current.state == st) then
		current = find_place(st)
		if current then current.state, current.paused = st, false end
	end
	return current
end

local function has(p, track)
	return type(track) == "string" and timpani().has_event(p.world, track)
end

local function set_volume(p, id, v)
	if id ~= nil then timpani().set_parameter(p.world, id, "volume", v) end
end

-- The ids of the game's own music in this place.
local function theirs(p)
	local list = {}
	if p.machine then
		if p.machine.music_action ~= nil then list[#list + 1] = p.machine.music_action end
		if p.machine.music_threat ~= nil then list[#list + 1] = p.machine.music_threat end
		return list
	end
	local id = p.owner[p.field]
	if id ~= nil and id ~= p.mine then list[1] = id end
	return list
end

local function start(p, track)
	local id = timpani().trigger_event(p.world, track)
	set_volume(p, id, (paused and not p.own) and 0 or 1)
	return id
end

-- Puts the held track, or silence, in this place: in the game's own slot where there is one.
local function apply(p)
	if p.machine then
		for _, id in ipairs(theirs(p)) do set_volume(p, id, 0) end
		if held and p.mine == nil and has(p, held) then p.mine = start(p, held) end
		return
	end
	local id = p.owner[p.field]
	if p.mine ~= nil and id == p.mine then return end
	-- Anything else in the slot but what this place stopped is the game's, swapped in since.
	if id ~= nil and id ~= p.quiet then timpani().stop(p.world, id) end
	if held and has(p, held) then
		p.mine, p.quiet = start(p, held), nil
		p.owner[p.field] = p.mine
	else
		p.quiet = id
	end
end

local function stop_mine(p)
	if p.mine ~= nil then timpani().stop(p.world, p.mine) end
	p.mine = nil
end

-- Gives the place's music back: the game's track where it was replaced, its volume in a mission.
local function give_back(p)
	if p.machine then
		stop_mine(p)
		for _, id in ipairs(theirs(p)) do set_volume(p, id, paused and 0 or 1) end
		return
	end
	local id = p.owner[p.field]
	local replaced = id ~= nil and (id == p.mine or id == p.quiet)
	stop_mine(p)
	p.quiet = nil
	if replaced and p.default and has(p, p.default) then p.owner[p.field] = start(p, p.default) end
end

local function set_paused(p, on)
	if p.own then
		if on then timpani().pause_all(p.world) else timpani().resume_all(p.world) end
		return
	end
	local v = on and 0 or 1
	set_volume(p, p.mine, v)
	if held == nil then
		for _, id in ipairs(theirs(p)) do set_volume(p, id, v) end
	end
end

-- Each frame, from main.lua: a held track comes back when the screen swaps its own in, and loops; a
-- pause outside a world of its own holds against the game's fades.
function M.tick()
	local p = place()
	if not p then return end
	if p.paused ~= paused then
		p.paused = paused
		set_paused(p, paused)
	elseif paused and not p.own then
		set_paused(p, true)
	end
	if held == nil then return end
	if p.mine ~= nil and not paused and not timpani().is_playing(p.world, p.mine) then
		-- The track ended: start it again in the same slot.
		if p.machine then
			p.mine = nil
		else
			p.quiet, p.mine = p.mine, nil
		end
	end
	apply(p)
end

-- Right after the mission's machine starts its threat or action music, so a held track isn't
-- interrupted for a frame.
function M.after_machine_enter()
	local p = current
	if p and p.machine and held ~= nil then
		for _, id in ipairs(theirs(p)) do set_volume(p, id, 0) end
	end
end

-- The music events this screen can play now.
function M.tracks()
	local p = place()
	local list = {}
	if not p then return list end
	for _, track in ipairs(M.TRACKS) do
		if has(p, track) then list[#list + 1] = track end
	end
	return list
end

-- What plays: place ("menu", "ship", "mission" or "screen", nil where there's no music), track (the
-- held one, nil while the game picks or while silence is held), held (true while either is) and paused.
function M.now()
	local p = place()
	return { place = p and p.name, track = held or nil, held = held ~= nil, paused = paused }
end

-- Plays a music event in place of the game's and holds it, on this screen and the next, until
-- release(). It loops. Only a track this screen has can start it: a screen without it is silent.
function M.play(track)
	if type(track) ~= "string" then return false, "unknown_event" end
	local p = place()
	if not p then return false, "no_music" end
	if not has(p, track) then return false, "unknown_event" end
	if p.mine ~= nil and p.owner then p.quiet = p.mine end
	stop_mine(p)
	held = track
	apply(p)
	return true
end

-- Holds silence: the game's music stops until release().
function M.stop()
	local p = place()
	if not p then return false, "no_music" end
	if p.mine ~= nil and p.owner then p.quiet = p.mine end
	stop_mine(p)
	held = false
	apply(p)
	return true
end

-- Gives the music back to the game.
function M.release()
	local p = place()
	held = nil
	if p then give_back(p) end
	return true
end

function M.pause()
	paused = true
	M.tick()
	return true
end

function M.resume()
	paused = false
	M.tick()
	return true
end

-- The music's volume in decibels, 0 as mixed and -60 silent; nil or false gives it back.
function M.volume(db)
	return audio.bus("music_master", db)
end

return M
