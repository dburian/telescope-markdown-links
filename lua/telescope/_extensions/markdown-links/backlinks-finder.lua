local async_job = require "telescope._"
local async = require'plenary.async'
local Path = require'plenary.path'
local conf = require'telescope.config'.values

local await_count = 1000

local flatten = vim.tbl_flatten

local function is_same_file(reference_path, cwd, link)
  return vim.loop.fs_realpath(Path:new(cwd, link):absolute()) == reference_path
end

local function get_rg_multiline_iter(linepipe)
  local next_line = linepipe:iter(false)

  return function ()
    local entry = {
      text = '',
    }

    local line = next_line()
    if line == nil then
      return nil
    end

    while line ~= nil and line ~= '--' do
      local context_sep_start, context_sep_end = string.find(line, '-%d+-')
      if context_sep_start ~= nil then
        entry.path = string.sub(line, 1, context_sep_start - 1)
        entry.text = entry.text .. string.sub(line, context_sep_end + 1, -1)
      else
        local _, lnum, column, text = string.match(line,
          '^([^:]+):([0-9]+):([0-9]+):(.*)$'
        )
        if lnum ~= nil and column ~= nil and text ~= nil then
          entry.lnum = lnum
          entry.col = column
          entry.text = entry.text .. text
        end
      end

      line = next_line()
    end

    return entry
  end
end

local function ref_entry_maker_from_multiline(entry)
  -- TODO: Check if the matched link is really the one we're searching for.
  local link_label, link_id = string.match(entry.text, '%[([^]]+)%]%[([^]]+)%]')
  P(entry.text)
  -- TODO: Globalize displayer

  return {
    value = entry,
    display = link_label,
    ordinal = link_label .. entry.path,
    lnum = tonumber(entry.lnum),
    -- TODO: Make this more clear.
    col = tonumber(entry.col) - #link_label - 1,
    path = entry.path
  }
end

local function get_ref_rg_cmd(opts, target_path, search_dirs)
  local args = {
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
    search_dirs,
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
  local target_cwd = vim.fn.fnamemodify(target_path, ':h')
  -- TODO: Add option for entry maker

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
  for _, dir in ipairs(opts.search_dirs or {cwd, target_cwd}) do
    table.insert(search_dirs, vim.fn.expand(dir))
  end
  search_dirs = vim.fn.uniq(search_dirs)


  return setmetatable({
    close = function ()
      if ref_filter_job then
        ref_filter_job:close()
      end
      if ref_final_job then
        ref_final_job:close()
      end
      -- TODO: Close all jobs
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

        -- TODO: Think about better code flow in __call.

        local ref_entries = {}
        for line in ref_filter_stdout:iter(false) do
          async.util.scheduler()
          table.insert(ref_entries, ref_entry_maker(line))
        end

        ref_entries = vim.tbl_filter(function (entry)
          return is_same_file(target_path, entry.cwd, entry.link)
        end, ref_entries)

        local ref_final_cmds = vim.tbl_map(function (entry)
          return {
            conf.vimgrep_arguments,
            '-B', 1,
            '-e', [=[\]\[]=] .. entry.link_id .. [=[\]]=],
            '--',
            Path.new(entry.cwd, entry.filename):absolute(),
            ';'
          }
        end, ref_entries)

        ref_final_cmds = flatten(ref_final_cmds)
        P(ref_final_cmds)

        async.util.scheduler()
        ref_final_stdout = async_job.LinesPipe()
        ref_final_job = async_job.spawn{
          command = table.remove(ref_final_cmds, 1),
          args = ref_final_cmds,
          cwd = cwd,
          env = env,

          stdout = ref_final_stdout
        }

        local ref_match_iter = get_rg_multiline_iter(ref_final_stdout)
        local result_nr = #results
        for match in ref_match_iter do
          async.util.scheduler()
          local entry = ref_entry_maker_from_multiline(match)

          async.util.scheduler()
          result_nr = result_nr + 1
          results[result_nr] = entry
          process_result(entry)
        end


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
