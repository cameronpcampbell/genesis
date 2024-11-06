--!strict
--!native
--!optimize 2


--> Types ---------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------


--> Functions -----------------------------------------------------------------------------------------
local function SplinePointsToKeyPoints(splinePoints: { Vector3 })
	local keyPoints = {}

	for _,splinePoint in splinePoints do
		keyPoints[splinePoint.X] = splinePoint.Z
	end

	return keyPoints
end
-------------------------------------------------------------------------------------------------------


--> Variables -----------------------------------------------------------------------------------------
local SplinePoints = {
	Vector3.new(-1, 0, -1),
	Vector3.new(-0.682539701461792, 0, 1),
	Vector3.new(-0.29523807764053345, 0, -1),
}

local Octaves, Lacunarity, Persistence, Scale = 2, .3, 3, 700

local KeyPoints = SplinePointsToKeyPoints(SplinePoints)
-------------------------------------------------------------------------------------------------------


--> Functions -----------------------------------------------------------------------------------------
local function Lerp(start: number, finish: number, t: number)
	return start + (finish - start) * t
end


local function FractalNoise(x: number, y: number, z: number, octaves: number, lacunarity: number, persistence: number, scale: number)
	local x1, y1, z1 = x, y, z
	local value, amplitude = 0, 1

	for i = 1, octaves do
		value += math.noise(x1 / scale, y1 / scale, z1 / scale) * amplitude
		y1 *= lacunarity
		x1 *= lacunarity
		z1 *= lacunarity
		amplitude *= persistence
	end

	return value
end

local function GetOutput(input: number)
	local output
	local lowerKeypoint: number?, higherKeypoint: number? = nil, nil

	for inputKeypoint, outputKeypoint in KeyPoints do
		if input == inputKeypoint then
			output = outputKeypoint
			break
		end

		if (input < inputKeypoint) and (not higherKeypoint or inputKeypoint < higherKeypoint) then
			higherKeypoint = inputKeypoint
		end

		if (input > inputKeypoint) and (not lowerKeypoint or inputKeypoint > lowerKeypoint) then
			lowerKeypoint = inputKeypoint
		end
	end

	if output then return output end

	if higherKeypoint == nil then
		return KeyPoints[lowerKeypoint :: number]
	elseif lowerKeypoint == nil then
		return KeyPoints[higherKeypoint]

	else
		local alpha = (input - lowerKeypoint) / (higherKeypoint - lowerKeypoint)
		local lowerOutput = KeyPoints[lowerKeypoint]
		local higherOutput = KeyPoints[higherKeypoint]

		return Lerp(lowerOutput, higherOutput, alpha)
	end
end
-------------------------------------------------------------------------------------------------------


return function(x: number, y: number, z: number)
	return GetOutput(math.clamp(FractalNoise(x, y, z, Octaves, Lacunarity, Persistence, Scale), -1, 1))
end