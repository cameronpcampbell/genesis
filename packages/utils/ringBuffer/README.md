# RingBuffer

Circular buffer for Luau. Grows automatically when full and shrinks when sparsely used.

## Usage

```lua
local RingBuffer = require(ringBuffer)

local myRingBuffer = RingBuffer.New(8) -- initial capacity

myRingBuffer:Push("a")
myRingBuffer:Push("b")
myRingBuffer:Push("c")

print(myRingBuffer:Len())     -- 3
print(myRingBuffer:IsEmpty())  -- false

print(myRingBuffer:At(1))  -- "a"
print(myRingBuffer:At(3))  -- "c"

myRingBuffer:Discard(2)
print(myRingBuffer:Pop())  -- "c"
print(myRingBuffer:Pop())  -- nil (empty)
```

## API

### `RingBuffer.New(capacity: number) -> RingBuffer<T>`

| Parameter | Type | Description |
| --------- | ---- | ----------- |
| capacity | `number` | Initial buffer size. Must be >= 1. Also acts as the minimum capacity the buffer will shrink to. |

### `ringBuffer:Push(value: T)`
Appends a value to the back of the buffer.

### `ringBuffer:Pop() -> T?`
Removes and returns the value at the front of the buffer, or `nil` if the buffer is empty.

### `ringBuffer:At(idx: number) -> T`
Returns the value at logical position `idx`, where `idx = 1` is the front. `idx` must be in `[1, ringBuffer:Len()]`.

### `ringBuffer:Discard(n: number)`
Drops the first `n` values from the front. No-op when `n <= 0`. If `n` exceeds the current length, the buffer is emptied.

### `ringBuffer:IsEmpty() -> boolean`
Returns `true` when the buffer contains no values.

### `ringBuffer:Len() -> number`
Returns the number of values currently in the buffer.
