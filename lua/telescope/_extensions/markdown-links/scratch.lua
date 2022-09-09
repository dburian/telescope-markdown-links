local async_job = require'telescope._'
local async = require'plenary.async'

local obj = {
  key = 'value',
}
function obj:callback_f(callback)
  P('f called with self:' .. vim.inspect(self))
  local timer = vim.loop.new_timer()
  timer:start(1000, 0, function()
    P('callback called')
    callback('This is the result')
  end)
end

obj.blocking_f = async.wrap(obj.callback_f, 2)

local test = async.void(function ()
  P('void called')
  local result = obj:blocking_f()
  P('blocking returned result: ' .. result)
end)

P('starting main')
test()
P('ending main')
