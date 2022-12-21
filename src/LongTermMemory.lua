-- LongTermMemory
-- by boatbomber

-- This is mildly less cursed. It is a MemoryStore that periodically backs up to a DataStore
-- so that the data will not get lost.

local DataStoreService = game:GetService("DataStoreService")
local MemoryStoreService = game:GetService("MemoryStoreService")

local LongTermMemory = {}
LongTermMemory.__index = LongTermMemory

LongTermMemory._storeCache = {}

function LongTermMemory.new(name: string)
	if LongTermMemory._storeCache[name] then
		return LongTermMemory._storeCache[name]
	end

	local store = setmetatable({
		_DEBUG = false,
		_DEBUGID = "LongTermMemory[" .. name .. "]",

		_name = name,
		_datastore = DataStoreService:GetDataStore(name),
		_memorystore = MemoryStoreService:GetSortedMap(name),
	}, LongTermMemory)
	LongTermMemory._storeCache[name] = store

	return store
end

local logLevels = {print, warn, error}
function LongTermMemory:_log(logLevel, ...): ()
	if self._DEBUG then
		logLevels[logLevel](self._DEBUGID, ...)
	end
end

function LongTermMemory:GetAsync(key: string): any?
	local fromMemory = self._memorystore:GetAsync(key)
	if fromMemory ~= nil then
		self:_log(1, "Got", key, "from memory")
		return fromMemory.Value
	end

	local fromData = self._datastore:GetAsync(key)
	if fromData ~= nil then
		self:_log(1, "Got", key, "from datastore")
		return fromData.Value
	end

	return nil
end

function LongTermMemory:RemoveAsync(key: string): ()
	self._memorystore:RemoveAsync(key)
	self._datastore:RemoveAsync(key)
end

function LongTermMemory:UpdateAsync(key: string, callback: (any?) -> any?): any?
	local timestamp = DateTime.now().UnixTimestampMillis
	local exitValue = nil

	self._memorystore:UpdateAsync(key, function(old)
		if old == nil then
			old = self._datastore:GetAsync(key)
			self:_log(1, "Got", key, "from datastore during update since it was not in memory")
		end

		local oldValue = if old then old.Value else nil

		if old and old.Timestamp > timestamp then
			-- Stored is more recent, cancel this
			exitValue = oldValue
			return nil
		end

		local newValue = callback(oldValue)
		if newValue == nil then
			-- Callback cancelled
			exitValue = oldValue
			return nil
		end

		exitValue = newValue
		return {
			Value = newValue,
			Timestamp = timestamp,
		}
	end, 3_888_000)

	return exitValue
end

function LongTermMemory:SetAsync(key: string, value: any): any
	local timestamp = DateTime.now().UnixTimestampMillis
	local exitValue = nil

	self._memorystore:UpdateAsync(key, function(old)
		if old == nil then
			old = self._datastore:GetAsync(key)
			self:_log(1, "Got", key, "from datastore during set since it was not in memory")
		end

		if old and old.Timestamp > timestamp then
			-- Stored is more recent, cancel this
			exitValue = old.Value
			return nil
		end

		exitValue = value
		return {
			Value = value,
			Timestamp = timestamp,
		}
	end, 3_888_000)

	return exitValue
end

function LongTermMemory:ListKeysAsync(): {string}
	local keys, keysSet = {}, {}

	-- Get all keys from MemoryStore
	local exclusiveLowerBound = nil
	while true do
		local items = self._memorystore:GetRangeAsync(Enum.SortDirection.Ascending, 200, exclusiveLowerBound)
		for _, item in ipairs(items) do
			if keysSet[item.key] then continue end

			table.insert(keys, item.key)
			keysSet[item.key] = true
			self:_log(1, "Listed key", item.key, "from memory")
		end

		-- If the call returned less than requested amount, we’ve reached the end of the map
		if #items < 200 then
			break
		end
		-- Last retrieved key is the exclusive lower bound for the next iteration
		exclusiveLowerBound = items[#items].key
	end

	-- Get all keys from DataStore
	local keyPages = self._datastore:ListKeysAsync()
	while not keyPages.IsFinished do
		local currentPage = keyPages:GetCurrentPage()
		for _, item in currentPage do
			if keysSet[item.KeyName] then continue end

			table.insert(keys, item.KeyName)
			keysSet[item.KeyName] = true
			self:_log(1, "Listed key", item.KeyName, "from datastore")
		end
		keyPages:AdvanceToNextPageAsync()
	end

	return keys
end

function LongTermMemory:Backup()
	local exclusiveLowerBound = nil
	while true do
		local items = self._memorystore:GetRangeAsync(Enum.SortDirection.Ascending, 200, exclusiveLowerBound)
		for _, item in ipairs(items) do
			self:_log(1, "Backing up", "['" .. tostring(item.key) .. "'] =", item.value)
			self._datastore:SetAsync(item.key, item.value)
		end

		-- If the call returned less than requested amount, we’ve reached the end of the map
		if #items < 200 then
			break
		end

		-- Last retrieved key is the exclusive lower bound for the next iteration
		exclusiveLowerBound = items[#items].key
	end
end

function LongTermMemory:Destroy()
	LongTermMemory._storeCache[self._name] = nil
	self:Backup()
	self._memorystore:Destroy()
	self._datastore:Destroy()
	table.clear(self)
end

-- Periodically backup
task.defer(function()
	while true do
		task.wait(120)
		for _name, store in LongTermMemory._storeCache do
			store:Backup()
		end
	end
end)

-- Backup on close
game:BindToClose(function()
	for _name, store in LongTermMemory._storeCache do
		store:Backup()
	end
end)

return LongTermMemory
