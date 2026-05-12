--!strict
--!native

local Budget = require(script.budget)
type BudgetConfig = Budget.BudgetConfig
type BudgetState = Budget.BudgetState

local Reconciler = require(script.reconciler)
type Reconciler = Reconciler.Reconciler
type Generator = Reconciler.Generator

local DebugVisuals = require(script.debugVisuals)
type DebugVisuals = DebugVisuals.DebugVisuals

const HALF_VEC = vector.create(0.5, 0.5, 0.5)
const DEFAULT_SPLIT_FACTOR = 1.0
const BAND_COUNT = 3

type ChunkKey = vector

export type BaseChunkLoaderConfig = {
    ChunkSize: number,
    Generator: Generator,
    Target: any?,
    RenderDistance: number,
    OctreeLodAmount: number?,
    OctreeSplitFactor: number?,
    NearBandRadius: number?,
    MidBandRadius: number?,
    LoadBandPriority: { number }?,
}

-- Workaround for a solver bug with optional fields.
type ChunkLoaderConfig =
    | BaseChunkLoaderConfig
    | (BaseChunkLoaderConfig & { TargetPosition: (target: any) -> vector? })
    | (BaseChunkLoaderConfig & { Budget: BudgetConfig })
    | (BaseChunkLoaderConfig & { TargetPosition: (target: any) -> vector?, Budget: BudgetConfig })

export type LoaderStats = {
    State: {
        Total: number,
        Creating: number,
        Alive: number,
        Destroying: number,
    },
    Queues: {
        Load: number,
        LoadByBand: { number },
        Destroy: number,
        DestroyByBand: { number },
    },
    Budget: {
        LoadSeconds: { number },
        DestroySeconds: { number },
    },
    SLO: {
        LoadResidenceP95: { number },
        DestroyResidenceP95: { number },
        LoadHoLAgeSeconds: { number },
        DestroyHoLAgeSeconds: { number },
    },
    Octree: {
        Leaves: number,
        Nodes: number,
        LeavesBySize: { [number]: number },
    },
}

type ChunkLoader = {
    BaseLeafSize: number,
    RootSize: number,
    SplitFactor: number,
    Target: any,
    TargetPosition: (target: any) -> vector?,
    Budget: BudgetState,
    LastStepClock: number?,
    RenderDistance: number,
    LastX: number?,
    LastY: number?,
    LastZ: number?,
    Reconciler: Reconciler,
    DebugVisuals: DebugVisuals,
    SetTarget: (self: ChunkLoader, target: any) -> (),
    SetRenderDistance: (self: ChunkLoader, renderDistance: number) -> (),
    SetDebugVisuals: (self: ChunkLoader, enabled: boolean) -> (),
    Step: (self: ChunkLoader, deltaTime: number?) -> (),
    Stats: (self: ChunkLoader) -> LoaderStats,
}

const function DefaultTargetPosition(target: any): vector?
    return
        if type(target) == "vector" then target
        else ((target :: BasePart).Position :: any) :: vector
end

const function Direction(num: number): number
    return
        if num > 0 then 1
        elseif num < 0 then -1
        else 0
end

const function ChunkPos(pos: vector, gridSize: number): (number, number, number)
    local shifted = pos / gridSize + HALF_VEC
    return math.floor(shifted.x), math.floor(shifted.y), math.floor(shifted.z)
end

const function EnterRegion(
    self: ChunkLoader,
    fromX: number, fromY: number, fromZ: number,
    toX: number, toY: number, toZ: number
)
    debug.profilebegin("Genesis/Loader/EnterRegion")

    local reconciler = self.Reconciler
    local desired = reconciler.Desired
    local loadQueues = reconciler.LoadQueues
    local loadEnqueueClocks = reconciler.LoadEnqueueClocks
    local enqueueClocks = reconciler.EnqueueClocks
    local undesired = reconciler.Undesired

    local stepX = if fromX <= toX then 1 else -1
    local stepY = if fromY <= toY then 1 else -1
    local stepZ = if fromZ <= toZ then 1 else -1

    for chunkX = fromX, toX, stepX do
        for chunkY = fromY, toY, stepY do
            for chunkZ = fromZ, toZ, stepZ do
                local key = vector.create(chunkX, chunkY, chunkZ)

                if desired[key] == nil then
                    desired[key] = true
                    if undesired[key] then
                        -- Octree is still alive from a prior leave; just un-mark.
                        undesired[key] = nil
                        reconciler.UndesiredCount -= 1
                        enqueueClocks[key] = nil
                    else
                        local now = os.clock()
                        local band = Reconciler.ClassifyBand(reconciler, key)
                        loadQueues[band]:Push(key)
                        loadEnqueueClocks[band]:Push(now)
                        enqueueClocks[key] = now
                    end
                end
            end
        end
    end

    debug.profileend()
end

const function LeaveRegion(
    self: ChunkLoader,
    fromX: number, fromY: number, fromZ: number,
    toX: number, toY: number, toZ: number
)
    debug.profilebegin("Genesis/Loader/LeaveRegion")

    local reconciler = self.Reconciler
    local desired = reconciler.Desired
    local octrees = reconciler.Octrees
    local createInflight = reconciler.CreateInflight
    local undesired = reconciler.Undesired
    local enqueueClocks = reconciler.EnqueueClocks

    local stepX = if fromX <= toX then 1 else -1
    local stepY = if fromY <= toY then 1 else -1
    local stepZ = if fromZ <= toZ then 1 else -1

    for chunkX = fromX, toX, stepX do
        for chunkY = fromY, toY, stepY do
            for chunkZ = fromZ, toZ, stepZ do
                local key = vector.create(chunkX, chunkY, chunkZ)

                desired[key] = nil

                -- If the octree already exists and isn't mid-create, mark it for
                -- destruction. Mid-create keys are picked up post-create.
                if octrees[key] ~= nil and createInflight[key] == nil and undesired[key] == nil then
                    undesired[key] = true
                    reconciler.UndesiredCount += 1
                    enqueueClocks[key] = os.clock()
                end
            end
        end
    end

    debug.profileend()
end

const function FillCube(self: ChunkLoader, centerX: number, centerY: number, centerZ: number, dist: number)
    debug.profilebegin("Genesis/Loader/FillCube")

    EnterRegion(self, centerX, centerY, centerZ, centerX, centerY, centerZ)

    for shell = 1, dist do
        local inner = shell - 1
        EnterRegion(self, centerX + shell, centerY - shell, centerZ - shell, centerX + shell, centerY + shell, centerZ + shell)
        EnterRegion(self, centerX - shell, centerY - shell, centerZ - shell, centerX - shell, centerY + shell, centerZ + shell)
        EnterRegion(self, centerX - inner, centerY + shell, centerZ - shell, centerX + inner, centerY + shell, centerZ + shell)
        EnterRegion(self, centerX - inner, centerY - shell, centerZ - shell, centerX + inner, centerY - shell, centerZ + shell)
        EnterRegion(self, centerX - inner, centerY - inner, centerZ + shell, centerX + inner, centerY + inner, centerZ + shell)
        EnterRegion(self, centerX - inner, centerY - inner, centerZ - shell, centerX + inner, centerY + inner, centerZ - shell)
    end

    debug.profileend()
end

const function ClearCube(self: ChunkLoader, centerX: number, centerY: number, centerZ: number, dist: number)
    debug.profilebegin("Genesis/Loader/ClearCube")

    for shell = dist, 1, -1 do
        local inner = shell - 1
        LeaveRegion(self, centerX + shell, centerY - shell, centerZ - shell, centerX + shell, centerY + shell, centerZ + shell)
        LeaveRegion(self, centerX - shell, centerY - shell, centerZ - shell, centerX - shell, centerY + shell, centerZ + shell)
        LeaveRegion(self, centerX - inner, centerY + shell, centerZ - shell, centerX + inner, centerY + shell, centerZ + shell)
        LeaveRegion(self, centerX - inner, centerY - shell, centerZ - shell, centerX + inner, centerY - shell, centerZ + shell)
        LeaveRegion(self, centerX - inner, centerY - inner, centerZ + shell, centerX + inner, centerY + inner, centerZ + shell)
        LeaveRegion(self, centerX - inner, centerY - inner, centerZ - shell, centerX + inner, centerY + inner, centerZ - shell)
    end

    LeaveRegion(self, centerX, centerY, centerZ, centerX, centerY, centerZ)

    debug.profileend()
end

const function DiffRenderDist(
    self: ChunkLoader,
    centerX: number, centerY: number, centerZ: number,
    oldDist: number, newDist: number
)
    debug.profilebegin("Genesis/Loader/DiffRenderDist")

    local growing = newDist > oldDist
    local innerDist, outerDist = oldDist, newDist
    if not growing then
        innerDist, outerDist = newDist, oldDist
    end

    if growing then
        EnterRegion(self, centerX + innerDist + 1, centerY - outerDist, centerZ - outerDist, centerX + outerDist, centerY + outerDist, centerZ + outerDist)
        EnterRegion(self, centerX - outerDist, centerY - outerDist, centerZ - outerDist, centerX - innerDist - 1, centerY + outerDist, centerZ + outerDist)
        EnterRegion(self, centerX - innerDist, centerY + innerDist + 1, centerZ - outerDist, centerX + innerDist, centerY + outerDist, centerZ + outerDist)
        EnterRegion(self, centerX - innerDist, centerY - outerDist, centerZ - outerDist, centerX + innerDist, centerY - innerDist - 1, centerZ + outerDist)
        EnterRegion(self, centerX - innerDist, centerY - innerDist, centerZ + innerDist + 1, centerX + innerDist, centerY + innerDist, centerZ + outerDist)
        EnterRegion(self, centerX - innerDist, centerY - innerDist, centerZ - outerDist, centerX + innerDist, centerY + innerDist, centerZ - innerDist - 1)
    else
        LeaveRegion(self, centerX + innerDist + 1, centerY - outerDist, centerZ - outerDist, centerX + outerDist, centerY + outerDist, centerZ + outerDist)
        LeaveRegion(self, centerX - outerDist, centerY - outerDist, centerZ - outerDist, centerX - innerDist - 1, centerY + outerDist, centerZ + outerDist)
        LeaveRegion(self, centerX - innerDist, centerY + innerDist + 1, centerZ - outerDist, centerX + innerDist, centerY + outerDist, centerZ + outerDist)
        LeaveRegion(self, centerX - innerDist, centerY - outerDist, centerZ - outerDist, centerX + innerDist, centerY - innerDist - 1, centerZ + outerDist)
        LeaveRegion(self, centerX - innerDist, centerY - innerDist, centerZ + innerDist + 1, centerX + innerDist, centerY + innerDist, centerZ + outerDist)
        LeaveRegion(self, centerX - innerDist, centerY - innerDist, centerZ - outerDist, centerX + innerDist, centerY + innerDist, centerZ - innerDist - 1)
    end

    debug.profileend()
end

const function DiffMovement(
    self: ChunkLoader,
    oldX: number, oldY: number, oldZ: number,
    newX: number, newY: number, newZ: number,
    renderDist: number
)
    debug.profilebegin("Genesis/Loader/DiffMovement")

    local renderDiam = renderDist * 2 + 1
    local diffX = newX - oldX
    local diffY = newY - oldY
    local diffZ = newZ - oldZ

    local clampedDiffX = if math.abs(diffX) <= renderDiam - 1 then diffX else 0
    local clampedDiffZ = if math.abs(diffZ) <= renderDiam - 1 then diffZ else 0

    local dirXRenderDist = renderDist
    local xHasOverlap = false

    if diffX ~= 0 then
        local dirX = Direction(diffX)
        dirXRenderDist = renderDist * dirX

        local gapXMain = math.abs(diffX) - renderDist * 2 - 1
        local gapX = math.max(gapXMain, 0) * dirX
        xHasOverlap = gapXMain < 0

        EnterRegion(self,
            oldX + dirXRenderDist + dirX + gapX, newY - renderDist, newZ - renderDist,
            newX + dirXRenderDist, newY + renderDist, newZ + renderDist
        )

        LeaveRegion(self,
            oldX - dirXRenderDist, oldY - renderDist, oldZ - renderDist,
            newX - dirXRenderDist - dirX - gapX, oldY + renderDist, oldZ + renderDist
        )
    end

    local xHasOverlapOrUnchanged = xHasOverlap or diffX == 0

    local dirZRenderDist = renderDist
    local zHasOverlap = false

    if xHasOverlapOrUnchanged and diffZ ~= 0 then
        local dirZ = Direction(diffZ)
        dirZRenderDist = renderDist * dirZ

        local gapZMain = math.abs(diffZ) - renderDist * 2 - 1
        local gapZ = math.max(gapZMain, 0) * dirZ
        zHasOverlap = gapZMain < 0

        EnterRegion(self,
            newX - dirXRenderDist, newY - renderDist, oldZ + dirZRenderDist + dirZ + gapZ,
            newX + dirXRenderDist - clampedDiffX, newY + renderDist, newZ + dirZRenderDist
        )

        LeaveRegion(self,
            oldX - dirXRenderDist + clampedDiffX, oldY - renderDist, oldZ - dirZRenderDist,
            oldX + dirXRenderDist, oldY + renderDist, newZ - dirZRenderDist - dirZ - gapZ
        )
    end

    local zHasOverlapOrUnchanged = zHasOverlap or diffZ == 0

    if xHasOverlapOrUnchanged and zHasOverlapOrUnchanged and diffY ~= 0 then
        local dirY = Direction(diffY)
        local dirYRenderDist = renderDist * dirY

        local gapYMain = math.abs(diffY) - renderDist * 2 - 1
        local gapY = math.max(gapYMain, 0) * dirY

        EnterRegion(self,
            newX - dirXRenderDist, oldY + dirYRenderDist + dirY + gapY, newZ - dirZRenderDist,
            newX + dirXRenderDist - clampedDiffX, newY + dirYRenderDist, newZ + dirZRenderDist - clampedDiffZ
        )

        LeaveRegion(self,
            oldX - dirXRenderDist + clampedDiffX, oldY - dirYRenderDist, oldZ - dirZRenderDist + clampedDiffZ,
            oldX + dirXRenderDist, newY - dirYRenderDist - dirY - gapY, oldZ + dirZRenderDist
        )
    end

    debug.profileend()
end

const function PollTarget(self: ChunkLoader)
    if self.Target == nil then return end
    local pos = self.TargetPosition(self.Target)
    if not pos then return end

    debug.profilebegin("Genesis/Loader/PollTarget")

    local newX, newY, newZ = ChunkPos(pos, self.RootSize)

    self.Reconciler.Target = pos
    self.Reconciler.TargetChunk = vector.create(newX, newY, newZ)

    local renderDistance, lastX = self.RenderDistance, self.LastX

    if lastX == nil then
        FillCube(self, newX, newY, newZ, renderDistance)

    else
        local lastY, lastZ = self.LastY :: number, self.LastZ :: number

        if lastX == newX and lastY == newY and lastZ == newZ then
            debug.profileend()
            return
        end

        DiffMovement(self, lastX, lastY, lastZ, newX, newY, newZ, renderDistance)
    end

    self.LastX = newX
    self.LastY = newY
    self.LastZ = newZ

    debug.profileend()
end

const function SetTarget(self: ChunkLoader, target: any?)
    debug.profilebegin("Genesis/Loader/SetTarget")

    if self.LastX ~= nil then
        ClearCube(
            self,
            self.LastX :: number,
            self.LastY :: number,
            self.LastZ :: number,
            self.RenderDistance
        )
    end

    self.Target = target
    self.LastX = nil
    self.LastY = nil
    self.LastZ = nil
    self.Reconciler.Target = nil
    self.Reconciler.TargetChunk = nil

    if target ~= nil then
        PollTarget(self)
    end

    debug.profileend()
end

const function SetRenderDistance(self: ChunkLoader, newRenderDistance: number)
    debug.profilebegin("Genesis/Loader/SetRenderDistance")

    local oldRenderDistance = self.RenderDistance

    if newRenderDistance ~= oldRenderDistance and self.LastX ~= nil then
        PollTarget(self)

        local lastX, lastY, lastZ =
            self.LastX, self.LastY :: number, self.LastZ :: number

        DiffRenderDist(self, lastX, lastY, lastZ, oldRenderDistance, newRenderDistance)
    end

    self.RenderDistance = newRenderDistance

    debug.profileend()
end

const function SetDebugVisuals(self: ChunkLoader, enabled: boolean)
    self.DebugVisuals:SetEnabled(enabled)
end

const ZERO_BAND_TABLE = table.create(BAND_COUNT, 0)

const function Stats(self: ChunkLoader): LoaderStats
    debug.profilebegin("Genesis/Loader/Stats")

    local reconciler = self.Reconciler
    local rstats = reconciler:Stats()

    local adaptive = self.Budget.Adaptive
    local loadP95: { number } = if adaptive then adaptive.LastLoadP95 else ZERO_BAND_TABLE
    local loadHoL: { number } = if adaptive then adaptive.LastLoadHoLAge else ZERO_BAND_TABLE
    local destroyP95: { number } = if adaptive then adaptive.LastDestroyP95 else ZERO_BAND_TABLE
    local destroyHoL: { number } = if adaptive then adaptive.LastDestroyHoLAge else ZERO_BAND_TABLE

    debug.profileend()

    return {
        State = {
            Total = rstats.Desired,
            Creating = rstats.CreateInflight,
            Alive = rstats.Octrees - rstats.CreateInflight,
            Destroying = rstats.DestroyInflight,
        },
        Queues = {
            Load = rstats.PendingCreate,
            LoadByBand = rstats.PendingCreateByBand,
            Destroy = rstats.PendingDestroy,
            DestroyByBand = rstats.PendingDestroyByBand,
        },
        Budget = {
            LoadSeconds = self.Budget.LoadSeconds,
            DestroySeconds = self.Budget.DestroySeconds,
        },
        SLO = {
            LoadResidenceP95 = loadP95,
            DestroyResidenceP95 = destroyP95,
            LoadHoLAgeSeconds = loadHoL,
            DestroyHoLAgeSeconds = destroyHoL,
        },
        Octree = rstats.Octree,
    }
end

const function Step(self: ChunkLoader, deltaTime: number?)
    local now = os.clock()

    local resolvedDt: number? = deltaTime
    if resolvedDt == nil and self.LastStepClock ~= nil then
        resolvedDt = now - self.LastStepClock
    end

    self.LastStepClock = now

    local reconciler = self.Reconciler

    if resolvedDt ~= nil then
        local loadQueueLens = table.create(BAND_COUNT, 0)
        local loadHoLAges = table.create(BAND_COUNT, 0)
        for band = 1, BAND_COUNT do
            loadQueueLens[band] = reconciler.LoadQueues[band]:Len()
            local oldest = reconciler:OldestLoadEnqueueClock(band)
            loadHoLAges[band] = if oldest ~= nil then now - oldest else 0
        end

        local destroyQueueLens = table.create(BAND_COUNT, 0)
        local destroyOldest: { number? } = table.create(BAND_COUNT)
        reconciler:AggregateUndesiredByBand(destroyQueueLens, destroyOldest)
        local destroyHoLAges = table.create(BAND_COUNT, 0)
        for band = 1, BAND_COUNT do
            local oldest = destroyOldest[band]
            destroyHoLAges[band] = if oldest ~= nil then now - oldest else 0
        end

        Budget.Adapt(
            self.Budget,
            reconciler.LoadResidenceHists,
            reconciler.DestroyResidenceHists,
            resolvedDt,
            reconciler.LastChunkWorkSeconds,
            loadQueueLens,
            destroyQueueLens,
            loadHoLAges,
            destroyHoLAges
        )
    end

    local budget = self.Budget
    local reconcilerLoadBudgets = reconciler.LoadBudgetSeconds
    local reconcilerDestroyBudgets = reconciler.DestroyBudgetSeconds
    for band = 1, BAND_COUNT do
        reconcilerLoadBudgets[band] = budget.LoadSeconds[band]
        reconcilerDestroyBudgets[band] = budget.DestroySeconds[band]
    end
    reconciler.LastChunkWorkSeconds = 0

    PollTarget(self)

    reconciler:Run()
end

const function ChunkLoader(config: ChunkLoaderConfig): ChunkLoader
    local budget = (config :: any).Budget :: BudgetConfig?
    local loadBandPriority = (config :: any).LoadBandPriority :: { number }?
    local budgetState = Budget.Resolve(budget, loadBandPriority)

    local octreeLodAmount = (config :: any).OctreeLodAmount or 1
    local rootSize = config.ChunkSize * 2 ^ (octreeLodAmount - 1)
    local octreeSplitFactor = (config :: any).OctreeSplitFactor or DEFAULT_SPLIT_FACTOR

    local renderDistance = config.RenderDistance
    local nearBandRadius =
        (config :: any).NearBandRadius or math.max(1, math.floor(renderDistance / 3))
    local midBandRadius =
        (config :: any).MidBandRadius or math.max(nearBandRadius + 1, math.floor(renderDistance * 2 / 3))

    local reconciler = Reconciler.New({
        BaseLeafSize = config.ChunkSize,
        LodAmount = octreeLodAmount,
        SplitFactor = octreeSplitFactor,
        Generator = config.Generator,
        NearBandRadius = nearBandRadius,
        MidBandRadius = midBandRadius,
    })

    local self: ChunkLoader = {
        BaseLeafSize = config.ChunkSize,
        RootSize = rootSize,
        SplitFactor = octreeSplitFactor,
        Target = config.Target,
        TargetPosition = (config :: any).TargetPosition or DefaultTargetPosition,
        Budget = budgetState,
        LastStepClock = nil,
        RenderDistance = renderDistance,
        LastX = nil,
        LastY = nil,
        LastZ = nil,
        Reconciler = reconciler,
        DebugVisuals = DebugVisuals.New(reconciler),
        SetTarget = SetTarget,
        SetRenderDistance = SetRenderDistance,
        SetDebugVisuals = SetDebugVisuals,
        Step = Step,
        Stats = Stats,
    }

    if self.Target ~= nil then
        PollTarget(self)
    end

    return self
end

return ChunkLoader
