--!strict
--!native

--> Modules -------------------------------------------------------------------------------------------
local Settings = require(script["Settings"])

local NoiseLab = require(script.NoiseLab)
--local CaveNoise = require(script["CaveNoise.noiseLab"])

local LOOKUP_TABLE = require(script.LookupTable)
-------------------------------------------------------------------------------------------------------


--> Types ---------------------------------------------------------------------------------------------
type ValuesTable = { number }
type ColorsIdsTable = { number }
type VerticesTable = { [Vector3]: number }
type MidPointsTable = { [Vector3]: { [Vector3]: Vector3 } }
-------------------------------------------------------------------------------------------------------




type Union = "Zebra" | "Apple"



--> Variables -----------------------------------------------------------------------------------------
local ISO_VALUE, SEED = Settings.IsoValue, Settings.Seed

local CHUNKS_SETTINGS = Settings.Chunks
local VOXEL_RES = CHUNKS_SETTINGS.VoxelResolution
print(VOXEL_RES)
local VOXEL_RES_INNER = VOXEL_RES - 1
local VOXEL_RES_OUTER = VOXEL_RES + 1
local CHUNK_VOXEL_COUNT = (VOXEL_RES + 1) ^ 3
--local CHUNK_VOXEL_SLICE_COUNT = (VOXEL_RES + 1) ^ 2

local TERRAIN_EXAGGERATION = .0003 --.008
--local TERRAIN_HEIGHT_SCALE = 125 -- this number will be wrong!

local COLORS_SETTINGS = Settings.Colors
local COLOR_GRASS, COLOR_DIRT, COLOR_STONE = COLORS_SETTINGS.Grass, COLORS_SETTINGS.Dirt, COLORS_SETTINGS.Stone
local COLOR_GRASS_ID, COLOR_DIRT_ID, COLOR_STONE_ID = 12884901889, 12884901890, 12884901891
--local COLOR_GRASS_ID, COLOR_DIRT_ID, COLOR_STONE_ID = 1, 0, 2

local MIDPOINT_PARENTS = {
	{1, 2}, {2, 3}, {3, 4}, {4, 1},
	{5, 6}, {6, 7}, {7, 8}, {8, 5},
	{1, 5}, {2, 6}, {3, 7}, {4, 8}
}

local FORWARDS = VOXEL_RES + ((VOXEL_RES + 1) * VOXEL_RES) + 1
local RIGHT = 1
local UP = VOXEL_RES + 1

local OFFSET_A, OFFSET_B, OFFSET_C, OFFSET_D, OFFSET_E, OFFSET_F, OFFSET_G = 
	FORWARDS,
	FORWARDS + RIGHT,
	RIGHT,
	UP,
	FORWARDS + UP,
	FORWARDS + UP + RIGHT,
	UP + RIGHT

local ChunksFolder = Instance.new("Folder")
ChunksFolder.Parent = workspace

local SurfaceNoise = NoiseLab {
	Octaves = 4,
	Lacunarity = 2,
	Persistence = .4,
	Scale = 18_000,

	KeyPoints = {
		Vector3.new(-1, 0, -1),
		Vector3.new(1, 0, 1),
	} 
}

--[[local SurfacePointOfInterestNoise = NoiseLab {
	Octaves = 2,
	Lacunarity = 2,
	Persistence = .3,
	Scale = 10_000,

	KeyPoints = {
    Vector3.new(-1, 0, 0),
    Vector3.new(1, 0, 1),
}
}]]

--[[local SurfacePointOfInterestMaskNoise = NoiseLab {
	Scale = 30_000,

	KeyPoints = {
    Vector3.new(0.030303001403808594, 0, 1),
    Vector3.new(0.8242424726486206, 0, -1),
	}
}]]

--[[local CaveNoise = NoiseLab {
	Octaves = 2,
	Lacunarity = .3,
	Persistence = 3,
	Scale = 700,
	
	KeyPoints = {
		Vector3.new(-1, 0, -1),
		Vector3.new(-0.682539701461792, 0, 1),
		Vector3.new(-0.29523807764053345, 0, -1),
	}
}]]
-------------------------------------------------------------------------------------------------------


--> Private Functions ---------------------------------------------------------------------------------
local function ChooseVertexColor(colorAId: number, colorBId: number)
	return colorAId
	--[[return
    (colorAId == COLOR_GRASS_ID or colorBId == COLOR_GRASS_ID) and COLOR_GRASS_ID or
		(colorAId == COLOR_STONE_ID or colorBId == COLOR_STONE_ID) and COLOR_STONE_ID or
		COLOR_DIRT_ID]]
end


local function CreateVertex(terrainEMesh: EditableMesh, vertices: VerticesTable)
	return function(pos: Vector3)
		local vertexId = terrainEMesh:AddVertex(pos)
		vertices[pos] = vertexId

		return vertexId
	end
end


local function IsosurfaceLerp(pos1: Vector3, val1: number, pos2: Vector3, val2: number)
	return pos1 + ((ISO_VALUE - val1) / (val2 - val1)) * (pos2 - pos1)
end


--[[local function FractalNoise(x: number, y: number, z: number, octaves: number, lacunarity: number, persistence: number, scale: number)
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
end]]


--[[local function SurfaceNoise(x: number, z: number)
	return FractalNoise(x, z, SEED,
		2,  -- Octaves.
		.1, -- Lacunarity.
		0.2,  -- Persistence.
		8000 -- Scale.
	)
end]]


local function Index3DToPosition(idx: number)
	local idxInner = idx - 1
	local x = idxInner // (VOXEL_RES_OUTER * VOXEL_RES_OUTER)
	local z = (idxInner // VOXEL_RES_OUTER) % VOXEL_RES_OUTER
	local y = idxInner % VOXEL_RES_OUTER

	return Vector3.new(x, y, z)
end


-- Performs the marching cubes algorithm on a cube of 8 positions starting from a specified position.
local function MarchingCubes(terrainEMesh: EditableMesh, values: ValuesTable, colorsIds: ColorsIdsTable)
	local vertices: VerticesTable = {}

	local createVertex = CreateVertex(terrainEMesh, vertices)

	return function(startIdx: number)
		-- Gets the indexes of each corner of the voxel.
		local voxelIndexA, voxelIndexB, voxelIndexC, voxelIndexD, voxelIndexE, voxelIndexF, voxelIndexG, voxelIndexH = 
			startIdx, startIdx + OFFSET_A, startIdx + OFFSET_B, startIdx + OFFSET_C,
			startIdx + OFFSET_D, startIdx + OFFSET_E, startIdx + OFFSET_F, startIdx + OFFSET_G
		local voxelIndexes = { voxelIndexA, voxelIndexB, voxelIndexC, voxelIndexD, voxelIndexE, voxelIndexF, voxelIndexG, voxelIndexH }

		-- Calculates the index in the LOOKUP_TABLE for the voxel.
		-- Does not use a loop as doing so would require either a subtraction
		-- or an addition operation which would be slightly less performant.
		local index: number = 0
		if values[voxelIndexA] >= ISO_VALUE then index += 1 end
		if values[voxelIndexB] >= ISO_VALUE then index += 2 end
		if values[voxelIndexC] >= ISO_VALUE then index += 4 end
		if values[voxelIndexD] >= ISO_VALUE then index += 8 end
		if values[voxelIndexE] >= ISO_VALUE then index += 16 end
		if values[voxelIndexF] >= ISO_VALUE then index += 32 end
		if values[voxelIndexG] >= ISO_VALUE then index += 64 end
		if values[voxelIndexH] >= ISO_VALUE then index += 128 end
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

      		local edge1CornerAPos, edge1CornerBPos = Index3DToPosition(edge1CornerAIdx), Index3DToPosition(edge1CornerBIdx)
			local edge2CornerAPos, edge2CornerBPos = Index3DToPosition(edge2CornerAIdx), Index3DToPosition(edge2CornerBIdx)
			local edge3CornerAPos, edge3CornerBPos = Index3DToPosition(edge3CornerAIdx), Index3DToPosition(edge3CornerBIdx)

			local edge1CornerAVal, edge1CornerBVal = values[edge1CornerAIdx], values[edge1CornerBIdx]
			local edge2CornerAVal, edge2CornerBVal = values[edge2CornerAIdx], values[edge2CornerBIdx]
			local edge3CornerAVal, edge3CornerBVal = values[edge3CornerAIdx], values[edge3CornerBIdx]

			local vertex1Pos = IsosurfaceLerp(edge1CornerAPos, edge1CornerAVal, edge1CornerBPos, edge1CornerBVal)
			local vertex2Pos = IsosurfaceLerp(edge2CornerAPos, edge2CornerAVal, edge2CornerBPos, edge2CornerBVal)
			local vertex3Pos = IsosurfaceLerp(edge3CornerAPos, edge3CornerAVal, edge3CornerBPos, edge3CornerBVal)

			-- Makes sure all vert positions are unique to prevent any future issues when constructing a mesh.
			if vertex1Pos == vertex2Pos or vertex1Pos == vertex3Pos or vertex2Pos == vertex3Pos then continue end

			local color1Id = ChooseVertexColor(colorsIds[edge1CornerAIdx], colorsIds[edge1CornerBIdx])
			local color2Id = ChooseVertexColor(colorsIds[edge2CornerAIdx], colorsIds[edge2CornerBIdx])
			local color3Id = ChooseVertexColor(colorsIds[edge3CornerAIdx], colorsIds[edge3CornerBIdx])

			local vertex1Id = vertices[vertex1Pos] or createVertex(vertex1Pos)
			local vertex2Id = vertices[vertex2Pos] or createVertex(vertex2Pos)
			local vertex3Id = vertices[vertex3Pos] or createVertex(vertex3Pos)

			local triId = terrainEMesh:AddTriangle(vertex1Id, vertex2Id, vertex3Id)
			terrainEMesh:SetFaceColors(triId, { color1Id, color2Id, color3Id })
		end
	end
end
-------------------------------------------------------------------------------------------------------


return function(xOffset: number, yOffset: number, zOffset: number, chunkSize: number)
	local chunkRadius = chunkSize / 2

	local function createTerrain()
		local terrainEMesh = Instance.new("EditableMesh")

		terrainEMesh:AddColor(COLOR_GRASS, 0)
		terrainEMesh:AddColor(COLOR_DIRT, 0)
		terrainEMesh:AddColor(COLOR_STONE, 0)

		local startX, startY, startZ = xOffset - chunkRadius, yOffset - chunkRadius, zOffset - chunkRadius
		local endX, endY, endZ = xOffset + chunkRadius, yOffset + chunkRadius, zOffset + chunkRadius
		local voxelSize = chunkSize / VOXEL_RES

		local values: ValuesTable, colorsIds: ColorsIdsTable--[[, surfaceValues: ValuesTable, caveValues: { boolean }]] =
			table.create(CHUNK_VOXEL_COUNT),
			table.create(CHUNK_VOXEL_COUNT)--,
			--table.create(CHUNK_VOXEL_SLICE_COUNT), 
			--table.create(CHUNK_VOXEL_SLICE_COUNT)

		local idx2d, idx3d = 0, 0
		for x = startX, endX, voxelSize do
			for z = startZ, endZ, voxelSize do
				idx2d += 1
				--local pointOfInterestMaskNoise = ((SurfacePointOfInterestMaskNoise(x, 0, z) + 1) / 2) - 1
				--local pointOfInterestNoise = (SurfacePointOfInterestNoise(x, 0, z) + 1.5) * pointOfInterestMaskNoise
				local value2d = SurfaceNoise(x, 0 , z)--FractalNoise(x, 0, z, 2, .3, .2, 200)-- + pointOfInterestNoise
				--local amplValue2d = ((-value2d) * 125)

				--[[if amplValue2d >= startY and amplValue2d <= endY then
					local caveValue2d = CaveNoise(x, amplValue2d + 50, z) 

					if caveValue2d >= (value2d >= 0 and value2d - .5 or value2d + .5) then
						caveValues[idx2d] = true
					else
						surfaceValues[idx2d] = value2d
					end
				end]]

				for y = startY, endY, voxelSize do
					idx3d += 1

					local value: number = value2d + ((y * TERRAIN_EXAGGERATION) - ISO_VALUE)
					--local r = (SurfacePointOfInterestMaskNoise(x, 0, z) + 1) / 2
					local colorId: number = COLOR_GRASS_ID --terrainEMesh:AddColor(Color3.new(r, r, r), 1) --COLOR_GRASS_ID

					--[[if value <= ISO_VALUE then
						local caveValue = CaveNoise(x,y,z)

						colorId = (value < -.6 and COLOR_STONE_ID) or (value < ISO_VALUE and COLOR_DIRT_ID) or colorId
						value = (caveValue >= value and caveValue) or value
					end]]

					values[idx3d] = value
					colorsIds[idx3d] = colorId
				end
			end
		end

		local idx3d = 0
		local march = MarchingCubes(terrainEMesh, values, colorsIds)

		for x = 0, VOXEL_RES_INNER do
			for y = 0, VOXEL_RES_INNER do
				for z = 0, VOXEL_RES_INNER do
					idx3d += 1
					march(idx3d)
				end
				idx3d += RIGHT
			end
			idx3d += UP
		end

		--print(terrainEMesh:GetVertices())

		local terrainMesh = Instance.new("MeshPart")
		terrainMesh.Size = Vector3.one
		terrainMesh.CanCollide = false
		terrainMesh.Anchored = true
		terrainMesh.Name = `{xOffset}:{yOffset}:{zOffset}`
		terrainMesh.Size = Vector3.one * ( chunkSize / VOXEL_RES )
		terrainMesh.Position = Vector3.new(startX, startY, startZ)
		terrainMesh.CastShadow = false

		--[[local surfaceAppearance = Instance.new("SurfaceAppearance")
		surfaceAppearance.Parent = terrainMesh]]

		terrainEMesh.Parent = terrainMesh
		terrainMesh.Parent = ChunksFolder
		
		return terrainMesh
	end
	
	return {
		createTerrain
	}
end