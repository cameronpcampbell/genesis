--!strict


--> Modules -------------------------------------------------------------------------------------------
local Core = script.Core
local ChunkLoader = require(Core.ChunkLoader)
-------------------------------------------------------------------------------------------------------


return {
    init = function(target: any & { Position: Vector3 })
        ChunkLoader(target)
    end
}