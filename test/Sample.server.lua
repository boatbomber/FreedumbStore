task.wait(2)

local Packages = game:GetService("ServerStorage"):WaitForChild("Packages")
local FreedumbStore = require(Packages:WaitForChild("FreedumbStore"))
local Store = FreedumbStore.new("AuctionHouse_V0.1.1", "Trades")
-- In datastore AuctionHouse_V0.1.0 at the key Trades, we're gonna fill a giant dictionary

-- We can flip on some debug prints if we want
Store:_setDebug(true)

for ID=1, 50 do
	-- Create tons of random data
	local data = table.create(ID*4096)
	for i=1, ID*4096 do
		data[i] = string.char(math.random(40, 120))
	end
	data = table.concat(data)

	print("Storing trade #" .. ID)
	Store:SetAsync("TradeID-" .. ID, {
		TradeData = data,
		Position = Vector3.new(math.random(100), math.random(100), math.random(100)),
	}):timeout(6):catch(warn):await()
end

Store:GetAsync("TradeID-25"):timeout(6):andThen(function(trade25)
	print("Trade 25:", trade25)
end):catch(warn)
Store:GetAllAsync():timeout(6):andThen(function(trades)
	print("All Trades:", trades)
end):catch(warn)
