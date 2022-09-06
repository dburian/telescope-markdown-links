local async_job = require'telescope._'
local async = require'plenary.async'

local test = async.void(function ()
  P('start')
  local cwd = '/home/dburian/Documents/wiki'

  local stdout = async_job.LinesPipe()
  local job_opts = {
    command = 'rg',
    args = {
      '--no-heading',
      '--smart-case',
      '--with-filename',
      -- '-e', 'k',
      '-e', [=[\[[^]]+\]: *[-_\./A-z0-9]+\.md]=],
      '--max-depth', 2,
      '--', '.',
    },
  }

  local job = async_job.spawn{
    command = job_opts.command,
    args = job_opts.args,
    cwd = cwd,
    stdout = stdout,
  }


  for line in stdout:iter(false) do
    P(line)
  end

  P('Done')
end)

P('before test')
test()
P('after test')
