# Changelog

New, changed or removed capabilities, one line each, brief and direct. A release's section becomes its release notes.

## 1.48.0

- New: `api.world.pickups` lists the weapons, backpacks and ammo lying on the ground and `api.world.remove_pickup` deletes one for every machine through the game's own destruction. The owner removes at once, the host asks the owner, any other client is refused.
- New: effects `aim_move_speed` and `reload_move_speed` set how fast the player moves while aiming or reloading, and let a weapon that holds the player in place be walked with.
- Fixed: a bot holds the aim for a moment before the first shot of a weapon, longer and until the barrel is level with a heavy weapon, so a recoilless rifle no longer fires at the ground.
- Fixed: `bot:deliver` drops the thing once the game counts the drop-off as near and the bot can get no closer, and walks to a spot beside a collection point it cannot enter.
- Fixed: a game function's nil results survive the API's hooks, so a hooked function that answers nil still answers nil.
- Changed: manual stratagem unlocks stay in `obsidian.storage` on a loader without `obsidian.save_data`.

## 1.47.0

- Changed: manual unlocks of custom stratagems (`api.stratagems.unlock`) go with the save through `obsidian.save_data`. Unlocks kept before this move to the Official save only.

## 1.46.0

- New: bare bots show the game's off-screen arrow, on every machine; the HUD card stays away.
- New: `bot:add_ammo` adds magazines or rounds through the game's own command.
- New: `api.brain` `engages` and `burst`; a "threat" fight leaves far enemies that haven't noticed the squad alone, holds fire on anything behind cover and fires automatic rifles in short bursts.
- Changed: navigating bots keep a body-width off pit rims, stand rather than walk on with no route, look further ahead with speed, are checked last of every walk source, and return to the last solid spot when knocked over an edge.
- Changed: a bot whose follow spot is across a pit or a long way round takes a spot on the near side of the leader.

## 1.45.0

- New: `api.nav` finds walking routes around walls, pits, lava, deep water and danger zones with rays over a grid: `path`, `walkable`, `walk_clear`, `zones`, `available`, `search_grid`.
- New: `api.brain`, the pure decisions bots use: weapon choice by threat, target commitment, aim window, blast and line-of-fire checks, formation spots, sprinting, grenades.
- New: `bot:navigate` routes and guards a bot's walking; `bot:movement` adds smooth turning, spacing, varied spots, strafing and sprinting to catch up; `bot:auto_grenades` throws grenades by rule.
- New: `fight` weapon "threat" saves support and heavy weapons for what deserves them, commits to one target, and never fires a blast that would catch a friend.
- New: `api.gear.blast` gives the blast radius of what a weapon fires; `api.enemies.tentacles` lists the Impaler's tentacles, and they count in `api.bots.hazards` and `avoid_shots`'s close attacks.
- Changed: bare bots start out of the camera's framing and the screen leash, and can spawn off the screen.

## 1.40.0

- New: `api.stratagems.hide(name)` takes a game stratagem out of the Arsenal, the Loadout screen, the default and saved loadouts and the mission inventory; `unhide` and `is_hidden` go with it.
- New: `api.stratagems.carry(name)` gives every player a stratagem as an extra entry in missions, beyond the 8 loadout slots, and other players' HUDs show it; `uncarry` and `is_carried` go with it.
- New: `api.stratagems.share_cooldown(name)` puts the whole squad on one cooldown for a stratagem; `unshare_cooldown` and `is_shared` go with it.
- Changed: when several stratagems share an arrow code, the one the player holds and can use wins.
- Changed: the Loadout screen filters and orders the lists the game reads, so a custom stratagem sits beside the base there too.

## 1.39.1

- Changed: the label of the F6 key says "Open in-game menu" in French, Spanish, Portuguese and Chinese too, as in English since 1.36.2.

## 1.39.0

- New: `bot:operate(unit, opts, on_done)` works a terminal to the end: objective terminals, the extraction beacon and hidden objects. Arrows go in one frame each, checked before the next, and presses come at a set rate. `bot:operating()` and `bot:cancel_operate()` go with it.
- New: `bot:deliver(unit, pos, opts, on_done)` carries a thing an objective asks for to the drop-off and puts it down there. `bot:delivering()` goes with it.
- New: `api.mission.drop_offs(thing)` lists where carried things count as delivered.
- New: `bot:load(unit, opts, on_done)` loads a teammate's recoilless rifle or missile launcher from the bot's backpack.
- New: `bot:take_ammo(unit, opts, on_done)` takes ammo from a teammate's ammo backpack, or from the bot's own.
- New: `api.bots.dead()` lists the players the next reinforcement brings back, and `bot:reinforce(pos, on_done)` calls it.
- New: `api.mission.extraction()` reads the beacon and the shuttle, `api.mission.aboard(unit)` says who got in, and `bot:board(opts, on_done)` walks a bot into the shuttle. A bare bot aboard leaves the level.
- New: `bot:detonate()` sets off the satchel charges the bot threw, and `bot:charges_out()` counts them.
- New: `api.bots.hazards(pos, radius, kinds)` lists mines, burning areas and armed hellbombs near a point.
- New: `api.mission.areas()` lists the hold and fortify areas with their radius and progress.
- New: `bot:camera(false)`, or `api.bots.add({ free_camera = true })`, takes a player bot out of the camera's framing and the screen's edge, so it walks anywhere on the map. `bot:in_camera()` goes with it.
- New: `use_weapon` takes `move`, to keep walking on the bot's orders while it fires, and `rest`, seconds the weapon stays put away afterwards. `bot:resting(slot)` says how long.
- New: `bot:use` takes `force`, to have the game use the thing with no wait for the game to offer it.
- Changed: a bot sent to use something stops a little short when the thing's own body keeps it from getting closer, as with the extraction beacon.

## 1.38.1

- Changed: a fighting bot fires only once it faces the target and has held on it a moment, so a shot doesn't leave on the way round, where a teammate may stand.
- Changed: in a mech, the bot lines up the gun on the mech's arm with the target, not the mech's middle.
- Changed: a driving bot eases off near the point it drives to and stops within 4 meters of it, or when the point ends up close behind, instead of circling it.
- Changed: a dead body in the way no longer stops a bot's shot.
- Changed: `bot:use` takes out the primary when the game offers the bot a reload of the bot's own first (an empty recoilless with the recoilless backpack), so the thing it was sent to use comes through.
- Changed: a new `fight` order looks for a target at once.
- Changed: `bot:use_weapon` reloads an empty launcher that the bot's backpack reloads before taking back the weapon from before, so the reload plays and the launcher comes out loaded next time.
- Fixed: with `freeze` on, a killed enemy falls and despawns while the rest stay frozen.
- Fixed: effects no longer log an error each time they're switched on outside a mission.

## 1.38.0

- New: `bot:hurts(target, slot)` and `api.gear.hurts(weapon, target)` answer the damage one hit does to a target after armor: square, glancing and on the weak spot, launchers included. An enemy the rifle gets 0 against is one for the anti-tank weapon.
- New: `api.enemies.charging(unit)` reads an enemy about to shoot (the Hunter's beam, the Cyborg IFV's laser sight, the Hulk's wind-up): when it fires and where the aim line runs.
- New: `bot:avoid_shots(true)` gets the bot out of that line, with a dive just before the shot. `bot:avoiding()` goes with it.
- New: `fight`'s `secondary` takes `only` and `every`.
- New: `bot:position()` answers where the bot stands.
- New: `bot:mech_friendly_fire(false)` keeps the mech a bot pilots from hurting Helldivers. Enemies still take the hits.
- Changed: a bot in an exosuit fires the rockets one each second, and only while it faces the target. Before, it emptied the rack at once.
- Changed: `bot:throw()` does nothing in a vehicle seat, where the button fires the vehicle's second weapon.
- Fixed: bots stand still while session mods are off. Before, each one kept the last buttons and sticks it was given, and the game went on reading those every frame.

## 1.37.0

- New: `bot:use(unit, opts, on_done)` uses a thing the way a player does: samples, ammo boxes, weapons and backpacks lying about, hellbombs, the first press on a terminal, things to carry, and a team reload on a teammate. `bot:using()` and `bot:cancel_use()` go with it.
- New: `api.bots.usables(pos, radius, kinds)` lists the things around a point that a Helldiver can use.
- New: `bot:carrying()` and `bot:drop()` for what the bot carries.
- New: `bot:say(word)` plays a voice line: yes, no, stay, move or a taunt.
- New: `bot:jump(dir, on_done)` jumps with a jump pack, and `bot:jumping()` says whether a jump is under way.
- Changed: `bot:stop_helping()` ends a help up or a heal only.

## 1.36.2

- Changed: the F6 key's label in the Keys tab reads **Open in-game menu**.

## 1.36.1

- New: `bot:wield(slot)` takes out the weapon in a chosen slot, and `bot:wielding()` answers the slot in hand. A bot that heals with the REP-80 takes back the weapon it held, with no swaps in between.
- New: `bot:use_weapon(slot, target, opts, on_done)` takes out one weapon, fires it at one target and takes back the weapon from before: an EAT or a recoilless rifle for a heavy enemy while the bot fights with the rifle. `bot:using_weapon()` and `bot:cancel_weapon()` go with it.
- New: `bot:fight(radius, opts)` takes `weapon` (the slot to fight with), `only` (a function that picks the enemies to shoot) and `secondary` (fire a vehicle seat's second gun too).
- New: `bot:sees(unit)` and `bot:enemies_in_sight(radius, only)` tell which enemies a straight line from the bot reaches. `api.enemies.info` gives `armor_min`, `armor_max` and `large`.
- New: bots get into vehicles: `bot:enter_vehicle(vehicle, seat, on_done)` walks to a seat's door and gets in, `bot:leave_vehicle()` gets out, and `bot:ride_along(true)` follows the player into the vehicle and out again. In a seat, `fight` works the seat's guns and walking orders drive. `bot:seat()`, `bot:boarding()` and `bot:fire_secondary(on)` go with them.
- New: `api.vehicles.near`, `nearest`, `kind`, `seats` and `seat_of` list vehicles, exosuits and turrets, and who sits where.
- New: `bot:auto_heal(radius, opts)` takes `below`, the share of health under which the bot starts healing someone (0.8). `retry` sets how long it waits before trying someone again, for `auto_revive` too.
- New: `bot:refill_backpack()`, and `api.gear.refill_backpack(unit)` for any player on this machine.
- Changed: a bot's launcher with an assisted reload, such as the recoilless rifle, reloads by itself while the bot wears the backpack for it.
- Changed: a fighting bot pulls and lets go of the trigger for a semi-automatic weapon, which fires once per pull.
- Fixed: `bot:switch()` held the switch button, which the game reads as a hold that swaps the sidearm and the support weapon back and forth. It now taps it.
- Changed: the F6 key's label in the Keys tab reads **Open in-game overlay menu**, and a manager that shows a controller column puts the **Open the menu with a controller** choice in the same row.

## 1.35.0

- New: `bot:throw_at(pos, on_done)` throws a grenade at a point as a player does: the bot faces it, charges the throw to the distance and lets go. `bot:throwing()` and `bot:cancel_throw()` go with it.
- Changed: a bot lets go of the trigger while it throws a grenade. Fire held during a throw sent the grenade at once at the bot's feet, and kept a fighting bot stuck in the throw afterwards.
- New: bots reload by themselves, an overheated laser's radiator included (the Sickle and the other heat weapons), with the trigger let go for a moment. `bot:auto_reload(false)` leaves reloads to `bot:reload()`.
- Fixed: `api.world.blast` with `spare_players` spared nobody. The explosion's hits come in a moment after the call, and are now filtered then too.

## 1.34.0

- Changed: no press or button of a bot outlasts the order, call or help that used it. A press of interact left held after a bot got up made the bot pick an item up, drop it and pick it up again without end, and broke into the get-up.
- Changed: a downed bot lies still instead of crawling where the orders lead, holds interact without extra presses, and waits while another bot comes to help it up. Left down for a teammate, it stops fighting from the ground once one stands close.
- Changed: of the bots that help by themselves, only the free one nearest to a downed or hurt Helldiver goes. `revive()` and `heal_target()` with no unit pick someone no other bot is helping, or answer `"already_helped"`.
- Changed: a bot changes weapons only standing calm. A heal walks into range before the REP-80 comes out, and the weapon held before comes back once the bot stands, never while downed or knocked down.
- Changed: on the way to help, a fighting bot shoots back at enemies within 10 metres, and presses interact on a downed body only once the game picks the body, never an item lying by it.
- Changed: `fight` holds fire while a Helldiver stands in the line of fire, picks an enemy a straight line reaches before one behind a wall, and reloads an empty magazine.
- Changed: a bot that walks into something and gets nowhere for a second steps aside and goes on.
- New: `bot:pickup_cooldown(seconds)` and `bot:next_pickup()`. After picking up a weapon or a backpack, a bot picks up neither for 20 seconds, so it can't swap the same two back and forth.

## 1.33.1

- New: `api.world.time_scale(scale, { lobby = true })` stops or slows the game with other players in the lobby too, for a mod that does the same on every machine at once.
- New: `api.player.damage(unit, power, opts)` damages any Helldiver, a teammate on another machine included: the hit goes to the machine that plays the body and lands there. `opts.through_armor`, `opts.statuses` and `opts.owner` shape the hit.
- New: `api.world.attach_effect` also takes `"fire"`, `"poison"`, `"confuse"` and `"stun"`, the look of the game's burn, poison, confusion and stun.
- New: bots get up from downed by themselves, pressing interact as a player does (`bot:auto_get_up(false)` leaves one down for a teammate).
- New: `bot:revive(unit)` walks a bot to a downed Helldiver and helps them up with interact, and `bot:heal_target(unit)` heals a hurt one with the REP-80's beam, then takes back the weapon the bot held. With no unit, each picks the nearest Helldiver who needs it. `bot:auto_revive(radius)` and `bot:auto_heal(radius)` do both by themselves while the bot follows or fights.
- New: the F6 window works with a controller. Both sticks pressed in open and close it, the D-pad or the left stick moves and changes values, A selects, B goes back, Y resets a row, and LB and RB switch pages. The guide at the foot shows the pad's buttons while a pad is in use, and the **Open the menu with a controller** option picks other buttons or none.
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
