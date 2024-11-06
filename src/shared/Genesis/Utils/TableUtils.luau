--!strict

local function TableMap<Item, Returns>(tble: { Item }, mapFn: (item: Item) -> Returns)
	local tbleLength = #tble
	local mappedTble = table.create(tbleLength)
	
	for idx = 1, tbleLength do mappedTble[idx] = mapFn(tble[idx]) end
	
	return mappedTble
end


return {
	TableMap = TableMap
}