vim9script

# The pager's font size follows the pane it was opened from: the font size of
# the pane's profile, or the zoomed size.  The pager sets it on its own profile
# in settings.json, and Windows Terminal applies that to the open pager.

import './settings.vim'

# Return the font size of "profile" as Windows Terminal resolves it with the
# "defaults" of all profiles
export def Size(profile: dict<any>, defaults: dict<any>): float
  for p in [profile, defaults]
    var font = p->get('font', {})
    if type(font) == v:t_dict && font->has_key('size')
      return 0.0 + font.size
    elseif p->has_key('fontSize')
      return 0.0 + p.fontSize
    endif
  endfor
  return 12.0
enddef

# Return the font size of a pane that is "pane" ([columns, rows]) cells large,
# judged by the pager, which uses "current" and is "own" cells large.  Zooming
# (ctrl+=, ctrl+wheel) isn't saved anywhere, but it changes the cell size and
# so how many cells fit.  "profile" is the size the pane's profile sets, it
# wins when the pane isn't zoomed.  Returns -1 when the sizes don't tell: the
# pane didn't fill the tab (more splits), or the pager isn't zoomed yet.
export def Zoomed(current: float, profile: float, pane: list<number>, own: list<number>): float
  if len(pane) != 2 || min(pane + own) <= 0
    return -1.0
  endif
  # The pane's cell size relative to the pager's.  Splitting the pane off may
  # already have taken 20% of its rows, so the height only rules out other
  # layouts.
  var width = 1.0 * own[0] / pane[0]
  var height = 1.0 * own[1] / pane[1]
  if width / height < 0.72 || width / height > 1.08
    return -1.0
  endif
  var size = current * width
  return abs(size - profile) < 0.5 ? profile : round(size)
enddef

# Return settings.json "text" with the font size of the pager's profile set to
# "size"
export def SetSize(text: string, size: float): string
  var value = size == trunc(size) ? string(float2nr(size)) : string(size)
  var containers = settings.Containers(text)
  var guid = '"guid"\_s*:\_s*"' .. settings.PROFILE_GUID .. '"'
  for path in ['.profiles.list[]', '.profiles[]']
    for [open, close] in containers->get(path, [])
      if strpart(text, open, close - open + 1) !~? guid
        continue
      endif
      var font = containers->get($'{path}.font', [])->indexof((_, f) => f[0] > open && f[1] < close)
      if font < 0
        return settings.Apply(text, [settings.AppendItem(text, open, close, $'"font": {{ "size": {value} }}')])
      endif
      var [font_open, font_close] = containers[$'{path}.font'][font]
      var [_, start, end] = strpart(text, 0, font_close)->matchstrpos('"size"\_s*:\_s*\zs[-+0-9.eE]\+', font_open)
      return settings.Apply(text, [start < 0
        ? settings.AppendItem(text, font_open, font_close, $'"size": {value}')
        : [start, end, value]])
    endfor
  endfor
  throw 'no pager profile'
enddef

# Give the pager's profile the font size of the pane it was opened from: the
# size of the pane's profile "source" (a guid), or the zoomed size when the
# pane's size "pane" ([columns, rows]) shows it was zoomed.  settings.json is
# only written when the size changes.
export def Sync(source: string, pane: list<number>)
  var fname = settings.File()
  if (empty(source) && empty(pane)) || empty(fname) || source ==? settings.PROFILE_GUID
    return
  endif
  var text = settings.Read(fname)
  var [defaults, profiles] = settings.Profiles(settings.Decode(text))
  var pager = settings.Profile(profiles, settings.PROFILE_GUID)
  if empty(pager)
    return
  endif
  var current = Size(pager, defaults)
  var profile = Size(settings.Profile(profiles, source), defaults)
  var zoomed = Zoomed(current, profile, pane, [&columns, &lines])
  var size = zoomed > 0 ? zoomed : profile
  if size != current
    try
      settings.Write(SetSize(text, size), fname)
    catch
      echomsg $'wt-scrollback.vim: Could not set the font size: {v:exception}'
    endtry
  endif
enddef

# vim: tabstop=8 shiftwidth=2 softtabstop=2 expandtab
