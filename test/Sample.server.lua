task.wait(2)

local Packages = game:GetService("ServerStorage"):WaitForChild("Packages")
local FreedumbStore = require(Packages:WaitForChild("FreedumbStore"))

local store = FreedumbStore.new("Data_v1", "Quests")
store._DEBUG = true

print("Before:", store:GetAllAsync())

for key=1, 10 do
	store:SetAsync("QuestID"..key, {
		Name = "Quest #"..key,
		Description = "This is quest #"..key,
	})
end

print("After:", store:GetAllAsync())
