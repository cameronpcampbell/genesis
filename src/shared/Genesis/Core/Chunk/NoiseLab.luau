--!strict
--!native
--!optimize 2


--> Types ---------------------------------------------------------------------------------------------
type NoiseLabProps = {
    Octaves: number?,
    Lacunarity: number?,
    Persistence: number?,
    Scale: number,
    KeyPoints: { Vector3 }
  }
  -------------------------------------------------------------------------------------------------------
  
  
  --> Functions -----------------------------------------------------------------------------------------
  local function Lerp(start: number, finish: number, t: number)
      return start + (finish - start) * t
  end
  
  
  local function FractalNoise(octaves: number, lacunarity: number, persistence: number, scale: number, shapeValue: (number) -> number)
      return function(x: number, y: number, z: number)
          local x1, y1, z1 = x, y, z
          local value, amplitude = 0, 1
  
          for i = 1, octaves do
              local noise = shapeValue(math.clamp(math.noise(x1 / scale, y1 / scale, z1 / scale), -1, 1))
  
              value += noise * amplitude
              y1 *= lacunarity
              x1 *= lacunarity
              z1 *= lacunarity
              amplitude *= persistence
          end
  
          return value
      end
  end
  
  local function ShapeValue(keyPoints: { Vector3 })
      local keypointsLength = #keyPoints
      local _upperIndex = keypointsLength
      local _upperKeypoint = keyPoints[_upperIndex]
        local _upperInputKeypoint, _upperOutputKeypoint = _upperKeypoint.X, _upperKeypoint.Z
  
      return function(input: number)
          if input > _upperInputKeypoint then return _upperOutputKeypoint end
  
          local upperIndex, upperInputKeypoint, upperOutputKeypoint = _upperIndex, _upperInputKeypoint, _upperOutputKeypoint
  
          for idx = upperIndex - 1, 1, -1 do
              local keypoint = keyPoints[idx]
              local inputKeypoint, outputKeypoint = keypoint.X, keypoint.Z
  
              if input == inputKeypoint then return outputKeypoint end
  
              if input > inputKeypoint then break end
              upperInputKeypoint, upperOutputKeypoint, upperIndex = inputKeypoint, outputKeypoint, idx
          end
  
          local lowerIndex = upperIndex - 1
          if lowerIndex == 0 then return upperOutputKeypoint end
  
          local lowerKeypoint = keyPoints[lowerIndex]
          local lowerInputKeypoint, lowerOutputKeypoint = lowerKeypoint.X, lowerKeypoint.Z
  
          local alpha = (input - lowerInputKeypoint) / (upperInputKeypoint - lowerInputKeypoint)
          return Lerp(lowerOutputKeypoint, upperOutputKeypoint, alpha)
      end
  end
  -------------------------------------------------------------------------------------------------------
  
  
  return function(props: NoiseLabProps)
    local octaves, lacunarity, persistence, scale, keyPoints =
          math.max(props.Octaves or 1, 1), math.max(props.Lacunarity or 0, 0),
          math.max(props.Persistence or 0, 0), math.max(props.Scale, 1), props.KeyPoints
  
      return FractalNoise(octaves, lacunarity, persistence, scale, ShapeValue(keyPoints))
  end