--!strict
--!native
--!nolint LocalShadow

local AssetService = game:GetService("AssetService")

local EMeshQueue = require(script.Parent.Parent.Parent.utils.eMeshQueue)
local Poisson = require(script.Parent.Parent.Parent.utils.poisson)
const LOOKUP_TABLE = require(script.lookupTable)

const MOVE_RIGHT = 1
const EMPTY_TABLE = {}
const VEGETATION_SEED_X = 73856093
const VEGETATION_SEED_Z = 19349663

export type MarchingCubesConfig = {
    Resolution: number?,
    IsoValue: number?,
    Seed: number?,
    Octaves: number?,
    Lacunarity: number?,
    Persistence: number?,
    Scale: number?,
    Amplitude: number?,
    Vegetation: Poisson.Config?,
}

type ValuesTable = { number }

const LOD_COLORS = {
	Color3.fromRGB(255, 80, 80),
	Color3.fromRGB(255, 180, 60),
	Color3.fromRGB(50, 240, 80),
	Color3.fromRGB(45, 180, 150),
	Color3.fromRGB(40, 90, 200),
	Color3.fromRGB(120, 140, 255),
	Color3.fromRGB(220, 120, 255),
}

-- Flattened (edge -> 2 corner indexes) so we avoid an inner table per edge lookup.
const MIDPOINT_PARENTS_FLAT = {
	1, 2,  2, 3,  3, 4,  4, 1,
	5, 6,  6, 7,  7, 8,  8, 5,
	1, 5,  2, 6,  3, 7,  4, 8,
}

type Bounds = {
	MinX: number, MinY: number, MinZ: number,
	MaxX: number, MaxY: number, MaxZ: number,
}

const function FractalNoise(
    x: number, y: number, z: number,
    octaves: number, lacunarity: number, persistence: number,
    scale: number
)
	local x1: number, y1: number, z1: number = x, y, z
	local value, amplitude = 0, 1
	for i = 1, octaves do
		value += math.noise(x1 / scale, y1 / scale, z1 / scale) * amplitude
		y1 *= lacunarity
		x1 *= lacunarity
		z1 *= lacunarity
		amplitude *= persistence
	end
	return value
end

const function SurfaceNoise(
    x: number, y: number, z: number,
    octaves: number, lacunarity: number, persistence: number,
    scale: number, seed: number, isoValue: number, amplitude: number
)
	return FractalNoise(
	    x, z, seed,
	    octaves, lacunarity, persistence, scale
	) + ((y * amplitude) - isoValue)
end

const function MarchingCubes(
    eMesh: EditableMesh, values: ValuesTable,
    isoValue: number, voxelResOuter: number, chunkVoxelCount: number,
    offsetA: number, offsetB: number, offsetC: number, offsetD: number,
    offsetE: number, offsetF: number, offsetG: number
)
	-- Vertex dedup by packed edge identity (cornerA, cornerB in the value grid).
	-- Adjacent voxels share corners by index, so the same edge between two cells
	-- yields the same key, deduplicating without Vector3 userdata hashing.
	local vertices: { [number]: number } = {}

	local outerSq = voxelResOuter * voxelResOuter

	local bounds: Bounds = {
		MinX = math.huge, MinY = math.huge, MinZ = math.huge,
		MaxX = -math.huge, MaxY = -math.huge, MaxZ = -math.huge,
	}

	-- Reused per-march scratch for the 8 voxel corner indexes into `values`.
	local voxelCorners = table.create(8) :: { number }

	local resolveVertex = function(ca: number, cb: number, key: number): number
		local id = vertices[key]
		if id then return id end

		local inner = ca - 1
		local ax = inner // outerSq
		local az = (inner // voxelResOuter) % voxelResOuter
		local ay = inner % voxelResOuter
		local av = values[ca]

		inner = cb - 1
		local bx = inner // outerSq
		local bz = (inner // voxelResOuter) % voxelResOuter
		local by = inner % voxelResOuter
		local bv = values[cb]

		local t = (isoValue - av) / (bv - av)
		local vx = ax + t * (bx - ax)
		local vy = ay + t * (by - ay)
		local vz = az + t * (bz - az)

		if vx < bounds.MinX then bounds.MinX = vx end
		if vy < bounds.MinY then bounds.MinY = vy end
		if vz < bounds.MinZ then bounds.MinZ = vz end
		if vx > bounds.MaxX then bounds.MaxX = vx end
		if vy > bounds.MaxY then bounds.MaxY = vy end
		if vz > bounds.MaxZ then bounds.MaxZ = vz end

		id = eMesh:AddVertex(Vector3.new(vx, vy, vz))
		vertices[key] = id
		return id
	end

	local march = function(startIdx: number)
		voxelCorners[1] = startIdx
		voxelCorners[2] = startIdx + offsetA
		voxelCorners[3] = startIdx + offsetB
		voxelCorners[4] = startIdx + offsetC
		voxelCorners[5] = startIdx + offsetD
		voxelCorners[6] = startIdx + offsetE
		voxelCorners[7] = startIdx + offsetF
		voxelCorners[8] = startIdx + offsetG

		local index = 0
		if values[startIdx] >= isoValue then index += 1 end
		if values[startIdx + offsetA] >= isoValue then index += 2 end
		if values[startIdx + offsetB] >= isoValue then index += 4 end
		if values[startIdx + offsetC] >= isoValue then index += 8 end
		if values[startIdx + offsetD] >= isoValue then index += 16 end
		if values[startIdx + offsetE] >= isoValue then index += 32 end
		if values[startIdx + offsetF] >= isoValue then index += 64 end
		if values[startIdx + offsetG] >= isoValue then index += 128 end
		if index == 0 or index == 255 then return end

		local lookupCase = LOOKUP_TABLE[index]

		for i = 1, #lookupCase, 3 do
			local e1 = lookupCase[i]
			local e2 = lookupCase[i + 1]
			local e3 = lookupCase[i + 2]

			local c1a = voxelCorners[MIDPOINT_PARENTS_FLAT[e1 * 2 - 1]]
			local c1b = voxelCorners[MIDPOINT_PARENTS_FLAT[e1 * 2]]
			local c2a = voxelCorners[MIDPOINT_PARENTS_FLAT[e2 * 2 - 1]]
			local c2b = voxelCorners[MIDPOINT_PARENTS_FLAT[e2 * 2]]
			local c3a = voxelCorners[MIDPOINT_PARENTS_FLAT[e3 * 2 - 1]]
			local c3b = voxelCorners[MIDPOINT_PARENTS_FLAT[e3 * 2]]

			local key1, key2, key3
			if c1a < c1b then key1 = c1a * chunkVoxelCount + c1b else key1 = c1b * chunkVoxelCount + c1a end
			if c2a < c2b then key2 = c2a * chunkVoxelCount + c2b else key2 = c2b * chunkVoxelCount + c2a end
			if c3a < c3b then key3 = c3a * chunkVoxelCount + c3b else key3 = c3b * chunkVoxelCount + c3a end

			local id1 = resolveVertex(c1a, c1b, key1)
			local id2 = resolveVertex(c2a, c2b, key2)
			local id3 = resolveVertex(c3a, c3b, key3)

			eMesh:AddTriangle(id1, id2, id3)
		end
	end

	return march, bounds
end

const function NameToColor(name: string): Color3
	local hash = 0
	for idx = 1, #name do
		hash = (hash * 31 + string.byte(name, idx)) % 360
	end
	return Color3.fromHSV(hash / 360, 0.7, 0.85)
end

const function PlaceVegetation(
	mesh: MeshPart,
	sampler: Poisson.Poisson,
	startX: number, startY: number, startZ: number, chunkSize: number,
	seed: number, isoValue: number, amplitude: number,
	octaves: number, lacunarity: number, persistence: number, scale: number
)
	local chunkSeed = seed + math.floor(startX) * VEGETATION_SEED_X + math.floor(startZ) * VEGETATION_SEED_Z
	local samples = sampler:Sample(chunkSeed, vector.create(chunkSize, chunkSize))

	for sampleIdx = 1, #samples do
		local sample = samples[sampleIdx]
		local position = sample.Position
		local worldX = startX + position.x
		local worldZ = startZ + position.y

		local noiseValue = FractalNoise(worldX, worldZ, seed, octaves, lacunarity, persistence, scale)
		local surfaceY = (isoValue - noiseValue) / amplitude

		local part = Instance.new("Part")
		part.Name = sample.Name
		part.Anchored = true
		part.CanCollide = false
		part.Size = vector.create(2, 4, 2) :: any
		part.Position = vector.create(worldX, surfaceY + 2, worldZ) :: any
		part.Color = NameToColor(sample.Name)
		part.Material = Enum.Material.Grass
		part.Parent = mesh
	end
end

const function Chunk(
    xOffset: number, yOffset: number, zOffset: number, chunkSize: number,
    canCollide: boolean,
    eMeshQueue: EMeshQueue.EMeshQueue,
    seed: number, isoValue: number, chunkVoxelCount: number,
    voxelRes: number, voxelResInner: number, voxelResOuter: number,
    offsetA: number, offsetB: number, offsetC: number, offsetD: number,
    offsetE: number, offsetF: number, offsetG: number,
    moveUp: number,
    octaves: number, lacunarity: number, persistence: number,
    scale: number, amplitude: number,
    vegetationSampler: Poisson.Poisson?
) : MeshPart?
    local eMesh = eMeshQueue:Wait()
    if not eMesh then print("could not create emesh"); return nil end

    local chunkRadius = chunkSize / 2
    local startX, startY, startZ =
        xOffset - chunkRadius, yOffset - chunkRadius, zOffset - chunkRadius
	local voxelSize = chunkSize / voxelRes

	local values = table.create(chunkVoxelCount) :: ValuesTable

	local stepValue = voxelSize * amplitude
	local startValue = startY * amplitude

	local idx2d, idx3d = 0, 0
	for xIdx = 0, voxelRes do
	    local x = startX + xIdx * voxelSize

		for zIdx = 0, voxelRes do
		    local z = startZ + zIdx * voxelSize
			idx2d += 1

			local value2d = SurfaceNoise(
			    x, 0 , z,
				octaves, lacunarity, persistence, scale,
				seed, isoValue, amplitude
			)

			local val = value2d + startValue
			for yIdx = 0, voxelRes do
				idx3d += 1
				values[idx3d] = val
				val += stepValue
			end
		end
	end

	local idx3d = 0
	local march, bounds = MarchingCubes(
    	eMesh, values, isoValue, voxelResOuter, chunkVoxelCount,
        offsetA, offsetB, offsetC, offsetD,
        offsetE, offsetF, offsetG
	)

	for _ = 0, voxelResInner do
		for _ = 0, voxelResInner do
			for _ = 0, voxelResInner do
				idx3d += 1

				march(idx3d)
			end

			idx3d += MOVE_RIGHT
		end

		idx3d += moveUp
	end

	if #eMesh:GetFaces() == 0 then
	    eMesh:Destroy()
	    return nil
	end

	local collisionFidelity = if canCollide
	    then Enum.CollisionFidelity.Default
	    else Enum.CollisionFidelity.Box

	local ok, mesh = pcall(
	    AssetService.CreateMeshPartAsync, AssetService,
		Content.fromObject(eMesh),
		{ CollisionFidelity = collisionFidelity } :: { [string]: any }
	)

	if not ok then
	    eMesh:Destroy()
        return nil
	end

	mesh.Position = vector.create(startX, startY, startZ) :: any

	mesh.Size = vector.create(
		(bounds.MaxX - bounds.MinX) * voxelSize,
		(bounds.MaxY - bounds.MinY) * voxelSize,
		(bounds.MaxZ - bounds.MinZ) * voxelSize
	) :: any

	mesh.Color = Color3.fromHex("348C31")
	mesh.Material = Enum.Material.Grass

	--local lodBucket = math.round(math.log(chunkSize, 2))
	--mesh.Color = LOD_COLORS[(lodBucket % #LOD_COLORS) + 1]

	mesh.Anchored = true
	mesh.CanCollide = canCollide
	mesh.Parent = workspace

	if vegetationSampler then
		PlaceVegetation(
			mesh, vegetationSampler,
			startX, startY, startZ, chunkSize,
			seed, isoValue, amplitude,
			octaves, lacunarity, persistence, scale
		)
	end

	return mesh
end

const function New(config: MarchingCubesConfig?)
    local config = config or EMPTY_TABLE :: MarchingCubesConfig

    local eMeshQueue = EMeshQueue.new()

    local octaves, lacunarity, persistence, scale, amplitude =
        config.Octaves or 4, config.Lacunarity or .5, config.Persistence or 0.3,
        config.Scale or 550, config.Amplitude or 0.008

    local voxelRes, isoValue, seed =
        config.Resolution or 10, config.IsoValue or 0, config.Seed or 0

    local voxelResInner, voxelResOuter = voxelRes - 1, voxelRes + 1
    local chunkVoxelCount = (voxelRes + 1) ^ 3

    local moveForwards = voxelRes + ((voxelRes + 1) * voxelRes) + 1
    local moveUp = voxelRes + 1

    local offsetA, offsetB, offsetC, offsetD, offsetE, offsetF, offsetG =
    	moveForwards,
    	moveForwards + MOVE_RIGHT,
    	MOVE_RIGHT,
    	moveUp,
    	moveForwards + moveUp,
    	moveForwards + moveUp + MOVE_RIGHT,
    	moveUp + MOVE_RIGHT

    local vegetationSampler: Poisson.Poisson? = if config.Vegetation then Poisson.new(config.Vegetation) else nil

     return {
         Chunk = function(xOffset: number, yOffset: number, zOffset: number, chunkSize: number, canCollide: boolean)
             return Chunk(
                 xOffset, yOffset, zOffset, chunkSize,
                 canCollide,
                 eMeshQueue,
                 seed, isoValue, chunkVoxelCount,
                 voxelRes, voxelResInner, voxelResOuter,
                 offsetA, offsetB, offsetC, offsetD,
                 offsetE, offsetF, offsetG,
                 moveUp,
                 octaves, lacunarity, persistence,
                 scale, amplitude,
                 vegetationSampler
             )
         end,

         Sample = function(pos: vector)
            return SurfaceNoise(
                pos.x, pos.y, pos.z,
                octaves, lacunarity, persistence, scale,
                seed, isoValue, amplitude
            ) / amplitude
        end
     }
end

return {
    new = New
}
