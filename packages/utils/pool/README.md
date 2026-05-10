# Pool

Generic object pool for Luau with automatic sizing, bulk operations, and automatic compaction.

## Usage

```lua
local Pool = require(pool)

local myPool = Pool.New({
    MinSize = 16,
    MaxSize = 256,

    Constructor = function() return { Value = 0 } end,

    -- Optional, called on release.
    Reset = function(items)
        for _, item in items do item.Value = 0 end
    end,

    -- Optional, called when discarding excess.
    Destructor = function(items)
        for _, item in items do item.Value = nil end
    end,
})

-- Takes item from pool, constructs new item if pool is empty.
local item = myPool:Take()

-- Return an item to pool (calls Reset).
myPool:Release(item)
myPool:ReleaseBulk({ itemA, itemB })

local poolLen = myPool:Len()
```

## API

### `Pool.New(config: PoolConfig<T>) -> Pool<T>`

Creates a pool pre-filled to `MinSize`. The backing array grows by doubling up to `MaxSize`.

| Config Field | Type | Required | Description |
| ------------ | ---- | -------- | ----------- |
| Constructor | `() -> T` | yes | Creates a new instance |
| Reset | `({ T }) -> ()` | no | Cleans a batch of items before they re-enter the pool |
| Destructor | `({ T }) -> ()` | no | Tears down a batch of items that won't be reused |
| MinSize | `number` | yes | The pool never shrinks below this. |
| MaxSize | `number` | yes | Excess items are destroyed. |

### `pool:Take() -> T`

Returns a pooled item or calls `Constructor` if the pool is empty. Auto-compacts the pool when usage drops, destroying always-idle items and shrinking the backing array.

### `pool:Release(item: T)`

Returns an item to the pool. Calls `Reset` if provided. If the pool is at `MaxSize`, the item is passed to `Destructor` instead.

### `pool:ReleaseBulk(items: { T })`

Batch release. Accepts as many items as capacity allows, resets them, and destroys the rest.

### `pool:Len() -> number`

Returns the number of items currently in the pool.
