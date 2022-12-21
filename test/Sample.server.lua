task.wait(2)

local Packages = game:GetService("ServerStorage"):WaitForChild("Packages")
local FreedumbStore = require(Packages:WaitForChild("FreedumbStore"))
local LongTermMemory = require(Packages:WaitForChild("FreedumbStore"):WaitForChild("LongTermMemory"))

local mem = LongTermMemory.new("testName")

print("startValue", mem:GetAsync("testKey2"))

local newValue = mem:UpdateAsync("testKey2", function(old)
	return "testValue5"
end)
print("updatedValue", newValue)
print("latestValue", mem:GetAsync("testKey2"))

print("listed", mem:ListKeysAsync())
