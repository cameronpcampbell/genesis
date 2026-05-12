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
| LoadBandPriority | `{ number }?` | no | Initial allocation weights for `{ Near, Mid, Far }`. Defaults to `{ 1, 2, 3 }`. Splits the seed budget across per-band buckets (see [Band Budgets](#band-budgets)). |
| Target | `any?` | no | Initial target. Can be a `BasePart` or `vector`. |
| TargetPosition | `(target: any) -> vector?` | no | Custom function to extract a position from the target. Defaults to reading `BasePart.Position` or passing a vector through. |
| Budget | `BudgetConfig?` | no | Budgeting configuration. See [Budget](#budget). |
| LookaheadTime | `number?` | no | Seconds to predict the target position ahead for LOD decisions. Defaults to `0.5`. Set to `0` to disable prediction. |

### `loader:Step(deltaTime: number?)`

Advances the loader: polls the target position, processes the load and destroy queues, and updates the adaptive budget. Call this once per frame. If `deltaTime` is omitted, the loader measures elapsed time itself.

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

## Band Budgets

Chunks are classified into three bands by the LOD level their leaves render at (derived from the chunk's distance via Strata's split rule). LOD 0 (highest detail, nearest to target) maps to the Near band. LOD `LodAmount - 1` (coarsest, farthest) maps to the Far band, the intermediate LODs fill Mid. Each band has a single per-frame budget that covers all chunk work for that band: new-root creation from the load queue, whole-chunk destruction at the trailing edge, and diff-loop refinement on existing octrees (subdivisions and merges). Inside each band's slot, work runs in priority order, pop queue first so leading-edge chunks aren't starved, then trailing-edge destroys, then refinement.

`LoadBandPriority` seeds the initial split: with the default `{ 1, 2, 3 }`, the seed budget divides 17% Near / 33% Mid / 50% Far across the three bands. Far gets the largest seed because it has the most chunks by volume (outermost shell) and is where new chunks pour in during movement. From there each band adapts independently against its own residence histogram (which samples both create and destroy completions), growing where chunks are settling slowly and shrinking where they're settling quickly.

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

The loader uses a residence-time SLO controller: each band's per-frame budget scales each frame to keep the 95th percentile of chunk residence time under a target deadline. When a band's queue is healthy, its budget shrinks and frame time stays flat; when chunks pile up, the budget grows toward a ceiling that lifts during heavy backlogs so the system catches up rather than desyncing. Each band adapts independently from its own residence histogram.

```lua
type BudgetConfig = {
    BandSeconds: number?,
    Adaptive: (AdaptiveBudgetConfig | boolean)?,
}
```

| Field | Default | Description |
| ----- | ------- | ----------- |
| BandSeconds | `0.0045` | Initial seconds per frame for all chunk work, split across band buckets by `LoadBandPriority`. Each band's bucket covers create, destroy, and refinement for chunks in that band. |
| Adaptive | `true` | Set to `false` to pin budgets to the initial seeds, or pass an `AdaptiveBudgetConfig` to tune the SLO controller. |

### `AdaptiveBudgetConfig`

All fields are optional.

| Field | Default | Description |
| ----- | ------- | ----------- |
| TargetResidenceSeconds | `2.0` | Target chunk residence time (enqueue to completion) for `TargetPercentile`. |
| TargetPercentile | `0.95` | Fraction of chunks that should complete within `TargetResidenceSeconds`. |
| NormalMaxBudgetSeconds | `0.0075` | Per-band ceiling under typical load. |
| BacklogMaxBudgetSeconds | `0.030` | Per-band ceiling when that band is in backlog or starvation. Lifts the frame-time guard rail to let the system catch up. |
| BacklogQueueThreshold | `256` | Per-band queue length (combined load and destroy pending) that activates the backlog ceiling for that band. |
| StarvationCeilingSeconds | `8.0` | Head-of-line age that forces the budget straight to `BacklogMaxBudgetSeconds`. |
| MinBudgetSeconds | `0.0015` | Floor on the per-frame budget. |
| GrowthRate | `1.25` | Per-frame multiplier cap when residence is over target. |
| ShrinkRate | `0.90` | Per-frame multiplier floor when residence is under target. |
| TargetFrameSeconds | _auto_ | Calibrated from quiet frames; pass an explicit value to override. |
| Smoothing | `0.2` | EMA smoothing factor for frame time measurement. |
