--!strict
--!native
--!nolint LocalShadow

local Yield = require(script.Parent.Parent.utils.yield)

local MarchingCubes = require(script.marchingCubes)

local ChunksFolder = Instance.new("Folder")
ChunksFolder.Parent = workspace

const function MarchingCubesGenerator(config: MarchingCubes.MarchingCubesConfig?)
    local nodes: { [vector]: MeshPart } = {}

    local marchingCubes = MarchingCubes.new(config)

    return {
        Create = function(positionGroups: { { vector } }, sizes: { vector })
            local jobs: { () -> () } = {}
            local jobCount = 0

            for groupIdx = 1, #positionGroups do
                local group = positionGroups[groupIdx]
                local size = sizes[groupIdx]

                for idx = 1, #group do
                    local pos = group[idx]

                    if nodes[pos] then
                        warn("[Genesis DEBUG] DUPLICATE CREATE at", pos)
                        continue
                    end

                    jobCount += 1
                    jobs[jobCount] = function()
                        local chunk = marchingCubes.Chunk(pos.x, pos.y, pos.z, size.x)
                        nodes[pos] = chunk
                    end
                end
            end

            Yield(jobs)
        end,

        Destroy = function(positions: { vector })
            for idx = 1, #positions do
                local pos = positions[idx]
                local mesh = nodes[pos]

                nodes[pos] = nil

                if not mesh then
                    --warn("[Genesis DEBUG] DESTROY KEY MISS at", pos)
                    continue
                end

                mesh:Destroy()
            end
        end,

        Sample = marchingCubes.Sample
    }
end

return MarchingCubesGenerator
