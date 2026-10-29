vim9script

# Show the scrollback that the helper read: its lines, colors and the text
# properties of its styles

# Return the highlight attributes of "style"
def Attrs(style: dict<any>): string
  var attrs: list<string> = []
  for [key, attr] in [['bold', 'bold'], ['italic', 'italic'], ['underline', 'underline'], ['strike', 'strikethrough']]
    if style->get(key, false)
      attrs->add(attr)
    endif
  endfor
  return attrs->empty() ? 'NONE' : attrs->join(',')
enddef

# Set Normal to the colors of the scrollback, "fg" and "bg" ("#rrggbb")
def SetColors(fg: string, bg: string)
  var luma = 299 * bg[1 : 2]->str2nr(16) + 587 * bg[3 : 4]->str2nr(16) + 114 * bg[5 : 6]->str2nr(16)
  var background = luma > 127500 ? 'light' : 'dark'
  if &background != background
    # This resets the highlight groups, so it must come before the overrides
    &background = background
  endif
  exe $'highlight Normal guifg={fg} guibg={bg}'
  exe $'highlight EndOfBuffer guifg={bg} guibg={bg}'
  highlight Visual guifg=NONE guibg=NONE gui=reverse cterm=reverse
  highlight WtScrollbackLabel guifg=#ffffff guibg=#7a5ccc gui=bold cterm=bold
enddef

# Add the ranges "props" of each style ([line, column, line, end column]) to
# the current buffer
export def AddProps(props: list<list<list<number>>>)
  for [idx, ranges] in props->items()
    if !empty(ranges)
      prop_add_list({type: $'WtScrollback{idx}', bufnr: bufnr()}, ranges)
    endif
  endfor
enddef

# Replace the current buffer with the scrollback "data" from the helper:
# "lines", the default colors "fg" and "bg", and the "styles" with the ranges
# ("props") they cover, of all lines or only some, see AddProps()
export def Render(data: dict<any>)
  setline(1, data.lines)
  SetColors(data.fg ?? '#cccccc', data.bg ?? '#0c0c0c')
  for [idx, style] in data.styles->items()
    var name = $'WtScrollback{idx}'
    exe $'highlight {name} guifg={style.fg ?? 'NONE'} guibg={style.bg ?? 'NONE'} gui={Attrs(style)} cterm={Attrs(style)}'
    prop_type_add(name, {bufnr: bufnr(), highlight: name, combine: false})
  endfor
  AddProps(data.props)
enddef

# vim: tabstop=8 shiftwidth=2 softtabstop=2 expandtab
