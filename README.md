# wt-scrollback.vim

Use Vim as [Windows Terminal](https://github.com/microsoft/terminal)'s
scrollback pager, with the colors, view, cursor and font size of the pane, also
of a pane running Vim or ssh.

Requires Vim 9.1 with `+vim9script` and `+textprop`, Windows Terminal (tested
with 1.24) and Windows PowerShell.

## Setup

```vim
Plug 'jclsn/wt-scrollback.vim'
```

Run `:WtScrollbackSetup`. It adds the settings from `:help wt-scrollback` to
Windows Terminal's `settings.json`.

## Usage

`ctrl+shift+h` opens the scrollback, `q` or `i` closes it, `y` also copies to
the clipboard.
