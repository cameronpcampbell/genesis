--!strict
--!native

local Strata = require(script.Parent.Parent.Parent.strata)

export type Generator = {
    Create: (positionGroups: { { vector } }, sizes: { vector }) -> (),
    Destroy: (positions: { vector }) -> (),
    Sample: (center: vector) -> number,
}

local RingBuffer = require(script.Parent.Parent.Parent.utils.ringBuffer)
type RingBuffer<T> = RingBuffer.RingBuffer<T>

const COST_SMOOTHING = 0.3
const DEFAULT_DESTROY_ITEM_COST = 0.0001
const DEFAULT_LOAD_ITEM_COST = 0.001
const LOAD_QUEUE_INITIAL_CAPACITY = 64

type ChunkKey = vector

export type ReconcilerConfig = {
    BaseLeafSize: number,
    LodAmount: number,
    SplitFactor: number,
    Generator: Generator,
}

export type ReconcilerStats = {
    Desired: number,
    Octrees: number,
    CreateInflight: number,
    DestroyInflight: number,
    PendingCreate: number,
    PendingDestroy: number,
    Octree: Strata.Stats,
}

export type Reconciler = {
    Desired: { [ChunkKey]: true },
    LoadQueue: RingBuffer<ChunkKey>,
    CreateInflight: { [ChunkKey]: true },
    DestroyInflight: { [ChunkKey]: true },
    Octrees: { [ChunkKey]: Strata.Strata },
    Undesired: { [ChunkKey]: true },
    UndesiredCount: number,
    Reconciling: boolean,
    Target: vector?,

    BaseLeafSize: number,
    LodAmount: number,
    SplitFactor: number,
    Generator: Generator,

    LoadItemCost: number,
    DestroyItemCost: number,
    LastChunkWorkSeconds: number,
    LoadBudgetSeconds: number,
    DestroyBudgetSeconds: number,

    LoadBatch: { { vector } },
    SizeBatch: { vector },
    DestroyBatch: { vector },
    ToCreate: { ChunkKey },
    ToDestroy: { ChunkKey },
    DestroyCandidates: { ChunkKey },

    Run: (self: Reconciler) -> (),
    Stats: (self: Reconciler) -> ReconcilerStats,
}

const function AppendDiff(
    loadBatch: { { vector } }, sizeBatch: { vector }, destroyBatch: { vector },
    diff: Strata.Diff
)
    local created, createdSizes, destroyed =
        diff.Created, diff.CreatedSizes, diff.Destroyed

    local loadLen = #loadBatch
    for idx = 1, #created do
        loadBatch[loadLen + idx] = created[idx]
        sizeBatch[loadLen + idx] = createdSizes[idx]
    end

    local destroyLen = #destroyBatch
    for idx = 1, #destroyed do
        destroyBatch[destroyLen + idx] = destroyed[idx]
    end
end

const function PredictLoadCost(diff: Strata.Diff, itemCost: number): number
    local count = 0
    local created = diff.Created

    for i = 1, #created do
        count += #created[i]
    end

    return count * itemCost
end

const function PredictDestroyCost(diff: Strata.Diff, itemCost: number): number
    return #diff.Destroyed * itemCost
end

const function LoopBody(self: Reconciler)
    local octrees, desired = self.Octrees, self.Desired
    local loadQueue = self.LoadQueue
    local createInflight, destroyInflight =
        self.CreateInflight, self.DestroyInflight
    local undesired = self.Undesired
    local baseLeafSize, lodAmount, splitFactor =
        self.BaseLeafSize, self.LodAmount, self.SplitFactor
    local rootSize = baseLeafSize * 2 ^ (lodAmount - 1)
    local generator = self.Generator
    local sample = generator.Sample
    local loadBudget = self.LoadBudgetSeconds
    local destroyBudget = self.DestroyBudgetSeconds

    local loadBatch = self.LoadBatch
    local sizeBatch = self.SizeBatch
    local destroyBatch = self.DestroyBatch
    local toCreate = self.ToCreate
    local toDestroy = self.ToDestroy
    local destroyCandidates = self.DestroyCandidates

    local loadElapsed = 0
    local destroyElapsed = 0

    while true do
        if loadElapsed >= loadBudget and destroyElapsed >= destroyBudget then break end

        local target = self.Target
        local loadItemCost = self.LoadItemCost
        local destroyItemCost = self.DestroyItemCost

        table.clear(loadBatch)
        table.clear(sizeBatch)
        table.clear(destroyBatch)
        local toCreateN = 0
        local toDestroyN = 0

        local predictedLoad = 0
        local predictedDestroy = 0

        local workStart = os.clock()
        local loadStructuralStart = workStart

        if target ~= nil then
            local committed = false
            for key, octree in octrees do
                if not desired[key] then continue end
                if createInflight[key] then continue end

                local liveLoadElapsed = loadElapsed + (os.clock() - loadStructuralStart)

                if committed and (liveLoadElapsed + predictedLoad >= loadBudget
                    or destroyElapsed + predictedDestroy >= destroyBudget)
                then break end

                local diff = octree:SetTarget(target)
                if diff ~= nil then
                    AppendDiff(loadBatch, sizeBatch, destroyBatch, diff)
                    predictedLoad += PredictLoadCost(diff, loadItemCost)
                    predictedDestroy += PredictDestroyCost(diff, destroyItemCost)
                    committed = true
                end
            end
        end

        local consumed = 0
        local committed = false
        local queueLen = loadQueue:Len()
        for idx = 1, queueLen do
            local key = loadQueue:At(idx)

            if desired[key] == nil or octrees[key] or createInflight[key] then
                consumed = idx
                continue
            end

            local liveLoadElapsed = loadElapsed + (os.clock() - loadStructuralStart)
            if committed and (liveLoadElapsed + predictedLoad >= loadBudget
                or destroyElapsed + predictedDestroy >= destroyBudget) then break end

            local octree = Strata.New({
                RootCenter = key * rootSize,
                BaseLeafSize = baseLeafSize,
                LodAmount = lodAmount,
                SplitFactor = splitFactor,
                Sample = sample,
            })

            octrees[key] = octree
            createInflight[key] = true
            toCreateN += 1
            toCreate[toCreateN] = key
            consumed = idx
            committed = true

            if target == nil then continue end

            local diff = octree:SetTarget(target)
            if diff ~= nil then
                AppendDiff(loadBatch, sizeBatch, destroyBatch, diff)
                predictedLoad += PredictLoadCost(diff, loadItemCost)
                predictedDestroy += PredictDestroyCost(diff, destroyItemCost)
            end
        end

        loadElapsed += os.clock() - loadStructuralStart

        if consumed > 0 then
            loadQueue:Discard(consumed)
        end

        local destroyStructuralStart = os.clock()

        table.clear(destroyCandidates)
        local destroyCandidateN = 0

        for key in undesired do
            destroyCandidateN += 1
            destroyCandidates[destroyCandidateN] = key
        end

        local destroyCommitted = false
        for idx = 1, destroyCandidateN do
            local liveDestroyElapsed = destroyElapsed + (os.clock() - destroyStructuralStart)
            if destroyCommitted and liveDestroyElapsed + predictedDestroy >= destroyBudget then break end

            local key = destroyCandidates[idx]
            local octree = octrees[key]
            local leaves = octree:Destroy()

            local destroyLen = #destroyBatch
            for lidx = 1, #leaves do
                destroyBatch[destroyLen + lidx] = leaves[lidx]
            end

            octrees[key] = nil
            undesired[key] = nil
            self.UndesiredCount -= 1
            destroyInflight[key] = true
            toDestroyN += 1
            toDestroy[toDestroyN] = key
            predictedDestroy += #leaves * destroyItemCost
            destroyCommitted = true
        end

        destroyElapsed += os.clock() - destroyStructuralStart

        if #loadBatch == 0 and #destroyBatch == 0 then
            self.LastChunkWorkSeconds += os.clock() - workStart
            break
        end

        if #loadBatch > 0 then
            local startClock = os.clock()
            generator.Create(loadBatch, sizeBatch)

            -- Cleared keys whose desire flipped while create was in flight now
            -- become pending destroys.
            for idx = 1, toCreateN do
                local key = toCreate[idx]
                createInflight[key] = nil
                if desired[key] == nil and undesired[key] == nil then
                    undesired[key] = true
                    self.UndesiredCount += 1
                end
            end

            local elapsed = os.clock() - startClock
            loadElapsed += elapsed

            local totalCount = 0
            for i = 1, #loadBatch do
                totalCount += #loadBatch[i]
            end

            if totalCount > 0 then
                local measured = elapsed / totalCount
                self.LoadItemCost =
                    COST_SMOOTHING * measured + (1 - COST_SMOOTHING) * self.LoadItemCost
            end
        end

        if #destroyBatch > 0 then
            local startClock = os.clock()
            generator.Destroy(destroyBatch)

            for idx = 1, toDestroyN do
                destroyInflight[toDestroy[idx]] = nil
            end

            local elapsed = os.clock() - startClock
            destroyElapsed += elapsed

            local count = #destroyBatch
            if count > 0 then
                local measured = elapsed / count

                self.DestroyItemCost =
                    COST_SMOOTHING * measured + (1 - COST_SMOOTHING) * self.DestroyItemCost
            end
        end

        self.LastChunkWorkSeconds += os.clock() - workStart
    end
end

const function Run(self: Reconciler)
    if self.Reconciling then return end
    self.Reconciling = true

    local ok, err = pcall(LoopBody, self)
    self.Reconciling = false

    if not ok then error(err) end
end

const function GetStats(self: Reconciler): ReconcilerStats
    debug.profilebegin("Genesis/Reconciler/Stats")

    local desired = self.Desired
    local octrees = self.Octrees
    local createInflight = self.CreateInflight
    local destroyInflight = self.DestroyInflight

    local desiredN = 0
    for _ in desired do desiredN += 1 end

    local octreesN = 0
    for _ in octrees do octreesN += 1 end

    local createInflightN = 0
    for _ in createInflight do createInflightN += 1 end

    local destroyInflightN = 0
    for _ in destroyInflight do destroyInflightN += 1 end

    local pendingCreate = 0
    for key in desired do
        if octrees[key] then continue end
        if createInflight[key] then continue end

        pendingCreate += 1
    end

    local pendingDestroy = self.UndesiredCount

    local octreeStats: Strata.Stats = {
        Leaves = 0,
        Nodes = 0,
        LeavesBySize = {},
    }

    for key, octree in octrees do
        if createInflight[key] then continue end

        octree:Stats(octreeStats)
    end

    debug.profileend()

    return {
        Desired = desiredN,
        Octrees = octreesN,
        CreateInflight = createInflightN,
        DestroyInflight = destroyInflightN,
        PendingCreate = pendingCreate,
        PendingDestroy = pendingDestroy,
        Octree = octreeStats,
    }
end

local Reconciler = {}

function Reconciler.New(config: ReconcilerConfig): Reconciler
    return {
        Desired = {},
        LoadQueue = RingBuffer.New<<vector>>(LOAD_QUEUE_INITIAL_CAPACITY),
        CreateInflight = {},
        DestroyInflight = {},
        Octrees = {},
        Undesired = {},
        UndesiredCount = 0,
        Reconciling = false,
        Target = nil,

        BaseLeafSize = config.BaseLeafSize,
        LodAmount = config.LodAmount,
        SplitFactor = config.SplitFactor,
        Generator = config.Generator,

        LoadItemCost = DEFAULT_LOAD_ITEM_COST,
        DestroyItemCost = DEFAULT_DESTROY_ITEM_COST,
        LastChunkWorkSeconds = 0,
        LoadBudgetSeconds = math.huge,
        DestroyBudgetSeconds = math.huge,

        LoadBatch = {},
        SizeBatch = {},
        DestroyBatch = {},
        ToCreate = {},
        ToDestroy = {},
        DestroyCandidates = {},

        Run = Run,
        Stats = GetStats,
    }
end

return Reconciler
