# markdown-links

[Telescope](https://github.com/nvim-telescope/telescope.nvim) extension to find
links leading from and to a markdown file.

## About

This extension provides two pickers:

- `find_links` - displays all files linked from the current file,
- `find_backlinks` - displays all files that link to the current file.


## Install

To use this extension you need to install
[ripgrep](https://github.com/BurntSushi/ripgrep).

Then install 'telescope-markdown-links' using your favorite plugin manager.

E.g. [plug](https://github.com/junegunn/vim-plug)
```vim
Plug 'dburian/telescope-markdown-links'
```

## Usage

Enable the extension following telescope's
[instructions](https://github.com/nvim-telescope/telescope.nvim#loading-extensions):

```lua
require'telescope'.load_extension'markdown-links'
```

After that you can use the plugin as a command:
```
:Telescope markdown-links find_links
```
or in code:
```lua
vim.keymap.set('n', '<leader>fl',
require'telescope'.extensions['markdown-links'].find_links, {noremap = true,
silent = true})

vim.keymap.set('n', '<leader>fbl',
require'telescope'.extensions['markdown-links'].find_backlinks, {noremap = true,
silent = true})
```

## Setup

Both pickers follow the same style as telescope builtin pickers, so you can
adjust things like `prompt_title`. Additionally `find_backlinks` accepts these
extra options:

- `target_path` - absolute path of the file, to which all the links should be
  found. Defaults to the path of the currently opened file.
- `search_dirs` - list of all directories to be searched. Defaults to the list
  consisting of:
  - current working directory of nvim
  - enclosing directory of `target_path`

## How

Instead of leveraging treesitter queries, I opted to use ripgrep for searching
links - it seemed easier and quicker (if I am wrong, let me know :). This leads
to the fact that some links might not be found. Currently the extension should
register all the following links:

```markdown
[link identifier]: ./relative/path/to/file.md
[absolute ref. link]: /home/user/documents/notes/file.md

this is a simple [reference link][link identifier]

this is a reference link with [absolute target path][absolute ref. link]

                                          this is a reference link [which,
unfortunatelly did not fit into one line, but spans two][link identifier]

this is a simple [inline link](./relative/path/to/file.md)

this is an inline link [with absolute path](/home/user/documents/notes/file.md)

this is an inline link [which too unfortunatelly did not fit into one line, but
spans only two lines](./some/path/file.md)
```

If a link should be registered and it's not, raise an issue. Also if you'd like
the extension to support more formats create a PR or raise an issue.


## Why

This extension tries to help people who:

- take notes in markdown (maybe following the Zettelkasten method or building
  second brain),
- use nvim,
- use telescope.

If you do all the things above (and use
[nvim-cmp](https://github.com/hrsh7th/nvim-cmp)) checkout my other
[extension](https://github.com/dburian/cmp-markdown-link).

## Contributing

This plugin is a side project and I am currently not a full-time open source
developer. Consequently I might not be as quick to react to issues or PRs. Thank
you for your understanding :).

If you'd like a feature to be implemented raise an issue or create PRs.
