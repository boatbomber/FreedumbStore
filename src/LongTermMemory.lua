-- LongTermMemory
-- by boatbomber

-- This is mildly less cursed. It is a MemoryStore that periodically backs up to a DataStore
-- so that the data will not get lost.

local DataStoreService = game:GetService("DataStoreService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local MessagingService = game:GetService("MessagingService")
local RunService = game:GetService("RunService")

local MSG_ID = "LongTermMemoryEvents"
local JOB_ID = if RunService:IsStudio() then "STUDIO_JOB" else game.JobId

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
		_destroying = false,

		_name = name,
		_datastore = DataStoreService:GetDataStore(name),
		_memorystore = MemoryStoreService:GetSortedMap(name),
		_observerstore = MemoryStoreService:GetSortedMap("_OBS_" .. name),
		_hasObservers = false,

		_changeListeners = {},
		_cache = {},
		_cacheExpirations = {},
		_lastBackup = 0,

		Expiration = 3600 * 30, -- 30 hours
	}, LongTermMemory)
	LongTermMemory._storeCache[name] = store

	store._hasObservers = store:HasObservers()
	store:Observe()

	-- Occasionally refresh the observer list
	task.delay(120, function()
		while store._hasObservers ~= nil do
			store._hasObservers = store:HasObservers()
			task.wait(math.random(120, 300))
		end
	end)

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

function LongTermMemory:Observe()
	self:_log(1, "Observing")
	self._observerstore:SetAsync(JOB_ID, 0, 3600)
end

function LongTermMemory:StopObserving()
	self:_log(1, "Stopped observing")
	self._observerstore:RemoveAsync(JOB_ID)
end

function LongTermMemory:HasObservers(): boolean
	local observers = self._observerstore:GetRangeAsync(
		Enum.SortDirection.Ascending,
		2 -- We only need 2 to know if there are any other observers
	)
	for _, observer in ipairs(observers) do
		if observer.key ~= JOB_ID then
			return true
		end
	end
	return false
end

function LongTermMemory:SendMessage(message: {[any]: any}): ()
	if not self._hasObservers then
		self:_log(1, "No observers, not sending message")
		return
	end

	message.jobId = JOB_ID
	message.store = self._name

	self:_log(1, "Sending message:", message)
	task.spawn(function()
		local success, err = pcall(MessagingService.PublishAsync, MessagingService, MSG_ID, message)
		if not success then
			self:_log(2, "Failed to send message:", err)
		end
	end)
end

function LongTermMemory:ReceiveMessage(message): ()
	self:_log(1, "Received message:", message)
	if message.action == "keyChanged" then
		self:ClearCacheLocally(message.key)
		self:FireOnChanged(message.key, true)
	else
		self:_log(2, "Unknown message action:", message.action)
	end
end

function LongTermMemory:OnChanged(listener: (key: any, fromExternal: boolean?) -> ()): () -> ()
	self:_log(1, "OnChanged listener added")
	table.insert(self._changeListeners, listener)

	return function()
		self:_log(1, "OnChanged listener removed")
		for index, storedListener in self._changeListeners do
			if storedListener ~= listener then continue end

			table.remove(self._changeListeners, index)
			break
		end
	end
end

function LongTermMemory:FireOnChanged(...): ()
	self:_log(1, "Firing OnChanged:", ...)

	for _, listener in self._changeListeners do
		task.spawn(pcall, listener, ...)
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
	self:FireOnChanged(key)
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
			action = "keyChanged",
			key = key,
		})

		self:_log(1, "Updated memory for", key, "to", newValue)
		exitValue = newValue

		self:FireOnChanged(key)

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
			action = "keyChanged",
			key = key,
		})

		self:_log(1, "Set memory for", key, "to", value)
		exitValue = value

		self:FireOnChanged(key)

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
			local backupSuccess, backupErr = pcall(self._datastore.SetAsync, self._datastore, item.key, item.value)
			if backupSuccess then
				-- Now that it's backed up, we can remove it from memory
				local removalSuccess, removalErr = pcall(self._memorystore.RemoveAsync, self._memorystore, item.key)
				if not removalSuccess then
					self:_log(2, "Failed to remove", tostring(item.key), "from memory after backing up:", removalErr)
				end
			else
				self:_log(2, "Failed to backup", tostring(item.key), ":", backupErr)
			end
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
	if self._destroying then return end
	self._destroying = true

	LongTermMemory._storeCache[self._name] = nil
	self:StopObserving()
	self:Backup()
	for _key, thread in self._cacheExpirations do
		task.cancel(thread)
	end
	self._memorystore:Destroy()
	self._observerstore:Destroy()
	setmetatable(self, nil)
	table.clear(self)
end


task.defer(function()
	-- Connect to events
	local subscribeSuccess, subscribeConnection = pcall(function()
		return MessagingService:SubscribeAsync(MSG_ID, function(message)
			local data = message.Data
			if data.jobId == JOB_ID then
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
			local success, err = pcall(store.Backup, store)
			if not success then
				warn("Failed to backup", store._DEBUGID, err)
			end
		end
	end)

	-- Periodically backup
	while true do
		task.wait(math.random(400, 800))
		for _name, store in LongTermMemory._storeCache do
			local success, err = pcall(store.Backup, store)
			if not success then
				warn("Failed to backup", store._DEBUGID, err)
			end
		end
	end
end)

return LongTermMemory
