# FreedumbStore

A Roblox Datastore wrapper that avoids the limitations by being absolutely ridiculous. Use at your own risk.

This system avoids the 6 second cooldown, and avoids the 4MB limit. Store massive tables and update them rapidly!
(This is a bad idea, don't actually do that. Use responsibly.)

## Example

```Lua
local FreedumbStore = require(Packages.FreedumbStore)
local Store = FreedumbStore.new("Data_v1", "Trades")
-- In datastore Data_v1 at the key Trades, we're gonna fill a giant dictionary

-- We can flip on some debug prints if we want
-- Store._DEBUG = true
-- Store._memorystore._DEBUG = true

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
```

## API

```Lua
function FreedumbStore.new(name: string, primaryKey: string): FreedomStore
```

Returns a new FreedumbStore.

```Lua
function FreedumbStore:GetAsync(key: string, useCache: boolean?): any?
```

Returns the value at that key of the table. useCache defaults to true.

```Lua
function FreedumbStore:GetAllAsync(useCache: boolean?): {[any]: any}
```

Returns the entire table. Large and slow, use sparingly. useCache defaults to true.

```Lua
function FreedumbStore:GetChunkAsync(chunkIndex: number, useCache: boolean?): {[any]: any}
```

Returns the section of the table at that chunk index. useCache defaults to true.

```Lua
function FreedumbStore:ClearCache(): ()
```

Clears the cached chunks.

```Lua
function FreedumbStore:SetAsync(key: string, value: any): ()
```

Sets the value at that key of the table.

```Lua
function FreedumbStore:UpdateAsync(key: string, callback: (oldValue: any?) -> any?): any
```

Update the value at that key of the table.

```Lua
function FreedumbStore:SetChunkAsync(chunkIndex: number, chunk: any): ()
```

[BE CAREFUL WITH THIS] Sets the entire chunk.

```Lua
function FreedumbStore:GetChunkIndexOfKey(key: string): number?
```

[INTERNAL] Returns the chunk index that a given key is stored in, if exists.

```Lua
function FreedumbStore:FindAvailableChunkIndex(): number
```

[INTERNAL]  Returns the first chunk index that is not full.
