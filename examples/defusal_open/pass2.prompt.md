# Map: Bomb defusal map for 5 against 5, designed by you

Design a bomb defusal map in the style of Counter-Strike: the terrorists (T) plant the bomb at one of two bomb sites, the counter-terrorists (CT) defend them. Lay it out like a competitive map: separate routes from the T spawn to each site and through a middle area, where the teams meet at chokepoints.

Coordinates are map units of Quake and GoldSrc, with z up.

## Rules

5. **Timing.** For each bomb target, the CT walking distance is at most 0.8 times the T walking distance, and the T walking distances to the two targets differ by at most 25 % of the larger.
6. **Cover.** Each bomb site has at least 4 cover boxes: axis-aligned brushes with texture `crate` in one `func_detail` entity, whose center is within 384 units in x and y of the site's `info_bomb_target`, resting on the floor, from 32 to 128 units tall, at least one of them 64 or taller. Cover must not cut off any spawn or bomb target, and must keep the timing of rule 5.

## What to do

This is the second of two passes: the cover. `structure.map` holds the map, built in the first pass: its rooms, corridors, spawns and bomb targets. Do not change it. Read it to find the sites and their floors.

1. Design the cover and write it as the `func_detail` entity in `detail.txt`, in the .map format below.
2. Join them with `cat structure.map detail.txt > map.map` and run `mapconvert check map.map --base structure.map`. If it fails, or a rule is not met, fix `detail.txt`, join and check again.

## The Valve 220 .map format

A .map is a list of entities. Each entity is `{`, its "key" "value" lines, its brushes, and `}`.
The first entity is the world, which holds the brushes of the structure:

```
{
"classname" "worldspawn"
"mapversion" "220"
"wad" ""
<brushes>
}
```

A brush is a convex solid: `{`, one line per plane, `}`. Write every brush as an axis-aligned box.
For the box from (x0 y0 z0) to (x1 y1 z1) (x0 < x1, y0 < y1, z0 < z1) with texture TEX, write
exactly these six lines, with the numbers put in:

```
{
( x0 y0 z0 ) ( x0 y1 z0 ) ( x0 y0 z1 ) TEX [ 0 1 0 0 ] [ 0 0 -1 0 ] 0 0.25 0.25
( x1 y0 z0 ) ( x1 y0 z1 ) ( x1 y1 z0 ) TEX [ 0 1 0 0 ] [ 0 0 -1 0 ] 0 0.25 0.25
( x0 y0 z0 ) ( x0 y0 z1 ) ( x1 y0 z0 ) TEX [ 1 0 0 0 ] [ 0 0 -1 0 ] 0 0.25 0.25
( x0 y1 z0 ) ( x1 y1 z0 ) ( x0 y1 z1 ) TEX [ 1 0 0 0 ] [ 0 0 -1 0 ] 0 0.25 0.25
( x0 y0 z0 ) ( x1 y0 z0 ) ( x0 y1 z0 ) TEX [ 1 0 0 0 ] [ 0 -1 0 0 ] 0 0.25 0.25
( x0 y0 z1 ) ( x0 y1 z1 ) ( x1 y0 z1 ) TEX [ 1 0 0 0 ] [ 0 -1 0 0 ] 0 0.25 0.25
}
```

For example the box from (0 0 0) to (64 32 16) with texture crate:

```
{
( 0 0 0 ) ( 0 32 0 ) ( 0 0 16 ) crate [ 0 1 0 0 ] [ 0 0 -1 0 ] 0 0.25 0.25
( 64 0 0 ) ( 64 0 16 ) ( 64 32 0 ) crate [ 0 1 0 0 ] [ 0 0 -1 0 ] 0 0.25 0.25
( 0 0 0 ) ( 0 0 16 ) ( 64 0 0 ) crate [ 1 0 0 0 ] [ 0 0 -1 0 ] 0 0.25 0.25
( 0 32 0 ) ( 64 32 0 ) ( 0 32 16 ) crate [ 1 0 0 0 ] [ 0 0 -1 0 ] 0 0.25 0.25
( 0 0 0 ) ( 64 0 0 ) ( 0 32 0 ) crate [ 1 0 0 0 ] [ 0 -1 0 0 ] 0 0.25 0.25
( 0 0 16 ) ( 0 32 16 ) ( 64 0 16 ) crate [ 1 0 0 0 ] [ 0 -1 0 0 ] 0 0.25 0.25
}
```

A point entity has an origin and no brushes:

```
{
"classname" "info_player_start"
"origin" "96 240 40"
}
```

A brush entity has brushes and no origin:

```
{
"classname" "func_detail"
<brushes>
}
```

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
- The files that must exist at the end: `detail.txt`, `map.map`.
