--!strict
--!optimize 2
--!native


--> Services ------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------


--> Modules -------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------


--> Types ---------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------


--> Variables -----------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------


--> Functions -----------------------------------------------------------------------------------------
local function Vector3Hash(x: number, y: number, z: number)
	return  Vector3.new(x, y, z) :: any --bit32.bxor(bit32.bxor(x, y * 54), z * 775)
end

-------------------------------------------------------------------------------------------------------


return function()
    local hashTable: { [Vector3]: Vector3 } = {}

    local function insert(x: number, y: number, z: number)
        local hash = Vector3Hash(x, y, z)

        hashTable[hash] = hash -- TODO: change this to vector3.
    end

    local function find(x: number, y: number, z: number)
        local hash = Vector3Hash(x, y, z)

        return hashTable[hash]
    end

    local function remove(x: number, y: number, z: number)
        local hash = Vector3Hash(x, y, z)

        hashTable[hash] = nil :: any
    end

    return hashTable, insert, find, remove
end