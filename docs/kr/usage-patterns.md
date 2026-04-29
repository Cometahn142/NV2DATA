# 사용 패턴 (Usage Patterns)

## 세션 잠금 (Session Locking)을 통한 데이터 보호

```luau
local NV2DATA = require(Packages.NV2DATA)

local Store = NV2DATA.GetStore({ DataStoreName = "PlayerData" }, { Coins = 0 })

local profile = Store:LoadProfileAsync("Player_123")
if profile then
    profile:Reconcile() -- 누락된 기본값 채우기
    profile.Data.Coins += 100 -- 데이터 수정 시 자동 감지
end
```
