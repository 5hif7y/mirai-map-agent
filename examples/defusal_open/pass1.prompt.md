# Map: Bomb defusal map for 5 against 5, designed by you

Design a bomb defusal map in the style of Counter-Strike: the terrorists (T) plant the bomb at one of two bomb sites, the counter-terrorists (CT) defend them. Lay it out like a competitive map: separate routes from the T spawn to each site and through a middle area, where the teams meet at chokepoints.

Coordinates are map units of Quake and GoldSrc, with z up.

## Rules

1. **Bounds.** The space a player walks in (rooms and corridors) inside x 0 to 3072, y 0 to 3072, z 0 to 512; the solid around it may reach up to 64 units further.
2. **Sealed.** Floors, walls and ceilings are solid world brushes; no air may reach the outside of the map. Textures: floor `dev_floor`, walls `dev_wall`, ceiling `dev_ceiling`.
3. **Spawns.** A T spawn area with 5 `info_player_deathmatch` and a CT spawn area with 5 `info_player_start`, standing on the floor, every spawn at least 64 units from every other.
4. **Bomb sites.** Two sites, A and B, each marked by one `info_bomb_target` standing on its floor.
5. **Timing.** For each bomb target, the CT walking distance is at most 0.8 times the T walking distance, and the T walking distances to the two targets differ by at most 25 % of the larger.

## What to do

This is the first of two passes: the structure. The cover of the sites comes in the second pass; leave room for it in the sites.

1. Design the rooms, corridors and point entities and write them as `layout.json`; build them with `mapconvert layout layout.json structure.map`.
2. Run `mapconvert check structure.map`. If it fails, or a rule is not met, fix `layout.json`, rebuild and check again.

## The layout JSON and `mapconvert layout`

`mapconvert layout layout.json structure.map` builds the structure of a map from rooms and
corridors: a closed shell of solid world brushes out of which the rooms and corridors are dug. It
cannot leave a wall open to the void. The JSON:

```
{
  "unit": 16,
  "textures": {"floor": "dev_floor", "wall": "dev_wall", "ceiling": "dev_ceiling"},
  "rooms": [{"name": "a", "x": 0, "y": 0, "w": 24, "d": 20, "floor": 0, "height": 10}],
  "corridors": [{"from": "a", "to": "b", "width": 6}],
  "entities": [{"classname": "info_player_start", "room": "a", "at": [4, 4]}]
}
```

- Every size and position is in grid steps of `unit` map units (16): a room with "x": 2 starts at
  x = 32 units. Divide the map units of the task by 16.
- A room is a box of empty space: x, y its lowest corner, w along x, d along y, its floor at
  `floor` and its ceiling at `floor + height`.
- A corridor joins the centers of two rooms with an L of `width` steps: first along x at the y of
  the center of `from`, then along y at the x of the center of `to`. It sits at the floor of the
  lower room and is as tall as the lower room. A player steps up at most one step (16 units) from
  a corridor into a room.
- An entity is put in a room at "at": [cx, cy] grid steps from the room's lowest corner. Its
  origin is the middle of that cell, (room.x + cx) * 16 + 8 and likewise for y, at the room's
  floor + 36. Extra keys go in "keys": {"targetname": "x"}.

## The check

`mapconvert check map.map` reports whether a player can walk from the spawns (info_player_*) to
every objective (info_bomb_target, hostage_entity, func_hostage_rescue) and whether the map leaks
(its air reaches past every brush, so it is open to the void). With `--base structure.map` it also
reports whether every brush of the structure is still in the map unchanged. It prints `pass` and
exits with status 0 when the map is good, `fail` and status 1 when not.
It also prints the walking distance from the spawns of each classname to each objective, in units
along a grid of 16 units: the rules on timing below are measured with these numbers.

## Rules

- Work only in the current directory. The tool `mapconvert` is on the PATH.
- Do not read, list or search anything outside the current directory: no other folders and no search of the disk. Everything you need is in this task.
- Run `mapconvert check` at most 8 times in this task.
- Stop when the check prints `pass`, or after the 8th check, and reply with one line: `DONE pass` or `DONE fail`.
- The files that must exist at the end: `layout.json`, `structure.map`.
