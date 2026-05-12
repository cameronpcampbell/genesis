--!strict
--!native

local Strata = require(script.Parent.Parent.Parent.strata)
local ResidenceHistogram = require(script.Parent.residenceHistogram)

export type InitConfig = {
    ChunkSize: number,
    OctreeLodAmount: number,
}

export type Generator = {
    Init: (config: InitConfig) -> (),
    Create: (position: vector, size: vector) -> (),
    Destroy: (position: vector) -> (),
    Sample: (center: vector) -> number,
}

local RingBuffer = require(script.Parent.Parent.Parent.utils.ringBuffer)
type RingBuffer<T> = RingBuffer.RingBuffer<T>
type ResidenceHistogram = ResidenceHistogram.ResidenceHistogram

const COST_SMOOTHING = 0.5
const COST_MAX_DECAY = 0.95
const DEFAULT_DESTROY_ITEM_COST = 0.0001
const DEFAULT_LOAD_ITEM_COST = 0.001
const LOAD_QUEUE_INITIAL_CAPACITY = 64
const BAND_COUNT = 3

type ChunkKey = vector

export type ReconcilerConfig = {
    BaseLeafSize: number,
    LodAmount: number,
    SplitFactor: number,
    Generator: Generator,
    NearBandRadius: number,
    MidBandRadius: number,
}

export type ReconcilerStats = {
    Desired: number,
    Octrees: number,
    CreateInflight: number,
    DestroyInflight: number,
    PendingCreate: number,
    PendingCreateByBand: { number },
    PendingDestroy: number,
    Octree: Strata.Stats,
}

export type Reconciler = {
    Desired: { [ChunkKey]: true },
    LoadQueues: { RingBuffer<ChunkKey> },
    LoadEnqueueClocks: { RingBuffer<number> },
    EnqueueClocks: { [ChunkKey]: number },
    CreateInflight: { [ChunkKey]: true },
    DestroyInflight: { [ChunkKey]: true },
    Octrees: { [ChunkKey]: Strata.Strata },
    Undesired: { [ChunkKey]: true },
    UndesiredCount: number,
    Reconciling: boolean,
    Target: vector?,
    TargetChunk: vector?,
    LoadResidenceHists: { ResidenceHistogram },
    DestroyResidenceHist: ResidenceHistogram,

    BaseLeafSize: number,
    LodAmount: number,
    SplitFactor: number,
    Generator: Generator,

    LoadItemCost: number,
    DestroyItemCost: number,
    LoadItemCostMax: number,
    DestroyItemCostMax: number,
    LastChunkWorkSeconds: number,
    LoadBudgetSeconds: { number },
    DestroyBudgetSeconds: number,

    LoadBatch: { { vector } },
    SizeBatch: { vector },
    LoadBatchBand: { number },
    DestroyBatch: { vector },
    ToCreate: { ChunkKey },
    ToDestroy: { ChunkKey },
    DestroyCandidates: { ChunkKey },

    NearBandRadius: number,
    MidBandRadius: number,

    Run: (self: Reconciler) -> (),
    Stats: (self: Reconciler) -> ReconcilerStats,
    OldestLoadEnqueueClock: (self: Reconciler, band: number) -> number?,
}

const function ClassifyBand(self: Reconciler, key: ChunkKey): number
    local target = self.TargetChunk
    if target == nil then return 1 end

    local dx = key.x - target.x
    local dy = key.y - target.y
    local dz = key.z - target.z
    if dx < 0 then dx = -dx end
    if dy < 0 then dy = -dy end
    if dz < 0 then dz = -dz end

    local maxD = dx
    if dy > maxD then maxD = dy end
    if dz > maxD then maxD = dz end

    if maxD <= self.NearBandRadius then return 1 end
    if maxD <= self.MidBandRadius then return 2 end
    return 3
end

const function AppendDiff(
    loadBatch: { { vector } }, sizeBatch: { vector },
    loadBatchBand: { number }, destroyBatch: { vector },
    band: number, diff: Strata.Diff
)
    local created, createdSizes, destroyed =
        diff.Created, diff.CreatedSizes, diff.Destroyed

    local loadLen = #loadBatch
    for idx = 1, #created do
        local newIdx = loadLen + idx
        loadBatch[newIdx] = created[idx]
        sizeBatch[newIdx] = createdSizes[idx]
        loadBatchBand[newIdx] = band
    end

    local destroyLen = #destroyBatch
    for idx = 1, #destroyed do
        destroyBatch[destroyLen + idx] = destroyed[idx]
    end
end

const function RunDiffLoopForBand(
    self: Reconciler,
    bandFilter: number,
    target: vector,
    loadBatch: { { vector } }, sizeBatch: { vector },
    loadBatchBand: { number }, destroyBatch: { vector },
    bandLoadElapsed: number, destroyElapsed: number,
    bandStructuralStart: number,
    bandLoadBudget: number, destroyBudget: number,
    loadItemCostMax: number, destroyItemCostMax: number
)
    local octrees = self.Octrees
    local desired = self.Desired
    local createInflight = self.CreateInflight

    local committed = false
    for key, octree in octrees do
        if not desired[key] then continue end
        if createInflight[key] then continue end
        if ClassifyBand(self, key) ~= bandFilter then continue end

        if committed then
            local liveLoadElapsed = bandLoadElapsed + (os.clock() - bandStructuralStart)
            local loadOver = liveLoadElapsed + loadItemCostMax > bandLoadBudget
            local destroyOver = destroyElapsed + destroyItemCostMax > destroyBudget
            if loadOver and destroyOver then break end
        end

        local diff = octree:SetTarget(target)
        if diff ~= nil then
            AppendDiff(loadBatch, sizeBatch, loadBatchBand, destroyBatch, bandFilter, diff)
            committed = true
        end
    end
end

const function PopLoadQueueForBand(
    self: Reconciler,
    band: number,
    target: vector?,
    rootSize: number, baseLeafSize: number, lodAmount: number, splitFactor: number,
    sample: (vector) -> number,
    loadBatch: { { vector } }, sizeBatch: { vector },
    loadBatchBand: { number }, destroyBatch: { vector },
    toCreate: { ChunkKey }, toCreateNRef: { number },
    bandLoadElapsed: number,
    bandStructuralStart: number,
    bandLoadBudget: number,
    loadItemCostMax: number
)
    local octrees = self.Octrees
    local desired = self.Desired
    local createInflight = self.CreateInflight
    local enqueueClocks = self.EnqueueClocks
    local loadQueue = self.LoadQueues[band]
    local loadEnqueueClock = self.LoadEnqueueClocks[band]

    local queueLen = loadQueue:Len()
    if queueLen == 0 then return end

    local idx = 1
    local consumedN = 0
    local committedLoad = false

    while idx <= queueLen do
        local key = loadQueue:At(idx)
        if desired[key] == nil or octrees[key] or createInflight[key] then
            consumedN = idx
            enqueueClocks[key] = nil
            idx += 1
            continue
        end

        if committedLoad then
            local liveLoadElapsed = bandLoadElapsed + (os.clock() - bandStructuralStart)
            if liveLoadElapsed + loadItemCostMax > bandLoadBudget then break end
        end

        local octree = Strata.New({
            RootCenter = key * rootSize,
            BaseLeafSize = baseLeafSize,
            LodAmount = lodAmount,
            SplitFactor = splitFactor,
            Sample = sample,
        })

        octrees[key] = octree
        createInflight[key] = true
        toCreateNRef[1] += 1
        toCreate[toCreateNRef[1]] = key
        consumedN = idx
        idx += 1
        committedLoad = true

        if target ~= nil then
            local diff = octree:SetTarget(target)
            if diff ~= nil then
                AppendDiff(loadBatch, sizeBatch, loadBatchBand, destroyBatch, band, diff)
            end
        end
    end

    if consumedN > 0 then
        loadQueue:Discard(consumedN)
        loadEnqueueClock:Discard(consumedN)
    end
end

const function AllBandsLoadDone(loadElapsed: { number }, loadBudget: { number }): boolean
    for band = 1, BAND_COUNT do
        if loadElapsed[band] < loadBudget[band] then return false end
    end
    return true
end

const function LoopBody(self: Reconciler)
    local octrees, desired = self.Octrees, self.Desired
    local enqueueClocks = self.EnqueueClocks
    local loadResidenceHists = self.LoadResidenceHists
    local destroyResidenceHist = self.DestroyResidenceHist
    local createInflight, destroyInflight =
        self.CreateInflight, self.DestroyInflight
    local undesired = self.Undesired
    local baseLeafSize, lodAmount, splitFactor =
        self.BaseLeafSize, self.LodAmount, self.SplitFactor
    local rootSize = baseLeafSize * 2 ^ (lodAmount - 1)
    local generator = self.Generator
    local sample = generator.Sample
    local loadBudgets = self.LoadBudgetSeconds
    local destroyBudget = self.DestroyBudgetSeconds

    self.LoadItemCostMax *= COST_MAX_DECAY
    self.DestroyItemCostMax *= COST_MAX_DECAY
    if self.LoadItemCostMax < self.LoadItemCost then
        self.LoadItemCostMax = self.LoadItemCost
    end
    if self.DestroyItemCostMax < self.DestroyItemCost then
        self.DestroyItemCostMax = self.DestroyItemCost
    end

    local loadBatch = self.LoadBatch
    local sizeBatch = self.SizeBatch
    local loadBatchBand = self.LoadBatchBand
    local destroyBatch = self.DestroyBatch
    local toCreate = self.ToCreate
    local toDestroy = self.ToDestroy
    local destroyCandidates = self.DestroyCandidates
    local toCreateNRef = { 0 }

    local loadElapsed = table.create(BAND_COUNT, 0)
    local destroyElapsed = 0

    while true do
        local allLoadDone = AllBandsLoadDone(loadElapsed, loadBudgets)
        local destroyDone = destroyElapsed >= destroyBudget
        if allLoadDone and destroyDone then break end

        local target = self.Target
        local loadItemCostMax = self.LoadItemCostMax
        local destroyItemCostMax = self.DestroyItemCostMax

        table.clear(loadBatch)
        table.clear(sizeBatch)
        table.clear(loadBatchBand)
        table.clear(destroyBatch)
        toCreateNRef[1] = 0
        local toDestroyN = 0

        local workStart = os.clock()

        -- Per-band structural pass: diff loop and pop queue gate against
        -- their own band's budget. Each band's structural time is charged
        -- back to that band's elapsed counter.
        for band = 1, BAND_COUNT do
            if loadElapsed[band] >= loadBudgets[band] then continue end

            local bandStart = os.clock()

            if target ~= nil then
                RunDiffLoopForBand(
                    self, band, target,
                    loadBatch, sizeBatch, loadBatchBand, destroyBatch,
                    loadElapsed[band], destroyElapsed, bandStart,
                    loadBudgets[band], destroyBudget,
                    loadItemCostMax, destroyItemCostMax
                )
            end

            if loadElapsed[band] + (os.clock() - bandStart) < loadBudgets[band] then
                PopLoadQueueForBand(
                    self, band, target,
                    rootSize, baseLeafSize, lodAmount, splitFactor, sample,
                    loadBatch, sizeBatch, loadBatchBand, destroyBatch,
                    toCreate, toCreateNRef,
                    loadElapsed[band], bandStart,
                    loadBudgets[band], loadItemCostMax
                )
            end

            loadElapsed[band] += os.clock() - bandStart
        end

        local destroyStructuralStart = os.clock()

        if not destroyDone then
            table.clear(destroyCandidates)
            local destroyCandidateN = 0

            for key in undesired do
                destroyCandidateN += 1
                destroyCandidates[destroyCandidateN] = key
            end

            local destroyCommitted = false
            for idx = 1, destroyCandidateN do
                if destroyCommitted then
                    local liveDestroyElapsed = destroyElapsed + (os.clock() - destroyStructuralStart)
                    if liveDestroyElapsed + destroyItemCostMax > destroyBudget then break end
                end

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
                destroyCommitted = true
            end
        end

        destroyElapsed += os.clock() - destroyStructuralStart

        if #loadBatch == 0 and #destroyBatch == 0 then
            self.LastChunkWorkSeconds += os.clock() - workStart
            break
        end

        if #loadBatch > 0 then
            local create = generator.Create
            local groupCount = #loadBatch
            local totalCreateCount = 0
            local totalElapsed = 0

            for groupIdx = 1, groupCount do
                local group = loadBatch[groupIdx]
                local size = sizeBatch[groupIdx]
                local band = loadBatchBand[groupIdx]
                local groupStart = os.clock()
                for idx = 1, #group do
                    local pos = group[idx]
                    create(pos, size)
                    totalCreateCount += 1
                end
                local groupElapsed = os.clock() - groupStart
                loadElapsed[band] += groupElapsed
                totalElapsed += groupElapsed
            end

            -- Resolve completed root creates: sample residence against the
            -- chunk's current band, then flip desire-changed mid-creates to
            -- pending destroys.
            for idx = 1, toCreateNRef[1] do
                local key = toCreate[idx]
                createInflight[key] = nil

                local enqueuedAt = enqueueClocks[key]
                if enqueuedAt ~= nil then
                    local band = ClassifyBand(self, key)
                    loadResidenceHists[band]:Sample(os.clock() - enqueuedAt)
                    enqueueClocks[key] = nil
                end

                if desired[key] == nil and undesired[key] == nil then
                    undesired[key] = true
                    self.UndesiredCount += 1
                    enqueueClocks[key] = os.clock()
                end
            end

            if totalCreateCount > 0 then
                local measured = totalElapsed / totalCreateCount
                self.LoadItemCost =
                    COST_SMOOTHING * measured + (1 - COST_SMOOTHING) * self.LoadItemCost
                if measured > self.LoadItemCostMax then
                    self.LoadItemCostMax = measured
                end
            end
        end

        if #destroyBatch > 0 then
            local startClock = os.clock()
            local destroy = generator.Destroy
            local count = #destroyBatch
            for idx = 1, count do
                destroy(destroyBatch[idx])
            end

            for idx = 1, toDestroyN do
                local key = toDestroy[idx]
                destroyInflight[key] = nil

                local enqueuedAt = enqueueClocks[key]
                if enqueuedAt ~= nil then
                    destroyResidenceHist:Sample(os.clock() - enqueuedAt)
                    enqueueClocks[key] = nil
                end
            end

            local elapsed = os.clock() - startClock
            destroyElapsed += elapsed

            if count > 0 then
                local measured = elapsed / count
                self.DestroyItemCost =
                    COST_SMOOTHING * measured + (1 - COST_SMOOTHING) * self.DestroyItemCost
                if measured > self.DestroyItemCostMax then
                    self.DestroyItemCostMax = measured
                end
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

const function OldestLoadEnqueueClock(self: Reconciler, band: number): number?
    local ring = self.LoadEnqueueClocks[band]
    if ring.Count == 0 then return nil end
    return ring:At(1)
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
    local pendingCreateByBand = table.create(BAND_COUNT, 0)
    for band = 1, BAND_COUNT do
        local len = self.LoadQueues[band]:Len()
        pendingCreateByBand[band] = len
        pendingCreate += len
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
        PendingCreateByBand = pendingCreateByBand,
        PendingDestroy = pendingDestroy,
        Octree = octreeStats,
    }
end

local Reconciler = {}

function Reconciler.New(config: ReconcilerConfig): Reconciler
    config.Generator.Init({
        ChunkSize = config.BaseLeafSize,
        OctreeLodAmount = config.LodAmount,
    })

    local loadQueues = table.create(BAND_COUNT)
    local loadEnqueueClocks = table.create(BAND_COUNT)
    local loadResidenceHists = table.create(BAND_COUNT)
    for band = 1, BAND_COUNT do
        loadQueues[band] = RingBuffer.New<<vector>>(LOAD_QUEUE_INITIAL_CAPACITY)
        loadEnqueueClocks[band] = RingBuffer.New<<number>>(LOAD_QUEUE_INITIAL_CAPACITY)
        loadResidenceHists[band] = ResidenceHistogram.New()
    end

    local loadBudgetSeconds = table.create(BAND_COUNT, math.huge)

    return {
        Desired = {},
        LoadQueues = loadQueues,
        LoadEnqueueClocks = loadEnqueueClocks,
        EnqueueClocks = {},
        CreateInflight = {},
        DestroyInflight = {},
        Octrees = {},
        Undesired = {},
        UndesiredCount = 0,
        Reconciling = false,
        Target = nil,
        TargetChunk = nil,
        LoadResidenceHists = loadResidenceHists,
        DestroyResidenceHist = ResidenceHistogram.New(),

        BaseLeafSize = config.BaseLeafSize,
        LodAmount = config.LodAmount,
        SplitFactor = config.SplitFactor,
        Generator = config.Generator,

        LoadItemCost = DEFAULT_LOAD_ITEM_COST,
        DestroyItemCost = DEFAULT_DESTROY_ITEM_COST,
        LoadItemCostMax = DEFAULT_LOAD_ITEM_COST,
        DestroyItemCostMax = DEFAULT_DESTROY_ITEM_COST,
        LastChunkWorkSeconds = 0,
        LoadBudgetSeconds = loadBudgetSeconds,
        DestroyBudgetSeconds = math.huge,

        LoadBatch = {},
        SizeBatch = {},
        LoadBatchBand = {},
        DestroyBatch = {},
        ToCreate = {},
        ToDestroy = {},
        DestroyCandidates = {},

        NearBandRadius = config.NearBandRadius,
        MidBandRadius = config.MidBandRadius,

        Run = Run,
        Stats = GetStats,
        OldestLoadEnqueueClock = OldestLoadEnqueueClock,
    }
end

Reconciler.ClassifyBand = ClassifyBand
Reconciler.BandCount = BAND_COUNT

return Reconciler
