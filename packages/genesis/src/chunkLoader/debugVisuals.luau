--!strict

local Reconciler = require(script.Parent.reconciler)
type Reconciler = Reconciler.Reconciler
type Generator = Reconciler.Generator

const LOD_COLORS = {
    Color3.fromRGB(255, 80, 80),
    Color3.fromRGB(255, 180, 60),
    Color3.fromRGB(50, 240, 80),
    Color3.fromRGB(45, 180, 150),
    Color3.fromRGB(40, 90, 200),
    Color3.fromRGB(120, 140, 255),
    Color3.fromRGB(220, 120, 255),
}

const function NewWireframeGenerator(): Generator
    local nodes: { [vector]: WireframeHandleAdornment } = {}

    return {
        Create = function(positionGroups: { { vector } }, sizes: { vector })
            for groupIdx = 1, #positionGroups do
                local group = positionGroups[groupIdx]
                local size = sizes[groupIdx]

                local lodBucket = math.round(math.log(size.x, 2))
                local color = LOD_COLORS[(lodBucket % #LOD_COLORS) + 1]

                local halfSize = (size :: any) :: Vector3 * 0.5
                local corner1 = Vector3.new(-halfSize.X, -halfSize.Y, -halfSize.Z)
                local corner2 = Vector3.new( halfSize.X, -halfSize.Y, -halfSize.Z)
                local corner3 = Vector3.new( halfSize.X,  halfSize.Y, -halfSize.Z)
                local corner4 = Vector3.new(-halfSize.X,  halfSize.Y, -halfSize.Z)
                local corner5 = Vector3.new(-halfSize.X, -halfSize.Y,  halfSize.Z)
                local corner6 = Vector3.new( halfSize.X, -halfSize.Y,  halfSize.Z)
                local corner7 = Vector3.new( halfSize.X,  halfSize.Y,  halfSize.Z)
                local corner8 = Vector3.new(-halfSize.X,  halfSize.Y,  halfSize.Z)

                for idx = 1, #group do
                    local pos = group[idx]

                    local adornment = Instance.new("WireframeHandleAdornment")
                    adornment.CFrame = CFrame.new((pos :: any) :: Vector3)
                    adornment.Adornee = workspace.Terrain
                    adornment.Color3 = color

                    adornment:AddLine(corner1, corner2)
                    adornment:AddLine(corner2, corner3)
                    adornment:AddLine(corner3, corner4)
                    adornment:AddLine(corner4, corner1)
                    adornment:AddLine(corner5, corner6)
                    adornment:AddLine(corner6, corner7)
                    adornment:AddLine(corner7, corner8)
                    adornment:AddLine(corner8, corner5)
                    adornment:AddLine(corner1, corner5)
                    adornment:AddLine(corner2, corner6)
                    adornment:AddLine(corner3, corner7)
                    adornment:AddLine(corner4, corner8)

                    adornment.Parent = workspace.Terrain

                    nodes[pos] = adornment
                end
            end
        end,

        Destroy = function(positions: { vector })
            for idx = 1, #positions do
                local pos = positions[idx]
                local adornment = nodes[pos]

                if not adornment then continue end

                adornment:Destroy()
                nodes[pos] = nil
            end
        end,

        Sample = function(_center: vector)
            return 1
        end,
    }
end

export type DebugVisuals = {
    Reconciler: Reconciler,
    DebugGenerator: Generator?,
    RealGenerator: Generator?,
    SetEnabled: (self: DebugVisuals, enabled: boolean) -> (),
}

const function MakeTee(real: Generator, debug: Generator): Generator
    return {
        Create = function(positionGroups: { { vector } }, sizes: { vector })
            real.Create(positionGroups, sizes)
            debug.Create(positionGroups, sizes)
        end,

        Destroy = function(positions: { vector })
            real.Destroy(positions)
            debug.Destroy(positions)
        end,

        Sample = real.Sample,
    }
end

const function CollectAlive(
    reconciler: Reconciler
): ({ { vector } }, { vector })
    local groups: { { vector } } = {}
    local sizes: { vector } = {}
    local bucketIncluded: { [number]: number } = {}

    for _, octree in reconciler.Octrees do
        octree:Collect(groups, sizes, bucketIncluded)
    end

    return groups, sizes
end

const function FlattenGroups(groups: { { vector } }): { vector }
    local positions: { vector } = {}
    local count = 0

    for groupIdx = 1, #groups do
        local group = groups[groupIdx]

        for posIdx = 1, #group do
            count += 1
            positions[count] = group[posIdx]
        end
    end

    return positions
end

const function SetEnabled(self: DebugVisuals, enabled: boolean)
    if (self.DebugGenerator ~= nil) == enabled then return end

    local reconciler = self.Reconciler

    if enabled then
        local debugGen = NewWireframeGenerator()

        local groups, sizes = CollectAlive(reconciler)
        if #groups > 0 then
            debugGen.Create(groups, sizes)
        end

        self.RealGenerator = reconciler.Generator
        self.DebugGenerator = debugGen
        reconciler.Generator = MakeTee(reconciler.Generator, debugGen)

    else
        local debugGen = self.DebugGenerator :: Generator
        local realGen = self.RealGenerator :: Generator

        local groups, _sizes = CollectAlive(reconciler)
        local positions = FlattenGroups(groups)

        if #positions > 0 then
            debugGen.Destroy(positions)
        end

        reconciler.Generator = realGen
        self.DebugGenerator = nil
        self.RealGenerator = nil
    end
end

local DebugVisuals = {}

function DebugVisuals.New(reconciler: Reconciler): DebugVisuals
    return {
        Reconciler = reconciler,
        DebugGenerator = nil,
        RealGenerator = nil,
        SetEnabled = SetEnabled,
    }
end

return DebugVisuals
