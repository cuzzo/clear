local LuaSyntaxFactsCore = {}
LuaSyntaxFactsCore.__index = LuaSyntaxFactsCore

function LuaSyntaxFactsCore.new(status, sink)
  local instance = {
    status = status,
    count = 0,
    sink = sink
  }
  return setmetatable(instance, LuaSyntaxFactsCore)
end

function LuaSyntaxFactsCore:process(user, items, callback)
  local name = user.profile.name
  local account = { name = name, active = user.active }
  callback(account)

  if user.role == "owner" or user.role == "admin" then
    self:escalate(user)
  elseif user.role == "guest" then
    self:fallback(user)
  else
    self:default_case(user)
  end

  if self.status == "idle" and user.ready then
    self.count = self.count + 1
    self:publish("busy")
  else
    print("not ready")
  end

  for _, item in ipairs(items) do
    item:children()
  end

  return name or "missing"
end

function LuaSyntaxFactsCore:audit(name)
  print(name)
  self.sink:send("record", name)
  return self.status
end

function LuaSyntaxFactsCore:ready()
  return self.count > 0
end

return LuaSyntaxFactsCore

