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

local Promise = require(script.Parent.Promise)

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
		_changeListeners = {},

		_datastore = DataStoreService:GetDataStore(name),
		_memorystore = LongTermMemory.new(name .. "/" .. primaryKey .. "/Mem"),
		_keymap = LongTermMemory.new(name .. "/" .. primaryKey .. "/Keys"),
		_lockstore = MemoryStoreService:GetSortedMap(name .. "/" .. primaryKey .. "/Locks"),
	}, FreedumbStore)
	FreedumbStore._storeCache[name][primaryKey] = store

	store._memorystore:OnChanged(function(key: any, fromExternal: boolean?)
		if type(key) == "number" or tonumber(key) ~= nil then
			local chunkIndex = tonumber(key)
			if fromExternal then
				-- Clear our outdated cache
				store._cache[chunkIndex] = nil
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
	self:_log(2, "Destroying")
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

function FreedumbStore:ClearCache()
	self:_log(1, "Clearing cache")
	self._cache = {}
	return Promise.resolve()
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
			return Promise.resolve(self._cache[chunkIndex])
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
		self._cache[chunkIndex] = chunk
		return chunk
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

function FreedumbStore:SetChunkAsync(chunkIndex: number, chunk: any)
	if not self._locks[chunkIndex] then
		self:_log(2, "Cannot set chunk", chunkIndex, "without a lock")
		return Promise.reject("Cannot set chunk #" .. chunkIndex .. " without a lock")
	end

	return Promise.new(function(resolve, reject)
		self:_log(1, "Setting chunk", chunkIndex)

		local location = HttpService:GenerateGUID(false)
		local sanitizedChunk = Sanitizer:Sanitize(chunk)

		-- Place data inside store at location
		self:_log(1, "Putting chunk", chunkIndex, "at location", location)
		local function setData()
			self._datastore:SetAsync(location, sanitizedChunk)
		end

		local dataFailures = 0
		local dataSuccess, err = pcall(setData)
		while not dataSuccess do
			dataFailures += 1
			self:_log(2, "Failed to set chunk", chunkIndex, "at location", location, "with error", err)
			task.wait(dataFailures)
			if dataFailures > 10 then
				self:_log(2, "Failed to set chunk", chunkIndex, "at location", location, "after 10 retries")
				reject(err)
				return
			end
			self:_log(1, "Retrying...")
			dataSuccess, err = pcall(setData)
		end

		-- Update location memory
		self:_log(1, "Updating chunk", chunkIndex, "location memory to new location")
		local locationFailures = 0
		local locationSuccess, trueLocation = self._memorystore:SetAsync(chunkIndex, location):await()
		while not locationSuccess do
			locationFailures += 1
			self:_log(2, "Failed to update chunk", chunkIndex, "location memory to new location with error", trueLocation)
			task.wait(locationFailures)
			self:_log(1, "Retrying...")
			locationSuccess, trueLocation = self._memorystore:SetAsync(chunkIndex, location):await()

			if locationFailures > 10 then
				self:_log(2, "Failed to update chunk", chunkIndex, "location memory to new location after 10 retries")
				reject(trueLocation)
				return
			end
		end

		if trueLocation ~= location then
			self:_log(2, "Chunk", chunkIndex, "location was moved to", trueLocation, "while we were setting it to", location)
			local trueDataSuccess, trueDataResult = pcall(self._datastore.GetAsync, self._datastore, trueLocation)
			if trueDataSuccess then
				self:_log(1, "Updating cache for chunk", chunkIndex, "from true location", trueLocation)
				self._cache[chunkIndex] = Sanitizer:Desanitize(trueDataResult)
			else
				self:_log(2, "Failed to get latest", chunkIndex, "from true location", trueLocation, "with error", trueDataResult, " (cleared cache instead)")
				self._cache[chunkIndex] = nil
			end
		else
			self:_log(1, "Updating cache for chunk", chunkIndex, "from local set")
			self._cache[chunkIndex] = chunk
		end

		-- Update top chunk if needed
		self._memorystore:UpdateAsync("TopChunk", function(topChunk)
			if (topChunk == nil) or (topChunk < chunkIndex) then
				self:_log(1, "Updating top chunk to", chunkIndex)
				return chunkIndex
			end

			return nil
		end)

		resolve(self._cache[chunkIndex])
		return
	end)
end

function FreedumbStore:UpdateChunkAsync(chunkIndex: number, callback: (any?) -> any?)
	self:_log(1, "Updating chunk", chunkIndex)

	-- Aquire the lock for this chunk
	return self:AquireLock(chunkIndex):andThen(function()
		-- Get the chunk
		return self:GetChunkAsync(chunkIndex, false):andThen(function(chunk)
			-- Update the chunk
			local newChunk = callback(chunk)
			if newChunk ~= nil then
				-- Save the chunk
				return self:SetChunkAsync(chunkIndex, newChunk)
			end
			return chunk
		end):finally(function()
			-- Release the lock for this chunk
			self:ReleaseLock(chunkIndex)
		end)
	end)
end

function FreedumbStore:SetAsync(key: string, value: any)
	return Promise.new(function(resolve, reject)
		self:_log(1, "Setting key", key, "to value", value)

		-- Get the chunk index this key is in
		local chunkIndex = nil

		local keySuccess, keyIndex = self:GetChunkIndexOfKey(key):await()
		if not keySuccess then
			reject(keyIndex)
			return
		else
			chunkIndex = keyIndex
		end

		if chunkIndex == nil then
			local availableSuccess, availableIndex = self:FindAvailableChunkIndex():await()
			if not availableSuccess then
				reject(availableIndex)
				return
			else
				chunkIndex = availableIndex
			end
		end

		self:_log(1, "Putting key", key, "into chunk", chunkIndex)
		if chunkIndex == nil then
			reject("Could not find a chunk to put key " .. key .. " into")
			return
		end

		-- Update the chunk and put the key in
		self:UpdateChunkAsync(chunkIndex, function(chunk)
			chunk = chunk or {}
			chunk[key] = value
			return chunk
		end):andThen(function(newChunk)
			-- Save where this key is
			self:SetChunkIndexOfKey(key, chunkIndex)

			resolve(newChunk[key])
			return
		end)
	end)
end

function FreedumbStore:UpdateAsync(key: string, callback: (any?) -> any?)
	return Promise.new(function(resolve, reject)
		self:_log(1, "Updating key", key)

		-- Get the chunk index this key is in
		local chunkIndex = nil

		local keySuccess, keyIndex = self:GetChunkIndexOfKey(key):await()
		if not keySuccess then
			reject(keyIndex)
			return
		else
			chunkIndex = keyIndex
		end

		if chunkIndex == nil then
			local availableSuccess, availableIndex = self:FindAvailableChunkIndex():await()
			if not availableSuccess then
				reject(availableIndex)
				return
			else
				chunkIndex = availableIndex
			end
		end

		self:_log(1, "Putting key", key, "into chunk", chunkIndex)
		if chunkIndex == nil then
			reject("Could not find a chunk to put key " .. key .. " into")
			return
		end

		-- Update the chunk and put the key in
		self:UpdateChunkAsync(chunkIndex, function(chunk)
			chunk = chunk or {}
			local value = chunk[key]
			local newValue = callback(value)

			if newValue == nil then
				-- Update cancelled, still on value
				self:_log(1, "Update cancelled, still on value")
				return nil
			end

			if newValue == value then
				-- No change, still on value
				self:_log(1, "Update had no change, still on value")
				return nil
			end

			chunk[key] = newValue
			return chunk
		end):andThen(function(newChunk)
			-- Save where this key is
			self:SetChunkIndexOfKey(key, chunkIndex)

			resolve(newChunk[key])
			return
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
		end):andThen(function(newChunk)
			-- Remove where this key is
			self:SetChunkIndexOfKey(key, nil)

			return true
		end)
	end)
end

return FreedumbStore
