--!strict
--!native
--!nolint LocalShadow

local AssetService = game:GetService("AssetService")

local EMeshQueue = require(script.Parent.Parent.Parent.utils.eMeshQueue)
const LOOKUP_TABLE = require(script.lookupTable)

const MOVE_RIGHT = 1

const EMPTY_TABLE = {}

export type MarchingCubesConfig = {
    Resolution: number?,
    IsoValue: number?,
    Seed: number?,
    Octaves: number?,
    Lacunarity: number?,
    Persistence: number?,
    Scale: number?,
    Amplitude: number?
}

type ValuesTable = { number }
type ColorsIdsTable = { number }
type VerticesTable = { [Vector3]: number }
type MidPointsTable = { [Vector3]: { [Vector3]: Vector3 } }

const LOD_COLORS = {
	Color3.fromRGB(255, 80, 80),
	Color3.fromRGB(255, 180, 60),
	Color3.fromRGB(50, 240, 80),
	Color3.fromRGB(45, 180, 150),
	Color3.fromRGB(40, 90, 200),
	Color3.fromRGB(120, 140, 255),
	Color3.fromRGB(220, 120, 255),
}

const MIDPOINT_PARENTS = {
	{1, 2}, {2, 3}, {3, 4}, {4, 1},
	{5, 6}, {6, 7}, {7, 8}, {8, 5},
	{1, 5}, {2, 6}, {3, 7}, {4, 8}
}

--local CreateDataModelContentAsync = AssetService.CreateDataModelContentAsync
    --:: (self: AssetService, content: Content, options: { [string]: any }?) -> (boolean, Content)

--[[
const function ChooseVertexColor(colorAId: number, colorBId: number)
	return colorAId
	--[=[return
    (colorAId == COLOR_GRASS_ID or colorBId == COLOR_GRASS_ID) and COLOR_GRASS_ID or
		(colorAId == COLOR_STONE_ID or colorBId == COLOR_STONE_ID) and COLOR_STONE_ID or
		COLOR_DIRT_ID]=]
end]]


type Bounds = { Min: Vector3, Max: Vector3 }

const function CreateVertex(terrainEMesh: EditableMesh, vertices: VerticesTable, bounds: Bounds)
	return function(pos: Vector3)
		local vertexId = terrainEMesh:AddVertex(pos)
		vertices[pos] = vertexId

		bounds.Min = bounds.Min:Min(pos)
		bounds.Max = bounds.Max:Max(pos)

		return vertexId
	end
end


const function IsosurfaceLerp(
    pos1: Vector3, val1: number,
    pos2: Vector3, val2: number,
    isoValue: number
)
	return pos1 + ((isoValue - val1) / (val2 - val1)) * (pos2 - pos1)
end


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
    scale: number, seed: number, isoValue: number
)
	return FractalNoise(
	    x, z, seed,
	    octaves, lacunarity, persistence, scale
	) + ((y * 0.008) - isoValue)
end

const function Index3DToPosition(idx: number, voxelResOuter: number)
	local idxInner = idx - 1
	local x = idxInner // (voxelResOuter * voxelResOuter)
	local z = (idxInner // voxelResOuter) % voxelResOuter
	local y = idxInner % voxelResOuter

	return Vector3.new(x, y, z)
end

const function MarchingCubes(
    eMesh: EditableMesh, values: ValuesTable,
    isoValue: number, voxelResOuter: number,
    offsetA: number, offsetB: number, offsetC: number, offsetD: number,
    offsetE: number, offsetF: number, offsetG: number
)
	local vertices: VerticesTable = {}
	local bounds: Bounds = {
		Min = Vector3.new(math.huge, math.huge, math.huge),
		Max = Vector3.new(-math.huge, -math.huge, -math.huge),
	}

	local createVertex = CreateVertex(eMesh, vertices, bounds)

	local march = function(startIdx: number)
		-- Gets the indexes of each corner of the voxel.
		local voxelIndexA, voxelIndexB, voxelIndexC, voxelIndexD =
			startIdx, startIdx + offsetA, startIdx + offsetB, startIdx + offsetC
		local voxelIndexE, voxelIndexF, voxelIndexG, voxelIndexH =
		    startIdx + offsetD, startIdx + offsetE, startIdx + offsetF, startIdx + offsetG
		local voxelIndexes = {
		    voxelIndexA, voxelIndexB, voxelIndexC, voxelIndexD,
			voxelIndexE, voxelIndexF, voxelIndexG, voxelIndexH
		}

		-- Calculates the index in the LOOKUP_TABLE for the voxel.
		-- Does not use a loop as doing so would require either a subtraction
		-- or an addition operation which would be slightly less performant.
		local index: number = 0
		if values[voxelIndexA] >= isoValue then index += 1 end
		if values[voxelIndexB] >= isoValue then index += 2 end
		if values[voxelIndexC] >= isoValue then index += 4 end
		if values[voxelIndexD] >= isoValue then index += 8 end
		if values[voxelIndexE] >= isoValue then index += 16 end
		if values[voxelIndexF] >= isoValue then index += 32 end
		if values[voxelIndexG] >= isoValue then index += 64 end
		if values[voxelIndexH] >= isoValue then index += 128 end
		if index == 0 or index == 255 then return end -- Voxel is empty.

		local lookupCase = LOOKUP_TABLE[index]

		-- Iterates over the lookupCase in batches of 3 where each batch contains the indexes of 3 edges.
		-- A vertex will be made (unless already made) somewhere along each of the the 3 edges.
		-- The vertices will then be used to construct a triangle.
		for i = 1, #lookupCase, 3 do
			local edge1CornerIds = MIDPOINT_PARENTS[lookupCase[i]]
			local edge2CornerIds = MIDPOINT_PARENTS[lookupCase[i + 1]]
			local edge3CornerIds = MIDPOINT_PARENTS[lookupCase[i + 2]]

			local edge1CornerAIdx, edge1CornerBIdx = voxelIndexes[edge1CornerIds[1]], voxelIndexes[edge1CornerIds[2]]
			local edge2CornerAIdx, edge2CornerBIdx = voxelIndexes[edge2CornerIds[1]], voxelIndexes[edge2CornerIds[2]]
			local edge3CornerAIdx, edge3CornerBIdx = voxelIndexes[edge3CornerIds[1]], voxelIndexes[edge3CornerIds[2]]

      		local edge1CornerAPos, edge1CornerBPos =
                Index3DToPosition(edge1CornerAIdx, voxelResOuter), Index3DToPosition(edge1CornerBIdx, voxelResOuter)
			local edge2CornerAPos, edge2CornerBPos =
			    Index3DToPosition(edge2CornerAIdx, voxelResOuter), Index3DToPosition(edge2CornerBIdx, voxelResOuter)
			local edge3CornerAPos, edge3CornerBPos =
			    Index3DToPosition(edge3CornerAIdx, voxelResOuter), Index3DToPosition(edge3CornerBIdx, voxelResOuter)

			local edge1CornerAVal, edge1CornerBVal = values[edge1CornerAIdx], values[edge1CornerBIdx]
			local edge2CornerAVal, edge2CornerBVal = values[edge2CornerAIdx], values[edge2CornerBIdx]
			local edge3CornerAVal, edge3CornerBVal = values[edge3CornerAIdx], values[edge3CornerBIdx]

			local vertex1Pos = IsosurfaceLerp(edge1CornerAPos, edge1CornerAVal, edge1CornerBPos, edge1CornerBVal, isoValue)
			local vertex2Pos = IsosurfaceLerp(edge2CornerAPos, edge2CornerAVal, edge2CornerBPos, edge2CornerBVal, isoValue)
			local vertex3Pos = IsosurfaceLerp(edge3CornerAPos, edge3CornerAVal, edge3CornerBPos, edge3CornerBVal, isoValue)

			-- Makes sure all vert positions are unique to prevent any future issues when constructing a mesh.
			if vertex1Pos == vertex2Pos or vertex1Pos == vertex3Pos or vertex2Pos == vertex3Pos then continue end

			--local color1Id = ChooseVertexColor(colorsIds[edge1CornerAIdx], colorsIds[edge1CornerBIdx])
			--local color2Id = ChooseVertexColor(colorsIds[edge2CornerAIdx], colorsIds[edge2CornerBIdx])
			--local color3Id = ChooseVertexColor(colorsIds[edge3CornerAIdx], colorsIds[edge3CornerBIdx])

			local vertex1Id = vertices[vertex1Pos] or createVertex(vertex1Pos)
			local vertex2Id = vertices[vertex2Pos] or createVertex(vertex2Pos)
			local vertex3Id = vertices[vertex3Pos] or createVertex(vertex3Pos)

			local _triId = eMesh:AddTriangle(vertex1Id, vertex2Id, vertex3Id)
			--terrainEMesh:SetFaceColors(triId, { color1Id, color2Id, color3Id })
		end
	end

	return march, bounds
end

const function Chunk(
    xOffset: number, yOffset: number, zOffset: number, chunkSize: number,
    eMeshQueue: EMeshQueue.EMeshQueue,
    seed: number, isoValue: number, chunkVoxelCount: number,
    voxelRes: number, voxelResInner: number, voxelResOuter: number,
    offsetA: number, offsetB: number, offsetC: number, offsetD: number,
    offsetE: number, offsetF: number, offsetG: number,
    moveUp: number,
    octaves: number, lacunarity: number, persistence: number,
    scale: number, amplitude: number
) : MeshPart?
    local eMesh = eMeshQueue:Wait()
    if not eMesh then print("could not create emesh"); return nil end

    local chunkRadius = chunkSize / 2
    local startX, startY, startZ =
        xOffset - chunkRadius, yOffset - chunkRadius, zOffset - chunkRadius
	local voxelSize = chunkSize / voxelRes

	local values = table.create(chunkVoxelCount) :: ValuesTable

	local idx2d, idx3d = 0, 0
	for xIdx = 0, voxelRes do
	    local x = startX + xIdx * voxelSize

		for zIdx = 0, voxelRes do
		    local z = startZ + zIdx * voxelSize
			idx2d += 1

			local value2d = SurfaceNoise(
			    x, 0 , z,
				octaves, lacunarity, persistence, scale,
				seed, isoValue
			)
			--local amplValue2d = (-value2d) * 125

			--[[if amplValue2d >= startY and amplValue2d <= endY then
				local caveValue2d = CaveNoise(x, amplValue2d + 50, z)

				if caveValue2d >= (value2d >= 0 and value2d - .5 or value2d + .5) then
					caveValues[idx2d] = true
				else
					surfaceValues[idx2d] = value2d
				end
			end]]

			for yIdx = 0, voxelRes do
			    local y = startY + yIdx * voxelSize
				idx3d += 1

				local value: number = value2d + (y * amplitude)
				values[idx3d] = value
			end
		end
	end

	local idx3d = 0
	local march, bounds = MarchingCubes(
    	eMesh, values, isoValue, voxelResOuter,
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
	    return nil
	end

	--local _ok, content =
	    --CreateDataModelContentAsync(AssetService, Content.fromObject(eMesh))

	local meshLocalSize = bounds.Max - bounds.Min

	--eMesh:Destroy()

	local mesh = AssetService:CreateMeshPartAsync(Content.fromObject(eMesh))

	mesh.Position = vector.create(startX, startY, startZ) :: any

	mesh.Size = vector.create(
		meshLocalSize.X * voxelSize,
		meshLocalSize.Y * voxelSize,
		meshLocalSize.Z * voxelSize
	) :: any

	local lodBucket = math.round(math.log(chunkSize, 2))
	mesh.Color = LOD_COLORS[(lodBucket % #LOD_COLORS) + 1]

	mesh.Anchored = true
	mesh.CanCollide = false
	mesh.Parent = workspace

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

     return {
         Chunk = function(xOffset: number, yOffset: number, zOffset: number, chunkSize: number)
             return Chunk(
                 xOffset, yOffset, zOffset, chunkSize,
                 eMeshQueue,
                 seed, isoValue, chunkVoxelCount,
                 voxelRes, voxelResInner, voxelResOuter,
                 offsetA, offsetB, offsetC, offsetD,
                 offsetE, offsetF, offsetG,
                 moveUp,
                 octaves, lacunarity, persistence,
                 scale, amplitude
             )
         end,

         Sample = function(pos: vector)
            return SurfaceNoise(
                pos.x, pos.y, pos.z,
                octaves, lacunarity, persistence, scale,
                seed, isoValue
            ) / amplitude
        end
     }
end

return {
    new = New
}
