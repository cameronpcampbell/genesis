--!strict
--!native
--!nolint LocalShadow

local MarchingCubes = require(script.marchingCubes)

local ChunksFolder = Instance.new("Folder")
ChunksFolder.Parent = workspace

const function MarchingCubesGenerator(
    config: MarchingCubes.MarchingCubesConfig?
)
    local nodes: { [vector]: MeshPart } = {}
    local baseLeafSize = 0

    local marchingCubes = MarchingCubes.new(config)

    return {
        Init = function(initConfig: { ChunkSize: number, OctreeLodAmount: number })
            baseLeafSize = initConfig.ChunkSize
        end,

        Create = function(pos: vector, size: vector)
            if nodes[pos] then
                warn("[Genesis DEBUG] DUPLICATE CREATE at", pos)
                return
            end

            local canCollide = size.x == baseLeafSize
            nodes[pos] = marchingCubes.Chunk(pos.x, pos.y, pos.z, size.x, canCollide)
        end,

        Destroy = function(pos: vector)
            local mesh = nodes[pos]
            nodes[pos] = nil

            if not mesh then
                --warn("[Genesis DEBUG] DESTROY KEY MISS at", pos)
                return
            end

            mesh:Destroy()
        end,

        Sample = marchingCubes.Sample
    }
end

return MarchingCubesGenerator
