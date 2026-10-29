vim9script

# Tests for reading and editing Windows Terminal's settings.json

import './common.vim'
import '../autoload/wt_scrollback/settings.vim'

const sample = [
  '// Comment with "quotes" and a { brace',
  '{',
  '    "url": "https://example.com/a,]",',
  '    /* block',
  '       comment */',
  '    "list": [ 1, 2, ],',
  '    "profiles": {',
  '        "defaults": { "font": { "size": 11 } },',
  '        "list": [',
  '            { "guid": "{A}", "name": "\"quoted\"" },',
  '            { "guid": "{B}" }, // last',
  '        ],',
  '    },',
  '}']->join("\n")

# Test for comments, trailing commas and strings that look like either
def g:Test_Decode()
  var json = settings.Decode(sample)
  assert_equal('https://example.com/a,]', json.url)
  assert_equal([1, 2], json.list)
  assert_equal('"quoted"', json.profiles.list[0].name)
enddef

# Test for text that isn't a JSON object
def g:Test_Decode_Invalid()
  assert_equal({}, settings.Decode('{ "profiles": '))
  assert_equal({}, settings.Decode('[1, 2]'))
  assert_equal({}, settings.Decode(''))
enddef

# Test for the profile defaults and list, also from the old format
def g:Test_Profiles()
  var [defaults, profiles] = settings.Profiles(settings.Decode(sample))
  assert_equal({font: {size: 11}}, defaults)
  assert_equal(2, len(profiles))
  assert_equal([{}, [{guid: '{C}'}]], settings.Profiles({profiles: [{guid: '{C}'}]}))
  assert_equal([{}, []], settings.Profiles({}))
  assert_equal({guid: '{B}'}, settings.Profile(profiles, '{b}'))
  assert_equal({}, settings.Profile(profiles, '{X}'))
enddef

# Test for finding the containers, without the brackets in comments and strings
def g:Test_Containers()
  var containers = settings.Containers(sample)
  assert_equal(['', '.list', '.profiles', '.profiles.defaults', '.profiles.defaults.font',
    '.profiles.list', '.profiles.list[]'], containers->keys()->sort())
  var [open, close] = containers['.profiles.list'][0]
  assert_equal('[', strpart(sample, open, 1))
  assert_equal(']', strpart(sample, close, 1))
  var items = containers['.profiles.list[]']
  assert_equal(2, len(items))
  assert_equal('{ "guid": "{B}" }', strpart(sample, items[1][0], items[1][1] - items[1][0] + 1))
enddef

# Test for appending to a list: after its trailing comma and comment, with its
# indent
def g:Test_AppendItem()
  var [open, close] = settings.Containers(sample)['.profiles.list'][0]
  var result = settings.Apply(sample, [settings.AppendItem(sample, open, close, "{\n    \"guid\": \"{C}\"\n}")])
  assert_equal([
    '            { "guid": "{B}" }, // last',
    '            {',
    '                "guid": "{C}"',
    '            }',
    '        ],'], result->split("\n")[10 : 14])
  assert_equal('{C}', settings.Decode(result).profiles.list[2].guid)
enddef

# Test for appending to a list without a trailing comma, and to an empty one
def g:Test_AppendItem_Comma()
  var text = "{\n  \"a\": [ 1 ],\n  \"b\": []\n}"
  var containers = settings.Containers(text)
  var result = settings.Apply(text, [
    settings.AppendItem(text, containers['.a'][0][0], containers['.a'][0][1], '2'),
    settings.AppendItem(text, containers['.b'][0][0], containers['.b'][0][1], '3')])
  assert_equal({a: [1, 2], b: [3]}, settings.Decode(result))
enddef

# Test for keeping Windows line endings
def g:Test_AppendItem_Crlf()
  var text = "{\r\n  \"a\": [\r\n    1\r\n  ]\r\n}"
  var [open, close] = settings.Containers(text)['.a'][0]
  var result = settings.Apply(text, [settings.AppendItem(text, open, close, '2')])
  assert_equal("{\r\n  \"a\": [\r\n    1,\r\n      2\r\n  ]\r\n}", result)
enddef

# Test for writing and reading back a file as it is
def g:Test_ReadWrite()
  var fname = $'{common.TempDir()}\settings.json'
  for text in ["{\r\n}", "{\n}\n", '{}']
    settings.Write(text, fname)
    assert_equal(text, settings.Read(fname))
  endfor
enddef

# Test for finding the settings.json the tests use
def g:Test_File()
  delete(common.SettingsFile())
  assert_equal('', settings.File())
  var fname = common.WriteSettings(['{}'])
  assert_equal(fname, settings.File())
enddef

# vim: tabstop=8 shiftwidth=2 softtabstop=2 expandtab
