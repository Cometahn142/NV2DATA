# Usage Patterns

## Session Locking

```luau
local NV2DATA = require(Packages.NV2DATA)

local Store = NV2DATA.GetStore({ DataStoreName = "PlayerData" }, { Coins = 0 })

local profile = Store:LoadProfileAsync("Player_123")
if profile then
    profile:Reconcile()
    profile.Data.Coins += 100
end
```
