local Path = require'plenary.path'

local M = {}

function M.is_same_file(reference_path, cwd, link)
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
function M.split_cwd_filename(path)
  local path_split_patt = string.format('^(.+)%s([^%s]+)$', Path.path.sep, Path.path.sep)
  return string.match(path, path_split_patt)
end

function M.get_rg_multiline_match_iter(linespipe, match_factory)
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

function M.is_markdown()
  return vim.bo.filetype == 'markdown'
end

function M.setup_debug()
  -- Purely for my convenience.

  vim.keymap.set('n', '<leader>l', require'telescope._extensions.markdown-links'.find_links)
  vim.keymap.set('n', '<leader>b', require'telescope._extensions.markdown-links'.find_backlinks)
  vim.keymap.set('n', '<leader><leader>r', function ()
    package.loaded['telescope._extensions.markdown-links'] = nil
    package.loaded['telescope._extensions.markdown-links.backlinks-finder'] = nil
    package.loaded['telescope._extensions.markdown-links.utils'] = nil
    vim.cmd[[:wa]]
    require'telescope._extensions.markdown-links'
    require'telescope._extensions.markdown-links.backlinks-finder'
    require'telescope._extensions.markdown-links.utils'
    print('RELODED')
  end)
end

return M
