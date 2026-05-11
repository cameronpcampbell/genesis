# Genesis

Chunk loading system for Luau. Manages procedural world chunks around a target position with octree-based LOD and adaptive budgeting to ensure smooth performance.

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
| Target | `any?` | no | Initial target. Can be a `BasePart` or `vector`. |
| TargetPosition | `(target: any) -> vector?` | no | Custom function to extract a position from the target. Defaults to reading `BasePart.Position` or passing a vector through. |
| Budget | `BudgetConfig?` | no | Per-frame time budget for loading and destroying. See [Budget](#budget). |

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
        Destroy: number,
    },
    Budget: {
        LoadSeconds: number,
        DestroySeconds: number,
    },
    Octree: {
        Leaves: number,
        Nodes: number,
        LeavesBySize: { [number]: number },
    },
}
```

## Generator

A generator is any table with `Create`, `Destroy`, and `Sample` fields.

```lua
type Generator = {
    Create: (positionGroups: { { vector } }, sizes: { vector }) -> (),
    Destroy: (positions: { vector }) -> (),
    Sample: (center: vector) -> number,
}
```

`Create` receives positions grouped by size: `positionGroups[i]` holds all chunk centers at `sizes[i]`. `Destroy` receives a flat list of centers to remove. `Sample` is the SDF probe Strata uses for SVO culling (see [Strata](/packages/strata/README.md)).

## Budget

Budget controls how much time per frame the loader spends creating and destroying chunks. Adaptive budgeting is enabled by default and adjusts limits based on frame time.

```lua
type BudgetConfig = {
    LoadSeconds: number?,
    DestroySeconds: number?,
    Adaptive: (AdaptiveBudgetConfig | boolean)?,
}
```

| Field | Default | Description |
| ----- | ------- | ----------- |
| LoadSeconds | `0.004` | Seconds per frame allocated to chunk creation. |
| DestroySeconds | `0.004` | Seconds per frame allocated to chunk destruction. |
| Adaptive | `true` | Set to `false` to disable adaptive budgeting, or pass an `AdaptiveBudgetConfig` to tune it. |

### `AdaptiveBudgetConfig`

All fields are optional.

| Field | Default | Description |
| ----- | ------- | ----------- |
| TargetFrameSeconds | _auto_ | Target frame time. Auto-calibrated from quiet frames; pass an explicit value to override. |
| LoadMin | `0.002` | Floor for the load budget. |
| LoadMax | `0.012` | Ceiling for the load budget. |
| DestroyMin | `0.002` | Floor for the destroy budget. |
| DestroyMax | `0.012` | Ceiling for the destroy budget. |
| ShrinkFactor | `0.85` | Multiplier applied to the budget on over-budget frames. |
| OvershootTolerance | `1.15` | Fraction of target frame time the smoothed frame time must exceed before the budget shrinks. Raise it to let the budget hold near its ceiling under sustained chunk work, lower it for stricter throttling. |
| Smoothing | `0.2` | EMA smoothing factor for frame time measurement. |
