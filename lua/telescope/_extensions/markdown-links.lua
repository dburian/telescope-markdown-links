
local Path = require'plenary.path'

local pickers = require'telescope.pickers'
local finders = require'telescope.finders'
local conf = require'telescope.config'.values
local entry_display = require'telescope.pickers.entry_display'

local backlinks_finder = require'telescope._extensions.markdown-links.backlinks-finder'

local file_patt = '[-%a%d/%._]+%.md'
local label_patt = '[^]]*'
local inline_link_patt = "%[(" .. label_patt .. ")%]%((" .. file_patt .. ")%)"
local ref_link_patt = "%[(" .. label_patt .. ")%]:%s(" .. file_patt .. ")"


local function get_buf_links(buf_nr)
  buf_nr = buf_nr or 0
  local text = table.concat(vim.api.nvim_buf_get_lines(buf_nr, 0, -1, {}), ' ')

  local links = {}
  for label, target in string.gmatch(text, inline_link_patt) do
    links[target] = { format = "inline", label = label }
  end

  for label, target in string.gmatch(text, ref_link_patt) do
    links[target] = { format = "reference", label = label }
  end

  local links_arr = {}
  for target, link in pairs(links) do
    table.insert(links_arr, vim.tbl_extend('keep', { target = target }, link))
  end

  return links_arr
end


local function find_links(opts)
  opts = opts or {}
  local buf_name = vim.api.nvim_buf_get_name(0)
  opts.cwd = vim.fn.fnamemodify(buf_name, ':h')
  local filename = vim.fn.fnamemodify(buf_name, ':t')

  local links = get_buf_links()

  local longest_target = 0
  for _, link in ipairs(links) do
    longest_target = math.max(longest_target, #link.target)
  end

  local displayer = entry_display.create {
    separator = " ",
    items = {
      {},
      {},
    }
  }

  local make_display = function (entry)
    return displayer {
      entry.value.target,
      {'[' .. entry.value.label .. ']', "TelescopeResultsComment" },
      }
  end

  pickers.new(opts, {
    prompt_title = "Links in " .. filename,
    finder = finders.new_table{
      results = links,
      entry_maker = function (link)
        return {
          value = link,
          display = make_display,
          ordinal = link.target,
          path = Path:new(opts.cwd, link.target):absolute(),
        }
      end,
    },
    sorter = conf.generic_sorter(opts),
    previewer = conf.file_previewer(opts),
  }):find()
end

local function find_backlinks(opts)
  opts = opts or {}

  local buf_name = vim.api.nvim_buf_get_name(0)
  local filename = vim.fn.fnamemodify(buf_name, ':t')

  pickers.new(opts, {
    prompt_title = "Backlinks to " .. filename,
    finder = backlinks_finder(opts),
    previewer = conf.grep_previewer(opts),
  }):find()
end

vim.keymap.set('n', '<leader>l', find_links)
vim.keymap.set('n', '<leader>b', find_backlinks)
vim.keymap.set('n', '<leader><leader>r', function ()
  package.loaded['telescope._extensions.markdown-links'] = nil
  package.loaded['telescope._extensions.markdown-links.backlinks-finder'] = nil
  vim.cmd[[:wa]]
  require'telescope._extensions.markdown-links'
  require'telescope._extensions.markdown-links.backlinks-finder'
  print('RELODED')
end)
