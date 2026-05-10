--!strict
--!native
--!nolint LocalShadow

const WARMUP_FRAMES = 5
const MIN_QUIET_FRAMES = 5

const DEFAULT_LOAD_BUDGET_SECONDS = 0.004
const DEFAULT_DESTROY_BUDGET_SECONDS = 0.004
const DEFAULT_FALLBACK_TARGET_SECONDS = 1 / 60
const DEFAULT_LOAD_MIN = 0.002
const DEFAULT_LOAD_MAX = 0.012
const DEFAULT_DESTROY_MIN = 0.002
const DEFAULT_DESTROY_MAX = 0.012
const DEFAULT_LOAD_BURST_MAX = 0.025
const DEFAULT_DESTROY_BURST_MAX = 0.025
const DEFAULT_UTILIZATION = 0.7
const DEFAULT_BURST_UTILIZATION = 0.9
const DEFAULT_BURST_QUEUE_THRESHOLD = 32
const DEFAULT_SHRINK_FACTOR = 0.85
const DEFAULT_SMOOTHING = 0.2
const DEFAULT_OUTLIER_RATIO = 3.0
const DEFAULT_QUIET_CHUNK_THRESHOLD = 0.0005

export type AdaptiveBudgetConfig = {
	TargetFrameSeconds: number?,
	LoadMin: number?,
	LoadMax: number?,
	DestroyMin: number?,
	DestroyMax: number?,
	LoadBurstMax: number?,
	DestroyBurstMax: number?,
	Utilization: number?,
	BurstUtilization: number?,
	BurstQueueThreshold: number?,
	ShrinkFactor: number?,
	Smoothing: number?,
	OutlierRatio: number?,
	QuietChunkThreshold: number?,
}

export type BudgetConfig = {
	LoadSeconds: number?,
	DestroySeconds: number?,
	Adaptive: (AdaptiveBudgetConfig | boolean)?,
}

export type AdaptiveBudgetParams = {
	TargetFrameSeconds: number?,
	LoadMin: number,
	LoadMax: number,
	DestroyMin: number,
	DestroyMax: number,
	LoadBurstMax: number,
	DestroyBurstMax: number,
	Utilization: number,
	BurstUtilization: number,
	BurstQueueThreshold: number,
	ShrinkFactor: number,
	Smoothing: number,
	OutlierRatio: number,
	QuietChunkThreshold: number,
}

export type AdaptiveBudgetState = {
	Params: AdaptiveBudgetParams,
	SmoothedFrameSeconds: number,
	SmoothedChunkWorkSeconds: number,
	BaselineNonChunkSeconds: number,
	DetectedTargetSeconds: number,
	FramesSeen: number,
	QuietFramesSeen: number,
}

export type BudgetState = {
	LoadSeconds: number,
	DestroySeconds: number,
	Adaptive: AdaptiveBudgetState?,
}

const function ResolveAdaptiveParams(config: AdaptiveBudgetConfig?): AdaptiveBudgetParams
	local config: AdaptiveBudgetConfig = config or {}

	return {
		TargetFrameSeconds = config.TargetFrameSeconds,
		LoadMin = config.LoadMin or DEFAULT_LOAD_MIN,
		LoadMax = config.LoadMax or DEFAULT_LOAD_MAX,
		DestroyMin = config.DestroyMin or DEFAULT_DESTROY_MIN,
		DestroyMax = config.DestroyMax or DEFAULT_DESTROY_MAX,
		LoadBurstMax = config.LoadBurstMax or DEFAULT_LOAD_BURST_MAX,
		DestroyBurstMax = config.DestroyBurstMax or DEFAULT_DESTROY_BURST_MAX,
		Utilization = config.Utilization or DEFAULT_UTILIZATION,
		BurstUtilization = config.BurstUtilization or DEFAULT_BURST_UTILIZATION,
		BurstQueueThreshold = config.BurstQueueThreshold or DEFAULT_BURST_QUEUE_THRESHOLD,
		ShrinkFactor = config.ShrinkFactor or DEFAULT_SHRINK_FACTOR,
		Smoothing = config.Smoothing or DEFAULT_SMOOTHING,
		OutlierRatio = config.OutlierRatio or DEFAULT_OUTLIER_RATIO,
		QuietChunkThreshold = config.QuietChunkThreshold or DEFAULT_QUIET_CHUNK_THRESHOLD,
	}
end

const function Adapt(
	budget: BudgetState,
	frameDt: number,
	chunkWorkSeconds: number,
	loadQueueLen: number,
	destroyQueueLen: number
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

	-- Without active queues there is no chunk pressure, so frameDt represents the
	-- engine's per-frame floor. Use these frames to calibrate the non-chunk
	-- baseline and the device's refresh interval.
	local isQuietFrame =
	    chunkWorkSeconds < params.QuietChunkThreshold
		and loadQueueLen == 0
		and destroyQueueLen == 0

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

	local effectiveTarget: number

	if params.TargetFrameSeconds ~= nil then
		effectiveTarget = params.TargetFrameSeconds

	elseif adaptive.QuietFramesSeen >= MIN_QUIET_FRAMES then
		effectiveTarget = adaptive.DetectedTargetSeconds

	else
		effectiveTarget = DEFAULT_FALLBACK_TARGET_SECONDS
	end

	-- One-off hitches (yields, GC, asset loads) shouldn't shrink the budget.
	if frameDt > effectiveTarget * params.OutlierRatio then
		debug.profileend()
		return
	end

	local baseline = adaptive.BaselineNonChunkSeconds
	if baseline <= 0 then
		baseline = math.max(0, adaptive.SmoothedFrameSeconds - adaptive.SmoothedChunkWorkSeconds)
	end

	local headroom = math.max(0, effectiveTarget - baseline)

	local loadBurst = loadQueueLen >= params.BurstQueueThreshold
	local destroyBurst = destroyQueueLen >= params.BurstQueueThreshold

	local loadUtilization = if loadBurst then params.BurstUtilization else params.Utilization
	local destroyUtilization = if destroyBurst then params.BurstUtilization else params.Utilization

	local loadCeiling = if loadBurst then params.LoadBurstMax else params.LoadMax
	local destroyCeiling = if destroyBurst then params.DestroyBurstMax else params.DestroyMax

	local loadDesired = headroom * loadUtilization
	local destroyDesired = headroom * destroyUtilization

	-- Smoothed frame already over target means the non-chunk baseline is stale
	-- (background pressure rose) or chunk work is too high. Pull both budgets
	-- down toward something that fits the observed overshoot.
	if adaptive.SmoothedFrameSeconds > effectiveTarget then
		local overshoot = adaptive.SmoothedFrameSeconds / effectiveTarget
		local factor = math.max(params.ShrinkFactor, 1 / overshoot)
		local shrunkChunk = adaptive.SmoothedChunkWorkSeconds * factor

		loadDesired = math.min(loadDesired, shrunkChunk)
		destroyDesired = math.min(destroyDesired, shrunkChunk)
	end

	budget.LoadSeconds = math.clamp(loadDesired, params.LoadMin, loadCeiling)
	budget.DestroySeconds = math.clamp(destroyDesired, params.DestroyMin, destroyCeiling)

	debug.profileend()
end

const function Resolve(budgetConfig: BudgetConfig?): BudgetState
	local adaptiveConfig = if budgetConfig then budgetConfig.Adaptive else nil

	local loadSeconds =
	    (if budgetConfig then budgetConfig.LoadSeconds else nil)
		or DEFAULT_LOAD_BUDGET_SECONDS

	local destroySeconds =
	    (if budgetConfig then budgetConfig.DestroySeconds else nil)
		or DEFAULT_DESTROY_BUDGET_SECONDS

	local adaptive: AdaptiveBudgetState? = nil

	if adaptiveConfig ~= false then
		local params = ResolveAdaptiveParams(
		    if type(adaptiveConfig) == "table" then adaptiveConfig else nil
		)

		local seedTarget = params.TargetFrameSeconds or DEFAULT_FALLBACK_TARGET_SECONDS

		adaptive = {
			Params = params,
			SmoothedFrameSeconds = seedTarget,
			SmoothedChunkWorkSeconds = 0,
			BaselineNonChunkSeconds = 0,
			DetectedTargetSeconds = math.huge,
			FramesSeen = 0,
			QuietFramesSeen = 0,
		}
	end

	return {
		LoadSeconds = loadSeconds,
		DestroySeconds = destroySeconds,
		Adaptive = adaptive,
	}
end

return {
	Adapt = Adapt,
	Resolve = Resolve,
}
