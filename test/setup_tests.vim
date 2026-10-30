vim9script

# Tests for :WtScrollbackSetup configuring Windows Terminal

import './common.vim'
import '../autoload/wt_scrollback/settings.vim'

source ../plugin/wt_scrollback.vim

const pager = expand('<script>:p:h:h') .. '\pager.vim'

# settings.json as Windows Terminal writes it, with separate key bindings
const new_format = [
  '{',
  '    "$schema": "https://aka.ms/terminal-profiles-schema",',
  '    "actions": [',
  '        { "command": "paste", "id": "User.paste" }',
  '    ],',
  '    "keybindings": [',
  '        { "id": "User.paste", "keys": "ctrl+v" }',
  '    ],',
  '    "profiles": {',
  '        "defaults": {},',
  '        "list": [',
  '            { "guid": "{61c54bbd-c2c6-5271-96e7-009a87ff44bf}", "name": "Windows PowerShell" }',
  '        ]',
  '    }',
  '}']

# Return the pager's profile in "json"
def PagerProfile(json: dict<any>): dict<any>
  return settings.Profile(settings.Profiles(json)[1], settings.PROFILE_GUID)
enddef

# Return the action of the pager in "json"
def Action(json: dict<any>): dict<any>
  return json.actions->copy()->filter((_, a) => a.id == 'User.WtScrollback')->get(0, {})
enddef

# Test for configuring settings.json with separate key bindings
def g:Test_Setup()
  var fname = common.WriteSettings(new_format)
  :WtScrollbackSetup
  var json = settings.Decode(settings.Read(fname))

  var profile = PagerProfile(json)
  assert_equal('wt-scrollback.vim', profile.name)
  assert_true(profile.hidden)
  assert_equal($'"{v:progpath}" -N -u "{pager}"', profile.commandline)
  assert_equal('Windows PowerShell', json.profiles.list[0].name)

  var action = Action(json)
  assert_equal(['selectAll', 'copy', 'scrollToBottom', 'splitPane', 'togglePaneZoom'],
    action.command.actions->mapnew((_, a) => a.action))
  assert_equal(settings.PROFILE_GUID, action.command.actions[3].profile)
  assert_false(action->has_key('keys'))
  assert_equal({id: 'User.WtScrollback', keys: 'ctrl+shift+h'}, json.keybindings[-1])
  assert_true(json.disableAnimations)

  # The original is backed up
  assert_equal(new_format, readfile($'{fname}.bak'))
  assert_match('Configured', execute('messages'))
enddef

# Test for configuring settings.json with the key bindings in the actions
def g:Test_Setup_KeysInActions()
  var fname = common.WriteSettings(new_format[: 4] + new_format[8 :])
  :WtScrollbackSetup
  var json = settings.Decode(settings.Read(fname))
  assert_equal('ctrl+shift+h', Action(json).keys)
  assert_false(json->has_key('keybindings'))
enddef

# Test for settings.json without actions and with the old list of profiles
def g:Test_Setup_NoActions()
  var fname = common.WriteSettings(['{', '    "profiles": [', '        { "name": "cmd" }', '    ]', '}'])
  :WtScrollbackSetup
  var json = settings.Decode(settings.Read(fname))
  assert_equal('ctrl+shift+h', Action(json).keys)
  assert_equal('wt-scrollback.vim', json.profiles[1].name)
enddef

# Test for keeping comments, line endings, the rest of the file and an
# animation setting
def g:Test_Setup_KeepsFile()
  var lines = new_format->copy()
  lines[1] ..= ' // the schema'
  lines->insert('    "disableAnimations": false,', 2)
  var fname = common.WriteSettings(lines->mapnew((_, l) => $"{l}\r"))
  :WtScrollbackSetup
  var text = settings.Read(fname)
  assert_match('"$schema": "https://aka.ms/terminal-profiles-schema", // the schema' .. "\r\n", text)
  assert_equal(-1, text->substitute("\r\n", '', 'g')->stridx("\n"))
  assert_false(settings.Decode(text).disableAnimations)
enddef

# Test for running the setup again
def g:Test_Setup_AlreadyConfigured()
  var fname = common.WriteSettings(new_format)
  :WtScrollbackSetup
  var text = settings.Read(fname)
  :messages clear
  :WtScrollbackSetup
  assert_equal(text, settings.Read(fname))
  assert_match('Windows Terminal already uses it', execute('messages'))
enddef

# Test for a settings.json that can't be read, like while Windows Terminal
# writes it
def g:Test_Setup_Unreadable()
  var fname = common.WriteSettings(['{ "profiles": '])
  :WtScrollbackSetup
  assert_equal(['{ "profiles": '], readfile(fname))
  assert_false(filereadable($'{fname}.bak'))
  assert_match('Could not read', execute('messages'))
enddef

# Test for no settings.json
def g:Test_Setup_NoSettings()
  delete(common.SettingsFile())
  :WtScrollbackSetup
  assert_match('No Windows Terminal settings.json found', execute('messages'))
enddef

# vim: tabstop=8 shiftwidth=2 softtabstop=2 expandtab
