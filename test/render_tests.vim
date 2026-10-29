vim9script

# Tests for showing the scrollback that the helper read

import '../autoload/wt_scrollback/render.vim'

# Return scrollback data with "overrides"
def Data(overrides: dict<any>): dict<any>
  return {fg: '#cccccc', bg: '#0c0c0c', lines: ['plain'], styles: [], props: []}->extend(overrides)
enddef

# Return [col, length, highlight group] of each text property in line "lnum"
def Props(lnum: number): list<list<any>>
  return prop_list(lnum)->mapnew((_, p) => [p.col, p.length, p.type])
enddef

# Test for the lines and the text properties of the styles
def g:Test_Render_Props()
  :enew!
  render.Render(Data({
    lines: ['red bold', 'täxt'],
    styles: [{fg: '#ff0000', bg: '', bold: true}, {fg: '', bg: '#00ff00', underline: true}],
    props: [[[1, 1, 1, 4]], [[1, 5, 1, 9], [2, 2, 2, 4]]],
  }))
  assert_equal(['red bold', 'täxt'], getline(1, '$'))
  assert_equal([[1, 3, 'WtScrollback0'], [5, 4, 'WtScrollback1']], Props(1))
  assert_equal([[2, 2, 'WtScrollback1']], Props(2))

  var red = hlget('WtScrollback0')[0]
  assert_equal('#ff0000', red.guifg)
  assert_equal({bold: true}, red.gui)
  assert_false(red->has_key('guibg'))
  var green = hlget('WtScrollback1')[0]
  assert_equal('#00ff00', green.guibg)
  assert_equal({underline: true}, green.gui)
enddef

# Test for all the attributes
def g:Test_Render_Attributes()
  :enew!
  render.Render(Data({styles: [{fg: '#010203', bg: '', bold: true, italic: true, underline: true, strike: true}],
    props: [[[1, 1, 1, 2]]]}))
  assert_equal({bold: true, italic: true, underline: true, strikethrough: true}, hlget('WtScrollback0')[0].gui)
enddef

# Test for rendering into a second buffer, with its own property types
def g:Test_Render_TwoBuffers()
  :enew!
  render.Render(Data({styles: [{fg: '#111111', bg: ''}], props: [[[1, 1, 1, 2]]]}))
  :enew!
  render.Render(Data({styles: [{fg: '#222222', bg: ''}], props: [[[1, 2, 1, 3]]]}))
  assert_equal([[2, 1, 'WtScrollback0']], Props(1))
enddef

# Test for the default colors and the background they make
def g:Test_Render_Colors()
  :enew!
  render.Render(Data({fg: '#e3e5e5', bg: '#0f111b'}))
  var normal = hlget('Normal')[0]
  assert_equal(['#e3e5e5', '#0f111b'], [normal.guifg, normal.guibg])
  assert_equal('#0f111b', hlget('EndOfBuffer')[0].guibg)
  assert_equal('dark', &background)

  render.Render(Data({fg: '#000000', bg: '#ffffff'}))
  assert_equal('light', &background)
  assert_equal('#ffffff', hlget('Normal')[0].guibg)

  # Without colors in the copy
  render.Render(Data({fg: '', bg: ''}))
  assert_equal('#0c0c0c', hlget('Normal')[0].guibg)
  set background=dark
enddef

# vim: tabstop=8 shiftwidth=2 softtabstop=2 expandtab
