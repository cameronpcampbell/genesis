--!strict
--!native

local Pool = require(script.Parent.utils.pool)

const DEFAULT_SPLIT_FACTOR = 1.0
const DEFAULT_SURFACE_FACTOR = 1.5155

const NODE_POOL_MIN = 64
const NODE_POOL_MAX = 4096
const CHILDREN_POOL_MIN = 16
const CHILDREN_POOL_MAX = 512

const VECTOR_ZERO = vector.create(0, 0, 0)

const OCTANT_OFFSETS = {
	vector.create(-1, -1, -1),
	vector.create( 1, -1, -1),
	vector.create(-1,  1, -1),
	vector.create( 1,  1, -1),
	vector.create(-1, -1,  1),
	vector.create( 1, -1,  1),
	vector.create(-1,  1,  1),
	vector.create( 1,  1,  1),
}

export type Sample = (center: vector) -> number

export type StrataConfig = {
	RootCenter: vector,
	BaseLeafSize: number,
	LodAmount: number,
	SplitFactor: number?,
	SurfaceFactor: number?,
	Sample: Sample,
}

export type Diff = {
	Created: { { vector } },
	CreatedSizes: { vector },
	Destroyed: { vector },
}

export type Stats = {
	Leaves: number,
	Nodes: number,
	LeavesBySize: { [number]: number },
}

type Node = {
	Center: vector,
	Size: number,
	SizeVector: vector,
	IsLeaf: boolean,
	IsRendered: boolean,
	Children: { Node }?,
}

export type Strata = {
	Root: Node,
	BaseLeafSize: number,
	SplitFactor: number,
	SurfaceFactor: number,
	Sample: Sample,
	LastTarget: vector?,
	LevelOffsets: { [number]: { vector } },
	SharedSizeVectors: { [number]: vector },
	BucketIncluded: { [number]: number },
	NodePool: Pool.Pool<Node>,
	ChildrenPool: Pool.Pool<{ Node }>,
	TraversalStack: { Node },
	SDFStack: { number },
	CollapseStack: { Node },
	SetTarget: (self: Strata, target: vector) -> Diff?,
	Destroy: (self: Strata) -> { vector },
	Stats: (self: Strata, accumulator: Stats?) -> Stats,
	Collect: (
		self: Strata,
		positionGroups: { { vector } },
		sizes: { vector },
		bucketIncluded: { [number]: number }
	) -> (),
}

const function NewNodeForPool(): Node
	return {
		Center = VECTOR_ZERO,
		Size = 0,
		SizeVector = VECTOR_ZERO,
		IsLeaf = true,
		IsRendered = false,
		Children = nil,
	}
end

const function NewChildrenForPool(): { Node }
	return table.create(8) :: { Node }
end

const function ResetNodes(nodes: { Node })
	for _, node in nodes do
		node.IsLeaf = true
		node.IsRendered = false
		node.Children = nil
	end
end

const function AcquireNode(self: Strata, center: vector, size: number): Node
	local node = self.NodePool:Take()
	node.Center = center
	node.Size = size
	node.SizeVector = self.SharedSizeVectors[size]
	return node
end

const function CollapseSubtree(self: Strata, parent: Node, destroyed: { vector }, count: number): number
	local parentChildren = parent.Children
	if parentChildren == nil then
		parent.IsLeaf = true
		return count
	end

	local nodePool = self.NodePool
	local childrenPool = self.ChildrenPool
	local stack = self.CollapseStack

	local stackTop = 0
	for idx = 1, 8 do
		stackTop += 1
		stack[stackTop] = parentChildren[idx]
	end

	childrenPool:Release(parentChildren)
	parent.Children = nil
	parent.IsLeaf = true

	while stackTop > 0 do
		local node = stack[stackTop]
		stack[stackTop] = nil
		stackTop -= 1

		if node.IsLeaf then
			if node.IsRendered then
				count += 1
				destroyed[count] = node.Center
			end

			nodePool:Release(node)

			continue
		end

		local nodeChildren = node.Children
		if nodeChildren then
			for idx = 1, 8 do
				stackTop += 1
				stack[stackTop] = nodeChildren[idx]
			end

			childrenPool:Release(nodeChildren)
		end

		nodePool:Release(node)
	end

	return count
end

const function CollectAllRendered(root: Node, out: { vector }, stack: { Node }): { vector }
	local stackTop = 1
	stack[1] = root
	local count = #out

	while stackTop > 0 do
		local node = stack[stackTop]
		stack[stackTop] = nil
		stackTop -= 1

		if node.IsLeaf then
			if node.IsRendered then
				count += 1
				out[count] = node.Center
				node.IsRendered = false
			end

			continue
		end

		local children = node.Children
		if not children then continue end

		for idx = 1, 8 do
			stackTop += 1
			stack[stackTop] = children[idx]
		end
	end

	return out
end

const function SetTarget(self: Strata, target: vector): Diff?
	debug.profilebegin("Strata/SetTarget")

	local baseLeafSize = self.BaseLeafSize
	local invBaseLeaf = 1 / baseLeafSize
	target = vector.create(
		math.round(target.x * invBaseLeaf) * baseLeafSize,
		math.round(target.y * invBaseLeaf) * baseLeafSize,
		math.round(target.z * invBaseLeaf) * baseLeafSize
	)

	local lastTarget = self.LastTarget
	if lastTarget ~= nil and target == lastTarget then
		debug.profileend()
		return nil
	end

	self.LastTarget = target

	local bucketIncluded = self.BucketIncluded
	local sharedSizeVectors = self.SharedSizeVectors

	local created: { { vector } } = {}
	local createdSizes: { vector } = {}
	local destroyed: { vector } = {}
	table.clear(bucketIncluded)

	local diff: Diff = { Created = created, CreatedSizes = createdSizes, Destroyed = destroyed }

	local splitFactor, levelOffsets = self.SplitFactor, self.LevelOffsets
	local surfaceFactor = self.SurfaceFactor
	local sample = self.Sample
	local childrenPool = self.ChildrenPool

	local stack = self.TraversalStack
	local sdfStack = self.SDFStack

	local nGroups = 0
	local nDestroyed = 0

	stack[1] = self.Root
	sdfStack[1] = sample(self.Root.Center)
	local stackTop = 1

	while stackTop > 0 do
		local node = stack[stackTop]
		local sdf = sdfStack[stackTop]

		stack[stackTop] = nil
		stackTop -= 1

		local center, size = node.Center, node.Size

		if math.abs(sdf) >= size * surfaceFactor then
			if not node.IsLeaf then
				nDestroyed = CollapseSubtree(self, node, destroyed, nDestroyed)

			elseif node.IsRendered then
				nDestroyed += 1
				destroyed[nDestroyed] = center
				node.IsRendered = false
			end

			continue
		end

		local invSize = 1 / size
		local snappedTarget = vector.create(
			math.round(target.x * invSize) * size,
			math.round(target.y * invSize) * size,
			math.round(target.z * invSize) * size
		)
		local delta = snappedTarget - center

		local maxAxis =
		    math.max(math.abs(delta.x), math.abs(delta.y), math.abs(delta.z))

		local shouldSplit = size > baseLeafSize and maxAxis < splitFactor * size

		if not shouldSplit then
			if not node.IsLeaf then
				nDestroyed = CollapseSubtree(self, node, destroyed, nDestroyed)
			end

			if not node.IsRendered then
				local groupIdx = bucketIncluded[size]

				if not groupIdx then
					nGroups += 1
					groupIdx = nGroups
					bucketIncluded[size] = groupIdx
					created[groupIdx] = {}
					createdSizes[groupIdx] = sharedSizeVectors[size]
				end

				local bucket = created[groupIdx]
				bucket[#bucket + 1] = center
				node.IsRendered = true
			end

			continue
		end

		if not node.IsLeaf then
			local children = node.Children :: { Node }

			for idx = 1, 8 do
				local child = children[idx]
				stackTop += 1
				stack[stackTop] = child
				sdfStack[stackTop] = sample(child.Center)
			end

			continue
		end

		if node.IsRendered then
			nDestroyed += 1
			destroyed[nDestroyed] = center
			node.IsRendered = false
		end

		local offs = levelOffsets[size] :: { vector }
		local childSize = size * 0.5
		local newChildren = childrenPool:Take()

		for idx = 1, 8 do
			local childCenter = center + offs[idx]
			local child = AcquireNode(self, childCenter, childSize)
			newChildren[idx] = child
			stackTop += 1
			stack[stackTop] = child
			sdfStack[stackTop] = sample(childCenter)
		end

		node.Children = newChildren
		node.IsLeaf = false
	end

	debug.profileend()

	return diff
end

const function Destroy(self: Strata): { vector }
	local out = {}

	CollectAllRendered(self.Root, out, self.TraversalStack)

	return out
end

const function Collect(
	self: Strata,
	positionGroups: { { vector } },
	sizes: { vector },
	bucketIncluded: { [number]: number }
)
	local sharedSizeVectors = self.SharedSizeVectors
	local stack = self.TraversalStack
	stack[1] = self.Root
	local stackTop = 1

	local nGroups = #positionGroups

	while stackTop > 0 do
		local node = stack[stackTop]
		stack[stackTop] = nil
		stackTop -= 1

		if node.IsLeaf then
			if node.IsRendered then
				local size = node.Size
				local groupIdx = bucketIncluded[size]
				if not groupIdx then
					nGroups += 1
					groupIdx = nGroups
					bucketIncluded[size] = groupIdx
					positionGroups[groupIdx] = {}
					sizes[groupIdx] = sharedSizeVectors[size]
				end

				local bucket = positionGroups[groupIdx]
				bucket[#bucket + 1] = node.Center
			end

			continue
		end

		local children = node.Children
		if not children then continue end

		for idx = 1, 8 do
			stackTop += 1
			stack[stackTop] = children[idx]
		end
	end
end

const function GetStats(self: Strata, accumulator: Stats?): Stats
	local stats = accumulator or {
		Leaves = 0,
		Nodes = 0,
		LeavesBySize = {},
	}

	local stack = self.TraversalStack
	stack[1] = self.Root
	local stackTop = 1

	while stackTop > 0 do
		local node = stack[stackTop]
		stack[stackTop] = nil
		stackTop -= 1

		stats.Nodes += 1

		if node.IsLeaf then
			if node.IsRendered then
				stats.Leaves += 1
				local size = node.Size
				stats.LeavesBySize[size] = (stats.LeavesBySize[size] or 0) + 1
			end

			continue
		end

		local children = node.Children
		if not children then continue end

		for idx = 1, 8 do
			stackTop += 1
			stack[stackTop] = children[idx]
		end
	end

	return stats
end

type LevelData = {
	LevelOffsets: { [number]: { vector } },
	SharedSizeVectors: { [number]: vector },
}

const function BuildLevelData(rootSize: number, baseLeafSize: number): LevelData
	local levelOffsets: { [number]: { vector } } = {}
	local sharedSizeVectors: { [number]: vector } = {}

	local size = rootSize
	while size > baseLeafSize do
		local quarter = size * 0.25
		local offs = table.create(8) :: { vector }

		for idx = 1, 8 do
			offs[idx] = OCTANT_OFFSETS[idx] * quarter
		end

		levelOffsets[size] = offs
		sharedSizeVectors[size] = vector.create(size, size, size)
		size = size * 0.5
	end

	sharedSizeVectors[size] = vector.create(size, size, size)

	return {
		LevelOffsets = levelOffsets,
		SharedSizeVectors = sharedSizeVectors,
	}
end

local _levelDataCache: { [number]: LevelData } = {}

const function CachedLevelData(rootSize: number, baseLeafSize: number): LevelData
	local key = rootSize * 65536 + baseLeafSize

	local cached = _levelDataCache[key]
	if cached then return cached end

	cached = BuildLevelData(rootSize, baseLeafSize)
	_levelDataCache[key] = cached

	return cached
end

local Strata = {}

function Strata.New(config: StrataConfig): Strata
	local baseLeafSize = config.BaseLeafSize
	local rootSize = baseLeafSize * 2 ^ (config.LodAmount - 1)
	local levelData = CachedLevelData(rootSize, baseLeafSize)
	local sharedSizeVectors = levelData.SharedSizeVectors

	local nodePool = Pool.New({
		Constructor = NewNodeForPool,
		Reset = ResetNodes,
		MinSize = NODE_POOL_MIN,
		MaxSize = NODE_POOL_MAX,
	})

	local childrenPool = Pool.New({
		Constructor = NewChildrenForPool,
		MinSize = CHILDREN_POOL_MIN,
		MaxSize = CHILDREN_POOL_MAX,
	})

	local root = nodePool:Take()
	root.Center = config.RootCenter
	root.Size = rootSize
	root.SizeVector = sharedSizeVectors[rootSize]

	return {
		Root = root,
		BaseLeafSize = baseLeafSize,
		SplitFactor = config.SplitFactor or DEFAULT_SPLIT_FACTOR,
		SurfaceFactor = config.SurfaceFactor or DEFAULT_SURFACE_FACTOR,
		Sample = config.Sample,
		LastTarget = nil,
		LevelOffsets = levelData.LevelOffsets,
		SharedSizeVectors = sharedSizeVectors,
		BucketIncluded = {},
		NodePool = nodePool,
		ChildrenPool = childrenPool,
		TraversalStack = table.create(64) :: { Node },
		SDFStack = table.create(64, 0) :: { number },
		CollapseStack = table.create(64) :: { Node },
		SetTarget = SetTarget,
		Destroy = Destroy,
		Stats = GetStats,
		Collect = Collect,
	}
end

return Strata
