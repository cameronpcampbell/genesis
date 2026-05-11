# EMeshQueue

First-come-first-served queue for `AssetService:CreateEditableMesh()`. Roblox limits how many editable meshes can be created per frame; this queue serializes requests so callers yield until a mesh is actually available instead of failing or busy-waiting.

## Usage

```luau
local EMeshQueue = require(eMeshQueue)

local queue = EMeshQueue.new()

-- Yields the calling thread until an EditableMesh is allocated.
local mesh = queue:Wait()
if mesh then
    -- Build geometry on `mesh`...
end

-- Yields with an optional timeout. Returns nil if the timeout elapses first.
local mesh = queue:Wait(0.5)

-- Tear down when you no longer need the queue.
queue:Destroy()
```

## API

### `EMeshQueue.new() -> EMeshQueue`

Creates a queue and connects to `RunService.Heartbeat`. Each frame the queue creates as many editable meshes as `AssetService` will allow and hands them out to waiting threads in arrival order.

### `queue:Wait(timeout: number?) -> EditableMesh?`

Yields the calling thread and returns an `EditableMesh` once one is allocated. If `timeout` is provided and the wait exceeds it, the thread resumes with `nil` and the slot is dropped from the queue.

### `queue:Destroy()`

Disconnects the heartbeat. Any threads still parked in `Wait` remain yielded, so drain or cancel your waiters first.
