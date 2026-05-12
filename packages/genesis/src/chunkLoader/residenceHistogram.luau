--!strict
--!native

const BUCKET_COUNT = 24
const BUCKET_BASE = 0.01
const BUCKET_FACTOR = 1.4
const INV_LOG_FACTOR = 1 / math.log(BUCKET_FACTOR)
const LOG_BASE = math.log(BUCKET_BASE)

export type ResidenceHistogram = {
    Buckets: { number },
    TotalMass: number,
    Sample: (self: ResidenceHistogram, residence: number) -> (),
    Decay: (self: ResidenceHistogram, factor: number) -> (),
    Percentile: (self: ResidenceHistogram, p: number) -> number,
}

const function BucketUpperEdge(index: number): number
    return BUCKET_BASE * BUCKET_FACTOR ^ (index + 1)
end

const function BucketIndex(residence: number): number
    if residence <= BUCKET_BASE then return 0 end

    local idx = math.floor((math.log(residence) - LOG_BASE) * INV_LOG_FACTOR)
    if idx < 0 then return 0 end
    if idx >= BUCKET_COUNT then return BUCKET_COUNT - 1 end
    return idx
end

const function Sample(self: ResidenceHistogram, residence: number)
    local idx = BucketIndex(residence)
    local buckets = self.Buckets
    buckets[idx + 1] += 1
    self.TotalMass += 1
end

const function Decay(self: ResidenceHistogram, factor: number)
    local buckets = self.Buckets
    for i = 1, BUCKET_COUNT do
        buckets[i] *= factor
    end
    self.TotalMass *= factor
end

const function Percentile(self: ResidenceHistogram, p: number): number
    local total = self.TotalMass
    if total <= 0 then return 0 end

    local threshold = total * p
    local buckets = self.Buckets
    local accum = 0

    for i = 1, BUCKET_COUNT do
        accum += buckets[i]
        if accum >= threshold then
            return BucketUpperEdge(i - 1)
        end
    end

    return BucketUpperEdge(BUCKET_COUNT - 1)
end

const function New(): ResidenceHistogram
    local buckets = table.create(BUCKET_COUNT, 0)

    return {
        Buckets = buckets,
        TotalMass = 0,
        Sample = Sample,
        Decay = Decay,
        Percentile = Percentile,
    }
end

return {
    New = New,
}
