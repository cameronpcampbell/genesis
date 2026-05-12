--!strict
--!native

export type Node = {
	Radius: number,
	Weight: number,
	Children: { [string]: Node }?,
}

export type Config = { [string]: Node }

export type Sample = {
	Position: vector,
	Name: string,
}

export type Group = {
	Names: { string },
	Radii: { number },
	Weights: { number },
	TotalWeight: number,
	ChildGroups: { Group? },
}

export type Poisson = {
	Nodes: { [string]: Node },
	TopGroup: Group,
	RMin: number,
	RMax: number,

	Sample: (self: Poisson, seed: number, size: vector) -> { Sample },
}

type SamplerState = {
	Points: { Sample },
	PointRadii: { number },
	PointChildGroups: { Group? },
	PointParents: { number },
	Grid: { [number]: { number } },
	GridW: number,
	GridH: number,
	CellSize: number,
	RMax: number,
	SizeX: number,
	SizeY: number,
	Rng: Random,
}

const K = 30
const SEED_ATTEMPTS = 30
const SQRT_HALF = 0.7071067811865476
const TWO_PI = 6.283185307179586

const function BuildGroup(nodes: { [string]: Node }, accum: { Min: number, Max: number }): Group
	local keys = {}
	for name in pairs(nodes) do
		keys[#keys + 1] = name
	end
	table.sort(keys)

	local count = #keys
	if count == 0 then
		error("[Poisson] node group is empty")
	end

	local names = table.create(count) :: { string }
	local radii = table.create(count) :: { number }
	local weights = table.create(count) :: { number }
	local childGroups = table.create(count) :: { Group? }
	local totalWeight = 0

	for idx = 1, count do
		local name = keys[idx]
		local node = nodes[name]
		local radius = node.Radius
		local weight = node.Weight

		if type(radius) ~= "number" or radius <= 0 then
			error("[Poisson] node '" .. name .. "' has invalid Radius; must be a number > 0")
		end

		if type(weight) ~= "number" or weight <= 0 then
			error("[Poisson] node '" .. name .. "' has invalid Weight; must be a number > 0")
		end

		names[idx] = name
		radii[idx] = radius
		weights[idx] = weight
		totalWeight += weight

		if radius < accum.Min then accum.Min = radius end
		if radius > accum.Max then accum.Max = radius end

		local children = node.Children
		if children and next(children) then
			childGroups[idx] = BuildGroup(children, accum)
		end
	end

	return {
		Names = names,
		Radii = radii,
		Weights = weights,
		TotalWeight = totalWeight,
		ChildGroups = childGroups,
	}
end

const function PickWeighted(rng: Random, group: Group): number
	local weights = group.Weights
	local count = #weights
	local pick = rng:NextNumber() * group.TotalWeight
	local acc = 0

	for idx = 1, count do
		acc += weights[idx]
		if pick <= acc then
			return idx
		end
	end

	return count
end

const function BuildIgnoreSet(pointParents: { number }, parentIdx: number): { [number]: true }
	local set: { [number]: true } = {}
	local current = parentIdx

	while current ~= 0 do
		set[current] = true
		current = pointParents[current]
	end

	return set
end

const function IsValid(state: SamplerState, px: number, py: number, radius: number, ignoreSet: { [number]: true }): boolean
	local cellSize = state.CellSize
	local gridW = state.GridW
	local gridH = state.GridH
	local rMax = state.RMax
	local grid = state.Grid
	local points = state.Points
	local pointRadii = state.PointRadii

	local cx = math.floor(px / cellSize)
	local cy = math.floor(py / cellSize)
	local searchRadius = math.ceil((radius + rMax) / cellSize)

	local x0 = math.max(0, cx - searchRadius)
	local x1 = math.min(gridW - 1, cx + searchRadius)
	local y0 = math.max(0, cy - searchRadius)
	local y1 = math.min(gridH - 1, cy + searchRadius)

	for y = y0, y1 do
		local rowBase = y * gridW
		for x = x0, x1 do
			local cell = grid[rowBase + x]
			if not cell then continue end

			for slotIdx = 1, #cell do
				local sampleIdx = cell[slotIdx]
				if ignoreSet[sampleIdx] then continue end

				local otherPos = points[sampleIdx].Position
				local otherRadius = pointRadii[sampleIdx]
				local dx = otherPos.x - px
				local dy = otherPos.y - py
				local minDist = radius + otherRadius
				if dx * dx + dy * dy < minDist * minDist then
					return false
				end
			end
		end
	end

	return true
end

const function AddSample(
	state: SamplerState,
	px: number,
	py: number,
	name: string,
	radius: number,
	childGroup: Group?,
	parentIdx: number
): number
	local points = state.Points
	local idx = #points + 1

	points[idx] = { Position = vector.create(px, py), Name = name }
	state.PointRadii[idx] = radius
	state.PointChildGroups[idx] = childGroup
	state.PointParents[idx] = parentIdx

	local cellSize = state.CellSize
	local gridW = state.GridW
	local cx = math.floor(px / cellSize)
	local cy = math.floor(py / cellSize)
	local cellIdx = cy * gridW + cx

	local grid = state.Grid
	local cell = grid[cellIdx]
	if cell then
		cell[#cell + 1] = idx

	else
		grid[cellIdx] = { idx }
	end

	return idx
end

const function BridsonPass(
	state: SamplerState,
	group: Group,
	centerX: number,
	centerY: number,
	regionRadius: number,
	parentIdx: number
)
	local rng = state.Rng
	local sizeX = state.SizeX
	local sizeY = state.SizeY
	local isDisc = regionRadius > 0
	local discRadiusSq = regionRadius * regionRadius
	local ignoreSet = BuildIgnoreSet(state.PointParents, parentIdx)

	local active: { number } = {}
	local seeded = false

	for seedIdx = 1, SEED_ATTEMPTS do
		local classIdx = PickWeighted(rng, group)
		local radius = group.Radii[classIdx]
		local name = group.Names[classIdx]
		local childGroup = group.ChildGroups[classIdx]

		local px: number
		local py: number

		if isDisc then
			local angle = rng:NextNumber() * TWO_PI
			local r = regionRadius * math.sqrt(rng:NextNumber())
			px = centerX + math.cos(angle) * r
			py = centerY + math.sin(angle) * r

		else
			px = rng:NextNumber() * sizeX
			py = rng:NextNumber() * sizeY
		end

		if px < 0 or px >= sizeX or py < 0 or py >= sizeY then continue end

		if not IsValid(state, px, py, radius, ignoreSet) then continue end

		local idx = AddSample(state, px, py, name, radius, childGroup, parentIdx)
		active[#active + 1] = idx
		seeded = true
		break
	end

	if not seeded then return end

	while #active > 0 do
		local activeLen = #active
		local activeIdx = rng:NextInteger(1, activeLen)
		local sampleIdx = active[activeIdx]
		local samplePos = state.Points[sampleIdx].Position
		local sampleRadius = state.PointRadii[sampleIdx]
		local sx = samplePos.x
		local sy = samplePos.y

		local placed = false

		for candidateIdx = 1, K do
			local classIdx = PickWeighted(rng, group)
			local radius = group.Radii[classIdx]
			local name = group.Names[classIdx]
			local childGroup = group.ChildGroups[classIdx]

			local minDist = sampleRadius + radius
			local minDistSq = minDist * minDist
			local maxDistSq = 4 * minDistSq
			local distSq = minDistSq + (maxDistSq - minDistSq) * rng:NextNumber()
			local distance = math.sqrt(distSq)
			local angle = rng:NextNumber() * TWO_PI

			local px = sx + math.cos(angle) * distance
			local py = sy + math.sin(angle) * distance

			if px < 0 or px >= sizeX or py < 0 or py >= sizeY then continue end

			if isDisc then
				local dx = px - centerX
				local dy = py - centerY
				if dx * dx + dy * dy > discRadiusSq then continue end
			end

			if not IsValid(state, px, py, radius, ignoreSet) then continue end

			local idx = AddSample(state, px, py, name, radius, childGroup, parentIdx)
			active[#active + 1] = idx
			placed = true
			break
		end

		if not placed then
			active[activeIdx] = active[activeLen]
			active[activeLen] = nil
		end
	end
end

const function Sample(self: Poisson, seed: number, size: vector): { Sample }
	local sizeX = size.x
	local sizeY = size.y

	if sizeX <= 0 or sizeY <= 0 then
		return {}
	end

	local rMin = self.RMin
	local rMax = self.RMax
	local cellSize = rMin * SQRT_HALF
	local gridW = math.ceil(sizeX / cellSize)
	local gridH = math.ceil(sizeY / cellSize)

	local state: SamplerState = {
		Points = {},
		PointRadii = {},
		PointChildGroups = {},
		PointParents = {},
		Grid = {},
		GridW = gridW,
		GridH = gridH,
		CellSize = cellSize,
		RMax = rMax,
		SizeX = sizeX,
		SizeY = sizeY,
		Rng = Random.new(seed),
	}

	BridsonPass(state, self.TopGroup, 0, 0, 0, 0)

	local idx = 1
	while idx <= #state.Points do
		local childGroup = state.PointChildGroups[idx]
		if childGroup then
			local position = state.Points[idx].Position
			local radius = state.PointRadii[idx]
			BridsonPass(state, childGroup, position.x, position.y, radius, idx)
		end
		idx += 1
	end

	return state.Points
end

const function New(config: Config): Poisson
	local accum = { Min = math.huge, Max = 0 }
	local topGroup = BuildGroup(config, accum)

	return {
		Nodes = config,
		TopGroup = topGroup,
		RMin = accum.Min,
		RMax = accum.Max,
		Sample = Sample,
	}
end

return {
	new = New,
}
