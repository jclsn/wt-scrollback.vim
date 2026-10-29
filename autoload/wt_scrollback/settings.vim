vim9script

# Windows Terminal's settings.json: finding, reading and editing it.  It is
# JSON with comments and trailing commas.  Edits are text insertions, so the
# rest of the file, comments and line endings included, stays as it is.  All
# positions are byte indexes.

# The guid of the pager's profile
export const PROFILE_GUID = '{7b7965fa-a70a-5652-bcf0-a02e57f39683}'

# A string, a line comment or a block comment
const token = '"\%(\\.\|[^"\\]\)*"\|//[^\n]*\|/\*\_.\{-}\*/'

# Return the settings.json of Windows Terminal, Windows Terminal Preview or an
# unpackaged Windows Terminal, or an empty string
export def File(): string
  var local = empty($LOCALAPPDATA) ? expand('~/AppData/Local') : $LOCALAPPDATA
  for fname in [
      $'{local}\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json',
      $'{local}\Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json',
      $'{local}\Microsoft\Windows Terminal\settings.json']
    if filereadable(fname)
      return fname
    endif
  endfor
  return ''
enddef

# Return the text of "fname" with its line endings
export def Read(fname: string): string
  return readfile(fname, 'b')->join("\n")
enddef

# Write "text" to "fname" as it is
export def Write(text: string, fname: string)
  writefile(text->split("\n", true), fname, 'b')
enddef

# Return "text" with the comments blanked out and, with "strings", the
# contents of the strings too.  Positions stay the same, so with "strings" all
# that is left is the structure, in ASCII.
def Mask(text: string, strings: bool): string
  return text->substitute(token, (m) => m[0][0] != '"'
    ? m[0]->substitute('[^\n]', ' ', 'g')
    : strings ? '"' .. repeat('x', len(m[0]) - 2) .. '"' : m[0], 'g')
enddef

# Parse "text", or return an empty dict when it isn't valid
export def Decode(text: string): dict<any>
  var masked = Mask(text, true)
  var clean = Mask(text, false)
  # Drop trailing commas
  var parts: list<string> = []
  var start = 0
  var comma = match(masked, ',\ze[ \t\r\n]*[]}]')
  while comma >= 0
    parts->add(strpart(clean, start, comma - start))
    start = comma + 1
    comma = match(masked, ',\ze[ \t\r\n]*[]}]', start)
  endwhile
  parts->add(strpart(clean, start))
  try
    var settings = parts->join('')->json_decode()
    return type(settings) == v:t_dict ? settings : {}
  catch
    return {}
  endtry
enddef

# Return the default profile settings and the list of profiles of "settings"
export def Profiles(settings: dict<any>): list<any>
  var profiles = settings->get('profiles', [])
  if type(profiles) == v:t_dict
    return [profiles->get('defaults', {}), profiles->get('list', [])]
  endif
  return [{}, type(profiles) == v:t_list ? profiles : []]
enddef

# Return the profile with "guid" in "profiles", or an empty dict
export def Profile(profiles: list<any>, guid: string): dict<any>
  var idx = profiles->indexof((_, p) => type(p) == v:t_dict && p->get('guid', '') ==? guid)
  return idx < 0 ? {} : profiles[idx]
enddef

# Return the positions of the "{" or "[" and the matching bracket of each
# container in "text", by path (".actions", ".profiles.list",
# ".profiles.list[]", ...), in the order they appear
export def Containers(text: string): dict<list<list<number>>>
  var masked = Mask(text, true)
  var found: dict<list<list<number>>> = {}
  var stack: list<dict<any>> = []
  var last_string = ''
  var i = match(masked, '[][{}:,"]')
  while i >= 0
    var c = strpart(masked, i, 1)
    if c == '"'
      var end = matchend(masked, '"x*"', i)
      last_string = strpart(text, i + 1, end - i - 2)
      i = end - 1
    elseif c == ':' && !empty(stack)
      stack[-1].key = last_string
    elseif c == ',' && !empty(stack)
      stack[-1].key = ''
    elseif c == '{' || c == '['
      var path = ''
      if !empty(stack)
        path = stack[-1].path .. (stack[-1].type == '{' ? $'.{stack[-1].key}' : '[]')
      endif
      stack->add({type: c, path: path, key: '', start: i})
    elseif !empty(stack)
      var top = stack->remove(-1)
      found[top.path] = found->get(top.path, [])->add([top.start, i])
    endif
    i = match(masked, '[][{}:,"]', i + 1)
  endwhile
  return found
enddef

# Return the edit [start, end, replacement] that makes "item" the last element
# of the container from "open" to "close" in "text"
export def AppendItem(text: string, open: number, close: number, item: string): list<any>
  var nl = stridx(text, "\r\n") >= 0 ? "\r\n" : "\n"
  var line_start = strridx(text, "\n", close - 1)
  var indent = strpart(text, line_start + 1, close - line_start - 1)->matchstr('^[ \t]*')
  var inner = strpart(Mask(text, true), open + 1, close - open - 1)
  var last = match(inner, '[^ \t\r\n][ \t\r\n]*$')
  last = last < 0 ? open : open + 1 + last
  var comma = last == open || strpart(inner, last - open - 1, 1) == ',' ? '' : ','
  # Comments after the last element stay in front of the new one
  var keep = strpart(text, last + 1, close - last - 1)->substitute('[ \t\r\n]*$', '', '')
  var lines = item->split("\n")->map((_, l) => $'{indent}    {l}')
  return [last + 1, close, comma .. keep .. nl .. lines->join(nl) .. nl .. indent]
enddef

# Return "text" with the edits [start, end, replacement] applied
export def Apply(text: string, edits: list<list<any>>): string
  var result = text
  for [start, end, replacement] in edits->copy()->sort((a, b) => b[0] - a[0])
    result = strpart(result, 0, start) .. replacement .. strpart(result, end)
  endfor
  return result
enddef

# vim: tabstop=8 shiftwidth=2 softtabstop=2 expandtab
