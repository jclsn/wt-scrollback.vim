vim9script

# The helper that reads the scrollback from the clipboard and the cursor from
# the pane, see wt-scrollback.ps1.  It is built from that script into
# %LOCALAPPDATA%\wt-scrollback.vim on first use and whenever the script is
# newer.

const source = expand('<script>:p')->resolve()->fnamemodify(':h:h:h') .. '\wt-scrollback.ps1'

# Return the path of the helper
export def Exe(): string
  var local = empty($LOCALAPPDATA) ? expand('~/AppData/Local') : $LOCALAPPDATA
  return $'{local}\wt-scrollback.vim\wt-scrollback.exe'
enddef

# Start "cmd" without any I/O and call "Done", if given, when it exits
def Job(cmd: list<string>, Done: func())
  job_start(cmd, {in_io: 'null', out_io: 'null', err_io: 'null', exit_cb: (_, _) => {
    if Done != null_function
      Done()
    endif
  }})
enddef

# Build the helper and call "Done", if given, when it is built
export def Build(Done: func() = null_function)
  Job(['powershell.exe', '-NoLogo', '-NoProfile', '-NonInteractive', '-File', source, Exe()], Done)
enddef

# Run the helper with "args" and call "Done" when it is done, building it
# first when needed
export def Run(args: list<string>, Done: func())
  if getftime(Exe()) < getftime(source)
    Build(() => {
      Job([Exe()] + args, Done)
    })
  else
    Job([Exe()] + args, Done)
  endif
enddef

# vim: tabstop=8 shiftwidth=2 softtabstop=2 expandtab
