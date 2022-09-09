local async_job = require "telescope._"
local async = require'plenary.async'
local Path = require'plenary.path'
local conf = require'telescope.config'.values

local await_count = 1000

local flatten = vim.tbl_flatten

local function is_same_file(reference_path, cwd, link)
  local other_path
  if vim.startswith(link, Path.path.sep) then
    other_path = link
  else
    -- TODO: Maybe i do not need the fs_realpath
    other_path = Path:new(cwd, link):absolute()
  end

  return vim.loop.fs_realpath(other_path) == reference_path
end

--- Is not that robust as `fnamemodify`, but can be called without
-- `vim.schedule_wrap`.
local function split_cwd_filename(path)
  local path_split_patt = string.format('^(.+)%s([^%s]+)$', Path.path.sep, Path.path.sep)
  return string.match(path, path_split_patt)
end

local function get_rg_multiline_match_iter(linespipe, match_factory)
  local next_line = linespipe:iter(false)

  return function ()
    local match = {
      text = '',
    }

    local line = next_line()
    if line == nil then
      return nil
    end

    while line ~= nil and line ~= '--' do
      local context_sep_start, context_sep_end = string.find(line, '-%d+-')
      if context_sep_start ~= nil then
        match.path = string.sub(line, 1, context_sep_start - 1)
        match.text = match.text .. string.sub(line, context_sep_end + 1, -1)
      else
        local _, lnum, column, text = string.match(line,
          '^([^:]+):([0-9]+):([0-9]+):(.*)$'
        )
        if lnum ~= nil and column ~= nil and text ~= nil then
          match.lnum = tonumber(lnum)
          match.col = tonumber(column)
          match.text = match.text .. text
        end
      end

      line = next_line()
    end

    if match_factory and type(match_factory) == 'function' then
      return match_factory(match)
    end

    return match
  end
end

local BacklinksJob = {}
BacklinksJob.__index = BacklinksJob

function BacklinksJob:new(opts)
  local target_fname = vim.fn.fnamemodify(opts.target_path, ':t')

  local target_fname_regexp_sanitized = string.gsub(target_fname, '%.', [[\.]])
  local target_path_regexp = [=[[-_\./A-z0-9]*]=] .. target_fname_regexp_sanitized
  local ref_filter_cmd = flatten{
    'rg',
    '--with-filename',
    '--color=never',
    '--no-heading',
    '--no-line-number',
    '-e',
    [=[\[[^]]+\]:[ \t]*]=] .. target_path_regexp,
    '-o',
    '--',
    opts.search_dirs,
  }

  local inline_cmd = flatten{
    conf.vimgrep_arguments,
    '-B', 1,
    '-e', [[\]\(]] .. target_path_regexp .. [[\)]],
    '--',
    opts.search_dirs
  }

  local create_cmd_opts = function (cmd)
    return {
      -- no cwd: it causes AsyncJob init to call vimL function, which is unsafe
      -- without `vim.scheduler`
      command = table.remove(cmd, 1),
      args = cmd,
      env = opts.env,
      stdout = async_job.LinesPipe()
    }
  end

  local target_fname_patt_sanitized = string.gsub(target_fname, '%.', '%%.')
  local ref_link_patt = '%[([^]]*)%]%s*:%s*([-_%./%a%d]*' .. target_fname_patt_sanitized .. ')'
  local ref_entry_maker = function (line)
    local sep_ind = string.find(line, ':')

    if sep_ind == nil then
      return {}
    end

    local link_id, link = string.match(line, ref_link_patt)

    local path = string.sub(line, 1, sep_ind - 1)
    local cwd, filename = split_cwd_filename(path)
    return {
      path = path,
      filename = filename,
      cwd = cwd,
      link_id = link_id,
      link = link,
    }
  end

  return setmetatable({
    opts = opts,
    _is_running = false,
    _is_completed = false,
    _has_started = false,
    _ref_filter_opts = create_cmd_opts(ref_filter_cmd),
    _ref_entry_maker = ref_entry_maker,
    _inline_opts = create_cmd_opts(inline_cmd),
    _ref_filter_job = false,
    _ref_final_job = false,
    _inline_job = false,
  }, self)
end

function BacklinksJob:is_running()
  return self._is_running
end

function BacklinksJob:has_started()
  return self._has_started
end

function BacklinksJob:is_completed()
  return self._is_completed
end


-- Asynchronously runs the job, calling back when the job is done.
function BacklinksJob:_run_async()
  self._ref_filter_job = async_job.spawn(self._ref_filter_opts)
  self._inline_job = async_job.spawn(self._inline_opts)
  local ref_final_stdout = async_job.LinesPipe()

  -- Processing inline-style link matches
  local inline_match_factory = function (match)
    local match_cwd, _ = split_cwd_filename(match.path)
    for label, target in string.gmatch(match.text, '%[([^]]+)%]%(([^)]+)%)') do
      if is_same_file(self.opts.target_path, match_cwd, target) then
        match.label = label
        match.target = target
        break
      end
    end

    return match
  end
  local inline_match_iter = get_rg_multiline_match_iter(
    self._inline_opts.stdout,
    inline_match_factory
  )
  for match in inline_match_iter do
    if match.label ~= nil then
      local entry = self.opts.entry_maker(match)
      self._process_result(entry)
    end
  end

  -- Processing reference-style link matches
  local filtered_ref_matches = {}
  for line in self._ref_filter_opts.stdout:iter(false) do
    table.insert(filtered_ref_matches, self._ref_entry_maker(line))
  end

  filtered_ref_matches = vim.tbl_filter(function (entry)
    return is_same_file(self.opts.target_path, entry.cwd, entry.link)
  end, filtered_ref_matches)

  local matched_link_ids = {}
  for _, match in ipairs(filtered_ref_matches) do
    matched_link_ids[match.path] = match.link_id
  end


  if #filtered_ref_matches == 0 then
    self._process_complete()
    -- return callback()
    return
  end

  local ref_final_cmds = vim.tbl_map(function (entry)
    return {
      conf.vimgrep_arguments,
      '-B', 1,
      '-e', [=[\]\[]=] .. entry.link_id .. [=[\]]=],
      '--',
      entry.path,
      ';'
    }
  end, filtered_ref_matches)
  ref_final_cmds = flatten(ref_final_cmds)

  self._ref_final_job = async_job.spawn{
    command = table.remove(ref_final_cmds, 1),
    args = ref_final_cmds,
    env = self.opts.env,
    stdout = ref_final_stdout
  }

  local ref_match_factory = function (match)
    for label, link_id in string.gmatch(match.text, '%[([^]]+)%]%[([^]]+)%]') do
      if matched_link_ids[match.path] == link_id then
        match.label = label
        match.link_id = link_id
        P({match = match, link_id = link_id, map = matched_link_ids})
        break
      end
    end

    return match
  end
  local ref_match_iter = get_rg_multiline_match_iter(
    ref_final_stdout,
    ref_match_factory
  )
  for match in ref_match_iter do
    if match.label ~= nil then
      local entry = self.opts.entry_maker(match)
      self._process_result(entry)
    end
  end

  self._process_complete()
  -- callback()
end

BacklinksJob._run = BacklinksJob._run_async

--- Runs the job with blocking call.
function BacklinksJob:run()
  self._is_running = true
  self._has_started = true

  local result = self:_run()

  self._is_running = false
  self._is_completed = true

  return result
end

function BacklinksJob:refresh(new_process_result, new_process_complete)
  self._process_result = new_process_result
  self._process_complete = new_process_complete
end



local function get_backlinks_entry_maker(opts)
  return function (match)
    local col = match.col - #match.label - 2
    local lnum = match.lnum
    if col <= 0 then
      lnum = lnum - 1
      col = string.find(match.text, '%[' .. match.label) - 1
    end

    return {
      value = match,
      -- TODO: Displayer
      display = Path:new(match.path):shorten() .. ': ' .. match.label,
      ordinal = table.concat({
        match.path,
        match.lnum,
        match.col,
        match.label,
      }, ':'),
      lnum = lnum,
      col = col,
      path = match.path
    }
  end
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

local function get_inline_rg_cmd(opts, target_path, search_dirs)
  local filename = vim.fn.fnamemodify(target_path, ':t')

  local args = {
    conf.vimgrep_arguments,
    '-B', 1,
    -- TODO: Extract regex for all paths.
    '-e', [[\]\([-_\./A-z0-9]*]] .. string.gsub(filename, '%.', [[\.]]) .. [[\)]],
    '--',
    search_dirs
  }

  return {
    command = 'rg',
    args = flatten(args)
  }
end

local function get_ref_entry_maker(target_path)
  local target_filename = vim.fn.fnamemodify(target_path, ':t')
  target_filename = string.gsub(target_filename, '%.', '%%.')
  local link_patt = '%[([^]]*)%]%s*:%s*([-_%./%a%d]*' .. target_filename .. ')'

  return function (line)
    local sep_ind = string.find(line, ':')

    if sep_ind == nil then
      return {}
    end

    local link_id, link = string.match(line, link_patt)

    local path = string.sub(line, 1, sep_ind - 1)
    local cwd, filename = split_cwd_filename(path)
    return {
      path = path,
      filename = filename,
      cwd = cwd,
      link_id = link_id,
      link = link,
    }
  end
end

---  Finds all markdown files linking to `opts.target_file`
--  Searches down to `opts.max_depth` for reference and inline links.
return function (opts)
  opts = opts or {}

  -- TODO: Move some of the default opts to picker
  local cwd = opts.cwd
  local env = opts.env
  local target_path = opts.target_path

  local target_cwd = vim.fn.fnamemodify(target_path, ':h')
  opts.entry_maker = opts.entry_maker or get_backlinks_entry_maker(opts)
  local entry_maker = opts.entry_maker

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
  opts.search_dirs = vim.fn.uniq(search_dirs)

  local job = BacklinksJob:new(opts)

  return setmetatable({
    close = function ()
      if ref_filter_job then
        ref_filter_job:close()
      end
      if ref_final_job then
        ref_final_job:close()
      end
      if inline_job then
        inline_job:close()
      end
      -- TODO: Think about what happens here..
    end,
    results = results,
  }, {
    __call = function (_, prompt, process_result, process_complete)
      -- Always publish all results we have so far.
      local curr_num_res = num_results
      for i = 1, curr_num_res do
        async.util.scheduler()
        process_result(results[i])
      end
      -- P({prompt = prompt, had_results = #results, num_results = num_results})

      local _process_result = function (entry)
        num_results = num_results + 1
        results[num_results] = entry
        -- P({new_entry = entry})

        if num_results % await_count == 0 then
          async.util.scheduler()
        end

        async.util.scheduler()
        process_result(results[num_results])
      end

      if not job:has_started() then
        job:refresh(_process_result, process_complete)
        job:run()
      elseif job:is_running() then
        -- We need to refresh `process_result` and `process_complete`, which are
        -- unique to each finder's call.
        job:refresh(_process_result, process_complete)
      elseif job:is_completed() then
        -- All results have already been published.
        process_complete()
      end
    end,
    old_call = function (_, _, process_result, process_complete)
      if not job_started then

        -- for each directory, create rg commmands for both inline and
        -- reference style links
        local ref_job_opts = get_ref_rg_cmd(opts, target_path, search_dirs)

        ref_filter_stdout = async_job.LinesPipe()
        ref_filter_job = async_job.spawn {
          command = ref_job_opts.command,
          args = ref_job_opts.args,
          cwd = cwd,
          env = env,

          stdout = ref_filter_stdout,
        }

        local inline_job_opts = get_inline_rg_cmd(opts, target_path, search_dirs)
        inline_stdout = async_job.LinesPipe()
        inline_job = async_job.spawn {
          command = inline_job_opts.command,
          args = inline_job_opts.args,
          cwd = cwd,
          env = env,

          stdout = inline_stdout
        }


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
            entry.path,
            ';'
          }
        end, ref_entries)

        ref_final_cmds = flatten(ref_final_cmds)

        async.util.scheduler()
        ref_final_stdout = async_job.LinesPipe()
        ref_final_job = async_job.spawn{
          command = table.remove(ref_final_cmds, 1),
          args = ref_final_cmds,
          cwd = cwd,
          env = env,

          stdout = ref_final_stdout
        }

        local ref_match_iter = get_rg_multiline_match_iter(ref_final_stdout, function (match)
          -- TODO: Check if the matched link is really the one we're searching for.
          match.label, match.link_id = string.match(match.text, '%[([^]]+)%]%[([^]]+)%]')
          return match
        end)
        for match in ref_match_iter do
          async.util.scheduler()
          local entry = entry_maker(match)

          num_results = num_results + 1
          results[num_results] = entry
          process_result(entry)
        end

        local inline_match_iter = get_rg_multiline_match_iter(inline_stdout, function (match)
          -- TODO: Check if the matched link is really the one we're searching for.
          -- TODO: In the long run, look into rg json output
          match.label, _ = string.match(match.text, '%[([^]]+)%]%(([^)]+)%)')

          return match
        end)
        for match in inline_match_iter do
          async.util.scheduler()
          local entry = entry_maker(match)

          local entry_cwd = vim.fn.fnamemodify(entry.path, ':h')
          if is_same_file(target_path, entry_cwd, entry.value.target) then
            num_results = num_results + 1
            results[num_results] = entry
            process_result(entry)
          end
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
