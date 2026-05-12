# Genesis

Chunk loading system for Luau. Manages procedural world chunks around a target position with optional octree-based LOD and an adaptive per-frame budget that keeps chunks settling on time without stalling the frame.

## Usage

```lua
local Genesis = require(genesis)
local Terra = require(terra)

local loader = Genesis.New({
    ChunkSize = 165,
    RenderDistance = 3,
    OctreeLodAmount = 6,
    OctreeSplitFactor = 2.5,
    Generator = Terra.MarchingCubes(),
})

loader:SetTarget(character.HumanoidRootPart)

game:GetService("RunService").Heartbeat:Connect(function(deltaTime)
    loader:Step(deltaTime)
end)
```

## API

### `Genesis.New(config: ChunkLoaderConfig) -> ChunkLoader`

| Config Field | Type | Required | Description |
| ------------ | ---- | -------- | ----------- |
| ChunkSize | `number` | yes | Side length of the smallest octree node. |
| OctreeLodAmount | `number?` | no | Number of octree LODs. Defaults to `1` (no subdivision). |
| OctreeSplitFactor | `number?` | no | Controls how far each LOD ring extends from the target. Defaults to `1.0`. Larger values push coarser detail farther out. |
| Generator | `Generator` | yes | Object that creates and destroys chunk geometry. |
| RenderDistance | `number` | yes | Radius in root node units around the target to keep loaded. |
| LoadBandPriority | `{ number }?` | no | Initial weights for `{ Near, Mid, Far }` band budgets. Defaults to `{ 1, 2, 3 }`. Higher means more per-frame time spent on that band. |
| Target | `any?` | no | Initial target. Can be a `BasePart` or `vector`. |
| TargetPosition | `(target: any) -> vector?` | no | Custom function to extract a position from the target. Defaults to reading `BasePart.Position` or passing a vector through. |
| Budget | `BudgetConfig?` | no | Budgeting configuration. See [Budget](#budget). |
| LookaheadTime | `number?` | no | Seconds to predict the target position ahead for LOD decisions. Defaults to `0.5`. Set to `0` to disable prediction. |

### `loader:Step(deltaTime: number?)`

Advances the loader. Call this once per frame. If `deltaTime` is omitted, the loader measures elapsed time itself.

### `loader:SetTarget(target: any?)`

Sets or clears the target that chunks load around. Accepts a `BasePart`, a `vector`, or `nil`. Changing the target clears all chunks from the previous position and begins loading around the new one.

### `loader:SetRenderDistance(renderDistance: number)`

Changes the render distance. Chunks outside the new distance are queued for destruction, chunks inside it are queued for creation.

### `loader:Stats() -> LoaderStats`

Returns a snapshot of current loader state.

```lua
type LoaderStats = {
    State: {
        Total: number,
        Creating: number,
        Alive: number,
        Destroying: number,
    },
    Queues: {
        Load: number,
        LoadByBand: { number },
        Destroy: number,
        DestroyByBand: { number },
    },
    Budget: {
        BandSeconds: { number },
    },
    SLO: {
        ResidenceP95: { number },
        HoLAgeSeconds: { number },
    },
    Octree: {
        Leaves: number,
        Nodes: number,
        LeavesBySize: { [number]: number },
    },
}
```

`Queues.Load` and `Queues.Destroy` are total pending counts. `Queues.LoadByBand` and `Queues.DestroyByBand` break them down by band as `{ Near, Mid, Far }`. `Budget.BandSeconds`, `SLO.ResidenceP95`, and `SLO.HoLAgeSeconds` are likewise per-band.

Chunks are split into three bands by LOD. Near is LOD 0 (closest, highest detail), Far is the coarsest, Mid is everything in between.

## Generator

A generator is any table with `Create`, `Destroy`, and `Sample` fields.

```lua
type Generator = {
    Create: (position: vector, size: vector, lod: number) -> (),
    Destroy: (position: vector) -> (),
    Sample: (center: vector) -> number,
}
```

`Create` and `Destroy` are called once per chunk with the chunk's center position. `Create` also receives the chunk's size vector and its normalized LOD as a decimal in `[0, 1)`, where `0` is the leaf (finest detail) and the coarsest level is `(OctreeLodAmount - 1) / OctreeLodAmount`. `Sample` is the SDF probe Strata uses for culling (see [Strata](/packages/strata/README.md)).

## Budget

Each band gets a per-frame time budget that adapts to keep chunks loading on time. By default the budget scales itself, growing when chunks are backing up and shrinking when they're settling quickly.

```lua
type BudgetConfig = {
    BandSeconds: number?,
    Adaptive: (AdaptiveBudgetConfig | boolean)?,
}
```

| Field | Default | Description |
| ----- | ------- | ----------- |
| BandSeconds | `0.0045` | Initial seconds per frame for all chunk work, split across bands by `LoadBandPriority`. |
| Adaptive | `true` | Set to `false` to pin budgets to the initial seeds. Pass an `AdaptiveBudgetConfig` to tune the adaptive controller. |

### `AdaptiveBudgetConfig`

All fields are optional.

| Field | Default | Description |
| ----- | ------- | ----------- |
| TargetResidenceSeconds | `2.0` | Target time from chunk enqueue to completion. |
| TargetPercentile | `0.95` | Fraction of chunks that should complete within `TargetResidenceSeconds`. |
| NormalMaxBudgetSeconds | `0.0075` | Per-band ceiling under typical load. |
| BacklogMaxBudgetSeconds | `0.030` | Per-band ceiling when a band is backlogged. Lets the system catch up at the cost of a higher frame-time bump. |
| BacklogQueueThreshold | `256` | Per-band queue length that activates the backlog ceiling. |
| StarvationCeilingSeconds | `8.0` | Oldest pending chunk age that forces the budget straight to `BacklogMaxBudgetSeconds`. |
| MinBudgetSeconds | `0.0015` | Floor on the per-frame budget. |
| GrowthRate | `1.25` | Per-frame multiplier cap when residence is over target. |
| ShrinkRate | `0.90` | Per-frame multiplier floor when residence is under target. |
| TargetFrameSeconds | _auto_ | Calibrated from quiet frames. Pass an explicit value to override. |
| Smoothing | `0.2` | EMA smoothing factor for frame time measurement. |
