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
    PendingDestroyByBand: { number },
    OldestUndesiredByBand: { number? },
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
    BandResidenceHists: { ResidenceHistogram },

    BaseLeafSize: number,
    LodAmount: number,
    SplitFactor: number,
    Generator: Generator,

    LoadItemCost: number,
    DestroyItemCost: number,
    LoadItemCostMax: number,
    DestroyItemCostMax: number,
    LastChunkWorkSeconds: number,
    BandBudgetSeconds: { number },

    LoadBatch: { { vector } },
    SizeBatch: { vector },
    LoadBatchBand: { number },
    DestroyBatch: { vector },
    DestroyBatchBand: { number },
    ToCreate: { ChunkKey },
    ToDestroy: { ChunkKey },
    DestroyCandidatesByBand: { { ChunkKey } },

    NearBandRadius: number,
    MidBandRadius: number,

    Run: (self: Reconciler) -> (),
    Stats: (self: Reconciler) -> ReconcilerStats,
    OldestLoadEnqueueClock: (self: Reconciler, band: number) -> number?,
    AggregateUndesiredByBand: (self: Reconciler, lensOut: { number }, oldestOut: { number? }) -> (),
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
    loadBatch: { { vector } }, sizeBatch: { vector }, loadBatchBand: { number },
    destroyBatch: { vector }, destroyBatchBand: { number },
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
        local newIdx = destroyLen + idx
        destroyBatch[newIdx] = destroyed[idx]
        destroyBatchBand[newIdx] = band
    end
end

const function PopLoadQueueForBand(
    self: Reconciler,
    band: number,
    target: vector?,
    rootSize: number, baseLeafSize: number, lodAmount: number, splitFactor: number,
    sample: (vector) -> number,
    loadBatch: { { vector } }, sizeBatch: { vector }, loadBatchBand: { number },
    destroyBatch: { vector }, destroyBatchBand: { number },
    toCreate: { ChunkKey }, toCreateNRef: { number },
    bandElapsed: number,
    bandStructuralStart: number,
    bandBudget: number,
    maxItemCost: number
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
    local committed = false

    while idx <= queueLen do
        local key = loadQueue:At(idx)
        if desired[key] == nil or octrees[key] or createInflight[key] then
            consumedN = idx
            enqueueClocks[key] = nil
            idx += 1
            continue
        end

        if committed then
            local live = bandElapsed + (os.clock() - bandStructuralStart)
            if live + maxItemCost > bandBudget then break end
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
        committed = true

        if target ~= nil then
            local diff = octree:SetTarget(target)
            if diff ~= nil then
                AppendDiff(
                    loadBatch, sizeBatch, loadBatchBand,
                    destroyBatch, destroyBatchBand,
                    band, diff
                )
            end
        end
    end

    if consumedN > 0 then
        loadQueue:Discard(consumedN)
        loadEnqueueClock:Discard(consumedN)
    end
end

const function RunWholeChunkDestroyForBand(
    self: Reconciler,
    band: number,
    destroyBatch: { vector }, destroyBatchBand: { number },
    toDestroy: { ChunkKey }, toDestroyNRef: { number },
    bandElapsed: number,
    bandStructuralStart: number,
    bandBudget: number,
    maxItemCost: number
)
    local octrees = self.Octrees
    local destroyInflight = self.DestroyInflight
    local undesired = self.Undesired
    local cands = self.DestroyCandidatesByBand[band]

    local committed = false
    for idx = 1, #cands do
        if committed then
            local live = bandElapsed + (os.clock() - bandStructuralStart)
            if live + maxItemCost > bandBudget then break end
        end

        local key = cands[idx]
        local octree = octrees[key]
        local leaves = octree:Destroy()

        local destroyLen = #destroyBatch
        for lidx = 1, #leaves do
            local newIdx = destroyLen + lidx
            destroyBatch[newIdx] = leaves[lidx]
            destroyBatchBand[newIdx] = band
        end

        octrees[key] = nil
        undesired[key] = nil
        self.UndesiredCount -= 1
        destroyInflight[key] = true
        toDestroyNRef[1] += 1
        toDestroy[toDestroyNRef[1]] = key
        committed = true
    end
end

const function RunDiffLoopForBand(
    self: Reconciler,
    bandFilter: number,
    target: vector,
    loadBatch: { { vector } }, sizeBatch: { vector }, loadBatchBand: { number },
    destroyBatch: { vector }, destroyBatchBand: { number },
    bandElapsed: number,
    bandStructuralStart: number,
    bandBudget: number,
    maxItemCost: number
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
            local live = bandElapsed + (os.clock() - bandStructuralStart)
            if live + maxItemCost > bandBudget then break end
        end

        local diff = octree:SetTarget(target)
        if diff ~= nil then
            AppendDiff(
                loadBatch, sizeBatch, loadBatchBand,
                destroyBatch, destroyBatchBand,
                bandFilter, diff
            )
            committed = true
        end
    end
end

const function AllBandsDone(elapsed: { number }, budget: { number }): boolean
    for band = 1, BAND_COUNT do
        if elapsed[band] < budget[band] then return false end
    end
    return true
end

const function LoopBody(self: Reconciler)
    local octrees, desired = self.Octrees, self.Desired
    local enqueueClocks = self.EnqueueClocks
    local residenceHists = self.BandResidenceHists
    local createInflight, destroyInflight =
        self.CreateInflight, self.DestroyInflight
    local undesired = self.Undesired
    local baseLeafSize, lodAmount, splitFactor =
        self.BaseLeafSize, self.LodAmount, self.SplitFactor
    local rootSize = baseLeafSize * 2 ^ (lodAmount - 1)
    local generator = self.Generator
    local sample = generator.Sample
    local bandBudgets = self.BandBudgetSeconds

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
    local destroyBatchBand = self.DestroyBatchBand
    local toCreate = self.ToCreate
    local toDestroy = self.ToDestroy
    local destroyCandidatesByBand = self.DestroyCandidatesByBand
    local toCreateNRef = { 0 }
    local toDestroyNRef = { 0 }

    local bandElapsed = table.create(BAND_COUNT, 0)
    local destroyCountPerBand = table.create(BAND_COUNT, 0)

    while true do
        if AllBandsDone(bandElapsed, bandBudgets) then break end

        local target = self.Target
        local loadItemCostMax = self.LoadItemCostMax
        local destroyItemCostMax = self.DestroyItemCostMax
        local maxItemCost =
            if loadItemCostMax > destroyItemCostMax then loadItemCostMax else destroyItemCostMax

        table.clear(loadBatch)
        table.clear(sizeBatch)
        table.clear(loadBatchBand)
        table.clear(destroyBatch)
        table.clear(destroyBatchBand)
        toCreateNRef[1] = 0
        toDestroyNRef[1] = 0

        local workStart = os.clock()

        -- Build per-band undesired candidate lists once per outer iteration.
        -- Each chunk is classified at current target so trailing-edge entries
        -- end up in the appropriate band's slot.
        for band = 1, BAND_COUNT do
            table.clear(destroyCandidatesByBand[band])
        end
        for key in undesired do
            local band = ClassifyBand(self, key)
            local cands = destroyCandidatesByBand[band]
            cands[#cands + 1] = key
        end

        -- Per-band slot: pop new roots first (leading-edge creation has the
        -- highest visual priority), then whole-chunk trailing-edge destroys,
        -- then diff-loop refinement on existing octrees. All three workloads
        -- share the band's single budget and elapsed counter.
        for band = 1, BAND_COUNT do
            if bandElapsed[band] >= bandBudgets[band] then continue end

            local bandStart = os.clock()
            local bandBudget = bandBudgets[band]

            PopLoadQueueForBand(
                self, band, target,
                rootSize, baseLeafSize, lodAmount, splitFactor, sample,
                loadBatch, sizeBatch, loadBatchBand,
                destroyBatch, destroyBatchBand,
                toCreate, toCreateNRef,
                bandElapsed[band], bandStart,
                bandBudget, maxItemCost
            )

            if bandElapsed[band] + (os.clock() - bandStart) < bandBudget then
                RunWholeChunkDestroyForBand(
                    self, band,
                    destroyBatch, destroyBatchBand,
                    toDestroy, toDestroyNRef,
                    bandElapsed[band], bandStart,
                    bandBudget, maxItemCost
                )
            end

            if target ~= nil
                and bandElapsed[band] + (os.clock() - bandStart) < bandBudget
            then
                RunDiffLoopForBand(
                    self, band, target,
                    loadBatch, sizeBatch, loadBatchBand,
                    destroyBatch, destroyBatchBand,
                    bandElapsed[band], bandStart,
                    bandBudget, maxItemCost
                )
            end

            bandElapsed[band] += os.clock() - bandStart
        end

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
                bandElapsed[band] += groupElapsed
                totalElapsed += groupElapsed
            end

            -- Resolve completed root creates: sample residence into the
            -- chunk's current band, then flip desire-changed mid-creates to
            -- pending destroys.
            for idx = 1, toCreateNRef[1] do
                local key = toCreate[idx]
                createInflight[key] = nil

                local enqueuedAt = enqueueClocks[key]
                if enqueuedAt ~= nil then
                    local band = ClassifyBand(self, key)
                    residenceHists[band]:Sample(os.clock() - enqueuedAt)
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

            for band = 1, BAND_COUNT do
                destroyCountPerBand[band] = 0
            end

            for idx = 1, count do
                destroy(destroyBatch[idx])
                destroyCountPerBand[destroyBatchBand[idx]] += 1
            end

            for idx = 1, toDestroyNRef[1] do
                local key = toDestroy[idx]
                destroyInflight[key] = nil

                local enqueuedAt = enqueueClocks[key]
                if enqueuedAt ~= nil then
                    local band = ClassifyBand(self, key)
                    residenceHists[band]:Sample(os.clock() - enqueuedAt)
                    enqueueClocks[key] = nil
                end
            end

            local elapsed = os.clock() - startClock

            -- Destroy time is measured in one flat pass and distributed to
            -- bands proportionally by leaf count. Per-call timing would be
            -- accurate but spends an os.clock() per leaf.
            if count > 0 then
                local invCount = 1 / count
                for band = 1, BAND_COUNT do
                    bandElapsed[band] += elapsed * destroyCountPerBand[band] * invCount
                end

                local measured = elapsed * invCount
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

const function AggregateUndesiredByBand(
    self: Reconciler,
    lensOut: { number },
    oldestOut: { number? }
)
    for band = 1, BAND_COUNT do
        lensOut[band] = 0
        oldestOut[band] = nil
    end
    if self.UndesiredCount == 0 then return end

    local enqueueClocks = self.EnqueueClocks
    for key in self.Undesired do
        local band = ClassifyBand(self, key)
        lensOut[band] += 1
        local clock = enqueueClocks[key]
        if clock ~= nil then
            local current = oldestOut[band]
            if current == nil or clock < current then
                oldestOut[band] = clock
            end
        end
    end
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
    local pendingDestroyByBand = table.create(BAND_COUNT, 0)
    local oldestUndesiredByBand: { number? } = {}
    AggregateUndesiredByBand(self, pendingDestroyByBand, oldestUndesiredByBand)

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
        PendingDestroyByBand = pendingDestroyByBand,
        OldestUndesiredByBand = oldestUndesiredByBand,
        Octree = octreeStats,
    }
end

local Reconciler = {}

function Reconciler.New(config: ReconcilerConfig): Reconciler
    config.Generator.Init({
        ChunkSize = config.BaseLeafSize,
        OctreeLodAmount = config.LodAmount,
    })

    local loadQueues: { RingBuffer<vector> } = {}
    local loadEnqueueClocks: { RingBuffer<number> } = {}
    local bandResidenceHists: { ResidenceHistogram } = {}
    local destroyCandidatesByBand: { { vector } } = {}
    for band = 1, BAND_COUNT do
        loadQueues[band] = RingBuffer.New<<vector>>(LOAD_QUEUE_INITIAL_CAPACITY)
        loadEnqueueClocks[band] = RingBuffer.New<<number>>(LOAD_QUEUE_INITIAL_CAPACITY)
        bandResidenceHists[band] = ResidenceHistogram.New()
        destroyCandidatesByBand[band] = {}
    end

    local bandBudgetSeconds = table.create(BAND_COUNT, math.huge)

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
        BandResidenceHists = bandResidenceHists,

        BaseLeafSize = config.BaseLeafSize,
        LodAmount = config.LodAmount,
        SplitFactor = config.SplitFactor,
        Generator = config.Generator,

        LoadItemCost = DEFAULT_LOAD_ITEM_COST,
        DestroyItemCost = DEFAULT_DESTROY_ITEM_COST,
        LoadItemCostMax = DEFAULT_LOAD_ITEM_COST,
        DestroyItemCostMax = DEFAULT_DESTROY_ITEM_COST,
        LastChunkWorkSeconds = 0,
        BandBudgetSeconds = bandBudgetSeconds,

        LoadBatch = {},
        SizeBatch = {},
        LoadBatchBand = {},
        DestroyBatch = {},
        DestroyBatchBand = {},
        ToCreate = {},
        ToDestroy = {},
        DestroyCandidatesByBand = destroyCandidatesByBand,

        NearBandRadius = config.NearBandRadius,
        MidBandRadius = config.MidBandRadius,

        Run = Run,
        Stats = GetStats,
        OldestLoadEnqueueClock = OldestLoadEnqueueClock,
        AggregateUndesiredByBand = AggregateUndesiredByBand,
    }
end

Reconciler.ClassifyBand = ClassifyBand
Reconciler.BandCount = BAND_COUNT

return Reconciler
