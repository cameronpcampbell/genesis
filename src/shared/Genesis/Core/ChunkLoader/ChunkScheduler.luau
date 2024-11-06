--!strict


--> Services ------------------------------------------------------------------------------------------
local RunService = game:GetService("RunService")
-------------------------------------------------------------------------------------------------------


--> Modules -------------------------------------------------------------------------------------------
local Config = require(script.Parent.Parent.Parent.Config)

local Chunk = require(script.Parent.Parent.Chunk)

local Utils = script.Parent.Parent.Parent.Utils
local Vector3HashTable = require(Utils.Vector3HashTable) 
-------------------------------------------------------------------------------------------------------


--> Variables -----------------------------------------------------------------------------------------
local ROOT_SIZE = Config.ROOT_SIZE
local RENDER_DISTANCE, RENDER_DIAMETER = Config.RENDER_DISTANCE, Config.RENDER_DIAMETER

local ChunksToCreateTable, ChunksToCreateTable_Add, ChunksToCreateTable_Find, ChunksToCreateTable_Remove = Vector3HashTable()
local ChunksToDestroyTable, ChunksToDestroyTable_Add, ChunksToDestroyTable_Find, ChunksToDestroyTable_Remove = Vector3HashTable()

local Heartbeat = RunService.Heartbeat
local HeartbeatWait = Heartbeat.Wait
-------------------------------------------------------------------------------------------------------


--> Functions -----------------------------------------------------------------------------------------
local function QueueOneChunkForCreation(rootX: number, rootY: number, rootZ: number)
    local x, y, z = rootX * ROOT_SIZE, rootY * ROOT_SIZE, rootZ * ROOT_SIZE

    -- Makes sure chunk is not queued for destruction.
    if ChunksToDestroyTable_Find(x, y, z) then
        ChunksToDestroyTable_Remove(x, y, z)
    end

    ChunksToCreateTable_Add(x, y, z)
end

local function QueueOneChunkForDestruction(rootX: number, rootY: number, rootZ: number)
    local x, y, z = rootX * ROOT_SIZE, rootY * ROOT_SIZE, rootZ * ROOT_SIZE

    -- Makes sure chunk is not queued for creation.
    if ChunksToCreateTable_Find(x, y, z) then
        ChunksToCreateTable_Remove(x, y, z)
    end

    ChunksToDestroyTable_Add(x, y, z)
end


local function QueueChunksForCreation(
    targetRootPosX: number, targetRootPosY: number, targetRootPosZ: number,
    diffX: number, diffY: number, diffZ: number
)
    local aXStart: number, dirX: number

    local diffXIsNotZero = diffX ~= 0
    if diffXIsNotZero then
        local absDiffX = math.abs(diffX); dirX = diffX / absDiffX

        local aXEnd = targetRootPosX + RENDER_DISTANCE * dirX; aXStart = aXEnd + dirX - math.min(absDiffX, RENDER_DIAMETER) * dirX

        local aZStart, aZEnd = targetRootPosZ - RENDER_DISTANCE, targetRootPosZ + RENDER_DISTANCE

        local aYStart, aYEnd = targetRootPosY - RENDER_DISTANCE, targetRootPosY + RENDER_DISTANCE

        for x = aXStart, aXEnd, dirX do
            for z = aZStart, aZEnd do
                for y = aYStart, aYEnd do
                    QueueOneChunkForCreation(x, y, z)
                end
            end
        end
    end

    local bZStart: number, dirZ: number

    local diffZIsNotZero = diffZ ~= 0
    if diffZIsNotZero then
        local absDiffZ = math.abs(diffZ); dirZ = diffZ / absDiffZ

        local bZEnd = targetRootPosZ + RENDER_DISTANCE * dirZ; bZStart = bZEnd + dirZ - math.min(absDiffZ, RENDER_DIAMETER) * dirZ

        local bXStart: number, bXEnd: number
        if not diffXIsNotZero then bXStart, bXEnd = targetRootPosX - RENDER_DISTANCE, targetRootPosX + RENDER_DISTANCE
        elseif dirX == 1 then bXStart, bXEnd = targetRootPosX - RENDER_DISTANCE, aXStart - 1
        else bXStart, bXEnd = aXStart + 1, targetRootPosX + RENDER_DISTANCE end

        local aYStart, aYEnd = targetRootPosY - RENDER_DISTANCE, targetRootPosY + RENDER_DISTANCE

        for x = bXStart, bXEnd do
            for z = bZStart, bZEnd, dirZ do
                for y = aYStart, aYEnd do
                    QueueOneChunkForCreation(x, y, z)
                end
            end
        end
    end

    if diffY ~= 0 then
        local absDiffY = math.abs(diffY); local dirY = diffY / absDiffY

        local cYEnd = targetRootPosY + RENDER_DISTANCE * dirY
        local cYStart = cYEnd + dirY - math.min(absDiffY, RENDER_DIAMETER) * dirY

        local cZStart: number, cZEnd: number
        if not diffZIsNotZero then cZStart, cZEnd = targetRootPosZ - RENDER_DISTANCE, targetRootPosZ + RENDER_DISTANCE
        elseif dirZ == 1 then cZStart, cZEnd = targetRootPosZ - RENDER_DISTANCE, bZStart - 1
        else cZStart, cZEnd = bZStart + 1, targetRootPosZ + RENDER_DISTANCE end

        local cXStart: number, cXEnd: number
        if not diffXIsNotZero then cXStart, cXEnd = targetRootPosX - RENDER_DISTANCE, targetRootPosX + RENDER_DISTANCE
        elseif dirX == 1 then cXStart, cXEnd = targetRootPosX - RENDER_DISTANCE, aXStart - 1
        else cXStart, cXEnd = aXStart + 1, targetRootPosX + RENDER_DISTANCE end

        for x = cXStart, cXEnd do
            for z = cZStart, cZEnd do
                for y = cYStart, cYEnd, dirY do
                    QueueOneChunkForCreation(x, y, z)
                end
            end
        end
    end
end


local function QueueChunksForDestruction(
    lastTargetRootPosX: number, lastTargetRootPosY: number, lastTargetRootPosZ: number,
    diffX: number, diffY: number, diffZ: number
)   
    local dirX: number

    local diffXIsNotZero = diffX ~= 0
    if diffXIsNotZero then
        local absDiffX = math.abs(diffX); dirX = diffX / absDiffX

        local aXStart = lastTargetRootPosX - RENDER_DISTANCE * dirX
        local aXEndOffset = math.min(absDiffX, RENDER_DIAMETER)
        local aXEnd = aXStart - dirX + aXEndOffset * dirX

        local aZStart, aZEnd = lastTargetRootPosZ - RENDER_DISTANCE, lastTargetRootPosZ + RENDER_DISTANCE

        local aYStart, aYEnd = lastTargetRootPosY - RENDER_DISTANCE, lastTargetRootPosY + RENDER_DISTANCE

        for x = aXStart, aXEnd, dirX do
            for z = aZStart, aZEnd do
                for y = aYStart, aYEnd do
                    QueueOneChunkForDestruction(x, y, z)
                end
            end
        end
    end
    
    local dirZ: number

    local diffZIsNotZero = diffZ ~= 0
    if diffZ ~= 0 then
        local absDiffZ = math.abs(diffZ); dirZ = diffZ / absDiffZ

        local bZStart = lastTargetRootPosZ - RENDER_DISTANCE * dirZ
        local bZEnd = bZStart - dirZ + math.min(absDiffZ, RENDER_DIAMETER) * dirZ

        local bXStart: number, bXEnd: number
        if not diffXIsNotZero then bXStart, bXEnd = lastTargetRootPosX - RENDER_DISTANCE, lastTargetRootPosX + RENDER_DISTANCE
        elseif dirX == 1 then bXStart, bXEnd = lastTargetRootPosX - RENDER_DISTANCE + diffX, lastTargetRootPosX + RENDER_DISTANCE
        else bXStart, bXEnd = lastTargetRootPosX - RENDER_DISTANCE, lastTargetRootPosX + RENDER_DISTANCE + diffX end

        local aYStart, aYEnd = lastTargetRootPosY - RENDER_DISTANCE, lastTargetRootPosY + RENDER_DISTANCE

        for x = bXStart, bXEnd do
            for z = bZStart, bZEnd, dirZ do
                for y = aYStart, aYEnd do
                    QueueOneChunkForDestruction(x, y, z)
                end
            end
        end
    end

    if diffY ~= 0 then
        local absDiffY = math.abs(diffY); local dirY = diffY / absDiffY

        local cYStart = lastTargetRootPosY - RENDER_DISTANCE * dirY
        local cYEnd = cYStart - dirY + math.min(absDiffY, RENDER_DIAMETER) * dirY

        local cZStart: number, cZEnd: number
        if not diffZIsNotZero then cZStart, cZEnd = lastTargetRootPosZ - RENDER_DISTANCE, lastTargetRootPosZ + RENDER_DISTANCE
        elseif dirZ == 1 then cZStart, cZEnd = lastTargetRootPosZ - RENDER_DISTANCE + diffZ, lastTargetRootPosZ + RENDER_DISTANCE
        else cZStart, cZEnd = lastTargetRootPosZ - RENDER_DISTANCE, lastTargetRootPosZ + RENDER_DISTANCE + diffZ end

        local cXStart: number, cXEnd: number
        if not diffXIsNotZero then cXStart, cXEnd = lastTargetRootPosX - RENDER_DISTANCE, lastTargetRootPosX + RENDER_DISTANCE
        elseif dirX == 1 then cXStart, cXEnd = lastTargetRootPosX - RENDER_DISTANCE + diffX, lastTargetRootPosX + RENDER_DISTANCE
        else cXStart, cXEnd = lastTargetRootPosX - RENDER_DISTANCE, lastTargetRootPosX + RENDER_DISTANCE + diffX end

        for x = cXStart, cXEnd do
            for z = cZStart, cZEnd do
                for y = cYStart, cYEnd, dirY do
                    QueueOneChunkForDestruction(x, y, z)
                end
            end
        end
    end
end


local function CreateChunk(pos: Vector3, color: Color3?, shape: Enum.PartType?)
    Chunk(pos.X, pos.Y, pos.Z, ROOT_SIZE)[1]()
end

local function DestroyChunk(pos: Vector3)
    local chunk = (workspace :: any).Folder:FindFirstChild(`{pos.X}:{pos.Y}:{pos.Z}`);
    (chunk :: any):Destroy()
end


local function CreateChunks()
    local idx = 0
    for v3Key,v3 in ChunksToCreateTable do
        CreateChunk(v3)
        ChunksToCreateTable_Remove(v3.X, v3.Y, v3.Z)
        if idx % 10 == 0 then HeartbeatWait(Heartbeat) end
        idx += 1
    end
end


local function DestroyChunks()
    local idx = 0
    for v3Key,v3 in ChunksToDestroyTable do
        DestroyChunk(v3)
        ChunksToDestroyTable_Remove(v3.X, v3.Y, v3.Z)
        if idx % 80 == 0 then HeartbeatWait(Heartbeat) end
        idx += 1
    end
end


local function InitialiseChunks(targetRootPosX: number, targetRootPosY: number, targetRootPosZ: number)
    local idx = 0
    for x = targetRootPosX - RENDER_DISTANCE, targetRootPosX + RENDER_DISTANCE do
        for z = targetRootPosZ - RENDER_DISTANCE, targetRootPosZ + RENDER_DISTANCE do
            for y = targetRootPosY - RENDER_DISTANCE, targetRootPosY + RENDER_DISTANCE do
                CreateChunk(Vector3.new(x, y, z) * ROOT_SIZE)
                if idx % 800 == 0 then HeartbeatWait(Heartbeat) end
                idx += 1
            end
        end
    end
end
-------------------------------------------------------------------------------------------------------


return {
    InitialiseChunks  = InitialiseChunks,

    QueueChunksForCreation = QueueChunksForCreation,
    QueueChunksForDestruction = QueueChunksForDestruction,

    CreateChunks = CreateChunks,
    DestroyChunks = DestroyChunks
}