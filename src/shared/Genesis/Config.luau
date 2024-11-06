--!strict


--> Dependencies --------------------------------------------------------------------------------------
local Utils = script.Parent.Utils
local TableUtils = require(Utils.TableUtils)
-------------------------------------------------------------------------------------------------------


--> Types ---------------------------------------------------------------------------------------------
type TerrainConfig = {
	CHUNK_SIZE: number,
	RENDER_DISTANCE: number,
	OCTREE_DIST_MULTIPLYERS: { number },
	
	OCTREE_MAX_DIVISIONS: number,
	OCTREE_DISTANCES: { number },
	ROOT_SIZE: number,
	ROOT_SIZE_MULTIPLYER: number,
	RENDER_DIAMETER: number
}
-------------------------------------------------------------------------------------------------------


--> Variables -----------------------------------------------------------------------------------------
local TableMap = TableUtils.TableMap


-- [ CONFIG ] ===============================================================
local CHUNK_SIZE = 1600
local RENDER_DISTANCE = 16
local OCTREE_DIST_MULTIPLYERS = {
	--[[3,   -- White -> Red
	1.8, -- Red -> Orange
	.95, -- Orange -> Yellow
	.5   -- Yellow -> Green]]
}
--local OCTREE_DIST_MULTIPLYERS = { 1.8, 1.5, .95, .8 }
-- ==========================================================================


-- Derived from the variables above.
local MAX_DIVISIONS = #OCTREE_DIST_MULTIPLYERS
local ROOT_SIZE = CHUNK_SIZE * (2 ^ (MAX_DIVISIONS))


local Config: TerrainConfig = {
	CHUNK_SIZE = CHUNK_SIZE,
	RENDER_DISTANCE = RENDER_DISTANCE,
	OCTREE_DIST_MULTIPLYERS = OCTREE_DIST_MULTIPLYERS,
	
	-- Derived.
	RENDER_DIAMETER = RENDER_DISTANCE ^ 2 + 1,
	OCTREE_MAX_DIVISIONS = MAX_DIVISIONS,
	OCTREE_DISTANCES = TableMap(OCTREE_DIST_MULTIPLYERS, function(multiplyer: number)
		return ROOT_SIZE * multiplyer
	end),
	ROOT_SIZE = ROOT_SIZE,
	ROOT_SIZE_MULTIPLYER = 1 / ROOT_SIZE
}
-------------------------------------------------------------------------------------------------------


return Config