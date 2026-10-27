vim9script
# wt-scrollback.vim - Vim as Windows Terminal's scrollback pager
# The pager itself is pager.vim, which Windows Terminal starts with -u. This
# only offers to configure Windows Terminal for it.

if exists('g:loaded_wt_scrollback')
	finish
endif
g:loaded_wt_scrollback = 1

import autoload 'wt_scrollback.vim'

command -bar WtScrollbackSetup wt_scrollback.Setup(true)

def Check()
	# Only ask in an interactive Vim
	if get(g:, 'wt_scrollback_check', true) && has('ttyin') && has('ttyout')
		wt_scrollback.Setup(false)
	endif
enddef

# After startup, so the prompt doesn't get in the way of the first screen
autocmd VimEnter * ++once timer_start(0, (_) => Check())
