vim9script

# Tests for the pager's font size following the pane it was opened from

import './common.vim'
import '../autoload/wt_scrollback/font.vim'
import '../autoload/wt_scrollback/settings.vim'

const powershell = '{61c54bbd-c2c6-5271-96e7-009a87ff44bf}'

# Return settings.json lines with the profile of PowerShell and of the pager,
# whose settings are "ps_settings" and "pager_settings"
def SettingsLines(ps_settings: string, pager_settings: string): list<string>
  return [
    '{',
    '    "profiles": {',
    '        "defaults": { "font": { "face": "Mono" } },',
    '        "list": [',
    $'            {{ "guid": "{powershell}"{ps_settings} }},',
    '            {',
    $'                "guid": "{settings.PROFILE_GUID}",',
    $'                "name": "wt-scrollback.vim"{pager_settings}',
    '            }',
    '        ]',
    '    }',
    '}']
enddef

# Return the pager's font in settings.json
def PagerFont(): dict<any>
  var json = settings.Decode(settings.Read(common.SettingsFile()))
  return settings.Profile(settings.Profiles(json)[1], settings.PROFILE_GUID)->get('font', {})
enddef

# Test for the font size of a profile
def g:Test_Size()
  assert_equal(15.0, font.Size({font: {size: 15}}, {font: {size: 11}}))
  assert_equal(13.0, font.Size({fontSize: 13}, {font: {size: 11}}))
  assert_equal(11.0, font.Size({font: {face: 'Mono'}}, {font: {size: 11}}))
  assert_equal(12.0, font.Size({}, {}))
enddef

# Test for working out the zoomed font size from the pane's size
def g:Test_Zoomed()
  # Not zoomed, before and after splitting off 20% of the rows
  assert_equal(12.0, font.Zoomed(12.0, 12.0, [200, 50], [200, 50]))
  assert_equal(12.0, font.Zoomed(12.0, 12.0, [200, 40], [200, 50]))
  # Zoomed in to 15
  assert_equal(15.0, font.Zoomed(12.0, 12.0, [160, 40], [200, 50]))
  assert_equal(15.0, font.Zoomed(12.0, 12.0, [160, 32], [200, 50]))
  # Back to the profile's size, which wins over rounding
  assert_equal(12.0, font.Zoomed(15.0, 12.0, [200, 50], [160, 40]))
  assert_equal(15.0, font.Zoomed(12.0, 15.0, [161, 40], [200, 50]))
  # The pane was split side by side, or the pager isn't zoomed yet
  assert_equal(-1.0, font.Zoomed(12.0, 12.0, [100, 50], [200, 50]))
  assert_equal(-1.0, font.Zoomed(12.0, 12.0, [200, 50], [200, 10]))
  assert_equal(-1.0, font.Zoomed(12.0, 12.0, [], [200, 50]))
enddef

# Test for setting the size on the pager's profile without a font
def g:Test_SetSize_NoFont()
  var text = SettingsLines('', '')->join("\n")
  var result = font.SetSize(text, 14.0)
  assert_match('"name": "wt-scrollback.vim",\n *"font": { "size": 14 }\n', result)
  assert_equal(text, result->substitute(',\n *"font": { "size": 14 }', '', ''))
enddef

# Test for changing the size, and adding it to a font without one
def g:Test_SetSize_Font()
  var text = SettingsLines('', ', "font": { "size": 9, "face": "X" }')->join("\n")
  assert_equal(text->substitute('"size": 9', '"size": 10.5', ''), font.SetSize(text, 10.5))
  text = SettingsLines('', ', "font": { "face": "X" }')->join("\n")
  assert_equal({face: 'X', size: 16}, settings.Decode(font.SetSize(text, 16.0)).profiles.list[1].font)
enddef

# Test for no pager profile
def g:Test_SetSize_NoProfile()
  assert_fails('font.SetSize(''{ "profiles": [] }'', 12.0)', 'no pager profile')
enddef

# Test for the pager taking the size of the pane's profile
def g:Test_Sync_Profile()
  common.WriteSettings(SettingsLines(', "font": { "size": 15 }', ''))
  font.Sync(powershell, [])
  assert_equal({size: 15}, PagerFont())
  # Back to the default
  common.WriteSettings(SettingsLines('', ', "font": { "size": 15 }'))
  font.Sync(powershell, [])
  assert_equal({size: 12}, PagerFont())
enddef

# Test for the pager taking the size of a zoomed pane
def g:Test_Sync_Zoomed()
  common.WriteSettings(SettingsLines('', ''))
  font.Sync(powershell, [float2nr(&columns * 0.8), float2nr(&lines * 0.8)])
  assert_equal({size: 15}, PagerFont())
enddef

# Test for not writing settings.json when the size is right
def g:Test_Sync_Unchanged()
  var lines = SettingsLines('', '')
  var fname = common.WriteSettings(lines)
  setfperm(fname, 'r--r--r--')
  font.Sync(powershell, [&columns, &lines])
  font.Sync('', [])
  setfperm(fname, 'rw-rw-rw-')
  assert_equal(lines, readfile(fname))
  assert_equal('', v:errmsg)
enddef

# vim: tabstop=8 shiftwidth=2 softtabstop=2 expandtab
