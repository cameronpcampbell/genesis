--!strict
--!native

export type PoolConfig<T> = {
	Constructor: () -> T,
	Reset: ((items: { T }) -> ())?,
	Destructor: ((items: { T }) -> ())?,
	MinSize: number,
	MaxSize: number,
}

export type Pool<T> = {
	Constructor: () -> T,
	Reset: ((items: { T }) -> ())?,
	Destructor: ((items: { T }) -> ())?,
	MinSize: number,
	MaxSize: number,
	Items: { T },
	CallbackBuffer: { T },
	Capacity: number,
	Count: number,
	LowWaterMark: number,

	Take: (self: Pool<T>) -> T,
	Release: (self: Pool<T>, item: T) -> (),
	ReleaseBulk: (self: Pool<T>, items: { T }) -> (),
	Len: (self: Pool<T>) -> number,
}

const function Resize<T>(self: Pool<T>, newCapacity: number)
	local items, count = self.Items, self.Count
	local newItems = table.create(newCapacity) :: { T }

	table.move(items, 1, count, 1, newItems)

	self.Items = newItems
	self.Capacity = newCapacity
end

const function InvokeBuffered<T>(self: Pool<T>, callback: (items: { T }) -> (), source: { T }, start: number, finish: number)
	local callbackBuffer = self.CallbackBuffer
	local count = finish - start + 1

	table.move(source, start, finish, 1, callbackBuffer)

	callback(callbackBuffer)

	for idx = 1, count do
		callbackBuffer[idx] = nil :: any
	end
end

const function InvokeBufferedSingle<T>(self: Pool<T>, callback: (items: { T }) -> (), item: T)
	local callbackBuffer = self.CallbackBuffer
	callbackBuffer[1] = item

	callback(callbackBuffer)

	callbackBuffer[1] = nil :: any
end

const function Cleanup<T>(self: Pool<T>, idleSlack: number)
	debug.profilebegin("Pool/Cleanup")

	local count = self.Count
	local minSize = self.MinSize

	local drop = math.min(idleSlack, count - minSize)
	if drop > 0 then
		local items = self.Items
		local destructor = self.Destructor
		local newCount = count - drop

		if destructor then
			InvokeBuffered(self, destructor, items, newCount + 1, count)
		end

		for idx = newCount + 1, count do
			items[idx] = nil :: any
		end

		count = newCount
		self.Count = count
	end

	self.LowWaterMark = count

	local capacity = self.Capacity
	local minCapacity = math.max(minSize, 1)

	if capacity > minCapacity and count <= capacity / 4 then
		local newCapacity = math.max(minCapacity, math.floor(capacity / 2))

		if newCapacity < capacity then
			Resize(self, newCapacity)
		end
	end

	debug.profileend()
end

const function TryCleanup<T>(self: Pool<T>)
	local idleSlack = self.Count - self.LowWaterMark

	if idleSlack > 0 and self.Capacity > self.MinSize then
		Cleanup(self, idleSlack)
	end
end

const function Take<T>(self: Pool<T>): T
	debug.profilebegin("Pool/Take")

	local count = self.Count
	if count == 0 then
		local item = self.Constructor()

		debug.profileend()

		return item
	end

	local item = self.Items[count]
	self.Items[count] = nil :: any

	local newCount = count - 1
	self.Count = newCount

	if newCount < self.LowWaterMark then
		self.LowWaterMark = newCount
	end

	debug.profileend()

	return item
end

const function Release<T>(self: Pool<T>, item: T)
	debug.profilebegin("Pool/Release")

	local count = self.Count
	if count >= self.MaxSize then
		local destructor = self.Destructor

		if destructor then
			InvokeBufferedSingle(self, destructor, item)
		end

		debug.profileend()

		return
	end

	if count == self.Capacity then
		local newCapacity = math.min(self.MaxSize, self.Capacity * 2)
		Resize(self, newCapacity)
	end

	local reset = self.Reset
	if reset then
		InvokeBufferedSingle(self, reset, item)
	end

	count += 1
	self.Count = count
	self.Items[count] = item

	TryCleanup(self)

	debug.profileend()
end

const function ReleaseBulk<T>(self: Pool<T>, items: { T })
	local itemCount = #items
	if itemCount == 0 then return end

	debug.profilebegin("Pool/ReleaseBulk")

	local poolCount, maxSize = self.Count, self.MaxSize
	local accept = math.min(itemCount, maxSize - poolCount)
	local destructor = self.Destructor
	local reset = self.Reset

	if accept <= 0 then
		if destructor then destructor(items) end

		debug.profileend()

		return
	end

	local capacity = self.Capacity
	local needed = poolCount + accept
	if needed > capacity then
		local target = capacity
		while target < needed do
			target = math.min(maxSize, target * 2)
		end
		Resize(self, target)
	end

	if reset then
		if accept == itemCount then
			reset(items)

		else
			InvokeBuffered(self, reset, items, 1, accept)
		end
	end

	table.move(items, 1, accept, poolCount + 1, self.Items)
	local newPoolCount = poolCount + accept
	self.Count = newPoolCount

	TryCleanup(self)

	if destructor and accept < itemCount then
		InvokeBuffered(self, destructor, items, accept + 1, itemCount)
	end

	debug.profileend()
end

const function Len<T>(self: Pool<T>): number
	return self.Count
end

const function New<T>(config: PoolConfig<T>): Pool<T>
	local minSize = config.MinSize
	local maxSize = config.MaxSize

	if minSize < 0 then
		warn("[Pool] MinSize must be >= 0, clamping to 0 (was " .. tostring(minSize) .. ")")
		minSize = 0
	end

	if maxSize < minSize then
		warn("[Pool] MaxSize must be >= MinSize, clamping to MinSize=" .. tostring(minSize) .. " (was " .. tostring(maxSize) .. ")")
		maxSize = minSize
	end

	local capacity = math.max(minSize, 1)
	local items = table.create(capacity) :: { T }
	local constructor = config.Constructor
	local reset = config.Reset

	for idx = 1, minSize do
		items[idx] = constructor()
	end

	if reset and minSize > 0 then
		reset(items)
	end

	return {
		Constructor = constructor,
		Reset = reset,
		Destructor = config.Destructor,
		MinSize = minSize,
		MaxSize = maxSize,
		Items = items,
		CallbackBuffer = table.create(8) :: { T },
		Capacity = capacity,
		Count = minSize,
		LowWaterMark = minSize,
		Take = Take,
		Release = Release,
		ReleaseBulk = ReleaseBulk,
		Len = Len,
	}
end

return {
	New = New,
}
