# Obsidian API reference

For people writing mods for Obsidian, and the AI tools they write them with. The guide comes first. The complete list of calls and effects, generated from the source at each release, is at the end.

## Contents

- [Using the API](#using-the-api)
- [The game and its players](#the-game-and-its-players)
- [Changes and effects](#changes-and-effects)
- [Events](#events)
- [Player and gear](#player-and-gear)
- [Stratagems](#stratagems)
- [Enemies and missions](#enemies-and-missions)
- [World, camera and map](#world-camera-and-map)
- [Sound and music](#sound-and-music)
- [Menus, messages and the save](#menus-messages-and-the-save)
- [Bots](#bots)
- [Recipes](#recipes)
- [Rules worth knowing](#rules-worth-knowing)
- [Every call](#every-call)

## Using the API

Obsidian API is a library for mods. It finds things in the game by name, changes them in ways the game accepts, and puts them back when it has to. Obsidian Trainer is built on it and uses nothing you can't use yourself, so if the Trainer can do something, your mod can too.

The sections below go through the whole API, one area at a time. Each call is listed with what it takes, what it answers, and an example. [Recipes](#recipes) puts several of them together into small mods you can copy, and [Rules worth knowing](#rules-worth-knowing) is the short list of things that break the game if you get them wrong.

### Asking for it

List the API in your mod's `obsidian.json`. Obsidian then switches it on with your mod and starts it first.

```json
{
  "obsidian": 1,
  "id": "yourname.panic-button",
  "version": "1.0.0",
  "name": { "en": "Panic Button" },
  "scope": "session",
  "entry": "main.lua",
  "requires": ["obsidian.api"]
}
```

Then import it in your script:

```lua
local api = obsidian.import("obsidian.api")

obsidian.keybind("panic", function()
  api.player.heal()
  api.enemies.kill_near(20)
end)
```

`api` is a table of tables: `api.player`, `api.enemies`, `api.music` and so on. Each one has a section here.

### Client mods and session mods

The API is a library (in Obsidian's Wiki), so it takes the scope of the mod that requires it. Most of what it does changes the game everyone in the lobby shares, and that needs a session mod. A client mod can still require it and stay a client mod, with no effect on matchmaking or the Galactic War. A client mod can:

- read anything: the catalog, the mission's objectives, the lobby, where things are
- show things only this player sees or hears: hints, `api.ui`, `api.map`, `api.audio` and `api.music`
- listen to `api.events`

Anything else answers `false, "needs_session"` in a client mod.

A session mod's changes only run while the lobby is cleared, which means everyone in it runs Obsidian and agreed to session mods. When someone joins who isn't, the API takes its effects and edits off, and calls that change the game answer `false, "not_cleared"`. When the lobby clears again, it puts them back. Scopes (in Obsidian's Wiki) has the details.

### How calls answer

Actions answer `true` when they worked, or `false` and a short reason when they didn't. Calls that make something, such as `api.bots.add`, answer the thing or `nil` and a reason. Nothing throws an error for an ordinary refusal, so you can show the reason or ignore it:

```lua
local ok, why = api.stratagems.call("stratagem_resupply", api.world.cursor())
if not ok then obsidian.toast("No resupply: " .. why) end
```

These are the reasons you'll see:

| Reason | What it means |
|---|---|
| `needs_session` | The call changes the shared game and your mod is a client mod |
| `not_cleared` | Your session mod is waiting for the lobby to clear |
| `not_in_mission` | It only works in a mission |
| `not_on_ship` | It only works on the ship |
| `host_only` | Only the host can do it |
| `alone_only`, `solo_only` | Only with nobody else in the lobby |
| `no_avatar` | The player (or bot) has no body right now: in a hellpod, dead, or not landed yet |
| `no_position` | No position was given, or none could be found, such as the cursor pointing at the sky |
| `not_available` | The item doesn't exist, or it's paid content this player doesn't own |
| `bad_type`, `bad_value`, `out_of_range` | A value of the wrong type, or outside what the game takes |
| `unknown_event`, `unknown_bus`, `unknown_enemy`, `unknown_status`, `unknown_wave`, `unknown_faction`, `unknown_mutator`, `unknown_shading` | The game has nothing by that name, or not loaded on this screen |
| `no_music`, `no_world` | This screen has no music, or no sound world to play in |
| `no_vehicle`, `not_driving`, `seated` | Something about the vehicle the player is or isn't in |
| `spawns_off`, `not_loaded`, `no_enemy` | Spawning is switched off, the enemy's package isn't loaded, or that enemy is gone |
| `close_screen` | Close the ship's menus first |
| `denied` | A console command that reaches the shared backend, a save or paid content |

### A first mod

This one heals the player and clears the enemies around them on a key, and tells them how many it got:

```lua
local api = obsidian.import("obsidian.api")

obsidian.keybind("panic", function()
  if not api.game.in_mission() then return end
  local near = api.enemies.near(20)
  api.player.heal()
  api.enemies.kill_near(20)
  api.ui.hint("Cleared " .. #near .. " enemies")
end)
```

Add the key to `obsidian.json` as Options and keys (in Obsidian's Wiki) shows, and the player can change it in the mod's Keys tab.


## The game and its players

### Where you are: api.game

The game moves between states: the main menu, the ship, the drop, the mission, the results. Most of the API checks the state for you, but your own code often needs to know too.

| Call | Answers |
|---|---|
| `state()` | The state object and its name. The name is `"main_menu"`, `"menu"` (the ship), `"mission_start"`, `"game"` (a mission), `"mission_end"` and a few others |
| `state_name()` | Just the name |
| `in_mission()` | `true` in a mission |
| `on_ship()` | `true` on the ship |
| `is_host()` | `true` for the host, or for a player with no lobby at all |
| `alone()` | `true` with nobody else in the lobby. When it can't tell, it says `false`, because the calls that ask are the risky ones |
| `lobby()` | The game's lobby object, or nil |

```lua
obsidian.on_frame(function()
  if api.game.in_mission() and api.game.is_host() then
    -- host-side mission logic here
  end
end)
```

#### Players and units

A unit is anything with a body in the level: a Helldiver, an enemy, a crate. A player record is the game's entry for a player, which stays while their unit comes and goes with deaths and hellpods.

| Call | Answers |
|---|---|
| `me()` | This player's record. `players[1]` in the game's own list is the first player in the lobby, which isn't always you |
| `my_unit()` | This player's unit, or nil while they have none |
| `avatar(record)` | The unit of a record, when it has a living one |
| `all_avatars()` | Everyone's units this session, yours first: a list of `{ record, unit, owned }` |
| `component(name)` | One of the mission's components, such as `"inventory"` or `"stratagem"` |
| `master(unit, component)` | The state a component keeps for a unit this machine owns |
| `masters(name)`, `slaves(name)` | Every unit's state for a component, as `unit → context` maps, on this machine or as copies from others |

#### Writing to the game safely

Two kinds of write can take the game down, and these calls are there so you don't have to make them by hand.

`command(unit, component, command, data)` queues a command on a unit this machine owns, the way the game's own code changes things. It only takes commands it knows, because the game stops on an unknown one with an error no script can catch. It answers `false` when the game would have stopped.

`protected(component, state, key, value)` writes one of the values the game guards against cheating, such as hitpoints or ammunition, through the game's own setter. Writing those directly cuts the player off from the network. [Rules worth knowing](#rules-worth-knowing) lists them.

```lua
local unit = api.game.my_unit()
api.game.command(unit, "health", "reset")   -- full health, as the game heals
```

#### Small helpers

- `box(v)` and `unbox(t)` turn the game's vectors into tables that last and back. The game's vectors only live for the frame they were made in, so box one before you keep it.
- `after(frames, fn)` runs `fn` that many frames from now, for work the game needs spread out.
- `global(name)` reads one of the game's globals, such as `"LoadoutSettings"`, without a strict-mode error when it isn't there yet.

### Who's playing: api.lobby

| Call | Answers |
|---|---|
| `players()` | A list of `{ peer, name, ping, host, me }`, you included. `ping` is in milliseconds. Teammates have names only during a mission |
| `share(name, value)` | Puts a text of up to 200 characters where every other machine can read it, under your mod's id. Answers `false, "not_available"` without a lobby |
| `shared(name)` | What each other machine shares under that name, as `peer → text`. A machine that shares nothing is left out |

Steam passes a shared text on within about a second, so it suits things that change now and then, like a score or a vote. It's too slow for every frame.

```lua
api.lobby.share("score", tostring(my_score))

local total = my_score
for peer, text in pairs(api.lobby.shared("score")) do
  total = total + (tonumber(text) or 0)
end
```

### Everything by name: api.catalog

The catalog lists what's in the game, by the names the game itself uses: `"weapon_assaultrifle"`, `"stratagem_resupply"`, `"perk_cardio"`. Paid content this player doesn't own is left out of every list, so whatever you offer from here is something they're allowed to use.

| Call | Answers |
|---|---|
| `primaries()`, `sidearms()`, `perks()`, `stratagems()` | The game's loadout lists, each item with its `name` and the game's own fields |
| `support_weapons()` | Stratagems that drop a weapon: `{ name, unit_path }` |
| `backpacks()` | Packs from a crate: `{ name, unit_path, stratagem }`. These are the only paths `api.gear.give_backpack` takes |
| `crates()`, `pickups()` | What stratagems drop, and what lies on the ground once they open: `{ name, unit_path }` |
| `vehicles()` | The seven vehicles |
| `by_subtype(subtype)` | Stratagems of a subtype such as `"turret"` or `"strike"` |
| `stratagem(name)` | One stratagem's entry, custom ones included |
| `enemies(faction)` | Every enemy, or one faction's: `{ key, name, faction, unit, boss, ... }` |
| `enemy(key)`, `enemy_groups()`, `waves(faction)` | One enemy, the groups they come in, and a faction's encounter waves |
| `status_templates()` | Every status effect by name, such as `"flashbang_stun"` |
| `cosmetics(slot)` | Helmets, bodies, capes or characters (`"gender"`) |
| `text(key)` | A display name in the player's language: `text("stratagem_resupply")` is "Resupply" in English |
| `usable(name)` | `false` for paid content they don't own |
| `unlocked(name)` | `true` for what the Loadout screen would offer them: earned by rank or reward, or in a pack they own |
| `max_upgrade(unit_path)` | The highest upgrade value a weapon or pack takes |
| `item_name(unit_path)` | The item a unit path belongs to, by the name its upgrades are kept under |
| `unowned_path(path)` | `true` for a paid weapon's path they don't own |
| `fields(family)`, `families_of(settings)` | What [Changes and effects](#changes-and-effects) can edit, with ranges |

```lua
-- A menu row for every support weapon, with its name in the player's language.
for _, w in ipairs(api.catalog.support_weapons()) do
  page:action(api.catalog.text(w.name), function()
    return api.gear.give_weapon("support_weapon", w.unit_path) and "Done" or "No"
  end)
end
```

`api.data` holds the raw tables behind `fields`: every editable field of weapons, enemies, stratagems and the rest, with its range and when a change takes effect. You rarely need it directly.

## Changes and effects

There are two ways to change how the game plays. An edit changes a number in the game's data, such as a rifle's damage or a stratagem's cooldown. An effect is a switch, such as god mode or low gravity, that the API keeps applied across respawns and missions. Both come off by themselves when the lobby stops being cleared, and go back on when it clears.

### Edits: api.edits

```lua
-- Double the assault rifle's damage, every upgrade level included.
local ok, why = api.edits.set_unit("equipment/wep_assaultrifle_01", "weapon_info.power", 150)

-- A value in any table the game reads.
local resupply = api.catalog.stratagem("stratagem_resupply")
api.edits.set_table("Resupply", resupply, "cooldown_time", 30)
```

| Call | What it does |
|---|---|
| `set_unit(settings_path, path, value, opts)` | Changes a field in a unit's settings file, by the settings path and a dotted field path |
| `set_table(target, t, path, value, opts)` | Changes a field in any table the game reads: a stratagem, a status template, a character's info. `target` is a name for the list of changes |
| `value(settings_path, path)`, `table_value(t, path)` | Reads a field the way the game would |
| `original(settings_path, path)` | Whether a field was changed, and what it was before |
| `list()`, `count()` | Every change: what, where, the old and new value, and which mod made it |
| `revert(id)`, `revert_where(settings_path, path)`, `revert_table(t, path)`, `revert_all()` | Undoes one change, one field, or everything |
| `table_changed(t, path)` | Whether a field of a table was changed |

`opts` can hold:

- `min` and `max`, to refuse values outside a range
- `new = true`, to allow a field the table doesn't have yet
- `also`, a list of more paths in the same table that take the same value, as one change
- `apply`, a note of when the change takes effect, shown by the Trainer

What edits do for you:

- Types are checked, so a number stays a number.
- Tables stay the same tables. Units in play hold on to them, so the API changes the values inside instead of swapping the table.
- A weapon keeps a copy of its settings for every upgrade level, and an edit reaches all of them.
- The guarded values the game checks for cheating are refused. Use `api.game.protected` for those.

#### Which fields, and when they apply

`api.catalog.fields(family)` lists what can be edited for a family such as `"weapon"`, `"enemy"`, `"stratagem"` or `"vehicle"`, with each field's range and when a change takes effect:

| When | Meaning |
|---|---|
| `live` | The next time the game reads it, usually at once |
| `reload` | Cached on things already spawned. It reaches new ones at once, and `api.gear.refresh()` pushes it into weapons in play |
| `spawn` | The next one to spawn |
| `use` | The next call-in or the next time a state starts |
| `loadout` | The next mission or respawn |

`api.catalog.families_of(settings)` says which families a settings table has fields for.

A stratagem's upgrade levels can set a field for themselves, and the game lays them over the base, so an edit of the base alone stops at the first level that has its own. `api.stratagems.edit` changes the field at every level at once:

```lua
api.stratagems.edit("stratagem_railcannon_strike", "cooldown_time", 30)
```

### Effects: api.effects

```lua
api.effects.set("god", true)
api.effects.set("speed", 2)      -- a number is the effect's value
api.effects.set("speed", false)  -- false switches it off
api.effects.is_on("god")         -- true
api.effects.get("speed")         -- 2, or false when off
api.effects.toggle("god")
api.effects.active()             -- the ids of every effect that's on
api.effects.clear()              -- everything off
```

The game rebuilds a lot of state when a mission starts or a player respawns, and would quietly drop a change made before that. An effect remembers it's on and applies itself again each time.

#### Your own effects

```lua
api.effects.define({
  id = "mymod.moon_jump",
  apply = function(ctx, value) end,       -- switched on, and again after each respawn or new mission
  frame = function(ctx, value, dt) end,   -- every frame while on
  remove = function(ctx, value) end,      -- switched off
})

api.effects.set("mymod.moon_jump", true)
```

`ctx` has `state`, `name` (of the state), `record` (this player's) and `unit` (their body). Any of them can be nil, between missions or while the player is in a hellpod. Give every effect a `remove`, so it can come off cleanly when the lobby stops being cleared. Start the id with your mod's name, so it doesn't clash with anyone else's.

#### Every effect

Most of these have a friendlier call in their own section, such as `api.combat.scale` or `api.world.camera.fov`. They all work through `api.effects.set` as well.

| Effect | Value | Does |
|---|---|---|
| `god` | `true` | No damage, falls and seats destroyed under the player included |
| `no_status` | `true` | No status effects such as fire, stun or poison |
| `infinite_stamina` | `true` | Sprint forever |
| `speed` | multiplier | Movement speed in every state |
| `sprint_speed` | number | Top sprint speed |
| `throw_range` | multiplier | How far grenades and flares go |
| `acceleration`, `deceleration` | number | How fast the player starts and stops |
| `ignore_slow` | `true` | Nothing that slows the player through the mover does |
| `no_screen_leash` | `true` | The camera stops holding the player inside the screen |
| `regen` | hitpoints per second | Health regeneration |
| `shield` | shield points | An energy shield that recharges |
| `armor` | number | Armor at every angle |
| `hidden` | `true` | Enemies ignore the player |
| `noclip` | `true` | Walk through anything |
| `hide_model` | `true` | Hides the player's model |
| `heavy_armor_look` | `true` | The heavy armor perk's look, without its armor. Shows in missions only |
| `outline_color` | `{ r, g, b }` | The outline the player shows through walls. `api.player.set_outline` sets it |
| `infinite_ammo` | `true` | Weapons never run dry: every weapon this machine runs, the bots' included |
| `instant_reload` | `true` | Reloads finish at once |
| `no_cooldown` | `true` | Stratagems come back at once |
| `free_stratagems` | `true` | No cooldowns, uses or grenades spent |
| `instant_call_in` | `true` | Flares activate almost at once |
| `fast_pods` | `true` | Hellpods land almost at once |
| `ignore_jammers` | `true` | Stratagems work inside no-stratagem zones |
| `any_arrow` | `true` | Any first arrow calls the stratagem picked with `api.stratagems.select` |
| `no_spawns` | `true` | No new enemies |
| `freeze` | `true` | Enemies stand still. The ones killed fall and go as usual |
| `blind` | `true` | Enemies can't see |
| `host_owns_enemies` | `true` | Every new enemy stays on the host, so the host's edits reach all of them |
| `protect_objectives` | `true` | Convoys and escorted people take no damage |
| `fast_extract` | `true` | Beacon, shuttle and boarding happen at once |
| `skip_waits` | `true` | Objective countdowns finish at once |
| `fast_mission_start` | `true` | No minimum load time before a drop |
| `infinite_respawns` | `true` | Lives never run out |
| `auto_respawn` | `true`, or seconds | A dead player drops back in after 3 seconds (or the seconds given), with no reinforcements left and in a lobby too |
| `no_game_over` | `true` | A wipe doesn't end the mission |
| `time_scale` | multiplier | Game speed. On the host it's everyone's game |
| `pause` | `true` | Stops the game |
| `camera_distance` | metres | How far the camera sits (17 at the start of a mission) |
| `camera_angle` | degrees | How steeply it looks down (65 at the start) |
| `free_camera_bounds` | `true` | The camera can leave the map |
| `no_camera_shake` | `true` | No shakes |
| `photo_mode` | `true` | Freezes the camera and clears the screen. `api.world.camera.photo` sets it |
| `hide_hud` | `true` | No HUD |
| `show_patrols` | `true` | Patrol routes on the map |
| `test_info` | `true` | The game's own debug text |
| `no_fog`, `no_dof` | `true` | No fog, no depth of field |
| `exposure` | number | Brightness, 1 as the planet has it |
| `time_of_day` | `"dawn"`, `"day"`, `"dusk"` or `"night"` | The light of another time of day |
| `gravity` | number | -18 is normal, nearer 0 is floatier |
| `mute_music` | `true` | Music off |
| `vehicle_speed`, `vehicle_turn` | multiplier | The driven vehicle's speed and turning |
| `vehicle_armor` | number | The driven vehicle's armor |
| `vehicle_god`, `vehicle_rockets` | `true` | No vehicle damage, endless exosuit rockets |

A few are set through their own call and keep their value under a longer id: `api.audio.bus` (`bus_<name>`), `api.world.shading` (`shading_<name>`), `api.player.immune` (`immune_<name>`), `api.combat.scale` (`damage_to_players`, `damage_to_enemies`), `api.enemies.set_pressure` (`enemy_cap`, `enemy_difficulty`, `patrol_count`, `patrol_interval`), `api.mission.mutator` (`mutator`), and the camera's `camera_fov`, `camera_spin` and `camera_spectate`.

## Events

The game tells its own systems when something happens: an enemy dies, a stratagem lands, a player goes down. `api.events.on(name, fn)` lets your mod listen in.

```lua
local kills = 0

api.events.on("on_enemy_killed", function(unit, attacker, owner)
  kills = kills + 1
  if kills % 50 == 0 then api.ui.hint(kills .. " down") end
end)
```

| Call | What it does |
|---|---|
| `on(name, fn)` | Calls `fn` each time the event happens. Answers `false, "unknown_event"` for a name the game doesn't have |
| `off(name, fn)` | Stops it. A function can take itself off while its event is being handled |
| `NAMES` | Every event name below |

### The events

| Event | Your function gets | When |
|---|---|---|
| `on_enemy_killed` | `unit`, `attacker`, `owner`, `damage_type` | This player got a kill. `damage_type` is there only when this game worked out the hit |
| `on_enemy_spawned` | `unit`, `enemy_name` | An enemy appeared, on every player's game |
| `on_player_death` | `unit` | A player died, on every player's game |
| `on_objective_completed` | nothing | An objective was finished |
| `on_stratagem_pre_activated` | `stratagem`, `position`, `owner`, `flare` | A flare's countdown started |
| `on_stratagem_activated` | `peer`, `stratagem`, `position`, `unit` | A stratagem's countdown ended, on every player's game |
| `on_stratagem_used` | `unit`, `data` | A player used a stratagem |
| `on_stratagem_wielded` | `unit`, `flare`, `info` | A player took a flare in hand |
| `on_avatar_extract` | `unit`, `shuttle` | This player boarded the shuttle |
| `on_extract_shuttle_landed` | `unit` | The shuttle landed |
| `on_killed` | `unit`, `attacker`, `owner` | Anything with health was killed |
| `on_dead` | `unit` | A unit's death finished playing out |
| `on_health_downed` | `unit`, `state` | A player went down |
| `on_damage_taken` | `unit`, `hit` | A unit lost health. `hit` has `damage`, `hit_zone`, `attacker_unit` and `owner_unit` |
| `on_health_received` | `unit`, `amount` | A unit was healed. A full heal passes neither |
| `on_add_to_stat` | `unit`, `stat`, `amount` | A statistic went up, such as `"stratagems_used"` or `"hits"`. This one comes often |
| `on_pause` | `paused` | The pause menu opened or closed |
| `on_mission_end` | `stats`, `extra` | The end screens have the results |

`stratagem` in the stratagem events is the game's entry for it, with `name`, `id` and the rest. Custom stratagems arrive with their own entry on the thrower's game, and as their base on everyone else's.

### Things to know

- Events arrive on this machine only. "On every player's game" means each player's game sees it and tells its own mods, so in a lobby of four, four games each hear one enemy die.
- A function that fails counts against your mod, and the other listeners still run.
- Nothing arrives while a session mod's lobby isn't cleared. A client mod hears events in any lobby.
- `position` and `hit` only last the frame they arrive in. Copy what you need: `local x, y = position.x, position.y`.
- Listening costs nothing until a mod asks for an event, so ask only for the ones you use.

### Example: a kill streak

Ten kills without dying plays the objective sting:

```lua
local streak = 0

api.events.on("on_enemy_killed", function()
  streak = streak + 1
  if streak == 10 then api.audio.stinger("music_objective_complete") end
end)

api.events.on("on_player_death", function(unit)
  if unit == api.game.my_unit() then streak = 0 end
end)
```

## Player and gear

Everything in this section acts on the player of this machine. Calls that take a `unit` can act on another player this machine plays instead, such as a [bot](#bots) or a second controller. Leave it out for the main player.

### Staying alive: api.player

| Call | What it does |
|---|---|
| `heal(unit)` | Full health and no status effects |
| `heal_by(amount)` | Adds hitpoints, past the maximum if you ask for more |
| `set_health(hitpoints)` | Sets hitpoints, anything above 0 |
| `revive()` | Up from downed |
| `respawn()` | A dead player comes back at once. Answers `false, "alive"` when they aren't dead |
| `heal_everyone()`, `revive_everyone()` | The same for every player, through each one's own game |
| `lives()`, `set_lives(n)` | The lobby's reinforcements. The game only counts them with nobody else in the lobby |
| `knockdown()` | Knocks the player down, as a blast does |
| `damage(unit, power, opts)` | A hit on any Helldiver, a teammate's included. `opts.through_armor`, `opts.statuses` (status templates) and `opts.owner` (the unit it comes from) shape it |
| `drop_carried()` | Drops whatever they carry, such as a hard drive |
| `clear_status(name)` | Takes off a status, by template name or by element such as `"fire"` |
| `immune(name, on)` | Keeps a status off across respawns, until `on` is `false` |

```lua
-- Never burn again.
api.player.immune("fire", true)
```

Health belongs to whoever owns the body, so all of this works on a client too. A hit on a Helldiver is worked out on the machine that plays the body, so `damage` on a teammate goes to that machine through the lobby and lands there a moment later, when that machine runs Obsidian API 1.33.0 or later.

### Getting around

| Call | What it does |
|---|---|
| `teleport(pos, unit)` | Moves the player to a position, nudged up until they fit. Answers `false, "seated"` in a vehicle |
| `teleport_cursor()`, `teleport_ahead(metres)` | To the cursor, or some metres in front |
| `teleport_spawn()`, `teleport_objective()`, `teleport_extraction()` | To where the mission started, the next objective, or extraction |
| `unstick()` | Back onto the map from wherever they got stuck |

Movement itself is a set of effects: `speed`, `sprint_speed`, `acceleration`, `noclip`, `infinite_stamina` and more. [Changes and effects](#every-effect) lists them.

### Looks

| Call | What it does |
|---|---|
| `set_cosmetic(slot, index)` | Changes the helmet, body, cape or character (`"gender"`), with an index from `api.catalog.cosmetics(slot)`. It comes back after a respawn |
| `set_outline(r, g, b)` | The outline the player shows through walls. `set_outline(nil)` gives the team colour back |
| `taunt()` | Plays a taunt |

### Weapons and ammunition: api.gear

| Call | What it does |
|---|---|
| `refill(unit)` | Fills every weapon. For beam weapons that means no heat |
| `refill_grenades(unit)` | Fills grenades |
| `refill_backpack()` | Fills the backpack's uses |
| `set_grenade(path)` | Changes the grenade type: `equipment/equipment_grenade_01`, `_incendiary`, `_stun` or `_smoke` |
| `give_weapon(slot, path, upgrade, unit)` | Puts a weapon in `"primary_weapon"`, `"sidearm_weapon"` or `"support_weapon"`. The old one drops to the ground |
| `weapons_of(owner)` | The weapons a player holds: `{ unit, component, slot, info }` |
| `tune(unit, component, changes)` | Changes one weapon's numbers, leaving every other weapon of its type alone |
| `refresh()` | Pushes cached settings into the weapons in play, after an edit |

`upgrade` runs from 0 to 15. Leave it out for the upgrades the player owns for that weapon, and use `api.catalog.max_upgrade(path)` for all of them. A paid weapon they don't own answers `"not_available"`.

```lua
api.gear.give_weapon("primary_weapon", "equipment/wep_assaultrifle_01", 3)
```

#### Tuning one weapon

An [edit](#changes-and-effects) changes a weapon's type for everyone holding it on that machine. `tune` changes one weapon in one player's hands. `changes` holds a factor for a number and `true` or `false` for an attribute. Each call replaces the last one, and `{}` takes it all off.

```lua
for _, w in ipairs(api.gear.weapons_of()) do
  api.gear.tune(w.unit, w.component, { firerate = 1.5, armorpiercing = true })
end
```

The component `"melee"` tunes that weapon's melee attack instead, with `power`, `duration` (how long the swing holds the player, so smaller swings faster) and `delay` (how soon it hits). Tuning reaches only the weapons this machine owns, so each player's game tunes their own.

### Perks

| Call | What it does |
|---|---|
| `give_perk(name, unit)` | Changes the main perk, as the game's console does |
| `remove_perk(unit)` | Takes it away |
| `add_perk(name, unit)` | Adds a perk on top of the main one |
| `remove_extra_perk(name, unit)`, `extra_perks(unit)` | Takes one added perk off, or lists them |

Laser sight runs code every frame that other players' games can't set up, so `give_perk("perk_lasersight")` answers `"alone_only"` with others in the lobby, and `add_perk` refuses it with `"not_available"`. Added perks go when the player dies, like the body they were on, so add them again after a respawn.

### Backpacks and drones

`give_backpack(path, upgrade, unit)` takes only paths from `api.catalog.backpacks()`. The game reads settings that other paths don't have, in a place where nothing can catch the error. The old pack drops.

`add_drone(path, unit, upgrade)` gives a player a drone pack's drones and leaves their backpack slot alone. `path` is a drone pack from `api.catalog.backpacks()`, such as `equipment/equipment_drone_defensive_backpack_01`. The drones need the pack's station to dock and reload, so the station rides on the player as a worn pack would, and every game running Obsidian API hides it. Call it again for more drones. It answers a drone with `alive()` and `remove()`.

```lua
local dog = api.gear.add_drone("equipment/equipment_drone_defensive_backpack_01")
-- later
dog:remove()
```

Drones dock while their player sits in a vehicle, and go when the player dies.

### Vehicles: api.vehicles

| Call | What it does |
|---|---|
| `current()` | The vehicle the player is in, or nil |
| `driving()` | `true` while they drive it |
| `driven()` | The vehicle they're driving, once it's theirs (a moment after getting in) |
| `repair()`, `refill()` | Repairs it, or refills its weapons |
| `near(pos, radius)`, `nearest(pos, radius)` | Vehicles, exosuits and mannable turrets within `radius` (10 metres) of a position or the player, nearest first, or the nearest one |
| `kind(v)` | `"exosuit"`, `"apc"`, `"bike"`, `"tank"` or `"turret"` |
| `seats(v)` | The seats: `{ index, name, drives, unit, free, weapons }` each, where `weapons` lists the guns that seat fires and the trigger each one is on |
| `seat_of(unit)` | The vehicle a Helldiver sits in and the seat's index, or nil |

The effects `vehicle_speed`, `vehicle_turn`, `vehicle_armor`, `vehicle_god` and `vehicle_rockets` reach the vehicle the player drives, and let go when they get out. A passenger's game can't change it.

## Stratagems

### Cooldowns and uses

| Call | What it does |
|---|---|
| `reset_cooldowns()` | Every stratagem of this player is ready again |
| `refill_uses()` | Every stratagem gets its uses back |
| `give(name, unit)` | Adds a stratagem to the player's eight slots, or gives a use back when they already have it |
| `edit(name, field, value)` | Changes a field of a stratagem at every upgrade level, such as `"cooldown_time"` |

The effects `no_cooldown`, `free_stratagems`, `instant_call_in`, `fast_pods` and `ignore_jammers` cover the rest. [Changes and effects](#every-effect) has the list.

### Calling one down

`call(name, pos, delay, unit)` puts down a real flare, the way the game does for its own timed drops. There's the sound and the countdown, patrols hear it, and Reinforce works. No cooldown or use is spent, and it's called at the upgrade level the player owns. `delay` adds seconds on top of the stratagem's own call-in time. `unit` calls it as another player on this machine, so the call-in and its kills are theirs.

```lua
api.stratagems.call("stratagem_resupply", api.world.cursor(), 15)
api.stratagems.call("stratagem_airstrike", { x = 100, y = 220, z = 0 })
```

`pos` is the game's vector or a plain `{ x, y, z }` table.

`drop(name, pos)` is the quick one: the hellpod or strike arrives with no flare and no wait. It can't do Reinforce, which needs a flare, and answers `"needs_flare"`.

`select(id)` with the effect `any_arrow` on makes any first arrow call the chosen stratagem, by its index in the game's list. The Trainer uses it for "Any arrow calls".

### Your own stratagems

`define(def)` adds a stratagem to the game's list. It starts as a copy of one of the game's own, its base, and you change what you want. It answers `{ name, id }`, or `nil` and a reason.

```lua
api.stratagems.define({
  name = "mymod_pitchfork",
  base = "stratagem_lasercannon",
  title = { en = "Pitchfork", fr = "Fourche" },
  description = "Three barrels, three times the heat.",
  code = { "down", "left", "up", "down", "left", "right" },
  icon = "stratagem_lasercannon",
  stats = { cooldown_time = 60, num_uses = 2, activation_time = 2 },
  upgrades = {
    { title = "Pitchfork Light", description = "Move while firing.", cost = 3, stats = { cooldown_time = 45 } },
  },
})
```

Call `define` while your mod starts, in the main chunk. The game doesn't have its stratagem list yet then, so `define` answers `{ name = ..., pending = true }` and makes the stratagem once the list is there, before the save's loadout is read, so a saved loadout naming it keeps it. A mistake in the definition itself is still answered at once; one only the game's list shows, such as a base it hasn't got, goes to the log. Called later, `define` answers `{ name, id }` straight away.

#### What you can set

| Field | What it is | Left out |
|---|---|---|
| `name` | Its key: letters, digits and `_`, and new. Start it with your mod's name | Required |
| `base` | One of the game's stratagems. It's copied, and it's what other players see | Required |
| `title` | Its name, as a string or a table by language: `en`, `fr`, `es`, `pt-BR` | Required |
| `description` | The words under it in the Loadout screen | The base's |
| `code` | The arrows, `"up"`, `"down"`, `"left"` and `"right"`, from 1 to 10 of them | The base's |
| `icon` | An icon the HUD already has, as any stratagem's `icon` field names it | The base's |
| `type` | `"supply"`, `"offensive"`, `"defensive"` or `"special"`, which sorts it in the Loadout screen | The base's |
| `subtypes` | The game's tags, such as `{ "support_weapon", "weapon" }` | The base's |
| `unit` | What it calls down. It has to be a unit every game has | The base's |
| `stats` | Fields of the entry: `num_uses`, `cooldown_time`, `activation_time`, `despawn_time`, `patrol_alert_radius` and others the base has | The base's |
| `attributes` | The bars the Loadout screen shows, as the game's `attr_` fields | The base's |
| `upgrades` | Its levels from Mk2 on. Each has `title`, `description`, `cost`, `stats`, `attributes`, `upgrade_attributes` and `icon` | The base's levels, named after yours ("Pitchfork Mk2") |
| `on_activate` | A function that runs when it's called down | Nothing more than the base does |

A value of the wrong type is refused with `"bad_type"`, a name in use with `"taken"`, a base the game doesn't have with `"not_available"`, and arrows that aren't arrows with `"bad_code"`.

#### Making it do something

`on_activate(ctx)` runs on the thrower's machine when the flare's countdown ends, right before the hellpod or strike would go out. `ctx` has:

- `name`: your stratagem's name
- `position`: where it landed, as the game's vector, good for that frame only
- `owner`: the thrower's unit
- `upgrade`: the level it was called at

Answer `false` to stop the base's drop. Anything else lets it go ahead as well.

```lua
api.stratagems.define({
  name = "mymod_thunder",
  base = "stratagem_airstrike",
  title = "Thunder Call",
  code = { "up", "up", "down", "down" },
  on_activate = function(ctx)
    api.world.flash()
    api.world.explode(ctx.position, 3000, 10)
    for _, enemy in ipairs(api.enemies.near(15, ctx.position)) do
      api.enemies.apply_status(enemy, "flashbang_stun")
    end
    return false   -- no airstrike, just the thunder
  end,
})
```

What `on_activate` does goes through the API's ordinary calls, so it reaches other players the way those calls do: explosions, spawns and status effects happen in everyone's game.

#### What other players see

Nobody else's game has your stratagem, so on the network it is always its base. The stratagem ids in the game's messages, and in the loadout and flare fields it copies to other machines, go out as the base's. A player without your mod is never sent an id their game doesn't know. They see your flare, the HUD icon and the call-in as the base's, and what lands is whatever your stratagem calls down, which is why `unit` has to be something every game has.

This holds in any lobby, cleared or not. In a lobby that isn't cleared, the stratagem also plays as its base on your own machine: the base's numbers and call-in, and no `on_activate`.

#### Unlocks and the save

`unlock` in the def says when the Loadout screen offers it, while session mods are on:

| `unlock` | Offered |
|---|---|
| `"base"`, or left out | To a player who has the base, by rank, reward or a DLC they own |
| `"free"` | To everyone, from the start |
| `{ rank = n }` | From rank `n` on, as the game's own rank unlocks |
| `"manual"` | Once your mod calls `api.stratagems.unlock(name)` |

`unlock(name)` opens any custom stratagem, whatever its `unlock` says, and `lock(name)` takes that back. Use them for a progression of your own: a mission done, a goal reached. What they open is kept by Obsidian API for the next launch, never in the game's save. `is_unlocked(name)` answers whether the Loadout screen offers it now.

```lua
api.stratagems.define({ name = "mymod_tower", base = "stratagem_tesla_tower", title = "Repair Tower", unlock = "manual" })

-- Ten objectives done open it for good.
local done = 0
api.events.on("on_objective_completed", function()
  done = done + 1
  if done == 10 then api.stratagems.unlock("mymod_tower") end
end)
```

- A base from a paid pack stays paid.
- `api.catalog.unlocked(name)` and `usable(name)` answer by its `unlock`, or as for its base.
- The save keeps its upgrades under its own name, like any stratagem's.
- When your mod is off, a saved loadout that has it gets the default stratagem in that slot. The save keeps working.

#### Listing them

`custom()` answers every custom stratagem made so far, from any mod, as `{ name, base, id }`.

## Enemies and missions

### Finding enemies

| Call | Answers |
|---|---|
| `list()`, `count()` | The living enemies this machine knows about |
| `near(radius, pos)` | Living enemies within a radius of a position, or of the player, nearest first |
| `nearest(pos)` | The closest one, and how far away it is |
| `info(unit)` | `{ key, name, faction, boss, hitpoints, max_hitpoints, owned }` |
| `carried()` | Everything the map is carrying: the living, corpses that haven't decayed yet, and the spawn queue |
| `room()` | How many more fit under `MAX_SAFE` |
| `available(enemy)` | Whether an enemy from the catalog can spawn right now, which needs its package loaded |

```lua
local bug, metres = api.enemies.nearest()
if bug and metres < 10 then api.enemies.apply_status(bug, "flashbang_stun") end
```

### Spawning

| Call | What it does |
|---|---|
| `spawn(key, count, where)` | Spawns enemies by catalog key or unit path. `where` is `"cursor"`, a position, or nothing for in front of the player |
| `spawn_group(key, where)` | One of the game's enemy groups, from `api.catalog.enemy_groups()` |
| `force_wave(name, pos)` | A wave from `waves()` right now, all at once, at a position or ten metres ahead |
| `waves()` | The waves this mission's faction can have |
| `spawn_entity(path, pos)` | A crate or pickup, by a path from `api.catalog.crates()` or `pickups()` |
| `call_encounter()`, `add_patrol()` | Starts an encounter, or sends another patrol, as the game would |
| `load_faction(name)` | Loads `"bugs"`, `"cyborgs"` or `"illuminates"` mid-mission, so they can spawn on any planet |

Spawning on a client sends the request to the host, which spawns for everyone. Groups and waves are the host's to make.

The game normally keeps a mission to 16 enemies. Far more than that has taken missions down with no error, so the Trainer stops at `MAX_SAFE`, 64 including corpses. `spawn` itself doesn't stop you: check `room()` first.

`load_faction` answers `"alone_only"` with anyone else in the lobby, because every game needs the package to show the enemy. The game pauses for a moment while it loads, and it's unloaded when the mission ends.

### Getting rid of them

| Call | What it does |
|---|---|
| `kill(unit)`, `kill_near(radius)`, `kill_all()` | Kills, with corpses and kill credit |
| `despawn(unit)`, `despawn_all()` | Gone, with no corpse, no kill and no objective progress |
| `damage(unit, power, statuses, opts)` | A hit from this player. Armor counts, unless `opts.through_armor` is `true`. `statuses` is an optional list of status names |
| `set_hitpoints(unit, hitpoints)` | Sets an enemy's health |
| `apply_status(unit, template)` | A status effect, such as `"flashbang_stun"` or `"heavy_burn"`. Names are in `api.catalog.status_templates()` |
| `stun_near(radius)` | Stuns every enemy within a radius of the player |

Each enemy is run by one player's game, its owner, and these calls go through whichever game that is. They work on any enemy from any player's machine.

### How hard it pushes

```lua
api.enemies.set_pressure({ cap = 24, difficulty = 15, patrols = 20, interval = 4 })
api.enemies.set_pressure({ difficulty = false })   -- that one back to the game
```

`set_pressure(t)` makes fights bigger without changing the mission. It's the host's call.

- `cap`: the most enemies at once, up to `MAX_CAP` (32). It lifts both limits waves stop at.
- `difficulty`: what each encounter can spend on enemies.
- `patrols` and `interval`: how many patrols, and how often they come.

A number sets one, `false` gives it back, and a key left out stays as it is. The effects `no_spawns`, `freeze`, `blind` and `host_owns_enemies` do the rest.

### The mission: api.mission

| Call | What it does |
|---|---|
| `objectives()` | Every objective: `{ name, text, type, state, group, done, total, position }`. `state` is `"pending"`, `"complete"` or `"failed"` |
| `finish_objectives()`, `restart_objectives()` | Completes every objective, or starts them over |
| `win()` | Wins now, with no shuttle. Everyone counts as extracted |
| `abort()` | Back to the ship, as the pause menu does it |
| `spawn_samples()`, `collect_samples()` | Research samples on every marker, or all of them collected |
| `reveal_map()` | The whole map uncovered |
| `params()` | What the mission's seed says: faction, planet, difficulty, `layout` and the rest |
| `mutator(name)` | One of the proving ground modifiers in any mission, or `nil` for none |
| `seed(choice)` | A mission seed from chosen parts |
| `practice(choice)` | Starts a solo practice mission from the ship |
| `drop(choice)` | Starts a solo real mission from the ship, which pays XP and leaves the campaign alone |

Objectives and the end of a mission belong to the host.

#### Modifiers

| Name | What it does |
|---|---|
| `super_boots` | 40% faster on foot |
| `what_goes_around` | Damage to a teammate comes back to the shooter |
| `orbital_support` | Support stratagems land near a player every 20 seconds |
| `orbital_bombardments` | Strikes land near a player every 15 seconds, plus their call-in |

There's one at a time, and a real proving ground keeps its own.

#### Practice missions and custom drops

`practice(choice)` starts a mission the way the game's training menu does: it pays no XP or samples and doesn't touch the campaign. `drop(choice)` starts the same mission as a real one: XP, samples and unlocks count as in any drop. At the mission's end the planet in the save is hidden, and the campaign keys, the Galactic War and leaderboard reports and the player's boss influence go back to their values from the moment of the drop, win or loss. Both take the same `choice`, which picks each part by its place in a list, starting at 1:

```lua
api.mission.practice({
  time = 2,          -- api.mission.TIMES: dawn, day, dusk, night
  environment = 1,   -- ENVIRONMENTS: desert, forest, snow, lava, city
  enemy = 1,         -- FACTIONS: bugs, cyborgs, illuminates
  kind = 1,          -- TYPES: mission, boss, genocide
  difficulty = 3,
  look = 4,          -- LOOKS, optional: terrain_1-3, bug_world, cyborg_world, illuminate_world
  layout = 120,      -- 1 to LAYOUTS (215), optional
})
```

It works from the ship, with nobody else in the lobby. Anything else answers `"not_on_ship"` or `"solo_only"`.

`look` and `layout` are random when left out. A planet has three terrain sets (city has two). The faction looks are the worlds event planets have, each on one planet type: `bug_world` on desert, `cyborg_world` on snow, `illuminate_world` on forest. Another pairing answers `"look_not_here"`, since the game has no art for it. The seed holds 215 layouts for each set of parts, and the same layout with the same parts gives the same map.

`seed(choice)` makes the seed without starting anything, for a mod that starts missions its own way: a number, or `false` and `"bad_choice"` or `"look_not_here"`. Every player's game builds the map from the seed alone, so a seed made this way needs nothing else on the other machines.

### Damage: api.combat

```lua
api.combat.scale({ players = 0.5, enemies = 2 })   -- half damage to players, double to enemies
api.combat.scale({ enemies = false })              -- enemies back to normal
```

A multiplier from 0 to 100, applied after armor, so armor that stops a shot still stops it. `1` or `false` turns a side off. The game works out a hit without knowing who fired it, so the scale goes by who's hit. Each player's game works out its own hits, so everyone in a lobby should use the same numbers.

Two kinds of hit can be heard as they're worked out:

| Call | Your function gets | When |
|---|---|---|
| `on_hit(fn)` | `victim`, `hit` | A player of this machine landed a hit that cost health, on an enemy any machine runs. `hit` has `damage`, `owner_unit` (the player), `attacker_unit` (the weapon, grenade or projectile) , `slot`: `"primary_weapon"`, `"sidearm_weapon"` or `"support_weapon"` when the attacker is a weapon the player holds, else `nil`, and `position`, where it landed as `{ x, y, z }`, when the hit carries one. Teammates and the player's own body count as victims too |
| `on_fatal(fn)` | `unit`, `damage` | A hit would kill a player of this machine. Answer `true` to spare them: the hit leaves them 1 hitpoint, or a downed player as they were |

`off_hit(fn)` and `off_fatal(fn)` stop them. `on_damage_taken` in [Events](#the-events) only reaches the machine that runs the victim, so in a lobby it misses most of your hits on enemies; `on_hit` doesn't. A rocket's or a grenade's hit has no `slot`.

Hearing a hit changes nothing, so `on_hit` works for client mods and in any lobby. `on_fatal` changes the game: it needs a session mod, and spares nobody where session mods aren't cleared.

```lua
-- Every third rifle hit on an enemy sets it alight.
local count = {}
api.combat.on_hit(function(victim, hit)
  if hit.slot ~= "primary_weapon" or not api.game.global("EntityAux").has_component(victim, "enemy") then return end
  count[victim] = (count[victim] or 0) + 1
  if count[victim] % 3 == 0 then api.enemies.apply_status(victim, "regular_burn") end
end)
```

## World, camera and map

### Positions

Most calls that need a place take a position: the game's vector, or a plain `{ x, y, z }` table. These find one for you.

| Call | Answers |
|---|---|
| `api.world.cursor()` | The point of the level under the mouse. When the ray from the camera hits nothing, where it meets the ground |
| `api.world.ahead(metres)` | A point some metres in front of the player |
| `api.world.to_screen(pos)` | Where a point of the level is on the screen, in pixels from the bottom left, and whether it's in view |
| `api.world.raycast(from, to, filter)` | The first thing on the line between two points: `true`, where and how far along, or `false`. `filter` is one of the game's collision filters, `"default"` when left out. `"mover_blocker"` is what stops a body walking, so ask it before moving a player |

The game's vectors last only the frame they were made in. Keep a position for later as numbers, or with `api.game.box`.

```lua
local p = api.world.cursor()
local saved = p and { x = p.x, y = p.y, z = p.z }
```

### Things in the level

`api.world.explode(pos, power, radius)` sets off an explosion through the game's own manager, which does the damage and the push. The Trainer's blast starts at a power of 500 and a radius of 8 metres.

#### Shots and blasts

The game's guns, the plasma weapons and the rockets included, fire rays, not projectiles: the shot hits the first thing on its line at once, and the plasma rifle, the plasma pistol and the rockets add an explosion from their settings' `explosive_info` where it lands. `api.world.shoot` does the same from any point:

```lua
local me = api.world.placement(api.game.my_unit())
local from = { x = me.x, y = me.y, z = me.z + 1 }
local to = { x = me.x + 15, y = me.y, z = me.z + 1 }
local ok, landed, unit = api.world.shoot(from, to, { power = 200, explosion = "equipment/wep_plasma_01", spare_players = true })
```

`api.world.blast(pos, "equipment/equipment_grenade_01")` sets off an item's explosion by itself. The damage reaches every machine's units as the player's own hits do, and the explosion's look shows on this machine only, as with `api.world.arc`. With `spare_players`, damage to Helldivers is dropped, though the push of the blast still reaches them.

#### Arcs and effects

The game draws its lightning as particle effects and deals the damage separately, so a mod can do the same from anywhere. `api.world.arc(points)` draws a bolt from each point to the next, and `api.enemies.chain` picks the enemies an arc would jump between:

```lua
local me = api.world.placement(api.game.my_unit())
local targets = api.enemies.chain(me, 4, 12, 6)   -- up to 4: the first within 12 m, then 6 m per jump
local path = { { x = me.x, y = me.y, z = me.z + 1 } }
for _, enemy in ipairs(targets) do
  api.enemies.damage(enemy, 150)
  path[#path + 1] = api.world.placement(enemy)
end
if #path > 1 then api.world.arc(path) end
```

Drawing shows on this machine only. For other players to see it, send what to draw with `api.lobby.share`, and have the mod draw it on their side. `api.enemies.damage` only hits enemies, so an attack built this way never hurts a player.

`api.world.attach_effect(unit, "shock")` puts the crackle of a shocked Helldiver on a unit (`"enemy_shock"`, `"fire"`, `"poison"`, `"confuse"` and `"stun"` are the game's other status looks), following the body until `api.world.detach_effect(handle)`. Only the effects named in `api.world.EFFECTS` can be drawn: each one is in a package every mission loads, and drawing an effect that isn't loaded crashes the game.

`api.world.prop(unit, pos, opts)` places one of the game's units in the level, on this machine only. Nothing goes over the network and no game system knows about it, so it does nothing but be seen, with whatever glow the unit has. `opts.scale` sets its size, 1 as made. It answers a prop:

| Call | What it does |
|---|---|
| `move(pos)` | Moves it |
| `scale(size)` | Resizes it |
| `flow(event)` | Runs one of the unit's own flow events, the way the game plays a unit's sounds and effects. `"on_picked_up"` on a research sample plays the pickup |
| `alive()` | `false` once it's removed or the level is gone |
| `remove()` | Takes it away |

```lua
local sample = api.world.prop("gameobjects_spec/gameobject_bug_research_object", pos, { scale = 2 })
sample:flow("on_picked_up")
sample:remove()
```

The unit has to be in a package the level has loaded, or the game stops. A mission's research samples, `gameobjects/flare_01` and the enemies of a loaded faction are safe.

`api.world.clear_decals()` cleans the marks shots and blasts leave on the ground.

### The camera

All of this is this player's alone.

```lua
api.world.camera.fov(90)                    -- degrees, 10 to 120; nil gives it back
api.world.camera.spin(30)                   -- degrees around the player
api.world.camera.spectate(friend_unit)      -- nil comes back to you
api.world.camera.photo(true)                -- freezes the camera and clears the screen
api.world.camera.place(position, rotation)  -- moves it, in photo mode
```

- `spectate` takes another player's unit, from `api.game.all_avatars()`.
- A low spin or a shallow angle can make aiming feel odd, because the mouse aims in screen space.
- The effects `camera_distance`, `camera_angle`, `free_camera_bounds` and `no_camera_shake` cover the rest.

#### Taking the camera

`api.world.camera.take()` stops the game moving the camera, in a mission or on the ship. From then on it sits where `set(pose)` puts it, every frame, until `release()` or the next screen. A pose is plain numbers, so keep one from frame to frame:

| Field | What it is |
|---|---|
| `position` | `{ x, y, z }` in metres |
| `yaw` | Degrees about the up axis. 0 looks along +y, the level's north, and it grows turning left |
| `pitch` | Degrees up (positive) or down (negative), held short of straight up or down |
| `roll` | Degrees the picture tips |
| `fov` | The vertical field of view, 5 to 150 degrees |
| `ortho` | A width in metres to draw without perspective, as a plan; `false` goes back to perspective |
| `far` | How far the camera sees, in metres; the game's own reach when left out |

`get()` answers the pose now, the game's own camera when nothing has taken it. `forward(yaw, pitch)` answers the way a pose looks, as `{ x, y, z }`, for moving along it.

```lua
api.world.camera.take()
local pose = api.world.camera.get()
obsidian.on_frame(function()
  local dt = rawget(_G, "ENGINE_DT") or 0.016
  local f = api.world.camera.forward(pose.yaw, pose.pitch)
  pose.position.x = pose.position.x + f.x * 4 * dt   -- glides ahead at 4 m/s
  pose.position.y = pose.position.y + f.y * 4 * dt
  api.world.camera.set(pose)
end)
```

The game's other camera work stops while it's taken: the listener for sounds stays where it was, and shakes don't reach it. Grass and other scattered detail follow what the camera looks at.

### Photos: lights, time and screenshots

These are for a photo mode, and all of them are this player's alone.

`api.world.light(pos, opts)` puts a light in the level: a beacon flare, hidden, with no physics, and its light taken over. `opts` takes `color` (`{ r, g, b }` from 0 to 1), `intensity`, `range` (metres it reaches), `shadows` (`true` casts them) and `spot` (an angle in degrees makes a spotlight, pointing along `yaw` and `pitch`). It answers a light with `set(opts)`, `move(pos)`, `alive()` and `remove()`, or `nil, "no_light"` where the flare has none. Remove your lights when you're done: they stay for the rest of the mission.

```lua
local key = api.world.light(api.world.ahead(4), { color = { 1, 0.8, 0.6 }, intensity = 3, range = 10, shadows = true })
key:set({ spot = 50, yaw = 90, pitch = -40 })
key:remove()
```

| Call | What it does |
|---|---|
| `time_scale(scale, opts)` | How fast this player's game runs: 0 stops it, 1 is normal, between is slow motion. Only alone in the lobby (`"solo_only"`) unless `opts.lobby` is true, and a new screen sets it back to 1 |
| `time_now()` | The scale now |
| `time_of_day(name, towards, blend)` | The mission's look at `"dawn"`, `"day"`, `"dusk"` or `"night"`, with `blend` (0 to 1) of `towards` mixed in. Forest planets also have the `"swamp"` set. `nil` gives the mission's own back |
| `visible(unit, on)` | Hides a unit, shadow and all, or shows it again |
| `flashlight(unit, on)` | A Helldiver's flashlight, as a night mission lights it. Only the night armour has one: elsewhere the answer is `false, "no_flashlight"` |
| `place(unit, pos, angle, floor)` | Puts a Helldiver at `pos` facing `angle` degrees, in a stopped game too. The game keeps the place once it runs. The physics mover stays above `floor`, so a Helldiver sunk into the ground doesn't fall out of the level |
| `placement(unit)` | Where a Helldiver stands, and the way it faces in degrees |
| `pose(unit, event)`, `end_pose(unit)` | Plays one of a Helldiver's animation events as a pose, ending the pose before it first. Poses such as `at_ease` and `radio_activate` hold until ended. A stopped game plays the change once it runs for a moment |
| `part_visible(unit, part, on)`, `part_hidden(unit, part)` | Hides or shows one part of a Helldiver: `helmet`, `heavy_armor`, `boots`, `cape`, `body`, `weapon` (in hand), `holstered` or `backpack`. Mesh by mesh, so meshes the game keeps hidden stay hidden |

#### Screenshots: api.capture

The engine has no screenshot call, so `api.capture` goes to Windows: GDI copies the game window off the screen and GDI+ writes a PNG or JPEG. It needs the game's FFI, which the PC game loads itself. `available()` answers `false, "no_ffi"` where it's missing.

`shot(opts, done)` waits a few frames with the API's windows, panels and toasts held back (and, on an Obsidian with `obsidian.ui.solo`, every mod's drawing), copies the picture, and calls `done(path)`, or `done(nil, reason)`, as your mod. Check `busy()` before drawing guides of your own, as an older Obsidian can't hold them back for you.

| opts | What it is |
|---|---|
| `folder_name` | A folder in the player's Pictures, `"Helldivers"` by default. `folder` takes a full path instead |
| `name` | An `os.date` pattern, `"Helldivers %Y-%m-%d %H-%M-%S"` by default. A name already taken gets a number |
| `format` | `"png"` (the default) or `"jpg"`, with `quality` from 1 to 100 |
| `aspect` | A width over height to cut from the middle, `21 / 9` say |
| `crop` | `{ x, y, w, h }` in shares of the picture, from the top left |
| `keep` | `true` keeps your mod's own drawing in the picture, such as a color over it or a caption; hide your guides while `busy()` |

```lua
api.capture.shot({ aspect = 16 / 9 }, function(path, why)
  api.menu.toast(path and ("Saved " .. path) or ("Not saved: " .. why))
end)
```

`folder(name)` answers the Pictures folder path with `name` in it, made if missing, and `open_folder(path)` opens one in the file explorer. A failed copy answers `"no_window"`, `"minimized"`, `"black"` (the picture came back empty, as some fullscreen setups give) or `"not_saved"`.

### The look of a mission

```lua
api.world.shading("exposure", "scalar", 1.4)
api.world.shading("fog_color", "vector3", { 0.5, 0.45, 0.3 })
api.world.shading("fog_color", "vector3")   -- back to the planet's
api.world.flash()                           -- lightning
```

`shading(name, kind, value)` sets one of the values the planet's lighting is made of. The names are in `api.world.SHADING`, by kind:

| Kind | Value | Names |
|---|---|---|
| `scalar` | a number | `exposure`, `dof_amount`, `ambient_camera_falloff`, `sun_enabled`, `ssao_radius`, `ssao_strength`, `vignette_opacity`, `color_grading_enabled` |
| `vector2` | `{ a, b }` | `fog_depth_range`, `dof_near_setting`, `dof_far_setting`, `bloom_threshold_offset` |
| `vector3` | `{ a, b, c }` | `fog_color`, `fog_sun_blend`, `sun_color`, `sun_direction`, `ambient_top_color`, `ambient_bottom_color` |

From 1.23.0, names from the game's shaders too: `cloud_shadow_opacity`, `dust_opacity`, `emissive_material_intensity`, `emissive_particle_intensity`, `cube_environment_intensity_sun` and `cube_environment_intensity_shadow` (scalars); `cloud_shadow_movement`, `cloud_shadow_scale`, `dust_scale0` to `dust_scale2` and `dust_speed0` to `dust_speed2` (vector2); `dust_color` and `vignette` (vector3). `sun_direction` is the way the light travels, so its `z` is below 0.

A value goes on again in each new mission until you give it back. The game ships the code for these names without using all of them itself, so try yours on a first run.

`flash(seconds)` needs a forest planet, and not one of the illuminates. Others answer `"wrong_environment"`.

The effects `no_fog`, `no_dof`, `exposure`, `time_of_day`, `gravity`, `time_scale`, `hide_hud` and `show_patrols` are on [Changes and effects](#every-effect).

### The map: api.map

`api.map` reads and steers this player's mission map. It changes only what this player sees, so a client mod can use it.

| Call | What it does |
|---|---|
| `is_open(unit)` | Whether a map is open, the local player's when `unit` is nil |
| `open()`, `close()` | What the map key does. A map opened this way stays open until the player uses the map key, does something else such as a dodge or a reload, or `close()` is called |
| `zoom()`, `set_zoom(z)` | The zoom, from 0.5 (furthest out) to 4 |
| `view()` | The world point under the map's crosshair, where a ping would go. `cursor()` is the same |
| `look_at(pos)` | Pans so a world point is under the crosshair |
| `pings()` | Every player's ping: `{ record, owned, position }` |
| `to_map(pos)`, `to_world(x, y)` | Between world positions and the map's own units at zoom 1 |
| `marker(pos, opts)` | A marker of your own on this player's map |
| `clear_markers()` | Takes every marker of yours away |

`api.ui.ping(pos)` sets this player's ping, which everyone sees.

#### Markers

`marker(pos, opts)` stays at `pos`, or follows a unit with `opts.unit`. `opts` also takes `icon` (a material the map has loaded, `icon_map_pickup_generic` by default), `size` in map pixels (18 by default) and `color` as `{ a, r, g, b }`. It answers a marker with `move(pos)`, `set(opts)` and `remove()`, and it goes when the mission ends.

```lua
local m = api.map.marker(pos, { icon = "icon_map_objective_bunker_01", size = 32, color = { 255, 40, 255, 40 } })
m:move(new_pos)
m:remove()
```

## Sound and music

Sound is local. Other players hear their own game, so a client mod can use all of this.

### Volumes and sounds: api.audio

```lua
api.audio.bus("combat_enemy", -30)    -- decibels: 0 is as mixed, -60 is silent
api.audio.bus("combat_enemy", false)  -- back to the game's mix

api.audio.play("ui_select")           -- everywhere
api.audio.play("ui_select", position) -- from a point in the level
api.audio.stinger("music_objective_found")
```

| Call | What it does |
|---|---|
| `bus(name, db)` | Sets one part of the mix, from -100 to 24 decibels. `nil` or `false` gives it back |
| `play(event, pos)` | Plays a sound event, at a position or everywhere |
| `stinger(name)` | A short music sting in a mission, through the game's own cooldown of 5 seconds |
| `BUSES` | The parts of the mix you can set |

The buses are `sfx_master`, `vo_master`, `music_master` and `intro_master`, which the options menu sets, and `ambient_base`, `ambient_top`, `combat_effects`, `combat_enemy`, `combat_player`, `combat_player_extra`, `misc_weapons`, `music`, `music_event`, `reflections`, `stinger`, `vo`, `vo_pain`, `wep_casing` and `wep_rattle`, which the game blends as a mission gets tense. A volume you set holds against those blends.

`play` and `stinger` answer `"unknown_event"` for a sound this screen hasn't loaded. The stingers the game uses are `music_objective_found`, `music_objective_complete` and `music_objective_fail`.

### The soundtrack: api.music

`api.music` decides what music plays. A track you pick plays in place of the game's, loops, and stays through the next screens until you give the music back.

```lua
api.music.play("music_credits")   -- the credits theme, on the ship and on into the mission
api.music.pause()
api.music.resume()
api.music.stop()                  -- silence, kept the same way
api.music.release()               -- the game picks its music again
api.music.volume(-12)             -- quieter; false gives the volume back
```

| Call | What it does |
|---|---|
| `tracks()` | The music this screen can play now |
| `play(track)` | Plays a track in place of the game's music and holds it |
| `stop()` | Holds silence instead |
| `release()` | Gives the music back to the game |
| `pause()`, `resume()` | Pauses and resumes whatever plays, held or not |
| `volume(db)` | The music's volume, the same as `api.audio.bus("music_master", db)` |
| `now()` | `{ place, track, held, paused, loading }`. `place` is `"menu"`, `"ship"`, `"mission"`, `"screen"` (the drop and the results), or nil where there's no music |
| `TRACKS` | Every music track the game's scripts start |

#### The tracks

| Track | Where the game plays it |
|---|---|
| `music_theme` | The main menu |
| `music_bridge` | The ship |
| `music_credits` | The credits |
| `music_mission_start` | The drop |
| `music_mission_end_success`, `music_mission_end_failed` | The results |
| `music_jingle` | A short jingle on the ship |
| `music_threat` | A mission, with patrols nearby |
| `music_action_bugs`, `music_action_cyborgs`, `music_action_illuminates` | A fight, by faction |
| `music_action_plus` | A fight during extraction, once the objectives are done |
| `music_boss_bugs`, `music_boss_cyborgs`, `music_boss_illuminates` | A boss fight |

The main menu, the ship and missions have the whole set, so you can play the main theme in a mission or a boss track on the ship. `tracks()` answers what a screen has loaded: `play` answers `"unknown_event"` for a track it lacks, and `"no_music"` where there's no music at all.

A mission has none of the menu tracks (`music_bridge`, `music_theme`, `music_credits`), so there `play` loads the package that holds them, in the background, and answers `true, "loading"`. The game's music stays down meanwhile and the track starts once the package is there, which then stays loaded until the game unloads it on the ship. `play(track, { db = -6 })` plays a track at its own level, in decibels below the mix.

#### How it behaves

- On the main menu and the ship, the music has a sound world of its own, so a pause stops it where it is.
- In a mission, music shares its world with every other sound. A pause there mutes the music and lets it run on silently, so it comes back further along.
- In a mission, the game starts threat and fight music as patrols and enemies come and go. While a track is held, those stay silent. When you release it, they fade back in.
- A held track loops when it ends.

#### Example: a boss theme for the ship

```lua
local api = obsidian.import("obsidian.api")

obsidian.on_frame(function()
  local on_ship, held = api.game.on_ship(), api.music.now().held
  if on_ship and not held then
    api.music.play("music_boss_cyborgs")
  elseif not on_ship and held then
    api.music.release()   -- a held track would follow the player into the drop
  end
end)
```

## Menus, messages and the save

### The in-game window: api.menu

F6 opens a window over the game: a folder for each mod down the left with that mod's pages in it, and the open page on the right. The title bar names the mod whose page is open. It works with the keys, a pad and the mouse, players can move and resize it, and it opens where it was left. Moving, changing a value, choosing and going back play the game's own menu sounds, quietly. The key is Obsidian API's, so your mod needs none: it opens the window once a page is listed, and players change it in the Keys tab of Obsidian API.

With a controller, both sticks pressed in together open and close the window (the **Open the menu with a controller** option of Obsidian API picks other buttons, or none). The D-pad or the left stick moves through the rows and changes values, A selects, B goes back, Y resets a row, and LB and RB switch to the page before or after, across every mod's folder. The guide at the foot shows the pad's buttons while a pad is in use. A pad can't type, so A does nothing on a number or text row: left and right step a number.

`api.menu.add(title, build, opts)` adds a page to your mod's folder. `title` is text, or a function that answers it, since at boot the game's language isn't known yet. `build(page)` runs each time the page opens. `opts.icon` is one of `obsidian.ui.glyphs()`.

| Row | What it does |
|---|---|
| `page:header(label)` | A heading over the rows after it |
| `page:label(label)` | A line of text |
| `page:toggle(label, opts)` | On or off, with `opts.get()` and `opts.set(value)` |
| `page:number(label, opts)` | From `opts.min` to `opts.max` in steps of `opts.step`, ten at a time with Shift. Enter types a value. `opts.format` is a `string.format` pattern |
| `page:choice(label, opts)` | One of `opts.choices`, a list of `{ id, label }` |
| `page:action(label, fn, opts)` | Calls `fn()`. A string it answers shows as a toast |
| `page:input(label, fn, opts)` | Asks for a line of text, then calls `fn(text)`. With `opts.code`, it takes arrows instead (the arrow keys, W A S D or a pad) and passes them on as words, `"up down left"` |
| `page:page(label, build, opts)` | A page inside this one |
| `page:refresh()` | Builds the page again after the current action |

Any row takes `help`, a line shown at the bottom while the row is selected, `enabled`, a function that answers `false` and a reason, and `icon`, a HUD icon from `obsidian.ui.icons()` before the label. A label can be a function, for live values. A toggle, number or choice takes `default`: the row then gets a reset button, lit once the value has moved, and R does the same from the keys. Where writing a value isn't the way back, give `reset`, a function that undoes it, and `changed`, one that says whether there's anything to undo.

Your functions run as your mod, so `obsidian.text`, `obsidian.storage` and `api.edits` see your mod and not the API. A row that fails shows the error as a toast and doesn't count against your mod. A session mod's pages leave the list, and close, while the lobby isn't cleared. A client mod's stay in any lobby.

| Call | What it does |
|---|---|
| `open()`, `close()`, `toggle()`, `is_open()` | For a mod that opens the window at a moment it picks. A second `toggle()` in the same frame does nothing, so two keys bound to it don't cancel out |
| `toast(text, seconds)` | A short message at the top left, or beside the window while it's open. `seconds` is 4 when left out |

```lua
local api = obsidian.import("obsidian.api")
local reach = 10

api.menu.add("Panic Button", function(page)
  page:header("Tuning")
  page:number("Reach", { min = 5, max = 40, step = 5, default = 10,
    get = function() return reach end, set = function(v) reach = v end,
    help = "How far from the player the button clears enemies, in metres." })
  page:action("Clear the area", function()
    api.enemies.kill_near(reach)
    return "Cleared"
  end)
end, { icon = "enemies" })
```

#### Panels

`api.menu.panel(spec)` makes a window of your mod's own, with tabs along the top, at the bottom right of the screen at first. Your code opens and closes it. The rows are the rows above, plus `page:slider(label, opts)`, a number on a bar the mouse drags, from `opts.min` to `opts.max`. A choice's `swatch` (`{ r, g, b }`, 0 to 255) shows a color square beside the choice's label, and `format` can be a function for any row with a value.

A panel handles the arrow keys, Enter, Esc, Tab (Shift and Tab goes back a tab), R and the left mouse button, and the wheel while the mouse is over the panel. W A S D, Q, E, the right mouse button and the wheel away from the panel are yours: read them raw to steer something while the panel is open, such as a camera. The game gets no input while a panel is open, and the F6 window waits.

Players drag a panel by the title bar and resize it from the grip in the corner across from the anchor. The line between the rows and the help drags too, for room for longer help: four lines at first. The place, the size, the help's room, the opacity and the scale are kept for the next launch, per mod and `spec.id`, in Obsidian API's storage. A panel always stays on screen.

| spec | What it is |
|---|---|
| `title` | Text, or a function |
| `tabs` | `{ { title = ..., build = function(page) end, icon = ... }, ... }`, at least one. With `icon`, one of `obsidian.ui.glyphs()` or a HUD icon from `obsidian.ui.icons()`, the tab shows the icon in place of the title, and the title shows over the help while the tab is open or under the mouse. An icon that doesn't draw leaves the title |
| `id` | Names the kept place among your mod's panels, `"panel"` by default |
| `anchor` | The corner the panel is kept at and grows from: `"bottom_right"` (the default), `"bottom_left"`, `"top_right"` or `"top_left"`. `"right"` and `"left"` are the top corners with the full height of the screen at first. `side` is the same as `anchor` |
| `width`, `height` | In the game's 1280 by 720 design units: 540 by 360 by default, and 390 wide for `"right"` and `"left"` |
| `opacity` | The background's strength, from 0 to 1, until the player's own is kept: 0.5 by default. The rows and words stay at full strength |
| `scale` | How big everything in the panel is drawn, from 0.6 to 1.6, 1 by default |
| `buttons` | Buttons in the title bar, left of the close button: `{ { glyph = "reset", help = "...", run = function() end } }`. `glyph` is one of `obsidian.ui.glyphs()` or a HUD icon. `run` runs as your mod, and a string it answers shows as a toast. The help shows over the panel's help while the mouse is on the button |
| `sounds` | `false` and the panel plays none of the game's menu sounds |
| `headings` | `true` shows the open tab's title over the tab's rows, in larger letters than a row heading. A tab with `reset` (a function, run as your mod; a string it answers shows as a toast) gets a reset button beside the title, with `reset_help` as the button's help |
| `status` | A function answering a short text for the title bar |
| `guide` | Your keys for the panel's key guide, before the panel's own: `{ { keys = { "H" }, label = "Hide" } }` |
| `on_close` | Called as your mod when the panel closes, by Esc, the close button or `close()` |

A panel answers `open(tab)`, `close()`, `is_open()`, `hide(on)` (draws nothing and reads no keys, but still keeps input from the game), `hidden()`, `select_tab(n)`, `tab_number()`, `refresh()`, `under_mouse()` and `typing()`, and also:

| Call | What it does |
|---|---|
| `set_opacity(a)`, `opacity()` | The background's strength, from 0 to 1. Kept with the place |
| `set_scale(s)`, `scale()` | Everything in the panel bigger or smaller, from 0.6 to 1.6, growing from the anchor's corner. Kept with the place |
| `reset_place()` | Back to the first place and size, the help's room too. Opacity and scale stay |
| `set_cursor_hidden(on)`, `cursor_hidden()` | With `true`, the cursor hides and the panel leaves the mouse alone while still drawn: for looking around while the right mouse button is held, say. `false` brings the cursor back, and so does closing the panel |

```lua
local panel = api.menu.panel({ title = "Photo Mode", id = "controls", on_close = stop_photo_mode,
  buttons = { { glyph = "reset", help = "Puts every setting back.", run = reset_everything } },
  tabs = {
    { title = "Camera", icon = "weapons", build = function(page)
      page:slider("Field of view", { min = 20, max = 120, step = 1, format = "%d deg", default = 60,
        get = function() return fov end, set = function(v) fov = v end })
    end },
  } })
panel:open()
```

`obsidian.menu` hands every call to this window from the Obsidian release after 1.1.0. On 1.1.0 it's the loader's own window, which nothing opens now that the Trainer's pages are here, so use `api.menu`. There, the key waits for a cleared lobby when Obsidian API runs as a session mod, and folders are named after the mod's id, written out.

### Messages: api.ui

| Call | What it does |
|---|---|
| `hint(text, seconds)` | Shows the game's hint box, even with hints turned off. `text` is your words, or a hint name such as `"hint_alarm"`. `seconds` is 7 when left out |
| `ping(pos)` | Puts this player's mark on the map at a position, or takes it away with `nil`. Everyone sees it |

Your words in a hint go through `obsidian.notify` (in Obsidian's Wiki), so `hint` can answer `false, "queue_full"` when your mod already has three waiting.

```lua
api.ui.hint("Extraction in 60 seconds", 5)
```

### The ship's menus

| Call | What it does |
|---|---|
| `open(name, opts)` | Opens a menu of the ship by name, as walking up to its terminal does: `"armory"`, `"encyclopedia"`, `"training"`, `"main"`, `"loadout"` and others |
| `close()` | Closes the top menu |
| `menus()` | The name of every menu this screen can open |

A menu reads the player who opened it, and Loadout and the briefing read a mission, so `opts.seed` gives them one. `opts.pad` opens it for a pad other than the main player's.

```lua
api.ui.open("loadout", { seed = 51000003 })
```

### Your words in the game's screens

`with_texts(texts, fn, ...)` runs `fn` while some of the game's text keys show your words. `texts` is `{ key = words }`. Only while `fn` runs, so you can reuse one of the game's screens with your own titles and leave every other text alone. It answers what `fn` answers.

Wrap the screen's own function in a hook, and the texts change only while it runs:

```lua
-- "SomeMenuScreen" and "draw" stand for the game screen you're reusing.
obsidian.hook("SomeMenuScreen", "draw", function(original, self, ...)
  return api.ui.with_texts({ menu_campaign = "SURVIVORS" }, original, self, ...)
end)
```

### Your settings in the pause menu: api.mod_settings

The game's pause menu gets a **Mods** row under its own Settings. It opens a list of mods, and each mod's page is the game's own Settings screen with your rows: a name on the left, a value you change with the arrows or the mouse, and a line of help under them while one is selected. The row shows up once any page has a row. A row can also be one of your `obsidian.json` options, kept in step with Obsidian (below).

`api.mod_settings.page(title)` gives your mod its page, titled in the list of mods. Asking again gives the same page. Its rows:

| Call | What it does |
|---|---|
| `page:toggle(id, opts)` | Yes or No. `opts.default` is `false` when left out |
| `page:choice(id, opts)` | One of `opts.choices`, a list of `{ id, label }`. `opts.default` is an id, the first when left out |
| `page:number(id, opts)` | From `opts.min` to `opts.max` in steps of `opts.step`, 100 steps at most. `opts.format(value)` gives the words shown |
| `page:button(label, fn, opts)` | A row that calls `fn` when pressed |
| `page:get(id)` | The value now |
| `page:set(id, value)` | Changes it as the page would. `false` when the value doesn't fit the row |

Every row but a button takes `opts.label`, `opts.info` (the line of help) and `opts.on_change(value)`, called when the value changes, from the menu or from `set`. The row calls answer the value the row starts with: the one kept from the last time, or the default.

Any words (the page title, a label, the info, a choice's label) can be a string or a table by language, `{ en = "...", fr = "...", es = "...", ["pt-BR"] = "..." }`. The page shows the game's language, else English. Pages are made at boot, before the game knows its language, so the table is read each time the page is drawn. Labels are shown in capitals, accents included.

Values are kept for the next launch, in Obsidian API's storage. These are your mod's in-game settings, separate from the options in your `obsidian.json`, which players change in Obsidian and you read with `obsidian.settings.get`. The page opens in any lobby, cleared or not, so a client mod's settings are always at hand.

#### A row that is one of your obsidian.json options

With `opts.option = true`, a toggle, choice or number is the option of your `obsidian.json` with the same id, so players can change it in either place:

- The row starts from the value set in Obsidian (what `obsidian.settings.get(id)` answers), so make it from your own code, at load.
- A change in game applies at once (your `on_change` runs) and is kept in Obsidian API's storage as `option/<mod id>/<option id>`. Obsidian takes it into the active profile while the game is closed (when Obsidian starts, a moment after the game closes, and before a deploy) and removes the key. Until then the kept value wins at the next launch.
- Give the row the same choices (ids), range and step as the option, so every value fits both. A value that doesn't fit the row falls back to the row's default.
- `api.mod_settings.BINDS` is `true` from Obsidian API 1.16.0 on. On an older API, check it and leave the row out, since the row would be a separate in-game setting there.

The option's labels in `obsidian.json` are Obsidian's; the row needs its own, by language as above.

#### Rows of the pause menu

`api.mod_settings.pause_row(id, label, fn, opts)` adds a row to the pause menu itself, under the Mods row. Choosing it closes the pause menu, then calls `fn()` as your mod. `opts.when(screen)` decides where it shows: `screen` is `"game"` in a mission and `"menu"` on the ship. The label is words or a table by language, in capitals like the game's rows. `remove_pause_row(id)` takes it away.

```lua
api.mod_settings.pause_row("photo", "Photo Mode", start_photo_mode, { when = function(screen) return screen == "game" end })
```

```lua
local page = api.mod_settings.page("Better HUD")
local show_ammo = page:toggle("ammo", { label = "Ammo counter", default = true,
  info = "Rounds left by the magazine picture.", on_change = function(on) show_ammo = on end })
page:number("size", { label = "Bar height", min = 2, max = 8, default = 4, format = function(v) return v .. " px" end })

-- The same toggle as the "solo_pause" option in obsidian.json.
if api.mod_settings.BINDS then
  page:toggle("solo_pause", { option = true, default = true, on_change = function(on) solo_pause = on end,
    label = { en = "Dynamic solo pause", fr = "Pause dynamique en solo", es = "Pausa dinámica en solitario", ["pt-BR"] = "Pausa dinâmica solo" } })
end
```

### The save: api.progress

Obsidian leaves the player's own progression alone, with two lines it won't cross: there's no way to change XP or rank, and no way to get paid content.

| Call | What it does |
|---|---|
| `samples()`, `max_samples()`, `set_samples(n)` | Research samples |
| `unlock_items()` | Unlocks every item that isn't paid content, without touching XP |
| `upgrade_all()` | Buys every upgrade. Upgrades of paid items stay locked with the item |
| `upgrades()` | The upgrades the player owns, by item |
| `set_upgrade(name, value)` | Sets an item's upgrades: a bit per upgrade for a weapon, a level for a stratagem |
| `upgrade_limit(name)` | The highest value `set_upgrade` takes, or nil for an item with none |
| `loadout()` | What the next spawn uses: `{ perk, primary_weapon, sidearm_weapon, stratagems }`, by name |
| `set_loadout(t)` | Changes it, from the next spawn |
| `rank()` | The player's rank |
| `owned_cosmetics(slot)` | The helmets, bodies or capes they own |

```lua
api.progress.set_loadout({ primary_weapon = "weapon_railgun", stratagems = { [1] = "stratagem_resupply" } })
api.progress.set_upgrade("weapon_railgun", 3)
```

These write the real save, on the ship, with its menus closed. Anywhere else they answer `"close_screen"`.

- `set_loadout` takes any of `perk`, `primary_weapon`, `sidearm_weapon` and `stratagems`. `stratagems` maps the four free slots, 1 to 4, to names. It goes into the first preset as well, because the Loadout screen starts from that.
- Paid items and unknown names go back to the default, as when the game reads a save. An item the player hasn't unlocked doesn't survive a visit to the Loadout screen.

### The developer console: api.console

The game's developers left their console commands in the scripts. The release build throws the console away, and the API catches the commands as the scripts register them.

| Call | What it does |
|---|---|
| `commands()` | Every command the game has registered on this screen, sorted |
| `run(line)` | Runs a command line, as the console would. Answers `true` or `false` and the console's message |
| `denied(name)` | Whether a command is refused |

```lua
for _, name in ipairs(api.console.commands()) do obsidian.log(name) end
local ok, message = api.console.run("help")
```

Commands that reach the shared backend, wipe saves or achievements, or unlock paid content are refused with `"denied"`. `spawn_enemy` runs only with nobody else in the lobby, because it loads a package on this game alone.

## Bots

`api.bots.add(opts)` makes a Helldiver this machine plays. It needs the host, or a player alone, in a mission, and answers `nil, "host_only"` or `nil, "not_in_mission"` otherwise.

```lua
local alpha = api.bots.add({ name = "Alpha" })
alpha:follow()      -- stay near me
alpha:fight(25)     -- shoot anything within 25 metres
```

`opts` takes:

- `name`: shown over its head and in the HUD. "Bot 1", "Bot 2" and so on when left out.
- `bare`: `true` for a bare Helldiver, `false` to refuse one when every player slot is taken.
- `position`: where a bare Helldiver appears, next to the player when left out.

### Two kinds of bot

A bot is first a local co-op player on a game pad nobody holds, joined the way a second controller joins. It has a HUD slot, a name, revives and reinforcements, and other players see an ordinary local player.

Once all four player slots are taken, a new bot is a bare Helldiver: a body with its name over its head, and no HUD slot or respawn. It's good for a fight beside you or something to shoot at. `bare = true` asks for one even with slots free. A bare Helldiver needs a game pad number nobody uses to be driven, and stands still when none is left.

Bots leave before a mission's results, so they never reach the end screens or anyone's save.

### Orders

| Call | What the bot does |
|---|---|
| `follow(unit, distance)` | Keeps near a unit, the player's by default, walking to it when it's further than `distance` (6 metres) |
| `go_to(pos, distance)` | Walks to a position and stops within `distance` (1.5 metres). The order ends when it gets there |
| `hold()` | Stays where it stands |
| `aim_at(pos)` | Faces a position, while it has nothing to fight. `nil` lets it face where it walks |
| `fight(radius, opts)` | Aims at and shoots the nearest enemy within `radius` (25 metres) that a straight line from the bot reaches, and holds fire while a Helldiver stands in the line of fire. `fight(false)` stops. `opts` is below, in [Weapons](#weapons) |
| `fighting()` | The radius it fights in, or `false` |

A new order to walk replaces the last one: `go_to` ends `follow`, and `hold` ends both. Orders return the bot, so they chain:

```lua
alpha:go_to(api.world.cursor()):aim_at(api.world.ahead(30))
```

Bots walk straight at their goal with no pathfinding. A bot that walks into something and gets nowhere for a second steps aside, one side and then the other, and goes on: that gets it around a crate or a rock, not out of a dead end. The game also keeps local players inside the screen, so a player bot stops at the edge of the view.

Friendly fire is always on in Helldivers, so a fighting bot never fires with a Helldiver in the line of fire, and looks for an enemy it can reach with a straight line before anything behind a wall.

### Gear and help

These go to the bot the way `api.gear`, `api.stratagems` and `api.player` give them to the main player. Each answers `true`, or `false` and a reason: `"no_avatar"` while the bot has no body, in its hellpod or dead.

| Call | What it does |
|---|---|
| `give_weapon(slot, path, upgrade)` | A weapon in `"primary_weapon"`, `"sidearm_weapon"` or `"support_weapon"` |
| `give_backpack(path, upgrade)` | A pack from `api.catalog.backpacks()` |
| `give_perk(name)`, `remove_perk()` | Its main perk |
| `give_stratagem(name)` | A stratagem in its slots |
| `refill()` | Fills its weapons |
| `call(name, pos, delay)` | A real call-in of the bot's own, at its upgrade level |
| `heal()` | Up from downed and at full health |
| `teleport(pos)` | Moves it |
| `weapons()` | The weapons it holds, as `api.gear.weapons_of` lists them |

```lua
local bravo = api.bots.add({ name = "Bravo", bare = true })
bravo:give_weapon("primary_weapon", "equipment/wep_assaultrifle_01")
bravo:call("stratagem_resupply", api.world.ahead(6))
```

### Helping each other

Bots help the squad the game's own ways, with the inputs a player uses:

- **Getting up.** A downed bot lies still and holds interact until it's up, the way the keyboard's key counts presses. The game counts 30 presses (10 with the perk that shortens it), and lets a downed Helldiver up only while the body is on the screen. `bot:auto_get_up(false)` leaves it down for a teammate: it fights from the ground with what it holds, and lies still once a teammate stands close enough to help. A downed bot also lies still while another bot helps it up.
- **Helping up.** `bot:revive(unit, on_done)` walks to a downed Helldiver, stands beside the body, turns to it and presses interact once the game has picked the body as the thing to use, never an item lying by it. With no unit, it picks the nearest downed one within 30 meters that no other bot is helping.
- **Healing.** `bot:heal_target(unit, on_done)` walks within range (12 meters, 18 upgraded) with the weapon it holds, takes the REP-80 (`equipment/wep_repairtool_01`) out of the bot's slots, faces the target and holds fire until they're at full health, then takes back the weapon it held. With no unit, it picks the most hurt Helldiver within 30 meters that no other bot is healing. The beam does nothing to a downed Helldiver, so help them up first.
- **On their own.** `bot:auto_revive(radius)` (15 meters) and `bot:auto_heal(radius)` (20 meters, under 80% health) start these by themselves between other orders, while the bot follows or fights. `false` stops either. `auto_heal(radius, { below = 0.5 })` starts only under half health, and `retry` (both calls, 5 seconds) is how long a bot waits before it tries again someone it failed to help. Only one bot goes to each Helldiver: the free one nearest to them. A bot is free when it calls no stratagem, helps no one, isn't downed and isn't in a vehicle seat, carrying an objective, using something or extracting.

Both answer `true` once started, or `false` and a reason, and `on_done(ok, reason)` hears how it ended. With no unit and another bot already on the way to everyone who needs it, the reason is `"already_helped"`. While one runs, the bot's other orders wait, though a bot that fights shoots back on the way at enemies within 10 meters, and `bot:stop_helping()` ends it. A bot changes weapons only while it stands calm (not downed, knocked down, throwing or in another animation), since a weapon taken out in the middle of one leaves the body in a pose with no animation. A bot wearing the heal drone's backpack (`equipment/equipment_drone_heal_backpack_01`) heals whoever stands within 6 meters of the drone with no order at all.

### Grenades and reloads

`bot:throw_at(pos, on_done)` throws a grenade at a point the way a player does: the bot turns to it, holds the throw until the charge matches the distance, and lets go. It answers `false, "no_grenades"` with none left, and `on_done(ok, reason)` hears how it went. `bot:throw()` is the plain button: a short throw ahead. Either way the bot lets go of the trigger while it throws, since fire held during a throw sends the grenade at once at the bot's feet.

Bots reload by themselves as a player would: an empty magazine with a spare one left, or a laser such as the Sickle at full heat with a radiator left. The trigger is let go for a moment so the reload goes through. `bot:auto_reload(false)` turns that off, and `bot:reload()` presses the button.

### Weapons

`bot:wield(slot)` takes out the weapon in a slot: `"primary"`, `"sidearm"` or `"support"` (or the game's `"primary_weapon"` and so on). It comes out once the bot stands calm, and `bot:wielding()` answers the slot of the weapon in hand. `bot:switch()` taps the pad's switch button, so the primary and the support weapon take turns.

`fight` takes options:

- `weapon`: the slot it fights with. The bot takes it out and comes back to it after a heal or anything else it takes out.
- `only`: a function given an enemy unit, true for the enemies to shoot. The rest are left alone. An error in it picks none, and goes in the log once.
- `secondary`: `true` in a vehicle seat to fire the seat's second weapon as well, or a table that sets `only` and `every` for that weapon (below).

`bot:use_weapon(slot, target, opts, on_done)` takes out one weapon, fires it at one unit and takes back the weapon from before: an EAT or a recoilless rifle for a Tank while `fight` keeps to the rifle. The bot stands still, faces the target and fires only along a clear line with no Helldiver in the way, and reloads as it would by itself. An empty launcher that the bot's backpack reloads is reloaded before the weapon from before comes back, so it comes out loaded next time. `opts.shots` is how many shots before it's done (1), `opts.time` the seconds before it gives up (10), and `opts.keep = true` keeps the weapon out afterwards. `on_done(ok, reason)` hears `true` and `"shots"`, `"killed"` or `"spent"` (the EAT leaves the slot once fired), or `false` and why. `bot:using_weapon()` answers the slot and target, and `bot:cancel_weapon()` stops it.

When to fire is the mod's to decide. The API gives what it needs:
- `bot:hurts(target, slot)` answers the damage one hit of that slot's weapon does to the target after armor.
- `bot:sees(unit)` says whether a straight line from the bot reaches it.
- `bot:enemies_in_sight(radius, only)` lists the enemies it sees, nearest first. Each enemy costs a ray, so look every second or so rather than every frame.

Armor and anti-tank are two sides of one sum. Every hit costs the shot's power minus the armor where it lands: `armor_min` for a square hit, up to `armor_max` for a glancing one, and armor piercing takes 15 off. Some enemies have a part with separate armor, such as the Bug Tank's weak spot (45 against a body of 1000 to 1500). So an anti-tank target is one the bot's gun does nothing to. `bot:hurts` answers three numbers, each 0 where the weapon can't get through: square, glancing and on the weak spot. For a weapon that explodes, it adds the blast, and for a launcher it counts the rocket. `api.gear.hurts(weapon, target)` does the same for any weapon unit. `api.enemies.info(unit)` still has `armor_min`, `armor_max` and `large`, but `large` is the game's size mark: the bike has it, and it says nothing about armor.

```lua
-- The rifle for what it can hurt; the EAT for what it can't, once each 40 seconds at most.
alpha:fight(25, { weapon = "primary", only = function(e) return (alpha:hurts(e, "primary") or 0) > 0 end })
local wait = 0
obsidian.on_frame(function()
  wait = wait - (rawget(_G, "ENGINE_DT") or 0.016)
  if wait > 0 or alpha:using_weapon() then return end
  wait = 1   -- look once a second
  local heavy = alpha:enemies_in_sight(30, function(e) return alpha:hurts(e, "primary") == 0 end)[1]
  if heavy and alpha:use_weapon("support", heavy) then wait = 40 end
end)
```

### Getting out of a shot

`api.enemies.charging(unit)` answers an enemy that holds fire before a shot, while it holds it: the Hunter's beam (3 seconds), the Cyborg IFV's laser sight, the Hulk's wind-up. It gives `{ time, from, to, effect }`: the seconds until it fires, where the aim line runs (ending at what it hits), and the line the game draws. It works on every machine, whoever runs the enemy.

`bot:avoid_shots(true, opts)` uses it: while a line runs within `opts.width` metres of the bot (2), the bot walks straight out of it to the side it's on, and dives just before the shot if it's still in the line. It looks at enemies within `opts.radius` metres (40). `opts.dodge = false` walks out only, and `bot:avoiding()` says whether it's getting out of one now. It waits while the bot sits in a vehicle, is downed, calls a stratagem or throws.

A semi-automatic weapon fires once per trigger pull, so a fighting bot pulls and lets go. A launcher with an assisted reload, such as the recoilless rifle, reloads by itself only while the bot wears the backpack it needs; otherwise the reload is a teammate's. `bot:refill_backpack()` fills that backpack.

### Vehicles

`bot:enter_vehicle(vehicle, seat, on_done)` walks to a seat's door and gets in as a player does. `vehicle` comes from `api.vehicles.near` or `nearest`. With no `seat`, the bot takes the first free seat no other bot is on the way to, a seat that doesn't steer before the one that does. It answers `true` once started, or `false` and `"no_avatar"`, `"busy"`, `"downed"`, `"seated"`, `"no_vehicle"`, `"no_seat"` or `"taken"`. `on_done(ok, reason)` hears `true` once seated, or `false` and `"taken"`, `"destroyed"`, `"refused"`, `"timeout"` and the like. `bot:boarding()` answers the vehicle and seat it's on the way to, `bot:seat()` the ones it sits in, and `bot:leave_vehicle()` gets it out.

`bot:ride_along(true)` gets the bot into the vehicle of the Helldiver it follows (the player when it follows no one) while a seat that doesn't steer is free, and out again once they're out. Pass a unit to ride along with someone else, and `false` to stop.

In a seat, the orders work the seat's controls:

- `fight` aims the seat's gun and fires it. A seat with no gun fights nothing. `fight(25, { secondary = true })` also fires the second weapon: the tank's machine gun or the first exosuit's rockets. The rockets leave from the exosuit's front, so they go only while it faces the target, one each second. `secondary` as a table sets that: `only` picks the enemies the second weapon is for, and `every` the seconds between shots (0 holds the trigger). `bot:fire_secondary(on)` holds that trigger by hand.
- The throw button is the second trigger in a seat, so `bot:throw()` does nothing there.
- In the seat that steers, `go_to` and `follow` drive: the APC and the bike speed up on the trigger and steer on the stick, the tank drives a track on each stick.

`bot:mech_friendly_fire(false)` keeps the mech a bot pilots from hurting Helldivers: its shots cost players and other bots no health, and enemies take them as before. Shells still in the air count for 2 seconds after the bot gets out. It works while session mods run, and only on health: a knockdown or a status effect from a shot isn't held back.

```lua
-- Into the exosuit the player clicked: the gun for what it can hurt, rockets for the rest, one each 2 seconds.
local mech = api.vehicles.nearest(api.world.cursor(), 4)
if mech then
  alpha:enter_vehicle(mech, nil, function(ok)
    if not ok then return end
    local function soft(e) return (api.enemies.info(e) or { armor_min = 0 }).armor_min < 100 end
    alpha:fight(30, { only = soft, secondary = { every = 2, only = function(e) return not soft(e) end } })
  end)
end
```

### Using things

`bot:use(unit, opts, on_done)` uses a thing the way a player does. The bot walks within reach, stands, faces it and presses interact once the game's own pick of what to use lands on it. That covers a sample, an ammo box, a weapon or backpack lying about, a hellbomb, the first press on a terminal or the extraction beacon, and a thing an objective asks to carry. On a teammate, it's the team reload of their launcher from the bot's backpack. `api.bots.usables(pos, radius, kinds)` lists the things around a point, nearest first: `{ unit, kind, position, enabled }` each, where `kind` is the game's name for it (`"research_sample_pickup"`, `"ammo_pickup"`, `"hellbomb"`, `"objective_interact_object"` and so on).

`opts` takes `reach` (1.2 metres), `time` (20 seconds) and `presses` (1, the presses it tries when one does nothing). `on_done(ok, reason)` hears `true` and `"used"`, or `false` and `"gone"`, `"not_offered"` (the game doesn't let this bot use it from there, such as an ammo box with the bot's ammo full), `"picked_other"`, `"no_effect"`, `"downed"`, `"timeout"` or `"cancelled"`. While it runs, the bot presses on nothing else, and a weapon or backpack it was sent for isn't held back by the pickup cooldown. `bot:using()` answers the thing, and `bot:cancel_use()` stops it.

What the bot carries comes from `bot:carrying()`, and `bot:drop()` puts it down. A carrying bot fights with a one-handed weapon only.

| Call | What it does |
|---|---|
| `say(word)` | A voice line with the words over the bot's head: `"yes"`, `"no"`, `"stay"`, `"move"` or `"taunt"` |
| `jump(dir, on_done)` | A jump with a jump pack along a world direction, up to 12 metres. It answers `false` and `"no_jump_pack"` or `"no_fuel"`, and `on_done` hears `true` and `"landed"`, or `false` and `"refused"` when the game wouldn't jump (about 4 metres clear ahead are needed) |
| `jumping()` | `true` while a jump is under way |

```lua
-- Pick up every sample within 20 metres, one after another.
local function next_sample()
  local s = api.bots.usables(nil, 20, { "research_sample_pickup" })[1]
  if s then alpha:use(s.unit, function() next_sample() end) end
end
next_sample()
```

Entering terminal codes, boarding the shuttle, reinforcing, finding a way around walls and staying out of hazards aren't there yet.

### Picking things up

Picking up a weapon or a backpack drops what the bot held in that slot right where it stands, so a bot that keeps pressing interact would take the dropped one back, and so on. After a bot picks one up, it picks up neither for 20 seconds. `bot:pickup_cooldown(seconds)` changes that (0 turns it off), and `bot:next_pickup()` answers the seconds left. Ammo and other items are never held back. Every press and button a bot's order or help uses lasts only as long as that order needs it, so none stays held after the order ends.

```lua
local medic = api.bots.add({ name = "Medic" })
medic:give_weapon("support_weapon", "equipment/wep_repairtool_01")
medic:follow():fight(25):auto_revive(15):auto_heal(20)
```

### Stratagems by code

`call` drops a stratagem straight in. `use_stratagem(name, pos, on_done)` calls one the way a player does: the bot holds the stratagem button, presses the code's arrows one at a time, faces `pos` and throws the flare there, with the charge a mouse player gets by aiming at that point. It only works for a stratagem in the bot's slots, and the call spends the cooldown and a use as a player's does. Other players see the bot enter the code and throw.

It answers `true` once started, or `false` and a reason: `"no_avatar"`, `"no_position"`, `"not_available"` (no stratagem by that name), `"not_held"`, `"cooling_down"`, `"no_uses"` or `"busy"` (already calling one). `on_done(ok, reason)` hears how it ended: `true` once the flare leaves the hand, or `false` and one of these:

| Reason | What happened |
|---|---|
| `"jammed"` | The bot stands in a no-stratagem zone |
| `"refused"` | The code went in, and the game didn't call the stratagem |
| `"wrong_code"` | The game counted the arrows wrong three times in a row |
| `"interrupted"` | The menu closed early or never opened: downed, knocked down, or in a vehicle seat |
| `"cancelled"` | `cancel_stratagem()` or `remove()` |
| `"no_avatar"` | The bot died |
| `"timeout"` | Nothing came of it in 10 seconds |

While it runs, the bot stands still, holds fire and faces `pos`. Its orders stay as they were and carry on afterwards. The code goes in at more than 10 arrows a second, and each step waits for the game, so a missed or doubled arrow means the button is let go and the code entered again.

| Call | Answers |
|---|---|
| `stratagems()` | The stratagems in its slots: `{ name, id, uses_left, cooldown, ready }` each |
| `using_stratagem()` | The stratagem it's calling and the step, `"open"`, `"code"` or `"throw"`, or `false` |
| `cancel_stratagem()` | Lets go of the button. A flare already in hand goes back unthrown |

```lua
-- Resupply when the primary weapon runs low, thrown 5 metres ahead.
local ok, why = alpha:use_stratagem("stratagem_resupply", api.world.ahead(5), function(done, reason)
  if not done then obsidian.log("resupply failed: " .. reason) end
end)
```

### Driving one yourself

For anything the orders don't cover, a bot takes the same inputs a game pad gives:

| Call | Input |
|---|---|
| `move(dir)` | Walks in a world direction `{ x, y }`. Its length is the speed, up to 1. `nil` stops |
| `aim(dir)` | Faces and aims in a direction |
| `fire(on)`, `firing()` | Holds the trigger until `fire(false)` |
| `sprint(on)` | Sprints |
| `reload()`, `dodge()`, `melee()`, `interact()` | One press each |
| `throw()` | Throws a grenade |
| `switch()` | The next weapon |

### The rest

| Call | Answers |
|---|---|
| `unit()` | The bot's body, or nil while it has none |
| `alive()` | `true` while it has a body |
| `remove()` | Takes it out of the mission |
| `api.bots.all()` | Every bot |
| `api.bots.remove_all()` | Takes them all out |

### Example: a squad on a key

```lua
local api = obsidian.import("obsidian.api")
local squad = {}

obsidian.keybind("squad", function()
  if #squad > 0 then
    api.bots.remove_all()
    squad = {}
    return
  end
  for _, name in ipairs({ "Alpha", "Bravo", "Charlie" }) do
    local bot = api.bots.add({ name = name })
    if bot then
      bot:follow(nil, 4 + #squad * 2):fight(30)
      squad[#squad + 1] = bot
    end
  end
end)
```

## Recipes

Each recipe is a whole `main.lua`. Put it in a folder with an `obsidian.json` that has `"scope": "session"` and `"requires": ["obsidian.api"]`, and add any keys it uses, as Options and keys (in Obsidian's Wiki) shows.

### Low gravity on a key

An effect of your own, switched with a key. It stays on through respawns and missions until the key is pressed again.

```lua
local api = obsidian.import("obsidian.api")

api.effects.define({
  id = "moonwalk.low_gravity",
  apply = function() api.effects.set("gravity", -6) end,
  remove = function() api.effects.set("gravity", false) end,
})

obsidian.keybind("toggle", function()
  api.effects.toggle("moonwalk.low_gravity")
  api.ui.hint(api.effects.is_on("moonwalk.low_gravity") and "Low gravity" or "Normal gravity", 3)
end)
```

### A stronger rifle for everyone

An edit, made once the game has built its weapon tables. Until then `set_unit` answers `false`, so the frame function tries again, and returning `true` stops it. When the lobby stops being cleared the edit comes off, and it goes back on when the lobby clears.

```lua
local api = obsidian.import("obsidian.api")

obsidian.on_frame(function()
  return api.edits.set_unit("equipment/wep_assaultrifle_01", "weapon_info.power", 150) == true
end)
```

### A stratagem that stuns everything nearby

A custom stratagem with a behaviour of its own. Other players see a flare of the base, the airstrike, and then the stun that lands.

```lua
local api = obsidian.import("obsidian.api")

api.stratagems.define({
  name = "stunner_stun_bomb",
  base = "stratagem_airstrike",
  title = "Stun Bomb",
  description = "Stuns every enemy within 15 metres of the flare.",
  code = { "up", "down", "up", "down" },
  stats = { cooldown_time = 45 },
  on_activate = function(ctx)
    for _, enemy in ipairs(api.enemies.near(15, ctx.position)) do
      api.enemies.apply_status(enemy, "flashbang_stun")
    end
    api.world.flash()
    return false
  end,
})
```

`api.world.flash()` only works on forest planets, and answers `false` elsewhere, which is fine here.

### Two stratagems in one call

A resupply that brings an orbital strike down beside it. The position is copied first, because the game's vector only lasts the frame.

```lua
local api = obsidian.import("obsidian.api")

api.stratagems.define({
  name = "combo_armed_resupply",
  base = "stratagem_resupply",
  title = "Armed Resupply",
  on_activate = function(ctx)
    local p = ctx.position
    api.stratagems.call("stratagem_orbital_strike", { x = p.x + 12, y = p.y, z = p.z }, 2)
  end,
})
```

### Combat music only in big fights

The game's own music stays until more than 12 enemies are around, then a boss track takes over, and it lets go once things calm down.

```lua
local api = obsidian.import("obsidian.api")
local frames = 0

obsidian.on_frame(function()
  frames = frames + 1
  if frames % 30 ~= 0 or not api.game.in_mission() then return end
  local busy = #api.enemies.near(40) > 12
  local held = api.music.now().held
  if busy and not held then
    api.music.play("music_boss_" .. (api.mission.params() or {}).enemy)
  elseif not busy and held then
    api.music.release()
  end
end)
```

`api.mission.params().enemy` is the mission's faction, `"bugs"`, `"cyborgs"` or `"illuminates"`, which matches the boss tracks' names.

### A shared kill count

Each machine shares its own count. Every 50 kills of yours, a hint shows you the whole lobby's total.

```lua
local api = obsidian.import("obsidian.api")
local mine = 0

api.events.on("on_enemy_killed", function()
  mine = mine + 1
  api.lobby.share("kills", tostring(mine))
  if mine % 50 == 0 then
    local total = mine
    for _, text in pairs(api.lobby.shared("kills")) do total = total + (tonumber(text) or 0) end
    api.ui.hint("The squad has " .. total .. " kills")
  end
end)
```

### A sparring partner

A bare Helldiver that stands at the cursor and keeps facing you, to practise aiming at.

```lua
local api = obsidian.import("obsidian.api")
local dummy

obsidian.keybind("dummy", function()
  if dummy then dummy:remove() dummy = nil return end
  dummy = api.bots.add({ name = "Dummy", bare = true, position = api.world.cursor() })
end)

obsidian.on_frame(function()
  if dummy and dummy:alive() then dummy:aim_at(api.world.ahead(0)) end
end)
```

### A marker on the next objective

```lua
local api = obsidian.import("obsidian.api")
local marker

obsidian.on_frame(function()
  if not api.game.in_mission() then marker = nil return end
  for _, o in ipairs(api.mission.objectives()) do
    if o.state == "pending" and o.position then
      if marker then marker:move(o.position) else marker = api.map.marker(o.position, { size = 26 }) end
      return
    end
  end
  if marker then marker:remove() marker = nil end
end)
```

## Rules worth knowing

The API's calls already keep to these rules. They matter when your mod reaches past the API to the game's own tables and functions.

### Guarded values

> [!WARNING]
> The game keeps hashed copies of guarded values such as `hitpoints_real`, `rounds`, `cooldown_timer`, `uses_left`, `num_grenades` and `extra_lives`. Writing one directly trips its anti-tamper check, which cuts the player off from the network until they restart. Use `api.game.protected` or a queued command. `api.edits` refuses those keys.

### Errors no script can catch

- A queued command with a name the game doesn't know stops the game, inside its own update, where no `pcall` reaches. `api.game.command` only sends commands from a list of known ones.
- Spawning a unit whose package isn't loaded stops the game. `api.enemies.available(enemy)` checks, and every spawn in the API checks first.
- A wrong type in a bot's input table is an error inside the game's update. `api.bots` fills the table with the types the game expects.
- Each screen has sound worlds of its own, and the engine destroys them when the screen goes. Asking a gone world about one of its sounds took the game down in testing, so keep a sound id only for the screen it was made on.

### Values that look right and aren't

- A timer the game runs while it's above zero, such as a hellpod's `drop_time`, never finishes at 0. Use 0.01.
- The game's vectors last only the frame they were made in. One kept in a variable and read later comes back as NaN. Copy the numbers, or use `api.game.box`.
- A stratagem's upgrade levels can set a field for themselves. Change it at every level with `api.stratagems.edit`.
- A weapon keeps a copy of its settings for each upgrade level. `api.edits.set_unit` reaches every copy, and a direct write to the base table doesn't.

### What reaches other people

- XP and rank go into the shared leaderboards with the next ordinary results, even after a purge. The API has no way to change them, on purpose.
- Paid content stays paid. Everything that lists or gives items goes through the DLC check.
- `api.console.run` refuses commands that reach the shared backend, wipe saves or achievements, or unlock paid content. `spawn_enemy` runs only with nobody else in the lobby, because it loads a package on this game alone.
- A custom stratagem is always its base on the network. Whatever it calls down has to be a unit every game has.

### Who owns what

Each enemy, player and object is run by one machine, its owner. Commands only reach units this machine owns, so the API sends changes to other machines' units through the game's own requests, which go to the owner. That's why `api.enemies.kill`, `damage` and `apply_status` work on any enemy, and why `api.gear.tune` only reaches the weapons in this machine's hands.

The host runs encounters, patrols, objectives and the end of a mission. Calls that change those answer `"host_only"` on a client.

### Session mods and the lobby

A session mod's hooks, frame functions, effects and edits stop while the lobby isn't cleared, and come back when it clears. Give every effect a `remove`, and don't keep state that only makes sense while your changes are on. Writing session mods (in Obsidian's Wiki) goes through the rest.

<!-- Everything below is generated by tools/reference.py from the source. Don't edit it by hand. -->

## Every call (Obsidian API 1.38.1)

Each table of `api`, its calls in the order of the source, and the comment above each one. `bot:`, `drone:`, `prop:`, `marker:` and `page:` are methods of what `api.bots.add`, `api.gear.add_drone`, `api.world.prop`, `api.map.marker` and `api.mod_settings.page` answer, and under `api.menu`, of the page a build gets. Where this list and the guide above disagree, this list is right.

### api.audio

Sound. All of it is local: other players hear their own game.

- `api.audio.BUSES`
- `api.audio.bus(name, db)`: name: one of BUSES. db: a volume in decibels, 0 is as mixed and -60 silent; nil or false gives the bus back to the game.
- `api.audio.play(event, pos)`: event: a sound event such as "ui_select". pos: where it plays, nil for everywhere.
- `api.audio.stinger(name)`: A music sting, through the game's own cooldown of 5 s. Mission only.

### api.bots

Bots: Helldivers this machine plays. A bot is a local co-op player on a pad nobody holds, joined the way the host joins a second controller, so it has everything a player has: a HUD slot, a name, revives, reinforcements. Its character reads an input table this file owns and refills each frame. With every player record taken, a bot can be a bare Helldiver instead: a unit with no record, no HUD and no respawn, for a body to fight beside or shoot at. The input code skips a character with no pad, and its filter commands look the pad up in the pad manager, so a pad number the game doesn't have is an error there. A bare bot takes a pad of the game's that no player and no controller uses, and stands still when there's none left. The input table copies the pad mapping in ControllerSettings, so each field has the type the game's input code compares it as: an axis is a vector, a button a number from 0 to 1, a press or a filter a boolean. A wrong type is an error inside the game's update, outside any pcall. Vectors last one frame in this engine, so the table holds plain numbers and gets new vectors right before the input component reads it, from a hook on its update: vectors made in the frame callback are a frame old by then, and read as NaN.

- `api.bots.add(opts)`: A new bot. opts: name (shown over the bot's head and in the HUD), bare (true for a unit with no record, false to refuse one when every record is taken), position (for a bare bot; next to the player by default). The host or a player alone only: a client's local players join through the host.
- `bot:unit()`: The bot's unit while alive: a player bot has none in the hellpod or while dead.
- `bot:alive()`
- `bot:position()`: Where the bot stands, as { x, y, z }, or nil while it has no body.
- `bot:move(dir)`: Where to walk, as a world direction; the length is the speed, up to 1. nil stops.
- `bot:go_to(pos, distance)`: Walk to a position and stop within distance (1.5 metres) of it. nil stops.
- `bot:hold()`: Stay where it stands: no following and no walking.
- `bot:aim_at(pos)`: Face a position, each frame, while fight has no target. nil stops.
- `bot:aim(dir)`: Where to face and shoot, as a world direction. nil lets it face where it walks.
- `bot:fire(on)`: Holds the trigger until fire(false). A fight order decides the trigger while there is one.
- `bot:firing()`
- `bot:sprint(on)`
- `bot:reload()`
- `bot:dodge()`
- `bot:melee()`
- `bot:interact()`
- `bot:throw()`: A grenade: the throw button is held a moment and let go, a short throw ahead. throw_at aims one. In a vehicle seat it does nothing: that button fires the vehicle's second weapon there.
- `bot:switch()`: The pad's switch button tapped: the primary weapon and the support weapon take turns, and the sidearm goes back to the primary. wield(slot) takes out a chosen one. The game's input reads a press with no release within 0.2 seconds as the button held, which takes out the sidearm, and from the sidearm the support weapon (InputComponent.update_masters, "toggle_sidearm"): a press alone swaps between those two without end. The press and the release go in the same frame, which the game reads as a tap ("toggle_weapon").
- `bot:follow(unit, distance)`: Keep near a unit, a player's by default: walk to it when further than distance (6 metres).
- `bot:fighting()`: The radius it fights in, or false.
- `bot:fight(radius, opts)`: Aim at and shoot the nearest enemy within radius (25 metres), each frame. false stops. opts, all optional: weapon, a slot ("primary", "sidearm", "support" or the game's "primary_weapon" and so on) the bot takes out and fights with, coming back to it after anything else it takes out; only, a function given an enemy unit that answers true for the enemies to shoot (the rest are left alone); secondary, true or a table to fire a vehicle seat's second weapon along with the first (the tank's machine gun, the first exosuit's rockets). The rockets go only while the exosuit faces the target. As a table: secondary.only, a function given an enemy unit that answers true for the enemies the second weapon is for (the vehicle then also turns to them when only leaves them out); secondary.every, the seconds between shots, one press each: 1 for the exosuit's rockets by default, held for the rest.
- `bot:fire_secondary(on)`: In a vehicle seat, holds the second trigger until fire_secondary(false): the tank's machine gun, an exosuit's left arm, the first exosuit's grenades. On foot that button throws a grenade, so it does nothing there.
- `bot:give_weapon(slot, path, upgrade)`
- `bot:give_backpack(path, upgrade)`
- `bot:give_perk(name)`
- `bot:remove_perk()`
- `bot:refill()`
- `bot:refill_backpack()`: The backpack's uses back to full, as api.gear.refill_backpack: the recoilless rifle's rockets, for one.
- `bot:give_stratagem(name)`
- `bot:call(name, pos, delay)`: A real call-in of the bot's, at the bot's upgrade level, as api.stratagems.call.
- `bot:heal()`: Up from downed and at full health, as api.player.heal.
- `bot:teleport(pos)`
- `bot:stratagems()`: The stratagems in the bot's slots: { name, id, uses_left, cooldown, ready } each. uses_left is nil for one with no limit, and cooldown the seconds left before it can be called again.
- `bot:use_stratagem(name, pos, on_done)`: Enters the code of a stratagem the bot holds and throws the beacon toward pos. Answers true once started, or false and a reason: "no_avatar", "no_position", "not_available" (no such stratagem), "not_held" (not in the bot's slots), "cooling_down", "no_uses", "busy" (already calling one). on_done(ok, reason) hears how it ended: true once the beacon is thrown, or false and "jammed" (a no-stratagem zone), "refused" (the game wouldn't call it), "wrong_code", "interrupted" (downed, knocked down, or a vehicle seat), "cancelled", "no_avatar" or "timeout". While it runs the bot stands, faces pos and holds fire, and the other orders wait.
- `bot:using_stratagem()`: The stratagem the bot is calling and the step it's at ("open", "code", "throw"), or false.
- `bot:cancel_stratagem()`: Stops a call. A beacon already in hand goes back, as a melee press does for a player.
- `bot:weapons()`: The weapons it holds, as api.gear.weapons_of.
- `bot:hurts(target, slot)`: The damage one hit of the weapon in a slot does to a target after armor, as api.gear.hurts answers it: square, glancing and on the target's weak spot, 0 where it can't hurt it. slot: as wield takes it, or nil for the weapon in hand. An enemy the rifle answers 0 for is one for the anti-tank weapon. Answers the three numbers, or nil and "bad_slot", "no_avatar", "no_weapon" or "no_target".
- `bot:wield(slot)`: Takes out the weapon in a slot: "primary_weapon", "sidearm_weapon" or "support_weapon", or "primary", "sidearm" or "support". The weapon comes out once the bot stands calm, within 10 seconds, and a help or a use_weapon that starts meanwhile comes back to it afterwards. Answers true, or false and a reason: "bad_slot", "no_avatar", "no_weapon" (nothing in that slot).
- `bot:wielding()`: The slot of the weapon in the bot's hands ("primary_weapon", "sidearm_weapon" or "support_weapon"), or nil.
- `bot:revive(unit, on_done)`: Walks to a downed Helldiver and helps them up: the bot stands by the body, turns to it and presses interact. unit: the downed Helldiver, or nil for the nearest one within 30 metres that no other bot is helping. Answers true once started, or false and a reason: "no_avatar", "downed" (the bot is downed itself), "seated" (in a vehicle seat), "busy" (calling a stratagem, throwing or using a weapon), "no_one_downed" (no one downed near), "already_helped" (another bot is on the way to each one), "not_downed", "self". on_done(ok, reason) hears how it ended: true once they're up, or false and "dead", "downed", "no_help_up" (presses that did nothing), "timeout" or "cancelled". While it runs, the bot's other orders wait, but a bot that fights shoots back at enemies close by on the way.
- `bot:heal_target(unit, on_done)`: Heals a hurt Helldiver with the REP-80, as a player does: the bot walks within range, takes the REP-80 out, faces the target and holds fire until they're at full health, then takes back the weapon it held. unit: the Helldiver, or nil for the most hurt one within 30 metres that no other bot is healing. Answers true once started, or false and a reason: "no_avatar", "downed", "seated", "busy", "no_heal_tool" (no REP-80 in the bot's slots), "no_one_hurt" (no one hurt near), "already_helped", "not_hurt", "self". on_done(ok, reason): true at full health, or false and "dead", "downed" (the target went down: help them up first), "no_ammo", "no_switch" (the REP-80 wouldn't come out), "timeout" or "cancelled".
- `bot:helping()`: What the bot is doing for someone: "revive" or "heal" and the unit, or false.
- `bot:stop_helping()`
- `bot:enter_vehicle(vehicle, seat, on_done)`: Gets into a vehicle seat as a player does: the bot walks to the seat's door, stands and gets in. vehicle: a unit from api.vehicles.near or api.vehicles.nearest. seat: the seat's index (api.vehicles.seats), or nil for the first free seat no other bot is on the way to, a seat that doesn't steer before the one that does. Answers true once started, or false and a reason: "no_avatar", "busy" (calling a stratagem, throwing or using a weapon), "downed", "seated" (in a seat already: leave_vehicle first), "no_vehicle" (a unit with no seats), "no_seat" (no such seat, or none free), "taken". on_done(ok, reason): true once seated, or false and "taken" (someone else got in), "destroyed", "no_vehicle", "refused" (the game wouldn't seat the bot), "downed", "timeout", "cancelled" or "no_avatar". While it runs the bot's other orders wait, but a bot that fights shoots back at enemies close by on the way.
- `bot:leave_vehicle()`: Gets out of the seat it sits in, with the interact press a player gets out with, again each second until out (a seat lets no one out in its first moment). Answers true, or false and "no_avatar" or "not_seated".
- `bot:seat()`: The vehicle the bot sits in and the seat's index, or nil.
- `bot:boarding()`: The vehicle and seat the bot is on its way to (enter_vehicle), or false.
- `bot:ride_along(on)`: Rides along with a Helldiver: when they sit in a vehicle with a seat free that doesn't steer, the bot gets in (enter_vehicle), and once they're out it gets out of that vehicle too. on: true for the unit the bot follows (the player when it follows no one), a unit, or false to stop (the default).
- `bot:mech_friendly_fire(on)`: Hits from the mech the bot pilots cost Helldivers no health while on is false, and for 2 seconds after it gets out, for a shell still in the air. Every Helldiver counts, other players and bots alike, on any machine: the game takes the lower of what the bot's machine and theirs work out. Enemies take the hits as before. true, the game's own way, is the default.
- `bot:avoid_shots(on, opts)`: Gets out of the line of an enemy about to shoot (api.enemies.charging: the Hunter's beam, the Cyborg IFV's laser sight, the Hulk's wind-up): while the line runs within opts.width metres of the bot (2), it walks straight out to the side it's on, and dives just before the shot if still in it. It looks at enemies within opts.radius metres (40). opts.dodge: false to walk out only. Not in a seat, while downed or while calling a stratagem or throwing. false stops (the default).
- `bot:avoiding()`: Whether the bot is getting out of a line now: true and the enemy, or false.
- `bot:auto_get_up(on)`: Downed, the bot holds interact by itself until up: true by default. false leaves it down for a teammate, fighting from the ground with what it holds.
- `bot:auto_revive(radius, opts)`: Helps up downed Helldivers within radius (15 metres) by itself, between other orders, while it follows or fights. Of the bots that do, only the free one nearest to a downed Helldiver goes. false stops. opts.retry: seconds before it tries again someone it failed to help up (5).
- `bot:auto_heal(radius, opts)`: Heals hurt Helldivers within radius (20 metres) by itself with the REP-80, when it carries one with ammo, then takes back the weapon it held. One bot heals each Helldiver, the nearest free one. false stops. opts.below: the share of health under which it starts on someone, from 0 to 1 (0.8, so under 80% health). opts.retry: seconds before it tries again someone a heal failed on (5).
- `bot:auto_helping()`: The radius it helps in by itself: revive's and heal's, or false for each it doesn't.
- `bot:downed()`: Whether the bot is downed now.
- `bot:pickup_cooldown(seconds)`: After a bot picks up a weapon or a backpack, it picks up neither for this many seconds (20 by default). Taking one drops what the bot held in that slot right there, so a bot that keeps pressing interact would pick the dropped one up again, and so on. 0 or false lets it pick up at any time.
- `bot:next_pickup()`: Seconds left before the bot can pick up a weapon or a backpack again: 0 when it can now.
- `bot:sees(target)`: Whether a straight line from the bot's chest reaches the unit before anything else does: a wall, a rock, another body. In a seat, the bot's own vehicle and its guns don't count. True when the game gives no physics to ask.
- `bot:enemies_in_sight(radius, only)`: Living enemies within radius (25 metres) that the bot sees, nearest first. only: a function given an enemy unit that answers true for the ones to count, or nil for all. Each enemy costs a ray, so a mod that looks every second or so rather than every frame spends little.
- `bot:throw_at(pos, on_done)`: Throws a grenade at a point: the bot faces it, charges the throw to the distance and lets go, as a player does. Answers true once started, or false and a reason: "no_avatar", "no_position", "busy" (calling a stratagem or throwing already), "no_grenades". on_done(ok, reason): true once thrown, or false and "interrupted" (downed, knocked down, a vehicle seat), "cancelled" or "timeout". While it runs the bot stands and holds fire, and its other orders wait.
- `bot:throwing()`: Whether the bot is throwing a grenade at a point (throw_at).
- `bot:cancel_throw()`: Stops a throw_at that hasn't let go yet.
- `bot:use_weapon(slot, target, opts, on_done)`: Takes out the weapon in a slot and fires it at a unit, then takes back the weapon the bot held before: an EAT or a recoilless rifle for one heavy enemy, while fight keeps to the rifle. slot: "primary", "sidearm", "support" or the game's "primary_weapon" and so on. opts, all optional: shots, how many shots before it's done (1; math.huge keeps firing until the target dies); time, seconds before it gives up (10); keep, true to keep the weapon out afterwards. on_done may come in place of opts. The bot stands still, faces the target and pulls the trigger only facing it, along a clear line and with no Helldiver in the way; it reloads as auto_reload does, and an empty launcher the bot's backpack reloads is reloaded before the weapon from before comes back, as a player does. Answers true once started, or false and a reason: "bad_slot", "no_avatar", "busy" (calling a stratagem, throwing, using a weapon, or helping someone: stop_helping first), "downed", "seated", "no_weapon" (nothing in that slot), "no_target". on_done(ok, reason): true and "shots" (all fired), "killed" (the target died) or "spent" (the weapon went from the slot after firing, as the EAT does), or false and "no_switch" (the weapon wouldn't come out), "no_ammo", "no_weapon", "timeout", "downed", "seated", "cancelled" or "no_avatar".
- `bot:using_weapon()`: The slot and the target of the weapon the bot is using (use_weapon), or false.
- `bot:cancel_weapon()`: Stops a use_weapon. The weapon from before comes back, as when it ends.
- `bot:auto_reload(on)`: Reloads by itself, as a player would: an empty magazine with a spare left, or an overheated laser with a radiator left. true by default; false leaves reloads to the orders (reload()).
- `bot:remove()`
- `api.bots.all()`
- `api.bots.remove_all()`
- `api.bots.usables(pos, radius, kinds)`: Things a Helldiver can use within radius (15 metres) of a position, or of the player, nearest first: { unit, kind, position, enabled } each. kind is the game's name for it, as above; enabled is false while the game lets no one use it. kinds: a list of those names to keep, or nil for all.
- `bot:use(unit, opts, on_done)`: Uses a thing the way a player does: the bot walks within reach, stands, faces it and presses interact once the game offers it, the press a player's interact sends. A sample, an ammo box, a weapon or a backpack lying about, a hellbomb, a terminal's first press, a thing to carry: a unit from usables, or a teammate (a team reload of their launcher, from the bot's backpack). opts, all optional: reach, the metres from the thing it stops at (1.2); time, the seconds before it gives up (20); presses, how many presses it tries when one does nothing (1). on_done may come in place of opts. Answers true once started, or false and a reason: "no_avatar", "busy" (calling a stratagem, throwing or using a weapon), "downed", "seated", "no_target". on_done(ok, reason): true and "used", or false and "gone" (the thing went before the bot got to it), "not_offered" (the game doesn't let this bot use it from there: an ammo box with the bot's ammo full, for one), "picked_other" (something else stands in the way), "no_effect", "downed", "timeout", "cancelled" or "no_avatar". A new use, revive or heal ends the one running. While it runs the bot's other orders wait, but a bot that fights shoots back at enemies close by on the way.
- `bot:using()`: The thing the bot is on the way to use (use), or false.
- `bot:cancel_use()`: Stops a use that hasn't taken yet.
- `bot:carrying()`: What the bot carries (a hard drive, a missile for the artillery), or nil.
- `bot:drop()`: Puts down what the bot carries, as api.player.drop_carried. Answers true, or false and "no_avatar" or "not_carrying".
- `bot:say(word)`
- `bot:jump(dir, on_done)`
- `bot:jumping()`: Whether a jump is under way.

### api.capture

Screenshots: the game's picture, saved as a PNG or JPEG file. The engine has no call for it, so this goes to Windows through LuaJIT's FFI, which the game's own scripts load (foundation/lua/util/noise.lua sets HAS_FFI on PC): GDI copies the game window's picture off the screen, and GDI+ writes the file. A shot waits a few frames first, with this library's window, its toasts and (on a loader with obsidian.ui.solo) every mod's drawing held back, so the picture has only the game in it. The engine shows a frame a little after Lua draws it, so the copy is taken after the frames it shows are clear. Every C name goes through a name of this library's, `obsapi_<name> __asm__("<name>")`: LuaJIT keeps one namespace for every script in the process, and two mods declaring the same name fail.

- `api.capture.WAIT_FRAMES`: Frames the screen goes without anything of a mod's on it before the copy.
- `api.capture.FOLDER_NAME`
- `api.capture.available()`: Whether shots can be taken here: true, or false and why not ("no_ffi", "not_windows", ...).
- `api.capture.folder(name)`: The Pictures folder of this Windows user (wherever it was moved), with a folder of `name` in it. Answers the path, made if missing, or nil and why not.
- `api.capture.open_folder(path)`: Opens a folder in Windows' file explorer.
- `api.capture.shot(opts, done)`: Takes a shot after the screen clears of mods: M.WAIT_FRAMES frames with nothing of this library's or any mod's drawn. done(path) gets the file's path, or done(nil, reason). opts: folder (a full path) or folder_name (a folder in Pictures, "Helldivers" by default), name (an os.date pattern), format ("png" or "jpg"), quality (1 to 100, JPEG), crop ({ x, y, w, h } in shares of the picture) or aspect (a width over height, cut from the middle), keep (true: the calling mod's own drawing stays in the picture, a tint or a caption, say; its guides are its to hide while busy()). Answers true, or false and why not.
- `api.capture.busy()`: Whether a shot is waiting, while the screen has to stay clear: a mod drawing its own guides checks it.

### api.catalog

Game content by name. Lists come from the game's own tables where it has them, and paid content a player doesn't own is left out: DLC stays paid. What a player has unlocked by playing doesn't matter here. unlocked() answers that for a mod that wants to know.

- `api.catalog.text(key)`: A display name in the game's language. The menu's font covers Latin-1, so anything beyond that falls back to a readable form of the key rather than a row of boxes.
- `api.catalog.usable(name)`: False for an item of a paid pack this player doesn't own.
- `api.catalog.xp_and_rewards()`: The player's XP and earned rewards from the save, or nil before there's one to read.
- `api.catalog.unlocked(name)`: True for an item the Loadout screen would offer this player (menu_screen_loadout.lua:142): earned, or in a paid pack they own. The lists here don't use it.
- `api.catalog.primaries()`
- `api.catalog.sidearms()`
- `api.catalog.stratagems()`
- `api.catalog.perks()`
- `api.catalog.support_weapons()`: Support weapons are stratagems whose crate holds the weapon: { name, unit_path }. All of them carry the subtype weapon; support_weapon leaves out the mortar, recoilless, LAW and missile launcher.
- `api.catalog.unowned_path(path)`: True for a unit path of a paid weapon this player doesn't own, in the loadout lists or in a crate.
- `api.catalog.backpacks()`: Every pack in a crate of a stratagem this player can use: { name, unit_path, stratagem }. The path is the settings' own backpack_path, the only kind the game's set_backpack can read safely.
- `api.catalog.backpack(path)`
- `api.catalog.crates()`: Crates a stratagem drops: { name, unit_path }.
- `api.catalog.pickups()`: Everything crates hold, as pickups that can lie on the ground: { name, unit_path }.
- `api.catalog.by_subtype(subtype)`: Stratagems of a subtype, by what they send down: { name, unit_path }.
- `api.catalog.vehicles()`: The seven vehicles. The mannable turret has a vehicle's settings too, but it doesn't go anywhere.
- `api.catalog.max_upgrade(unit_path)`: The highest upgrade value a unit takes. Bitmask upgrades add up, and the game's limit is 15.
- `api.catalog.stratagem(name)`
- `api.catalog.item_name(unit_path)`: The stratagem or weapon a unit path belongs to, by the name the game keeps upgrades under.
- `api.catalog.cosmetics(slot)`
- `api.catalog.status_templates()`
- `api.catalog.enemies(faction)`: Every enemy: { key, name, loc, faction, unit, settings, boss, console, packages }.
- `api.catalog.enemy(key)`
- `api.catalog.enemy_groups()`
- `api.catalog.waves(faction)`: The encounter waves of a faction, as the game lists them: { name, cost, events }.
- `api.catalog.fields(family)`: Editable fields of a family, as listed in data.lua.
- `api.catalog.families_of(settings)`: The families a settings table has fields for, judged by what it holds.

### api.combat

Damage by who takes it. Every hit asks HealthComponent or ShieldComponent what it costs, so a hook there reaches them all, and the game still makes the guarded write with the answer. No attacker is passed in, so a scale goes by victim. Each player's game works out its own hits, so everyone in a lobby should use the same numbers.

- `api.combat.on_hit(fn)`: fn(victim, hit) for every hit a player of this machine lands that costs health, whichever machine runs the victim, in any lobby: client mods can listen too. hit: damage, owner_unit (the player), attacker_unit (a weapon, a grenade, a projectile...), slot (primary_weapon, sidearm_weapon or support_weapon when attacker_unit is a weapon in the player's inventory, else nil) and position (where it landed, { x, y, z }, when the hit says). Teammates and the player's own body count as victims too.
- `api.combat.off_hit(fn)`
- `api.combat.on_fatal(fn)`: fn(unit, damage) for a hit that would kill a player of this machine. Answering true spares them: the hit leaves them 1 hitpoint, or a downed player where they were. The first true wins.
- `api.combat.off_fatal(fn)`
- `api.combat.scale(t)`: t: players, enemies. A multiplier from 0 to 100; 1 or false leaves that side alone, and a side left out stays as it is.

### api.console

The developers' console commands. In a release build Debug.console is a dummy that throws away what each game script registers, but the scripts still build their command tables. Putting a collector in the dummy's place keeps those tables, with no debug world, no hotkeys and no writes to the user settings. The stock console itself stays off.

- `api.console.denied(name)`
- `api.console.commands()`: Every command the game has registered right now, sorted, without the denied ones.
- `api.console.run(line)`: Runs one command line. As in the game's own dispatch, every plugin with that command runs. Returns ok and a message.

### api.data

What can be edited and spawned, generated from the game's own data and checked against it. apply says when a change takes effect: live (next read), reload (cached on an entity: next spawn, or now through gear.refresh), spawn (next spawn), use (next call-in or state entry), loadout (next mission or respawn).


### api.edits

Checked, recorded, reversible changes to the game's data tables. Every table stays the same table: entities and shot callbacks hold direct references to them. A journal keeps each old value once, so undoing is exact and tells false from absent. Weapons have a deep-cloned table per upgrade, which a change to the base table would miss, so each unit edit recomputes those clones in place from the edited base.

- `api.edits.set_unit(settings_path, path, value, opts)`: A value in a unit's settings file, by settings path and dotted field path. opts: min, max, new (the field may be absent), target (a name for the list), apply (see fields.lua).
- `api.edits.set_table(target, t, path, value, opts)`: A value in any table the game reads: a stratagem, a status template, character_info. opts as above, and also: more paths in the table that take the same value, as one change.
- `api.edits.value(settings_path, path)`
- `api.edits.table_value(t, path)`
- `api.edits.original(settings_path, path)`: Whether a field was changed, and its value before the change.
- `api.edits.list()`
- `api.edits.count()`
- `api.edits.revert(id)`
- `api.edits.revert_where(settings_path, path)`
- `api.edits.table_changed(t, path)`
- `api.edits.revert_table(t, path)`
- `api.edits.revert_all()`

### api.effects

Effects: named switches that stay on across respawns and missions. The game rebuilds component flags per mission and avatar state per spawn, so an effect is applied again whenever the state or the avatar changes. An effect has a value: false when off, true or a number when on. define{ id, apply = fn(ctx, value), remove = fn(ctx, value), frame = fn(ctx, value, dt) } ctx: state, name (of the state), record (local player), unit (avatar or nil).

- `api.effects.define(def)`
- `api.effects.get(id)`
- `api.effects.is_on(id)`
- `api.effects.set(id, value)`: value false or nil switches it off. A changed value applies again.
- `api.effects.toggle(id)`
- `api.effects.clear()`
- `api.effects.active()`

### api.enemies

Enemies: spawning them, stopping them, getting rid of them. The host runs the encounter, patrol and wave managers. Enemies themselves are shared out between peers, so kills go through the owner. Only units whose package is loaded can spawn: an unloaded unit is a fatal engine error, so every spawn checks first.

- `api.enemies.available(enemy)`: Whether a unit from the catalog can spawn right now.
- `api.enemies.list()`: Living enemies known to this peer.
- `api.enemies.count()`
- `api.enemies.MAX_SAFE`: The game keeps to 16 enemies, and a map holding far more took a mission down with no error. The Trainer stops here, though spawn doesn't: this is a chosen line, not a measured limit.
- `api.enemies.carried()`: Every enemy the map is carrying: corpses count until they decay, and the queue spawns any moment.
- `api.enemies.room()`
- `api.enemies.spawn(key, count, where)`: key: a catalog key or unit path. where: "cursor", a position, or nil for in front of the player. A client's single spawn goes to the host as a request; groups are the host's to make.
- `api.enemies.spawn_group(key, where)`
- `api.enemies.spawn_entity(path, pos)`: Non-enemy things by unit path, with no package check: only paths from mission_common belong here.
- `api.enemies.kill_all()`
- `api.enemies.kill_near(radius)`
- `api.enemies.kill(unit)`
- `api.enemies.info(unit)`: What the game knows about one enemy: { key, name, faction, boss, hitpoints, max_hitpoints, owned, armor_min, armor_max, large }. armor_min and armor_max are the game's armor numbers for the enemy: a weapon's hit gets through by its power against them (api.gear.weapons_of lists a weapon's power). large is the game's own mark for its biggest enemies (the Tank, the Impaler, the IFV among them). The catalog fields are nil for a unit it doesn't list.
- `api.enemies.charging(unit)`: An enemy that holds fire a moment before a shot, while it holds it: the Hunter's beam (3 seconds), the Cyborg IFV's laser sight, the Hulk's wind-up. On every machine, owner or not: the game runs the shot on each. Answers { time, from, to, effect } or nil (not about to shoot, dead, not an enemy). time: seconds until it fires. from and to ({ x, y, z }): where the aim line runs, ending at what it hits. effect: the line the game draws ("effects/illuminate_hunter_beam", the IFV's laser sight), nil for an enemy that draws none.
- `api.enemies.nearest(pos)`: The closest living enemy to a position, or to the player, and how far it is.
- `api.enemies.apply_status(unit, template)`: A hit of no power that carries the status, the way weapons do it, so it reaches the owner from any peer. The status command itself fails on an enemy this peer doesn't own.
- `api.enemies.stun_near(radius)`
- `api.enemies.near(radius, pos)`: Living enemies within a radius of a position, or of the player, nearest first.
- `api.enemies.chain(pos, count, first, jump)`: A chain of living enemies, as an arc jumps: the nearest within `first` metres of a position, then each time the nearest one not yet in the chain within `jump` metres of the last. Up to `count` of them, in order, and fewer when the chain runs out. pos: a vector or { x, y, z }.
- `api.enemies.damage(unit, power, statuses, opts)`: A hit from the player, as apply_status sends it, so it reaches the owner and armor counts. statuses: a list of status templates that go with it, or nil. opts.through_armor: true for a hit no armor stops, as burns and poison are.
- `api.enemies.set_hitpoints(unit, hitpoints)`: The owner sets it, by command or by the game's own request, as a kill does.
- `api.enemies.despawn_all()`: Gone with no corpse, no kill and no objective progress: a clean-up.
- `api.enemies.despawn(unit)`
- `api.enemies.call_encounter()`
- `api.enemies.add_patrol()`
- `api.enemies.load_faction(name)`: Every peer needs the package to mirror a unit, so it's for solo play. The flush stops the game for a moment, as the game's own console does (encounter_manager.lua:736-753).
- `api.enemies.max_enemies()`
- `api.enemies.MAX_CAP`: The most enemies at once. Waves stop at two limits: the global cap on all enemies, and the encounter manager's own, 6 to 12 by difficulty. The game asks only the host.
- `api.enemies.set_pressure(t)`: Bigger fights with no change to the seed. t: cap, difficulty, patrols, interval. A number sets one, false gives it back to the game, and one left out stays as it is.
- `api.enemies.waves()`: Names of the waves this mission's faction can have.
- `api.enemies.force_wave(name, pos)`: A named wave now, at a position or ten metres ahead. Its groups are spawned directly: the game only runs a wave it picked itself, with bookkeeping that a forced one would break.

### api.events

Events: hearing what happens in a mission, without polling. The game tells its listeners through an event delegate, a new one per game state. It has no pcall, and the loader's session gate doesn't reach it, so both are done here. Each function a mod gives is a hook on a small table of its own: the loader then runs it protected, as that mod, and not at all once the mod is off.

- `api.events.NAMES`: The game's own names. What each one carries is in the wiki.
- `api.events.on(name, fn)`
- `api.events.off(name, fn)`: A new list each time, so a function can take itself off while its event is going round.

### api.game

Reaching the running game: the current state, the local player, and writes the game accepts. Two rules from the game's own code shape this file. A queued command with an unknown name fails an assert inside the game's update, where no pcall can catch it, so command() takes only names listed here. A protected value written directly trips the game's tamper check, so protected() goes through the game's own setter, and data edits refuse those keys (see edits.lua).

- `api.game.global`
- `api.game.state()`: The state object and its name, in every game state once the game has booted.
- `api.game.state_name()`
- `api.game.in_mission()`
- `api.game.on_ship()`
- `api.game.is_host()`: Host of the lobby, or alone with no lobby at all.
- `api.game.lobby()`
- `api.game.alone()`: Nobody else in the lobby. With no way to tell, it answers no: the callers are the risky actions.
- `api.game.me(st)`: The local player's record. players[1] is the first player in the lobby, not this one.
- `api.game.avatar(rec)`: The unit of a player record, when there is one and it's alive. A record in the ship has a different game object type, so the field is checked first.
- `api.game.my_unit()`
- `api.game.component(name)`
- `api.game.all_avatars()`: Everyone's units in this session: the local one first.
- `api.game.box(v)`: A vector as a table the game keeps across frames.
- `api.game.unbox(t)`
- `api.game.command(unit, component, command, data)`: Queues a command on a unit this peer owns. Returns false when the game would have asserted.
- `api.game.protected(component, state, key, value)`: Writes a protected value through the game's own setter. Components that copy state only when dirty need the flag as well, or the change never reaches the slave state.
- `api.game.master(unit, component)`: The master state of a component on a unit this peer owns.
- `api.game.masters(name)`: Unit -> context maps for a component, master or every peer's slave copy.
- `api.game.slaves(name)`
- `api.game.forfeit_progress()`: What a player earns in their own save is theirs: Obsidian no longer holds any of it back, and asks of these two do nothing there. They stay so the mods calling them keep working, and pass the ask on to an older loader that still holds.
- `api.game.hold_progress()`
- `api.game.after(frames, fn)`: Runs fn after this many frames, for work the game needs spread over frames.

### api.gear

Weapons, ammunition, grenades, perks, backpacks and vehicles of the local player.

- `api.gear.refill(unit)`: Fills every weapon. For beam weapons the rounds value is heat, so full means zero.
- `api.gear.refill_grenades(unit)`
- `api.gear.set_grenade(path)`: grenade type: equipment/equipment_grenade_01, _incendiary, _stun or _smoke.
- `api.gear.give_weapon(slot, path, upgrade, unit)`: slot: primary_weapon, sidearm_weapon or support_weapon. The old weapon drops as a pickup. upgrade: a value from 0 to 15, or nil for what the player owns for that weapon. A paid weapon the player doesn't own is refused. unit: a player on this machine, the main one by default.
- `api.gear.give_perk(name, unit)`: Every other peer picks the new perk up with no setup, and laser sight's per-frame code needs its setup, so that one would fail inside their update. It's kept to solo play.
- `api.gear.remove_perk(unit)`
- `api.gear.add_perk(name, unit)`: unit: nil for the local player. A new body after a death starts with none.
- `api.gear.remove_extra_perk(name, unit)`
- `api.gear.extra_perks(unit)`: The names of the perks added on top, sorted.
- `api.gear.give_backpack(path, upgrade, unit)`: path: a backpack_path from catalog.backpacks. The game reads settings no other path has, outside any pcall, so a path from elsewhere is refused. upgrade and unit as in give_weapon. The old pack drops.
- `api.gear.add_drone(path, unit, upgrade)`
- `drone:alive()`
- `drone:remove()`: Only the station goes, as when the game drops a pack: a drone without its station takes itself away.
- `api.gear.refill_backpack(unit)`: The backpack's uses back to full. unit: a player on this machine, the main one by default.
- `api.gear.current_vehicle`
- `api.gear.repair_vehicle()`
- `api.gear.refill_vehicle()`
- `api.gear.refresh()`: Fields cached on live weapons take a settings change when reloaded this way. Loaded rounds stay, so a bigger magazine shows after the next reload.
- `api.gear.hurts(weapon, target)`: The damage one hit of a weapon does to a target after armor, as the game works it out: square (the hit meets armor_min), glancing (armor_max) and on the target's weak spot (the lowest armor, from the body parts with armor of their own). 0 means the weapon can't hurt it there. A gun's bullet or pellet with the weapon's armor piercing; a weapon that explodes adds the blast at the center, which always lands square; a launcher counts what it fires. A beam or a flamethrower answers per second. Critical hits don't count. weapon: a weapon unit (api.gear.weapons_of). Answers the three numbers, or nil and "no_weapon" or "no_target" (a unit with no health).
- `api.gear.weapons_of(owner)`: The weapons a player's unit holds: { unit, component, slot, info }, where slot is primary_weapon, sidearm_weapon or support_weapon, and info the weapon's settings before any tuning. owner: nil for the main player.
- `api.gear.tune(unit, component, changes)`: changes: { field = factor } on a number of its settings, { attribute = true or false } on one of its attributes. It replaces the tuning before; {} takes it all off. It reaches only this machine's own weapons, and each player runs it for theirs. component "melee" tunes the weapon's melee attack: power, and duration and delay for how soon it hits and the next can start.

### api.lobby

Who's in the lobby. Read only. Names live on the mission's player objects, so a teammate has one only during a mission.

- `api.lobby.players()`: { peer, name, ping, host, me }, the local player included.
- `api.lobby.share(name, value)`
- `api.lobby.shared(name)`: What each other machine shares under `name`, by peer. A machine that shares nothing is left out.

### api.map

The mission map: open or closed, zoom, the view, every player's ping, and a mod's own markers. The map is a character state, CharacterStateMap, which leaves on the frame its map input goes false, so opening it from here holds that input until the player's own key takes over. The game sends the character its input only when the input changes, so a value forced here stays until it's put back, and the idle state would open the map again on it. The player's key is read from the input component's own table, which the pad manager fills each frame. Zoom and the view are per local player in the HUD's hud_info. Markers are drawn after the game's map, in the map's own units, on the map gui of each local player.

- `api.map.NO_PING`: The map's own units, as the HUD works them out: centred, turned 45 degrees, and scaled to fit 350 at zoom 1. This value, the field's default, means no ping.
- `api.map.to_map(pos, l)`: A world position as map units at zoom 1, or nil outside a mission.
- `api.map.to_world(x, y, l)`: Map units back to a world position on the ground plane (z 0).
- `api.map.is_open(unit)`: Whether a unit's map is open: the local player's when unit is nil.
- `api.map.open()`: Opens the local player's map, as the map key does. It stays open until the player closes it, does anything else (dodge, reload, a stratagem), or close() is called.
- `api.map.close()`
- `api.map.zoom()`: The local player's map zoom: 1 at the start, 0.5 at the furthest.
- `api.map.set_zoom(z)`
- `api.map.view()`: The world point under the map's crosshair: the middle of the view, where a ping would go.
- `api.map.cursor`
- `api.map.look_at(pos)`: Pans the local player's map so a world position is under the crosshair.
- `api.map.pings()`: Every player's ping as { record, owned, position }, for the players that have one.
- `api.map.marker(pos, opts)`: A marker of the mod's own on everyone's map on this machine. pos: a world position, or opts.unit to follow a unit. opts: icon (a material the map gui loaded, "icon_map_pickup_generic" by default), size in map pixels (18), color { a, r, g, b }.
- `marker:move(pos)`
- `marker:set(opts)`
- `marker:remove()`
- `api.map.clear_markers()`

### api.menu

The in-game window that F6 opens: a folder per mod down the left with that mod's pages in it, and the open page on the right. Your pages' functions run as your mod. A session mod's pages show while the lobby is cleared, a client mod's in any lobby.

- `page:header(label)`: A heading over the rows after it.
- `page:label(label, opts)`: A line of text.
- `page:toggle(label, opts)`: On or off. opts: get(), set(value), default.
- `page:number(label, opts)`: A number. opts: get(), set(value), min, max, step (Shift takes ten), format, default.
- `page:choice(label, opts)`: One of opts.choices, a list of { id, label }. A choice's swatch, { r, g, b } from 0 to 255, shows beside its label. opts: get(), set(id), default.
- `page:slider(label, opts)`: A number on a bar that the mouse drags. opts: get(), set(value), min, max (both needed), step, format, default. The keys step it as they step a number.
- `page:action(label, fn, opts)`: A row that calls fn(). A string it returns becomes a toast.
- `page:input(label, fn, opts)`: A row that asks for a line of text, then calls fn(text). A string it returns becomes a toast. With opts.code, it takes arrows instead: the arrow keys, W A S D and a pad's directions, handed over as words, "up down left".
- `page:page(label, build, opts)`: A row that opens a page inside this one. build(page) runs each time it opens.
- `page:refresh()`: Builds the page again after the current action, as an action can change what it lists.
- `api.menu.close()`: Closes the window and gives the input and the cursor back to the game.
- `api.menu.open()`: Opens the window where it was left, or on the first page. false during logos, cutscenes, screen changes and while the chat is typing.
- `api.menu.toggle()`: Opens or closes it. A second toggle in the same frame does nothing, so two keys bound to it, such as an older Trainer's beside this library's, don't cancel out.
- `api.menu.is_open()`: Whether the window is open.
- `api.menu.toast(text, seconds)`: A short message at the top left of the screen, or beside the window while it's open.
- `api.menu.add(title, build, opts)`: A page in the list down the left, in the folder of the mod that adds it. title: text, or a function that answers it. build(page) runs each time the page opens. opts.icon: one of obsidian.ui.glyphs().
- `panel:open(tab)`: Opens the panel on a tab, closing the F6 window and any other panel. false while a panel can't open (as the window can't: logos, cutscenes, screen changes, the chat typing).
- `panel:close()`: Closes the panel, gives the game the input and the cursor back, and calls on_close. A hidden cursor (set_cursor_hidden) comes back for the next open.
- `panel:is_open()`
- `panel:hide(on)`: Hidden, it draws nothing and reads no keys, and the cursor goes, but the game still gets no input: the mod keeps steering. A screenshot hides every panel by itself.
- `panel:hidden()`
- `panel:set_cursor_hidden(on)`: With on, the cursor hides and the panel leaves the mouse alone, still drawn: for looking around while a mouse button is held, say. Off brings the cursor back. Closing the panel turns it off.
- `panel:cursor_hidden()`
- `panel:set_opacity(a)`: How strong the background is, from 0 (clear) to 1, 0.5 at first. The rows and the words stay at full strength. Kept with the panel's place for the next launch.
- `panel:opacity()`
- `panel:set_scale(s)`: How big everything in the panel is drawn, from 0.6 to 1.6, 1 at first, growing from the corner the panel is kept at. Kept with the panel's place for the next launch.
- `panel:scale()`
- `panel:reset_place()`: Puts the panel back where and as big as it first opened, help room included. Opacity and scale stay.
- `panel:tab_number()`: The tab that's open, by number.
- `panel:select_tab(i)`
- `panel:refresh()`: Builds the open tab again, as after an action that changes what the tab lists.
- `panel:under_mouse()`: Whether the mouse is over the panel now: the mod leaves the wheel and clicks there to the panel. false while the cursor is hidden.
- `panel:typing()`: Whether the panel is taking the keys for itself now: typing into a row. Also answers "number" while a number is typed, which takes digits, the point and the minus only, and "text" otherwise, so a mod can keep reading the letter keys while a number is typed.
- `api.menu.panel(spec)`: A panel, closed. spec: title (text or a function); tabs ({ { title = ..., build = function(page) end, icon = ... }, ... }), where an icon (a name of obsidian.ui.glyphs(), an icon of the game's HUD, or shapes of the mod's own: a list of convex polygons on a grid of 16 with y up, each a flat list of points { x1, y1, x2, y2, ... }, as the glyphs are made) shows in place of the title, and the title shows over the help; id (names the kept place among the mod's panels, "panel" by default); anchor ("bottom_right", the default, "bottom_left", "top_right", "top_left", or "right" and "left" for the full height down that side; side is the same); width and height (in the game's 1280 by 720 design units, 540 by 360 by default, 390 wide down a side); opacity (0.5) and scale (1) until the player changes them; buttons (in the title bar, left of the close button: { { glyph = "reset", help = "...", run = function() end } }, run as the mod, a string answered becoming a toast); sounds (false, and the panel plays none of the game's menu sounds); status (a function answering a short text for the title bar); guide (key guide entries before the panel's own: { keys = { "H" }, label = "Hide" }); headings (true: the open tab's title in capitals over the tab's rows, with a reset button beside it for a tab that has `reset`, a function run as the mod whose answered string becomes a toast, and `reset_help` for the foot); on_close().

### api.mission

The mission: objectives, extraction, waits, samples, and choosing what to play. Objectives and the end of a mission belong to the host. The objective commands walk the entities this peer owns, so an object a client is using can be missed; each action says what it reached.

- `api.mission.objectives()`: Every objective of this mission: { name, text, type, state, group, done, total, position }. state: pending, complete or failed. done and total: the count the objective list shows, where it has one. position: a plain copy of the first marker, or nil.
- `api.mission.finish_objectives()`
- `api.mission.restart_objectives()`
- `api.mission.win()`: Win now, with no shuttle. The score pays for extracted players, so they're marked extracted.
- `api.mission.abort()`: Back to the ship, as the pause menu does it.
- `api.mission.MUTATORS`: The game's proving ground modifiers, in any mission. One at a time, as the game has them. Two are read live from the level's params, a field that's empty in a normal mission. Level generation reads it too, so it's set only with an avatar on the map, and a real proving ground keeps its own. The other two are timers: flares near a player, every drop_interval, as the proving grounds drop them.
- `api.mission.mutator(name)`: name: one of MUTATORS, or nil or false for none.
- `api.mission.spawn_samples()`
- `api.mission.collect_samples()`
- `api.mission.reveal_map()`
- `api.mission.params()`: What the current mission's seed says, or nil: the game's names for its parts, with layout (1 to LAYOUTS) added, and the seed.
- `api.mission.TIMES`
- `api.mission.ENVIRONMENTS`
- `api.mission.FACTIONS`
- `api.mission.TYPES`
- `api.mission.LOOKS`: How a planet looks: one of its three terrain sets, or the look of a faction's world, which the game gives only event planets, each on one planet type. Pairs the game never draws may have no art.
- `api.mission.LAYOUTS`: How many layouts each set of parts has: the seed holds the layout above its seven digits of parts, and the game sends it as a 31-bit number.
- `api.mission.seed(choice)`: A mission seed from chosen parts, or false and a reason. choice: { time, environment, enemy, kind, difficulty, look, layout }: 1-based indexes in TIMES, ENVIRONMENTS, FACTIONS, TYPES and LOOKS, a difficulty from 1 to 15, and a layout from 1 to LAYOUTS. look and layout are random when left out. Reasons: bad_choice, look_not_here.
- `api.mission.practice(choice)`: Starts a solo practice mission from the ship with chosen parts. As in the game's own training menu, it pays no XP or samples and touches no campaign. Proving ground types need a second seed, so they aren't offered. choice: as for seed: { time, environment, enemy, kind, difficulty, look, layout }.
- `api.mission.drop(choice)`: Starts a solo mission from the ship with chosen parts, as a real mission: it pays XP and samples and counts toward the account like any drop. The campaign is left as it was at the drop, win or loss: no planet or mission done, no planet stats, no event or boss progress, and no Galactic War or leaderboard report from it. Proving ground types aren't offered. choice: as for seed: { time, environment, enemy, kind, difficulty, look, layout }.

### api.mod_settings

Mod Settings: a row of the game's pause menu that opens a list of mods, and a page of settings for each, drawn and driven by the game's own Settings screen (MenuScreenOptions), so they look and handle like the game's. A mod asks for its page and adds rows to it; the values are kept for the next launch. These are a mod's in-game settings. A row made with `option = true` is instead one of the options in the mod's obsidian.json, under the same id: it starts from the value set in Obsidian, and a change in game is kept as `option/<mod id>/<option id>` until Obsidian takes it into the profile (it does that while the game is closed, and removes the key: core/src/game_options.rs in Obsidian). The pending value wins over the app's at the next launch, so a change made in game isn't lost when Obsidian wasn't open. Values live in this library's storage. obsidian.storage writes to the mod whose code is running: a change from the menu (this library's code) is written at once, one from a mod's own code waits in `dirty` for this library's frame callback. The menu's hooks are wraps, never gated, so a client mod's page opens in any lobby. Words (a title, label, info or choice label) are a string or a table by language, { en = ..., fr = ..., es = ..., ["pt-BR"] = ... }, read when drawn, since pages are made at boot before the game knows its language.

- `page:toggle(id, opts)`: opts: label, info (a line under the rows while it's selected), default, on_change(value), option (true: the row is the mod's obsidian.json option with this id).
- `page:choice(id, opts)`: opts.choices: { { id = "...", label = "..." }, ... }; default: one of the ids, else the first.
- `page:number(id, opts)`: opts: min, max, step (each step is a stop on the row's arrows, 100 at most), default, format(value) for the words shown.
- `page:button(label, fn, opts)`: A row that does something when pressed. Nothing is kept.
- `page:get(id)`
- `page:set(id, value)`: Sets a value as the page would; false when there's no such row or the value doesn't fit it.
- `api.mod_settings.page(title)`: The calling mod's page, titled for the list of mods. Asking again gives the same page.
- `api.mod_settings.pause_row(id, label, fn, opts)`: A row of the pause menu, under the Mods row, that closes the pause menu and runs fn() when chosen. label: words, or a table by language. opts.when(screen): true where the row shows, screen being "game" in a mission or "menu" on the ship; without it the row shows on every pause menu. Asking again with the same id replaces the row.
- `api.mod_settings.remove_pause_row(id)`: Takes a pause row away.

### api.music

The soundtrack: what plays, holding a track of your choosing across screens, pausing and volume. All of it is local, like the rest of the sound. Each screen keeps its music in one place of its own. The main menu's music object, the ship and the mission's start and end screens each hold one event id, and swap it when they change track: a held track takes that id's place, so the screen's own fades go on working on it. The ship sets the volume of that id every frame without asking whether there is one, so the slot never goes empty: silence leaves the stopped id in it. A mission's music comes from its audio state machine instead, which starts threat and action music as patrols and fights come and go. A held track there plays beside them while they're kept silent through their "volume" parameter, the one the machine fades them with. The engine pauses only a whole sound world. The main menu and the ship play their music in worlds of their own, so they pause for real; anywhere else a pause is silence, and the track keeps its time.

- `api.music.TRACKS`: Every music event the game's scripts start, menus first. A sound bank holds only some of them, so tracks() says which ones the current screen has.
- `api.music.PACKAGES`: The package that holds each menu track's sound bank. A screen without the bank can load it: a mission has none of them. Once loaded a package stays until the game unloads it, at the ship or the menu that loads it too (abstract_base_state.lua:57).
- `api.music.tracks()`: The music events this screen can play now.
- `api.music.now()`: What plays: place ("menu", "ship", "mission" or "screen", nil where there's no music), track (the held one, nil while the game picks or while silence is held), held (true while either is), paused, and loading (true while a held track waits for its package).
- `api.music.play(track, opts)`: Plays a music event in place of the game's and holds it, on this screen and the next, until release(). It loops. A screen without the track is silent, except for the menu tracks of PACKAGES: those load their package first, in the background, and start once it's there, silent meanwhile (the answer is then true, "loading"). opts.db: the track's own volume in decibels, 0 as mixed, down to -60.
- `api.music.stop()`: Holds silence: the game's music stops until release().
- `api.music.release()`: Gives the music back to the game.
- `api.music.pause()`
- `api.music.resume()`
- `api.music.volume(db)`: The music's volume in decibels, 0 as mixed and -60 silent; nil or false gives it back.

### api.player

The local player: staying alive, moving, getting around, looking the part. Avatar health and status belong to the avatar's owner, so all of this works as a client too.

- `api.player.set_outline(r, g, b)`
- `api.player.clear_status(name)`: The game indexes its template table with this name outside any pcall, so an unknown one is refused. name: a status template or an element such as "fire".
- `api.player.immune(name, on)`: name as in clear_status. Stays on across respawns, until on is false.
- `api.player.knockdown()`
- `api.player.drop_carried()`: Drops what the player carries, such as a hard drive.
- `api.player.heal_by(amount)`: Adds hitpoints, past the maximum if asked to: the game doesn't stop it here.
- `api.player.set_health(hitpoints)`
- `api.player.heal(unit)`
- `api.player.revive()`: Downed players get up with a heal. A dead avatar has no way back but a respawn.
- `api.player.respawn()`
- `api.player.heal_everyone()`: Helping teammates goes through the owner, with the game's own requests.
- `api.player.revive_everyone()`
- `api.player.damage(unit, power, opts)`: A hit on any Helldiver, a teammate on another machine included, which lands on the machine that plays the body a moment later. unit: any player's body. power: as a hit's, 0 to 10000. opts.through_armor: no armor stops it. opts.statuses: status templates that go with it. opts.owner: the unit the hit comes from, such as an enemy, for this machine's own players. Answers true once the hit is landed or on its way.
- `api.player.lives()`
- `api.player.set_lives(n)`: Only through the game's setter: the value is under the tamper check. Lives count only alone.
- `api.player.teleport`
- `api.player.teleport_cursor()`
- `api.player.teleport_ahead(metres)`
- `api.player.teleport_spawn()`
- `api.player.teleport_objective()`
- `api.player.teleport_extraction()`
- `api.player.unstick()`: Back on the map from wherever the player got stuck.
- `api.player.set_cosmetic(slot, index)`: slot: helmet, body or cape, with an index from catalog.cosmetics. Comes back on respawn.
- `api.player.taunt()`

### api.progress

The player's own save: unlocks, upgrades and samples. Obsidian leaves personal progression alone, with two exceptions kept here on purpose. There is no way to change XP or rank: the total stays in the save and goes up with the next ordinary leaderboard upload, after any purge. And there's no way to get paid content: everything that lists items goes through the DLC check.

- `api.progress.samples()`
- `api.progress.max_samples()`
- `api.progress.set_samples(n)`
- `api.progress.unlock_items()`: Adds every item that isn't paid content, without touching XP. Merges, never replaces.
- `api.progress.upgrade_all()`: Upgrades of paid items stay in the map but do nothing: those items stay locked.
- `api.progress.loadout()`: The set the next spawn uses: { perk, primary_weapon, sidearm_weapon, stratagems }, by name.
- `api.progress.set_loadout(t)`: t: any of those keys. stratagems maps the free slots, 1 to 4 after the four every player has, to names. It's in the save at once and applies at the next spawn. The Loadout screen starts from the first preset, so that goes along with it, and paid or unknown items go back to the default, as the game does when it reads a save. The save can't get an item the player hasn't unlocked past that screen.
- `api.progress.upgrades()`
- `api.progress.upgrade_limit(name)`: The highest value set_upgrade takes for an item, nil for one with no upgrades.
- `api.progress.set_upgrade(name, value)`: name: a weapon or stratagem. value: its upgrades as the game keeps them, a bit each for a weapon, a level for a stratagem, from 0 to the item's most. Upgrades of paid items the player doesn't own would do nothing, so they're refused here.
- `api.progress.rank()`
- `api.progress.owned_cosmetics(slot)`

### api.stratagems

Stratagems: cooldowns, uses, call-in time and getting one without the arrows.

- `api.stratagems.select(id)`: id: the index in LoadoutSettings.stratagems.
- `api.stratagems.reset_cooldowns()`
- `api.stratagems.refill_uses()`
- `api.stratagems.give(name, unit)`: Adds a stratagem to the eight slots, or gives a use back when the player has it.
- `api.stratagems.edit(name, field, value)`: A field of a stratagem, at every upgrade level. Levels can set the field for themselves, and the game applies them over the base, so an edit of the base alone would stop at the first of those.
- `api.stratagems.call(name, pos, delay, unit)`: A real call-in at a position, delay seconds on top of its own, at the level the player owns. No cooldown or use is spent. unit: whose call-in it is, a player on this machine, the main one by default.
- `api.stratagems.drop(name, pos)`: Sends a stratagem to a position with no flare and no call-in.
- `api.stratagems.define(def)`: Makes a custom stratagem. def: name         its key, letters, digits and _ ("mymod_pitchfork"); must be new base         a stratagem of the game's: copied, and what other players see title        its name: a string, or { en = ..., fr = ..., es = ..., ["pt-BR"] = ... } description  words under it; the base's if nil code         the arrows, { "down", "left", "up", ... }, 1 to 10; the base's if nil icon         an icon the HUD has, as a stratagem's icon field; the base's if nil icon_material  with icon: a material the mod ships in the boot bundle, whose sub-material icon is. Every gui listing hud/hud lists it too. The base's icon when the deploy hasn't got it type         "supply", "offensive", "defensive" or "special"; subtypes, a list as the game's unit         what it calls down: a unit every game has; the base's if nil stats        fields of the entry: num_uses, cooldown_time, activation_time, despawn_time, ... attributes   the bars the Loadout screen shows, as the game's attr_ fields upgrades     its levels, Mk2 and on: { title, description, cost, stats, attributes, upgrade_attributes, icon }; the base's, renamed, if nil on_activate  function(ctx) on the thrower's machine when it's called down. ctx: name, position (the game's vector, good for this frame: copy it to keep it), owner (the thrower's unit), upgrade. Answer false to drop nothing. unlock       "base" (with its base, as when nil), "free" (from the start), { rank = n } (from rank n) or "manual" (once api.stratagems.unlock(name) is called) Answers { name, id }, or nil and a reason. Before the game has its stratagem list, as in a mod's main chunk, it answers { name, pending = true } and makes the stratagem once the list is there, before the save's loadout is read. A pending one that can't be made then is logged. The Arsenal and the Loadout screen list a custom stratagem right after its base.
- `api.stratagems.custom()`: The custom stratagems made so far: { name, base, id }.
- `api.stratagems.unlock(name)`: Opens a custom stratagem, kept for the next launch: the Loadout screen offers it from now on, whatever its unlock says. For a mod's own progression, such as a mission done or a goal reached.
- `api.stratagems.lock(name)`: Takes back what unlock(name) gave. A "free" stratagem or one opened by rank stays open.
- `api.stratagems.is_unlocked(name)`: Whether the Loadout screen offers a custom stratagem to this player now: by its unlock, or its base.

### api.ui

Messages and map marks, through the game's own HUD.

- `api.ui.hint(text, seconds)`: text: a hint name from HintSettings, or words to show. seconds: nil for the game's 7. It shows with the game's hints turned off too.
- `api.ui.open(name, opts)`: A menu of the ship by name, as a terminal opens it: "armory", "encyclopedia", "training", "main", "loadout" and so on. A menu reads the player who opened it, and Loadout and the briefing read the mission, so opts.seed gives them one. opts.pad is a pad number, nil for the main player's.
- `api.ui.close()`: Closes the top menu.
- `api.ui.menus()`: The name of every menu this state can open.
- `api.ui.ping(pos)`: The player's map mark at a world position, or off with nil. Every player sees it.
- `api.ui.with_texts(texts, fn, ...)`: Runs fn with some of the game's text keys showing other words, as LocalizationManager gives them: texts is { key = words }. Only while fn runs, so a screen of the game can be reused with a mod's words and nothing else changes. Answers what fn answers; an error in fn is raised again after.

### api.vehicles

The vehicle under the player. Driving makes a vehicle this peer's, a moment after getting in, so these effects wait for that, and each one takes back what it changed when the player gets out. Speed goes through the mover's multiplier, as the player's own speed does. The mover's speed itself is under the tamper check.

- `api.vehicles.current()`
- `api.vehicles.driven()`: The vehicle this player is driving, once it's theirs.
- `api.vehicles.driving()`
- `api.vehicles.repair`
- `api.vehicles.refill`
- `api.vehicles.seat_settings(v, index)`: The settings of one seat of a vehicle (seat_info), or nil.
- `api.vehicles.kind(v)`: What a vehicle is: "exosuit", "apc", "bike", "tank" (the tank destroyer, driven a track on each stick), or "turret" (a mannable turret). nil for a unit with no seats.
- `api.vehicles.seats(v)`: The seats of a vehicle in the game's order: { index, name, drives, unit, free, weapons } each. drives is true for the seat that steers, unit is who sits there (nil for nobody), free is true for an empty seat the game lets someone into, and weapons lists the guns that seat fires: { unit, trigger } each, where trigger is "primary" (the fire button) or "secondary" (the second trigger: the tank's machine gun, an exosuit's left arm, the first exosuit's grenades). {} for a unit with no seats.
- `api.vehicles.seat_of(unit)`: The vehicle a Helldiver sits in and the seat's index, or nil. unit: the player's when nil.
- `api.vehicles.near(pos, radius)`: Vehicles, exosuits and mannable turrets within radius (10 metres) of a position, or of the player, nearest first. A destroyed one isn't listed.
- `api.vehicles.nearest(pos, radius)`: The vehicle nearest to a position within radius (4 metres), and how far it is: the one under the cursor with api.world.cursor(). nil when there's none.

### api.world

Time, camera, HUD, the look of the world, and finding a place in it. The camera and the look are this player's alone: nobody else sees them.

- `api.world.camera.defaults()`: The camera the game set on this screen, before any effect changed it: { fov, distance, angle }, the field of view and the angle in degrees, the distance in metres. A mission starts at 60, 17 and 65; the ship has its own.
- `api.world.camera.spectate(unit)`: unit: another player's avatar, from game.all_avatars. nil comes back to this player.
- `api.world.camera.photo(on)`: Freezes the camera and clears the screen. In a mission or on the ship.
- `api.world.camera.place(pos, rotation)`: Where the frozen camera sits. pos is a Vector3, rotation a Quaternion, nil to leave it.
- `api.world.SHADING`
- `api.world.shading(name, kind, value)`: A value of the look of the mission. kind: scalar, vector2 or vector3. value: a number, or a list of 2 or 3. nil gives it back to the planet. It goes on again in each new mission.
- `api.world.flash(seconds)`: A lightning flash. Only forest planets have the setting it fades to, and not the illuminates' ones (campaign.md 4.4). A name the resource lacks is left to no chance, so it's refused.
- `api.world.cursor()`: The point of the level under the mouse: the ray from the camera through the cursor, or where that ray meets the ground plane when it hits nothing.
- `api.world.to_screen(pos)`: Where a point of the level is on the screen: pixels from the bottom left, as kits draw without a frame, and whether it's in view. pos: a vector or { x, y, z }.
- `api.world.ahead(metres)`: A position some metres in front of the avatar.
- `api.world.raycast(from, to, filter)`: The first thing on the straight line from one point to another: true, where and how far along, or false. filter: the game's collision filter, "default" when left out; "mover_blocker" is what stops a body walking, the one to ask before moving a player. from, to: vectors or { x, y, z }.
- `api.world.prop(unit_name, pos, opts)`
- `prop:alive()`: false once its level is gone, or it was removed.
- `prop:move(pos)`: Moves it, at once even in a stopped world.
- `prop:scale(size)`
- `prop:flow(event)`: Runs one of the unit's own flow events, the way the game makes a unit play its sounds and effects: "on_picked_up" on a research sample plays the pickup.
- `prop:remove()`
- `api.world.explode(pos, power, radius)`: An explosion at a position. The game's own manager does the damage and the push.
- `api.world.blast(pos, path, opts)`: An explosion at a position with the look, sound and damage of an item's own: a grenade, the plasma rifle's shot, a rocket. path: the item's unit, which has explosive_info in its settings, one of equipment/* (every mission loads those). It goes through the game's manager as this player's. opts.scale: its power times this, 0 to 10 (1 when left out); opts.spare_players: no damage to Helldivers (the push still reaches them). Only this machine sets it off: the damage reaches every machine's units as the player's own hits do, and the look shows here.
- `api.world.shoot(from, to, opts)`: A shot from one point toward another, as a weapon's ray goes: the first thing it meets, up to opts.range metres (the distance to `to` when left out, 200 at most). opts.power: damage to an enemy it hits (api.enemies.damage, so never a player); opts.explosion: an item's unit path, for its explosion where the shot lands (M.blast), as the plasma weapons and rockets do; opts.spare_players: the shot passes through Helldivers, and the explosion spares them. true, where it landed { x, y, z } and the unit it hit (nil for the ground), or false and a reason.
- `api.world.EFFECTS`: The effects a mod may draw, by name. Each is in mission_common, which every mission loads: a particle effect that isn't loaded crashes the game. arc and tesla are bolts, drawn from one point to another (the arc weapons' lightning, and the Tesla Tower's); shock and enemy_shock are the crackle the game shows on a shocked Helldiver and a shocked enemy, which run until taken off.
- `api.world.MAX_ARC_POINTS`: The longest path one arc() draws.
- `api.world.arc(points, opts)`: A bolt along a path, from each point to the next, as the arc weapons draw theirs. Only this player sees it, and it does no damage. points: 2 to MAX_ARC_POINTS vectors or { x, y, z }. opts.effect: "arc" (the default) or "tesla"; opts.size: the bolt's thickness, 0.1 to 5, 1 when left out.
- `api.world.attach_effect(unit, effect, node)`: Puts a running effect on a unit, following it, as the game puts the shock crackle on a body: on the unit's `node` ("boss", the body's centre, when it has one, else the root). Only this player sees it. effect: "shock", "enemy_shock", "fire", "poison", "confuse" or "stun". A handle for detach_effect, or false and a reason.
- `api.world.detach_effect(handle)`: Takes an effect from attach_effect off. With its unit or its mission gone, the game has already removed it, and the handle is only forgotten.
- `api.world.clear_decals()`
- `api.world.camera.forward(yaw, pitch)`: The way a yaw and a pitch look, as { x, y, z }.
- `api.world.camera.get()`: Where the camera is now, as set() takes it: { position, yaw, pitch, roll, fov }. Roll reads 0.
- `api.world.camera.take()`: Takes the camera where it is: the game stops moving it, and it goes where set() puts it, every frame, until release() or a change of screen. This player's only, in a mission. Poses are plain numbers, kept from frame to frame (the engine's vectors last a frame): position { x, y, z } in metres, and angles in degrees. yaw turns about the up axis, 0 looking along +y, the level's north, and grows turning left seen from above; pitch looks up when positive and down when negative; roll tips the picture. fov is the vertical field of view. ortho, a width in metres, draws without perspective, as a plan does; far is how far the camera sees, in metres. In a mission or on the ship. Answers true, or false and why not.
- `api.world.camera.set(pose)`: Where the taken camera goes. pose: any of position, yaw, pitch, roll, fov (from 5 to 150), ortho (false or nil for perspective) and far, as get() answers them.
- `api.world.camera.taken()`: Whether a mod has the camera.
- `api.world.camera.release()`: Gives the camera back to the game, which goes on from where it left it.
- `api.world.LIGHT_UNIT`: The unit a light is made of, a beacon flare in every mission's packages, and the name of its light.
- `api.world.LIGHT_NAME`
- `api.world.light(pos, opts)`: A light in the level that only this player sees: a beacon flare, hidden, with no physics, and its light taken over. pos: { x, y, z } or a vector. opts: color { r, g, b } from 0 to 1, intensity, range (metres the light reaches), shadows (true casts them), spot (an angle in degrees makes it a spotlight, nil an all-round light) with yaw and pitch for where a spotlight points. Answers a light with :set(opts), :move(pos), :alive() and :remove(), or nil and a reason.
- `light:alive()`
- `light:set(opts)`: Changes any of the light's opts, as M.light takes them.
- `light:settle()`: The unit's scene node at once, as a stopped world doesn't move it. move() and set() do it themselves.
- `light:move(pos)`
- `light:remove()`
- `api.world.time_scale(scale, opts)`: How fast this player's game runs: 0 stops it, 1 is normal speed, anything between is slow motion. Only with nobody else in the lobby, as another player's game would part from this one. A change of screen sets it back to 1. opts.lobby: slow or stop time with other players in the lobby too. The game's time scale is only this machine's (it sets GAME_DT; the network and the game's update still run), so a mod passing it must do the same on every machine at once, or the machines drift apart while it holds.
- `api.world.time_now()`: 1 unless time_scale changed it.
- `api.world.AVATAR_PARTS`: What a Helldiver is drawn with. The avatar's own unit is never drawn (customization_component.lua:34): the armour, helmet, cape and boots are units of their own, linked to it, and so are the weapons and the backpack it carries (equipment_component.lua:94).
- `api.world.parts_of(unit)`: The unit and every unit linked to it that draws as part of it: children, and for a Helldiver the armour parts and what it carries.
- `api.world.SHRUNK`
- `api.world.cape_of(unit)`: A Helldiver's cape: cloth, which doesn't follow a change of size, so it's hidden on its own.
- `api.world.visible(unit, on)`: Whether a unit is drawn, on this machine only: false hides it, shadow and all. Nothing else about it changes. A Helldiver hides whole, armour and what it carries too, by shrinking to nothing and growing back to the size it had: making a unit visible again would also show the meshes the game keeps hidden, such as the stratagem radio. Its cape is cloth and hides on its own.
- `api.world.hidden(unit)`: Whether visible() has a Helldiver hidden.
- `api.world.detail(multiplier)`
- `api.world.planet_shading(name)`: A value of the planet's look as the mission set it, before any change through shading(): a number, or a list of 2 or 3. nil where it can't be read.
- `api.world.sun()`: Which way the sunlight comes from in this player's view, as a unit vector pointing at the sun, or nil where there's no sun to read: a sun_direction set through shading() first, else the planet's.
- `api.world.time_of_day(name, towards, blend)`: The time of day of the mission's look: "dawn", "day", "dusk" or "night", or nil for the mission's own. blend, from 0 to 1, mixes in a second one, `towards`: dusk part way to night, say. Forest planets also have "swamp", "swamp_dawn", "swamp_day", "swamp_dusk" and "swamp_night". This player's only.
- `api.world.HELLDIVER_PARTS`: From main.lua, once a frame: what a change of screen gives back. The parts of a Helldiver that show or hide on their own, by name: the armour pieces the customization state holds, the weapon in hand, the other weapons carried, and equipment that isn't a weapon (a backpack). body is the whole figure under the armour.
- `api.world.part_units(unit, part)`: The units of one part of a Helldiver (a name of HELLDIVER_PARTS), with what's linked to them, such as a weapon's sights. Empty when the Helldiver has none.
- `api.world.part_visible(unit, part, on)`: Shows or hides one part of a Helldiver, on this machine only. It hides mesh by mesh and gives each mesh back as it was, so meshes the game keeps hidden stay hidden; a part hangs on a node of the Helldiver, so the size of the part can't hide it. Answers false and "no_target" when the Helldiver has none.
- `api.world.part_hidden(unit, part)`: Whether part_visible has a part of a Helldiver hidden.
- `api.world.placement(unit)`: Where a Helldiver stands and the way it faces, in degrees (the character's rotation_angle).
- `api.world.place(unit, pos, angle, floor)`: Puts a Helldiver at pos facing `angle` degrees (nil keeps the way it faces), on this machine only, in a stopped game too. Every frame the game puts a Helldiver at the mover component's position and turns it to the character's rotation_angle (character_component.lua:1000), so both the master and the slave states change, as the game's own teleport changes them (mover_component.lua). The physics mover goes along, never below `floor` (a height; nil for none): a mover under the ground falls out of the level, and the game removes what falls out. The Helldiver itself goes as low as asked. A running game carries on from the mover.
- `api.world.POSE_EXITS`: Poses that hold until the game ends them, and how each is left; every pose is then cleared with no_animation_fullbody, which ends what a full-body animation left (at_ease has no way out of the pose).
- `api.world.POSE_CLEAR`
- `api.world.end_pose(unit)`: Ends the pose pose() sent last to a Helldiver. Answers whether there was one. A stopped game shows the change once it runs for a moment.
- `api.world.pose(unit, event)`: Sends one of a Helldiver's animation events as a pose, on this machine only, after ending the pose sent before it, so poses don't pile up. Answers false and "no_event" when the unit hasn't that event. A stopped game plays it once it runs for a moment.
- `api.world.flashlight(unit, on)`: A Helldiver's flashlight, on this machine only, as the game lights it on a night mission. Only the night armour carries one (a light in the armour's units): anywhere else this answers false and "no_flashlight".

### Effects

Every effect id, for `api.effects.set(id, value)`, with the module that defines it. A trailing `_` takes a name after it: `bus_music`, `shading_exposure`, `immune_fire`.

- `acceleration` (player)
- `any_arrow` (stratagems): Any first arrow calls the chosen stratagem. The hook in main.lua reads selected. A bot's code is left alone: the choice is the player's.
- `armor` (player)
- `auto_respawn` (player): A few seconds after this player dies, the game's own respawn countdown runs out and drops them at the respawn point, with or without reinforcements left, alone or with others. It waits for the first drop, leaves a respawn the game has already started alone, and stops once the player extracts. value: true for 3 seconds, or the seconds before the drop.
- `blind` (enemies)
- `camera_angle` (world)
- `camera_distance` (world)
- `camera_fov` (world): The manager is one table that each state sets up again, so these go back on after a change of state. A spin of -45 is what a mission starts with (state_game.lua:196).
- `camera_spectate` (world)
- `camera_spin` (world)
- `damage_to_enemies` (combat)
- `damage_to_players` (combat)
- `deceleration` (player)
- `detail` (world): How far the engine keeps the most detailed models, as a multiple of the game's own (lod_object_ multiplier, a renderer setting). A camera further out than the game's own would see units drop their models, and some vanish. nil gives the game's back. This player's only, and back at a change of screen.
- `enemy_cap` (enemies)
- `exposure` (world)
- `fast_extract` (mission)
- `fast_mission_start` (mission): Skips the minimum load time before a drop. Applied through the hook in main.lua.
- `fast_pods` (stratagems): Hellpods drop only while their timer is above zero, so the shortest wait is a tiny one.
- `free_camera_bounds` (world)
- `free_stratagems` (stratagems): The inventory's own flag: no cooldowns, no uses spent, no grenades spent.
- `freeze` (enemies)
- `god` (player): god: the flags stop ordinary damage, and the frame function catches what goes around them, such as a seat destroyed under the player, which sets hitpoints directly.
- `gravity` (world)
- `heavy_armor_look` (player): The look only, in missions: armor values are the armor effect's. A player with the perk keeps it on the way out.
- `hidden` (player)
- `hide_hud` (world)
- `hide_model` (player): Getting out of a seat shows the model again, so the frame function looks.
- `host_owns_enemies` (enemies): Keeps every new enemy on the host, so edits made there reach all of them.
- `ignore_jammers` (stratagems): The game's one question about a no-stratagem zone. The hook in main.lua answers it, and the session gate turns the hook off, so there's nothing to undo here.
- `ignore_slow` (player)
- `infinite_ammo` (gear): Every weapon this machine runs, the bots' included.
- `infinite_respawns` (mission): Lives count only when alone, as in the game.
- `infinite_stamina` (player): The stamina value is a plain field. The command only freezes it, so it's filled as well.
- `instant_call_in` (stratagems): The flare's flag gives a 0.01 s call-in. Never 0: at 0 the game cancels the stratagem.
- `instant_reload` (gear): The reload timer is under the tamper check, so it's shortened through the game's setter, once per reload. Other weapon kinds read their reload time from the settings (see edits).
- `mutator` (mission)
- `mute_music` (world): Boot rewrites the music volume each frame, so it's set again after that.
- `no_camera_shake` (world): Checked inside the hook on add_shake in main.lua, since shakes aren't state to set or clear.
- `no_cooldown` (stratagems)
- `no_dof` (world)
- `no_fog` (world)
- `no_game_over` (mission): A wipe doesn't end the mission, so everyone gets to respawn.
- `no_screen_leash` (player): Off, the camera stops holding the player inside the screen.
- `no_spawns` (enemies)
- `no_status` (player)
- `noclip` (player): The way a vehicle seat works: with no physics mover, the position is written directly.
- `outline_color` (player): The outline a player shows through walls. value: { r, g, b }.
- `pause` (world)
- `photo_mode` (world)
- `protect_objectives` (mission)
- `regen` (player)
- `shield` (player)
- `show_patrols` (world)
- `skip_waits` (mission)
- `speed` (player): A multiplier the mover reads for every state, unlike the speeds in the settings.
- `sprint_speed` (player)
- `test_info` (world)
- `throw_range` (player)
- `time_of_day` (world): dawn, day, dusk, night, as the shading environments of the planets name them.
- `time_scale` (world): Time. Host speed changes everyone's game; a client's only its own simulation.
