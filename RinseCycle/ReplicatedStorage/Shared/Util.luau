-- Small helpers shared by server and client.

local Util = {}

----------------------------------------------------------------------------------------------------
-- Signal: a tiny event object (no BindableEvent, so tables pass through untouched).
--   local s = Util.Signal.new(); local c = s:Connect(fn); s:Fire(...); c:Disconnect()
-- Handlers run in their own thread (task.spawn), so a yielding handler never blocks Fire.
----------------------------------------------------------------------------------------------------
export type Connection = { Connected: boolean, Disconnect: (self: Connection) -> () }
export type Signal = {
	Connect: (self: Signal, fn: (...any) -> ()) -> Connection,
	Once: (self: Signal, fn: (...any) -> ()) -> Connection,
	Fire: (self: Signal, ...any) -> (),
	Wait: (self: Signal) -> ...any,
	DisconnectAll: (self: Signal) -> (),
}

local Signal = {}
Signal.__index = Signal

function Signal.new(): Signal
	return (setmetatable({ _handlers = {} }, Signal) :: any) :: Signal
end

function Signal:Connect(fn)
	local handlers = self._handlers
	local connection
	connection = {
		Connected = true,
		Disconnect = function(c)
			if not c.Connected then
				return
			end
			c.Connected = false
			local i = table.find(handlers, connection)
			if i then
				table.remove(handlers, i)
			end
		end,
		_fn = fn,
	}
	table.insert(handlers, connection)
	return connection
end

function Signal:Once(fn)
	local connection
	connection = self:Connect(function(...)
		connection:Disconnect()
		fn(...)
	end)
	return connection
end

function Signal:Fire(...)
	-- Copy first so handlers can disconnect themselves while we iterate.
	for _, c in table.clone(self._handlers) do
		if c.Connected then
			task.spawn(c._fn, ...)
		end
	end
end

function Signal:Wait()
	local thread = coroutine.running()
	self:Once(function(...)
		task.spawn(thread, ...)
	end)
	return coroutine.yield()
end

function Signal:DisconnectAll()
	for _, c in table.clone(self._handlers) do
		c:Disconnect()
	end
end

Util.Signal = Signal

----------------------------------------------------------------------------------------------------
-- Tables and randomness
----------------------------------------------------------------------------------------------------

function Util.DeepCopy<T>(value: T): T
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for k, v in value :: any do
		copy[Util.DeepCopy(k)] = Util.DeepCopy(v)
	end
	return copy :: any
end

-- Fills missing keys in `target` from `template` (recursively). Used to migrate old save data.
function Util.Reconcile(target: { [any]: any }, template: { [any]: any })
	for k, v in template do
		if target[k] == nil then
			target[k] = Util.DeepCopy(v)
		elseif type(v) == "table" and type(target[k]) == "table" then
			Util.Reconcile(target[k], v)
		end
	end
	return target
end

-- Picks one entry from a list of { ..., [weightKey] = number }. rng is an optional Random.
function Util.WeightedPick<T>(entries: { T }, weightKey: string, rng: Random?): T
	local total = 0
	for _, e in entries do
		total += (e :: any)[weightKey]
	end
	local roll = (if rng then rng:NextNumber() else math.random()) * total
	for _, e in entries do
		roll -= (e :: any)[weightKey]
		if roll <= 0 then
			return e
		end
	end
	return entries[#entries]
end

function Util.Shuffle<T>(list: { T }, rng: Random?): { T }
	for i = #list, 2, -1 do
		local j = if rng then rng:NextInteger(1, i) else math.random(1, i)
		list[i], list[j] = list[j], list[i]
	end
	return list
end

-- Server time that is identical on every client (use for countdowns).
function Util.Now(): number
	return workspace:GetServerTimeNow()
end

-- True if the value is a finite Vector3 (no NaN / inf). Use on anything a client sends.
function Util.IsFiniteVector3(v: any): boolean
	if typeof(v) ~= "Vector3" then
		return false
	end
	for _, n in { v.X, v.Y, v.Z } do
		if n ~= n or n == math.huge or n == -math.huge then
			return false
		end
	end
	return true
end

return Util
