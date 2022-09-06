local async_job = require "telescope._"
local async = require'plenary.async'
local make_entry= require 'telescope.make_entry'
local Path = require'plenary.path'

local await_count = 1000

local flatten = vim.tbl_flatten

local function get_backlinks_entry_maker(opts)
  return make_entry.gen_from_string()
end

local function is_same_file(reference_path, cwd, link)
  return vim.loop.fs_realpath(Path:new(cwd, link)) == reference_path
end

local function get_ref_rg_cmd(opts, target_path, search_dirs)
  local args = opts.vimgrep_arguments or {
    '--with-filename',
    '--no-heading',
    '--no-line-number',
  }
  local filename = vim.fn.fnamemodify(target_path, ':t')

  table.insert(args, {
    '-e',
    [=[\[[^]]+\]:[ \t]*[-_\./A-z0-9]*]=] .. string.gsub(filename, '%.', [[\.]]),
    '-o',
    '--',
    search_dirs
  })

  return {
    command = 'rg',
    args = flatten(args)
  }
end

local function get_ref_entry_maker(target_path)
  local filename = vim.fn.fnamemodify(target_path, ':t')
  filename = string.gsub(filename, '%.', '%%.')

  return function (line)
    local sep_ind = string.find(line, ':')

    if sep_ind == nil then
      return {}
    end

    local link_id, link = string.match(line, '%[([^]]*)%]%s*:%s*([-_%./%a%d]*' .. filename .. ')')

    local path = string.sub(line, 1, sep_ind - 1)
    return {
      filename = vim.fn.fnamemodify(path, ':t'),
      cwd = vim.fn.fnamemodify(path, ':h'),
      link_id = link_id,
      link = link,
    }
  end
end

---  Finds all markdown files linking to `opts.target_file`
--  Searches down to `opts.max_depth` for reference and inline links.
return function (opts)
  opts = opts or {}

  local cwd = opts.cwd or vim.fn.getcwd()
  local env = opts.env
  local target_path = opts.target_path or vim.api.nvim_buf_get_name(0)

  local entry_maker = opts.entry_maker or get_backlinks_entry_maker(opts)
  local ref_entry_maker = get_ref_entry_maker(target_path)

  local results = vim.F.if_nil(opts.results, {})
  local num_results = #results

  local ref_filter_job
  local ref_filter_stdout = nil

  local ref_final_job
  local ref_final_stdout = nil

  local inline_job
  local inline_stdout = nil

  local job_started = false
  local job_completed = false

  -- Directories to explore with `opts.max_depth`
  local search_dirs = {}
  for _, dir in ipairs(opts.search_dirs or {cwd, vim.fn.fnamemodify(target_path, ':h')}) do
    table.insert(search_dirs, vim.fn.expand(dir))
  end


  return setmetatable({
    close = function ()
      if ref_filter_job then
        ref_filter_job:close()
      end
    end,
    results = results,
  }, {
    __call = function (_, _, process_result, process_complete)
      if not job_started then

        -- for each directory, create rg commmands for both inline and
        -- reference style links
        local job_opts = get_ref_rg_cmd(opts, target_path, search_dirs)

        ref_filter_stdout = async_job.LinesPipe()
        ref_filter_job = async_job.spawn {
          command = job_opts.command,
          args = job_opts.args,
          cwd = cwd,
          env = env,

          stdout = ref_filter_stdout,
        }

        -- TODO: Spawn rg for inline links

        job_started = true
      end

      if not job_completed then
        if not vim.tbl_isempty(results) then
          for _, v in ipairs(results) do
            process_result(v)
          end
        end

        local ref_entries = {}
        for line in ref_filter_stdout:iter(false) do
          async.util.scheduler()
          table.insert(ref_entries, ref_entry_maker(line))

        end

        ref_entries = vim.tbl_filter(function (entry)
          return is_same_file(target_path, entry.cwd, entry.link)
        end, ref_entries)

        process_complete()
        job_completed = true
        return
      end

      local current_count = num_results
      for index = 1, current_count do
        -- TODO: Figure out scheduling...
        if index % await_count then
          async.util.scheduler()
        end

        if process_result(results[index]) then
          break
        end
      end

      if job_completed then
        process_complete()
      end
    end,
  })
end
