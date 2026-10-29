vim9script

# Common routines used by the tests

# Wait up to "timeout" milliseconds for "Assert" to pass.  "Assert" must be a
# lambda containing one assert function.  Returns zero for success, one for
# failure (like the assert functions).
export def WaitForAssert(Assert: func(): number, timeout = 2000): number
  var start = reltime()
  while true
    var errors_len = v:errors->len()
    if Assert() == 0
      return 0
    endif
    if start->reltime()->reltimefloat() * 1000 > timeout
      return 1
    endif
    # Retry without the error of this attempt
    v:errors->remove(errors_len, -1)
    sleep 10m
  endwhile
  return 1
enddef

# Create a new temporary directory and return its path
export def TempDir(): string
  var dir = tempname()
  mkdir(dir, 'p')
  return dir
enddef

# Return the settings.json of an unpackaged Windows Terminal, which the tests
# use, as $LOCALAPPDATA is a directory of their own
export def SettingsFile(): string
  return $'{$LOCALAPPDATA}\Microsoft\Windows Terminal\settings.json'
enddef

# Write "lines" to the settings.json the tests use and return its path
export def WriteSettings(lines: list<string>): string
  var fname = SettingsFile()
  mkdir(fname->fnamemodify(':h'), 'p')
  writefile(lines, fname)
  delete($'{fname}.bak')
  return fname
enddef

# vim: tabstop=8 shiftwidth=2 softtabstop=2 expandtab
