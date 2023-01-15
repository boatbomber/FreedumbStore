-- LongTermMemory
-- by boatbomber

-- This is mildly less cursed. It is a MemoryStore that periodically backs up to a DataStore
-- so that the data will not get lost.

local DataStoreService = game:GetService("DataStoreService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local MessagingService = game:GetService("MessagingService")

local MSG_ID = "LongTermMemoryEvents"

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

		_cache = {},
		_cacheExpirations = {},
		_lastBackup = 0,

		Expiration = 3_800_000,
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

function LongTermMemory:CacheLocally(key: string, value: any?, expiration: number): ()
	self:_log(1, "Setting local cache for", key, "for", expiration, "seconds")
	self._cache[key] = value
	if self._cacheExpirations[key] then
		task.cancel(self._cacheExpirations[key])
		self._cacheExpirations[key] = nil
	end
	self._cacheExpirations[key] = task.delay(expiration, function()
		if self._cache[key] == value then
			self._cache[key] = nil
			self:_log(1, "Expired local cache for", key, "after", expiration, "seconds")
		end
		self._cacheExpirations[key] = nil
	end)
end

function LongTermMemory:ClearCacheLocally(key: string): ()
	self:_log(1, "Clearing local cache for", key)
	self._cache[key] = nil
	if self._cacheExpirations[key] then
		task.cancel(self._cacheExpirations[key])
		self._cacheExpirations[key] = nil
	end
end

function LongTermMemory:SendMessage(message: {[any]: any}): ()
	message.jobId = game.JobId
	message.store = self._name

	self:_log(1, "Sending message:", message)

	task.spawn(MessagingService.PublishAsync, MessagingService, MSG_ID, message)
end

function LongTermMemory:ReceiveMessage(message): ()
	self:_log(1, "Received message:", message)
	if message.action == "cacheClear" then
		self:ClearCacheLocally(message.key)
	else
		self:_log(2, "Unknown message action:", message.action)
	end
end

function LongTermMemory:GetAsync(key: string): any?
	if self._cache[key] ~= nil then
		self:_log(1, "Got", key, "from cache")
		return self._cache[key]
	end

	local fromMemory = self._memorystore:GetAsync(key)
	if fromMemory ~= nil then
		self:_log(1, "Got", key, "from memory")
		self:CacheLocally(key, fromMemory.v, 1800)
		return fromMemory.v
	end

	local fromData = self._datastore:GetAsync(key)
	if fromData ~= nil then
		self:_log(1, "Got", key, "from datastore")
		self:CacheLocally(key, fromData.v, 1800)
		return fromData.v
	end

	return nil
end

function LongTermMemory:RemoveAsync(key: string): ()
	self._memorystore:RemoveAsync(key)
	self._datastore:RemoveAsync(key)
end

function LongTermMemory:UpdateAsync(key: string, callback: (any?) -> any?, expiration: number?): any?
	local timestamp = DateTime.now().UnixTimestampMillis
	local exitValue = nil

	self._memorystore:UpdateAsync(key, function(old)
		if old == nil then
			old = self._datastore:GetAsync(key)
			self:_log(1, "Got", key, "from datastore during update since it was not in memory")
		end

		local oldValue = if old then old.v else nil

		if old and old.t > timestamp then
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

		if newValue == oldValue then
			-- Value is the same, cancel this
			exitValue = newValue
			return nil
		end

		self:SendMessage({
			action = "cacheClear",
			key = key,
		})

		self:_log(1, "Updated memory for", key, "to", newValue)
		exitValue = newValue
		return {
			v = newValue,
			t = timestamp,
		}
	end, expiration or self.Expiration)

	self:CacheLocally(key, exitValue, 1800)
	return exitValue
end

function LongTermMemory:SetAsync(key: string, value: any, expiration: number?): any
	local timestamp = DateTime.now().UnixTimestampMillis
	local exitValue = nil

	self._memorystore:UpdateAsync(key, function(old)
		if old == nil then
			old = self._datastore:GetAsync(key)
			self:_log(1, "Got", key, "from datastore during set since it was not in memory")
		end

		if old ~= nil then
			if (old.t > timestamp) or (old.v == value) then
				-- Stored is more recent or unchanged, cancel this
				exitValue = old.Value
				return nil
			end
		end

		self:SendMessage({
			action = "cacheClear",
			key = key,
		})

		self:_log(1, "Set memory for", key, "to", value)
		exitValue = value
		return {
			v = value,
			t = timestamp,
		}
	end, expiration or self.Expiration)

	self:CacheLocally(key, exitValue, 1800)
	return exitValue
end

function LongTermMemory:Backup()
	if os.clock() - self._lastBackup < 3 then
		self:_log(2, "Backup rejected due to cooldown")
		return
	end
	self._lastBackup = os.clock()
	self:_log(1, "Backing up memory to datastore")

	local exclusiveLowerBound = nil
	while true do
		local items = self._memorystore:GetRangeAsync(Enum.SortDirection.Ascending, 200, exclusiveLowerBound)
		for _, item in ipairs(items) do
			self:_log(1, "Backing up", "['" .. tostring(item.key) .. "'] =", item.value)
			self._datastore:SetAsync(item.key, item.value)
			self:CacheLocally(item.key, item.value.v, 1800)
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
	setmetatable(self, nil)
	table.clear(self)
end


task.defer(function()
	-- Connect to events
	local subscribeSuccess, subscribeConnection = pcall(function()
		return MessagingService:SubscribeAsync(MSG_ID, function(message)
			local data = message.Data
			if data.jobId == game.JobId then
				-- Ignore messages from self
				return
			end

			local store = LongTermMemory._storeCache[data.store]
			if not store then
				-- Ignore messages for stores we don't have
				return
			end

			store:ReceiveMessage(data)
		end)
	end)
	if not subscribeSuccess then
		warn("Failed to subscribe to LongTermMemoryEvents")
		return
	end

	-- Disconnect and Backup on close
	game:BindToClose(function()
		if subscribeSuccess and subscribeConnection then
			subscribeConnection:Disconnect()
		end

		for _name, store in LongTermMemory._storeCache do
			store:Backup()
		end
	end)

	-- Periodically backup
	while true do
		task.wait(120)
		for _name, store in LongTermMemory._storeCache do
			store:Backup()
		end
	end
end)



return LongTermMemory
