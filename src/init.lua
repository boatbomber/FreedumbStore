-- FreedumbStore
-- by boatbomber

-- The entirety of this system is a monstrosity. I'm sorry for writing it.
-- If you use this, any problems that arise are your own fault.
-- I am not responsible for any negative consequences that occur.
-- If you use this, you agree to all of the above.
-- You have been warned.

local HttpService = game:GetService("HttpService")
local DataStoreService = game:GetService("DataStoreService")
local LongTermMemory = require(script:WaitForChild("LongTermMemory"))

local FreedumbStore = {
	_storeCache = {},
	ChunkSize = 3_000_000, -- 3 MB
}
FreedumbStore.__index = FreedumbStore

function FreedumbStore.new(name: string, primaryKey: string)
	if FreedumbStore._storeCache[name] == nil then
		FreedumbStore._storeCache[name] = {}
	else
		if FreedumbStore._storeCache[name][primaryKey] ~= nil then
			return FreedumbStore._storeCache[name][primaryKey]
		end
	end

	local store = setmetatable({
		_DEBUG = true,
		_DEBUGID = "FreedumbStore[" .. name .. "/" .. primaryKey .. "]",
		_name = name,
		_primaryKey = primaryKey,
		_cache = {},

		_datastore = DataStoreService:GetDataStore(name),
		_memorystore = LongTermMemory.new(name),
	}, FreedumbStore)
	FreedumbStore._storeCache[name][primaryKey] = store

	store:_log(1, "Initialized!")

	return store
end

local logLevels = {print, warn, error}
function FreedumbStore:_log(logLevel, ...): ()
	if self._DEBUG then
		logLevels[logLevel](self._DEBUGID, ...)
	end
end

function FreedumbStore:ClearCache(): ()
	self._cache = {}
end

function FreedumbStore:FindAvailableChunkIndex(): number
	local chunkIndex = self._memorystore:GetAsync(self._primaryKey .. "/TopChunk") or 1
	while true do
		local chunk = self:GetChunkAsync(chunkIndex)
		if
			(chunk == nil) -- Doesn't exist
			or (next(chunk) == nil) -- Is empty
			or (#HttpService:JSONEncode(chunk) < self.ChunkSize) -- Is not full
		then
			break
		end

		chunkIndex += 1
	end

	return chunkIndex
end

function FreedumbStore:GetChunkIndexOfKey(key: string): number?
	local keyMap = self._memorystore:GetAsync(self._primaryKey .. "/KeyMap") or {}
	return keyMap[key]
end

function FreedumbStore:GetChunkAsync(chunkIndex: number): {[any]: any}
	local location = self._memorystore:GetAsync(self._primaryKey .. "/" .. chunkIndex)
	return self._datastore:GetAsync(location)
end

function FreedumbStore:GetAsync(key: string): any?
	-- Get the chunk index this key is in
	local chunkIndex = self:GetChunkIndexOfKey(key)
	if chunkIndex == nil then
		-- Key does not exist
		return nil
	end

	local chunk = self:GetChunkAsync(chunkIndex)
	if chunk == nil then
		-- Chunk does not exist
		return nil
	end

	return chunk[key]
end

function FreedumbStore:GetAllAsync(): {[any]: any}
	local hashmap = {}

	local chunkIndex = 0
	while true do
		chunkIndex += 1

		local chunk = self:GetChunkAsync(chunkIndex)
		if (chunk == nil) or (next(chunk) == nil) then
			-- Chunk does not exist or is empty
			break
		end

		for key, value in chunk do
			if hashmap[key] ~= nil then
				self:_log(2, "Duplicate key! '" .. tostring(key) .. "'")
			end
			hashmap[key] = value
		end
	end

	return hashmap
end

function FreedumbStore:SetAsync(key: string, value: any): ()
	-- Get the chunk index this key is in
	local chunkIndex: number = self:GetChunkIndexOfKey(key) or self:FindAvailableChunkIndex()

	-- Put this key-value into the chunk
	local chunk = self:GetChunkAsync(chunkIndex)
	chunk[key] = value

	-- Save where this key is
	self._memorystore:UpdateAsync(self._primaryKey .. "/KeyMap", function(keyMap)
		keyMap = keyMap or {}
		keyMap[key] = chunkIndex
		return keyMap
	end)

	-- Store the top chunk
	self._memorystore:UpdateAsync(self._primaryKey .. "/TopChunk", function(topChunk)
		if (topChunk == nil) or (topChunk < chunkIndex) then
			return chunkIndex
		end

		return nil
	end)

	-- Save the chunk
	self:SetChunkAsync(chunkIndex, chunk)
end

function FreedumbStore:SetChunkAsync(chunkIndex: number, chunk: any): ()
	local location = HttpService:GenerateGUID(false)

	self._datastore:SetAsync(location, chunk)
	self._memorystore:SetAsync(self._primaryKey .. "/" .. chunkIndex, location)
end

function FreedumbStore:UpdateAsync(key: string, callback: (any?) -> any?): any
	local value = self:GetAsync(key)
	local newValue = callback(value)

	if newValue == nil then
		-- Update cancelled, still on value
		return value
	end

	if newValue == value then
		-- No change, still on value
		return value
	end

	-- Update to newValue
	self:SetAsync(key, newValue)
	return newValue
end

return FreedumbStore
