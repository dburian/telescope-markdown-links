local async = require'plenary.async'
local Path = require'plenary.path'

local async_job = require "telescope._"
local conf = require'telescope.config'.values
local entry_display = require'telescope.pickers.entry_display'

local utils = require'telescope._extensions.markdown-links.utils'

local await_count = 1000

local flatten = vim.tbl_flatten

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
    local cwd, filename = utils.split_cwd_filename(path)
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

function BacklinksJob:close(force)
  self._ref_filter_job:close(force)
  self._ref_final_job:close(force)
  self._inline_job:close(force)
end


function BacklinksJob:_run()
  self._ref_filter_job = async_job.spawn(self._ref_filter_opts)
  self._inline_job = async_job.spawn(self._inline_opts)
  local ref_final_stdout = async_job.LinesPipe()

  -- Processing inline-style link matches
  local inline_match_factory = function (match)
    local match_cwd, _ = utils.split_cwd_filename(match.path)
    for label, target in string.gmatch(match.text, '%[([^]]+)%]%(([^)]+)%)') do
      if utils.is_same_file(self.opts.target_path, match_cwd, target) then
        match.label = label
        match.target = target
        break
      end
    end

    return match
  end
  local inline_match_iter = utils.get_rg_multiline_match_iter(
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
    return utils.is_same_file(self.opts.target_path, entry.cwd, entry.link)
  end, filtered_ref_matches)

  local matched_link_ids = {}
  for _, match in ipairs(filtered_ref_matches) do
    matched_link_ids[match.path] = match.link_id
  end


  if #filtered_ref_matches == 0 then
    self._process_complete()
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
        break
      end
    end

    return match
  end
  local ref_match_iter = utils.get_rg_multiline_match_iter(
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
end

--- Runs the job.
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
  local displayer = entry_display.create {
    separator = " ",
    items = {
      {},
      {},
    }
  }

  local make_display = opts.make_display or function (entry)
    return displayer {
      Path:new(entry.path):make_relative(opts.cwd),
      {'[' .. entry.value.label .. ']', "TelescopeResultsComment" },
    }
  end

  return function (match)
    local col = match.col - #match.label - 2
    local lnum = match.lnum
    if col <= 0 then
      lnum = lnum - 1
      col = string.find(match.text, '%[' .. match.label) - 1
    end

    return {
      value = match,
      display = make_display,
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

---  Finds all markdown files linking to `opts.target_path`
return function (opts)
  opts = opts or {}
  opts.entry_maker = opts.entry_maker or get_backlinks_entry_maker(opts)

  local target_cwd = vim.fn.fnamemodify(opts.target_path, ':h')

  local results = vim.F.if_nil(opts.results, {})
  local num_results = #results

  local search_dirs = {}
  for _, dir in ipairs(opts.search_dirs or {opts.cwd, target_cwd}) do
    table.insert(search_dirs, vim.fn.expand(dir))
  end
  opts.search_dirs = vim.fn.uniq(search_dirs)

  local job = BacklinksJob:new(opts)

  return setmetatable({
    close = function ()
      job:close()
    end,
  }, {
    __call = function (_, _, process_result, process_complete)
      -- Always publish all results we have so far.
      local curr_num_res = num_results
      for i = 1, curr_num_res do
        async.util.scheduler()
        process_result(results[i])
      end

      local _process_result = function (entry)
        num_results = num_results + 1
        results[num_results] = entry

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
  })
end
