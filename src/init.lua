#!/usr/bin/luajit

-- basic init process
-- note we do not catch all errors as we cannot do much about them

-- note that stdin, stderr should be attached to /dev/console

package.path = '/lib/lua/?.lua;/lib/lua/?/init.lua;;'
package.cpath = '/lib/?.so;/lib/?/init.so;;'

local S = require 'syscall'

local util = require 'init.util'
local constants = require 'init.constants'

--First, check if pid is init or a call to init with a command
local pid = S.getpid()
if pid ~= 1 then
  local commands = {
    poweroff = true,
    restart = true,
    halt = true,
    status = true,
    test = true,
  }
  local command = arg[1]
  return commands[command] and util.initCommand(command) or S.exit(1)
end

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

  --udev
  print('running udev')
  util.try(util.exec, '/sbin/udevd', {'init'})
  util.try(util.exec, '/sbin/udevadm', {'trigger', '--action=add', '--type=subsystems'})
  util.try(util.exec, '/sbin/udevadm', {'trigger', '--action=add', '--type=devices'})
  util.try(util.exec, '/sbin/udevadm', {'settle'})

  -- interfaces
  print('setting up network')
  local i = S.nl.interfaces()
  local lo, eth0 = i.lo, i.eth0
  lo:up()
  eth0:up()
  --TODO dhcp
  --eth0:address('10.3.0.2/24')

  -- hostname
  --S.sethostname('lua')

  --file systems
  local except = 'no'..table.concat(constants.NETFS, ',no')
  util.try(util.exec, '/bin/mount', {'-a', '-t', except, '-O', 'no_netdev'})

  --TODO implement handling of /tmp
  --
  -- run services
  print('starting docker')
  util.exec('/usr/bin/docker', {'--host=tcp://0.0.0.0:2375', '-d'}, nil, false)
end

S.unlink('/run/nologin')
S.unlink('/run/initctl')

init()

local function shutdown()
  local function killAll()
    S.kill(-1, 'TERM')
    if util.waitUntil(function() return #util.listProcesses() == 2 end, 5) then
      return true
    end

    S.kill(-1, 'KILL')
    if util.waitUntil(function() return #util.listProcesses() == 2 end, 15) then
      return true
    else
      return nil, 'failed to kill all processes'
    end
  end

  util.try(util.exec, '/sbin/udevadm', {'control', '--exit'})
  killAll()
  local except = 'no'..table.concat(util.tableConcat(constants.NETFS, constants.VIRTFS), ',no')
  util.try(util.exec, '/bin/umount', {'-a', '-t', except, '-O', 'no_netdev'})

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

local coroutines = {}
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

--listen for socket commands, pass in shared commands
local c = require 'init.server'.create(commands)
table.insert(coroutines, c)

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
