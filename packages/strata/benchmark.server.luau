--!strict

local Strata = require(script.Parent.packages.strata)

const SPLIT_FACTOR = 2.5
const PATH_STEPS = 200

type Scenario = {
    Name: string,
    BaseLeafSize: number,
    LodAmount: number,
    Sample: Strata.Sample,
}

const SAMPLE_ZERO: Strata.Sample = function()
    return 1
end
const SCENARIOS: { Scenario } = {
    { Name = "lod4 leaf32",   BaseLeafSize = 32, LodAmount = 4, Sample = SAMPLE_ZERO },
    { Name = "lod6 leaf32",   BaseLeafSize = 32, LodAmount = 6, Sample = SAMPLE_ZERO },
    { Name = "lod8 leaf32",   BaseLeafSize = 32, LodAmount = 8, Sample = SAMPLE_ZERO },
}

const function Percentile(sorted: { number }, p: number): number
    local n = #sorted
    if n == 0 then return 0 end
    local idx = math.clamp(math.ceil(p * n), 1, n)
    return sorted[idx]
end

const function RunScenario(scenario: Scenario)
    local rootSize = scenario.BaseLeafSize * 2 ^ (scenario.LodAmount - 1)

    local constructStart = os.clock()
    local octree = Strata.New({
        RootCenter = vector.create(0, 0, 0),
        BaseLeafSize = scenario.BaseLeafSize,
        LodAmount = scenario.LodAmount,
        SplitFactor = SPLIT_FACTOR,
        Sample = scenario.Sample,
    })
    local constructMs = (os.clock() - constructStart) * 1000

    local coldStart = os.clock()
    octree:SetTarget(vector.create(0, 0, 0))
    local coldMs = (os.clock() - coldStart) * 1000

    local stats = octree:Stats()

    local pathRadius = rootSize * 0.4
    local samples = table.create(PATH_STEPS) :: { number }
    local diffSamples = table.create(PATH_STEPS) :: { number }
    local skipped = 0
    local createdTotal = 0
    local destroyedTotal = 0

    local pathSum = 0
    for step = 1, PATH_STEPS do
        local t = step / PATH_STEPS
        local x = math.sin(step * 0.137) * pathRadius * t
        local y = math.cos(step * 0.091) * pathRadius * 0.5 * t
        local z = math.sin(step * 0.211 + 1.3) * pathRadius * t
        local target = vector.create(x, y, z)

        local startClock = os.clock()
        local diff = octree:SetTarget(target)
        local elapsedMs = (os.clock() - startClock) * 1000
        samples[step] = elapsedMs
        pathSum += elapsedMs

        if diff then
            diffSamples[#diffSamples + 1] = elapsedMs
            local groups = diff.Created
            for idx = 1, #groups do
                createdTotal += #groups[idx]
            end
            destroyedTotal += #diff.Destroyed
        else
            skipped += 1
        end
    end

    local teardownStart = os.clock()
    local leftover = octree:Teardown()
    local teardownMs = (os.clock() - teardownStart) * 1000

    table.sort(samples)
    table.sort(diffSamples)

    local pathAvg = pathSum / PATH_STEPS
    local pathP50 = Percentile(samples, 0.50)
    local pathP99 = Percentile(samples, 0.99)
    local diffP50 = Percentile(diffSamples, 0.50)
    local diffP99 = Percentile(diffSamples, 0.99)

    print(string.format(
        "[%s] root=%d leaves=%d nodes=%d",
        scenario.Name, rootSize, stats.Leaves, stats.Nodes
    ))
    print(string.format(
        "  construct=%.3fms  cold SetTarget=%.3fms  teardown=%.3fms (released=%d)",
        constructMs, coldMs, teardownMs, #leftover
    ))
    print(string.format(
        "  path: avg=%.4fms p50=%.4fms p99=%.4fms  (skipped=%d/%d)",
        pathAvg, pathP50, pathP99, skipped, PATH_STEPS
    ))
    print(string.format(
        "  diff-only: p50=%.4fms p99=%.4fms  created=%d destroyed=%d",
        diffP50, diffP99, createdTotal, destroyedTotal
    ))
end

print(string.format("path steps=%d  split factor=%.2f", PATH_STEPS, SPLIT_FACTOR))

for _, scenario in SCENARIOS do
    RunScenario(scenario)
end
