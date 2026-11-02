# Changelog

New, changed or removed capabilities, one line each, brief and direct. A release's section becomes its release notes.

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
