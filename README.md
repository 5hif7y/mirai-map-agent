# map_agent: maps written by an agent, in two passes

A plugin for the Mirai engine editor that gives an agent what it needs to write a Valve 220 map in two
passes, as methods of the editor API and so of its MCP server: a structure built from rooms and
corridors, and a check between passes.

It needs [valve220](https://github.com/5hif7y/mirai-valve220) and
[map_convert](https://github.com/5hif7y/mirai-map-convert).

## Install

It is not in the catalog on its own: there it is part of
[brush_maps](https://github.com/5hif7y/mirai-brush-maps), which joins the map plugins in one install
(`mirai plugin add brush_maps`). Installed alone, by its address, in the folder of a Mirai project:

```sh
mirai plugin add https://github.com/5hif7y/mirai-valve220.git
mirai plugin add https://github.com/5hif7y/mirai-map-convert.git
mirai plugin add https://github.com/5hif7y/mirai-map-agent.git
```

## The two passes

1. **Structural.** The agent writes rooms and corridors as JSON and `map_agent.layout` turns them into
   the brushes of a solid shell from which the rooms are dug. It cannot leave a wall open to the void,
   and the sides no room sees are `skip`.
2. **Detail.** The agent adds brushes in a `func_detail` entity (crates, pillars, frames), in Valve 220,
   and does not touch the structure.
3. **Between passes.** `map_agent.check` with `base` set to the structure fails if a brush of the
   structure changed, if a spawn or an objective cannot be reached on foot, or if the air of the spawns
   reaches the void.

## API

- `map_agent.layout {layout, out}`: the JSON of the layout to a Valve 220 `.map` in the project.

  ```json
  {
    "unit": 16,
    "textures": {"floor": "dev_floor", "wall": "dev_wall", "ceiling": "dev_ceiling"},
    "rooms": [{"name": "a", "x": 0, "y": 0, "w": 24, "d": 20, "floor": 0, "height": 10}],
    "corridors": [{"from": "a", "to": "b", "width": 6}],
    "entities": [{"classname": "info_player_start", "room": "a", "at": [4, 4]}]
  }
  ```

  Sizes and positions are in steps of `unit`. A corridor joins the centers of two rooms with an L at the
  floor of the lower one and ends at the wall of a higher room as a step.
- `map_agent.check {path, base}`: walks a player of 32 × 32 × 72 units on a grid of 16 from the spawns
  (`info_player_*`) to the objectives (`info_bomb_target`, `func_bomb_target`, `hostage_entity`,
  `func_hostage_rescue`, `func_buyzone`), floods the air of the spawns to find leaks, measures how far
  the spawns of each team walk to each objective and, with `base`, counts the brushes of the structure
  kept unchanged. The full report goes to `.mirai/tmp/map-agent-check.txt`.

  The walk climbs one step of 16 units and drops any height. It knows no ladders, crouching, water or
  jumps: it is a bound, not the navigation of a game.

## Measured

An agent (`pi` 1.5.0 with DeepSeek Flash) wrote 96 maps with these tools, from exact and from open
specifications, in one session or in two:

- Writing the structure as JSON for `layout` instead of brushes cut the output tokens about four times
  (about six times when the agent wrote the files by hand, without programs).
- With an open specification, writing the `.map` directly gave arenas: a box the size of the bounds
  with a few partitions in 7 of 8 maps. With the JSON every map had rooms and corridors.
- Two sessions, one per pass, did no better than one session that writes the JSON and then the detail,
  and cost between 18 % and 50 % more.
- The first `check` passed in most sessions: with these small maps the detail pass rarely broke the
  structure.

The corridors of `layout` join the centers of the rooms: with the spawns and the middle in line, the
spawns can see each other. Corridors through waypoints are not there yet.

`examples/defusal_open/` is one of the maps of the experiment, written in two sessions, with the two
prompts it came from.

## Tests

With `mirai test plugins/map_agent/editor/agent`. The maps of the tests are built in code.

## License

Licensed under either of [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE), at your option.
