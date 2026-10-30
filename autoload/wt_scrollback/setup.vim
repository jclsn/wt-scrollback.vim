vim9script

# Configure Windows Terminal to use pager.vim as the scrollback pager.
#
# Windows Terminal has no scrollback pager setting.  So this adds an action
# that copies the whole buffer as HTML, scrolls back down and opens the
# pager's hidden profile in a zoomed pane, a key binding for it and the
# profile, and turns off pane animations, so the pager appears at once.
#
# Selecting all scrolls to the top before the scrollbar is updated, so
# "scrollToBottom", which goes by the scrollbar, does nothing.  Scrolling to
# the last mark scrolls in the terminal itself: to the last prompt mark, or
# with none (any more) below, to the bottom.  So the second one always ends
# at the bottom.

import './helper.vim'
import './settings.vim'

const root_dir = expand('<script>:p')->resolve()->fnamemodify(':h:h:h')

const action_id = 'User.WtScrollback'
const keys = 'ctrl+shift+h'

# Display an info message
def InfoMsg(msg: string)
  :echohl Question
  :echomsg $'wt-scrollback.vim: {msg}'
  :echohl None
enddef

# Return the command that starts Vim with the pager vimrc
def PagerCmd(): string
  return $'"{v:progpath}" -N -u "{root_dir}\pager.vim"'
enddef

def ProfileJson(): string
  return [
    '{',
    '    "name": "wt-scrollback.vim",',
    $'    "guid": "{settings.PROFILE_GUID}",',
    '    "hidden": true,',
    $'    "commandline": {json_encode(PagerCmd())},',
    '    "closeOnExit": "always",',
    '    "cursorShape": "filledBox",',
    '    "bellStyle": "none",',
    '    "suppressApplicationTitle": true,',
    '    "tabTitle": "Scrollback"',
    '}']->join("\n")
enddef

# The action, with its key binding unless key bindings are separate
def ActionJson(with_keys: bool): string
  return ([
    '{',
    '    "command":',
    '    {',
    '        "action": "multipleActions",',
    '        "actions":',
    '        [',
    '            { "action": "selectAll" },',
    '            { "action": "copy", "singleLine": false, "copyFormatting": "html" },',
    '            { "action": "scrollToMark", "direction": "last" },',
    '            { "action": "scrollToMark", "direction": "last" },',
    $'            {{ "action": "splitPane", "split": "down", "size": 0.2, "profile": "{settings.PROFILE_GUID}" }},',
    '            { "action": "togglePaneZoom" }',
    '        ]',
    '    },',
    $'    "id": "{action_id}",']
    + (with_keys ? [$'    "keys": "{keys}",'] : [])
    + ['    "name": "Open scrollback in Vim"', '}'])
    ->join("\n")
enddef

# Return whether "json" has the pager's profile and the action
def IsConfigured(json: dict<any>): bool
  var pager = tolower($'{root_dir}\pager.vim')
  var [_, profiles] = settings.Profiles(json)
  return profiles->indexof((_, p) => type(p) == v:t_dict && p->get('commandline', '')->tolower()->stridx(pager) >= 0) >= 0
    && json->get('actions', [])->indexof((_, a) => type(a) == v:t_dict && a->get('id', '') ==# action_id) >= 0
enddef

# Return settings.json "text" ("json" parsed) with the pager's profile, the
# action and its key binding added at the end of their lists, so they win
# over earlier ones, and with pane animations turned off
def AddSettings(text: string, json: dict<any>): string
  var containers = settings.Containers(text)
  var First = (path) => containers->get(path, [])->get(0, [])
  var separate_keys = json->has_key('keybindings')
  var edits: list<list<any>> = []

  var profiles = First('.profiles.list') ?? First('.profiles')
  if empty(profiles) || strpart(text, profiles[0], 1) != '['
    throw 'no list of profiles'
  endif
  edits->add(settings.AppendItem(text, profiles[0], profiles[1], ProfileJson()))

  var root_items: list<string> = []
  var actions = First('.actions')
  if empty(actions)
    root_items->add("\"actions\":\n[\n" .. ActionJson(!separate_keys)->split("\n")
      ->map((_, l) => $'    {l}')->join("\n") .. "\n],")
  else
    edits->add(settings.AppendItem(text, actions[0], actions[1], ActionJson(!separate_keys)))
  endif
  if !json->has_key('disableAnimations')
    root_items->add('"disableAnimations": true,')
  endif
  if !empty(root_items)
    var nl = stridx(text, "\r\n") >= 0 ? "\r\n" : "\n"
    var root = First('')[0]
    edits->add([root + 1, root + 1, nl .. root_items->join("\n")->split("\n")
      ->map((_, l) => $'    {l}')->join(nl)])
  endif

  var bindings = First('.keybindings')
  if separate_keys && !empty(bindings)
    edits->add(settings.AppendItem(text, bindings[0], bindings[1],
      $'{{ "id": "{action_id}", "keys": "{keys}" }}'))
  endif
  return settings.Apply(text, edits)
enddef

# Configure Windows Terminal
export def Setup()
  var fname = settings.File()
  if empty(fname)
    InfoMsg('No Windows Terminal settings.json found')
    return
  endif

  var text = settings.Read(fname)
  var json = settings.Decode(text)
  if empty(json)
    # E.g. while Windows Terminal writes it
    InfoMsg($'Could not read {fname->fnamemodify(':~')}')
    return
  elseif IsConfigured(json)
    InfoMsg('Windows Terminal already uses it')
    return
  endif

  var result: string
  try
    result = AddSettings(text, json)
  catch
    InfoMsg($'Could not change {fname->fnamemodify(':~')}: {v:exception}')
    return
  endtry
  writefile(readfile(fname, 'B'), $'{fname}.bak')
  settings.Write(result, fname)
  # Now, so the first scrollback opens without the wait
  helper.Build()
  InfoMsg($'Configured {fname->fnamemodify(':~')}, Windows Terminal reloads it by itself')
enddef

# vim: tabstop=8 shiftwidth=2 softtabstop=2 expandtab
