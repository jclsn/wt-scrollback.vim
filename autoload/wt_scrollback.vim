vim9script
# Locating Windows Terminal's settings.json and adding the scrollback action,
# key binding and pager profile to it. Also imported by pager.vim, so this must
# not have side effects when sourced.

const ROOT = fnamemodify(resolve(expand('<script>:p')), ':h:h')
export const PAGER = ROOT .. '\pager.vim'
export const HELPER_SOURCE = ROOT .. '\wt-scrollback.ps1'

const ACTION_ID = 'User.WtScrollback'
const PROFILE_GUID = '{7b7965fa-a70a-5652-bcf0-a02e57f39683}'
const PROFILE_NAME = 'wt-scrollback.vim'

export def CacheDir(): string
	return (empty($LOCALAPPDATA) ? expand('~/AppData/Local') : $LOCALAPPDATA) .. '\wt-scrollback.vim'
enddef

# The helper that reads the clipboard and the other panes, built from
# HELPER_SOURCE on first use
export def HelperExe(): string
	return CacheDir() .. '\wt-scrollback.exe'
enddef

# Command that (re)builds the helper when it's missing or older than its
# source, followed by "args" for running it
export def BuildCommand(args: list<string> = []): list<string>
	return ['powershell.exe', '-NoLogo', '-NoProfile', '-NonInteractive', '-File', HELPER_SOURCE,
		HelperExe()] + args
enddef

def DeclinedFile(): string
	return CacheDir() .. '\declined'
enddef

# Windows Terminal's settings.json (stable, then Preview, then unpackaged), or
# '' when there is none
export def SettingsFile(): string
	const local = empty($LOCALAPPDATA) ? expand('~/AppData/Local') : $LOCALAPPDATA
	for file in [
			local .. '\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json',
			local .. '\Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json',
			local .. '\Microsoft\Windows Terminal\settings.json']
		if filereadable(file)
			return file
		endif
	endfor
	return ''
enddef

def InTerminal(): bool
	return has('win32') && !has('gui_running') && !empty($WT_SESSION)
enddef

# settings.json allows comments and trailing commas
def Decode(text: string): dict<any>
	var out: list<string> = []
	var chars = split(text, '\zs')
	var i = 0
	const n = len(chars)
	while i < n
		const c = chars[i]
		if c == '"'
			var j = i + 1
			while j < n && chars[j] != '"'
				j += chars[j] == '\' ? 2 : 1
			endwhile
			out += chars[i : j]
			i = j + 1
			continue
		elseif c == '/' && i + 1 < n && chars[i + 1] == '/'
			while i < n && chars[i] != "\n"
				i += 1
			endwhile
			continue
		elseif c == '/' && i + 1 < n && chars[i + 1] == '*'
			i += 2
			while i + 1 < n && (chars[i] != '*' || chars[i + 1] != '/')
				i += 1
			endwhile
			i += 2
			continue
		endif
		out->add(c)
		i += 1
	endwhile
	try
		return json_decode(join(out, '')->substitute(',\(\_s*[]}]\)', '\1', 'g'))
	catch
		return {}
	endtry
enddef

def IsConfigured(settings: dict<any>): bool
	var profiles = get(settings, 'profiles', [])
	if type(profiles) == v:t_dict
		profiles = get(profiles, 'list', [])
	endif
	const pager = tolower(PAGER)
	return profiles->indexof((_, p) => stridx(tolower(get(p, 'commandline', '')), pager) >= 0) >= 0
		&& get(settings, 'actions', [])->indexof((_, a) => get(a, 'id', '') ==# ACTION_ID) >= 0
enddef

def Str(s: string): string
	return json_encode(s)
enddef

export def Commandline(): string
	return $'"{v:progpath}" -N -u "{PAGER}"'
enddef

def Indent(text: string, ind: string): string
	return text->split("\n")->map((_, l) => ind .. l)->join("\n")
enddef

def ProfileJson(): string
	return join([
		'{',
		$'    "name": {Str(PROFILE_NAME)},',
		$'    "guid": {Str(PROFILE_GUID)},',
		'    "hidden": true,',
		$'    "commandline": {Str(Commandline())},',
		'    "closeOnExit": "always",',
		'    "cursorShape": "filledBox",',
		'    "bellStyle": "none",',
		'    "suppressApplicationTitle": true,',
		'    "tabTitle": "Scrollback"',
		'}'], "\n")
enddef

def ActionJson(keys: string): string
	return join([
		'{',
		'    "command":',
		'    {',
		'        "action": "multipleActions",',
		'        "actions":',
		'        [',
		'            { "action": "selectAll" },',
		'            { "action": "copy", "singleLine": false, "copyFormatting": "html" },',
		$'            {{ "action": "splitPane", "split": "down", "size": 0.2, "profile": {Str(PROFILE_GUID)} }},',
		'            { "action": "togglePaneZoom" }',
		'        ]',
		'    },',
		$'    "id": {Str(ACTION_ID)},'] + (empty(keys) ? [] : [$'    "keys": {Str(keys)},']) + [
		'    "name": "Open scrollback in Vim"',
		'}'], "\n")
enddef

def KeybindingJson(keys: string): string
	return $'{{ "id": {Str(ACTION_ID)}, "keys": {Str(keys)} }}'
enddef

# Positions (character indexes) of the "[" or "{" and the matching bracket of
# every container, by path (".actions", ".profiles.list", ".profiles.list[]",
# ...), in the order they appear
def AllContainers(chars: list<string>): dict<list<list<number>>>
	var found: dict<list<list<number>>> = {}
	var stack: list<dict<any>> = []
	var last_string = ''
	var i = 0
	const n = len(chars)
	while i < n
		const c = chars[i]
		if c == '"'
			var j = i + 1
			var s = ''
			while j < n && chars[j] != '"'
				s ..= chars[j]
				j += chars[j] == '\' ? 2 : 1
			endwhile
			last_string = s
			i = j
		elseif c == '/' && i + 1 < n && chars[i + 1] == '/'
			while i < n && chars[i] != "\n"
				i += 1
			endwhile
		elseif c == '/' && i + 1 < n && chars[i + 1] == '*'
			i += 2
			while i + 1 < n && (chars[i] != '*' || chars[i + 1] != '/')
				i += 1
			endwhile
			i += 1
		elseif c == ':' && !empty(stack)
			stack[-1].key = last_string
		elseif c == ',' && !empty(stack)
			stack[-1].key = ''
		elseif c == '{' || c == '['
			var path = ''
			if !empty(stack)
				path = stack[-1].type == '{' ? stack[-1].path .. '.' .. stack[-1].key : stack[-1].path .. '[]'
			endif
			stack->add({type: c, path: path, key: '', start: i})
		elseif (c == '}' || c == ']') && !empty(stack)
			const top = stack->remove(-1)
			if !found->has_key(top.path)
				found[top.path] = []
			endif
			found[top.path]->add([top.start, i])
		endif
		i += 1
	endwhile
	return found
enddef

# Like AllContainers(), only the first container of each path
def Containers(chars: list<string>): dict<list<number>>
	return AllContainers(chars)->map((_, v) => v[0])
enddef

# Index of the last character between "open" and "close" that isn't
# whitespace or part of a comment, or "open" when there is none
def LastSignificant(chars: list<string>, open: number, close: number): number
	var last = open
	var i = open + 1
	while i < close
		const c = chars[i]
		if c == '"'
			i += 1
			while i < close && chars[i] != '"'
				i += chars[i] == '\' ? 2 : 1
			endwhile
			last = i
		elseif c == '/' && chars[i + 1] == '/'
			while i < close && chars[i] != "\n"
				i += 1
			endwhile
		elseif c == '/' && chars[i + 1] == '*'
			i += 2
			while i + 1 < close && (chars[i] != '*' || chars[i + 1] != '/')
				i += 1
			endwhile
			i += 1
		elseif c !~ '\_s'
			last = i
		endif
		i += 1
	endwhile
	return last
enddef

# [start, end, text]: replacing chars[start : end - 1] with text makes "item"
# the last element of the container from "open" to "close"
def AppendItem(chars: list<string>, open: number, close: number, item: string): list<any>
	const line_start = join(chars[: close - 1], '')->strridx("\n")
	const close_indent = matchstr(join(chars[line_start + 1 : close - 1], ''), '^\s*')
	const last = LastSignificant(chars, open, close)
	const comma = last == open || chars[last] == ',' ? '' : ','
	# Everything after the last element (comments included) stays in front of
	# the new one
	var keep = join(chars[last + 1 : close - 1], '')->substitute('\_s*$', '', '')
	return [last + 1, close, comma .. keep .. "\n" .. Indent(item, close_indent .. '    ') .. "\n" .. close_indent]
enddef

# Without animations the pager pane appears at once, instead of sliding up with
# its focus border from the bottom. Only when it isn't set either way.
def ChangesAnimations(settings: dict<any>): bool
	return !settings->has_key('disableAnimations')
enddef

# settings.json with the pager profile, the action and its key binding added at
# the end of their lists, so they win over earlier ones, and pane animations
# turned off. The rest of the file is left as it is.
def AddToSettings(text: string, settings: dict<any>, keys: string): string
	const crlf = stridx(text, "\r\n") >= 0
	var chars = split(crlf ? substitute(text, "\r\n", "\n", 'g') : text, '\zs')
	const found = Containers(chars)
	if !found->has_key('')
		throw 'not a JSON object'
	endif
	const separate_keys = settings->has_key('keybindings')
	# [start, end, text] replacements, applied from the end
	var edits: list<list<any>> = []

	if found->has_key('.profiles.list')
		const [o, c] = found['.profiles.list']
		edits->add(AppendItem(chars, o, c, ProfileJson()))
	elseif found->has_key('.profiles') && chars[found['.profiles'][0]] == '['
		const [o, c] = found['.profiles']
		edits->add(AppendItem(chars, o, c, ProfileJson()))
	else
		throw 'no profiles list'
	endif

	# New top level entries
	var root_items: list<string> = []
	const action = ActionJson(separate_keys ? '' : keys)
	if found->has_key('.actions')
		const [o, c] = found['.actions']
		edits->add(AppendItem(chars, o, c, action))
	else
		root_items->add("\"actions\":\n[\n" .. Indent(action, '    ') .. "\n],")
	endif
	if ChangesAnimations(settings)
		root_items->add('"disableAnimations": true,')
	endif
	if !empty(root_items)
		const root = found[''][0]
		edits->add([root + 1, root + 1, "\n" .. Indent(join(root_items, "\n"), '    ')])
	endif
	if separate_keys && found->has_key('.keybindings')
		const [o, c] = found['.keybindings']
		edits->add(AppendItem(chars, o, c, KeybindingJson(keys)))
	endif

	for [start, end, replacement] in edits->sort((a, b) => b[0] - a[0])
		chars = (start > 0 ? chars[: start - 1] : []) + split(replacement, '\zs') + chars[end :]
	endfor
	return crlf ? substitute(join(chars, ''), "\n", "\r\n", 'g') : join(chars, '')
enddef

# A profile's font size as Windows Terminal resolves it
def FontSize(profile: dict<any>, defaults: dict<any>): float
	for p in [profile, defaults]
		const font = get(p, 'font', {})
		if type(font) == v:t_dict && font->has_key('size')
			return 0.0 + font.size
		elseif p->has_key('fontSize')
			return 0.0 + p.fontSize
		endif
	endfor
	return 12.0
enddef

# settings.json with the font size of the pager profile set to "size"
def SetFontSize(text: string, size: float): string
	const crlf = stridx(text, "\r\n") >= 0
	var chars = split(crlf ? substitute(text, "\r\n", "\n", 'g') : text, '\zs')
	const all = AllContainers(chars)
	const value = size == trunc(size) ? string(float2nr(size)) : string(size)
	const guid = '"guid"\_s*:\_s*"' .. PROFILE_GUID .. '"'
	for path in ['.profiles.list[]', '.profiles[]']
		for [o, c] in get(all, path, [])
			if join(chars[o : c], '') !~? guid
				continue
			endif
			var edit: list<any>
			const fonts = get(all, path .. '.font', [])->copy()->filter((_, f) => f[0] > o && f[1] < c)
			if empty(fonts)
				edit = AppendItem(chars, o, c, $'"font": {{ "size": {value} }}')
			else
				const [fo, fc] = fonts[0]
				const font = join(chars[fo : fc], '')
				const [_, start, end] = matchstrpos(font, '"size"\_s*:\_s*\zs[-+0-9.eE]\+')
				edit = start < 0 ? AppendItem(chars, fo, fc, $'"size": {value}')
					: [fo + charidx(font, start), fo + charidx(font, end), value]
			endif
			const [start, end, replacement] = edit
			chars = chars[: start - 1] + split(replacement, '\zs') + chars[end :]
			return crlf ? substitute(join(chars, ''), "\n", "\r\n", 'g') : join(chars, '')
		endfor
	endfor
	throw 'no pager profile'
enddef

# Gives the pager profile the font size of the profile with the guid "source",
# so the scrollback looks like the pane it was opened from. Windows Terminal
# applies the change to the open pager right away.
export def SyncFontSize(source: string)
	const file = SettingsFile()
	if empty(source) || empty(file)
		return
	endif
	const text = readfile(file, 'b')->join("\n")
	const settings = Decode(text)
	var profiles = get(settings, 'profiles', [])
	var defaults: dict<any> = {}
	if type(profiles) == v:t_dict
		defaults = get(profiles, 'defaults', {})
		profiles = get(profiles, 'list', [])
	endif
	const ByGuid = (guid) => profiles->copy()->filter((_, p) => type(p) == v:t_dict && get(p, 'guid', '') ==? guid)->get(0, {})
	const pager = ByGuid(PROFILE_GUID)
	const size = FontSize(ByGuid(source), defaults)
	if empty(pager) || source ==? PROFILE_GUID || FontSize(pager, defaults) == size
		return
	endif
	try
		writefile(split(SetFontSize(text, size), "\n", true), file, 'b')
	catch
		echomsg $'wt-scrollback.vim: Could not set the font size: {v:exception}'
	endtry
enddef

def Configure(file: string)
	const text = readfile(file, 'b')->join("\n")
	const settings = Decode(text)
	if empty(settings)
		echoerr $'wt-scrollback.vim: Could not read {file}'
		return
	endif
	var result: string
	try
		result = AddToSettings(text, settings, get(g:, 'wt_scrollback_keys', 'ctrl+shift+h'))
	catch
		echoerr $'wt-scrollback.vim: Could not change {file}: {v:exception}'
		return
	endtry
	const backup = $'{file}.{strftime('%Y%m%d%H%M%S')}.bak'
	if writefile(readfile(file, 'B'), backup) != 0
		echoerr $'wt-scrollback.vim: Could not write {backup}'
		return
	endif
	if writefile(split(result, "\n", true), file, 'b') != 0
		echoerr $'wt-scrollback.vim: Could not write {file}'
		return
	endif
	# Build the helper now, so the first scrollback opens without the wait
	job_start(BuildCommand(), {in_io: 'null', out_io: 'null', err_io: 'null'})
	echomsg $'wt-scrollback.vim: Configured {fnamemodify(file, ':~')} (backup: {fnamemodify(backup, ':t')}),'
		.. ' Windows Terminal reloads it by itself'
enddef

# Offers to add the scrollback pager to Windows Terminal. Without "forced" this
# is silent unless a prompt is actually needed.
export def Setup(forced: bool)
	if !InTerminal()
		if forced
			echomsg 'wt-scrollback.vim: Not running in Windows Terminal'
		endif
		return
	endif
	const file = SettingsFile()
	if empty(file)
		if forced
			echomsg 'wt-scrollback.vim: No Windows Terminal settings.json found'
		endif
		return
	endif
	const settings = Decode(readfile(file, 'b')->join("\n"))
	if IsConfigured(settings)
		if forced
			echomsg $'wt-scrollback.vim: {fnamemodify(file, ':~')} already uses it'
		endif
		return
	endif
	if !forced && filereadable(DeclinedFile())
		return
	endif
	const choice = confirm("wt-scrollback.vim: Use Vim as Windows Terminal's scrollback pager?\n"
		.. $"This adds an action, a key binding and a profile to {fnamemodify(file, ':~')}"
		.. (ChangesAnimations(settings) ? "\nand turns off pane animations." : '.'),
		"&Yes\n&No\nNever &ask again", 1, 'Question')
	if choice == 1
		Configure(file)
		delete(DeclinedFile())
	elseif choice == 3
		mkdir(CacheDir(), 'p')
		writefile([], DeclinedFile())
		echomsg 'wt-scrollback.vim: Won''t ask again, use :WtScrollbackSetup to configure it later'
	endif
enddef
