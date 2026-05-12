# Genesis

Chunk loading system for Luau. Manages procedural world chunks around a target position with octree-based LOD and a residence-time SLO controller that scales per-frame work to keep chunks settling within a target deadline.

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
| NearBandRadius | `number?` | no | Chebyshev radius (in root nodes) of the near band. Defaults to `RenderDistance / 3`. |
| MidBandRadius | `number?` | no | Chebyshev radius of the mid band. Defaults to `2 * RenderDistance / 3`. |
| LoadBandPriority | `{ number }?` | no | Initial allocation weights for `{ Near, Mid, Far }`. Defaults to `{ 3, 2, 1 }`. Splits the seed load budget across per-band buckets (see [Band Budgets](#band-budgets)). |
| Target | `any?` | no | Initial target. Can be a `BasePart` or `vector`. |
| TargetPosition | `(target: any) -> vector?` | no | Custom function to extract a position from the target. Defaults to reading `BasePart.Position` or passing a vector through. |
| Budget | `BudgetConfig?` | no | Budgeting configuration. See [Budget](#budget). |

### `loader:Step(deltaTime: number?)`

Advances the loader: polls the target position, processes the load and destroy queues, and updates the adaptive budget. Call this once per frame. If `deltaTime` is omitted, the loader measures elapsed time itself.

### `loader:SetTarget(target: any?)`

Sets or clears the target that chunks load around. Accepts a `BasePart`, a `vector`, or `nil`. Changing the target clears all chunks from the previous position and begins loading around the new one.

### `loader:SetRenderDistance(renderDistance: number)`

Changes the render distance. Chunks outside the new distance are queued for destruction; chunks inside it are queued for creation.

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
        LoadSeconds: { number },
        DestroySeconds: { number },
    },
    SLO: {
        LoadResidenceP95: { number },
        DestroyResidenceP95: { number },
        LoadHoLAgeSeconds: { number },
        DestroyHoLAgeSeconds: { number },
    },
    Octree: {
        Leaves: number,
        Nodes: number,
        LeavesBySize: { [number]: number },
    },
}
```

`Queues.Load` and `Queues.Destroy` are total pending counts. `Queues.LoadByBand` and `Queues.DestroyByBand` break them down by band as `{ Near, Mid, Far }`. `Budget.LoadSeconds`, `Budget.DestroySeconds`, and all `SLO` fields are likewise per-band.

## Band Budgets

Chunks are classified into three bands by Chebyshev distance from the target: Near (closest), Mid, and Far. Each band has its own pair of per-frame budget buckets: one for load (new-root creation + diff-loop refinement) and one for destroy (chunks leaving the render volume + diff-loop merges). Work charged to a band spends from that band's bucket, so a heavy Near re-subdivision pass can't starve Far new-root creation, nor can a wave of Far departures slow Near destroys.

`LoadBandPriority` seeds the initial split for both buckets: with the default `{ 3, 2, 1 }`, the seed load and destroy budgets each divide 50% Near / 33% Mid / 17% Far. From there each bucket adapts independently against its own residence histogram, growing where chunks are settling slowly and shrinking where they're settling quickly.

## Generator

A generator is any table with `Create`, `Destroy`, and `Sample` fields.

```lua
type Generator = {
    Create: (position: vector, size: vector) -> (),
    Destroy: (position: vector) -> (),
    Sample: (center: vector) -> number,
}
```

`Create` and `Destroy` are called once per chunk (one octree node) with the chunk's center position. `Create` also receives the chunk's size vector. `Sample` is the SDF probe Strata uses for SVO culling (see [Strata](/packages/strata/README.md)).

## Budget

The loader uses a residence-time SLO controller: per-band load buckets and the destroy budget scale each frame to keep the 95th percentile of chunk residence time under a target deadline. When the queues are healthy, budgets shrink and frame time stays flat; when chunks start piling up, the affected bucket grows toward a ceiling that lifts during heavy backlogs so the system catches up rather than desyncing. Each band's bucket adapts independently from its own residence histogram.

```lua
type BudgetConfig = {
    LoadSeconds: number?,
    DestroySeconds: number?,
    Adaptive: (AdaptiveBudgetConfig | boolean)?,
}
```

| Field | Default | Description |
| ----- | ------- | ----------- |
| LoadSeconds | `0.004` | Initial seconds per frame for chunk creation. Split across band buckets by `LoadBandPriority`. |
| DestroySeconds | `0.004` | Initial seconds per frame for chunk destruction. Split across band buckets by `LoadBandPriority`. |
| Adaptive | `true` | Set to `false` to pin budgets to the initial seeds, or pass an `AdaptiveBudgetConfig` to tune the SLO controller. |

### `AdaptiveBudgetConfig`

All fields are optional.

| Field | Default | Description |
| ----- | ------- | ----------- |
| TargetResidenceSeconds | `2.0` | Target chunk residence time (enqueue to completion) for `TargetPercentile`. |
| TargetPercentile | `0.95` | Fraction of chunks that should complete within `TargetResidenceSeconds`. |
| NormalMaxBudgetSeconds | `0.012` | Per-bucket ceiling under typical load (applies to each load band bucket and the destroy budget). |
| BacklogMaxBudgetSeconds | `0.050` | Per-bucket ceiling when that bucket is in backlog or starvation. Lifts the frame-time guard rail to let the system catch up. |
| BacklogQueueThreshold | `256` | Per-bucket queue length that activates the backlog ceiling for that bucket. |
| StarvationCeilingSeconds | `8.0` | Head-of-line age that forces the budget straight to `BacklogMaxBudgetSeconds`. |
| MinBudgetSeconds | `0.002` | Floor on the per-frame budget. |
| GrowthRate | `1.25` | Per-frame multiplier cap when residence is over target. |
| ShrinkRate | `0.90` | Per-frame multiplier floor when residence is under target. |
| TargetFrameSeconds | _auto_ | Calibrated from quiet frames; pass an explicit value to override. |
| Smoothing | `0.2` | EMA smoothing factor for frame time measurement. |
