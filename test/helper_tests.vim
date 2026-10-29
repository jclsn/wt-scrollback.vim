vim9script

# Tests for the helper turning Windows Terminal's HTML copy and the pane into
# lines, styles, view and cursor.  The first test builds the helper.

import './common.vim'
import '../autoload/wt_scrollback/helper.vim'

# Return Windows Terminal's HTML for "rows", each a list of SPAN STYLEs and
# texts, and the DIV's "style"
def Html(rows: list<list<list<string>>>, style = 'color:#CCCCCC;background-color:#0C0C0C;'): string
  var fragment = rows->mapnew((_, row) => row->mapnew((_, run) =>
    $'<SPAN STYLE="{run[0]}">{run[1]}</SPAN>')->join(''))->join('<BR>')
  return "Version:0.9\r\nStartHTML:0000000105\r\n<HTML><BODY><!--StartFragment -->"
    .. $'<DIV STYLE="display:inline-block;white-space:pre;{style}font-size:12pt;">{fragment}</DIV>'
    .. '<!--EndFragment --></BODY></HTML>'
enddef

# Run the helper on "html" with a pane of "width" columns, cursor at "x", "y"
# and with "rows" (none without "rows") and return what it read
def Run(html: string, width = 0, x = 0, y = 0, rows: list<string> = []): dict<any>
  var dir = common.TempDir()
  writefile([html], $'{dir}\copy.html', 'b')
  var args = ['--html', $'{dir}\copy.html', $'{dir}\out.json']
  if !empty(rows)
    writefile([$'{width} {x} {y} {{GUID}}'] + rows, $'{dir}\pane.txt')
    args->add($'{dir}\pane.txt')
  endif
  var done = false
  helper.Run(args, () => {
    done = true
  })
  # Building the helper takes a while
  common.WaitForAssert(() => assert_true(done), 120000)
  # The ranges on the screen and the other ones go to "screen_props" and
  # "other_props", both together to "props"
  var lines = readfile($'{dir}\out.json', 'b')
  var data = lines->remove(0)->json_decode()
  data.screen_props = lines->remove(0)->json_decode()
  data.other_props = lines->remove(0)->json_decode()
  data.props = data.screen_props->mapnew((i, ranges) => ranges + data.other_props[i])
  data.lines = lines
  return data
enddef

const plain = 'color:#CCCCCC;background-color:#0C0C0C;'

# Test for building the helper
def g:Test_Helper_00_Build()
  delete(helper.Exe())
  var data = Run(Html([[[plain, 'hi']]]))
  assert_true(executable(helper.Exe()))
  assert_equal(['hi'], data.lines)
enddef

# Test for the lines, entities and multibyte text
def g:Test_Helper_Lines()
  var data = Run(Html([
    [[plain, '&lt;a&gt; &amp; &quot;b&quot; &#x263A; &#9731;']],
    [[plain, 'ä'], [plain, 'ö']],
    [[plain, '']],
  ]))
  assert_equal(['<a> & "b" ☺ ☃', 'äö'], data.lines)
  assert_equal(['#CCCCCC', '#0C0C0C'], [data.fg, data.bg])
  assert_false(data->has_key('cursor'))
enddef

# Test for the styles and their byte ranges
def g:Test_Helper_Styles()
  var red = 'color:#FF0000;background-color:#0C0C0C;font-weight:bold;'
  var marked = 'color:#CCCCCC;background-color:#00FF00;text-decoration:underline line-through;font-style:italic;'
  var data = Run(Html([[[plain, 'ä '], [red, 'red'], [plain, ' '], [marked, 'x']]]))
  assert_equal(['ä red x'], data.lines)
  var styles = data.styles->mapnew((_, s) => s.fg .. s.bg)
  var r = styles->index('#FF0000')
  var m = styles->index('#00FF00')
  assert_equal({fg: '#FF0000', bg: '', bold: true, italic: false, underline: false, strike: false}, data.styles[r])
  assert_equal({fg: '', bg: '#00FF00', bold: false, italic: true, underline: true, strike: true}, data.styles[m])
  # Byte columns: "ä" is two bytes
  assert_equal([[1, 4, 1, 7]], data.props[r])
  assert_equal([[1, 8, 1, 9]], data.props[m])
enddef

# Test for dropping blank cells at the end of a row and empty rows at the end,
# but not cells with a background of their own
def g:Test_Helper_Trailing()
  var blue = 'color:#CCCCCC;background-color:#0000FF;'
  var data = Run(Html([
    [[plain, 'a   '], [plain, '  ']],
    [[plain, 'b'], [blue, '  '], [plain, '   ']],
    [[plain, '    ']],
    [[plain, '']],
  ]))
  assert_equal(['a', 'b  '], data.lines)
  assert_equal([[2, 2, 2, 4]], data.props[0])
enddef

# Test for the background most cells have becoming Vim's, like Vim's own
# filling the screen, with the foreground most used on it
def g:Test_Helper_DominantBackground()
  var screen = 'color:#E3E5E5;background-color:#0F111B;'
  var keyword = 'color:#7A5CCC;background-color:#0F111B;'
  var data = Run(Html([
    [[plain, 'PS> vim']],
    [[screen, 'some text here'], [keyword, 'if']],
    [[screen, 'more text here']],
  ]))
  assert_equal(['#E3E5E5', '#0F111B'], [data.fg, data.bg])
  # The shell's prompt keeps its own colors
  var styles = data.styles->mapnew((_, s) => [s.fg, s.bg])
  assert_notequal(-1, styles->index(['#CCCCCC', '#0C0C0C']))
  assert_notequal(-1, styles->index(['#7A5CCC', '']))
enddef

# Test for text without colors, which uses the DIV's
def g:Test_Helper_DivColors()
  var data = Run(Html([[['', 'plain']]], 'color:#AAAAAA;background-color:#101010;'))
  assert_equal(['#AAAAAA', '#101010'], [data.fg, data.bg])
  assert_equal([], data.styles)
enddef

# Test for finding the pane and its cursor
def g:Test_Helper_Cursor()
  var rows = range(1, 30)->mapnew((_, n) => [[plain, $'line {n}']])
  # The pane shows lines 26 to 30, the cursor is on "line 28", column 3
  var data = Run(Html(rows), 80, 2, 2, ['line 26', 'line 27', 'line 28', 'line 29', 'line 30'])
  assert_equal(26, data.topline)
  assert_equal([28, 3], data.cursor)
  assert_equal([80, 5], data.size)
  assert_equal('{GUID}', data.profile)
enddef

# Test for the cursor on a blank row below the text, like a fresh prompt
# line, and in a long line wrapped at the pane's width
def g:Test_Helper_CursorWrapped()
  var data = Run(Html([[[plain, 'x']], [[plain, repeat('a', 25)]], [[plain, 'end']]]),
    10, 4, 4, ['aaaaaaaaaa', 'aaaaaaaaaa', 'aaaaa', 'end', ''])
  assert_equal(2, data.topline)
  assert_equal([4, 5], data.cursor)
  assert_equal(['x', repeat('a', 25), 'end', ''], data.lines)

  data = Run(Html([[[plain, 'x']], [[plain, repeat('a', 25)]]]), 10, 3, 1, ['aaaaaaaaaa', 'aaaaaaaaaa', 'aaaaa'])
  assert_equal([2, 14], data.cursor)
enddef

# Test for the ranges on the pane's screen coming first, and for joining the
# ranges of runs with the same style
def g:Test_Helper_ScreenProps()
  var red = 'color:#FF0000;background-color:#0C0C0C;'
  var rows = range(1, 30)->mapnew((_, n) => [[red, 'li'], [red, 'ne'], [plain, $' {n} in the default color']])
  var data = Run(Html(rows), 80, 0, 0, range(26, 30)->mapnew((_, n) => $'line {n} in the default color'))
  assert_equal(range(26, 30)->mapnew((_, n) => [n, 1, n, 5]), data.screen_props[0])
  assert_equal(range(1, 25)->mapnew((_, n) => [n, 1, n, 5]), data.other_props[0])

  # Without a pane, the end of the scrollback is on the screen
  data = Run(Html(rows))
  assert_equal(30, len(data.screen_props[0]))
  assert_equal([], data.other_props[0])
enddef

# Test for a pane that doesn't match the copy
def g:Test_Helper_NoMatch()
  var data = Run(Html([[[plain, 'one']], [[plain, 'two']]]), 80, 0, 0, ['other', 'rows'])
  assert_false(data->has_key('cursor'))
  assert_false(data->has_key('profile'))
enddef

# vim: tabstop=8 shiftwidth=2 softtabstop=2 expandtab
