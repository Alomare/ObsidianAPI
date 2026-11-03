# Changelog

New, changed or removed capabilities, one line each, brief and direct. A release's section becomes its release notes.

## 1.10.1

- Changed: a bot's gear and help (`give_weapon`, `heal`, `teleport`, `call` and the rest) work when another mod calls them. In 1.10.0 they answered an error, looking for the API's own files in that mod.
- Changed: `api.catalog.unlocked(name)` answers for a custom stratagem as for its base.

## 1.10.0

- New: `api.music` picks the soundtrack: the tracks a screen has, playing one in place of the game's music and holding it across screens, silence, pause and resume, volume, and giving the music back.
- New: `api.stratagems.define(def)` makes a custom stratagem from one of the game's: its own name, words, code, icon, type, numbers and upgrades, and a function that runs when it's called down. Other players see the base, and the ids on the wire are always the base's. `api.stratagems.custom()` lists them.
- New: bot orders `go_to(pos)`, `hold()` and `aim_at(pos)`, and `fighting()` and `firing()` to read them back.
- New: a bot's gear and help: `give_weapon`, `give_backpack`, `give_perk`, `remove_perk`, `refill`, `give_stratagem`, `call`, `heal`, `teleport` and `weapons`.
- Changed: `api.gear.give_weapon`, `give_backpack`, `give_perk` and `remove_perk`, and `api.player.teleport`, take an optional unit, for another player on this machine.
- Changed: `api.bots.add` answers `nil, "not_in_mission"` where the game can't spawn a bare Helldiver, instead of an error.

## 1.9.2

- Changed: the names `api.bots` draws over bare bots go when the HUD's do: under `hide_hud` and a mod's full-screen menu, they no longer show through.

## 1.9.1

- Changed: `api.stratagems.call` takes a plain `{ x, y, z }` position too. Before, it counted down and nothing landed.

## 1.9.0

- New: `api.gear.add_perk(name, unit)`, `remove_extra_perk(name, unit)` and `extra_perks(unit)` put perks on a player on top of the main one.

## 1.8.0

- New: `api.map` reads and steers the mission map: open or closed, opening and closing it, zoom, the view, every player's ping, and conversions to and from the map's units.
- New: `api.map.marker(pos, opts)` puts a mod's own marker on the map, at a position or following a unit.
- New: `api.bots.add(opts)` makes Helldivers this machine plays: local players on free pads with a HUD slot, then bare Helldivers past the player records, with their name over their head. They move, aim, shoot, reload, throw, follow and fight, and go before a mission's results.

## 1.7.1

- Changed: Steam achievements are no longer held back while Obsidian API is on.
- Changed: `api.mission.win`, `finish_objectives` and the `fast_extract` effect no longer stop the mission from adding to the save.
- Changed: the game's `upgrade_all` console command is allowed. Commands that unlock paid content or wipe a save or achievements stay refused.

## 1.7.0

- New: `api.gear.add_drone(path, unit, upgrade)` gives a player a drone pack's drones without taking their backpack slot. Every game running Obsidian API hides the station they fly from.
- Changed: `api.gear.tune(unit, "melee", changes)` tunes a weapon's melee attack: `power`, and `duration` and `delay` for how fast it swings.
- Changed: `api.stratagems.call(name, pos, delay, unit)` takes an optional unit, for another player on this machine: the call-in is theirs, at their upgrade level.

## 1.6.0

- New: `api.gear.weapons_of(owner)` lists the weapons a player holds.
- New: `api.gear.tune(unit, component, changes)` changes one weapon's stats and attributes without touching other weapons of its type.
- Changed: `api.gear.refill`, `api.gear.refill_grenades` and `api.player.heal` take an optional unit, for another player on this machine.
- Changed: `api.stratagems.give(name, unit)` gives to that one player, the main player by default, and no longer to every player on this machine.

## 1.5.1

- New: `prop:flow(event)` runs one of a prop's own flow events, such as a research sample's `on_picked_up`.
- Changed: the `freeze` effect keeps commands queued for frozen enemies intact, which stops a crash when enemies take damage while frozen and then resume.

## 1.5.0

- New: `api.lobby.share(name, value)` and `api.lobby.shared(name)` share short texts between machines.
- New: `api.world.to_screen(pos)` finds a point of the level on the screen.
- New: `api.world.prop(unit, pos, opts)` places a unit in the level on this machine only, with `move`, `scale` and `remove`.
- New: `api.ui.with_texts(texts, fn, ...)` runs a function with some of the game's text keys showing your words.
- Changed: `api.enemies.spawn(key, count, pos)` takes a position.
