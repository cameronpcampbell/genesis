--!strict
--!optimize 2
--!native


--> Services ------------------------------------------------------------------------------------------
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
-------------------------------------------------------------------------------------------------------


--> Modules -------------------------------------------------------------------------------------------
local Config = require(script.Parent.Parent.Config)
local ChunkScheduler = require(script.ChunkScheduler)
-------------------------------------------------------------------------------------------------------


--> Types ---------------------------------------------------------------------------------------------
local ROOT_SIZE, ROOT_SIZE_MULTIPLYER = Config.ROOT_SIZE, Config.ROOT_SIZE_MULTIPLYER
-------------------------------------------------------------------------------------------------------


--> Variables -----------------------------------------------------------------------------------------
local InitialiseChunks, QueueChunksForCreation, QueueChunksForDestruction, CreateChunks, DestroyChunks = 
    ChunkScheduler.InitialiseChunks,
    ChunkScheduler.QueueChunksForCreation, ChunkScheduler.QueueChunksForDestruction,
    ChunkScheduler.CreateChunks, ChunkScheduler.DestroyChunks

local Heartbeat = RunService.Heartbeat
local HeartbeatWait = Heartbeat.Wait

local MANUAL_MODE = false
-------------------------------------------------------------------------------------------------------


--> Functions -----------------------------------------------------------------------------------------
local function ManualModeControls()
    local chunkPosUI = Instance.new("ScreenGui")
    chunkPosUI.Parent = Players.LocalPlayer.PlayerGui
    
    local xPos = Instance.new("TextBox")
    xPos.Size = UDim2.fromOffset(200, 50)
    xPos.Position = UDim2.fromOffset(25, 25)
    xPos.Text = "3"
    xPos.Parent = chunkPosUI

    local yPos = Instance.new("TextBox")
    yPos.Size = UDim2.fromOffset(200, 50)
    yPos.Position = UDim2.fromOffset(250, 25)
    yPos.Text = "-2"
    yPos.Parent = chunkPosUI

    local zPos = Instance.new("TextBox")
    zPos.Size = UDim2.fromOffset(200, 50)
    zPos.Position = UDim2.fromOffset(475, 25)
    zPos.Text = "-4"
    zPos.Parent = chunkPosUI

    
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.fromOffset(200, 50)
    btn.Position = UDim2.fromOffset(700, 25)
    btn.Text = "Update"
    btn.Parent = chunkPosUI

    return xPos, yPos, zPos, btn
end
-------------------------------------------------------------------------------------------------------


return function(target: any & { Position: Vector3 })
    Players.LocalPlayer.CameraMaxZoomDistance = 999999999;
    (target :: any).Parent.Humanoid.WalkSpeed = 400

    local targetPos = target.Position
    local lastTargetRootPosX = math.floor(targetPos.X * ROOT_SIZE_MULTIPLYER + .5)
    local lastTargetRootPosY = math.floor(targetPos.Y * ROOT_SIZE_MULTIPLYER + .5)
    local lastTargetRootPosZ = math.floor(targetPos.Z * ROOT_SIZE_MULTIPLYER + .5)

    InitialiseChunks(lastTargetRootPosX, lastTargetRootPosY, lastTargetRootPosZ)

    --[[local update, xPos, yPos, zPos, btn = false, nil, nil, nil, nil
    if MANUAL_MODE then
        (target :: any).Anchored = true
        xPos, yPos, zPos, btn = ManualModeControls()

        btn.MouseButton1Click:Connect(function() update = true end)
    end]]

    task.spawn(function()
        while HeartbeatWait(Heartbeat) do
            local targetPos = target.Position;
            (workspace:WaitForChild("Baseplate") :: any).Position = Vector3.new(targetPos.X, (workspace :: any).Baseplate.Position.Y, targetPos.Z)
        end
    end)

    while HeartbeatWait(Heartbeat) do
        

        CreateChunks()
        DestroyChunks()

        local targetPos = target.Position
        local targetRootPosX = math.floor(targetPos.X * ROOT_SIZE_MULTIPLYER + .5)
        local targetRootPosY = math.floor(targetPos.Y * ROOT_SIZE_MULTIPLYER + .5)
        local targetRootPosZ = math.floor(targetPos.Z * ROOT_SIZE_MULTIPLYER + .5)

        --[[if MANUAL_MODE then
            if not update then continue end

            local xPosValue: number?, yPosValue: number?, zPosValue: number? = tonumber(xPos.Text), tonumber(yPos.Text), tonumber(zPos.Text)
            if xPosValue == nil or yPosValue == nil or zPosValue == nil then continue end
            update = false

            (target :: any).Parent:MoveTo(Vector3.new(xPosValue * ROOT_SIZE, yPosValue * ROOT_SIZE, zPosValue * ROOT_SIZE))

            targetPos = Vector3.new(xPosValue * ROOT_SIZE, yPosValue * ROOT_SIZE, zPosValue * ROOT_SIZE)
        end]]

        local diffX, diffY, diffZ =
            targetRootPosX - lastTargetRootPosX, targetRootPosY - lastTargetRootPosY, targetRootPosZ - lastTargetRootPosZ
        if diffX == 0 and diffY == 0 and diffZ == 0 then continue end

        QueueChunksForCreation(targetRootPosX, targetRootPosY, targetRootPosZ, diffX, diffY, diffZ)
        QueueChunksForDestruction(lastTargetRootPosX, lastTargetRootPosY, lastTargetRootPosZ, diffX, diffY, diffZ)
        
        lastTargetRootPosX, lastTargetRootPosY, lastTargetRootPosZ = targetRootPosX, targetRootPosY, targetRootPosZ
    end
end