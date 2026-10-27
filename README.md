# wt-scrollback.vim

Use Vim as [Windows Terminal](https://github.com/microsoft/terminal)'s
scrollback pager. The scrollback looks exactly like the pane you were just on,
and the cursor is where it was, even when Vim or another program was running
there.

## Requirements

- Vim 9.1 or later with `+vim9script` and `+textprop`
- Windows Terminal (tested with 1.24)
- Windows PowerShell, which comes with Windows

## Installation

With [vim-plug](https://github.com/junegunn/vim-plug):

```vim
Plug 'jclsn/wt-scrollback.vim'
```

## Setup

The next time Vim starts inside Windows Terminal, it offers to configure
Windows Terminal for you. Choosing **Yes** backs up `settings.json` and adds a
hidden pager profile, an action and a key binding for it; Windows Terminal
picks the change up by itself. Run `:WtScrollbackSetup` to do this at any time.

Nothing happens outside Windows Terminal or when there is no `settings.json`.

To configure it by hand, add this to `settings.json` (with the paths of your
Vim and of this plugin):

```jsonc
"actions": [
    {
        "command": {
            "action": "multipleActions",
            "actions": [
                { "action": "selectAll" },
                { "action": "copy", "singleLine": false, "copyFormatting": "html" },
                { "action": "splitPane", "split": "down", "size": 0.2, "profile": "{7b7965fa-a70a-5652-bcf0-a02e57f39683}" },
                { "action": "togglePaneZoom" }
            ]
        },
        "id": "User.WtScrollback",
        "name": "Open scrollback in Vim"
    }
],
"keybindings": [
    { "id": "User.WtScrollback", "keys": "ctrl+shift+h" }
],
"profiles": {
    "list": [
        {
            "name": "wt-scrollback.vim",
            "guid": "{7b7965fa-a70a-5652-bcf0-a02e57f39683}",
            "hidden": true,
            "commandline": "\"C:\\Program Files\\Vim\\vim91\\vim.exe\" -N -u \"C:\\Users\\you\\vimfiles\\plugged\\wt-scrollback.vim\\pager.vim\"",
            "closeOnExit": "always",
            "cursorShape": "filledBox",
            "bellStyle": "none",
            "suppressApplicationTitle": true,
            "tabTitle": "Scrollback"
        }
    ]
}
```

To stop the check on startup:

```vim
g:wt_scrollback_check = false
```

To use another key binding, set it before running the setup:

```vim
g:wt_scrollback_keys = 'alt+shift+s'
```

## Usage

Open the scrollback with `ctrl+shift+h`. It opens as a zoomed pane on top of
the current tab. A purple **SCROLLBACK** label in the bottom row shows that you
are in the pager.

| Key      | Action                                     |
| -------- | ------------------------------------------ |
| `q`, `i` | Close the pager                            |
| `y`      | Yank, also copies to the system clipboard  |

The pager always runs locally, so this also works over ssh.

### How it works

Windows Terminal has no scrollback pager setting, so the action copies the
whole buffer as HTML (the only export that keeps the colors) and opens the
pager. A small helper, compiled once from `wt-scrollback.ps1` into
`%LOCALAPPDATA%\wt-scrollback.vim`, reads that HTML from the clipboard and
finds the cursor by reading the other panes' consoles. See
`:help wt-scrollback-internals`.
