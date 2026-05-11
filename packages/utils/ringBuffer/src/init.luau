--!strict
--!native

export type RingBuffer<T> = {
	Buffer: { T },
	Head: number,
	Tail: number,
	Count: number,
	Capacity: number,
	MinCapacity: number,

	Push: (self: RingBuffer<T>, value: T) -> (),
	Pop: (self: RingBuffer<T>) -> T?,
	At: (self: RingBuffer<T>, idx: number) -> T,
	Discard: (self: RingBuffer<T>, n: number) -> (),
	IsEmpty: (self: RingBuffer<T>) -> boolean,
	Len: (self: RingBuffer<T>) -> number,
}

const function Resize<T>(self: RingBuffer<T>, newCapacity: number)
	local buffer, capacity, head, count = self.Buffer, self.Capacity, self.Head, self.Count

	local newBuffer = table.create(newCapacity)
	local firstSegLen = math.min(count, capacity - head + 1)
	table.move(buffer, head, head + firstSegLen - 1, 1, newBuffer)

	if firstSegLen < count then
		table.move(buffer, 1, count - firstSegLen, firstSegLen + 1, newBuffer)
	end

	self.Buffer = newBuffer
	self.Head = 1
	self.Tail = if count == newCapacity then 1 else count + 1
	self.Capacity = newCapacity
end

const function Push<T>(self: RingBuffer<T>, value: T)
	if self.Count == self.Capacity then
		Resize(self, self.Capacity * 2)
	end

	local tail = self.Tail

	self.Buffer[tail] = value
	self.Tail = if tail == self.Capacity then 1 else tail + 1
	self.Count += 1
end

const function Pop<T>(self: RingBuffer<T>): T?
	if self.Count == 0 then return nil end

	local head = self.Head
	local value = self.Buffer[head]

	self.Buffer[head] = nil :: any
	self.Head = if head == self.Capacity then 1 else head + 1

	local newCount = self.Count - 1
	self.Count = newCount

	local capacity = self.Capacity
	if capacity > self.MinCapacity and newCount <= capacity / 4 then
		Resize(self, math.max(self.MinCapacity, math.floor(capacity / 2)))
	end

	return value
end

const function At<T>(self: RingBuffer<T>, idx: number): T
	local pos = (self.Head - 1 + idx - 1) % self.Capacity + 1
	return self.Buffer[pos]
end

const function Discard<T>(self: RingBuffer<T>, n: number)
	if n <= 0 then return end

	local count = self.Count
	local toDrop = if n < count then n else count

	local buf = self.Buffer
	local head = self.Head
	local capacity = self.Capacity

	local firstSegLen = math.min(toDrop, capacity - head + 1)
	for i = head, head + firstSegLen - 1 do
		buf[i] = nil :: any
	end
	if firstSegLen < toDrop then
		for i = 1, toDrop - firstSegLen do
			buf[i] = nil :: any
		end
	end

	local newHead = head + toDrop
	if newHead > capacity then newHead -= capacity end
	self.Head = newHead

	local newCount = count - toDrop
	self.Count = newCount

	if capacity > self.MinCapacity and newCount <= capacity / 4 then
		Resize(self, math.max(self.MinCapacity, math.floor(capacity / 2)))
	end
end

const function IsEmpty<T>(self: RingBuffer<T>): boolean
	return self.Count == 0
end

const function Len<T>(self: RingBuffer<T>): number
	return self.Count
end

const function New<T>(capacity: number): RingBuffer<T>
	if capacity < 1 then
		error("[RingBuffer] capacity must be >= 1")
	end

	return {
		Buffer = table.create(capacity),
		Head = 1,
		Tail = 1,
		Count = 0,
		Capacity = capacity,
		MinCapacity = capacity,
		Push = Push,
		Pop = Pop,
		At = At,
		Discard = Discard,
		IsEmpty = IsEmpty,
		Len = Len,
	}
end

return {
	New = New,
}
