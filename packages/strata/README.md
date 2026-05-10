# Strata

Octree-based LOD subdivision for Luau. Given a target position, returns a set of leaves that tile space, finer near the target and coarser farther away.

## Usage

```lua
local Strata = require(strata)

local octree = Strata.New({
    RootCenter = vector.create(0, 0, 0),
    BaseLeafSize = 16,
    LodAmount = 7,
    SplitFactor = 2.5,
})

local diff = octree:SetTarget(targetPosition)
if diff then
    for groupIdx, group in diff.Created do
        local size = diff.CreatedSizes[groupIdx]
        for _, center in group do
            -- Spawn a chunk at `center` with extent `size`.
        end
    end

    for _, center in diff.Destroyed do
        -- Despawn the chunk previously at `center`.
    end
end

-- On shutdown.
for _, center in octree:Teardown() do
    -- Despawn anything still rendered.
end
```

## API

### `Strata.New(config: Config) -> Octree`

| Config Field | Type | Required | Description |
| ------------ | ---- | -------- | ----------- |
| RootCenter | `vector` | yes | World-space center of the root cell. |
| BaseLeafSize | `number` | yes | Side length at the finest LOD. Coarser leaves are `2^k` multiples of this. |
| LodAmount | `number` | yes | Number of LODs including the leaf. Root side length is `BaseLeafSize * 2^(LodAmount - 1)`. |
| SplitFactor | `number` | no | Controls LOD ring size; defaults to `1.0`. A node splits when the target is within `SplitFactor * size` along any axis. Larger values produce larger LOD rings, pushing each level of detail farther out from the target. |
| Sample | `(center: vector) -> number` | yes | SDF probe driving sparse voxel octree (SVO) culling: nodes whose `\|Sample(center)\|` exceeds `size * SurfaceFactor` are pruned from the tree. The function must be a true or conservative signed distance field with Lipschitz constant ≤ 1: negative inside the surface, positive outside. |
| SurfaceFactor | `number` | no | SVO cull threshold multiplier; defaults to `1.5155` (`√3/2 * 1.75` safety factor over the box half-diagonal). A node is pruned when `\|sdf\| >= size * SurfaceFactor`. Increase to be more conservative (cull less, render more); decrease to cull more aggressively at the risk of skipping chunks that actually contain the surface. |

### `octree:SetTarget(target: vector) -> Diff?`

Updates subdivision toward `target` and returns the change vs. the previous target. Returns `nil` when the target has moved less than `BaseLeafSize` from the last refresh, so a real refresh did not run.

```lua
type Diff = {
    -- Created[i] is a list of centers, with the
    -- corresponding size at CreatedSizes[i].
    Created: { { vector } },
    CreatedSizes: { vector },

    -- Centers of cells that were destroyed.
    Destroyed: { vector },
}
```

Cells that become visible are grouped by size, since cells of the same LOD all share the same size vector. When non-nil, the returned tables are fresh and owned by the caller.

### `octree:Teardown() -> { vector }`

Returns the centers of every currently-rendered leaf and marks them un-rendered. Call this when destroying the octree to drive final cleanup.

### `octree:Stats(accumulator: Stats?) -> Stats`

Counts live nodes and rendered leaves. Pass an existing table to reuse it.

```lua
type Stats = {
    Leaves: number,
    Nodes: number,
    LeavesBySize: { [number]: number },
}
```

## Benchmark

Tested on Apple M2 Max (12 core).

BaseLeafSize = 32, SplitFactor = 2.5, 200 SetTarget calls along a path bounded by `0.4 * RootSize`.

Script used for the benchmark can be found [here](./benchmark.server.luau).

### Tree shape

|           |    4 lods |    6 lods |    8 lods |
|-----------|----------:|----------:|----------:|
| Root size | 256 studs | 1024 studs | 4096 studs |
| Leaves    |       512 |      1408 |      2304 |
| Nodes     |       585 |      1609 |      2633 |

- **Root size**: side length of the root cell (`BaseLeafSize * 2 ^ (LodAmount - 1)`).
- **Leaves**: rendered leaves after the initial subdivision at the origin.
- **Nodes**: total live nodes (internal + leaf) in the tree.

### Timings

|                |    4 lods |    6 lods |    8 lods |
|----------------|----------:|----------:|----------:|
| Construct      | 0.067 ms  | 0.015 ms  | 0.018 ms  |
| Cold SetTarget | 0.208 ms  | 0.531 ms  | 0.892 ms  |
| Path avg       | 0.0164 ms | 0.2034 ms | 0.5460 ms |
| Path p50       | 0.0002 ms | 0.2114 ms | 0.5573 ms |
| Path p99       | 0.0918 ms | 0.5516 ms | 1.0195 ms |
| Teardown       | 0.007 ms  | 0.027 ms  | 0.039 ms  |

- **Construct**: `Strata.New` allocation + level-data setup.
- **Cold SetTarget**: first `SetTarget` on a fresh octree, builds the whole tree.
- **Path avg / p50 / p99**: per-call time across all 200 path steps, including no-op skips. p99 is the worst-frame budget.
- **Teardown**: `octree:Teardown()` time to release every live leaf.
