# wt-scrollback.vim: builds the pager's helper.
#
# Usage: wt-scrollback.ps1 <helper exe>
#
# The helper needs Win32 calls that Vim script can't make and has to parse
# megabytes of HTML quickly, so the C# below is compiled once into a
# console-less exe, which the pager runs directly.  The exe
#   - reads the cursor and the visible rows of the other panes' consoles (each
#     pane is a ConPTY whose buffer mirrors what the pane shows),
#   - reads the "HTML Format" data of the scrollback action's copy from the
#     clipboard,
#   - finds the pane we came from by its rows, and that pane's profile
#     (WT_PROFILE_ID in its shell's environment),
#   - writes a line of JSON with the colors, styles, view and cursor, a line
#     with the ranges of the styles in the lines on the screen, one with the
#     other ranges, and then the lines of the scrollback.  So Vim can show the
#     screen before decoding most of the ranges, and reads the lines much
#     faster as they are than as JSON.
#
#   wt-scrollback.exe <vim pid> <output file>
#   wt-scrollback.exe --html <html file> <output file> [<pane file>]
#
# The second form is for the tests: the HTML comes from a file instead of the
# clipboard, and the only pane from <pane file>, whose first line is
# "<width> <cursor x> <cursor y> [<profile>]" and whose other lines are its
# rows.

$ErrorActionPreference = 'Stop'

$source = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class WtScrollback
{
    public static int Main(string[] args)
    {
        string html, output;
        var panes = new List<Pane>();
        if (args[0] == "--html")
        {
            html = File.ReadAllText(args[1], Encoding.UTF8);
            output = args[2];
            if (args.Length > 3) panes.Add(ReadPane(args[3]));
        }
        else
        {
            output = args[1];
            // First, as Windows Terminal may still be setting the clipboard
            try { panes = Probe(SiblingShells(uint.Parse(args[0]))); }
            catch (Exception) { }
            html = Encoding.UTF8.GetString(ReadHtml(1500));
        }
        File.WriteAllText(output, Convert(html, panes), new UTF8Encoding(false));
        return 0;
    }

    // ---- Clipboard -----------------------------------------------------------

    [DllImport("user32.dll")] static extern bool OpenClipboard(IntPtr owner);
    [DllImport("user32.dll")] static extern bool CloseClipboard();
    [DllImport("user32.dll")] static extern bool EmptyClipboard();
    [DllImport("user32.dll")] static extern IntPtr GetClipboardData(uint format);
    [DllImport("user32.dll")] static extern bool IsClipboardFormatAvailable(uint format);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern uint RegisterClipboardFormat(string name);
    [DllImport("kernel32.dll")] static extern IntPtr GlobalLock(IntPtr mem);
    [DllImport("kernel32.dll")] static extern bool GlobalUnlock(IntPtr mem);
    [DllImport("kernel32.dll")] static extern UIntPtr GlobalSize(IntPtr mem);

    // Windows Terminal sets the clipboard asynchronously, so poll until the
    // HTML shows up.  Emptying it afterwards guarantees we never pick up a
    // stale copy next time (and drops the whole scrollback from the clipboard).
    static byte[] ReadHtml(int timeoutMs)
    {
        uint format = RegisterClipboardFormat("HTML Format");
        var clock = Stopwatch.StartNew();
        while (clock.ElapsedMilliseconds < timeoutMs)
        {
            if (IsClipboardFormatAvailable(format) && OpenClipboard(IntPtr.Zero))
            {
                try
                {
                    IntPtr mem = GetClipboardData(format);
                    if (mem != IntPtr.Zero)
                    {
                        var data = new byte[(int)GlobalSize(mem).ToUInt64()];
                        Marshal.Copy(GlobalLock(mem), data, 0, data.Length);
                        GlobalUnlock(mem);
                        EmptyClipboard();
                        int end = Array.IndexOf(data, (byte)0);
                        if (end >= 0) Array.Resize(ref data, end);
                        return data;
                    }
                }
                finally { CloseClipboard(); }
            }
            Thread.Sleep(5);
        }
        return new byte[0];
    }

    // ---- Other panes' consoles -----------------------------------------------

    [DllImport("kernel32.dll")] static extern bool FreeConsole();
    [DllImport("kernel32.dll")] static extern bool AttachConsole(uint pid);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr CreateFile(string name, uint access, uint share, IntPtr sec, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll")] static extern bool GetConsoleScreenBufferInfo(IntPtr console, out CSBI info);
    [DllImport("kernel32.dll", EntryPoint = "ReadConsoleOutputCharacterW", CharSet = CharSet.Unicode)]
    static extern bool ReadConsoleOutputCharacter(IntPtr console, [Out] char[] buf, uint length, COORD start, out uint read);
    [DllImport("kernel32.dll")] static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint pid);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32FirstW(IntPtr snap, ref PROCESSENTRY32 entry);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32NextW(IntPtr snap, ref PROCESSENTRY32 entry);
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll")] static extern bool ReadProcessMemory(IntPtr proc, IntPtr addr, byte[] buf, IntPtr size, out IntPtr read);
    [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr proc, int cls, ref PROCESS_BASIC_INFORMATION info, int size, out int len);

    [StructLayout(LayoutKind.Sequential)] struct COORD { public short X, Y; }
    [StructLayout(LayoutKind.Sequential)] struct SMALL_RECT { public short Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] struct CSBI { public COORD Size, Cursor; public ushort Attributes; public SMALL_RECT Window; public COORD MaxSize; }
    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_BASIC_INFORMATION { public IntPtr ExitStatus, PebBaseAddress, AffinityMask, BasePriority, UniqueProcessId, InheritedFromUniqueProcessId; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct PROCESSENTRY32
    {
        public uint dwSize, cntUsage, th32ProcessID;
        public IntPtr th32DefaultHeapID;
        public uint th32ModuleID, cntThreads, th32ParentProcessID;
        public int pcPriClassBase;
        public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szExeFile;
    }

    // A pane's size, cursor and visible rows.  Its profile is only read for
    // the pane we came from.
    class Pane
    {
        public uint Pid;
        public int Width, CursorX, CursorY;
        public string[] Rows;
        string profile;
        public string Profile { get { return profile ?? (profile = ProfileOf(Pid)); } set { profile = value; } }
    }

    static Pane ReadPane(string file)
    {
        string[] lines = File.ReadAllLines(file, Encoding.UTF8);
        string[] head = lines[0].Split(' ');
        var rows = new string[lines.Length - 1];
        Array.Copy(lines, 1, rows, 0, rows.Length);
        return new Pane { Width = int.Parse(head[0]), CursorX = int.Parse(head[1]), CursorY = int.Parse(head[2]),
                          Profile = head.Length > 3 ? head[3] : "", Rows = rows };
    }

    // The other processes that the Windows Terminal process which started
    // Vim started: the shells of the other panes.
    static List<uint> SiblingShells(uint vimPid)
    {
        var procs = new List<PROCESSENTRY32>();
        uint terminal = 0;
        IntPtr snap = CreateToolhelp32Snapshot(2, 0); // TH32CS_SNAPPROCESS
        var entry = new PROCESSENTRY32 { dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32)) };
        for (bool ok = Process32FirstW(snap, ref entry); ok; ok = Process32NextW(snap, ref entry))
        {
            procs.Add(entry);
            if (entry.th32ProcessID == vimPid) terminal = entry.th32ParentProcessID;
        }
        CloseHandle(snap);
        var result = new List<uint>();
        foreach (var p in procs)
            if (p.th32ParentProcessID == terminal && p.th32ProcessID != vimPid
                && !p.szExeFile.Equals("OpenConsole.exe", StringComparison.OrdinalIgnoreCase)
                && !p.szExeFile.Equals("conhost.exe", StringComparison.OrdinalIgnoreCase))
                result.Add(p.th32ProcessID);
        return result;
    }

    static List<Pane> Probe(List<uint> pids)
    {
        var panes = new List<Pane>();
        foreach (uint pid in pids)
        {
            FreeConsole();
            if (!AttachConsole(pid)) continue;
            IntPtr con = CreateFile("CONOUT$", 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
            CSBI info;
            if (con != new IntPtr(-1) && GetConsoleScreenBufferInfo(con, out info))
            {
                var win = info.Window;
                var pane = new Pane { Pid = pid, Width = win.Right - win.Left + 1, CursorX = info.Cursor.X - win.Left,
                                      CursorY = info.Cursor.Y - win.Top, Rows = new string[win.Bottom - win.Top + 1] };
                var buf = new char[pane.Width];
                for (int y = 0; y < pane.Rows.Length; y++)
                {
                    uint read;
                    ReadConsoleOutputCharacter(con, buf, (uint)pane.Width, new COORD { X = win.Left, Y = (short)(win.Top + y) }, out read);
                    pane.Rows[y] = new string(buf, 0, (int)read).TrimEnd(' ', '\0');
                }
                panes.Add(pane);
            }
            CloseHandle(con);
        }
        FreeConsole();
        return panes;
    }

    static byte[] ReadMemory(IntPtr proc, IntPtr addr, int size)
    {
        var buf = new byte[size];
        IntPtr read;
        return ReadProcessMemory(proc, addr, buf, new IntPtr(size), out read) ? buf : null;
    }

    static long ReadPointer(IntPtr proc, IntPtr addr)
    {
        byte[] buf = ReadMemory(proc, addr, IntPtr.Size);
        return buf == null ? 0 : IntPtr.Size == 8 ? BitConverter.ToInt64(buf, 0) : BitConverter.ToInt32(buf, 0);
    }

    // Windows Terminal puts the guid of a pane's profile into the environment
    // of the process it starts in it: PEB -> process parameters -> environment.
    static string ProfileOf(uint pid)
    {
        IntPtr proc = OpenProcess(0x1010, false, pid); // QUERY_LIMITED_INFORMATION | VM_READ
        if (proc == IntPtr.Zero) return "";
        try
        {
            var info = new PROCESS_BASIC_INFORMATION();
            int len;
            if (NtQueryInformationProcess(proc, 0, ref info, Marshal.SizeOf(info), out len) != 0) return "";
            bool x64 = IntPtr.Size == 8;
            var parameters = new IntPtr(ReadPointer(proc, info.PebBaseAddress + (x64 ? 0x20 : 0x10)));
            if (parameters == IntPtr.Zero) return "";
            long env = ReadPointer(proc, parameters + (x64 ? 0x80 : 0x48));
            long size = Math.Min(ReadPointer(proc, parameters + (x64 ? 0x3F0 : 0x290)), 1 << 20);
            byte[] block = env == 0 ? null : ReadMemory(proc, new IntPtr(env), (int)size);
            if (block == null) return "";
            // Variables are separated by NULs
            string vars = "\0" + Encoding.Unicode.GetString(block);
            const string name = "\0WT_PROFILE_ID=";
            int start = vars.IndexOf(name, StringComparison.OrdinalIgnoreCase);
            if (start < 0) return "";
            start += name.Length;
            int end = vars.IndexOf('\0', start);
            return vars.Substring(start, (end < 0 ? vars.Length : end) - start);
        }
        finally { CloseHandle(proc); }
    }

    // ---- HTML -> lines + highlight ranges --------------------------------------
    // Windows Terminal's HTML: <DIV STYLE="...background-color:#..."> followed
    // by <SPAN STYLE="color:..;background-color:..;font-weight:bold;..">text</SPAN>
    // runs, rows separated by <BR> (a SPAN may continue across a <BR>).

    class Style
    {
        public string Fg = "", Bg = "";
        public bool Bold, Italic, Underline, Strike;
        public bool IsDefault { get { return Fg == "" && Bg == "" && !Bold && !Italic && !Underline && !Strike; } }
        public string Key { get { return Fg + "|" + Bg + "|" + Bold + Italic + Underline + Strike; } }
    }

    // The text html[Start, Start + Length) and the SPAN it is in
    struct Run { public int Start, Length, Tag; }

    static Style ParseStyle(string attrs)
    {
        var s = new Style();
        int start = attrs.IndexOf("STYLE=\"", StringComparison.OrdinalIgnoreCase);
        int end = start < 0 ? -1 : attrs.IndexOf('"', start + 7);
        if (end < 0) return s;
        foreach (string decl in attrs.Substring(start + 7, end - start - 7).Split(';'))
        {
            int colon = decl.IndexOf(':');
            if (colon < 0) continue;
            string key = decl.Substring(0, colon).Trim().ToLowerInvariant(), value = decl.Substring(colon + 1).Trim();
            if (key == "color") s.Fg = value;
            else if (key == "background-color") s.Bg = value;
            else if (key == "font-weight") s.Bold = value.Contains("bold");
            else if (key == "font-style") s.Italic = value.Contains("italic");
            else if (key == "text-decoration") { s.Underline = value.Contains("underline"); s.Strike = value.Contains("line-through"); }
        }
        return s;
    }

    // Is html[i, end) the tag name "name", not followed by a letter?
    static bool IsTag(string html, int i, int end, string name)
    {
        return end - i >= name.Length && string.Compare(html, i, name, 0, name.Length, StringComparison.OrdinalIgnoreCase) == 0
            && (end - i == name.Length || !char.IsLetter(html[i + name.Length]));
    }

    // Append html[start, start + length) to "sb", decoding the few entities
    // Windows Terminal writes and numeric ones
    static void AppendText(StringBuilder sb, string html, int start, int length)
    {
        int end = start + length;
        int amp = html.IndexOf('&', start, length);
        while (amp >= 0)
        {
            sb.Append(html, start, amp - start);
            int semi = html.IndexOf(';', amp, Math.Min(end - amp, 10));
            string name = semi < 0 ? "" : html.Substring(amp + 1, semi - amp - 1);
            int code;
            if (name == "lt") sb.Append('<');
            else if (name == "gt") sb.Append('>');
            else if (name == "amp") sb.Append('&');
            else if (name == "quot") sb.Append('"');
            else if (name == "apos") sb.Append('\'');
            else if (name == "nbsp") sb.Append(' ');
            else if (name.StartsWith("#x") && int.TryParse(name.Substring(2), System.Globalization.NumberStyles.HexNumber, null, out code)) sb.Append(char.ConvertFromUtf32(code));
            else if (name.StartsWith("#") && int.TryParse(name.Substring(1), out code)) sb.Append(char.ConvertFromUtf32(code));
            else { sb.Append('&'); semi = amp; } // not an entity
            start = semi + 1;
            amp = start < end ? html.IndexOf('&', start, end - start) : -1;
        }
        sb.Append(html, start, end - start);
    }

    // The UTF-8 length of sb[start, end): Vim's text properties count bytes
    static int Utf8Length(StringBuilder sb, int start, int end)
    {
        int n = 0;
        for (int i = start; i < end; i++)
        {
            char c = sb[i];
            n += c < 0x80 ? 1 : c < 0x800 || char.IsSurrogate(c) ? 2 : 3;
        }
        return n;
    }

    // The index of "value" in "values", which it is added to when missing
    static int Id(Dictionary<string, int> ids, List<string> values, string value)
    {
        int id;
        if (!ids.TryGetValue(value, out id)) { id = ids[value] = values.Count; values.Add(value); }
        return id;
    }

    // The index with the highest count, index 0 doesn't count.  "fallback"
    // when there is none or on a tie.
    static int Most(int[] counts, int fallback)
    {
        int best = fallback;
        for (int i = 1; i < counts.Length; i++) if (counts[i] > counts[best]) best = i;
        return best;
    }

    static string Convert(string html, List<Pane> panes)
    {
        int pos = 0, stop = html.Length;
        int fragment = html.IndexOf("<!--StartFragment", StringComparison.Ordinal);
        int fragmentEnd = html.IndexOf("<!--EndFragment", StringComparison.Ordinal);
        if (fragment >= 0 && fragmentEnd > fragment)
        {
            pos = html.IndexOf("-->", fragment, StringComparison.Ordinal) + 3;
            stop = fragmentEnd;
        }

        // The runs, the first run of each row, and the attributes of each SPAN
        // (the same few repeat all over) with how many characters they cover
        var runs = new List<Run>();
        var rowStarts = new List<int> { 0 };
        var tags = new List<string> { "" };
        var tagIds = new Dictionary<string, int> { { "", 0 } };
        var chars = new List<int> { 0 };
        int tag = 0, lastSpan = 0;
        var div = new Style();
        while (pos < stop)
        {
            int lt = html.IndexOf('<', pos, stop - pos);
            int textEnd = lt < 0 ? stop : lt;
            if (textEnd > pos)
            {
                runs.Add(new Run { Start = pos, Length = textEnd - pos, Tag = tag });
                chars[tag] += textEnd - pos;
            }
            if (lt < 0) break;
            int gt = html.IndexOf('>', lt, stop - lt);
            if (gt < 0) break;
            bool close = html[lt + 1] == '/';
            int name = close ? lt + 2 : lt + 1;
            if (IsTag(html, name, gt, "BR")) rowStarts.Add(runs.Count);
            else if (IsTag(html, name, gt, "SPAN"))
            {
                if (close) tag = 0;
                else
                {
                    int start = name + 4, length = gt - start;
                    string last = tags[lastSpan];
                    if (last.Length == length && string.CompareOrdinal(html, start, last, 0, length) == 0) tag = lastSpan;
                    else
                    {
                        string attrs = html.Substring(start, length);
                        if (!tagIds.TryGetValue(attrs, out tag))
                        {
                            tag = tagIds[attrs] = tags.Count;
                            tags.Add(attrs);
                            chars.Add(0);
                        }
                    }
                    lastSpan = tag;
                }
            }
            else if (IsTag(html, name, gt, "DIV") && !close) div = ParseStyle(html.Substring(name + 3, gt - name - 3));
            pos = gt + 1;
        }

        // The colors of each tag; text without colors of its own uses the DIV's
        int count = tags.Count;
        var raw = new Style[count];
        var colors = new List<string>();
        var colorIds = new Dictionary<string, int>();
        var fgOf = new int[count];
        var bgOf = new int[count];
        Id(colorIds, colors, "");
        int divFg = Id(colorIds, colors, div.Fg), divBg = Id(colorIds, colors, div.Bg);
        for (int t = 0; t < count; t++)
        {
            raw[t] = ParseStyle(tags[t]);
            fgOf[t] = raw[t].Fg == "" ? divFg : Id(colorIds, colors, raw[t].Fg);
            bgOf[t] = raw[t].Bg == "" ? divBg : Id(colorIds, colors, raw[t].Bg);
        }

        // Vim's background is the one most of the captured cells have, which
        // is not the terminal's when e.g. a full screen program filled the
        // screen with its own.  Its foreground is the one most used on it.
        var bgCount = new int[colors.Count];
        for (int t = 0; t < count; t++) bgCount[bgOf[t]] += chars[t];
        int defBg = Most(bgCount, divBg);
        var fgCount = new int[colors.Count];
        for (int t = 0; t < count; t++) if (bgOf[t] == defBg) fgCount[fgOf[t]] += chars[t];
        int defFg = Most(fgCount, divFg);

        // Tag -> index into styles, -1 for the default colors
        var styles = new List<Style>();
        var index = new int[count];
        var byKey = new Dictionary<string, int>();
        for (int t = 0; t < count; t++)
        {
            var s = new Style { Fg = fgOf[t] == defFg ? "" : colors[fgOf[t]], Bg = bgOf[t] == defBg ? "" : colors[bgOf[t]],
                                Bold = raw[t].Bold, Italic = raw[t].Italic, Underline = raw[t].Underline, Strike = raw[t].Strike };
            int idx = -1;
            if (!s.IsDefault && !byKey.TryGetValue(s.Key, out idx))
            {
                styles.Add(s);
                idx = byKey[s.Key] = styles.Count - 1;
            }
            index[t] = idx;
        }

        // The lines and the byte ranges of each style.  Blank cells with the
        // default background at the end of a row and empty rows at the end are
        // dropped.
        var lines = new List<string>(rowStarts.Count);
        var props = new List<int>[styles.Count]; // line, start, end column
        var sb = new StringBuilder();
        var starts = new List<int>();
        rowStarts.Add(runs.Count);
        for (int r = 0; r + 1 < rowStarts.Count; r++)
        {
            int first = rowStarts[r], end = rowStarts[r + 1];
            sb.Clear();
            starts.Clear();
            for (int i = first; i < end; i++)
            {
                starts.Add(sb.Length);
                AppendText(sb, html, runs[i].Start, runs[i].Length);
            }
            starts.Add(sb.Length);

            int textEnd = 0;
            for (int k = end - first - 1; k >= 0; k--)
            {
                int idx = index[runs[first + k].Tag], j = starts[k + 1];
                if (idx < 0 || styles[idx].Bg == "")
                    while (j > starts[k] && sb[j - 1] == ' ') j--;
                if (j > starts[k]) { textEnd = j; break; }
            }

            int lnum = lines.Count + 1, col = 1;
            for (int k = 0; k < end - first && starts[k] < textEnd; k++)
            {
                int n = Utf8Length(sb, starts[k], Math.Min(starts[k + 1], textEnd)), idx = index[runs[first + k].Tag];
                if (idx >= 0 && n > 0)
                {
                    var p = props[idx] ?? (props[idx] = new List<int>());
                    // Continue the range of the previous run when it has the
                    // same style
                    if (p.Count > 0 && p[p.Count - 3] == lnum && p[p.Count - 1] == col) p[p.Count - 1] = col + n;
                    else { p.Add(lnum); p.Add(col); p.Add(col + n); }
                }
                col += n;
            }
            lines.Add(sb.ToString(0, textEnd));
        }
        while (lines.Count > 1 && lines[lines.Count - 1] == "") lines.RemoveAt(lines.Count - 1);

        View view = Locate(lines, panes);

        var json = new StringBuilder(stop - pos);
        Str(json.Append("{\"fg\":"), colors[defFg]);
        Str(json.Append(",\"bg\":"), colors[defBg]);
        json.Append(",\"styles\":[");
        for (int i = 0; i < styles.Count; i++)
        {
            var s = styles[i];
            Str(json.Append(i > 0 ? ",{\"fg\":" : "{\"fg\":"), s.Fg);
            Str(json.Append(",\"bg\":"), s.Bg);
            json.Append(",\"bold\":").Append(s.Bold ? "true" : "false")
                .Append(",\"italic\":").Append(s.Italic ? "true" : "false")
                .Append(",\"underline\":").Append(s.Underline ? "true" : "false")
                .Append(",\"strike\":").Append(s.Strike ? "true" : "false").Append('}');
        }
        json.Append(']');
        if (view != null)
        {
            json.Append(",\"cursor\":[").Append(view.Lnum).Append(',').Append(view.Col)
                .Append("],\"topline\":").Append(view.Topline)
                .Append(",\"size\":[").Append(view.Pane.Width).Append(',').Append(view.Pane.Rows.Length).Append(']');
            if (view.Pane.Profile != "") Str(json.Append(",\"profile\":"), view.Pane.Profile);
        }
        json.Append("}\n");

        // The ranges in the lines on the screen first, so that Vim can show
        // the screen before it has decoded the rest
        int near = view != null ? view.Topline : Math.Max(1, lines.Count - 199);
        int nearEnd = view != null ? view.Topline + view.Pane.Rows.Length : lines.Count + 1;
        AppendProps(json, props, near, nearEnd, true).Append('\n');
        AppendProps(json, props, near, nearEnd, false);
        foreach (string line in lines) json.Append('\n').Append(line);
        return json.ToString();
    }

    // Append the ranges of each style in "props" in lines "first" to "end"
    // (exclusive), or with "inside" false the other ones, as a JSON list of
    // lists of [line, column, line, end column]
    static StringBuilder AppendProps(StringBuilder json, List<int>[] props, int first, int end, bool inside)
    {
        json.Append('[');
        for (int i = 0; i < props.Length; i++)
        {
            json.Append(i > 0 ? ",[" : "[");
            bool any = false;
            for (int k = 0; props[i] != null && k < props[i].Count; k += 3)
            {
                int lnum = props[i][k];
                if ((lnum >= first && lnum < end) != inside) continue;
                json.Append(any ? ",[" : "[").Append(lnum).Append(',').Append(props[i][k + 1])
                    .Append(',').Append(lnum).Append(',').Append(props[i][k + 2]).Append(']');
                any = true;
            }
            json.Append(']');
        }
        return json.Append(']');
    }

    // ---- Cursor position -------------------------------------------------------

    class View { public Pane Pane; public int Lnum, Col, Topline; }

    // Find the pane whose visible rows match the end of "lines" and map its
    // cursor into "lines" (1-based line, screen column) and the line at its
    // top.  Null when no pane matches at least half of its rows.
    static View Locate(List<string> lines, List<Pane> panes)
    {
        double bestScore = 0;
        int bestTop = 0;
        Pane best = null;
        List<int[]> bestRows = null;
        foreach (var pane in panes)
        {
            int wanted = 0;
            foreach (var r in pane.Rows) if (r != "") wanted++;
            if (wanted == 0 || pane.Width <= 0) continue;
            // Terminal rows ([line index, char offset]) covering the last
            // screenful; long lines wrap at the pane width.
            var rows = new List<int[]>();
            for (int i = lines.Count - 1; i >= 0 && rows.Count < pane.Rows.Length; i--)
                for (int off = (Math.Max(lines[i].Length, 1) - 1) / pane.Width * pane.Width; off >= 0; off -= pane.Width)
                    rows.Add(new[] { i, off });
            rows.Reverse();
            for (int top = Math.Max(0, rows.Count - pane.Rows.Length); top <= rows.Count; top++)
            {
                int score = 0;
                for (int k = 0; k < pane.Rows.Length && top + k < rows.Count; k++)
                {
                    string want = pane.Rows[k];
                    if (want == "") continue;
                    var r = rows[top + k];
                    string line = lines[r[0]];
                    // The row without its trailing blanks
                    int len = Math.Min(pane.Width, line.Length - r[1]);
                    while (len > 0 && line[r[1] + len - 1] == ' ') len--;
                    if (len == want.Length && string.CompareOrdinal(line, r[1], want, 0, len) == 0) score++;
                }
                if ((double)score / wanted > bestScore)
                {
                    bestScore = (double)score / wanted; bestTop = top; best = pane; bestRows = rows;
                }
            }
        }
        if (best == null || bestScore < 0.5) return null;

        int row = bestTop + best.CursorY, lnum, offset = 0;
        if (row < bestRows.Count) { lnum = bestRows[row][0]; offset = bestRows[row][1]; }
        else
        {   // The cursor is on a blank row below the copied text
            lnum = lines.Count - 1 + (row - bestRows.Count + 1);
            while (lines.Count <= lnum) lines.Add("");
        }
        return new View { Pane = best, Lnum = lnum + 1, Col = offset + best.CursorX + 1,
                          Topline = bestTop < bestRows.Count ? bestRows[bestTop][0] + 1 : lnum + 1 };
    }

    // Append "s" as a JSON string
    static StringBuilder Str(StringBuilder json, string s)
    {
        json.Append('"');
        int start = 0;
        for (int i = 0; i < s.Length; i++)
        {
            char c = s[i];
            if (c != '"' && c != '\\' && c >= ' ') continue;
            json.Append(s, start, i - start);
            if (c < ' ') json.Append("\\u").Append(((int)c).ToString("x4"));
            else json.Append('\\').Append(c);
            start = i + 1;
        }
        return json.Append(s, start, s.Length - start).Append('"');
    }
}
'@

$Exe = $args[0]
New-Item -ItemType Directory -Force (Split-Path $Exe) | Out-Null
$options = New-Object System.CodeDom.Compiler.CompilerParameters
$options.GenerateExecutable = $true
$options.ReferencedAssemblies.Add('System.dll') | Out-Null
$options.OutputAssembly = $Exe
$options.CompilerOptions = '/target:winexe /optimize+'
Add-Type -TypeDefinition $source -CompilerParameters $options
