--!strict
--!native

local AssetService = game:GetService("AssetService")
local RunService = game:GetService("RunService")

local RingBuffer = require(script.Parent.Parent.utils.ringBuffer)
type RingBuffer<T> = RingBuffer.RingBuffer<T>

const INITIAL_CAPACITY = 8

export type EMeshQueue = {
	Queue: RingBuffer<thread>,
	Cancelled: { [thread]: true },
	Connection: RBXScriptConnection,

	Wait: (self: EMeshQueue, timeout: number?) -> EditableMesh?,
	Destroy: (self: EMeshQueue) -> (),
}

const function DrainCancelled(self: EMeshQueue)
	local queue, cancelled = self.Queue, self.Cancelled

	while not queue:IsEmpty() do
		local front = queue.Buffer[queue.Head]

		if not cancelled[front] then break end

		queue:Pop()
		cancelled[front] = nil
	end
end

const function Wait(self: EMeshQueue, timeout: number?): EditableMesh?
	local thread = coroutine.running()
	self.Queue:Push(thread)

	if timeout then
		task.delay(timeout, function()
			if self.Cancelled[thread] then return end

			self.Cancelled[thread] = true
			coroutine.resume(thread, nil)
		end)
	end

	return coroutine.yield()
end

const function Destroy(self: EMeshQueue)
	self.Connection:Disconnect()
end

const function New(): EMeshQueue
	local self: EMeshQueue = {
		Queue = RingBuffer.New<<thread>>(INITIAL_CAPACITY),
		Cancelled = {},
		Connection = nil :: any,
		Wait = Wait,
		Destroy = Destroy,
	}

	self.Connection = RunService.Heartbeat:Connect(function()
		while true do
			DrainCancelled(self)
			if self.Queue:IsEmpty() then return end

			local eMesh = AssetService:CreateEditableMesh()
			if not eMesh then return end

			local thread = self.Queue:Pop() :: thread
			coroutine.resume(thread, eMesh)
		end
	end)

	return self
end

return {
	new = New,
}
