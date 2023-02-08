# FreedumbStore

A Roblox Datastore wrapper that avoids the limitations by being absolutely ridiculous. Use at your own risk.

This system avoids the 6 second cooldown (key hopping), bypasses the 4MB limit (auto-chunking), supports storing Roblox datatypes like Vector3 & Color3 (serializing), and allows you to write from multiple servers at once (atomic locking).

Store massive tables of Roblox datatypes and update them rapidly! *(This is a bad idea, don't actually do that. Use responsibly.)*

## Example

```Lua
local FreedumbStore = require(Packages.FreedumbStore)
local Store = FreedumbStore.new("AuctionHouse_V0.1.0", "Trades")
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
	})
end

local trade25 = Store:GetAsync("TradeID-25")
print("Trade 25:", trade25)
print("All Trades:", Store:GetAllAsync())
```

## Installation

Wally:

```toml
[server-dependencies]
FreedumbStore = "boatbomber/freedumbstore@0.4.2"
```

Rojo:

```bash
rojo build default.project.json -o FreedumbStore.rbxm
```

## API

```Lua
function FreedumbStore.new(name: string, primaryKey: string): FreedomStore
```

Returns a new FreedumbStore.

```Lua
function FreedumbStore:Destroy(): ()
```

Destroys the FreedumbStore. Will yield before destroying if there's a write operation in-progress when called.

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
function FreedumbStore:RemoveAsync(key: string): boolean
```

Removes a key and its value from the table. Returns a success boolean.

```Lua
function FreedumbStore:SetChunkAsync(chunkIndex: number, chunk: any): ()
```

[BE CAREFUL WITH THIS] Sets the entire chunk.

```Lua
function FreedumbStore:UpdateChunkAsync(chunkIndex: number, callback: (any?) -> any?): ()
```

Update an entire chunk.

```Lua
function FreedumbStore:OnChunkChanged(listener: (chunkIndex: number, chunk: any) -> ()): () -> ()
```

Adds a listener callback for chunk changes. Returns a disconnect function.

```Lua
function FreedumbStore:GetChunkIndexOfKey(key: string): number?
```

[INTERNAL] Returns the chunk index that a given key is stored in, if exists.

```Lua
function FreedumbStore:SetChunkIndexOfKey(key: string, chunkIndex: number): ()
```

[INTERNAL] Sets the chunk index that the given key is stored in.

```Lua
function FreedumbStore:FindAvailableChunkIndex(): number
```

[INTERNAL]  Returns the first chunk index that is not full.

```Lua
function FreedumbStore:FireChunkChanged(chunkIndex: number)
```

[INTERNAL] Fires chunk changed listeners.

```Lua
function FreedumbStore:AquireLock(chunkIndex: number): ()
```

[INTERNAL] Aquires the global lock for writing to that chunk. Yields until lock is received.

```Lua
function FreedumbStore:ReleaseLock(chunkIndex: number): ()
```

[INTERNAL] Releases the global lock to that chunk, if we have it.

## Budget

You'll still need to respect the total calls budget, sadly. Can't be truly free.

Read the budget [here](https://create.roblox.com/docs/scripting/data/data-stores#limits) and [here](https://create.roblox.com/docs/scripting/data/memory-stores#limits) or wherever Roblox moved the docs to by the time you read this.

**Budget Cost per function:**

*A is available chunks, C is used chunks, / is BestCase/WorstCase*

| Function   | Datastore Gets  | Datastore Sets | Memorystore Gets | Memorystore Sets  |
|-----------:|:------|:------|:------|:------|
|new|0|0|0|0|
|ClearCache|0|0|0|0|
|OnChunkChanged|0|0|0|0|
|FindAvailableChunkIndex|1/2*A|0|1+A|0|
|AquireLock|0|0|1+?|1|
|ReleaseLock|0|0|0|1|
|GetChunkIndexOfKey|0/1|0|1|0|
|SetChunkIndexOfKey|0|0|0|1|0/1|
|GetChunkAsync|1/2|0|1|0|
|GetAsync|1/3|0|2|0|
|GetAllAsync|1/2*(1+C)|0|1+C|0|
|SetChunkAsync|1|1|1|1/2|
|UpdateChunkAsync|2/3|1|3+?|3/4|
|SetAsync|3/5*A|1|5+A+?|3/5|
|UpdateAsync|3/5*A|1|5+A+?|3/5|
|RemoveAsync|2/4|1|4+?|4/5|
