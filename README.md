# Genesis
A procedural terrain generation library for Roblox.


<img src="example.png" alt="Genesis LOD visualization" width="400" height="400" />

## Features
- Optional Octree LOD support.
- Uses a slab based chunk loader, instead of a naive/slow brute force check against all of the old and updated chunk positions.
- Has an adaptive budgeting system which intelligently spreads chunk generation across frames to prevent lag.

[Documentation](/packages/genesis/README.md)

## Subprojects
- **[Strata](/packages/strata/README.md)**: A Library for handling octree generation.
- **[Terra](/packages/terra/README.md)**: A collection of generators for Genesis.

- **[Pool](/packages/utils/pool/README.md)**: A generic object pool library.
- **[RingBuffer](/packages/utils/ringBuffer/README.md)**: A ring buffer library.
- **[EMeshQueue](/packages/utils/eMeshQueue/README.md)**: A first come, first serve queue for creating editable meshes.
