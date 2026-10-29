if !has('vim9script') || !has('patch-9.1.0')
  " Needs Vim 9.1
  finish
endif

vim9script noclear

# Vim as Windows Terminal's scrollback pager

if get(g:, 'loaded_wt_scrollback', false)
  finish
endif
g:loaded_wt_scrollback = true

import autoload '../autoload/wt_scrollback/setup.vim'

command -bar WtScrollbackSetup setup.Setup()

# vim: tabstop=8 shiftwidth=2 softtabstop=2 expandtab
