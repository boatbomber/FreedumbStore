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
local Util = require(script:WaitForChild("Util"))

local Promise = require(script.Parent.Promise)
local HashLib = require(script.Parent.HashLib)

local FreedumbStore = {
	_storeCache = {},
	ChunkSize = 3_000_000, -- 3 MB
}
FreedumbStore.__index = FreedumbStore

local function createSafeName(name: string)
	if #name < 50 then
		-- This name is already safe
		return name
	end

	-- The name is too long, hash it down
	return HashLib.sha1(name)
end

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
		_locks = {},
		_changeListeners = {},
		_cache = {},
		_cacheExpirations = {},

		_datastore = DataStoreService:GetDataStore(createSafeName(name)),
		_memorystore = LongTermMemory.new(createSafeName(name .. "/" .. primaryKey .. "/Mem")),
		_keymap = LongTermMemory.new(createSafeName(name .. "/" .. primaryKey .. "/Keys")),
		_lockstore = MemoryStoreService:GetSortedMap(createSafeName(name .. "/" .. primaryKey .. "/Locks")),
	}, FreedumbStore)
	FreedumbStore._storeCache[name][primaryKey] = store

	store._memorystore:OnChanged(function(key: any, fromExternal: boolean?)
		if type(key) == "number" or tonumber(key) ~= nil then
			local chunkIndex = tonumber(key)
			if fromExternal then
				-- Clear our outdated cache
				store:RemoveCacheAsync(chunkIndex)
				store:_log(1, "Chunk", chunkIndex, "was changed externally")
			else
				store:_log(1, "Chunk", chunkIndex, "was changed locally")
			end

			store:FireChunkChanged(chunkIndex)
		end
	end)

	store:_log(1, "Initialized!")

	return store
end

function FreedumbStore:Destroy()
	self:_log(1, "Destroying")
	FreedumbStore._storeCache[self._name][self._primaryKey] = nil

	while next(self._locks) ~= nil do
		-- We're in middle of something, don't destroy yet
		task.wait()
	end

	setmetatable(self, nil)

	self._memorystore:Destroy()
	self._keymap:Destroy()
	self._lockstore:Destroy()

	table.clear(self)
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

function FreedumbStore:_setDebug(enabled: boolean): ()
	self._DEBUG = enabled
	self._memorystore._DEBUG = enabled
	self._keymap._DEBUG = enabled
end

function FreedumbStore:SetCacheAsync(key: string, value: any?, expiration: number)
	return Promise.new(function(resolve, reject)
		self:_log(1, "Setting local cache for", key, "for", expiration, "seconds")
		if self._cacheExpirations[key] then
			task.cancel(self._cacheExpirations[key])
			self._cacheExpirations[key] = nil
		end

		if type(value) == "table" then
			-- Ensure no one accidentally modifies the cache
			value = table.freeze(value)
		end
		self._cache[key] = value

		self._cacheExpirations[key] = task.delay(expiration, function()
			if self._cache[key] == value then
				self._cache[key] = nil
				self:_log(1, "Expired local cache for", key, "after", expiration, "seconds")
			end
			self._cacheExpirations[key] = nil
		end)
		resolve()
	end)
end

function FreedumbStore:RemoveCacheAsync(key: string)
	return Promise.new(function(resolve, reject)
		self:_log(1, "Clearing local cache for", key)
		self._cache[key] = nil
		if self._cacheExpirations[key] then
			task.cancel(self._cacheExpirations[key])
			self._cacheExpirations[key] = nil
		end
		resolve()
	end)
end

function FreedumbStore:GetCached(key: string)
	return Util.deepCopy(self._cache[key])
end

function FreedumbStore:OnChunkChanged(listener: (chunkIndex: number, chunk: any) -> ()): () -> ()
	self:_log(1, "OnChunkChanged listener added")
	table.insert(self._changeListeners, listener)

	return function()
		self:_log(1, "OnChunkChanged listener removed")
		for index, storedListener in self._changeListeners do
			if storedListener ~= listener then continue end

			table.remove(self._changeListeners, index)
			break
		end
	end
end

function FreedumbStore:FireChunkChanged(chunkIndex: number)
	self:_log(1, "Firing chunk changed", chunkIndex)

	return self:GetChunkAsync(chunkIndex):andThen(function(chunk)
		for _, listener in self._changeListeners do
			task.spawn(pcall, listener, chunkIndex, chunk)
		end
		return
	end)
end

function FreedumbStore:AquireLock(chunkIndex: number)
	return Promise.new(function(resolve, reject)
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

				if lockWaitTime > 30 then
					self:_log(2, "Lock wait time exceeded 30 seconds")
					reject("Lock wait time exceeded 30 seconds")
					return
				end
			end
		end

		self._locks[chunkIndex] = true
		self:_log(1, "Aquired lock for chunk", chunkIndex)
		resolve()
	end)
end

function FreedumbStore:ReleaseLock(chunkIndex: number)
	if not self._locks[chunkIndex] then
		self:_log(2, "Cannot release lock for chunk", chunkIndex, "since we don't have it")
		return Promise.reject("Cannot release lock for chunk " .. chunkIndex .. " since we don't have it")
	end

	return Promise.new(function(resolve, reject)
		self:_log(1, "Releasing lock for chunk", chunkIndex)

		local success, err = pcall(self._lockstore.RemoveAsync, self._lockstore, chunkIndex)
		if not success then
			self:_log(2, "Failed to release lock for chunk", chunkIndex, "with error", err)
			reject(err)
			return
		end

		self._locks[chunkIndex] = nil

		self:_log(1, "Released lock for chunk", chunkIndex)
		resolve()
	end)
end

function FreedumbStore:FindAvailableChunkIndex()
	return self._memorystore:GetAsync("TopChunk"):andThen(function(chunkIndex)
		if chunkIndex == nil then
			chunkIndex = 1
		end

		self:_log(1, "Starting search for available at chunk", chunkIndex)
		while true do
			local success, chunk = self:GetChunkAsync(chunkIndex):await()
			if not success then
				return Promise.reject("Failed to get chunk #" .. chunkIndex .. " with error " .. chunk)
			end

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
	end)
end

function FreedumbStore:GetChunkIndexOfKey(key: string)
	return self._keymap:GetAsync(key):andThen(function(chunkIndex)
		self:_log(1, "Key is in chunk", chunkIndex or "[none]")
		return chunkIndex
	end):catch(function(err)
		self:_log(2, "Failed to get chunk index of key", key, "with error", err)
		return Promise.reject(err)
	end)
end

function FreedumbStore:SetChunkIndexOfKey(key: string, chunkIndex: number)
	return self._keymap:SetAsync(key, chunkIndex):andThen(function(storedIndex)
		self:_log(1, "Key is now mapped to chunk", storedIndex)
		return storedIndex
	end):catch(function(err)
		self:_log(2, "Failed to set chunk index of key", key, "with error", err)
		return Promise.reject(err)
	end)
end

function FreedumbStore:GetChunkAsync(chunkIndex: number, useCache: boolean?)
	self:_log(1, "Getting chunk", chunkIndex, "(useCache=", useCache, ")")
	if (useCache ~= false) and (self._cache[chunkIndex] ~= nil) then
		self:_log(1, "Chunk #" .. chunkIndex .. " is cached")
		if next(self._cache[chunkIndex]) == nil then
			self:_log(1, "  But cached chunk #" .. chunkIndex .. " is empty, so let's check again anyway")
		else
			return Promise.resolve(self:GetCached(chunkIndex))
		end
	end

	return self._memorystore:GetAsync(chunkIndex):andThen(function(location)
		if location == nil then
			-- Chunk does not exist
			self:_log(1, "Chunk", chunkIndex, "does not exist")
			return {}
		end

		self:_log(1, "Chunk", chunkIndex, "is at location '" .. location .. "'")

		local dataSuccess, dataResult = pcall(self._datastore.GetAsync, self._datastore, location)
		if not dataSuccess then
			self:_log(2, "Failed to get chunk", chunkIndex, "from location '" .. location .. "' with error", dataResult)
			return Promise.reject(dataResult)
		end

		local chunk = Sanitizer:Desanitize(dataResult)
		self:SetCacheAsync(chunkIndex, chunk, 3600)
		return Util.deepCopy(chunk)
	end)
end

function FreedumbStore:GetAsync(key: string, useCache: boolean?)
	self:_log(1, "Getting value of key", key)

	-- Get the chunk index this key is in
	return self:GetChunkIndexOfKey(key):andThen(function(chunkIndex)
		if chunkIndex == nil then
			-- Key does not exist
			self:_log(1, "Key", key, "does not exist")
			return nil
		end

		return self:GetChunkAsync(chunkIndex, useCache ~= false):andThen(function(chunk)
			if chunk == nil then
				-- Chunk does not exist
				self:_log(1, "Key", key, "is in chunk", chunkIndex, "but that chunk does not exist")
				return nil
			end

			return chunk[key]
		end):catch(function(err)
			self:_log(2, "Failed to get chunk", chunkIndex, "with error", err)
			return Promise.reject(err)
		end)
	end)
end

function FreedumbStore:GetAllAsync(useCache: boolean?)
	self:_log(1, "Getting entire table")

	return self._memorystore:GetAsync("TopChunk"):andThen(function(topChunk)
		if topChunk == nil then
			topChunk = 1
		end

		local combined = {}
		for chunkIndex = 1, topChunk do
			-- In theory, we can use Promise.all to get all the chunks in parallel,
			-- but that increases the changes of ROblox dying on us, so we do them one by one with :await()
			local success, chunk = self:GetChunkAsync(chunkIndex, useCache ~= false):await()
			if not success then
				self:_log(2, "Failed to get chunk", chunkIndex, "with error", chunk)
				return Promise.reject("Failed to get chunk #" .. chunkIndex .. " with error " .. chunk)
			end

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
	end)
end

function FreedumbStore:_storeDataAtLocation(location: string, data: any)
	return Promise.new(function(resolve, reject)
		local success, err = pcall(self._datastore.SetAsync, self._datastore, location, data)
		if not success then
			self:_log(2, "Failed to store data at location", location, "with error", err)
			reject(err)
		else
			resolve()
		end
	end)
end

function FreedumbStore:_updateLocationMemory(key: string | number, location: string)
	return self._memorystore:SetAsync(key, location):catch(function(err)
		self:_log(2, "Failed to update location memory for key", key, "with error", err)
		return Promise.reject(err)
	end)
end

function FreedumbStore:SetChunkAsync(chunkIndex: number, chunk: any)
	if not self._locks[chunkIndex] then
		self:_log(2, "Cannot set chunk", chunkIndex, "without a lock")
		return Promise.reject("Cannot set chunk #" .. chunkIndex .. " without a lock")
	end

	self:_log(1, "Setting chunk", chunkIndex)

	local location = HttpService:GenerateGUID(false)
	local sanitizedChunk = Sanitizer:Sanitize(chunk)

	-- Place data inside store at location
	self:_log(1, "Putting chunk", chunkIndex, "at location", location)
	return Promise.retryWithDelay(
		function()
			return self:_storeDataAtLocation(location, sanitizedChunk)
		end,
		3, -- Retry count
		5 -- Delay between retries (in seconds)
	):andThen(function()
		-- Update cache
		self:_log(1, "Updating cache for chunk", chunkIndex, "from local set")
		return self:SetCacheAsync(chunkIndex, chunk, 3600)
	end):andThen(function()
		-- Update location memory
		self:_log(1, "Updating chunk", chunkIndex, "location memory to new location")
		return Promise.retryWithDelay(
			function()
				return self:_updateLocationMemory(chunkIndex, location)
			end,
			3, -- Retry count
			5 -- Delay between retries (in seconds)
		):andThen(function(trueLocation)
			if trueLocation ~= location then
				self:_log(2, "Chunk", chunkIndex, "location was moved to", trueLocation, "while we were setting it to", location)
				local trueDataSuccess, trueDataResult = pcall(self._datastore.GetAsync, self._datastore, trueLocation)
				if trueDataSuccess then
					self:_log(1, "Updating cache for chunk", chunkIndex, "from true location", trueLocation)
					self:SetCacheAsync(chunkIndex, Sanitizer:Desanitize(trueDataResult), 3600)
				else
					self:_log(2, "Failed to get latest", chunkIndex, "from true location", trueLocation, "with error", trueDataResult, " (cleared cache instead)")
					self:RemoveCacheAsync(chunkIndex)
				end
			end

			-- Update top chunk if needed
			return self._memorystore:UpdateAsync("TopChunk", function(topChunk)
				if (topChunk == nil) or (topChunk < chunkIndex) then
					self:_log(1, "Updating top chunk to", chunkIndex)
					return chunkIndex
				end

				return nil
			end):andThen(function(_topChunk)
				-- Return the updated chunk
				return self:GetCached(chunkIndex)
			end)
		end)
	end)
end

function FreedumbStore:UpdateChunkAsync(chunkIndex: number, callback: (any?) -> any?)
	self:_log(1, "Updating chunk", chunkIndex)

	-- Aquire the lock for this chunk
	return self:AquireLock(chunkIndex):timeout(10):andThen(function()
		-- Get the chunk
		return self:GetChunkAsync(chunkIndex, false):andThen(function(chunk)
			-- Update the chunk
			local newChunk = callback(chunk)
			if newChunk ~= nil then
				-- Save the chunk
				return self:SetChunkAsync(chunkIndex, newChunk)
			end
			return chunk
		end):catch(function(err)
			self:_log(2, err)
			return Promise.reject(err)
		end):finally(function()
			-- Release the lock for this chunk
			self:ReleaseLock(chunkIndex)
		end)
	end)
end

function FreedumbStore:SetAsync(key: string, value: any)
	self:_log(1, "Setting key", key, "to value", value)

	return self:GetChunkIndexOfKey(key):andThen(function(chunkIndex)
		if chunkIndex == nil then
			-- Get an available chunk index for this new key
			return self:FindAvailableChunkIndex()
		end
		return chunkIndex
	end):andThen(function(chunkIndex)
		self:_log(1, "Putting key", key, "into chunk", chunkIndex)
		if chunkIndex == nil then
			return Promise.reject("Could not find a chunk to put key " .. key .. " into")
		end

		-- Update the chunk and put the key in
		return self:UpdateChunkAsync(chunkIndex, function(chunk)
			chunk = chunk or {}
			chunk[key] = value
			return chunk
		end):andThen(function(newChunk)
			-- Save where this key is
			return self:SetChunkIndexOfKey(key, chunkIndex):andThen(function(_storedIndex)
				return newChunk[key]
			end)
		end):catch(function(err)
			self:_log(2, err)
			return Promise.reject(err)
		end)
	end)
end

function FreedumbStore:UpdateAsync(key: string, callback: (any?) -> any?)
	self:_log(1, "Updating key", key)

	return self:GetChunkIndexOfKey(key):andThen(function(chunkIndex)
		if chunkIndex == nil then
			-- Get an available chunk index for this new key
			return self:FindAvailableChunkIndex()
		end
		return chunkIndex
	end):andThen(function(chunkIndex)
		self:_log(1, "Putting key", key, "into chunk", chunkIndex)
		if chunkIndex == nil then
			return Promise.reject("Could not find a chunk to put key " .. key .. " into")
		end

		-- Update the chunk and put the key in
		return self:UpdateChunkAsync(chunkIndex, function(chunk)
			chunk = chunk or {}
			local value = chunk[key]
			local newValue = callback(value)

			if newValue == nil then
				-- Update cancelled, still on value
				self:_log(1, "Update cancelled, still on value")
				return nil
			end

			if type(newValue) ~= "table" and newValue == value then
				-- No change, still on value
				self:_log(1, "Update had no change, still on value")
				return nil
			end

			chunk[key] = newValue
			return chunk
		end):andThen(function(newChunk)
			-- Save where this key is
			return self:SetChunkIndexOfKey(key, chunkIndex):andThen(function(_storedIndex)
				return newChunk[key]
			end)
		end):catch(function(err)
			self:_log(2, err)
			return Promise.reject(err)
		end)
	end)
end

function FreedumbStore:RemoveAsync(key: string): boolean
	--[[ Note:
		In theory, we could rebalance the chunks here (ie. move keys around to fill in gaps)
		but that would cost a lot of budget and it just doesn't matter all that much.
		Old chunks with removed keys might be smaller than full chunks, but that's fine.
	--]]

	-- Get the chunk index this key is in
	return self:GetChunkIndexOfKey(key):andThen(function(chunkIndex)
		if chunkIndex == nil then
			self:_log(2, "Cannot remove key", key, "because it does not exist")
			return Promise.reject(false)
		end

		-- Update the chunk and remove the key
		return self:UpdateChunkAsync(chunkIndex, function(chunk)
			if chunk == nil then
				return nil
			end

			chunk[key] = nil
			return chunk
		end):andThen(function(_newChunk)
			-- Remove where this key is
			return self:SetChunkIndexOfKey(key, nil):andThen(function(_storedIndex)
				return true
			end)
		end)
	end)
end

return FreedumbStore
