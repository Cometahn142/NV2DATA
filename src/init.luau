--!strict
--!optimize 2

local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local MessagingService = game:GetService("MessagingService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Promise = require(ReplicatedStorage.Packages.Promise)
local Signal = require(ReplicatedStorage.Packages.Signal)

local t_insert = table.insert
local t_remove = table.remove
local t_find = table.find
local t_clone = table.clone
local t_clear = table.clear
local t_freeze = table.freeze
local m_floor = math.floor
local m_min = math.min
local m_ceil = math.ceil
local m_max = math.max
local s_rep = string.rep
local s_find = string.find
local o_clock = os.clock
local o_time = os.time
local typ = type
local tostr = tostring

local C = {
	SAVE_INTERVAL = 300,
	LOAD_REPEAT_PERIOD = 10,
	FIRST_LOAD_REPEAT = 5,
	SESSION_STEAL = 40,
	ASSUME_DEAD = 630,
	START_SESSION_TIMEOUT = 120,
	CRITICAL_ERROR_COUNT = 5,
	CRITICAL_ERROR_EXPIRE = 120,
	CRITICAL_STATE_EXPIRE = 120,
	MAX_QUEUE_SIZE = 150,
	MESSAGING_COOLDOWN = 6,
	SHUTDOWN_PHASE1 = 20,
	SHUTDOWN_PHASE2 = 6,
	MAX_RELEASE_RETRIES = 40,
	MAX_SHUTDOWN_RETRIES = 15,
}

local IS_STUDIO = RunService:IsStudio()
local JOB_ID = game.JobId
local PLACE_ID = game.PlaceId
local MESSAGING_PREFIX = "N2DATA_MSG_"

local DATA_STORE_OPTIONS = Instance.new("DataStoreOptions")
DATA_STORE_OPTIONS:SetExperimentalFeatures({ v2 = true })

local DataStoreState: "NotReady" | "NoInternet" | "NoAccess" | "Access" = "NotReady"

local activeProfiles: { [string]: any } = {}
local pendingLoadJobs: { [string]: any } = {}
local activeProfileCount = 0
local activeLoadJobs = 0
local activeSaveJobs = 0
local isShuttingDown = false

local autoSaveList: { any } = {}
local autoSaveIndex = 1
local lastAutoSave = o_clock()

local issueQueue: { number } = {}
local isCriticalState = false
local criticalStateStart = 0

if IS_STUDIO then
	task.spawn(function()
		local newState: "Access" | "NoAccess" | "NoInternet"
		local ok, msg = pcall(function()
			DataStoreService:GetDataStore("____N2DATA_INIT"):SetAsync("____N2DATA_TEST", o_time())
		end)
		if ok then
			newState = "Access"
			print("[N.2DATA] Access")
		else
			if s_find(tostr(msg), "ConnectFail", 1, true) ~= nil then
				newState = "NoInternet"
				warn("[N.2DATA] No internet access — running in Mock mode")
			else
				newState = "NoAccess"
				warn("[N.2DATA] DataStore API unavailable — running in Mock mode")
			end
		end
		DataStoreState = newState
	end)
else
	DataStoreState = "Access"
end

export type ProfileData = { [string]: any }

export type StoreConfig = {
	DataStoreName: string,
	Scope: string?,
	UseMock: boolean?,
	UseArrayCompression: boolean?,
}

export type GlobalUpdate = {
	Id: number,
	Data: any,
	IsLocked: boolean,
}

export type ProfileMetaData = {
	ProfileCreateTime: number,
	SessionLoadCount: number,
	ActiveSession: { PlaceId: number, JobId: string, SessionId: string }?,
	ForceLoadSession: { PlaceId: number, JobId: string }?,
	MetaTags: { [string]: any },
	GlobalUpdates: { any },
	LastUpdateTime: number,
	Version: number,
}

export type Profile<T> = {
	Data: T,
	LastSavedData: T,
	RobloxMetaData: { [string]: any },
	MetaData: ProfileMetaData,
	Key: string,
	UserIds: { number },
	KeyInfo: DataStoreKeyInfo?,
	Store: Store<T>,
	ViewMode: boolean,
	FirstSessionTime: number,
	SessionLoadCount: number,
	OnSave: any, -- Signal<()>
	OnLastSave: any, -- Signal<(string)>
	OnAfterSave: any, -- Signal<(T)>
	OnSessionEnd: any, -- Signal<()>
	IsActive: (self: Profile<T>) -> boolean,
	Reconcile: (self: Profile<T>) -> (),
	MarkDirty: (self: Profile<T>) -> (),
	Release: (self: Profile<T>) -> any,
	EndSession: (self: Profile<T>) -> any,
	Save: (self: Profile<T>) -> any,
	SetAsync: (self: Profile<T>) -> any,
	ListenToRelease: (self: Profile<T>, cb: () -> ()) -> any,
	AddUserId: (self: Profile<T>, userId: number) -> (),
	RemoveUserId: (self: Profile<T>, userId: number) -> (),
	ArrayInsert: (self: Profile<T>, targetTable: { any }, value: any, pos: number?) -> (),
	ArrayRemove: (self: Profile<T>, targetTable: { any }, pos: number) -> any,
	ArrayClear: (self: Profile<T>, targetTable: { any }) -> (),
	ProcessGlobalUpdates: (self: Profile<T>, cb: (msg: any, processed: () -> ()) -> ()) -> (),
	SetMetaTag: (self: Profile<T>, tag: string, val: any) -> (),
	GetMetaTag: (self: Profile<T>, tag: string) -> any,
	AddMiddleware: (self: Profile<T>, hook: string, cb: (...any) -> any) -> (),
	AddGlobalUpdate: (self: Profile<T>, data: any) -> any,
	GetActiveGlobalUpdates: (self: Profile<T>) -> { GlobalUpdate },
	LockGlobalUpdate: (self: Profile<T>, id: number) -> any,
	ClearGlobalUpdate: (self: Profile<T>, id: number) -> any,
}

export type VersionQuery = {
	NextAsync: (self: VersionQuery) -> any,
}

export type Store<T> = {
	Name: string,
	Template: T,
	MockMode: boolean,
	Mock: Store<T>,
	LoadProfileAsync: (self: Store<T>, key: string, forceLoad: boolean?, cancelFn: (() -> boolean)?) -> any,
	ViewProfileAsync: (self: Store<T>, key: string, version: string?) -> any,
	ProfileVersionQuery: (
		self: Store<T>,
		key: string,
		sortDir: Enum.SortDirection?,
		minDate: number?,
		maxDate: number?
	) -> VersionQuery,
	GlobalUpdateProfileAsync: (self: Store<T>, key: string, data: any) -> any,
	WipeProfileAsync: (self: Store<T>, key: string) -> any,
	AddMigration: (self: Store<T>, version: number, handler: (data: T) -> T) -> (),
	RestoreFromBackupAsync: (self: Store<T>, key: string) -> any,
}

export type NV2DATAModule = {
	OnError: any,
	OnOverwrite: any,
	OnCriticalToggle: any,
	DataStoreState: "NotReady" | "NoInternet" | "NoAccess" | "Access",
	IsCriticalState: boolean,
	GetStore: <T>(config: StoreConfig, template: T) -> Store<T>,
	SetConstant: (name: string, value: number) -> (),
	GetDebugState: () -> any,
}

local OnError = Signal.new()
local OnOverwrite = Signal.new()
local OnCriticalToggle = Signal.new()

local proxyRawMap = setmetatable({}, { __mode = "k" })
local proxyDirtyMap = setmetatable({}, { __mode = "k" })

local CreateDeepProxy: (tbl: any, markDirty: () -> ()) -> any

local deepProxyMeta = {
	__index = function(self, key)
		return proxyRawMap[self][key]
	end,
	__newindex = function(self, key, value)
		local raw = proxyRawMap[self]
		local isTable = typ(value) == "table"

		local oldValue = raw[key]
		local actualValue = (isTable and proxyRawMap[value]) or value
		if oldValue == actualValue then
			return
		end

		local markDirty = proxyDirtyMap[self]
		if isTable then
			raw[key] = proxyRawMap[value] or CreateDeepProxy(value, markDirty)
		else
			raw[key] = value
		end
		markDirty()
	end,
	__iter = function(self)
		return next, proxyRawMap[self]
	end,
	__len = function(self)
		return #proxyRawMap[self]
	end,
}

function CreateDeepProxy(tbl: any, markDirty: () -> ()): any
	if proxyRawMap[tbl] then
		return tbl
	end
	if typ(tbl) ~= "table" then
		return tbl
	end

	local raw = {}
	local proxy = setmetatable({}, deepProxyMeta)

	proxyRawMap[proxy] = raw
	proxyDirtyMap[proxy] = markDirty

	for k, v in tbl do
		if typ(v) == "table" then
			raw[k] = CreateDeepProxy(v, markDirty)
		else
			raw[k] = v
		end
	end

	return proxy
end

local function StripProxyAndCopy(t: any): any
	if typ(t) ~= "table" then
		return t
	end

	-- 프록시라면 원본 테이블을 가져옴
	local actualTable = proxyRawMap[t] or t
	local clone = t_clone(actualTable)

	for k, v in clone do
		if typ(v) == "table" then
			-- 재귀적으로 복사하되, 내부에서 프록시 여부를 다시 체크함
			clone[k] = StripProxyAndCopy(v)
		end
	end

	return clone
end

local function RegisterError(message: string, storeName: string?, profileKey: string?)
	local ctx = ""
	if storeName and storeName ~= "" then
		ctx = ctx .. " STORE:" .. storeName
	end
	if profileKey and profileKey ~= "" then
		ctx = ctx .. " KEY:" .. profileKey
	end
	warn("[N.2DATA] DataStore error" .. ctx .. " — " .. tostr(message))
	t_insert(issueQueue, o_clock())
	OnError:Fire(tostr(message), storeName or "", profileKey or "")
end

local function RegisterOverwrite(storeName: string, profileKey: string)
	warn("[N.2DATA] Schema mismatch auto-reconciled (STORE:" .. storeName .. "; KEY:" .. profileKey .. ")")
	OnOverwrite:Fire(storeName, profileKey)
end

local function UpdateCriticalState()
	if #issueQueue == 0 and not isCriticalState then
		return
	end

	local now = o_clock()
	local removeCount = 0

	for i = 1, #issueQueue do
		if now - issueQueue[i] > C.CRITICAL_ERROR_EXPIRE then
			removeCount = i
		else
			break
		end
	end

	if removeCount > 0 then
		table.move(issueQueue, removeCount + 1, #issueQueue, 1)
		for i = #issueQueue - removeCount + 1, #issueQueue do
			issueQueue[i] = nil
		end
	end

	if not isCriticalState then
		if #issueQueue >= C.CRITICAL_ERROR_COUNT then
			isCriticalState = true
			criticalStateStart = now
			OnCriticalToggle:Fire(true)
			warn("[N.2DATA] Critical state: high-frequency DataStore errors detected")
		end
	else
		if #issueQueue >= C.CRITICAL_ERROR_COUNT then
			criticalStateStart = now
		elseif now - criticalStateStart > C.CRITICAL_STATE_EXPIRE then
			isCriticalState = false
			OnCriticalToggle:Fire(false)
			warn("[N.2DATA] Critical state ended")
		end
	end
end

local function ReconcileTable(target: any, template: any)
	for k, v in template do
		if typ(k) == "string" then
			if target[k] == nil or typ(target[k]) ~= typ(v) then
				target[k] = StripProxyAndCopy(v)
			elseif typ(target[k]) == "table" and typ(v) == "table" then
				ReconcileTable(target[k], v)
			end
		end
	end
end

local function ValidateSchema(target: any, schema: any): boolean
	if typ(target) ~= typ(schema) then
		return false
	end
	if typ(target) ~= "table" then
		return true
	end
	for k, v in schema do
		local tk = target[k]
		if tk ~= nil and typ(tk) ~= typ(v) then
			return false
		end
		if typ(v) == "table" and tk ~= nil then
			if not ValidateSchema(tk, v) then
				return false
			end
		end
	end
	return true
end

local function CompressData(data: any): any
	if typ(data) ~= "table" then
		return data
	end

	local keys = {}
	local keyMap = {}

	local function getKeyIndex(k: string)
		if not keyMap[k] then
			t_insert(keys, k)
			keyMap[k] = "~" .. tostr(#keys)
		end
		return keyMap[k]
	end

	local function process(val: any): any
		if typ(val) == "table" then
			local newTbl = {}
			for k, v in val do
				if typ(k) == "string" then
					newTbl[getKeyIndex(k)] = process(v)
				else
					newTbl[k] = process(v)
				end
			end
			return newTbl
		end
		return val
	end

	local compressed = process(data)
	return { _C = true, K = keys, D = compressed }
end

local function DecompressData(data: any): any
	if typ(data) == "table" and data._C == true and data.K and data.D then
		local keys = data.K
		local compressed = data.D

		local function process(val: any): any
			if typ(val) == "table" then
				local newTbl = {}
				for k, v in val do
					if typ(k) == "string" and s_find(k, "^~") then
						local idx = tonumber(string.sub(k, 2))
						if idx and keys[idx] then
							newTbl[keys[idx]] = process(v)
						else
							newTbl[k] = process(v)
						end
					else
						newTbl[k] = process(v)
					end
				end
				return newTbl
			end
			return val
		end

		return process(compressed)
	end
	return data
end

local function GenerateId(): string
	return HttpService:GenerateGUID(false)
end

local function CreateMockKeyInfo(
	createdTime: number,
	updatedTime: number,
	versionId: number,
	robloxMetaData: any,
	userIds: any
): any
	local vStr = tostr(versionId)
	return {
		CreatedTime = createdTime,
		UpdatedTime = updatedTime,
		Version = s_rep("0", 16) .. "." .. s_rep("0", 10 - #vStr) .. vStr .. "." .. s_rep("0", 16) .. ".01",
		GetMetadata = function()
			return StripProxyAndCopy(robloxMetaData)
		end,
		GetUserIds = function()
			return StripProxyAndCopy(userIds)
		end,
	}
end

type QueueEntry = { Queue: { any }, First: number, Last: number, Count: number, Processing: boolean }
local Queues: { [string]: QueueEntry } = {}
local RequestPool: { any } = {}

local function AcquireRequest(exec, res, rej)
	local r = t_remove(RequestPool)
	if r then
		r.Execute = exec
		r.Resolve = res
		r.Reject = rej
	else
		r = { Execute = exec, Resolve = res, Reject = rej }
	end
	return r
end

local function ReleaseRequest(r)
	r.Execute = nil
	r.Resolve = nil
	r.Reject = nil
	t_insert(RequestPool, r)
end

local function EnqueueRequest(key: string, executeFn: () -> any): any
	if not Queues[key] then
		Queues[key] = { Queue = {}, First = 1, Last = 0, Count = 0, Processing = false }
	end
	local q = Queues[key]

	if q.Count >= C.MAX_QUEUE_SIZE then
		return Promise.reject("[N.2DATA] Queue overflow for key: " .. key)
	end

	return Promise.new(function(resolve, reject)
		q.Last = q.Last + 1
		q.Count = q.Count + 1
		q.Queue[q.Last] = AcquireRequest(executeFn, resolve, reject)

		if q.Processing then
			return
		end
		q.Processing = true

		task.spawn(function()
			while q.Count > 0 do
				if isCriticalState then
					task.wait(2)
					if q.Count == 0 then
						break
					end
				end

				local req = q.Queue[q.First]
				if not req then
					q.First = q.First + 1
					q.Count = q.Count - 1
					continue
				end

				q.Queue[q.First] = nil
				q.First = q.First + 1
				q.Count = q.Count - 1

				local ok, result, keyInfo = pcall(req.Execute)
				local res, rej2 = req.Resolve, req.Reject
				ReleaseRequest(req)

				if ok then
					res({ result = result, keyInfo = keyInfo })
				else
					RegisterError(result, nil, key)
					rej2(result)
				end
			end
			t_clear(q.Queue)
			q.First = 1
			q.Last = 0
			q.Processing = false
		end)
	end)
end

local function AddToAutoSaveList(profile: any)
	t_insert(autoSaveList, profile)
	if #autoSaveList == 1 then
		lastAutoSave = o_clock()
		autoSaveIndex = 1
	end
end

local function RemoveFromAutoSaveList(profile: any)
	local idx = t_find(autoSaveList, profile)
	if not idx then
		return
	end
	t_remove(autoSaveList, idx)
	if idx < autoSaveIndex then
		autoSaveIndex = autoSaveIndex - 1
	end
	if autoSaveIndex > #autoSaveList or autoSaveIndex < 1 then
		autoSaveIndex = 1
	end
end

local ProfileClass = {}
ProfileClass.__index = ProfileClass

function ProfileClass.new(
	key: string,
	data: any,
	metaData: ProfileMetaData,
	store: any,
	_uniqueSessionId: string?,
	isMockProfile: boolean?,
	keyInfo: DataStoreKeyInfo?
): any
	local self = setmetatable({}, ProfileClass)

	self.Key = key
	self.MetaData = metaData
	self.RobloxMetaData = keyInfo and keyInfo:GetMetadata() or {}
	self.Store = store
	self.UserIds = keyInfo and keyInfo:GetUserIds() or {}
	self.KeyInfo = keyInfo
	self.ViewMode = false
	self.FirstSessionTime = metaData.ProfileCreateTime
	self.SessionLoadCount = metaData.SessionLoadCount

	self._uniqueSessionId = _uniqueSessionId or GenerateId()

	self.OnSave = Signal.new()
	self.OnLastSave = Signal.new()
	self.OnAfterSave = Signal.new()
	self.OnSessionEnd = Signal.new()

	self._isReleased = false
	self._pendingSaves = 0
	self._releaseSignal = Signal.new()
	self._middlewares = { PreSave = {}, PostSave = {}, PreRelease = {} }

	self._clearedUpdates = {}
	self._loadIndex = metaData.SessionLoadCount or 0
	self._isMockProfile = isMockProfile or false
	self._isSaving = false
	self._saveDirty = false
	self._isDirty = false

	local extUpdates = metaData.GlobalUpdates
	self._activeUpdates = {}
	if extUpdates and typ(extUpdates[1]) == "number" then
		for _, u in extUpdates[2] do
			self._activeUpdates[u[1]] = { Id = u[1], Data = u[2], IsLocked = u[3] or false }
		end
	end

	self._lastMessageTime = 0
	self._loadTimestamp = o_clock()
	self._needsReconcile = false

	local function markDirty()
		self._isDirty = true
	end

	self.Data = CreateDeepProxy(data, markDirty)
	self.LastSavedData = StripProxyAndCopy(data)

	activeProfiles[key] = self
	activeProfileCount = activeProfileCount + 1
	AddToAutoSaveList(self)

	return self :: any
end

function ProfileClass:__newindex(key, value)
	if key == "Data" then
		if typ(value) ~= "table" then
			error(
				string.format(
					"[N.2DATA] PROTECTION ERROR: Profile.Data must be a table!\n(Received type: %s)\nCheck the logic in your script.",
					typ(value)
				),
				2
			)
		end

		local function markDirty()
			self._isDirty = true
		end

		rawset(self, key, CreateDeepProxy(value, markDirty))
		rawset(self, "_needsReconcile", true)
		rawset(self, "_isDirty", true)
	else
		rawset(self, key, value)
	end
end

function ProfileClass:IsActive(): boolean
	return not self._isReleased
end

function ProfileClass:MarkDirty()
	self._isDirty = true
end

function ProfileClass:Reconcile()
	if not self:IsActive() and not self.ViewMode then
		return
	end
	ReconcileTable(self.Data, self.Store.Template)
end

function ProfileClass:AddUserId(userId: number)
	assert(typ(userId) == "number" and userId % 1 == 0, "[N.2DATA] AddUserId: invalid argument")
	if userId < 0 and not self._isMockProfile and DataStoreState == "Access" then
		return
	end
	if not t_find(self.UserIds, userId) then
		t_insert(self.UserIds, userId)
	end
end

function ProfileClass:RemoveUserId(userId: number)
	assert(typ(userId) == "number" and userId % 1 == 0, "[N.2DATA] RemoveUserId: invalid argument")
	local idx = t_find(self.UserIds, userId)
	if idx then
		t_remove(self.UserIds, idx)
	end
end

function ProfileClass:ArrayInsert(targetTable: { any }, value: any, pos: number?)
	assert(typ(targetTable) == "table", "[N.2DATA] ArrayInsert: targetTable must be a table")
	if pos then
		t_insert(targetTable, pos, value)
	else
		t_insert(targetTable, value)
	end
	self:MarkDirty()
end

function ProfileClass:ArrayRemove(targetTable: { any }, pos: number): any
	assert(typ(targetTable) == "table", "[N.2DATA] ArrayRemove: targetTable must be a table")
	assert(typ(pos) == "number", "[N.2DATA] ArrayRemove: pos must be a number")
	local removed = t_remove(targetTable, pos)
	self:MarkDirty()
	return removed
end

function ProfileClass:ArrayClear(targetTable: { any })
	assert(typ(targetTable) == "table", "[N.2DATA] ArrayClear: targetTable must be a table")
	t_clear(targetTable)
	self:MarkDirty()
end

function ProfileClass:ListenToRelease(callback: () -> ()): any
	assert(typ(callback) == "function", "[N.2DATA] ListenToRelease: callback must be a function")
	return self._releaseSignal:Connect(callback)
end

function ProfileClass:AddMiddleware(hook: string, callback: (...any) -> any)
	assert(typ(callback) == "function", "[N.2DATA] AddMiddleware: callback must be a function")
	if self._middlewares[hook] then
		t_insert(self._middlewares[hook], callback)
	else
		warn("[N.2DATA] AddMiddleware: unknown hook '" .. tostr(hook) .. "'")
	end
end

function ProfileClass:_RunMiddlewares(hook: string, data: any): any
	local list = self._middlewares[hook]
	if not list or #list == 0 then
		return data
	end
	local current = data
	for i = 1, #list do
		local ok, result = pcall(list[i], current)
		if ok and result ~= nil then
			current = result
		elseif not ok then
			warn("[N.2DATA] Middleware '" .. hook .. "' error: " .. tostr(result))
		end
	end
	return current
end

function ProfileClass:SetMetaTag(tag: string, value: any)
	assert(typ(tag) == "string", "[N.2DATA] SetMetaTag: tag must be a string")
	if not self:IsActive() and not self.ViewMode then
		return
	end
	self.MetaData.MetaTags[tag] = value
end

function ProfileClass:GetMetaTag(tag: string): any
	return self.MetaData.MetaTags[tag]
end

function ProfileClass:Save(): any
	if self.ViewMode then
		return Promise.reject("[N.2DATA] :Save() is not allowed in ViewMode")
	end
	if not self:IsActive() then
		return Promise.reject("[N.2DATA] :Save() called on released profile")
	end

	if self._isSaving then
		self._saveDirty = true
		return Promise.resolve(true)
	end

	self._isSaving = true
	self._saveDirty = false

	return self:_SaveInternal(false, false, nil):finally(function()
		self._isSaving = false
		if self._saveDirty and self:IsActive() then
			task.spawn(function()
				self:Save():catch(function(_) end)
			end)
		end
	end)
end

function ProfileClass:SetAsync(): any
	if not self.ViewMode then
		return Promise.reject("[N.2DATA] :SetAsync() is only for ViewMode")
	end
	return self:_SaveInternal(false, true, nil)
end

function ProfileClass:_SaveInternal(isReleasing: boolean, forceOverride: boolean, _releaseReason: string?): any
	if not self:IsActive() and not isReleasing and not forceOverride then
		return Promise.reject("[N.2DATA] _SaveInternal: profile is already released")
	end

	if self._needsReconcile then
		if self.Store and self.Store.Template then
			if not ValidateSchema(self.Data, self.Store.Template) then
				warn(
					string.format(
						"[N.2DATA] SCHEMA MISMATCH DETECTED: Auto-reconciling before save.\n(Store: %s)",
						tostr(self.Store.Name)
					)
				)
				ReconcileTable(self.Data, self.Store.Template)
			end
		end
		self._needsReconcile = false
	end

	self._pendingSaves = self._pendingSaves + 1
	activeSaveJobs = activeSaveJobs + 1

	self.OnSave:Fire()

	local cleanData = StripProxyAndCopy(self.Data)
	local dataToSave = self:_RunMiddlewares("PreSave", cleanData)
	local dataToSaveToDatastore = self.Store._config.UseArrayCompression and CompressData(dataToSave) or dataToSave

	local myJobId = JOB_ID
	local myPlaceId = PLACE_ID
	local myLoadIdx = self._loadIndex
	local myMeta = StripProxyAndCopy(self.MetaData)
	local myUserIds = self.UserIds

	local useMock = self.Store.MockMode or self._isMockProfile
	local mockRef = self._isMockProfile and self.Store._userMockStore or self.Store._mockStore
	local capturedReleasing = isReleasing

	return EnqueueRequest(self.Key, function()
		if useMock then
			local existing = mockRef[self.Key]
			if not forceOverride and existing then
				local sess = existing.MetaData.ActiveSession
				local ownsSession = sess
					and sess.JobId == myJobId
					and sess.PlaceId == myPlaceId
					and existing.MetaData.SessionLoadCount == myLoadIdx
				if sess and not ownsSession and not capturedReleasing then
					error("SESSION_LOST")
				end
			end

			myMeta.LastUpdateTime = o_time()
			if capturedReleasing then
				myMeta.ActiveSession = nil
			end

			local extUpdates = existing and existing.MetaData and existing.MetaData.GlobalUpdates
			local extList = (extUpdates and typ(extUpdates[1]) == "number") and extUpdates[2] or {}
			local mergedUpdates = {}
			for i = 1, #extList do
				local ext = extList[i]
				local id = ext[1]
				if not self._clearedUpdates[id] then
					local extClone = t_clone(ext)
					if extClone[3] ~= true and self._activeUpdates[id] and self._activeUpdates[id].IsLocked then
						extClone[3] = true
					end
					t_insert(mergedUpdates, extClone)
				end
			end

			local extIndex = (extUpdates and typ(extUpdates[1]) == "number") and extUpdates[1] or 0

			if not myMeta.GlobalUpdates or typ(myMeta.GlobalUpdates[1]) ~= "number" then
				myMeta.GlobalUpdates = { 0, {} } :: { any }
			end
			myMeta.GlobalUpdates[1] = m_max(myMeta.GlobalUpdates[1], extIndex)
			myMeta.GlobalUpdates[2] = mergedUpdates

			local cTime = existing and existing.CreatedTime or m_floor(o_time() * 1000)
			local uTime = m_floor(o_time() * 1000)
			local vId = existing and (existing.VersionId + 1) or 1

			mockRef[self.Key] = {
				Data = StripProxyAndCopy(dataToSaveToDatastore),
				MetaData = StripProxyAndCopy(myMeta),
				RobloxMetaData = StripProxyAndCopy(self.RobloxMetaData),
				CreatedTime = cTime,
				UpdatedTime = uTime,
				VersionId = vId,
				UserIds = StripProxyAndCopy(myUserIds),
			}
			return CreateMockKeyInfo(cTime, uTime, vId, self.RobloxMetaData, myUserIds)
		end

		local ds = self.Store._dataStore
		if not ds then
			error("DATASTORE_UNAVAILABLE")
		end

		local saveCancelled = false
		local _, info = ds:UpdateAsync(self.Key, function(latest: any): (any, { number }?, any)
			if not latest then
				if forceOverride then
					latest = { Data = {}, MetaData = self.Store:_createDefaultMetaData() }
				else
					saveCancelled = true
					return nil
				end
			end

			if not forceOverride then
				local sess = latest.MetaData.ActiveSession
				local ownsSession = sess
					and sess.JobId == myJobId
					and sess.PlaceId == myPlaceId
					and latest.MetaData.SessionLoadCount == myLoadIdx
				if sess and not ownsSession and not capturedReleasing then
					saveCancelled = true
					return nil
				end

				local fs = latest.MetaData.ForceLoadSession
				if fs and fs.JobId ~= myJobId then
					capturedReleasing = true
					myMeta.ActiveSession = nil
				end
			end

			myMeta.LastUpdateTime = o_time()
			if capturedReleasing then
				myMeta.ActiveSession = nil
			end

			local extUpdates = latest.MetaData.GlobalUpdates
			local extList = (extUpdates and typ(extUpdates[1]) == "number") and extUpdates[2] or {}
			local mergedUpdates = {}
			for i = 1, #extList do
				local ext = extList[i]
				local id = ext[1]
				if not self._clearedUpdates[id] then
					local extClone = t_clone(ext)
					if extClone[3] ~= true and self._activeUpdates[id] and self._activeUpdates[id].IsLocked then
						extClone[3] = true
					end
					t_insert(mergedUpdates, extClone)
				end
			end

			local extIndex = (extUpdates and typ(extUpdates[1]) == "number") and extUpdates[1] or 0

			if not myMeta.GlobalUpdates or typ(myMeta.GlobalUpdates[1]) ~= "number" then
				myMeta.GlobalUpdates = { 0, {} } :: { any }
			end
			myMeta.GlobalUpdates[1] = m_max(myMeta.GlobalUpdates[1], extIndex)
			myMeta.GlobalUpdates[2] = mergedUpdates

			latest.Data = dataToSaveToDatastore
			latest.MetaData = myMeta

			return latest, myUserIds, self.RobloxMetaData
		end)

		if saveCancelled then
			error("SESSION_LOST")
		end

		return info
	end):andThen(function(resData)
		local loadedKeyInfo = resData.result
		self._pendingSaves = self._pendingSaves - 1
		activeSaveJobs = activeSaveJobs - 1

		self.LastSavedData = dataToSave
		self.MetaData = myMeta

		t_clear(self._activeUpdates)
		for _, u in self.MetaData.GlobalUpdates[2] do
			self._activeUpdates[u[1]] = { Id = u[1], Data = u[2], IsLocked = u[3] or false }
		end

		self._lastSaveTime = o_clock()
		self._isDirty = false
		if loadedKeyInfo then
			self.KeyInfo = loadedKeyInfo
		end
		self:_RunMiddlewares("PostSave", dataToSave)
		self.OnAfterSave:Fire(self.LastSavedData)

		if capturedReleasing and self.Store._backupStore then
			task.spawn(function()
				pcall(function()
					self.Store._backupStore:SetAsync(self.Key, {
						Data = dataToSaveToDatastore,
						MetaData = myMeta,
						BackupTimestamp = o_time(),
					})
				end)
			end)
		end

		return true
	end):catch(function(err)
		self._pendingSaves = self._pendingSaves - 1
		activeSaveJobs = activeSaveJobs - 1

		if tostr(err):match("SESSION_LOST") then
			if not capturedReleasing then
				task.spawn(function()
					self:_ReleaseInternal("External")
				end)
			end
			return Promise.reject("[N.2DATA] Save rejected: Session ownership lost")
		end

		RegisterError(err, self.Store.Name, self.Key)
		return Promise.reject(err)
	end)
end

function ProfileClass:Release(): any
	warn(`[N.2DATA] Profile:Release() is deprecated, use Profile:EndSession() instead.`)
	return self:EndSession()
end

function ProfileClass:EndSession(): any
	return self:_ReleaseInternal("Manual")
end

function ProfileClass:_ReleaseInternal(reason: string): any
	if self._isReleased then
		return Promise.resolve(nil)
	end

	local cleanData = StripProxyAndCopy(self.Data)
	self:_RunMiddlewares("PreRelease", cleanData)
	self._isReleased = true

	activeProfiles[self.Key] = nil
	activeProfileCount = activeProfileCount - 1
	RemoveFromAutoSaveList(self)

	self.OnLastSave:Fire(reason)
	self.OnSessionEnd:Fire()
	self._releaseSignal:Fire()
	self._releaseSignal:DisconnectAll()

	local function attemptSave(retries: number, backoff: number): any
		return self:_SaveInternal(true, false, reason):catch(function(err)
			local errStr = tostr(err)
			if
				s_find(errStr, "104")
				or s_find(errStr, "Forbidden")
				or s_find(errStr, "DataStore API is not accessible")
				or s_find(errStr, "SESSION_LOST")
				or s_find(errStr, "Session ownership lost")
			then
				return Promise.reject(err)
			end

			local limit = isShuttingDown and C.MAX_SHUTDOWN_RETRIES or C.MAX_RELEASE_RETRIES
			if retries < limit then
				local cap = isShuttingDown and 8 or 20
				local nextBo = m_min(cap, backoff * 2)
				local jitter = math.random() * (nextBo * 0.2)
				return Promise.delay(nextBo + jitter):andThen(function()
					return attemptSave(retries + 1, nextBo)
				end)
			end
			warn("[N.2DATA] Release: gave up after " .. retries .. " retries — KEY:" .. self.Key)
			return Promise.reject(err)
		end)
	end

	return attemptSave(0, 1)
end

function ProfileClass:AddGlobalUpdate(updateData: any): any
	if not self:IsActive() then
		return Promise.reject("[N.2DATA] AddGlobalUpdate: inactive")
	end

	if not self.MetaData.GlobalUpdates or typ(self.MetaData.GlobalUpdates[1]) ~= "number" then
		self.MetaData.GlobalUpdates = { 0, {} } :: { any }
	end

	self.MetaData.GlobalUpdates[1] = self.MetaData.GlobalUpdates[1] + 1
	local newId = self.MetaData.GlobalUpdates[1]
	t_insert(self.MetaData.GlobalUpdates[2], { newId, updateData, false })
	self._activeUpdates[newId] = { Id = newId, Data = updateData, IsLocked = false }
	self._isDirty = true
	return self:Save()
end

function ProfileClass:GetActiveGlobalUpdates(): { GlobalUpdate }
	local out = {}
	for id, u in self._activeUpdates do
		if not self._clearedUpdates[id] then
			t_insert(out, { Id = u.Id, Data = u.Data, IsLocked = u.IsLocked })
		end
	end
	return out
end

function ProfileClass:LockGlobalUpdate(updateId: number): any
	assert(typ(updateId) == "number", "[N.2DATA] LockGlobalUpdate: Invalid ID")
	if self._activeUpdates[updateId] and not self._activeUpdates[updateId].IsLocked then
		self._activeUpdates[updateId].IsLocked = true
		self._isDirty = true
		return self:Save()
	end
	return Promise.resolve(nil)
end

function ProfileClass:ClearGlobalUpdate(updateId: number): any
	assert(typ(updateId) == "number", "[N.2DATA] ClearGlobalUpdate: Invalid ID")
	if not self._clearedUpdates[updateId] then
		self._clearedUpdates[updateId] = true
		self._isDirty = true
		return self:Save()
	end
	return Promise.resolve(nil)
end

function ProfileClass:ProcessGlobalUpdates(callback: (message: any, processed: () -> ()) -> ())
	assert(typ(callback) == "function", "[N.2DATA] ProcessGlobalUpdates: callback must be a function")
	if not self.ViewMode and not self:IsActive() then
		return
	end

	local activeUpdates = self:GetActiveGlobalUpdates()
	for i = 1, #activeUpdates do
		local u = activeUpdates[i]
		if not u.IsLocked then
			local function processed()
				self:ClearGlobalUpdate(u.Id):catch(function(err)
					warn("[N.2DATA] ProcessGlobalUpdates: clear failed — " .. tostr(err))
				end)
			end
			task.spawn(callback, StripProxyAndCopy(u.Data), processed)
		end
	end
end

local VersionQueryClass = {}
VersionQueryClass.__index = VersionQueryClass

function VersionQueryClass.new(store, key, sortDir, minDate, maxDate)
	return setmetatable({
		_store = store,
		_key = key,
		_sortDir = sortDir,
		_minDate = minDate,
		_maxDate = maxDate,
		_pages = nil,
		_pageIdx = 0,
		_failed = false,
		_yielded = false,
		_jobQueue = {},
	}, VersionQueryClass)
end

function VersionQueryClass:NextAsync(): any
	if isShuttingDown then
		return Promise.reject("[N.2DATA] VersionQuery: shutting down")
	end
	if self._store.MockMode then
		return Promise.reject("[N.2DATA] VersionQuery: not supported in Mock")
	end

	return Promise.new(function(resolve, reject)
		local function queryJob()
			if self._failed then
				reject("[N.2DATA] VersionQuery: invalid")
				return
			end

			if not self._pages then
				self._yielded = true
				local ok, result = pcall(function()
					return self._store._dataStore:ListVersionsAsync(
						self._key,
						self._sortDir,
						self._minDate,
						self._maxDate
					)
				end)
				self._yielded = false

				if not ok or not result then
					self._failed = true
					for i = 1, #self._jobQueue do
						task.spawn(self._jobQueue[i])
					end
					t_clear(self._jobQueue)
					reject("[N.2DATA] VersionQuery: ListVersionsAsync failed — " .. tostr(result))
					return
				end
				self._pages = result
				self._pageIdx = 0
			end

			local page = self._pages:GetCurrentPage()
			local item = page[self._pageIdx + 1]

			if self._pages.IsFinished and not item then
				resolve(nil)
				return
			end

			if not item then
				self._yielded = true
				local ok2, err2 = pcall(function()
					self._pages:AdvanceToNextPageAsync()
				end)
				self._yielded = false
				self._pageIdx = 0

				local nextJob = t_remove(self._jobQueue, 1)
				if nextJob then
					task.spawn(nextJob)
				end

				if not ok2 then
					self._failed = true
					for i = 1, #self._jobQueue do
						task.spawn(self._jobQueue[i])
					end
					t_clear(self._jobQueue)
					reject("[N.2DATA] VersionQuery: AdvanceToNextPageAsync failed — " .. tostr(err2))
					return
				end

				page = self._pages:GetCurrentPage()
				if #page == 0 then
					resolve(nil)
					return
				end
				item = page[1]
			end

			self._pageIdx = self._pageIdx + 1
			self._store:ViewProfileAsync(self._key, item.Version):andThen(resolve):catch(reject)
		end

		if not self._yielded then
			task.spawn(queryJob)
		else
			t_insert(self._jobQueue, queryJob)
		end
	end)
end

local StoreClass = {}
StoreClass.__index = StoreClass

function StoreClass:_createDefaultMetaData()
	return {
		ProfileCreateTime = o_time(),
		SessionLoadCount = 0,
		ActiveSession = nil,
		ForceLoadSession = nil,
		MetaTags = {},
		GlobalUpdates = { 0, {} } :: { any },
		LastUpdateTime = o_time(),
		Version = 0,
	}
end

function StoreClass.new(config: StoreConfig, template: any): any
	local self = setmetatable({}, StoreClass)

	self._config = config
	self.Name = config.DataStoreName
	self.Template = template
	self.MockMode = config.UseMock == true or (DataStoreState ~= "Access" and DataStoreState ~= "NotReady")
	self._mockStore = {}
	self._userMockStore = {}
	self._migrations = {}
	self._sortedKeys = {}
	self._migrationsSorted = true
	self._dataStore = nil
	self._backupStore = nil
	self._mockNextCall = false

	task.spawn(function()
		while DataStoreState == "NotReady" do
			task.wait()
		end
		if DataStoreState ~= "Access" and not config.UseMock then
			self.MockMode = true
		end
		if DataStoreState == "Access" and not config.UseMock then
			self._dataStore = DataStoreService:GetDataStore(config.DataStoreName, config.Scope, DATA_STORE_OPTIONS)
			self._backupStore =
				DataStoreService:GetDataStore(config.DataStoreName .. "_Backups", config.Scope, DATA_STORE_OPTIONS)
		end
	end)

	local parentStore = self
	local mockProxy = {}

	local proxyNames = {
		"LoadProfileAsync",
		"ViewProfileAsync",
		"ProfileVersionQuery",
		"GlobalUpdateProfileAsync",
		"WipeProfileAsync",
		"RestoreFromBackupAsync",
	}
	for i = 1, #proxyNames do
		local name = proxyNames[i]
		mockProxy[name] = function(_, ...)
			parentStore._mockNextCall = true
			return StoreClass[name](parentStore, ...)
		end
	end

	setmetatable(mockProxy, {
		__index = function(_, k)
			return parentStore[k]
		end,
		__newindex = function(_, k, v)
			parentStore[k] = v
		end,
	})

	self.Mock = mockProxy
	return self :: any
end

function StoreClass:AddMigration(version: number, handler: (data: any) -> any)
	assert(
		typ(version) == "number" and version > 0 and version == m_floor(version),
		"[N.2DATA] AddMigration: version must be a positive integer"
	)
	assert(typ(handler) == "function", "[N.2DATA] AddMigration: handler must be a function")
	assert(self._migrations[version] == nil, "[N.2DATA] AddMigration: version already registered")

	self._migrations[version] = handler
	t_insert(self._sortedKeys, version)
	self._migrationsSorted = false
end

function StoreClass:_runMigrations(data: any, currentVersion: number): (any, number)
	if not self._migrationsSorted then
		table.sort(self._sortedKeys)
		self._migrationsSorted = true
	end

	local keys = self._sortedKeys
	if not keys or #keys == 0 or keys[#keys] <= currentVersion then
		return data, currentVersion
	end

	local migrated = StripProxyAndCopy(data)
	local newVersion = currentVersion

	for i = 1, #keys do
		local v = keys[i]
		if v > currentVersion then
			local snapshot = StripProxyAndCopy(migrated)
			local ok, result = pcall(self._migrations[v], migrated)

			if ok then
				if result ~= nil then
					migrated = result
				end
				newVersion = v
			else
				warn(
					"[N.2DATA] Migration v"
						.. v
						.. " FAILED (rolled back to v"
						.. newVersion
						.. ") — "
						.. tostr(result)
				)
				migrated = snapshot
				break
			end
		end
	end

	return migrated, newVersion
end

function StoreClass:_waitForDataStore()
	local waitStart = o_clock()
	while DataStoreState == "NotReady" do
		if o_clock() - waitStart > 15 then
			warn("[N.2DATA] _waitForDataStore: DataStore API timeout")
			break
		end
		task.wait(0.1)
	end
end

function StoreClass:RestoreFromBackupAsync(key: string): any
	assert(typ(key) == "string" and #key > 0, "[N.2DATA] RestoreFromBackupAsync: Invalid key")

	return Promise.new(function(resolve, reject)
		if self.MockMode or not self._backupStore then
			reject("[N.2DATA] RestoreFromBackupAsync: Disabled in Mock mode")
			return
		end

		local ok, result = pcall(function()
			return self._backupStore:GetAsync(key)
		end)

		if ok and result and result.Data then
			resolve(result.Data)
		else
			reject("[N.2DATA] Backup failure — " .. tostr(result))
		end
	end)
end

function StoreClass:LoadProfileAsync(key: string, forceLoad: boolean?, cancelFn: (() -> boolean)?): any
	assert(typ(key) == "string" and #key > 0 and #key <= 50, "[N.2DATA] LoadProfileAsync: Invalid key")
	if isShuttingDown then
		return Promise.reject("[N.2DATA] LoadProfileAsync: shutting down")
	end

	local pendingKey = self.Name .. "\0" .. key
	if pendingLoadJobs[pendingKey] then
		return pendingLoadJobs[pendingKey]
	end

	local isMockCall = self._mockNextCall
	self._mockNextCall = false

	activeLoadJobs = activeLoadJobs + 1

	local promise = Promise.new(function(resolve, reject)
		self:_waitForDataStore()
		local useMock = isMockCall or self.MockMode
		local mockRef = isMockCall and self._userMockStore or self._mockStore

		local requestForceLoad = true
		local stealSession = false
		local forceLoadSteps = 0
		local startTime = o_clock()
		local firstAttempt = true
		local sessionId = GenerateId()

		local function cancelled(): boolean
			if isShuttingDown then
				return true
			end
			if cancelFn and cancelFn() == true then
				return true
			end
			return false
		end

		local function attemptLoad()
			if cancelled() then
				reject("[N.2DATA] LoadProfileAsync: cancelled")
				return
			end

			EnqueueRequest(key, function()
				if activeProfiles[key] then
					return { success = true, profile = activeProfiles[key] }
				end

				if useMock then
					local md = mockRef[key]
					local dat = md and StripProxyAndCopy(md.Data) or StripProxyAndCopy(self.Template)
					local met = md and StripProxyAndCopy(md.MetaData) or self:_createDefaultMetaData()
					local rMeta = md and StripProxyAndCopy(md.RobloxMetaData) or {}

					local activeSess = met.ActiveSession
					if activeSess and activeSess.JobId ~= JOB_ID and not forceLoad and not stealSession then
						return { success = false, locked = true, activeSession = activeSess }
					end

					dat, met.Version = self:_runMigrations(dat, met.Version or 0)
					met.SessionLoadCount = met.SessionLoadCount + 1
					met.ActiveSession = { JobId = JOB_ID, PlaceId = PLACE_ID, SessionId = sessionId }
					met.LastUpdateTime = o_time()

					local cTime = md and md.CreatedTime or m_floor(o_time() * 1000)
					local uTime = m_floor(o_time() * 1000)
					local vId = md and (md.VersionId + 1) or 1
					local uIds = md and md.UserIds or {}

					mockRef[key] = {
						Data = StripProxyAndCopy(dat),
						MetaData = StripProxyAndCopy(met),
						RobloxMetaData = StripProxyAndCopy(rMeta),
						CreatedTime = cTime,
						UpdatedTime = uTime,
						VersionId = vId,
						UserIds = StripProxyAndCopy(uIds),
					}

					local mockKeyInfo = CreateMockKeyInfo(cTime, uTime, vId, rMeta, uIds)
					local p = ProfileClass.new(key, dat, met, self, sessionId, isMockCall, mockKeyInfo)
					p:Reconcile()
					return p
				end

				if not self._dataStore then
				error("DATASTORE_UNAVAILABLE")
				end

				local claimed = false
				local lockedByOther = false
				local lockedSession = nil

				local loadedData, loadedKeyInfo = self._dataStore:UpdateAsync(key, function(existing: any): any
				if not existing then
					local meta = self:_createDefaultMetaData()
					meta.SessionLoadCount = 1
					meta.ActiveSession = { JobId = JOB_ID, PlaceId = PLACE_ID, SessionId = sessionId }
					meta.LastUpdateTime = o_time()
					claimed = true
					local initData = StripProxyAndCopy(self.Template)
					if self.Store and self.Store._config.UseArrayCompression then
						initData = CompressData(initData)
					end
					return { Data = initData, MetaData = meta }
				end

				local uncompressedData = DecompressData(existing.Data)
				if not ValidateSchema(uncompressedData, self.Template) then
					ReconcileTable(uncompressedData, self.Template)
					if self.Store and self.Store._config.UseArrayCompression then
						existing.Data = CompressData(uncompressedData)
					else
						existing.Data = uncompressedData
					end
					RegisterOverwrite(self.Name, key)
				end

				local sess = existing.MetaData.ActiveSession
				if not sess then
					existing.MetaData.ActiveSession = { JobId = JOB_ID, PlaceId = PLACE_ID, SessionId = sessionId }
					existing.MetaData.ForceLoadSession = nil
					existing.MetaData.SessionLoadCount = existing.MetaData.SessionLoadCount + 1
					existing.MetaData.LastUpdateTime = o_time()
					claimed = true
					return existing
				end

				if sess.JobId == JOB_ID and sess.PlaceId == PLACE_ID then
					existing.MetaData.LastUpdateTime = o_time()
					claimed = true
					return existing
				end

				local age = o_time() - (existing.MetaData.LastUpdateTime or 0)
				if age > C.ASSUME_DEAD then
					existing.MetaData.ActiveSession = { JobId = JOB_ID, PlaceId = PLACE_ID, SessionId = sessionId }
					existing.MetaData.ForceLoadSession = nil
					existing.MetaData.SessionLoadCount = existing.MetaData.SessionLoadCount + 1
					existing.MetaData.LastUpdateTime = o_time()
					claimed = true
					return existing
				end

				if stealSession then
					local fs = existing.MetaData.ForceLoadSession
					local myForce = fs and fs.JobId == JOB_ID and fs.PlaceId == PLACE_ID
					if myForce or forceLoad then
						existing.MetaData.ActiveSession =
							{ JobId = JOB_ID, PlaceId = PLACE_ID, SessionId = sessionId }
						existing.MetaData.ForceLoadSession = nil
						existing.MetaData.SessionLoadCount = existing.MetaData.SessionLoadCount + 1
						existing.MetaData.LastUpdateTime = o_time()
						claimed = true
						return existing
					end
				end

				lockedByOther = true
				lockedSession = existing.MetaData.ActiveSession
				if forceLoad and requestForceLoad then
					existing.MetaData.ForceLoadSession = { JobId = JOB_ID, PlaceId = PLACE_ID }
				end
				return existing
				end)

				if claimed then
				loadedData.Data = DecompressData(loadedData.Data)
				loadedData.Data, loadedData.MetaData.Version =
					self:_runMigrations(loadedData.Data, loadedData.MetaData.Version or 0)
					local profile = ProfileClass.new(
						key,
						loadedData.Data,
						loadedData.MetaData,
						self,
						sessionId,
						false,
						loadedKeyInfo
					)
					profile:Reconcile()

					task.spawn(function()
						pcall(function()
							local topic = MESSAGING_PREFIX .. sessionId
							local conn = MessagingService:SubscribeAsync(topic, function(msg)
								if typ(msg.Data) ~= "table" then
									return
								end
								if msg.Data.LoadCount ~= profile._loadIndex then
									return
								end
								if not profile:IsActive() then
									return
								end

								local now = o_clock()
								if now - profile._lastMessageTime < C.MESSAGING_COOLDOWN then
									return
								end
								profile._lastMessageTime = now

								task.spawn(function()
									while profile._pendingSaves > 0 do
										task.wait(0.1)
									end
									if not profile:IsActive() then
										return
									end
									if msg.Data.EndSession then
										profile:_ReleaseInternal("External"):catch(function(_) end)
									else
										profile:Save():catch(function(_) end)
									end
								end)
							end)
							profile:ListenToRelease(function()
								pcall(function()
									conn:Disconnect()
								end)
							end)
						end)
					end)

					return profile
				end

				if lockedByOther then
					return { success = false, locked = true, activeSession = lockedSession }
				end

				return { success = false, error = "Unknown state" }
			end):andThen(function(resData)
				local result = resData.result
				local loadedKeyInfo = resData.keyInfo

				if typ(result) == "table" and result.Key then
					if loadedKeyInfo then
						result.KeyInfo = loadedKeyInfo
					end
					resolve(result)
					return
				end
				if typ(result) == "table" and result.success == true then
					if result.profile and loadedKeyInfo then
						result.profile.KeyInfo = loadedKeyInfo
					end
					resolve(result.profile)
					return
				end

				if result.locked then
					if not forceLoad then
						reject("[N.2DATA] Profile locked")
						return
					end
					if cancelled() then
						reject("[N.2DATA] Load cancelled")
						return
					end

					if o_clock() - startTime >= C.START_SESSION_TIMEOUT then
						reject("[N.2DATA] Load timed out while waiting for session lock to release")
						return
					end

					local rs = result.activeSession
					if rs and rs.SessionId then
						pcall(function()
							MessagingService:PublishAsync(
								MESSAGING_PREFIX .. rs.SessionId,
								{ LoadCount = rs.SessionLoadCount, EndSession = true }
							)
						end)
					end

					local wait = firstAttempt and C.FIRST_LOAD_REPEAT or C.LOAD_REPEAT_PERIOD
					firstAttempt = false
					requestForceLoad = false
					forceLoadSteps = forceLoadSteps + 1
					if forceLoadSteps >= m_ceil(C.SESSION_STEAL / C.LOAD_REPEAT_PERIOD) then
						stealSession = true
					end

					local jitter = math.random() * (wait * 0.2)
					task.delay(wait + jitter, attemptLoad)
					return
				end

				reject(result.error or "[N.2DATA] Load failed")
			end):catch(function(_err)
				if cancelled() then
					reject("[N.2DATA] Load cancelled")
					return
				end

				if o_clock() - startTime >= C.START_SESSION_TIMEOUT then
					reject("[N.2DATA] Load timed out")
					return
				end

				local backoff = m_min(20, 2 ^ m_min(forceLoadSteps, 4))
				local jitter = math.random() * (backoff * 0.2)
				task.delay(backoff + jitter, attemptLoad)
			end)
		end

		attemptLoad()
	end)

	pendingLoadJobs[pendingKey] = promise
	promise:finally(function()
		activeLoadJobs = activeLoadJobs - 1
		if pendingLoadJobs[pendingKey] == promise then
			pendingLoadJobs[pendingKey] = nil
		end
	end)

	return promise
end

function StoreClass:ViewProfileAsync(key: string, version: string?): any
	assert(typ(key) == "string" and #key > 0, "[N.2DATA] ViewProfileAsync: Invalid key")
	local isMockCall = self._mockNextCall
	self._mockNextCall = false
	local mockRef = isMockCall and self._userMockStore or self._mockStore
	local useMock = isMockCall or self.MockMode

	return EnqueueRequest(key, function()
		if useMock then
			local md = mockRef[key]
			local mockKeyInfo = nil
			if md then
				mockKeyInfo =
					CreateMockKeyInfo(md.CreatedTime, md.UpdatedTime, md.VersionId, md.RobloxMetaData or {}, md.UserIds)
			end
			local p = ProfileClass.new(
				key,
				md and StripProxyAndCopy(md.Data) or StripProxyAndCopy(self.Template),
				md and StripProxyAndCopy(md.MetaData) or self:_createDefaultMetaData(),
				self,
				nil,
				isMockCall,
				mockKeyInfo
			)
			p.ViewMode = true
			return p
		end

		if not self._dataStore then
			error("[N.2DATA] ViewProfileAsync: not initialized")
		end

		local result, loadedKeyInfo
		if version then
			result, loadedKeyInfo = self._dataStore:GetVersionAsync(key, version)
		else
			result, loadedKeyInfo = self._dataStore:GetAsync(key)
		end

		if not result then
			return nil
		end

		local dat, newVer = self:_runMigrations(result.Data, result.MetaData.Version or 0)
		result.MetaData.Version = newVer
		local p = ProfileClass.new(key, dat, result.MetaData, self, nil, false, loadedKeyInfo)
		p.ViewMode = true
		return p
	end):andThen(function(resData)
		return resData.result
	end)
end

function StoreClass:ProfileVersionQuery(
	key: string,
	sortDir: Enum.SortDirection?,
	minDate: number?,
	maxDate: number?
): VersionQuery
	assert(typ(key) == "string" and #key > 0, "[N.2DATA] ProfileVersionQuery: Invalid key")
	return VersionQueryClass.new(self, key, sortDir, minDate, maxDate) :: any
end

function StoreClass:GlobalUpdateProfileAsync(key: string, updateData: any): any
	assert(typ(key) == "string" and #key > 0, "[N.2DATA] GlobalUpdateProfileAsync: Invalid key")
	local isMockCall = self._mockNextCall
	self._mockNextCall = false

	local p = activeProfiles[key]
	if p and p:IsActive() then
		return p:AddGlobalUpdate(updateData):andThen(function()
			return true
		end)
	end

	local mockRef = isMockCall and self._userMockStore or self._mockStore
	local useMock = isMockCall or self.MockMode

	return EnqueueRequest(key, function()
		if useMock then
			local md = mockRef[key]
			if not md then
				return false
			end

			if not md.MetaData.GlobalUpdates or typ(md.MetaData.GlobalUpdates[1]) ~= "number" then
				md.MetaData.GlobalUpdates = { 0, {} } :: { any }
			end

			md.MetaData.GlobalUpdates[1] = md.MetaData.GlobalUpdates[1] + 1
			t_insert(md.MetaData.GlobalUpdates[2], { md.MetaData.GlobalUpdates[1], updateData })
			return true
		end

		if not self._dataStore then
			error("[N.2DATA] GlobalUpdateProfileAsync: not initialized")
		end

		local remoteSessionId = nil
		local remoteLoadCount = 0

		local _, _info = self._dataStore:UpdateAsync(key, function(existing: any): any
			if not existing then
				return nil
			end

			if not existing.MetaData.GlobalUpdates or typ(existing.MetaData.GlobalUpdates[1]) ~= "number" then
				existing.MetaData.GlobalUpdates = { 0, {} } :: { any }
			end

			existing.MetaData.GlobalUpdates[1] = existing.MetaData.GlobalUpdates[1] + 1
			t_insert(existing.MetaData.GlobalUpdates[2], { existing.MetaData.GlobalUpdates[1], updateData })

			local sess = existing.MetaData.ActiveSession
			if sess and (sess.JobId ~= JOB_ID or sess.PlaceId ~= PLACE_ID) and sess.SessionId then
				remoteSessionId = sess.SessionId
				remoteLoadCount = existing.MetaData.SessionLoadCount or 0
			end

			return existing
		end)

		if remoteSessionId then
			pcall(function()
				MessagingService:PublishAsync(MESSAGING_PREFIX .. remoteSessionId, { LoadCount = remoteLoadCount })
			end)
		end

		return true
	end):andThen(function(resData)
		return resData.result
	end)
end

function StoreClass:WipeProfileAsync(key: string): any
	assert(typ(key) == "string" and #key > 0, "[N.2DATA] WipeProfileAsync: Invalid key")
	local isMockCall = self._mockNextCall
	self._mockNextCall = false
	local mockRef = isMockCall and self._userMockStore or self._mockStore
	local useMock = isMockCall or self.MockMode

	if activeProfiles[key] then
		activeProfiles[key]:EndSession()
	end

	return EnqueueRequest(key, function()
		if useMock then
			mockRef[key] = nil
			return true
		end
		if not self._dataStore then
			error("[N.2DATA] WipeProfileAsync: not initialized")
		end
		self._dataStore:RemoveAsync(key)
		return true
	end):andThen(function(resData)
		return resData.result
	end)
end

RunService.Heartbeat:Connect(function()
	UpdateCriticalState()

	local listLen = #autoSaveList
	if listLen == 0 or isShuttingDown then
		return
	end

	local speed = C.SAVE_INTERVAL / listLen
	local now = o_clock()

	while now - lastAutoSave > speed do
		lastAutoSave = lastAutoSave + speed
		local profile = autoSaveList[autoSaveIndex]

		if profile and (now - (profile._loadTimestamp or now)) < C.SAVE_INTERVAL / 2 then
			profile = nil
			for _ = 1, listLen - 1 do
				autoSaveIndex = autoSaveIndex + 1
				if autoSaveIndex > listLen then
					autoSaveIndex = 1
				end
				local c = autoSaveList[autoSaveIndex]
				if c and (now - (c._loadTimestamp or now)) >= C.SAVE_INTERVAL / 2 then
					profile = c
					break
				end
			end
		end

		autoSaveIndex = autoSaveIndex + 1
		if autoSaveIndex > listLen then
			autoSaveIndex = 1
		end

		if profile and profile:IsActive() and profile._pendingSaves == 0 then
			local shouldForcedPing = (now - (profile._lastSaveTime or now)) > (C.ASSUME_DEAD * 0.5)
			if profile._isDirty or shouldForcedPing then
				task.spawn(function()
					profile:Save():catch(function(_) end)
				end)
			end
		end
	end
end)

game:BindToClose(function()
	isShuttingDown = true
	local t0 = o_clock() + 5
	while activeLoadJobs > 0 and o_clock() < t0 do
		task.wait(0.05)
	end

	local pending = 0
	local t1 = o_clock() + C.SHUTDOWN_PHASE1
	local snapshot: { any } = {}
	for _, p in activeProfiles do
		if p:IsActive() then
			t_insert(snapshot, p)
		end
	end

	for i = 1, #snapshot do
		pending = pending + 1
		task.spawn(function()
			snapshot[i]:_ReleaseInternal("Shutdown"):catch(function(_) end):finally(function()
				pending = pending - 1
			end)
		end)
	end

	while (pending > 0 or activeSaveJobs > 0) and o_clock() < t1 do
		task.wait(0.05)
	end

	if activeSaveJobs > 0 then
		local t2 = o_clock() + C.SHUTDOWN_PHASE2
		while activeSaveJobs > 0 and o_clock() < t2 do
			task.wait(0.05)
		end
	end
end)

local NV2DATA_API = {
	OnError = OnError,
	OnOverwrite = OnOverwrite,
	OnCriticalToggle = OnCriticalToggle,
}

function NV2DATA_API.GetStore<T>(config: StoreConfig, template: T): Store<T>
	assert(typ(config) == "table", "[N.2DATA] GetStore: config must be a table")
	assert(
		typ(config.DataStoreName) == "string" and #config.DataStoreName > 0 and #config.DataStoreName <= 50,
		"[N.2DATA] GetStore: Invalid DataStoreName"
	)
	assert(typ(template) == "table", "[N.2DATA] GetStore: template must be a table")
	return StoreClass.new(config, template) :: any
end

function NV2DATA_API.SetConstant(name: string, value: number)
	assert(typ(name) == "string", "[N.2DATA] SetConstant: name must be a string")
	assert(typ(value) == "number", "[N.2DATA] SetConstant: value must be a number")
	assert(C[name] ~= nil, "[N.2DATA] SetConstant: invalid constant")
	C[name] = value
end

function NV2DATA_API.GetDebugState(): any
	local stateSnapshot = {
		ActiveProfiles = StripProxyAndCopy(activeProfiles),
		PendingLoadJobs = StripProxyAndCopy(pendingLoadJobs),
		ActiveLoadJobs = activeLoadJobs,
		ActiveSaveJobs = activeSaveJobs,
		AutoSaveList = StripProxyAndCopy(autoSaveList),
		Queues = StripProxyAndCopy(Queues),
		IssueQueue = StripProxyAndCopy(issueQueue),
		DataStoreState = DataStoreState,
	}
	return stateSnapshot
end

t_freeze(NV2DATA_API)

local NV2DATA = setmetatable({}, {
	__index = function(_, key): any
		if key == "DataStoreState" then
			return DataStoreState
		elseif key == "IsCriticalState" then
			return isCriticalState
		end
		return NV2DATA_API[key]
	end,
	__newindex = function(_, _, _)
		error("[N.2DATA] Module is read-only")
	end,
	__metatable = "Locked",
})

return (NV2DATA :: any) :: NV2DATAModule
