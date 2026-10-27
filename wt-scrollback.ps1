# wt-scrollback.vim - helper for the pager
#
# Windows Terminal has no scrollback pager setting, so the action added to
# settings.json does selectAll + copy (as HTML, which keeps the colors) and
# opens a zoomed pane running `vim -u pager.vim`. The pager runs the helper
# below, which
#   - reads the "HTML Format" data of that copy from the clipboard,
#   - reads cursor + visible rows of the other panes' consoles (each pane is a
#     ConPTY whose buffer mirrors the pane's viewport) to find the pane we came
#     from and where its cursor was,
#   - turns all of it into lines + highlight ranges for vim (JSON).
#
# This needs Win32 calls, switching consoles kills the PowerShell host, and
# parsing megabytes of HTML is slow in both vimscript and PowerShell, so the
# C# below is compiled once into a console-less helper exe which the pager then
# runs directly (also skipping PowerShell's startup time). The pager only goes
# through this script when the exe is missing or older than this file.
#
# Usage: wt-scrollback.ps1 <helper exe> [<vim pid> <output json>]
#   builds <helper exe> if needed, then runs it with the remaining arguments
$ErrorActionPreference = 'Stop'
$Exe, $Rest = $args

$source = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

public static class WtScrollback
{
    public static int Main(string[] args)
    {
        int vimPid = int.Parse(args[0]);
        string html = Encoding.UTF8.GetString(ReadHtml(1500));
        List<Pane> panes;
        try { panes = Probe(SiblingShells(vimPid)); }
        catch (Exception) { panes = new List<Pane>(); }
        File.WriteAllText(args[1], Convert(html, panes), new UTF8Encoding(false));
        return 0;
    }

    // ---- Clipboard -------------------------------------------------------

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
    // HTML shows up. Emptying it afterwards guarantees we never pick up a stale
    // copy next time (and drops the whole scrollback from the clipboard).
    static byte[] ReadHtml(int timeoutMs)
    {
        uint format = RegisterClipboardFormat("HTML Format");
        var clock = Stopwatch.StartNew();
        while (clock.ElapsedMilliseconds < timeoutMs)
        {
            if (IsClipboardFormatAvailable(format) && OpenClipboard(IntPtr.Zero))
            {
                byte[] data = null;
                try
                {
                    IntPtr mem = GetClipboardData(format);
                    if (mem != IntPtr.Zero)
                    {
                        IntPtr ptr = GlobalLock(mem);
                        data = new byte[(int)GlobalSize(mem).ToUInt64()];
                        Marshal.Copy(ptr, data, 0, data.Length);
                        GlobalUnlock(mem);
                        EmptyClipboard();
                    }
                }
                finally { CloseClipboard(); }
                if (data != null)
                {
                    int end = Array.IndexOf(data, (byte)0);
                    if (end >= 0) Array.Resize(ref data, end);
                    return data;
                }
            }
            Thread.Sleep(10);
        }
        return new byte[0];
    }

    // ---- Other panes' consoles -------------------------------------------

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

    [StructLayout(LayoutKind.Sequential)] struct COORD { public short X, Y; }
    [StructLayout(LayoutKind.Sequential)] struct SMALL_RECT { public short Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] struct CSBI { public COORD Size, Cursor; public ushort Attributes; public SMALL_RECT Window; public COORD MaxSize; }

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

    class Pane { public int Width, CursorX, CursorY; public string[] Rows; }

    // The other shells started by the Windows Terminal process that started vim.
    static int[] SiblingShells(int vimPid)
    {
        var procs = new List<PROCESSENTRY32>();
        IntPtr snap = CreateToolhelp32Snapshot(2, 0); // TH32CS_SNAPPROCESS
        var entry = new PROCESSENTRY32 { dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32)) };
        for (bool ok = Process32FirstW(snap, ref entry); ok; ok = Process32NextW(snap, ref entry))
            procs.Add(entry);
        CloseHandle(snap);
        uint terminal = procs.Find(p => p.th32ProcessID == vimPid).th32ParentProcessID;
        var result = new List<int>();
        foreach (var p in procs)
        {
            string exe = p.szExeFile.ToLowerInvariant();
            if (p.th32ParentProcessID == terminal && p.th32ProcessID != vimPid
                && exe != "openconsole.exe" && exe != "conhost.exe")
                result.Add((int)p.th32ProcessID);
        }
        return result.ToArray();
    }

    // Cursor and visible rows of each pid's console, relative to its viewport.
    static List<Pane> Probe(int[] pids)
    {
        var panes = new List<Pane>();
        foreach (int pid in pids)
        {
            FreeConsole();
            if (!AttachConsole((uint)pid)) continue;
            IntPtr con = CreateFile("CONOUT$", 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
            CSBI info;
            if (con != new IntPtr(-1) && GetConsoleScreenBufferInfo(con, out info))
            {
                var win = info.Window;
                var pane = new Pane { Width = win.Right - win.Left + 1, CursorX = info.Cursor.X - win.Left,
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

    // ---- HTML -> lines + highlight ranges ----------------------------------
    // Windows Terminal's HTML: <DIV STYLE="...background-color:#..."> followed by
    // <SPAN STYLE="color:..;background-color:..;font-weight:bold;..">text</SPAN>
    // runs, rows separated by <BR> (a SPAN may continue across a <BR>).

    class Style
    {
        public string Fg = "", Bg = "";
        public bool Bold, Italic, Underline, Strike;
        public bool IsDefault { get { return Fg == "" && Bg == "" && !Bold && !Italic && !Underline && !Strike; } }
        public string Key { get { return Fg + "|" + Bg + "|" + Bold + Italic + Underline + Strike; } }
    }

    class Run { public string Text; public string Tag; public Run(string t, string g) { Text = t; Tag = g; } }

    static readonly Dictionary<string, Style> parsed = new Dictionary<string, Style>();
    static readonly Regex token = new Regex("<(/?)(SPAN|BR|DIV)\\b([^>]*)>|([^<]+)", RegexOptions.IgnoreCase);
    static readonly Regex styleAttr = new Regex("STYLE=\"([^\"]*)\"", RegexOptions.IgnoreCase);

    static Style ParseStyle(string tag)
    {
        Style s;
        if (parsed.TryGetValue(tag, out s)) return s;
        s = new Style();
        var m = styleAttr.Match(tag);
        foreach (string decl in (m.Success ? m.Groups[1].Value : "").Split(';'))
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
        parsed[tag] = s;
        return s;
    }

    static string Convert(string html, List<Pane> panes)
    {
        int start = html.IndexOf("<!--StartFragment");
        int stop = html.IndexOf("<!--EndFragment");
        if (start >= 0 && stop > start)
        {
            start = html.IndexOf("-->", start) + 3;
            html = html.Substring(start, stop - start);
        }

        var rows = new List<List<Run>> { new List<Run>() };
        var chars = new Dictionary<string, int>();
        string tag = "", defFg = "", defBg = "";
        for (Match m = token.Match(html); m.Success; m = m.NextMatch())
        {
            if (m.Groups[4].Success)
            {
                string text = System.Net.WebUtility.HtmlDecode(m.Groups[4].Value);
                rows[rows.Count - 1].Add(new Run(text, tag));
                int n; chars.TryGetValue(tag, out n); chars[tag] = n + text.Length;
                continue;
            }
            string name = m.Groups[2].Value.ToUpperInvariant();
            bool close = m.Groups[1].Value == "/";
            if (name == "BR") rows.Add(new List<Run>());
            else if (name == "SPAN") tag = close ? "" : m.Groups[3].Value;
            else if (name == "DIV" && !close) { var div = ParseStyle(m.Groups[3].Value); defFg = div.Fg; defBg = div.Bg; }
        }

        // The DIV usually only carries the background; take the most used fg on it.
        if (defFg == "")
        {
            var count = new Dictionary<string, int>();
            foreach (var kv in chars)
            {
                var s = ParseStyle(kv.Key);
                if (s.Bg == defBg && s.Fg != "") { int n; count.TryGetValue(s.Fg, out n); count[s.Fg] = n + kv.Value; }
            }
            int most = 0;
            foreach (var kv in count) if (kv.Value > most) { most = kv.Value; defFg = kv.Key; }
        }

        // Style tag -> index into styles (-1: terminal default, no highlight).
        var styles = new List<Style>();
        var index = new Dictionary<string, int>();
        var byKey = new Dictionary<string, int>();
        Func<string, int> styleOf = t =>
        {
            int idx;
            if (index.TryGetValue(t, out idx)) return idx;
            var raw = ParseStyle(t);
            var s = new Style { Fg = raw.Fg == defFg ? "" : raw.Fg, Bg = raw.Bg == defBg ? "" : raw.Bg,
                                Bold = raw.Bold, Italic = raw.Italic, Underline = raw.Underline, Strike = raw.Strike };
            if (s.IsDefault) idx = -1;
            else if (!byKey.TryGetValue(s.Key, out idx)) { styles.Add(s); idx = byKey[s.Key] = styles.Count - 1; }
            return index[t] = idx;
        };

        // Drop trailing blank cells (default background) and trailing empty rows.
        foreach (var row in rows)
        {
            while (row.Count > 0)
            {
                var last = row[row.Count - 1];
                int idx = styleOf(last.Tag);
                if (idx >= 0 && styles[idx].Bg != "") break;
                last.Text = last.Text.TrimEnd(' ');
                if (last.Text != "") break;
                row.RemoveAt(row.Count - 1);
            }
        }
        while (rows.Count > 1 && rows[rows.Count - 1].Count == 0) rows.RemoveAt(rows.Count - 1);

        var lines = new List<string>();
        var props = new List<StringBuilder>();
        var sb = new StringBuilder();
        foreach (var row in rows)
        {
            int lnum = lines.Count + 1, col = 1;
            sb.Clear();
            foreach (var run in row)
            {
                int n = Encoding.UTF8.GetByteCount(run.Text);
                int idx = styleOf(run.Tag);
                if (idx >= 0 && n > 0)
                {
                    while (props.Count <= idx) props.Add(new StringBuilder());
                    var p = props[idx];
                    p.Append(p.Length > 0 ? "," : "").Append('[').Append(lnum).Append(',').Append(col)
                     .Append(',').Append(lnum).Append(',').Append(col + n).Append(']');
                }
                col += n;
                sb.Append(run.Text);
            }
            lines.Add(sb.ToString());
        }

        int[] cursor = null;
        int topline = 0;
        Locate(lines, panes, ref cursor, ref topline);

        var json = new StringBuilder("{\"fg\":");
        Str(json, defFg).Append(",\"bg\":");
        Str(json, defBg).Append(",\"lines\":[");
        for (int i = 0; i < lines.Count; i++) Str(i > 0 ? json.Append(',') : json, lines[i]);
        json.Append("],\"styles\":[");
        for (int i = 0; i < styles.Count; i++)
        {
            var s = styles[i];
            json.Append(i > 0 ? ",{\"fg\":" : "{\"fg\":");
            Str(json, s.Fg).Append(",\"bg\":");
            Str(json, s.Bg).Append(",\"bold\":").Append(s.Bold ? "true" : "false")
                .Append(",\"italic\":").Append(s.Italic ? "true" : "false")
                .Append(",\"underline\":").Append(s.Underline ? "true" : "false")
                .Append(",\"strike\":").Append(s.Strike ? "true" : "false").Append('}');
        }
        json.Append("],\"props\":[");
        for (int i = 0; i < styles.Count; i++)
            json.Append(i > 0 ? ",[" : "[").Append(i < props.Count ? props[i].ToString() : "").Append(']');
        json.Append(']');
        if (cursor != null)
            json.Append(",\"cursor\":[").Append(cursor[0]).Append(',').Append(cursor[1])
                .Append("],\"topline\":").Append(topline);
        return json.Append('}').ToString();
    }

    // ---- Cursor position ---------------------------------------------------
    // Find the pane whose visible rows match the end of `lines` and map its
    // cursor into `lines` (1-based line, screen column) plus the line at its top.
    static void Locate(List<string> lines, List<Pane> panes, ref int[] cursor, ref int topline)
    {
        double bestScore = -1;
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
            {
                var chunks = new List<int[]>();
                for (int off = 0; off < Math.Max(lines[i].Length, 1); off += pane.Width) chunks.Add(new[] { i, off });
                rows.InsertRange(0, chunks);
            }
            for (int top = Math.Max(0, rows.Count - pane.Rows.Length); top <= rows.Count; top++)
            {
                int score = 0;
                for (int k = 0; k < pane.Rows.Length; k++)
                {
                    if (pane.Rows[k] == "") continue;
                    string text = "";
                    if (top + k < rows.Count)
                    {
                        var r = rows[top + k];
                        string line = lines[r[0]];
                        text = line.Substring(r[1], Math.Min(pane.Width, line.Length - r[1])).TrimEnd(' ');
                    }
                    if (text == pane.Rows[k]) score++;
                }
                if ((double)score / wanted > bestScore)
                {
                    bestScore = (double)score / wanted; bestTop = top; best = pane; bestRows = rows;
                }
            }
        }
        if (best == null || bestScore < 0.5) return;

        int row = bestTop + best.CursorY, lnum, offset;
        if (row < bestRows.Count) { lnum = bestRows[row][0]; offset = bestRows[row][1]; }
        else
        {   // cursor on a blank row below the copied text
            lnum = lines.Count - 1 + (row - bestRows.Count + 1);
            offset = 0;
            while (lines.Count <= lnum) lines.Add("");
        }
        cursor = new[] { lnum + 1, offset + best.CursorX + 1 };
        topline = bestTop < bestRows.Count ? bestRows[bestTop][0] + 1 : lnum + 1;
    }

    static StringBuilder Str(StringBuilder json, string s)
    {
        json.Append('"');
        foreach (char c in s)
        {
            if (c == '"' || c == '\\') json.Append('\\').Append(c);
            else if (c < ' ') json.Append("\\u").Append(((int)c).ToString("x4"));
            else json.Append(c);
        }
        return json.Append('"');
    }
}
'@

if (-not (Test-Path $Exe) -or (Get-Item $Exe).LastWriteTime -lt (Get-Item $PSCommandPath).LastWriteTime) {
    New-Item -ItemType Directory -Force (Split-Path $Exe) | Out-Null
    Add-Type -TypeDefinition $source -OutputAssembly $Exe -OutputType WindowsApplication
}
if ($Rest) {
    & $Exe @Rest | Out-Null  # piping makes PowerShell wait for the GUI-subsystem exe
}
