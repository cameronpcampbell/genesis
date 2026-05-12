# Poisson

Deterministic 2D Poisson disc sampler with multiple named classes, per-class radii and weights, and a parent/child hierarchy for placing decorations (sticks, pinecones) within the footprint of larger objects (trees).

## Usage

```luau
local Poisson = require(poisson)

local sampler = Poisson.new({
    Tree = {
        Radius = 15,
        ChildSpawnRadius = 12,
        Weight = 10,

        Children = {
            Stick = { Radius = 5, Weight = 8 },
            Pinecone = { Radius = 5, Weight = 5 },
        },
    },

    Bush = { Radius = 8, Weight = 5 },
})

local samples = sampler:Sample(50, vector.create(200, 200))

for _, sample in samples do
    print(sample.Name, sample.Position)
end
```

The same sampler can be reused across many seeds; each call to `Sample` is independent.

## Configuration

Each node has:

- `Radius` — exclusion radius. Two samples `A` and `B` satisfy `distance(A, B) >= rA + rB` (their radius discs do not overlap). One exception: a sample may overlap any of its ancestors so that children can lie inside their parent's footprint.
- `Weight` — relative probability that a candidate position becomes this class versus its siblings. Higher weight, more samples.
- `ChildSpawnRadius` — optional. Radius of the disc, centered on this sample, in which this node's children are scattered. Defaults to `Radius` when omitted. Has no effect on nodes without `Children`.
- `Children` — optional table of nested nodes. Children are placed *within* their parent's `ChildSpawnRadius` after the parent is placed. Nesting is unbounded.

The output is a flat list of `{ Position: vector, Name: string }`. The hierarchy is only used during placement.

## API

### `Poisson.new(config) -> Poisson`

Builds a sampler from a node tree. `config` is a table mapping node names to `Node`. All `Radius` and `Weight` values must be `> 0`.

### `sampler:Sample(seed, size) -> { Sample }`

Returns a flat list of placed samples within the rectangle anchored at the origin: `x` in `[0, size.x)`, `y` in `[0, size.y)`. `seed` is forwarded to `Random.new`; identical `(seed, size)` returns identical output.
