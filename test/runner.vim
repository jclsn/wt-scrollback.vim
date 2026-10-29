vim9script

# Script to run the tests.  The global variable TestName must be set to the
# name of the file containing the tests, the results go to results.txt.

# Run all the Test_* functions and return the results
def RunTests(): list<string>
  :set nomore
  :set debug=beep

  var results: list<string> = []
  var fns: list<string> = execute('function /^Test_')
    ->split("\n")
    ->map((_, v) => v->substitute('^\(def\|func\)\s\+\(Test_\w\+\).*', '\2', ''))
    ->filter((_, v) => v =~ '^Test_')
    ->sort()
  if fns->empty()
    return [$'[FAIL] No tests found in {g:TestName}']
  endif

  # Align the results after the longest test name, of all the test files when
  # run_tests.ps1 sets g:TestNameWidth
  var width = get(g:, 'TestNameWidth', fns->mapnew((_, f) => f->len())->max())

  for f in fns
    v:errors = []
    v:errmsg = ''
    try
      silent! :%bwipeout!
      exe $'call {f}()'
    catch
      add(v:errors, $'EXCEPTION: {f} -> {v:exception} at {v:throwpoint}')
    endtry

    if v:errmsg != ''
      add(v:errors, $'ERROR: {f} generated {v:errmsg}')
    endif

    if v:errors->empty()
      add(results, printf('%-*s [PASS]', width, f))
    else
      add(results, printf('%-*s [FAIL]', width, f))
      extend(results, v:errors->mapnew((_, e) => $'    {e}'))
    endif
  endfor
  return results
enddef

# Source the test file, run its tests and exit
def Main()
  var results: list<string> = []
  try
    exe $'source {g:TestName}'
    results = RunTests()
  catch
    results = [$'[FAIL] Exception in {g:TestName}: {v:exception} at {v:throwpoint}']
  endtry

  if exists('*g:TestCleanup')
    g:TestCleanup()
  endif
  writefile(results, 'results.txt')
  qall!
enddef

# Run once Vim has started, like the pager does.  ++nested lets the tests
# trigger autocommands.
autocmd VimEnter * ++once ++nested Main()

# vim: tabstop=8 shiftwidth=2 softtabstop=2 expandtab
