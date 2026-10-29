vim9script

# wt-scrollback.vim: the vimrc of the scrollback pager.
#
# Windows Terminal starts it in a zoomed pane after copying the whole buffer
# as HTML (see :help wt-scrollback).  The helper reads that copy and the pane
# it came from, and ":WtScrollback {json}" shows what it read.  Vim must be
# started with -N, as Vim9 script resets 'cpoptions' after sourcing.

set encoding=utf-8
# Nothing to remember from or for the scrollback
set viminfo=

import './autoload/wt_scrollback/helper.vim'
import './autoload/wt_scrollback/render.vim'
# Only needed after the scrollback is shown
import autoload './autoload/wt_scrollback/font.vim'

# Plugins could only paint over the terminal's colors
set noloadplugins
silent! set termguicolors
set background=dark

# Look like the terminal screen
set nonumber
set norelativenumber
set nolist
set nocursorline
# Windows Terminal joins wrapped rows into one line
set wrap
set noshowmode
set noshowcmd
set laststatus=0
set showtabline=0
set signcolumn=no
set colorcolumn=
set scrolloff=0
set sidescrolloff=0
set virtualedit=all
set tabstop=8
set shortmess+=IF
set mouse=a
&fillchars = 'eob: '

# The command line row shows where we are
set ruler
&rulerformat = '%30(%=%#WtScrollbackLabel# SCROLLBACK %* %l/%L%)'

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

# When the pane starts, Windows Terminal answers a mode query (e.g.
# "\e[?2026;2$y"), which Win32 Vim doesn't recognize and receives as typed
# keys.  "$" and "y" would leave a pending yank that the first key completes,
# moving the cursor to the top.  Drop such answers.
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

# Show the pane's first visible line at the top and put the cursor on the
# pane's cursor cell.  Without them (the pane wasn't found), show the end.
def RestoreView(data: dict<any>)
  if data->has_key('cursor')
    winrestview({topline: data.topline, lnum: data.cursor[0], col: 0})
    exe $'normal! {data.cursor[1]}|'
  else
    winrestview({lnum: line('$'), col: 0})
    normal! $zb
  endif
enddef

# Show the scrollback that the helper wrote to "fname" and delete the file.
# It has a line of JSON with the colors, styles, view and cursor, a line with
# the ranges of the styles on the screen, one with the other ranges, and the
# lines of the scrollback.
def Show(fname: string)
  var lines: list<string>
  var data: dict<any>
  try
    lines = readfile(fname, 'b')
    data = lines->remove(0)->json_decode()
    data.props = lines->remove(0)->json_decode()
  catch
    echomsg 'wt-scrollback.vim: The helper read no scrollback'
    return
  finally
    delete(fname)
  endtry
  var other_props = lines->remove(0)
  data.lines = lines

  render.Render(data)
  setlocal buftype=nofile
  setlocal bufhidden=hide
  setlocal noswapfile
  setlocal nomodified
  setlocal nomodifiable
  RestoreView(data)
  redraw!

  # Once the screen is shown
  timer_start(0, (_) => {
    render.AddProps(json_decode(other_props))
    if data->has_key('size')
      font.Sync(data->get('profile', ''), data.size)
    endif
    redraw
  })
enddef

# Copy yanked text to the system clipboard
def CopyToClipboard()
  if v:event.operator == 'y'
    setreg('+', v:event.regcontents, v:event.regtype)
  endif
enddef

augroup WtScrollback
  au!
  autocmd TextYankPost * CopyToClipboard()
augroup END

command -bar -nargs=1 -complete=file WtScrollback Show(<q-args>)

# Right away instead of on VimEnter, so the helper runs while Vim starts up.
# Only in Windows Terminal, the tests source this too.
if !empty($WT_SESSION)
  const json = tempname() .. '.json'
  helper.Run([string(getpid()), json], () => {
    Show(json)
  })
endif

# vim: tabstop=8 shiftwidth=2 softtabstop=2 expandtab
