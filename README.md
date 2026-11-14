# Obsidian API

A library for [Obsidian](https://github.com/Alomare/ObsidianLauncher) mods on HELLDIVERS (2015). It gives other mods the game data by name, checked changes that can be undone, and ready actions. It does nothing by itself.

## How to use

Obsidian API comes with Obsidian, in the Obsidian Kit. Mods that need it switch it on with them.

To build on it, list it in the `obsidian.json` of the mod:

```json
"requires": ["obsidian.api"]
```

Then ask for it in the script:

```lua
local api = obsidian.import("obsidian.api")

obsidian.keybind("panic", function()
  api.player.heal()
  api.enemies.kill_near(20)
end)
```

Actions answer `true`, or `false` and a short reason such as `"host_only"`. A client mod can require the API and stay a client mod: it can read game data and use the interface, sound and event calls, and anything that changes the shared game answers `false, "needs_session"`.

[REFERENCE.md](REFERENCE.md) has every call, with guides and recipes. A copy sits in the folder of the API in the Obsidian Kit, where an AI tool working on a mod can read it.

## Known issues

- Tested solo and offline, not yet with a second player.
