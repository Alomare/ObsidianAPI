# Obsidian API

A library for [Obsidian](https://github.com/Alomare/ObsidianModManager) mods on HELLDIVERS (2015). It gives other mods the game's data by name, checked changes that can be undone, and ready actions. It does nothing by itself. [Obsidian Trainer](https://github.com/Alomare/ObsidianTrainer) is built on it and uses nothing you can't use.

It has been tested solo and offline, but not yet with a second player.

## How to Use

Obsidian API comes with Obsidian, in the Obsidian Kit folder, and updates from this repository. Mods that need it switch it on with them, so players don't have to.

To build on it, list it in your mod's `obsidian.json`:

```json
"scope": "session",
"entry": "main.lua",
"requires": ["obsidian.api"]
```

Then ask for it in your script:

```lua
local api = obsidian.import("obsidian.api")

obsidian.keybind("panic", function()
  api.player.heal()
  api.enemies.kill_near(20)
end)
```

Actions answer `true`, or `false` and a short reason such as `"host_only"` or `"not_in_mission"`.

The API is a library: it runs as a session mod only when a session mod requires it. A client mod can require it too and stay a client mod. It can then read the game's data and use `api.ui`, `api.audio` and `api.events`, and anything that changes the shared game answers `false, "needs_session"`. The Obsidian API page in the app's Wiki covers the rest.

## Releasing

Set `version` in `obsidian.json`, commit, then push a tag with the same version:

```
git tag v1.0.1
git push origin v1.0.1
```

The Release workflow packs the mod into a `.zip` and publishes it, and Obsidian offers it as an update.

## License

[MIT](LICENSE)
