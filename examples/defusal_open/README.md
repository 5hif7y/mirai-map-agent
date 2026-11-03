# defusal_open

A bomb defusal map for 5 against 5 that an agent (`pi` 1.5.0 with DeepSeek Flash) designed in two
sessions from an open request, without coordinates:

1. `pass1.prompt.md` asked for the structure: it wrote `layout.json` and built `structure.map`.
2. `pass2.prompt.md` asked for the cover of the bomb sites over that structure: it wrote `detail.txt`,
   and `map.map` is the two joined.

The prompts name `mapconvert layout` and `mapconvert check`, the command line of the experiment; in this
plugin they are the API methods `map_agent.layout` and `map_agent.check`, which do the same.

`map_agent.check` on `map.map` with `structure.map` as `base` passes: both teams reach both sites, there
is no leak, the 59 brushes of the structure are kept, and the counter-terrorists walk 1 280 units to each
site against the 2 560 and 2 624 of the terrorists.
