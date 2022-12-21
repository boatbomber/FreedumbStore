task.wait(2)

local Packages = game:GetService("ServerStorage"):WaitForChild("Packages")
local FreedumbStore = require(Packages:WaitForChild("FreedumbStore"))
local Store = FreedumbStore.new("Data_v1.0", "Trades")
-- In datastore Data_v1 at the key Trades, we're gonna fill a giant dictionary

-- We can flip on some debug prints if we want
Store._DEBUG = true
Store._memorystore._DEBUG = true

for ID=1, 100 do
	-- Create tons of random data
	local data = table.create(ID*4096)
	for i=1, ID*4096 do
		data[i] = string.char(math.random(40, 120))
	end
	data = table.concat(data)

	print("Storing trade #" .. ID)
	Store:SetAsync("TradeID-" .. ID, {
		TradeData = data,
	})
end

local trade50 = Store:GetAsync("TradeID-50")
print("Trade 50:", trade50)

print("All Trades:", Store:GetAllAsync())
