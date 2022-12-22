-- FreedumbStore
-- by boatbomber

-- The entirety of this system is a monstrosity. I'm sorry for writing it.
-- If you use this, any problems that arise are your own fault.
-- I am not responsible for any negative consequences that occur.
-- If you use this, you agree to all of the above.
-- You have been warned.

local HttpService = game:GetService("HttpService")
local DataStoreService = game:GetService("DataStoreService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local LongTermMemory = require(script:WaitForChild("LongTermMemory"))
local Sanitizer = require(script:WaitForChild("Sanitizer"))

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
		_locks = {},

		_datastore = DataStoreService:GetDataStore(name),
		_memorystore = LongTermMemory.new(name .. "/" .. primaryKey .. "/Memory"),
		_keymap = LongTermMemory.new(name .. "/" .. primaryKey .. "/KeyMap"),
		_lockstore = MemoryStoreService:GetSortedMap(name .. "/" .. primaryKey .. "/Locks"),
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

function FreedumbStore:AquireLock(chunkIndex: number): ()
	self:_log(1, "Aquiring lock for chunk", chunkIndex)

	local unlocked, lockWaitTime = false, 0
	while unlocked == false do
		local success, message = pcall(function()
			self._lockstore:UpdateAsync(chunkIndex, function(lockOwner)
				if (lockOwner ~= nil) and (lockOwner ~= game.JobId) then
					self:_log(1, "Lock already taken by", lockOwner)
					return nil -- Someone else has this key rn, we must wait
				end

				unlocked = true

				-- Since other servers trying to take it will be returning
				-- different JobId, memorystore will know its a conflict
				-- and force the others to retry
				return game.JobId
			end, 20)
		end)
		if not success then
			warn(message)
		end

		if unlocked == false then
			lockWaitTime += task.wait()
			self:_log(1, "Waiting for lock for", chunkIndex, "for", lockWaitTime, "seconds so far")
		end
	end

	self._locks[chunkIndex] = true
	self:_log(1, "Aquired lock for chunk", chunkIndex)
end

function FreedumbStore:ReleaseLock(chunkIndex: number): ()
	if not self._locks[chunkIndex] then
		self:_log(2, "Cannot release lock for chunk", chunkIndex, "since we don't have it")
		return
	end

	self:_log(1, "Releasing lock for chunk", chunkIndex)

	pcall(self._lockstore.RemoveAsync, self._lockstore, chunkIndex)
	self._locks[chunkIndex] = nil

	self:_log(1, "Released lock for chunk", chunkIndex)
end

function FreedumbStore:FindAvailableChunkIndex(): number
	local chunkIndex = self._memorystore:GetAsync("TopChunk") or 1
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
	local chunkIndex = self._keymap:GetAsync(key)
	self:_log(1, "Key is in chunk", chunkIndex or "[none]")
	return chunkIndex
end

function FreedumbStore:SetChunkIndexOfKey(key: string, chunkIndex: number): ()
	self._keymap:SetAsync(key, chunkIndex)
	self:_log(1, "Key is now mapped to chunk", chunkIndex)
end

function FreedumbStore:GetChunkAsync(chunkIndex: number, useCache: boolean?): {[any]: any}
	self:_log(1, "Getting chunk", chunkIndex, "(useCache=", useCache, ")")
	if (useCache ~= false) and (self._cache[chunkIndex] ~= nil) then
		self:_log(1, "Chunk #" .. chunkIndex .. " is cached")
		return self._cache[chunkIndex]
	end

	local location = self._memorystore:GetAsync(chunkIndex)
	if location == nil then
		-- Chunk does not exist
		self:_log(1, "Chunk", chunkIndex, "does not exist")
		return {}
	else
		self:_log(1, "Chunk", chunkIndex, "is at location '" .. location .. "'")
	end

	local chunk = Sanitizer:Desanitize(self._datastore:GetAsync(location))
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
	self:_log(1, "Getting entire table")

	local combined = {}

	local topChunk = self._memorystore:GetAsync("TopChunk") or 1
	for chunkIndex = 1, topChunk do
		local chunk = self:GetChunkAsync(chunkIndex, useCache ~= false)
		if (chunk == nil) or (next(chunk) == nil) then
			-- Chunk does not exist or is empty
			break
		end

		self:_log(1, "Merging chunk", chunkIndex)
		for key, value in chunk do
			if combined[key] ~= nil then
				self:_log(2, "Duplicate key!", key)
			end
			combined[key] = value
		end
	end

	return combined
end

function FreedumbStore:SetChunkAsync(chunkIndex: number, chunk: any): {[any]: any}?
	if not self._locks[chunkIndex] then
		self:_log(2, "Cannot set chunk", chunkIndex, "without a lock")
		return
	end

	self:_log(1, "Setting chunk", chunkIndex)

	local location = HttpService:GenerateGUID(false)
	local sanitizedChunk = Sanitizer:Sanitize(chunk)

	self:_log(1, "Putting chunk", chunkIndex, "at location", location)
	self._datastore:SetAsync(location, sanitizedChunk)

	self:_log(1, "Updating chunk", chunkIndex, "location memory to new location")
	local trueLocation = self._memorystore:SetAsync(chunkIndex, location)

	self:_log(1, "Updating cache for chunk", chunkIndex, "from location", trueLocation)
	self._cache[chunkIndex] = Sanitizer:Desanitize(self._datastore:GetAsync(trueLocation))

	-- Update top chunk if needed
	self._memorystore:UpdateAsync("TopChunk", function(topChunk)
		if (topChunk == nil) or (topChunk < chunkIndex) then
			self:_log(1, "Updating top chunk to", chunkIndex)
			return chunkIndex
		end

		return nil
	end)

	return self._cache[chunkIndex]
end

function FreedumbStore:UpdateChunkAsync(chunkIndex: number, callback: (any?) -> any?): ()
	self:_log(1, "Updating chunk", chunkIndex)

	-- Aquire the lock for this chunk
	self:AquireLock(chunkIndex)

	-- Get the chunk
	local chunk = self:GetChunkAsync(chunkIndex, false)

	-- Update the chunk
	local newChunk = callback(chunk)
	if newChunk ~= nil then
		-- Save the chunk
		self:SetChunkAsync(chunkIndex, newChunk)
	end

	-- Release the lock for this chunk
	self:ReleaseLock(chunkIndex)
end

function FreedumbStore:SetAsync(key: string, value: any): ()
	self:_log(1, "Setting key", key, "to value", value)

	-- Get the chunk index this key is in
	local chunkIndex: number = self:GetChunkIndexOfKey(key) or self:FindAvailableChunkIndex()
	self:_log(1, "Putting key", key, "into chunk", chunkIndex)

	-- Update the chunk and put the key in
	self:UpdateChunkAsync(chunkIndex, function(chunk)
		chunk = chunk or {}
		chunk[key] = value
		return chunk
	end)

	-- Save where this key is
	self:SetChunkIndexOfKey(key, chunkIndex)
end

function FreedumbStore:UpdateAsync(key: string, callback: (any?) -> any?): any
	self:_log(1, "Updating key", key)

	-- Get the chunk index this key is in
	local chunkIndex: number = self:GetChunkIndexOfKey(key) or self:FindAvailableChunkIndex()
	self:_log(1, "Putting key", key, "into chunk", chunkIndex)

	-- Update the chunk and put the key in
	local exitValue = nil
	self:UpdateChunkAsync(chunkIndex, function(chunk)
		chunk = chunk or {}
		local value = chunk[key]
		local newValue = callback(value)

		if newValue == nil then
			-- Update cancelled, still on value
			self:_log("Update cancelled, still on value")
			exitValue = value
			return nil
		end

		if newValue == value then
			-- No change, still on value
			self:_log("Update had no change, still on value")
			exitValue = value
			return nil
		end

		chunk[key] = newValue
		exitValue = newValue
		return chunk
	end)

	-- Save where this key is
	self:SetChunkIndexOfKey(key, chunkIndex)

	return exitValue
end

return FreedumbStore
