local S = require 'syscall'

local t, c = S.t, S.c
local function nilf() return nil end
local function assert(cond, s, ...)
  if cond == nil then error(tostring(s)) end -- annoyingly, assert does not call tostring!
  return cond, s, ...
end

local maxevents = 1024

local poll = {
  init = function(this)
    return setmetatable({fd = assert(S.epoll_create())}, {__index = this})
  end,
  event = t.epoll_event(),
  add = function(this, s)
    local event = this.event
    event.events = c.EPOLL.IN
    event.data.fd = s:getfd()
    assert(this.fd:epoll_ctl("add", s, event))
  end,
  events = t.epoll_events(maxevents),
  get = function(this)
    local f, a, r = this.fd:epoll_wait(this.events, 10)
    if not f then
      print("error on fd", a)
      return nilf
    else
      return f, a, r
    end
  end,
  eof = function(ev) return ev.HUP or ev.ERR or ev.RDHUP end,
}

local function create(commands)
  print('listening for commands')

  local server = assert(S.socket("unix", "stream, nonblock"))
  server:setsockopt("socket", "reuseaddr", true)
  local sa = assert(t.sockaddr_un('/run/initctl'))
  assert(server:bind(sa))
  assert(server:listen(128))

  local ep = poll:init()

  ep:add(server)

  local w = {}

  local function serve()
    while true do
      for i, ev in ep:get() do
        if ep.eof(ev) then
          S.close(ev.fd)
          w[ev.fd] = nil
        elseif ev.fd == server:getfd() then -- server socket, accept
          repeat
            local a, err = server:accept(ss, nil, 'nonblock')
            if a then
              ep:add(a)
              w[a:getfd()] = a
            end
          until not a
        else
          local fd = w[ev.fd]
          if not fd then
            print(tostring(ev.fd)..' has already been closed')
          else
            local cmd = fd:read()
            cmd = cmd:sub(1, #cmd-1)
            if commands[cmd] then
              commands[cmd]()
            else
              print('Invalid command: '..cmd)
            end
          end
        end
      end

      coroutine.yield(true)
    end
  end
  return coroutine.create(function()
    local ok, err = xpcall(serve, function(msg)
      print(msg)
      print(debug.traceback())
    end)
  end)
end

return {
  create = create
}
