local S = require 'syscall'

local PATH = 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
local env = {PATH}

local function try(f, ...)
  local ok, err = f(...) -- could use pcall
  if ok then return ok end
  print("init: error at line " .. debug.getinfo(2, "l").currentline .. ": " .. tostring(err))
end

local function tableConcat(t1,t2)
  for i=1,#t2 do
    t1[#t1+1] = t2[i]
  end
  return t1
end

local function initCommand(cmd)
  local s = assert(S.socket("unix", "stream, nonblock"))
  local sa = assert(S.t.sockaddr_un('/run/initctl'))
  local ok, err = s:connect(sa)
  if not ok then error(err) end
  s:write(cmd..'\n')
  S.exit()
end

--TODO hook up pipes, merge all the stdout/stderrs to parent
local function exec(binary, args, e, wait)
  if wait == nil then
    wait = true
  end
  e = e or env
  local childPid = S.fork()
  if childPid < 0 then
    error('failed to fork and execute '..binary)
  elseif childPid > 0 then
    --parent
    if wait then
      local ok, err, status = S.waitpid(childPid)
      return status.EXITSTATUS == 0 or nil,
      err or status.EXITSTATUS ~= 0 and 'failed to run '..binary
    end
  else
    --child
    S.setsid()
    S.execve(binary, {binary, unpack(args)}, e)
    S.exit(1)
  end
end

local function fnfork(fn)
  e = e or env
  local childPid = S.fork()
  if childPid < 0 then
    error('failed to fork and execute '..binary)
  elseif childPid > 0 then
    --parent
    local ok, err, status = S.waitpid(childPid)
    return status.EXITSTATUS == 0 or nil,
    err or status.EXITSTATUS ~= 0 and 'failed to run function'
  else
    --child
    S.setsid()
    fn()
    S.exit(0)
  end
end

local function directory(path)
  return S.stat(path).isdir
end

local function mounted(path)
  if not directory(path) then return false end
  local a = S.stat(path)
  local b = S.stat(path .. '/..')
  return (a.dev ~= b.dev) or (a.ino == b.ino)
end

local function mount(fs_type, dir, device, opts, data)
  if mounted(dir) then return nil, dir..' is already mounted' end
  if not directory(dir) then
    S.mkdir(dir)
  end
  return S.mount(fs_type, dir, device, opts, data)
end

local function listProcesses()
  local fd = S.open('/proc')
  local gen = S.getdents(fd)
  S.close(fd)
  local list, dirent = {}, nil
  if gen then
    repeat
      dirent = gen()
      if dirent then
        if dirent.type == 4 and tonumber(dirent.name) then table.insert(list, tonumber(dirent.name)) end
      end
    until not dirent
  end
  print(#list)
  return list
end

local function waitUntil(condition, timeout, interval)
  if not timeout then timeout = 5 end
  if not interval then interval = 1 end
  local start = os.clock()
  while os.clock() - start < timeout do
    S.sleep(interval)
    if condition() then
      return true
    end
  end
  return false
end

return {
  try = try,
  initCommand = initCommand,
  mounted = mounted,
  mount = mount,
  listProcesses = listProcesses,
  waitUntil = waitUntil,
  directory = directory,
  fnFork = fnFork,
  exec = exec,
  tableConcat = tableConcat,
}
