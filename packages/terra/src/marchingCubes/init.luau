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

    local marchingCubes = MarchingCubes.new(config)

    return {
        Create = function(pos: vector, size: vector, lod: number)
            if nodes[pos] then
                warn("[Genesis DEBUG] DUPLICATE CREATE at", pos)
                return
            end

            nodes[pos] = marchingCubes.Chunk(pos.x, pos.y, pos.z, size.x, lod == 0)
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
