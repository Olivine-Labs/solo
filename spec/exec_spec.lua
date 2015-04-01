local util = require 'init.util'
describe('tests for fork and exec', function()
  it('can fork and has stdout', function()
    error({util.exec('/bin/mount', {'-a'})})
  end)
end)
