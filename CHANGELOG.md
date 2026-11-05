# Changelog

New, changed or removed capabilities, one line each, brief and direct. A release's section becomes its release notes.

## 1.33.0 (unreleased)

- New: `api.world.time_scale(scale, { lobby = true })` stops or slows the game with other players in the lobby too, for a mod that does the same on every machine at once.
- Changed: in the F6 window, the mouse drags the edge of the page list to make the list wider or narrower, and the line over the help to give the help more or fewer lines. Both sizes stay within bounds that keep names, rows and help readable, and are remembered with the window's place.

## 1.32.0

- New: `api.world.blast(pos, path, opts)` sets off the explosion of an item from `equipment/*` (a grenade, the plasma rifle's shot, a rocket) with that item's own look, sound and damage, as this player's. `opts.scale` multiplies the power, and `opts.spare_players` keeps the damage off Helldivers.
- New: `api.world.shoot(from, to, opts)` fires a ray the way a weapon's shot goes and answers where it landed and what it hit. `opts.power` damages an enemy it hits, `opts.explosion` adds an item's explosion where it lands (the plasma weapons are shots with an explosion, not projectiles), and `opts.spare_players` lets the shot pass through Helldivers.

## 1.31.0

- New: `api.world.arc(points, opts)` draws a bolt along a path of points, using the arc weapons' lightning or, with `effect = "tesla"`, the Tesla Tower's. It does no damage and only this player sees it.
- New: `api.world.attach_effect(unit, effect, node)` puts the shock crackle (`"shock"` for a Helldiver, `"enemy_shock"` for an enemy) on a unit until `api.world.detach_effect(handle)` takes it off. It's only an effect: no status and no slow.
- New: `api.enemies.chain(pos, count, first, jump)` lists enemies the way an arc jumps: the nearest within `first` metres of a position, then the nearest new one within `jump` metres of the last.
- New: `api.world.EFFECTS` names the effects a mod may draw. Each one is in a package every mission loads.

## 1.30.0

- New: `api.mission.drop(choice)` starts a solo mission from the ship with chosen parts, as a real mission. XP, samples and unlocks count. The campaign is put back as it was at the drop, with no planet progress and no Galactic War or leaderboard report from the mission. `api.mission.practice` still starts a training mission that pays nothing.

## 1.29.2

- Changed: `panel:typing()` also answers `"number"` while a number is typed into a row, and `"text"` for other rows. A number entry takes no letters, so a mod can keep reading the letter keys.

## 1.29.1

- Changed: client mods can call `api.world.to_screen`, `api.world.placement`, `api.world.part_units` and `api.world.part_hidden`, which only read. They answered `false, "needs_session"` before, so Better HUD's enemy health bars, damage numbers and reload and ammo circles drew nothing unless a session mod was deployed and the lobby cleared.

## 1.29.0

- New: `api.world.place(unit, pos, angle, floor)` and `api.world.placement(unit)` move and turn a Helldiver in a stopped game, by the mover and character states the game places it from each frame. The physics mover stays above `floor`, so a Helldiver sunk into the ground doesn't fall out of the level.
- New: `api.world.pose(unit, event)` and `api.world.end_pose(unit)` play a Helldiver's animation event as a pose and end it, so held poses such as at_ease and radio_activate don't stay.
- New: `api.world.part_visible(unit, part, on)`, `api.world.part_hidden(unit, part)` and `api.world.part_units(unit, part)` hide one part of a Helldiver, such as the helmet or the weapon in hand, mesh by mesh.
- New: panels take `headings = true`, which shows the open tab's title over the tab's rows, with a reset button for a tab that has `reset`.
- Changed: `api.world.flashlight()` answers `false, "no_flashlight"` for a Helldiver without one. Only the night armour carries a flashlight.
- Changed: tab icons drawn from shapes have the hard edges of 1.27.0 again.

## 1.28.0

- Added: `api.world.detail(multiplier)` keeps the most detailed models farther from the camera, so a camera far from the game's own doesn't see units drop their models or vanish.
- Added: `api.world.planet_shading(name)` reads a value of the planet's look as the mission set it.
- Added: `api.world.cape_of(unit)` and `api.world.hidden(unit)`.
- Changed: `api.world.visible()` hides a Helldiver by shrinking it to nothing and gives back the size it had. Showing it no longer reveals meshes the game keeps hidden, such as the stratagem radio. The cape, which is cloth, hides on its own.
- Changed: tab icons drawn from shapes have softer edges.
- Fixed: screenshots with Windows display scaling above 100% came out as the top left of the frame, enlarged.
- Fixed: a pause menu row on the ship left the pause menu open.

## 1.27.0

- Added: `api.world.sun()`, the direction toward the sun in this player's view, from a set `sun_direction` or the planet's.
- Added: `api.world.parts_of(unit)`, the unit with every unit linked to it, and for a Helldiver the armour parts and what it carries.
- Added: a panel tab's icon can be shapes of the mod's own, convex polygons on a grid of 16, as the glyphs are made.
- Fixed: `api.world.visible()` hid nothing on a Helldiver, whose own unit is never drawn. It now hides the armour, helmet, cape, boots, weapons and backpack with it.
- Fixed: a light from `api.world.light()` stayed away from where it was placed until it was first moved, in a stopped game.

## 1.26.0

- Changed: `api.world.camera.take()` and `api.world.camera.photo()` work on the ship as well as in missions. The camera goes back to the state it had, the ship's own there.

## 1.25.0

- Changed: the `camera_fov`, `camera_distance` and `camera_angle` effects give back the camera the game set on the current screen when they come off. They gave back a mission's 60 degrees, 17 m and 65 degrees, which is wrong on the ship.
- New: `api.world.camera.defaults()` answers the game's own field of view, distance and angle for the current screen.

## 1.24.0

- New: a panel drags by the title bar, resizes from a corner grip and stays on screen. The place and size are kept for the next launch, per mod and `spec.id`.
- New: `spec.anchor` keeps a panel at a corner of the screen, `"bottom_right"` by default, 540 by 360 (`spec.width`, `spec.height`). `"right"` and `"left"` keep the full height down that side, and `side` still works.
- New: `panel:set_opacity(a)` sets the background's strength, 0.5 by default, and `panel:set_scale(s)` draws the whole panel from 0.6 to 1.6 times as big. Both are kept with the place.
- New: a tab's `icon` shows in place of the tab's title, which then shows over the help.
- New: `spec.buttons` adds buttons to a panel's title bar, left of the close button, which run as the mod.
- New: `panel:set_cursor_hidden(on)` hides the cursor and leaves the mouse to the mod while the panel stays drawn, for looking around with a held button.
- New: `panel:reset_place()` puts a panel back where it first opened.
- New: the F6 window and panels play the game's own menu sounds, quietly, for moving, changing a value, choosing and going back. `spec.sounds = false` turns them off for a panel.
- Changed: a panel's help has room for four lines, and players drag the line above the help for more or less.
- Changed: a new panel opens at the bottom right of the screen, three wide by two high, at half opacity.
- Removed: the shield in the title bars of the F6 window and panels.

## 1.23.0

- New: `api.world.camera.take()`, `set(pose)`, `get()` and `release()`: a mod holds the camera and places it every frame by position, yaw, pitch, roll and field of view, with or without perspective. Client mods, any lobby.
- New: `api.world.light(pos, opts)` puts a light in the level that only this player sees, all-round or a spotlight, with color, intensity, range and shadows.
- New: `api.world.time_scale(scale)` stops or slows this player's game, alone in the lobby only. A new screen sets it back.
- New: `api.world.time_of_day(name, towards, blend)` sets the mission's time of day, mixing two of them.
- New: `api.world.visible(unit, on)` hides or shows a unit, and `api.world.flashlight(unit, on)` lights a Helldiver's flashlight.
- New: `api.world.shading` takes 14 more names from the game's shaders: dust, cloud shadows, glow, reflections and the vignette's shape.
- New: `api.capture` saves the game's picture as a PNG or JPEG in the player's Pictures folder, with every mod's drawing held back, cut to an aspect ratio or a crop.
- New: `api.menu.panel(spec)`, a mod's own window with tabs down one side of the screen, which leaves W A S D, Q, E and the right mouse button to the mod.
- New: `page:slider(label, opts)`, a number on a bar the mouse drags. A choice can show a color swatch, and `format` can be a function.
- New: `api.mod_settings.pause_row(id, label, fn, opts)` adds a row to the pause menu under Mods, which closes the pause menu and runs `fn`.
- Changed: `api.music.play(track, opts)` loads the ship's and the main menu's music in a mission, and takes `opts.db` for the track's own level.

## 1.22.1

- Changed: a new image beside the mod in Obsidian's mod list.

## 1.22.0

- New: a custom stratagem's `icon_material` names a material the mod ships in the boot bundle, holding the sub-material `icon`. Every gui that lists `hud/hud` lists it too, the loader's included. Without that material in the deploy, the base's icon.
- Changed: the Arsenal and the Loadout screen list a custom stratagem right after its base, not at the end.

## 1.21.0

- New: `bot:use_stratagem(name, pos, on_done)` calls a stratagem from the bot's slots the way a player does: the stratagem button held, the code entered one arrow at a time, and the flare thrown at `pos`. Cooldowns and uses count.
- New: `bot:stratagems()` lists the stratagems a bot carries, with cooldowns and uses left. `bot:using_stratagem()` and `bot:cancel_stratagem()` read and stop a call.
- Changed: the `any_arrow` effect leaves a bot's code alone.

## 1.20.0

- Changed: `api.stratagems.define` called before the game has its stratagem list, as in a mod's main chunk, answers `{ name, pending = true }` and makes the stratagem before the save's loadout is read. It answered `not_ready` before, and a mod that stopped trying never got its stratagem.

## 1.19.0

- New: the mod's image, shown beside it in Obsidian's mod list.

## 1.18.0

- New: the `auto_respawn` effect drops a dead player back in after 3 seconds, or the seconds given, with no reinforcements left and with other players in the lobby.
- New: `api.mission.seed(choice)` makes a mission seed from chosen parts, for a mod that starts missions its own way.
- New: `api.mission.practice` takes a `look` (one of the three terrain sets, or the bug, cyborg or illuminate world on its own planet type) and a `layout` from 1 to 215. `api.mission.LOOKS` and `api.mission.LAYOUTS` list them.
- Changed: a practice mission picks its layout from all 215 a seed holds. It always drew the same one before.
- Changed: `api.mission.params()` also gives the mission's `layout`.

## 1.17.0

- Changed: an expansion's pages in the F6 window show before its content starts, as a client mod's do, since they are its way in. Its guarded calls still wait for the content (Obsidian 1.2.0).

## 1.16.0

- New: a Mods page row made with `option = true` is the mod's `obsidian.json` option with the same id. It starts from the value set in Obsidian, and a change in game goes back to Obsidian's mod details once the game closes. `api.mod_settings.BINDS` is `true` from this version on.
- New: page titles, labels, help lines and choice labels can be tables by language, shown in the game's language.
- Fixed: accented letters on Mods pages show as capitals, as the rest of the label.

## 1.15.0

- New: `api.menu`, the in-game window, moved here from Obsidian's loader so it changes with the API's releases. It takes the same calls and pages as `obsidian.menu`, which hands every call here on the next Obsidian.
- New: each mod's pages sit in a folder named after the mod, opened and closed with Enter or a click and kept that way for the next launch. The title bar names the mod whose page is open, and reads Obsidian on a folder.
- New: the F6 key that opens the window, in the Keys tab of Obsidian API, moved from Obsidian Trainer. It opens the window once a page is listed. On the next Obsidian it also works in a lobby that isn't cleared, so a client mod's pages are always at hand.
- New: `api.menu.toast(text, seconds)`, a short message beside the window.

## 1.14.0

- Changed: `api.combat.on_hit` works for client mods and in any lobby, and each hit carries the `position` where it landed.
- Changed: the pause menu row is **Mods**, in every language.

## 1.13.0

- New: `api.enemies.damage(unit, power, statuses, { through_armor = true })` deals a hit that no armor stops.

## 1.12.0

- New: `api.combat.on_hit(fn)` hears every hit this machine's players land, on any machine's enemies, with the damage and the weapon slot that fired.
- New: `api.combat.on_fatal(fn)` can spare a player of this machine from a hit that would kill them.
- New: `api.world.raycast(from, to, filter)` finds the first thing between two points.
- New: a custom stratagem's `unlock` can make it free from the start, open from a rank, or open when a mod calls `api.stratagems.unlock(name)`, kept outside the game's save. `lock(name)` and `is_unlocked(name)` go with it.

## 1.11.0

- New: `api.mod_settings.page(title)` gives a mod a page of settings in the pause menu's new **Mod Settings**: toggles, choices, numbers and buttons, drawn by the game's own Settings screen and kept for the next launch.

## 1.10.3

- Changed: the `heavy_armor_look` effect waits for a mission. Its model isn't loaded on the ship, and turning it on there crashed the game.

## 1.10.2

- New: `REFERENCE.md`, inside the API's folder: a guide to every part of the API, recipes, the rules that keep the game running, and every call and effect, generated from the source at each release.

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
