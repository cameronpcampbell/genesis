--!strict


--> Types ---------------------------------------------------------------------------------------------
export type Settings = {
	IsoValue: number,
	Seed: number,
	Chunks: {
		RootNodeSize: number,
		VoxelResolution: number,
		RenderDistance: number,
	},
	Colors: {
		Grass: Color3,
		Dirt: Color3,
		Stone: Color3
	}
}
-------------------------------------------------------------------------------------------------------


--> Variables -----------------------------------------------------------------------------------------
local Settings: Settings = {
	IsoValue = 0,
	Seed = 50,
	Chunks = {
		RootNodeSize = 1600,
		VoxelResolution = 16,
		RenderDistance = 8,
	},
	Colors = {
		Grass = Color3.fromHex("618D5D"),
		Dirt = Color3.fromRGB(120, 72, 31),
		Stone = Color3.fromRGB(121, 120, 124)
	},
}
-------------------------------------------------------------------------------------------------------


return Settings