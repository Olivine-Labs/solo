#!/usr/bin/luajit

-- basic init process
-- note we do not catch all errors as we cannot do much about them

-- note that stdin, stderr should be attached to /dev/console

package.path = '/lib/lua/?.lua;/lib/lua/?/init.lua;;'
package.cpath = '/lib/?.so;/lib/?/init.so;;'

local S = require 'syscall'

local util = require 'init.util'
local constants = require 'init.constants'

local coroutines = {}

if S.stat('/run/initctl') then
  util.initCommand(table.concat(arg, ' '))
  --should never get here
  return S.exit(1)
end

local initialProcesses = 1
local function shutdown()
  local function killAll()
    S.kill(-1, 'TERM')
    if util.waitUntil(function() return #util.listProcesses() - 1 <= initialProcesses end, 5) then
      return true
    end

    S.kill(-1, 'KILL')
    if util.waitUntil(function() return #util.listProcesses() - 1 <= initialProcesses end, 15) then
      return true
    else
      return nil, 'failed to kill all processes'
    end
  end

  killAll()
  util.try(util.exec, '/bin/umount', {'-a', '-r'})

  S.sync()
end

local commands = {
  shutdown = function()
    shutdown()
    S.reboot('POWER_OFF')
  end,
  restart = function()
    shutdown()
    S.reboot('RESTART')
  end,
  halt = function()
    shutdown()
    S.reboot('HALT')
  end,
}

--Initialize the system
local function init()
  -- system mounts
  print('mounting filesystems')
  util.try(util.mount, 'sysfs', '/sys', 'sysfs', 'rw,nosuid,nodev,noexec,relatime')
  util.try(util.mount, 'proc', '/proc', 'proc', 'rw,nosuid,nodev,noexec,relatime')
  util.try(util.mount, 'tmpfs', '/run', 'run', 'nosuid,nodev', 'mode=0755')
  util.try(util.mount, 'devtmpfs', '/dev', 'dev', 'nosuid', 'mode=0755')
  util.try(util.mount, 'devpts', '/dev/pts', 'devpts', 'rw,nosuid,noexec,relatime', 'mode=0620')
  util.try(util.mount, 'tmpfs', '/dev/shm', 'shm', 'nosuid,nodev', 'mode=1777')

  initialProcesses = #util.listProcesses()

  --udev
  print('running mdev')
  util.try(util.exec, '/sbin/mdev', {'-s'})

  S.unlink('/run/nologin')
  S.unlink('/run/initctl')

  --listen for socket commands, pass in shared commands
  local c = require 'init.server'.create(commands)
  table.insert(coroutines, c)

  --reap zombies
  local c = coroutine.create(function()
    while true do
      local w, err = S.waitpid(-1, 'NOHANG')
      if not w and err.CHILD then -- no more children
        return false
      end
      coroutine.yield(true, w, err)
    end
  end)
  table.insert(coroutines, c)

  --file systems except network
  local except = 'no'..table.concat(constants.NETFS, ',no')
  util.try(util.exec, '/bin/mount', {'-a', '-t', except, '-O', 'no_netdev'})

  -- interfaces
  print('setting up network')
  local i = S.nl.interfaces()
  for k, v in pairs(i) do
    v:up()
  end

  -- docker
  print('starting docker')
  util.exec('/usr/bin/docker', {'--host=tcp://0.0.0.0:2375', '-d'}, nil, false)
  --TODO wait for docker to be up and listening, then start dhcp container

  --after dhcp, fire up network file systems
  util.try(util.exec, '/bin/mount', {'-a'})
end

init()

--event loop
while true do
  for _, v in pairs(coroutines) do
    local ok, res, err = coroutine.resume(v)
    if not ok or (ok and not res) then
      print('coroutine signaled for init exit')
      return S.exit()
    end
  end
end
