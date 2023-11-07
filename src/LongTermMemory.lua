-- LongTermMemory
-- by boatbomber

-- This is mildly less cursed. It is a MemoryStore that periodically backs up to a DataStore
-- so that the data will not get lost.

local DataStoreService = game:GetService("DataStoreService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local MessagingService = game:GetService("MessagingService")
local RunService = game:GetService("RunService")

local Promise = require(script.Parent.Parent.Promise)

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

function LongTermMemory:CacheLocally(key: string, value: any?, expiration: number)
	return Promise.new(function(resolve, reject)
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
		resolve()
	end)
end

function LongTermMemory:ClearCacheLocally(key: string)
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

function LongTermMemory:Observe()
	return Promise.new(function(resolve, reject)
		self:_log(1, "Observing")
		local success, result = pcall(self._observerstore.SetAsync, self._observerstore, JOB_ID, 0, 3600)
		if not success then
			self:_log(2, "Failed to observe:", result)
			reject(result)
			return
		end
		resolve(result)
	end)
end

function LongTermMemory:StopObserving()
	return Promise.new(function(resolve, reject)
		self:_log(1, "Stopped observing")
		local success, result = pcall(self._observerstore.RemoveAsync, self._observerstore, JOB_ID)
		if not success then
			self:_log(2, "Failed to stop observing:", result)
			reject(result)
			return
		end
		resolve(result)
	end)
end

function LongTermMemory:HasObservers()
	return Promise.new(function(resolve, reject)
		local success, observers = pcall(self._observerstore.GetRangeAsync, self._observerstore,
			Enum.SortDirection.Ascending,
			2 -- We only need 2 to know if there are any other observers
		)
		if not success then
			self:_log(2, "Failed to get observers:", observers)
			reject(observers)
			return
		end

		for _, observer in ipairs(observers) do
			if observer.key ~= JOB_ID then
				resolve(true)
			end
		end
		return resolve(false)
	end)
end

function LongTermMemory:SendMessage(message: {[any]: any})
	if not self._hasObservers then
		self:_log(1, "No observers, not sending message")
		return Promise.reject("No observers, not sending message")
	end

	return Promise.new(function(resolve, reject)
		message.jobId = JOB_ID
		message.store = self._name

		self:_log(1, "Sending message:", message)

		local success, err = pcall(MessagingService.PublishAsync, MessagingService, MSG_ID, message)
		if not success then
			self:_log(2, "Failed to send message:", err)
			reject(err)
			return
		end
		resolve()
	end)
end

function LongTermMemory:ReceiveMessage(message)
	return Promise.new(function(resolve, reject)
		self:_log(1, "Received message:", message)
		if message.action == "keyChanged" then
			self:ClearCacheLocally(message.key)
			self:FireOnChanged(message.key, true)
		else
			self:_log(2, "Unknown message action:", message.action)
			reject("Unknown message action: " .. message.action)
			return
		end
		resolve()
	end)
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

function LongTermMemory:FireOnChanged(...)
	self:_log(1, "Firing OnChanged:", ...)

	for _, listener in self._changeListeners do
		task.spawn(pcall, listener, ...)
	end

	return Promise.resolve()
end

function LongTermMemory:GetAsync(key: string)
	if self._cache[key] ~= nil then
		self:_log(1, "Got", key, "from cache")
		return Promise.resolve(self._cache[key])
	end

	return Promise.new(function(resolve, reject)
		local memSuccess, fromMemory = pcall(self._memorystore.GetAsync, self._memorystore, key)
		if not memSuccess then
			self:_log(2, "Failed to get", key, "from memory:", fromMemory)
			reject(fromMemory)
			return
		end

		if fromMemory ~= nil then
			self:_log(1, "Got", key, "from memory")
			self:CacheLocally(key, fromMemory.v, 1800)
			resolve(fromMemory.v)
			return
		end

		local dataSuccess, fromData = pcall(self._datastore.GetAsync, self._datastore, key)
		if not dataSuccess then
			self:_log(2, "Failed to get", key, "from datastore:", fromData)
			reject(fromData)
			return
		end

		if fromData ~= nil then
			self:_log(1, "Got", key, "from datastore")
			self:CacheLocally(key, fromData.v, 1800)
			resolve(fromData.v)
			return
		end

		-- There simply isn't a value
		resolve(nil)
		return
	end)
end

function LongTermMemory:RemoveAsync(key: string)
	return Promise.new(function(resolve, reject)
		local memSuccess, memErr = pcall(self._memorystore.RemoveAsync, self._memorystore, key)
		if not memSuccess then
			self:_log(2, "Failed to remove", key, "from memory:", memErr)
			reject(memErr)
			return
		end

		local dataSuccess, dataErr = pcall(self._datastore.RemoveAsync, self._datastore, key)
		if not dataSuccess then
			self:_log(2, "Failed to remove", key, "from datastore:", dataErr)
			reject(dataErr)
			return
		end

		self:FireOnChanged(key)
		resolve()
	end)
end

function LongTermMemory:UpdateAsync(key: string, callback: (any?) -> any?, expiration: number?)
	local timestamp = DateTime.now().UnixTimestampMillis
	local exitValue = nil

	return Promise.new(function(resolve, reject)
		local success, err = pcall(self._memorystore.UpdateAsync, self._memorystore,
			key, function(old)
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
			end,
			expiration or self.Expiration
		)

		if not success then
			self:_log(2, "Failed to update", key, "in memory:", err)
			reject(err)
			return
		end

		self:CacheLocally(key, exitValue, 1800)
		resolve(exitValue)
		return
	end)
end

function LongTermMemory:SetAsync(key: string, value: any, expiration: number?): any
	local timestamp = DateTime.now().UnixTimestampMillis
	local exitValue = nil

	return Promise.new(function(resolve, reject)
		local success, err = pcall(self._memorystore.UpdateAsync, self._memorystore,
			key, function(old)
				if old == nil then
					old = self._datastore:GetAsync(key)
					self:_log(1, "Got", key, "from datastore during set since it was not in memory")
				end

				if old ~= nil then
					if (old.t > timestamp) or (old.v == value) then
						-- Stored is more recent or unchanged, cancel this
						exitValue = old.v
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
			end,
			expiration or self.Expiration
		)

		if not success then
			self:_log(2, "Failed to set", key, "in memory:", err)
			reject(err)
			return
		end

		self:CacheLocally(key, exitValue, 1800)
		resolve(exitValue)
		return
	end)
end

function LongTermMemory:Backup()
	if os.clock() - self._lastBackup < 3 then
		self:_log(2, "Backup rejected due to cooldown")
		return Promise.reject("Backup rejected due to cooldown")
	end
	self._lastBackup = os.clock()
	self:_log(1, "Backing up memory to datastore")

	return Promise.new(function(resolve, reject)
		local exclusiveLowerBound = nil
		while true do
			local success, items = pcall(self._memorystore.GetRangeAsync, self._memorystore, Enum.SortDirection.Ascending, 200, exclusiveLowerBound)
			if not success then
				self:_log(2, "Failed to get range from memory:", items)
				reject(items)
				return
			end

			for _, item in ipairs(items) do
				if not item.value then continue end

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
		resolve()
	end)
end

function LongTermMemory:Destroy()
	if self._destroying then return end
	self._destroying = true

	LongTermMemory._storeCache[self._name] = nil
	self:StopObserving():catch(warn)
	self:Backup():await()
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
			store:Backup():catch(function(err)
				warn("Failed to backup", store._DEBUGID, err)
			end)
			task.wait(0.25) -- Reduce throttle
		end
	end)

	-- Periodically backup
	while true do
		task.wait(math.random(400, 800))
		for _name, store in LongTermMemory._storeCache do
			store:Backup():catch(function(err)
				warn("Failed to backup", store._DEBUGID, err)
			end)
			task.wait(1) -- Reduce throttle
		end
	end
end)

return LongTermMemory
