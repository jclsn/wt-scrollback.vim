vim9script

# Tests for showing the scrollback in the pager

import './common.vim'

source ../pager.vim

# Write scrollback data with "overrides" to a new file, as the helper does,
# and return its path.  "props" are the ranges on the screen, "other_props"
# the other ones.
def DataFile(overrides: dict<any>): string
  var fname = tempname()
  var data = {fg: '#cccccc', bg: '#0c0c0c', lines: ['line 1'], styles: [], props: [], other_props: []}
    ->extend(overrides)
  var info = data->copy()->filter((k, _) => index(['lines', 'props', 'other_props'], k) < 0)
  writefile([json_encode(info), json_encode(data.props), json_encode(data.other_props)] + data.lines, fname, 'b')
  return fname
enddef

# Return "count" numbered lines
def Lines(count: number): list<string>
  return range(1, count)->mapnew((_, n) => $'line {n}')
enddef

# Test for the scrollback buffer
def g:Test_WtScrollback_Buffer()
  :enew!
  var fname = DataFile({lines: ['red', 'plain'], styles: [{fg: '#ff0000', bg: ''}],
    props: [[[1, 1, 1, 4]]], other_props: [[[2, 1, 2, 3]]]})
  exe $'WtScrollback {fname}'
  assert_equal(['red', 'plain'], getline(1, '$'))
  assert_equal(1, prop_list(1)->len())
  # The other ranges follow once the screen is shown
  assert_equal(0, prop_list(2)->len())
  common.WaitForAssert(() => assert_equal(1, prop_list(2)->len()))
  assert_equal('nofile', &buftype)
  assert_false(&modifiable)
  assert_false(&modified)
  assert_false(&swapfile)
  # The helper's file is gone
  assert_false(filereadable(fname))
enddef

# Test for the view and the cursor of the pane
def g:Test_WtScrollback_Cursor()
  :enew!
  exe $'WtScrollback {DataFile({lines: Lines(100), topline: 10, cursor: [12, 3]})}'
  assert_equal(10, line('w0'))
  assert_equal(12, line('.'))
  assert_equal(3, col('.'))
enddef

# Test for the cursor in empty space, beyond the end of the line
def g:Test_WtScrollback_CursorBeyondText()
  :enew!
  exe $'WtScrollback {DataFile({lines: Lines(5), topline: 1, cursor: [2, 40]})}'
  assert_equal(2, line('.'))
  assert_equal(40, virtcol('.'))
  # Also after moving, which needs 'curswant'
  normal! j
  assert_equal(40, virtcol('.'))
enddef

# Test for no pane found: the end of the scrollback is shown
def g:Test_WtScrollback_NoCursor()
  :enew!
  exe $'WtScrollback {DataFile({lines: Lines(100)})}'
  assert_equal(100, line('.'))
  assert_equal(100, line('w$'))
enddef

# Test for the helper reading nothing
def g:Test_WtScrollback_NoData()
  :enew!
  var fname = tempname()
  writefile(['not json'], fname)
  exe $'WtScrollback {fname}'
  assert_match('The helper read no scrollback', execute('messages'))
  assert_false(filereadable(fname))
  v:errmsg = ''
enddef

# Test for the mappings that close the pager and drop the terminal's answers
def g:Test_Pager_Mappings()
  assert_match('quitall!', maparg('q', 'n'))
  assert_match('quitall!', maparg('i', 'n'))
  assert_match('DropReply', maparg('<Esc>[?', 'n'))
enddef

# Test for dropping the terminal's answer to a mode query
def g:Test_Pager_DropReply()
  :enew!
  setline(1, ['abc', 'def'])
  normal! G$
  feedkeys("\e[?2026;2$yk", 'xt')
  assert_equal([1, 3], [line('.'), col('.')])
  assert_equal(['abc', 'def'], getline(1, '$'))
enddef

# Test for the pager's options
def g:Test_Pager_Options()
  assert_true(&ruler)
  assert_equal(0, &laststatus)
  assert_equal('all', &virtualedit)
  assert_match('SCROLLBACK', &rulerformat)
  assert_equal('', &viminfo)
  assert_false(&loadplugins)
enddef

# vim: tabstop=8 shiftwidth=2 softtabstop=2 expandtab
