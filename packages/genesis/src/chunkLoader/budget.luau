--!strict
--!native
--!nolint LocalShadow

local ResidenceHistogram = require(script.Parent.residenceHistogram)
type ResidenceHistogram = ResidenceHistogram.ResidenceHistogram

const BAND_COUNT = 3

const WARMUP_FRAMES = 5
const MIN_QUIET_FRAMES = 5

const DEFAULT_BAND_BUDGET_SECONDS = 0.008
const DEFAULT_FALLBACK_TARGET_SECONDS = 1 / 60

const DEFAULT_LOAD_BAND_PRIORITY = { 1, 2, 3 }

const DEFAULT_TARGET_RESIDENCE_SECONDS = 2.0
const DEFAULT_TARGET_PERCENTILE = 0.95
const DEFAULT_STARVATION_CEILING_SECONDS = 8.0
const DEFAULT_BACKLOG_QUEUE_THRESHOLD = 256
const DEFAULT_BACKLOG_MAX_BUDGET_SECONDS = 0.050
const DEFAULT_NORMAL_MAX_BUDGET_SECONDS = 0.012
const DEFAULT_MIN_BUDGET_SECONDS = 0.002
const DEFAULT_GROWTH_RATE = 1.25
const DEFAULT_SHRINK_RATE = 0.90
const DEFAULT_SMOOTHING = 0.2
const DEFAULT_QUIET_CHUNK_THRESHOLD = 0.0005
const DEFAULT_HISTOGRAM_DECAY = 0.98

export type AdaptiveBudgetConfig = {
    TargetFrameSeconds: number?,
    TargetResidenceSeconds: number?,
    TargetPercentile: number?,
    StarvationCeilingSeconds: number?,
    BacklogQueueThreshold: number?,
    BacklogMaxBudgetSeconds: number?,
    NormalMaxBudgetSeconds: number?,
    MinBudgetSeconds: number?,
    GrowthRate: number?,
    ShrinkRate: number?,
    Smoothing: number?,
    QuietChunkThreshold: number?,
    HistogramDecay: number?,
}

export type BudgetConfig = {
    BandSeconds: number?,
    Adaptive: (AdaptiveBudgetConfig | boolean)?,
}

export type AdaptiveBudgetParams = {
    TargetFrameSeconds: number?,
    TargetResidenceSeconds: number,
    TargetPercentile: number,
    StarvationCeilingSeconds: number,
    BacklogQueueThreshold: number,
    BacklogMaxBudgetSeconds: number,
    NormalMaxBudgetSeconds: number,
    MinBudgetSeconds: number,
    GrowthRate: number,
    ShrinkRate: number,
    Smoothing: number,
    QuietChunkThreshold: number,
    HistogramDecay: number,
}

export type AdaptiveBudgetState = {
    Params: AdaptiveBudgetParams,
    SmoothedFrameSeconds: number,
    SmoothedChunkWorkSeconds: number,
    BaselineNonChunkSeconds: number,
    DetectedTargetSeconds: number,
    FramesSeen: number,
    QuietFramesSeen: number,
    LastP95: { number },
    LastHoLAge: { number },
}

export type BudgetState = {
    BandSeconds: { number },
    Adaptive: AdaptiveBudgetState?,
}

const function ResolveAdaptiveParams(config: AdaptiveBudgetConfig?): AdaptiveBudgetParams
    local config: AdaptiveBudgetConfig = config or {}

    return {
        TargetFrameSeconds = config.TargetFrameSeconds,
        TargetResidenceSeconds = config.TargetResidenceSeconds or DEFAULT_TARGET_RESIDENCE_SECONDS,
        TargetPercentile = config.TargetPercentile or DEFAULT_TARGET_PERCENTILE,
        StarvationCeilingSeconds = config.StarvationCeilingSeconds or DEFAULT_STARVATION_CEILING_SECONDS,
        BacklogQueueThreshold = config.BacklogQueueThreshold or DEFAULT_BACKLOG_QUEUE_THRESHOLD,
        BacklogMaxBudgetSeconds = config.BacklogMaxBudgetSeconds or DEFAULT_BACKLOG_MAX_BUDGET_SECONDS,
        NormalMaxBudgetSeconds = config.NormalMaxBudgetSeconds or DEFAULT_NORMAL_MAX_BUDGET_SECONDS,
        MinBudgetSeconds = config.MinBudgetSeconds or DEFAULT_MIN_BUDGET_SECONDS,
        GrowthRate = config.GrowthRate or DEFAULT_GROWTH_RATE,
        ShrinkRate = config.ShrinkRate or DEFAULT_SHRINK_RATE,
        Smoothing = config.Smoothing or DEFAULT_SMOOTHING,
        QuietChunkThreshold = config.QuietChunkThreshold or DEFAULT_QUIET_CHUNK_THRESHOLD,
        HistogramDecay = config.HistogramDecay or DEFAULT_HISTOGRAM_DECAY,
    }
end

const function AdaptSlice(
    currentSeconds: number,
    hist: ResidenceHistogram,
    queueLen: number,
    holAgeSeconds: number,
    params: AdaptiveBudgetParams
): (number, number, number)
    hist:Decay(params.HistogramDecay)

    debug.profilebegin("Genesis/Budget/ResidenceP95")
    local currentP95 = hist:Percentile(params.TargetPercentile)
    debug.profileend()

    local targetResidence = params.TargetResidenceSeconds
    local hasWork = queueLen > 0
    local backlog =
        queueLen > params.BacklogQueueThreshold
        or holAgeSeconds > params.StarvationCeilingSeconds

    local multiplier: number
    if currentP95 > 0 then
        multiplier = math.clamp(
            currentP95 / targetResidence, params.ShrinkRate, params.GrowthRate)
    elseif hasWork then
        multiplier = params.GrowthRate
    else
        multiplier = params.ShrinkRate
    end

    local newSeconds = currentSeconds * multiplier

    local maxBudget =
        if backlog then params.BacklogMaxBudgetSeconds else params.NormalMaxBudgetSeconds

    if holAgeSeconds > params.StarvationCeilingSeconds then
        newSeconds = params.BacklogMaxBudgetSeconds
    end

    local resolved = math.clamp(newSeconds, params.MinBudgetSeconds, maxBudget)
    return resolved, currentP95, holAgeSeconds
end

const function Adapt(
    budget: BudgetState,
    residenceHists: { ResidenceHistogram },
    frameDt: number,
    chunkWorkSeconds: number,
    queueLens: { number },
    holAges: { number }
)
    local adaptive = budget.Adaptive
    if not adaptive then return end

    debug.profilebegin("Genesis/Budget/Adapt")

    local params = adaptive.Params
    local smoothing = params.Smoothing

    adaptive.SmoothedFrameSeconds =
        smoothing * frameDt + (1 - smoothing) * adaptive.SmoothedFrameSeconds
    adaptive.SmoothedChunkWorkSeconds =
        smoothing * chunkWorkSeconds + (1 - smoothing) * adaptive.SmoothedChunkWorkSeconds

    -- Quiet frames calibrate the engine's per-frame floor and non-chunk
    -- baseline, used as the implicit TargetFrameSeconds when the caller
    -- doesn't pin one explicitly.
    local totalQueueLen = 0
    for band = 1, BAND_COUNT do
        totalQueueLen += queueLens[band]
    end

    local isQuietFrame =
        chunkWorkSeconds < params.QuietChunkThreshold
        and totalQueueLen == 0

    if isQuietFrame then
        adaptive.BaselineNonChunkSeconds =
            smoothing * frameDt + (1 - smoothing) * adaptive.BaselineNonChunkSeconds

        if frameDt < adaptive.DetectedTargetSeconds then
            adaptive.DetectedTargetSeconds = frameDt
        end

        adaptive.QuietFramesSeen += 1
    end

    adaptive.FramesSeen += 1
    if adaptive.FramesSeen <= WARMUP_FRAMES then
        debug.profileend()
        return
    end

    local bandSeconds = budget.BandSeconds
    local lastP95 = adaptive.LastP95
    local lastHoLAge = adaptive.LastHoLAge

    for band = 1, BAND_COUNT do
        local resolved, p95, holAge = AdaptSlice(
            bandSeconds[band],
            residenceHists[band],
            queueLens[band],
            holAges[band],
            params
        )
        bandSeconds[band] = resolved
        lastP95[band] = p95
        lastHoLAge[band] = holAge
    end

    debug.profileend()
end

const function SplitBandPriority(seed: number, priority: { number }): { number }
    local total = 0
    for band = 1, BAND_COUNT do
        total += priority[band]
    end

    local result = table.create(BAND_COUNT, 0)
    if total <= 0 then
        local even = seed / BAND_COUNT
        for band = 1, BAND_COUNT do
            result[band] = even
        end
        return result
    end

    for band = 1, BAND_COUNT do
        result[band] = seed * priority[band] / total
    end
    return result
end

const function Resolve(budgetConfig: BudgetConfig?, loadBandPriority: { number }?): BudgetState
    local adaptiveConfig = if budgetConfig then budgetConfig.Adaptive else nil

    local seed =
        (if budgetConfig then budgetConfig.BandSeconds else nil)
        or DEFAULT_BAND_BUDGET_SECONDS

    local priority = loadBandPriority or DEFAULT_LOAD_BAND_PRIORITY

    local bandSeconds = SplitBandPriority(seed, priority)

    local adaptive: AdaptiveBudgetState? = nil

    if adaptiveConfig ~= false then
        local params = ResolveAdaptiveParams(
            if type(adaptiveConfig) == "table" then adaptiveConfig else nil
        )

        for band = 1, BAND_COUNT do
            if bandSeconds[band] < params.MinBudgetSeconds then
                bandSeconds[band] = params.MinBudgetSeconds
            end
        end

        local seedTarget = params.TargetFrameSeconds or DEFAULT_FALLBACK_TARGET_SECONDS

        adaptive = {
            Params = params,
            SmoothedFrameSeconds = seedTarget,
            SmoothedChunkWorkSeconds = 0,
            BaselineNonChunkSeconds = 0,
            DetectedTargetSeconds = math.huge,
            FramesSeen = 0,
            QuietFramesSeen = 0,
            LastP95 = table.create(BAND_COUNT, 0),
            LastHoLAge = table.create(BAND_COUNT, 0),
        }
    end

    return {
        BandSeconds = bandSeconds,
        Adaptive = adaptive,
    }
end

return {
    Adapt = Adapt,
    Resolve = Resolve,
}
