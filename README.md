# FreedumbStore

A Roblox Datastore wrapper that avoids the limitations by being absolutely ridiculous. Use at your own risk.

## Example

```Lua
local HttpService = game:GetService("HttpService")

local FreedumbStore = require(Packages.FreedumbStore)
local Store = FreedumbStore.new("Data_v1", "Trades")

```

## API

```Lua
function FreedumbStore.new(name: string, primaryKey: string): FreedomStore
```

