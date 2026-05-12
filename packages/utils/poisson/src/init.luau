--!strict
--!native

export type Node = {
	Radius: number,
	Weight: number,
	ChildSpawnRadius: number?,
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
	ChildSpawnRadii: { number },
	ClassIndices: { number },
	TotalWeight: number,
	ChildGroups: { Group? },
}

export type Poisson = {
	Nodes: { [string]: Node },
	TopGroup: Group,
	RMin: number,
	RMax: number,
	ClassRadii: { number },
	ClassCellSizes: { number },

	Sample: (self: Poisson, seed: number, size: vector) -> { Sample },
}

type BuildAccum = {
	Min: number,
	Max: number,
	ClassRadii: { number },
	ClassCellSizes: { number },
}

type SamplerState = {
	Points: { Sample },
	PointClassIndices: { number },
	PointChildSpawnRadii: { number },
	PointChildGroups: { Group? },
	PointParents: { number },

	ClassRadii: { number },
	ClassCellSizes: { number },
	ClassGridW: { number },
	ClassGridH: { number },
	ClassGrids: { { [number]: { number } } },
	ClassCounts: { number },

	SizeX: number,
	SizeY: number,
	Rng: Random,
}

const K = 30
const K_TOP = 4
const SEED_ATTEMPTS = 30
const INNER_EPSILON = 1.001
const SQRT_HALF = 0.7071067811865476
const TWO_PI = 6.283185307179586
const ANGLE_STEP_TOP = TWO_PI / K_TOP

const function BuildGroup(nodes: { [string]: Node }, accum: BuildAccum): Group
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
	local childSpawnRadii = table.create(count) :: { number }
	local classIndices = table.create(count) :: { number }
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

		local childSpawnRadius = node.ChildSpawnRadius
		if childSpawnRadius == nil then
			childSpawnRadius = radius

		elseif type(childSpawnRadius) ~= "number" or childSpawnRadius <= 0 then
			error("[Poisson] node '" .. name .. "' has invalid ChildSpawnRadius; must be a number > 0")
		end

		local globalIdx = #accum.ClassRadii + 1
		accum.ClassRadii[globalIdx] = radius
		accum.ClassCellSizes[globalIdx] = radius * SQRT_HALF

		names[idx] = name
		radii[idx] = radius
		weights[idx] = weight
		childSpawnRadii[idx] = childSpawnRadius
		classIndices[idx] = globalIdx
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
		ChildSpawnRadii = childSpawnRadii,
		ClassIndices = classIndices,
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

const function IsValid(state: SamplerState, px: number, py: number, candidateRadius: number, ignoreSet: { [number]: true }): boolean
	local classRadii = state.ClassRadii
	local classCellSizes = state.ClassCellSizes
	local classGridW = state.ClassGridW
	local classGridH = state.ClassGridH
	local classGrids = state.ClassGrids
	local classCounts = state.ClassCounts
	local points = state.Points
	local classCount = #classRadii

	for j = 1, classCount do
		if classCounts[j] == 0 then continue end

		local cellSize = classCellSizes[j]
		local gridW = classGridW[j]
		local gridH = classGridH[j]
		local otherRadius = classRadii[j]
		local minDist = candidateRadius + otherRadius
		local minDistSq = minDist * minDist
		local searchRadius = math.ceil(minDist / cellSize)

		local cx = math.floor(px / cellSize)
		local cy = math.floor(py / cellSize)

		local x0 = math.max(0, cx - searchRadius)
		local x1 = math.min(gridW - 1, cx + searchRadius)
		local y0 = math.max(0, cy - searchRadius)
		local y1 = math.min(gridH - 1, cy + searchRadius)

		local grid = classGrids[j]

		for y = y0, y1 do
			local rowBase = y * gridW
			for x = x0, x1 do
				local cell = grid[rowBase + x]
				if not cell then continue end

				for slotIdx = 1, #cell do
					local sampleIdx = cell[slotIdx]
					if ignoreSet[sampleIdx] then continue end

					local otherPos = points[sampleIdx].Position
					local dx = otherPos.x - px
					local dy = otherPos.y - py
					if dx * dx + dy * dy < minDistSq then
						return false
					end
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
	classIdx: number,
	childSpawnRadius: number,
	childGroup: Group?,
	parentIdx: number
): number
	local points = state.Points
	local idx = #points + 1

	points[idx] = { Position = vector.create(px, py), Name = name }
	state.PointClassIndices[idx] = classIdx
	state.PointChildSpawnRadii[idx] = childSpawnRadius
	state.PointChildGroups[idx] = childGroup
	state.PointParents[idx] = parentIdx

	state.ClassCounts[classIdx] += 1

	local cellSize = state.ClassCellSizes[classIdx]
	local gridW = state.ClassGridW[classIdx]
	local cx = math.floor(px / cellSize)
	local cy = math.floor(py / cellSize)
	local cellIdx = cy * gridW + cx

	local grid = state.ClassGrids[classIdx]
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
	local ignoreSet = BuildIgnoreSet(state.PointParents, parentIdx)

	if parentIdx ~= 0 then
		local failures = 0

		while failures < K do
			local localIdx = PickWeighted(rng, group)
			local radius = group.Radii[localIdx]
			local childSpawnRadius = group.ChildSpawnRadii[localIdx]
			local classIdx = group.ClassIndices[localIdx]
			local name = group.Names[localIdx]
			local childGroup = group.ChildGroups[localIdx]

			local u: number
			local v: number
			local r2: number
			repeat
				u = rng:NextNumber() * 2 - 1
				v = rng:NextNumber() * 2 - 1
				r2 = u * u + v * v
			until r2 <= 1

			local px = centerX + u * regionRadius
			local py = centerY + v * regionRadius

			if px < 0 or px >= sizeX or py < 0 or py >= sizeY then
				failures += 1
				continue
			end

			if not IsValid(state, px, py, radius, ignoreSet) then
				failures += 1
				continue
			end

			AddSample(state, px, py, name, classIdx, childSpawnRadius, childGroup, parentIdx)
			failures = 0
		end

		return
	end

	local active: { number } = {}
	local seeded = false

	for seedIdx = 1, SEED_ATTEMPTS do
		local localIdx = PickWeighted(rng, group)
		local radius = group.Radii[localIdx]
		local childSpawnRadius = group.ChildSpawnRadii[localIdx]
		local classIdx = group.ClassIndices[localIdx]
		local name = group.Names[localIdx]
		local childGroup = group.ChildGroups[localIdx]

		local px = rng:NextNumber() * sizeX
		local py = rng:NextNumber() * sizeY

		if not IsValid(state, px, py, radius, ignoreSet) then continue end

		local idx = AddSample(state, px, py, name, classIdx, childSpawnRadius, childGroup, parentIdx)
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
		local sampleRadius = state.ClassRadii[state.PointClassIndices[sampleIdx]]
		local sx = samplePos.x
		local sy = samplePos.y

		local placed = false
		local baseAngle = rng:NextNumber() * TWO_PI

		for candIdx = 0, K_TOP - 1 do
			local localIdx = PickWeighted(rng, group)
			local radius = group.Radii[localIdx]
			local childSpawnRadius = group.ChildSpawnRadii[localIdx]
			local classIdx = group.ClassIndices[localIdx]
			local name = group.Names[localIdx]
			local childGroup = group.ChildGroups[localIdx]

			local innerDist = (sampleRadius + radius) * INNER_EPSILON
			local angle = baseAngle + candIdx * ANGLE_STEP_TOP

			local px = sx + math.cos(angle) * innerDist
			local py = sy + math.sin(angle) * innerDist

			if px < 0 or px >= sizeX or py < 0 or py >= sizeY then continue end

			if not IsValid(state, px, py, radius, ignoreSet) then continue end

			local idx = AddSample(state, px, py, name, classIdx, childSpawnRadius, childGroup, parentIdx)
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

	local classRadii = self.ClassRadii
	local classCellSizes = self.ClassCellSizes
	local classCount = #classRadii

	local classGridW = table.create(classCount) :: { number }
	local classGridH = table.create(classCount) :: { number }
	local classGrids = table.create(classCount) :: { { [number]: { number } } }
	local classCounts = table.create(classCount) :: { number }

	for j = 1, classCount do
		local cellSize = classCellSizes[j]
		classGridW[j] = math.ceil(sizeX / cellSize)
		classGridH[j] = math.ceil(sizeY / cellSize)
		classGrids[j] = {}
		classCounts[j] = 0
	end

	local state: SamplerState = {
		Points = {},
		PointClassIndices = {},
		PointChildSpawnRadii = {},
		PointChildGroups = {},
		PointParents = {},

		ClassRadii = classRadii,
		ClassCellSizes = classCellSizes,
		ClassGridW = classGridW,
		ClassGridH = classGridH,
		ClassGrids = classGrids,
		ClassCounts = classCounts,

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
			local spawnRadius = state.PointChildSpawnRadii[idx]
			BridsonPass(state, childGroup, position.x, position.y, spawnRadius, idx)
		end
		idx += 1
	end

	return state.Points
end

const function New(config: Config): Poisson
	local accum: BuildAccum = {
		Min = math.huge,
		Max = 0,
		ClassRadii = {},
		ClassCellSizes = {},
	}
	local topGroup = BuildGroup(config, accum)

	return {
		Nodes = config,
		TopGroup = topGroup,
		RMin = accum.Min,
		RMax = accum.Max,
		ClassRadii = accum.ClassRadii,
		ClassCellSizes = accum.ClassCellSizes,
		Sample = Sample,
	}
end

return {
	new = New,
}
