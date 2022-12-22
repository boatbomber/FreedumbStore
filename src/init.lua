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
		_DEBUG = false,
		_DEBUGID = "FreedumbStore[" .. name .. "/" .. primaryKey .. "]",
		_name = name,
		_primaryKey = primaryKey,
		_cache = {},

		_datastore = DataStoreService:GetDataStore(name),
		_memorystore = LongTermMemory.new(name .. "/Memory"),
	}, FreedumbStore)
	FreedumbStore._storeCache[name][primaryKey] = store

	store:_log(1, "Initialized!")

	return store
end

local logLevels = {print, warn, error}
function FreedumbStore:_log(logLevel, ...): ()
	if self._DEBUG then
		if type(select(1, ...)) == "function" then
			logLevels[logLevel](self._DEBUGID, select(1, ...)())
		else
			logLevels[logLevel](self._DEBUGID, ...)
		end
	end
end

function FreedumbStore:ClearCache(): ()
	self:_log(1, "Clearing cache")
	self._cache = {}
end

function FreedumbStore:FindAvailableChunkIndex(): number
	local chunkIndex = self._memorystore:GetAsync(self._primaryKey .. "/TopChunk") or 1
	self:_log(1, "Starting search for available at chunk", chunkIndex)
	while true do
		local chunk = self:GetChunkAsync(chunkIndex)
		if
			(chunk == nil) -- Doesn't exist
			or (next(chunk) == nil) -- Is empty
			or (#HttpService:JSONEncode(chunk) < self.ChunkSize) -- Is not full
		then
			-- Chunk is available
			self:_log(1, function()
				return "Chunk #" .. chunkIndex .. " is available with a size of", #HttpService:JSONEncode(chunk or {})/1024, "kilobytes"
			end)
			break
		end

		chunkIndex += 1
	end

	return chunkIndex
end

function FreedumbStore:GetChunkIndexOfKey(key: string): number?
	local keyMap = self._memorystore:GetAsync(self._primaryKey .. "/KeyMap") or {}
	local chunkIndex = keyMap[key]
	self:_log(1, "Key is in chunk", chunkIndex or "[none]")
	return chunkIndex
end

function FreedumbStore:GetChunkAsync(chunkIndex: number, useCache: boolean?): {[any]: any}
	self:_log(1, "Getting chunk", chunkIndex, "(useCache=", useCache, ")")
	if (useCache ~= false) and (self._cache[chunkIndex] ~= nil) then
		self:_log(1, "Chunk #" .. chunkIndex .. " is cached")
		return self._cache[chunkIndex]
	end

	local location = self._memorystore:GetAsync(self._primaryKey .. "/" .. chunkIndex)
	if location == nil then
		-- Chunk does not exist
		self:_log(1, "Chunk", chunkIndex, "does not exist")
		return {}
	else
		self:_log(1, "Chunk", chunkIndex, "is at location '" .. location .. "'")
	end

	local chunk = self._datastore:GetAsync(location)
	self._cache[chunkIndex] = chunk
	return chunk
end

function FreedumbStore:GetAsync(key: string, useCache: boolean?): any?
	self:_log(1, "Getting value of key", key)

	-- Get the chunk index this key is in
	local chunkIndex = self:GetChunkIndexOfKey(key)
	if chunkIndex == nil then
		-- Key does not exist
		self:_log(1, "Key", key, "does not exist")
		return nil
	end

	local chunk = self:GetChunkAsync(chunkIndex, useCache ~= false)
	if chunk == nil then
		-- Chunk does not exist
		self:_log(1, "Key", key, "is in chunk", chunkIndex, "but that chunk does not exist")
		return nil
	end

	return chunk[key]
end

function FreedumbStore:GetAllAsync(useCache: boolean?): {[any]: any}
	self:_log(1, "Getting entire hashmap")

	local hashmap = {}

	local chunkIndex = 0
	while true do
		chunkIndex += 1

		local chunk = self:GetChunkAsync(chunkIndex, useCache ~= false)
		if (chunk == nil) or (next(chunk) == nil) then
			-- Chunk does not exist or is empty
			break
		end

		self:_log(1, "Merging chunk #" .. chunkIndex .. " into hashmap")
		for key, value in chunk do
			if hashmap[key] ~= nil then
				self:_log(2, "Duplicate key!", key)
			end
			hashmap[key] = value
		end
	end

	return hashmap
end

function FreedumbStore:SetAsync(key: string, value: any): ()
	self:_log(1, "Setting key", key, "to value", value)

	-- Get the chunk index this key is in
	local chunkIndex: number = self:GetChunkIndexOfKey(key) or self:FindAvailableChunkIndex()
	self:_log(1, "Putting key", key, "into chunk", chunkIndex)

	-- Put this key-value into the chunk
	local chunk = self:GetChunkAsync(chunkIndex, false)
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
	self:_log(1, "Setting chunk", chunkIndex)

	local location = HttpService:GenerateGUID(false)

	self:_log(1, "Putting chunk", chunkIndex, "at location", location)
	self._datastore:SetAsync(location, chunk)

	self:_log(1, "Updating chunk", chunkIndex, "location memory to new location")
	local trueLocation = self._memorystore:SetAsync(self._primaryKey .. "/" .. chunkIndex, location)

	self:_log(1, "Updating cache for chunk", chunkIndex, "from location", trueLocation)
	self._cache[chunkIndex] = self._datastore:GetAsync(trueLocation)
end

function FreedumbStore:UpdateAsync(key: string, callback: (any?) -> any?): any
	self:_log(1, "Updating key", key)

	local value = self:GetAsync(key)
	local newValue = callback(value)

	if newValue == nil then
		-- Update cancelled, still on value
		self:_log("Update cancelled, still on value")
		return value
	end

	if newValue == value then
		-- No change, still on value
		self:_log("Update had no change, still on value")
		return value
	end

	-- Update to newValue
	self:SetAsync(key, newValue)
	return newValue
end

return FreedumbStore
