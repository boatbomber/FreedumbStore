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
	local chunkIndex = 0 -- TODO: Store last chunk index in memory store and start from there
	while true do
		chunkIndex += 1

		local chunk = self:GetChunkAsync(chunkIndex)
		if
			(chunk == nil) -- Doesn't exist
			or (next(chunk) == nil) -- Is empty
			or (#HttpService:JSONEncode(chunk) < self.ChunkSize) -- Is not full
		then
			break
		end
	end

	return chunkIndex
end

function FreedumbStore:GetChunkIndexOfKey(key: string): number?
	return nil
end

function FreedumbStore:GetChunkAsync(chunkIndex: number): {[any]: any}
	local hashmap = {}

	return hashmap
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
