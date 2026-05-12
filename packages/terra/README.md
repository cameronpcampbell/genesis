# Terra

A collection of procedural terrain generators for [Genesis](/packages/genesis/README.md). Each generator implements the `Generator` interface that Genesis expects: `Create`, `Destroy`, and `Sample`.

## Usage

```lua
local Genesis = require(genesis)
local Terra = require(terra)

local loader = Genesis.New({
    ChunkSize = 165,
    RenderDistance = 3,
    OctreeLodAmount = 6,
    OctreeSplitFactor = 2.5,
    Generator = Terra.MarchingCubes({
        Seed = 25,
    }),
})
```

## API

### `Terra.MarchingCubes(config: MarchingCubesConfig?) -> Generator`

Returns a generator that produces meshed terrain chunks from fractal noise using the marching cubes algorithm.

| Config Field | Type | Default | Description |
| ------------ | ---- | ------- | ----------- |
| Seed | `number?` | `0` | Noise seed. Different seeds produce different worlds. |
| Resolution | `number?` | `10` | Voxel resolution per chunk along each axis. Higher means smoother terrain and slower generation. |
| IsoValue | `number?` | `0` | Density threshold used to extract the surface. |
| Scale | `number?` | `550` | Horizontal noise scale. Larger values stretch features wider. |
| Amplitude | `number?` | `0.008` | Vertical density falloff per stud. Smaller values produce taller terrain. |
| Octaves | `number?` | `4` | Number of noise octaves layered together. |
| Lacunarity | `number?` | `0.5` | Frequency multiplier between octaves. |
| Persistence | `number?` | `0.3` | Amplitude multiplier between octaves. |
| Vegetation | `Poisson.Config?` | `nil` | If provided, places one `Part` per Poisson sample on the chunk surface. See [Poisson](/packages/utils/poisson/README.md) for the config shape. |

When `Vegetation` is set, every generated chunk samples Poisson over its XZ footprint (seeded per-chunk from `Seed` + chunk position) and spawns a `Part` for every sample at the noise-derived surface height. Spawned parts parent under the chunk's `MeshPart`, so chunk destruction cleans them up. If your chunking generates multiple chunks at the same XZ (different LODs, or stacked Y slices), expect duplicate parts at each surface point.
