--!strict

local Genesis = require("./packages/genesis")
local Terra = require("./packages/terra")

local Player = game:GetService("Players").LocalPlayer
Player.CameraMaxZoomDistance = 10 ^ 100000

local SpawnLocation =
    workspace:WaitForChild("SpawnLocation") :: SpawnLocation
SpawnLocation.Transparency = 1

const OCTREE_LOD_AMOUNT = 4

local Loader = Genesis.New({
    RenderDistance = 0,
    ChunkSize = 2048 / (2 ^ OCTREE_LOD_AMOUNT),
    OctreeLodAmount = OCTREE_LOD_AMOUNT,
    OctreeSplitFactor = 3.5,
    Generator = Terra.MarchingCubes({
        Seed = 25,
        Vegetation = {
            Tree = {
                Radius = 25,
                Weight = 10,
                ChildSpawnRadius = 15,

                Children = {
                    Pinecone = {
                        Radius = 5,
                        Weight = 10
                    }
                }
            },

        },
    })
})

--Loader:SetDebugVisuals(true)

const DEBUG_INTERVAL = 1.0
local DebugAccum = 0.0

game:GetService("RunService").Heartbeat:Connect(function(deltaTime)
    Loader:Step(deltaTime)

    DebugAccum += deltaTime
    if DebugAccum < DEBUG_INTERVAL then return end
    DebugAccum -= DEBUG_INTERVAL

    --PrintStats(Loader:Stats())
end)

const function SetupCharacter(char: Model)
    local humanoid = (char :: any).Humanoid :: Humanoid

    Loader:SetTarget(char:WaitForChild("HumanoidRootPart"))
    humanoid.WalkSpeed = 250

    local conn
    conn = humanoid.Died:Connect(function()
        (conn :: RBXScriptConnection):Disconnect()

        Loader:SetTarget(SpawnLocation.Position)
    end)
end

Player.CharacterAdded:Connect(SetupCharacter);
SetupCharacter(Player.Character or Player.CharacterAdded:Wait())

--[[function PrintStats(stats: typeof(Loader:Stats()))
    local state = stats.State
    local queues = stats.Queues
    local budget = stats.Budget
    local octree = stats.Octree

    local sizes = {}
    for size in octree.LeavesBySize do
        sizes[#sizes + 1] = size
    end
    table.sort(sizes)

    local lodParts = {}
    for _, size in sizes do
        lodParts[#lodParts + 1] =
            string.format("%d=%d", size, octree.LeavesBySize[size])
    end

    print(string.format(
        "[Genesis] state=%d (c=%d a=%d d=%d) | loadQ=%d destroyQ=%d | budget L=%.4f D=%.4f | octree leaves=%d nodes=%d [%s]",
        state.Total, state.Creating, state.Alive, state.Destroying,
        queues.Load, queues.Destroy,
        budget.LoadSeconds, budget.DestroySeconds,
        octree.Leaves, octree.Nodes, table.concat(lodParts, " ")
    ))
end]]
