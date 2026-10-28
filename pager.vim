vim9script
# wt-scrollback.vim - Vim as Windows Terminal's scrollback pager
#
# This is the vimrc the pager profile starts Vim with. Windows Terminal has no
# scrollback pager setting, so the action that :WtScrollbackSetup adds selects
# and copies the whole buffer as HTML, which keeps the colors, and opens a
# zoomed pane with this Vim. The helper built from wt-scrollback.ps1 reads that
# HTML from the clipboard and turns it into lines and highlight ranges, and it
# reads the cursor and the visible rows of the pane we came from. Here they
# become text properties, and the view and cursor are restored to that pane's
# screen.
#
# Profile commandline (:WtScrollbackSetup writes this):
#   vim -N -u ~/vimfiles/plugged/wt-scrollback.vim/pager.vim
#
# -N is needed because Vim9 script restores 'cpoptions' after sourcing, which
# would otherwise leave Vim in compatible mode.

set encoding=utf-8
# Nothing to remember from or for the scrollback
set viminfo=

import './autoload/wt_scrollback.vim'

# Plugins (matchparen, anything in ~/vimfiles/plugin, ...) could only paint over
# the terminal's colors, and all colors that matter come from the terminal
set noloadplugins

silent! set termguicolors
set background=dark

set nonumber
set norelativenumber
set noshowmode
# The command line row has no counterpart in the terminal, use it to show where
# we are
set ruler
&rulerformat = '%30(%=%#WtScrollbackLabel# SCROLLBACK %* %l/%L%)'
set noshowcmd
set laststatus=0
set showtabline=0
set signcolumn=no
set nolist
set nocursorline
set colorcolumn=
# Windows Terminal joins wrapped rows into one line, wrapping them again looks
# like the terminal did
set wrap
set scrolloff=0
set sidescrolloff=0
set virtualedit=all
set tabstop=8
set shortmess+=IF
&fillchars = 'eob: '
set mouse=a

# Strikethrough as Windows Terminal draws it
&t_Ts = "\e[9m"
&t_Te = "\e[29m"

# A block cursor in every mode, like the profile's cursorShape
set guicursor=a:block-blinkon0
&t_SI = "\e[2 q"
&t_SR = "\e[2 q"
&t_EI = "\e[2 q"

nnoremap q <Cmd>quitall!<CR>
nnoremap i <Cmd>quitall!<CR>

# When the pane starts, the terminal answers a mode query (e.g.
# "\e[?2026;2$y"), which Win32 Vim doesn't recognize and receives as typed
# keys. "$" and "y" would leave a pending yank that the first key completes,
# moving the cursor to the top. Swallow such replies.
def DropReply(): string
	# The rest of "ESC [ ? <parameters/intermediates> <final byte>"
	for _ in range(32)
		if getcharstr() =~ '^[@-~]$'
			break
		endif
	endfor
	return ''
enddef
noremap <expr> <Esc>[? DropReply()
set timeoutlen=50

const JSON = tempname() .. '.json'

def Highlight(name: string, st: dict<any>)
	var attrs: list<string> = []
	for [key, attr] in [['bold', 'bold'], ['italic', 'italic'], ['underline', 'underline'], ['strike', 'strikethrough']]
		if get(st, key, false)
			attrs->add(attr)
		endif
	endfor
	const gui = empty(attrs) ? 'NONE' : attrs->join(',')
	execute $'highlight {name} guifg={get(st, 'fg', '') ?? 'NONE'} guibg={get(st, 'bg', '') ?? 'NONE'} gui={gui} cterm={gui}'
enddef

def ApplyColors(data: dict<any>)
	const fg = data.fg ?? '#cccccc'
	const bg = data.bg ?? '#0c0c0c'
	const luma = 299 * str2nr(bg[1 : 2], 16) + 587 * str2nr(bg[3 : 4], 16) + 114 * str2nr(bg[5 : 6], 16)
	const background = luma > 127500 ? 'light' : 'dark'
	if &background != background
		&background = background
	endif
	execute $'highlight Normal guifg={fg} guibg={bg}'
	execute $'highlight EndOfBuffer guifg={bg} guibg={bg}'
	highlight Visual gui=reverse cterm=reverse guifg=NONE guibg=NONE
	highlight WtScrollbackLabel guifg=#ffffff guibg=#7a5ccc gui=bold cterm=bold
	for i in range(len(data.styles))
		const name = 'WtScrollback' .. i
		Highlight(name, data.styles[i])
		prop_type_add(name, {highlight: name, combine: false})
		prop_add_list({type: name}, data.props[i])
	endfor
enddef

# Puts the pane's first visible line at the top and the cursor on the pane's
# cursor cell. Without them (the pane wasn't found), shows the end.
def RestoreView(data: dict<any>)
	if has_key(data, 'cursor')
		winrestview({topline: data.topline, lnum: data.cursor[0], col: 0})
		execute $'normal! {data.cursor[1]}|'
	else
		winrestview({lnum: line('$'), col: 0})
		normal! $zb
	endif
enddef

def Load()
	var data: dict<any>
	try
		data = json_decode(readfile(JSON)->join("\n"))
	catch
		echomsg 'wt-scrollback.vim: The helper produced no scrollback'
		return
	finally
		delete(JSON)
	endtry
	setline(1, data.lines)
	ApplyColors(data)
	setlocal buftype=nofile bufhidden=hide noswapfile nomodified nomodifiable
	RestoreView(data)
	redraw!
	wt_scrollback.SyncFontSize(get(data, 'profile', ''), get(data, 'size', []))
enddef

def Start()
	var cmd = [wt_scrollback.HelperExe(), string(getpid()), JSON]
	if getftime(wt_scrollback.HelperExe()) < getftime(wt_scrollback.HELPER_SOURCE)
		cmd = wt_scrollback.BuildCommand(cmd[1 :])
	endif
	job_start(cmd, {in_io: 'null', out_io: 'null', err_io: 'null', exit_cb: (_, _) => Load()})
enddef

# Everything yanked also goes to the system clipboard
def CopyToClipboard()
	if v:event.operator == 'y'
		setreg('+', v:event.regcontents, v:event.regtype)
	endif
enddef

autocmd TextYankPost * CopyToClipboard()

# Right away instead of on VimEnter, the helper runs while Vim starts up
Start()
