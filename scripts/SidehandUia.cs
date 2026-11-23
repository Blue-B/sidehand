// Native UI Automation engine for uia.ps1 (C# 5: compiled by Windows PowerShell's Add-Type).
// The managed System.Windows.Automation client misses most Win32, WinForms and Chromium controls;
// the COM client (IUIAutomation) sees what Narrator sees.
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using Interop.UIAutomationClient;

public static class SidehandUia {
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr h, uint flags);
  [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] static extern IntPtr GetWindowLongPtr(IntPtr h, int i);
  [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] static extern IntPtr SetWindowLongPtr(IntPtr h, int i, IntPtr v);
  [DllImport("user32.dll")] static extern IntPtr GetParent(IntPtr h);
  [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint cmd);
  [DllImport("user32.dll")] static extern int GetDlgCtrlID(IntPtr h);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", SetLastError = true)] static extern IntPtr SendMessageTimeout(IntPtr h, int msg, IntPtr w, IntPtr l, int flags, int ms, out IntPtr result);
  [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern IntPtr SendMessageTimeout(IntPtr h, int msg, IntPtr w, string l, int flags, int ms, out IntPtr result);
  // Unicode: through PostMessageA a WM_CHAR outside ASCII (Hangul, accents) arrives garbled.
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool PostMessage(IntPtr h, int msg, IntPtr w, IntPtr l);
  [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
  [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
  [DllImport("user32.dll")] static extern bool ScreenToClient(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] static extern IntPtr ChildWindowFromPointEx(IntPtr h, POINT p, uint flags);
  [DllImport("user32.dll")] static extern uint MapVirtualKey(uint code, uint type);
  [DllImport("user32.dll")] static extern short VkKeyScan(char c);
  [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hgt, uint flags);
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] static extern bool LockSetForegroundWindow(uint code);
  [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool attach);
  [DllImport("user32.dll")] static extern bool GetKeyboardState(byte[] s);
  [DllImport("user32.dll")] static extern bool SetKeyboardState(byte[] s);
  [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
  [StructLayout(LayoutKind.Sequential)] struct LASTINPUTINFO { public uint cbSize, dwTime; }
  [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO i);
  [DllImport("kernel32.dll")] static extern uint GetTickCount();
  [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  delegate bool EnumWindowsProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumThreadWindows(uint tid, EnumWindowsProc f, IntPtr l);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr h);
  [DllImport("winmm.dll")] static extern uint timeBeginPeriod(uint ms);
  [DllImport("winmm.dll")] static extern uint timeEndPeriod(uint ms);
  const int RuntimeId = 30000, Bounds = 30001, ControlType = 30003, Name = 30005, Enabled = 30010, NativeHwnd = 30020,
    Password = 30019, Offscreen = 30022, ValueAvail = 30043, ValueValue = 30045, ToggleAvail = 30041,
    ToggleStateId = 30086, ExpandAvail = 30028, ExpandStateId = 30070, SelectAvail = 30036, Selected = 30079;
  const int PInvoke = 10000, PValue = 10002, PExpand = 10005, PSelectItem = 10010, PToggle = 10015,
    PScrollItem = 10017, PLegacy = 10018;

  static readonly string[] Types = { "Button", "Calendar", "CheckBox", "ComboBox", "Edit", "Hyperlink", "Image",
    "ListItem", "List", "Menu", "MenuBar", "MenuItem", "ProgressBar", "RadioButton", "ScrollBar", "Slider",
    "Spinner", "StatusBar", "Tab", "TabItem", "Text", "ToolBar", "ToolTip", "Tree", "TreeItem", "Custom",
    "Group", "Thumb", "DataGrid", "DataItem", "Document", "SplitButton", "Window", "Pane", "Header",
    "HeaderItem", "Table", "TitleBar", "Separator", "SemanticZoom", "AppBar" };
  // Containers that only add nesting; printed only when they carry a name.
  static readonly HashSet<string> Structural = new HashSet<string> { "Pane", "Group", "Custom", "Document",
    "Window", "TitleBar", "ToolBar", "StatusBar", "Header", "ScrollBar", "Thumb", "Separator", "Image",
    "Table", "List", "Tree", "Menu", "MenuBar", "Tab" };

  static readonly IUIAutomation A = new CUIAutomation();

  static IUIAutomationCacheRequest Request() {
    var r = A.CreateCacheRequest();
    foreach (var p in new[] { RuntimeId, Bounds, ControlType, Name, Enabled, NativeHwnd, Password, Offscreen, ValueAvail,
      ValueValue, ToggleAvail, ToggleStateId, ExpandAvail, ExpandStateId, SelectAvail, Selected }) r.AddProperty(p);
    return r;
  }

  static object P(IUIAutomationElement e, int id) { try { return e.GetCachedPropertyValue(id); } catch { return null; } }
  static bool Flag(IUIAutomationElement e, int id) { var v = P(e, id); return v is bool && (bool)v; }
  static int Int(IUIAutomationElement e, int id) { var v = P(e, id); return v is int ? (int)v : -1; }
  static string TypeOf(IUIAutomationElement e) { int i = e.CachedControlType - 50000; return i >= 0 && i < Types.Length ? Types[i] : "Unknown"; }
  static string Short(object o, int n) {
    var s = o as string; if (s == null) return "";
    s = Regex.Replace(s, @"\s+", " ").Trim();
    return s.Length > n ? s.Substring(0, n) + "..." : s;
  }

  // One compact line per element, or null for unnamed structural containers.
  static string Describe(IUIAutomationElement e, string id, bool rects) {
    string type = TypeOf(e), name = Short(e.CachedName, 100);
    if (name.Length == 0 && Structural.Contains(type)) return null;
    var sb = new StringBuilder(id).Append(' ').Append(type);
    if (name.Length > 0) sb.Append(" \"").Append(name).Append('"');
    if ((type == "Edit" || type == "ComboBox" || type == "Spinner") && Flag(e, ValueAvail) && !Flag(e, Password)) {
      var v = Short(P(e, ValueValue), 80);
      if (v.Length > 0) sb.Append(" value=\"").Append(v).Append('"');
    }
    if (Flag(e, ToggleAvail)) { int t = Int(e, ToggleStateId); if (t >= 0 && t <= 2) sb.Append(new[] { " [Off]", " [On]", " [Indeterminate]" }[t]); }
    if ((type == "TreeItem" || type == "ComboBox") && Flag(e, ExpandAvail)) { int s = Int(e, ExpandStateId); if (s == 0) sb.Append(" collapsed"); else if (s == 1) sb.Append(" expanded"); }
    if (Flag(e, SelectAvail) && Flag(e, Selected)) sb.Append(" selected");
    if (rects) {
      var r = e.CachedBoundingRectangle;
      if (r.right > r.left) sb.AppendFormat(" @{0},{1} {2}x{3}", r.left, r.top, r.right - r.left, r.bottom - r.top);
    }
    var en = P(e, Enabled); if (en is bool && !(bool)en) sb.Append(" disabled");
    if (Flag(e, Offscreen)) sb.Append(" offscreen");
    return sb.ToString();
  }

  class Walk {
    public IUIAutomationTreeWalker W = A.ControlViewWalker;
    public IUIAutomationCacheRequest Req = Request();
    public IUIAutomationCacheRequest Kids = KidsRequest();
    public int Max, Visited, ItemCap; public bool Rects;
    // One cross-process call per container for all its children, instead of one per element.
    // Lists, grids, tables and trees are still walked one by one, so ItemCap and Max bound them
    // even when they hold thousands of rows.
    static IUIAutomationCacheRequest KidsRequest() {
      var r = Request(); r.TreeScope = TreeScope.TreeScope_Element | TreeScope.TreeScope_Children; r.TreeFilter = A.ControlViewCondition;
      return r;
    }
    static bool IsList(IUIAutomationElement e) { int t = e.CachedControlType; return t == 50008 || t == 50028 || t == 50036 || t == 50023; }
    public List<string> Lines = new List<string>(), Refs = new List<string>();
    Dictionary<string, int> seen = new Dictionary<string, int>();
    static bool IsItem(IUIAutomationElement e) { int t = e.CachedControlType; return t == 50007 || t == 50029 || t == 50024; } // ListItem, DataItem, TreeItem
    public void Run(IUIAutomationElement el, int indent) {
      if (Visited >= Max) return;
      Visited++;
      int next = indent;
      try {
        string line = Describe(el, "e" + (Refs.Count + 1), Rects);
        if (line != null) {
          // Some HWND roots do not return a cached RuntimeId; ask once directly.
          var rid = P(el, RuntimeId) as int[] ?? el.GetRuntimeId() as int[];
          // Custom-drawn UIs (Sciter, e.g. AdGuard) give no RuntimeId: remember type, name and
          // how many same-type, same-name elements came before it, and find it again by that.
          string name = el.CachedName ?? "", key = el.CachedControlType + "|" + name;
          int nth; seen.TryGetValue(key, out nth); seen[key] = nth + 1;
          Refs.Add(rid != null && rid.Length > 0 ? string.Join(".", rid) : "@" + el.CachedControlType + "." + nth + "." + Uri.EscapeDataString(name));
          Lines.Add(new string(' ', indent * 2) + line);
          next = indent + 1;
        }
        bool bulk = !IsList(el);
        var kids = bulk ? el.BuildUpdatedCache(Kids).GetCachedChildren() : null;
        int k = 0;
        var child = bulk ? (kids != null && kids.Length > 0 ? kids.GetElement(k++) : null) : W.GetFirstChildElementBuildCache(el, Req);
        int items = 0, skipped = 0;
        while (child != null && Visited < Max) {
          // Long lists (file rows, search results) cost thousands of tokens; show the first ItemCap.
          if (ItemCap > 0 && IsItem(child) && ++items > ItemCap) { skipped++; Visited++; }
          else Run(child, next);
          child = bulk ? (k < kids.Length ? kids.GetElement(k++) : null) : W.GetNextSiblingElementBuildCache(child, Req);
        }
        if (skipped > 0) Lines.Add(new string(' ', next * 2) + "... " + skipped + " more items (pass filter to find one)");
      } catch (COMException) { } // element vanished mid-walk
    }
  }

  static Walk Read(IntPtr hwnd, int max, bool rects, int itemCap) {
    var w = new Walk { Max = max, Rects = rects, ItemCap = itemCap };
    w.Run(A.ElementFromHandleBuildCache(hwnd, w.Req), 0);
    return w;
  }

  static void SaveRefs(string cachePath, IntPtr hwnd, List<string> refs) {
    var sb = new StringBuilder().Append(hwnd.ToInt64()).Append('\n');
    for (int i = 0; i < refs.Count; i++) sb.Append('e').Append(i + 1).Append('\t').Append(refs[i]).Append('\n');
    File.WriteAllText(cachePath, sb.ToString());
  }

  static List<string> Matching(List<string> lines, string filter) {
    if (string.IsNullOrEmpty(filter)) return lines;
    return lines.FindAll(l => l.IndexOf(filter, StringComparison.OrdinalIgnoreCase) >= 0);
  }

  public static string Tree(long hwnd, string title, int max, bool rects, string filter, string cachePath) {
    var w = Read(new IntPtr(hwnd), max, rects, string.IsNullOrEmpty(filter) ? 25 : 0);
    SaveRefs(cachePath, new IntPtr(hwnd), w.Refs);
    var shown = Matching(w.Lines, filter);
    var head = "window: " + title + "  (" + w.Refs.Count + " elements";
    if (!string.IsNullOrEmpty(filter)) head += ", " + shown.Count + " match \"" + filter + "\"";
    if (w.Visited >= max) head += ", truncated at " + max + " nodes";
    if (IsIconic(new IntPtr(hwnd))) head += ", minimized: actions fail until window restore, which does not activate it";
    return head + ")\n" + string.Join("\n", shown);
  }

  // Polls until an element line contains `text` (or none does, with gone=true).
  public static string Wait(long hwnd, string title, string text, bool gone, int timeoutMs, int max, string cachePath) {
    var deadline = DateTime.UtcNow.AddMilliseconds(timeoutMs);
    while (true) {
      var w = Read(new IntPtr(hwnd), max, false, 0);
      var hits = Matching(w.Lines, text);
      if (gone ? hits.Count == 0 : hits.Count > 0) {
        SaveRefs(cachePath, new IntPtr(hwnd), w.Refs);
        return gone ? "ok gone: no element matches \"" + text + "\"" : "ok found in " + title + "\n" + string.Join("\n", hits);
      }
      if (DateTime.UtcNow >= deadline) throw new TimeoutException("timed out after " + timeoutMs + " ms waiting for \"" + text + "\"" + (gone ? " to disappear" : ""));
      Thread.Sleep(300);
    }
  }

  static T Pattern<T>(IUIAutomationElement e, int id) where T : class { try { return e.GetCurrentPattern(id) as T; } catch (COMException) { return null; } }

  static IUIAutomationElement Resolve(string cachePath, string refId, out IntPtr hwnd) {
    if (!File.Exists(cachePath)) throw new InvalidOperationException("no cached refs; run the tree first");
    var lines = File.ReadAllLines(cachePath);
    hwnd = new IntPtr(long.Parse(lines[0]));
    foreach (var l in lines) {
      var parts = l.Split('\t');
      if (parts.Length != 2 || parts[0] != refId) continue;
      if (parts[1].StartsWith("@")) {
        // shortcut: list items hidden past the 25-item cap are not counted, so a same-name element
        // after such a list can resolve to the wrong one; read with filter to avoid the cap.
        var loc = parts[1].Substring(1).Split(new[] { '.' }, 3);
        var cond = A.CreateAndConditionFromArray(new[] { A.ControlViewCondition,
          A.CreatePropertyCondition(ControlType, int.Parse(loc[0])), A.CreatePropertyCondition(Name, Uri.UnescapeDataString(loc[2])) });
        var all = A.ElementFromHandle(hwnd).FindAllBuildCache(TreeScope.TreeScope_Subtree, cond, Request());
        int nth = int.Parse(loc[1]);
        if (all == null || all.Length <= nth) throw new InvalidOperationException("ref " + refId + " is stale (element gone); run the tree again");
        return all.GetElement(nth);
      }
      var ids = Array.ConvertAll(parts[1].Split('.'), int.Parse);
      var el = A.ElementFromHandle(hwnd).FindFirstBuildCache(TreeScope.TreeScope_Subtree, A.CreatePropertyCondition(RuntimeId, ids), Request());
      if (el == null) throw new InvalidOperationException("ref " + refId + " is stale (element gone); run the tree again");
      return el;
    }
    throw new InvalidOperationException("unknown ref " + refId + "; run the tree again");
  }

  // OCR refs (uia.ps1 -Op ocr): "t3<TAB>dx,dy<TAB>text", the text's center relative to the window's
  // top-left in physical pixels.
  static POINT ResolveText(string cachePath, string refId, out IntPtr hwnd, out string text) {
    if (!File.Exists(cachePath)) throw new InvalidOperationException("no cached refs; run ocr first");
    // A t-ref is only a point: once the window scrolled or changed, something else sits there.
    if (DateTime.UtcNow - File.GetLastWriteTimeUtc(cachePath) > TimeSpan.FromSeconds(60))
      throw new InvalidOperationException("OCR refs expire after 60 s, since other content may be at that spot by now; run ocr again");
    var lines = File.ReadAllLines(cachePath);
    hwnd = new IntPtr(long.Parse(lines[0]));
    foreach (var l in lines) {
      var parts = l.Split('\t');
      if (parts.Length != 3 || parts[0] != refId) continue;
      RECT r;
      if (!GetWindowRect(hwnd, out r)) throw new InvalidOperationException("the window of " + refId + " is gone");
      if (IsIconic(hwnd)) throw new InvalidOperationException("window is minimized; run window restore first (it puts the window back behind the user's windows without activating it)");
      var d = parts[1].Split(',');
      var p = new POINT { X = r.L + int.Parse(d[0]), Y = r.T + int.Parse(d[1]) };
      if (p.X >= r.R || p.Y >= r.B) throw new InvalidOperationException("ref " + refId + " is outside the window now; run ocr again");
      text = parts[2];
      return p;
    }
    throw new InvalidOperationException("unknown ref " + refId + "; run ocr again");
  }

  static string Click(IUIAutomationElement el) {
    var inv = Pattern<IUIAutomationInvokePattern>(el, PInvoke); if (inv != null) { inv.Invoke(); return "invoke"; }
    var tog = Pattern<IUIAutomationTogglePattern>(el, PToggle); if (tog != null) { tog.Toggle(); return "toggle"; }
    var sel = Pattern<IUIAutomationSelectionItemPattern>(el, PSelectItem); if (sel != null) { sel.Select(); return "select"; }
    var exp = Pattern<IUIAutomationExpandCollapsePattern>(el, PExpand);
    if (exp != null) {
      if (exp.CurrentExpandCollapseState == ExpandCollapseState.ExpandCollapseState_Collapsed) exp.Expand(); else exp.Collapse();
      return "expand/collapse";
    }
    var leg = Pattern<IUIAutomationLegacyIAccessiblePattern>(el, PLegacy);
    if (leg != null && !string.IsNullOrEmpty(leg.CurrentDefaultAction)) { leg.DoDefaultAction(); return "default action"; }
    throw new InvalidOperationException("element supports no click pattern (Invoke/Toggle/SelectionItem/ExpandCollapse/default action)");
  }

  static string SetChecked(IUIAutomationElement el, bool on) {
    var tog = Pattern<IUIAutomationTogglePattern>(el, PToggle);
    if (tog == null) throw new InvalidOperationException("element has no toggle state");
    var want = on ? ToggleState.ToggleState_On : ToggleState.ToggleState_Off;
    // Browsers publish the new state a moment after Toggle returns; re-reading at once would
    // toggle it straight back.
    for (int i = 0; i < 3 && tog.CurrentToggleState != want; i++) {
      tog.Toggle();
      for (int w = 0; w < 10 && tog.CurrentToggleState != want; w++) Thread.Sleep(50);
    }
    if (tog.CurrentToggleState != want) throw new InvalidOperationException("toggle did not reach " + want);
    return on ? "check" : "uncheck";
  }

  static bool OwnedBy(IntPtr h, IntPtr root) {
    for (int i = 0; i < 16 && h != IntPtr.Zero; i++, h = GetWindow(h, 4 /* GW_OWNER */)) if (h == root) return true;
    return false;
  }

  static string Select(IUIAutomationElement el, string item, IntPtr root) {
    if (string.IsNullOrEmpty(item)) {
      var own = Pattern<IUIAutomationSelectionItemPattern>(el, PSelectItem);
      if (own == null) throw new InvalidOperationException("element is not selectable; pass value=<item name> to pick a child item");
      own.Select(); return "select";
    }
    // Browser drop-downs create their options only while open, sometimes in a popup outside the
    // element: expand, look in the element and then the whole window, pick, collapse.
    for (int attempt = 0; attempt < 4; attempt++) {
      IUIAutomationElementArray items;
      if (attempt < 3) {
        var scope = attempt == 2 ? A.ElementFromHandle(root) : el;
        items = scope.FindAllBuildCache(TreeScope.TreeScope_Descendants, A.CreatePropertyCondition(SelectAvail, true), Request());
      } else {
        // Chromium shows the option list in a top-level popup of the same process, owned by this window;
        // the app's other windows (another browser window, one SIDEHAND_ALLOW hides) are not the target.
        uint pid; GetWindowThreadProcessId(root, out pid);
        var popups = A.GetRootElement().FindAll(TreeScope.TreeScope_Children, A.CreatePropertyCondition(30002 /* ProcessId */, (int)pid));
        items = null;
        for (int k = 0; k < popups.Length && (items == null || items.Length == 0); k++)
          if (OwnedBy(popups.GetElement(k).CurrentNativeWindowHandle, root))
            items = popups.GetElement(k).FindAllBuildCache(TreeScope.TreeScope_Descendants, A.CreateAndCondition(A.CreatePropertyCondition(SelectAvail, true), A.CreatePropertyCondition(Name, item)), Request());
        if (items == null) break;
      }
      for (int pass = 0; pass < 2; pass++)
        for (int i = 0; i < items.Length; i++) {
          var it = items.GetElement(i); var n = it.CachedName ?? "";
          if (pass == 0 ? n == item : n.IndexOf(item, StringComparison.OrdinalIgnoreCase) >= 0) {
            Pattern<IUIAutomationSelectionItemPattern>(it, PSelectItem).Select();
            if (attempt > 0) { try { Pattern<IUIAutomationExpandCollapsePattern>(el, PExpand).Collapse(); } catch (Exception) { } }
            return "select \"" + Short(n, 60) + "\"";
          }
        }
      var ex = Pattern<IUIAutomationExpandCollapsePattern>(el, PExpand);
      if (ex == null) break;
      if (attempt == 0) { ex.Expand(); Thread.Sleep(500); }
    }
    var vp = Pattern<IUIAutomationValuePattern>(el, PValue);
    if (vp != null && vp.CurrentIsReadOnly == 0) {
      vp.SetValue(item);
      for (int w = 0; w < 10 && vp.CurrentValue != item; w++) Thread.Sleep(50);
      if (vp.CurrentValue == item) return "select \"" + Short(item, 60) + "\" (value)";
      throw new InvalidOperationException("the app ignored the selection (value is still \"" + vp.CurrentValue + "\"); browser drop-downs need real input");
    }
    throw new InvalidOperationException("no selectable item named \"" + item + "\" inside this element");
  }

  // --- window-message path -----------------------------------------------------------------------
  // UIA pattern calls on Win32-proxied controls can activate the target window; a plain window
  // message to a classic EDIT/BUTTON/LISTBOX/COMBOBOX never does, and returns in milliseconds.

  static IntPtr Send(IntPtr h, int msg, IntPtr w, IntPtr l) {
    IntPtr r;
    if (SendMessageTimeout(h, msg, w, l, 0x2, 5000, out r) == IntPtr.Zero) throw Unanswered();
    return r;
  }
  static IntPtr Send(IntPtr h, int msg, IntPtr w, string l) {
    IntPtr r;
    if (SendMessageTimeout(h, msg, w, l, 0x2, 5000, out r) == IntPtr.Zero) throw Unanswered();
    return r;
  }
  static Exception Unanswered() {
    return new InvalidOperationException("the app did not answer the window message (hung, or running as administrator)");
  }

  static void NotifyParent(IntPtr h, int code) {
    Send(GetParent(h), 0x0111 /* WM_COMMAND */, new IntPtr((code << 16) | (GetDlgCtrlID(h) & 0xFFFF)), h);
  }

  // A button whose handler opens a dialog (Save, Open, a message box) does not answer BM_CLICK until
  // the dialog closes. Send it from another thread; a window that shows up on the button's thread
  // meanwhile is that dialog (owned or not), so stop waiting and name it for the agent to read next.
  // The foreground watch learns of it at once: a dialog takes the foreground as it shows.
  static string ClickButton(IntPtr h, Foreground fg) {
    uint pid, tid = GetWindowThreadProcessId(h, out pid);
    var before = ThreadWindows(tid);
    Exception failed = null;
    var t = new Thread(() => { try { Send(h, 0x00F5 /* BM_CLICK */, IntPtr.Zero, IntPtr.Zero); } catch (Exception e) { failed = e; } });
    t.IsBackground = true; t.Start();
    var opened = IntPtr.Zero;
    while (opened == IntPtr.Zero && !t.Join(20)) opened = Opened(tid, before);
    if (opened == IntPtr.Zero && failed != null) opened = Opened(tid, before); // a dialog slower than the 5 s timeout
    if (opened != IntPtr.Zero) {
      fg.Opened = opened;
      var sb = new StringBuilder(256); GetWindowText(opened, sb, 256);
      return "click (it opened a window" + (sb.Length > 0 ? " \"" + Short(sb.ToString(), 60) + "\"" : "") + ")";
    }
    if (failed != null) throw failed;
    return "click";
  }

  static List<IntPtr> ThreadWindows(uint tid) {
    var list = new List<IntPtr>();
    EnumThreadWindows(tid, (w, l) => { if (IsWindowVisible(w)) list.Add(w); return true; }, IntPtr.Zero);
    return list;
  }

  // A visible window of the thread that was not there before, or zero.
  static IntPtr Opened(uint tid, List<IntPtr> before) {
    foreach (var w in ThreadWindows(tid)) if (!before.Contains(w)) return w;
    return IntPtr.Zero;
  }

  // Returns null when the element is not a classic control, so the caller falls back to UIA.
  static string ViaMessage(IUIAutomationElement el, string action, string value, Foreground fg) {
    var hv = P(el, NativeHwnd);
    var h = hv is int ? new IntPtr((int)hv) : IntPtr.Zero;
    if (h == IntPtr.Zero) return null;
    var sb = new StringBuilder(256); GetClassName(h, sb, 256);
    var cls = sb.ToString().ToUpperInvariant();
    bool list = cls.Contains("LISTBOX"), combo = cls.Contains("COMBOBOX");
    bool edit = !combo && cls.Contains("EDIT"), button = cls.Contains("BUTTON");
    if (action == "type" && edit) {
      Send(h, 0x000C /* WM_SETTEXT */, IntPtr.Zero, value ?? "");
      return "set text";
    }
    if (action == "click" && button) return ClickButton(h, fg);
    var tog = Pattern<IUIAutomationTogglePattern>(el, PToggle);
    if ((action == "check" || action == "uncheck") && button && tog != null) {
      // Read the state through UIA (owner-drawn WinForms checkboxes ignore BM_GETCHECK); reading never activates.
      var want = action == "check" ? ToggleState.ToggleState_On : ToggleState.ToggleState_Off;
      for (int i = 0; i < 3 && tog.CurrentToggleState != want; i++) {
        // A checkbox that asks first ("Turn this on?"): the answer decides the state, so stop here.
        var clicked = ClickButton(h, fg);
        if (clicked != "click") return action + clicked.Substring(5);
        Thread.Sleep(50);
      }
      if (tog.CurrentToggleState != want) throw new InvalidOperationException("checkbox did not reach the requested state");
      return action;
    }
    if (action == "select" && (list || combo) && !string.IsNullOrEmpty(value)) {
      int idx = Send(h, list ? 0x01A2 : 0x0158 /* LB_/CB_FINDSTRINGEXACT */, new IntPtr(-1), value).ToInt32();
      if (idx < 0) return null; // let UIA try a substring match
      if (list && Send(h, 0x0186 /* LB_SETCURSEL */, new IntPtr(idx), IntPtr.Zero).ToInt32() < 0)
        Send(h, 0x0185 /* LB_SETSEL (multi-select) */, new IntPtr(1), new IntPtr(idx));
      if (combo) Send(h, 0x014E /* CB_SETCURSEL */, new IntPtr(idx), IntPtr.Zero);
      NotifyParent(h, 1 /* LBN_SELCHANGE / CBN_SELCHANGE */);
      return "select \"" + Short(value, 60) + "\"";
    }
    return null;
  }

  // --- posted mouse and keyboard input -----------------------------------------------------------
  // Posted messages go through the app's own message loop, so buttons, lists, canvases and dialog
  // keys react as to real input, but nothing moves the user's pointer or changes the foreground.
  // Limits: OLE drag and drop between windows, and shortcuts the app checks with GetKeyState
  // (modifier state is not part of a posted message), need real input.

  static readonly HashSet<string> Pointer = new HashSet<string> { "right-click", "double-click", "hover", "wheel", "drag" };

  static POINT Center(IUIAutomationElement el) {
    var r = el.CachedBoundingRectangle;
    if (r.right <= r.left) throw new InvalidOperationException("element has no on-screen rectangle");
    return new POINT { X = (r.left + r.right) / 2, Y = (r.top + r.bottom) / 2 };
  }

  // Deepest visible child window of root under a screen point, even when another app covers it.
  static IntPtr HwndAt(IntPtr root, POINT screen) {
    var h = root;
    while (true) {
      var p = screen; ScreenToClient(h, ref p);
      var c = ChildWindowFromPointEx(h, p, 0x1 | 0x4 /* SKIPINVISIBLE | SKIPTRANSPARENT */);
      if (c == IntPtr.Zero || c == h) return h;
      h = c;
    }
  }

  // Message coordinates in this process's physical pixels: Windows itself rescales posted mouse
  // coordinates for a DPI-unaware target (scaling them here as well put clicks at 80% at 125%).
  static IntPtr XY(IntPtr h, POINT screen, bool client) {
    var p = screen;
    if (client) ScreenToClient(h, ref p);
    return new IntPtr((p.Y << 16) | (p.X & 0xFFFF));
  }

  static string ViaPointer(POINT at, IntPtr root, string action, string value, string cachePath) {
    var h = HwndAt(root, at);
    switch (action) {
      case "click": // OCR refs only: elements click through a pattern or a window message
        PostMessage(h, 0x0200, IntPtr.Zero, XY(h, at, true));
        PostMessage(h, 0x0201, new IntPtr(1), XY(h, at, true));
        PostMessage(h, 0x0202, IntPtr.Zero, XY(h, at, true));
        return "click";
      case "hover":
        // Two moves: an app can drop the first one while it starts tracking the mouse.
        PostMessage(h, 0x0200 /* WM_MOUSEMOVE */, IntPtr.Zero, XY(h, new POINT { X = at.X - 4, Y = at.Y }, true));
        Thread.Sleep(30);
        PostMessage(h, 0x0200, IntPtr.Zero, XY(h, at, true));
        return "hover";
      case "right-click":
        PostMessage(h, 0x0200, IntPtr.Zero, XY(h, at, true));
        PostMessage(h, 0x0204 /* WM_RBUTTONDOWN */, new IntPtr(2), XY(h, at, true));
        PostMessage(h, 0x0205 /* WM_RBUTTONUP */, IntPtr.Zero, XY(h, at, true));
        return "right-click";
      case "double-click":
        PostMessage(h, 0x0200, IntPtr.Zero, XY(h, at, true));
        PostMessage(h, 0x0201 /* WM_LBUTTONDOWN */, new IntPtr(1), XY(h, at, true));
        PostMessage(h, 0x0202 /* WM_LBUTTONUP */, IntPtr.Zero, XY(h, at, true));
        PostMessage(h, 0x0203 /* WM_LBUTTONDBLCLK */, new IntPtr(1), XY(h, at, true));
        PostMessage(h, 0x0202, IntPtr.Zero, XY(h, at, true));
        return "double-click";
      case "wheel": {
        // Wheel messages carry screen coordinates.
        int delta = WheelDelta(value);
        PostMessage(h, 0x020A /* WM_MOUSEWHEEL */, new IntPtr(delta << 16), XY(h, at, false));
        return "wheel " + delta;
      }
      case "drag": {
        // value: another ref (drop on its center) or "dx,dy" in pixels. Every message goes to the
        // window under the start point, as with real input once the app captured the mouse.
        POINT to;
        var m = Regex.Match(value ?? "", @"^\s*(-?\d+)\s*,\s*(-?\d+)\s*$");
        if (m.Success) to = new POINT { X = at.X + int.Parse(m.Groups[1].Value), Y = at.Y + int.Parse(m.Groups[2].Value) };
        else if (Regex.IsMatch(value ?? "", @"^e\d+$")) { IntPtr unused; to = Center(Resolve(cachePath, value, out unused)); }
        else if (Regex.IsMatch(value ?? "", @"^t\d+$")) { IntPtr unused; string s; to = ResolveText(cachePath, value, out unused, out s); }
        else throw new ArgumentException("drag needs value=<ref> or value=\"dx,dy\"");
        PostMessage(h, 0x0200, IntPtr.Zero, XY(h, at, true));
        PostMessage(h, 0x0201, new IntPtr(1), XY(h, at, true));
        for (int i = 1; i <= 10; i++) {
          var p = new POINT { X = at.X + (to.X - at.X) * i / 10, Y = at.Y + (to.Y - at.Y) * i / 10 };
          PostMessage(h, 0x0200, new IntPtr(1 /* MK_LBUTTON */), XY(h, p, true));
          Thread.Sleep(15);
        }
        PostMessage(h, 0x0202, IntPtr.Zero, XY(h, to, true));
        return "drag to " + to.X + "," + to.Y;
      }
    }
    return null;
  }

  // value: "down 3" / "up" / "-240"
  static int WheelDelta(string value) {
    var parts = (string.IsNullOrEmpty(value) ? "down" : value).Trim().Split(' ');
    int n = parts.Length > 1 ? int.Parse(parts[1]) : 1, delta;
    if (!int.TryParse(parts[0], out delta)) delta = (parts[0].ToLowerInvariant() == "up" ? 120 : -120) * n;
    return delta;
  }

  // WPF reads the mouse only from real input, so posted pointer messages do nothing there. Wheel and
  // double-click map to UI Automation; the rest is refused instead of reported as done.
  static string ViaWpfPointer(IUIAutomationElement el, IntPtr root, string action, string value) {
    if (action == "wheel") {
      int delta = WheelDelta(value), lines = Math.Max(1, Math.Abs(delta) / 120);
      // The element itself or its nearest scrollable ancestor inside the target window.
      for (var e = el; e != null; e = A.ControlViewWalker.GetParentElement(e)) {
        var sp = Pattern<IUIAutomationScrollPattern>(e, 10004 /* Scroll */);
        if (sp != null && sp.CurrentVerticallyScrollable != 0) {
          for (int i = 0; i < lines; i++)
            sp.Scroll(ScrollAmount.ScrollAmount_NoAmount, delta < 0 ? ScrollAmount.ScrollAmount_SmallIncrement : ScrollAmount.ScrollAmount_SmallDecrement);
          return "wheel " + delta + " as scroll " + (delta < 0 ? "down " : "up ") + lines + " line(s) of \"" + Short(e.CurrentName, 60) + "\"";
        }
        if (e.CurrentNativeWindowHandle == root) break;
      }
      throw new InvalidOperationException("WPF ignores background wheel messages and nothing around this element can scroll (no UI Automation ScrollPattern)");
    }
    if (action == "double-click") {
      // Invoke is the element's default action (a grid row begins editing, a button clicks). The
      // LegacyIAccessible default action of WPF list items ("Double Click") does nothing, so it is not used.
      var inv = Pattern<IUIAutomationInvokePattern>(el, PInvoke);
      if (inv == null) throw new InvalidOperationException("WPF ignores background double-clicks and this element has no default action (UI Automation Invoke); an app's own double-click handler needs real input");
      var sel = Pattern<IUIAutomationSelectionItemPattern>(el, PSelectItem);
      if (sel != null) sel.Select(); // what the first click of a double-click does
      inv.Invoke();
      return "double-click as default action (Invoke)";
    }
    // UIA ShowContextMenu activated the WPF window in testing and opened no menu; WM_CONTEXTMENU is ignored.
    throw new InvalidOperationException("WPF ignores background " + action + " (it reads only the real mouse, and UI Automation's context menu call activates the window); this needs real input, ask the user");
  }

  static readonly Dictionary<string, int> Keys = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase) {
    { "enter", 0x0D }, { "return", 0x0D }, { "tab", 0x09 }, { "esc", 0x1B }, { "escape", 0x1B }, { "space", 0x20 },
    { "backspace", 0x08 }, { "delete", 0x2E }, { "del", 0x2E }, { "insert", 0x2D }, { "home", 0x24 }, { "end", 0x23 },
    { "pageup", 0x21 }, { "pagedown", 0x22 }, { "left", 0x25 }, { "up", 0x26 }, { "right", 0x27 }, { "down", 0x28 },
    { "ctrl", 0x11 }, { "control", 0x11 }, { "shift", 0x10 }, { "alt", 0x12 }, { "apps", 0x5D }, { "menu", 0x5D } };

  static int Vk(string key) {
    int vk;
    if (Keys.TryGetValue(key, out vk)) return vk;
    var f = Regex.Match(key, @"^[Ff]([1-9]|1[0-2])$");
    if (f.Success) return 0x70 + int.Parse(f.Groups[1].Value) - 1;
    if (key.Length == 1) return VkKeyScan(key[0]) & 0xFF;
    throw new ArgumentException("unknown key \"" + key + "\"");
  }

  static void PostKey(IntPtr h, int vk, bool up, bool alt) {
    uint sc = MapVirtualKey((uint)vk, 0);
    long l = 1 | (sc << 16) | (alt ? 1L << 29 : 0) | (up ? (3L << 30) : 0);
    int msg = alt || vk == 0x12 ? (up ? 0x0105 : 0x0104) /* WM_SYSKEY* */ : (up ? 0x0101 : 0x0100) /* WM_KEY* */;
    PostMessage(h, msg, new IntPtr(vk), new IntPtr(l));
  }

  // value: "Enter", "Down Down Enter", "ctrl+a": space-separated keys or plus-joined combinations.
  static string Press(IntPtr h, string value) {
    if (string.IsNullOrEmpty(value)) throw new ArgumentException("press needs value=<keys>, e.g. Enter, Tab, ctrl+a, \"Down Down Enter\"");
    var combos = value.Split(new[] { ' ' }, StringSplitOptions.RemoveEmptyEntries);
    // Check every key before sending any: a misspelt one must not leave half the keys sent.
    foreach (var combo in combos) Array.ConvertAll(combo.Split('+'), Vk);
    // A combination marks Ctrl/Shift/Alt as held on the target's thread. When the user is typing in
    // another window of that same thread (a second browser window), their keys would get it too.
    var front = GetForegroundWindow(); uint frontPid, targetPid;
    if (value.IndexOf('+') >= 0 && front != IntPtr.Zero && GetAncestor(front, 2) != GetAncestor(h, 2)
        && GetWindowThreadProcessId(front, out frontPid) == GetWindowThreadProcessId(h, out targetPid))
      throw new InvalidOperationException("the user is working in another window of this app, and a key combination sent now would mix into their typing; send it when they are in another app (to replace a text, use type)");
    foreach (var combo in combos) {
      var keys = combo.Split('+');
      var vks = Array.ConvertAll(keys, Vk);
      bool alt = Array.IndexOf(vks, 0x12) >= 0;
      // Apps read Ctrl/Shift/Alt with GetKeyState, which a posted message does not change. Share
      // the target thread's input state for a moment and mark the modifiers as held there only;
      // the user's own thread and keyboard are untouched.
      bool mods = vks.Length > 1;
      uint me = GetCurrentThreadId(), unusedPid, them = GetWindowThreadProcessId(h, out unusedPid);
      byte[] saved = new byte[256];
      if (mods && AttachThreadInput(me, them, true)) {
        GetKeyboardState(saved);
        var held = (byte[])saved.Clone();
        for (int i = 0; i < vks.Length - 1; i++) held[vks[i]] |= 0x80;
        SetKeyboardState(held);
      } else mods = false;
      try {
      // The app's TranslateMessage turns a posted WM_KEYDOWN into WM_CHAR itself (Enter, Tab,
      // Backspace, space). A single character goes in as WM_CHAR alone instead: from a key press it
      // would come out unshifted ("B" as "b", "@" as "2").
      if (vks.Length == 1 && keys[0].Length == 1) PostMessage(h, 0x0102 /* WM_CHAR */, new IntPtr(keys[0][0]), new IntPtr(1));
      else {
        foreach (var vk in vks) PostKey(h, vk, false, alt && vk != 0x12);
        for (int i = vks.Length - 1; i >= 0; i--) PostKey(h, vks[i], true, alt && vks[i] != 0x12);
      }
      Thread.Sleep(mods ? 200 : 30); // the app reads the key state while handling the messages
      } finally {
        if (mods) { SetKeyboardState(saved); AttachThreadInput(me, them, false); }
      }
    }
    return "press " + value;
  }

  public static string Act(string cachePath, string refId, string action, string value, bool allowForeground) {
    if (action == "focus" && !allowForeground)
      throw new InvalidOperationException("focus takes the user's foreground and keyboard; needs the allow-foreground flag (user consent)");
    IntPtr hwnd;
    IUIAutomationElement el = null;
    var spot = new POINT(); string text = null;
    // An OCR ref is only a point in a custom-drawn window: mouse messages are all that reach it.
    bool drawn = refId.StartsWith("t");
    if (drawn && action != "click" && !Pointer.Contains(action))
      throw new InvalidOperationException("an OCR ref takes click, double-click, right-click, hover, wheel or drag");
    if (drawn) spot = ResolveText(cachePath, refId, out hwnd, out text);
    else el = Resolve(cachePath, refId, out hwnd);
    bool posted = drawn || Pointer.Contains(action) || action == "press";
    uint targetPid; GetWindowThreadProcessId(hwnd, out targetPid);
    var fg = new Foreground();
    var root = GetAncestor(hwnd, 2 /* GA_ROOT */);
    if (root == IntPtr.Zero) root = hwnd;
    // The user agreed to this window taking the foreground: focus keeps it, press borrows it for the keys.
    bool consent = action == "focus" || (action == "press" && allowForeground), borrowed = false;
    // An app can bring itself forward while it handles the action: an explicit SetForegroundWindow
    // ignores WS_EX_NOACTIVATE. The watch hands the foreground back within milliseconds.
    // (Not LockSetForegroundWindow, as launch does: with it the hidden-desktop `hover` case fails.)
    if (!consent) fg.Watch(root, targetPid);
    string done, via = "window message";
    try {
    done = posted ? null : ViaMessage(el, action, value, fg);
    bool wpf = !drawn && Pointer.Contains(action) && el.CurrentFrameworkId == "WPF";
    if (done == null) {
      via = posted && !wpf ? "posted input" : "UI Automation";
      // Apps activate themselves while handling a pattern call or a click (WPF/XAML peers call
      // Focus(), menus want the foreground). WS_EX_NOACTIVATE on the top-level window turns that
      // into a no-op while the call itself still lands (the guard Cua Driver uses). Only the bit
      // we add is cleared.
      long ex = GetWindowLongPtr(root, -20 /* GWL_EXSTYLE */).ToInt64();
      bool guard = action != "focus" && !(action == "press" && allowForeground) && (ex & 0x08000000 /* WS_EX_NOACTIVATE */) == 0;
      if (guard) SetWindowLongPtr(root, -20, new IntPtr(ex | 0x08000000));
      try {
        if (action == "press") {
          // Keys go to the element's own window; windowless elements (WPF, Chromium) get keyboard
          // focus inside their window first, which the guard keeps from activating it.
          var own = P(el, NativeHwnd);
          var kh = own is int && (int)own != 0 ? new IntPtr((int)own) : root;
          var inv = kh == root && !allowForeground && Regex.IsMatch(value ?? "", @"^\s*(enter|return)\s*$", RegexOptions.IgnoreCase) ? Pattern<IUIAutomationInvokePattern>(el, PInvoke) : null;
          if (inv != null) {
            // Enter on a focused button or link presses it: same as its Invoke, which needs no focus.
            inv.Invoke(); done = "press Enter as the element's default action (Invoke)"; via = "UI Automation";
          } else {
            if (kh == root) {
              // Windowless controls (WPF, Chromium) take keys only while their window has the focus.
              // WPF does not expose its default (IsDefault) button to UI Automation, so Enter in a text box cannot be mapped.
              if (allowForeground) { el.SetFocus(); borrowed = true; }
              // A text field in a Chromium window (browsers, Electron) is the exception: a posted click
              // puts the caret in it, and the page then takes posted keys while its window stays inactive.
              else if (el.CurrentFrameworkId == "Chrome" && el.CachedControlType == 50004 /* Edit */ && !Flag(el, Offscreen)) {
                ViaPointer(Center(el), root, "click", null, cachePath);
                Thread.Sleep(150);
                // The keys go to whatever has the focus in that window: make sure it is this field
                // (a banner or dialog over it would have taken the click instead).
                for (int i = 0; i < 7 && el.CurrentHasKeyboardFocus == 0; i++) Thread.Sleep(50);
                if (el.CurrentHasKeyboardFocus == 0) throw new InvalidOperationException("a background click did not put the caret in this field (something on the page may cover it), so no key was sent; read the window again, use type for text, or pass the allow-foreground flag (user consent)");
              } else throw new InvalidOperationException("this control takes keys only while its window is focused (without focus: Enter on a button or link, and any keys in a visible text field of a browser or Electron window); use type for text, or pass the allow-foreground flag (user consent)");
            }
            done = Press(kh, value);
          }
        } else if (wpf) done = ViaWpfPointer(el, root, action, value);
        else if (posted) done = ViaPointer(drawn ? spot : Center(el), root, action, value, cachePath);
        else done = ViaUia(el, action, value, root);
        if (guard) Thread.Sleep(250); // late activations land inside the guard
      } finally {
        if (guard) SetWindowLongPtr(root, -20, new IntPtr(GetWindowLongPtr(root, -20).ToInt64() & ~0x08000000L));
      }
    }

    Thread.Sleep(150); // let the app react before reading back
    } catch (Exception e) {
      fg.StopWatch();
      // A press that borrowed the foreground and then failed must not leave the app in front.
      if (borrowed && fg.GiveBack(true)) fg.Returned++;
      if (fg.Returned > 0) throw new InvalidOperationException(e.Message + " (the target app had come forward; the user's window was put back in front)", e);
      throw;
    } finally { fg.StopWatch(); }
    string after;
    if (drawn) after = refId + " \"" + text + "\" at " + spot.X + "," + spot.Y;
    else try { after = Describe(el.BuildUpdatedCache(Request()), refId, false) ?? refId; } catch (COMException) { after = refId + " (element gone after action)"; }
    var result = "ok " + done + " via " + via + ": " + after;
    var fgAfter = GetForegroundWindow(); uint fgPid; GetWindowThreadProcessId(fgAfter, out fgPid);
    bool front = fgAfter != fg.Before && fgPid == targetPid;
    // Only focus keeps the foreground; a press that borrowed it returns it once the keys are in.
    if (front && action != "focus" && fg.GiveBack(true)) { fg.Returned++; front = false; }
    if (front) result += "\nWARNING: the target app came to the foreground; the user's keystrokes now go to it";
    else if (fg.Returned > 0 && borrowed) result += "\nnote: the window had the foreground for the keys; the user's window was put back in front";
    else if (fg.Returned > 0) result += "\nnote: the target app came forward while handling this" + (fg.Ms >= 0 ? " (for at most " + fg.Ms + " ms)" : "") + "; the user's window was put back in front";
    return result;
  }

  // Remembers the user's foreground window when an operation starts. If an app took it meanwhile,
  // GiveBack returns it without injecting input and puts the app just behind it. `ours`: the window
  // that came forward is the app being operated or launched, so the user (who may be typing in
  // their own window) did not switch to it; otherwise only when they have not touched the input since.
  public sealed class Foreground {
    public IntPtr Before;
    public readonly uint Since;
    public int Returned;   // times the foreground was handed back
    public long Ms = -1;   // how long the app had it at most (since the last check that saw it elsewhere)
    Thread watch; volatile bool stop;
    readonly System.Diagnostics.Stopwatch clock = System.Diagnostics.Stopwatch.StartNew(); long backAt;
    public Foreground() : this(GetForegroundWindow(), GetTickCount()) { }
    // The background launch watcher continues the launch call's watch.
    public Foreground(IntPtr before, uint since) { Before = before; Since = since; }

    // Keeps checking the real foreground while an action runs. The operated window
    // coming forward is the app's doing: hand the foreground back at once, not when the action
    // ends. A visible window of another app is where the user went, and becomes the one to hand
    // back to. A dialog the click opened (Opened) is handed back the same way. Other windows of the
    // operated app (the Explorer taskbar when the target is an Explorer window) are left to the check
    // at the end of the action.
    // root zero (launch): any window of the started process counts as the app coming forward.
    public void Watch(IntPtr root, uint appPid) {
      if (Before == root) return; // the user is working in that window
      watch = new Thread(() => {
        timeBeginPeriod(1); // Sleep(1) lasts up to 15 ms otherwise (and may still, for a hidden process)
        long ok = clock.ElapsedMilliseconds;
        try {
          while (!stop) {
            var now = GetForegroundWindow(); uint pid = 0;
            if (now != IntPtr.Zero && now != Before) {
              GetWindowThreadProcessId(now, out pid);
              if (root != IntPtr.Zero ? now == root || now == Opened : pid == appPid) {
                if (!GiveBack(true)) break; // not possible (an elevated or minimized window): the caller warns
                Returned++; Ms = backAt - ok;
              } else if (pid != appPid && IsWindowVisible(now)) Before = now;
            }
            ok = clock.ElapsedMilliseconds;
            Thread.Sleep(1);
          }
        } finally { timeEndPeriod(1); }
      });
      watch.IsBackground = true; watch.Start();
    }
    public void StopWatch() { stop = true; if (watch != null) watch.Join(); }
    // A dialog the action opened: the watch hands it back like the operated window.
    public volatile IntPtr Opened;

    public bool GiveBack(bool ours) {
      var now = GetForegroundWindow();
      // A window the user minimized or closed meanwhile is not somewhere to send their keys.
      if (now == Before || Before == IntPtr.Zero || !IsWindow(Before) || !IsWindowVisible(Before) || IsIconic(Before)) return false;
      var li = new LASTINPUTINFO(); li.cbSize = (uint)Marshal.SizeOf(li);
      if (!ours && (!GetLastInputInfo(ref li) || (int)(li.dwTime - Since) > 0)) return false;
      // Sharing the foreground thread's input state lets this background process hand the
      // foreground over; no input is synthesized.
      uint unusedPid, me = GetCurrentThreadId(), them = now == IntPtr.Zero ? 0 : GetWindowThreadProcessId(now, out unusedPid);
      bool attached = them != 0 && them != me && AttachThreadInput(me, them, true);
      try { BringWindowToTop(Before); SetForegroundWindow(Before); }
      finally { if (attached) AttachThreadInput(me, them, false); }
      if (GetForegroundWindow() != Before) return false;
      backAt = clock.ElapsedMilliseconds;
      if (now != IntPtr.Zero) SetWindowPos(now, Before, 0, 0, 0, 0, 0x0010 | 0x0002 | 0x0001 /* NOACTIVATE | NOMOVE | NOSIZE */);
      return true;
    }
  }

  // --- windows and apps ---------------------------------------------------------------------------

  // move "x,y" | resize "w,h" | minimize | restore | close. Nothing here activates the window; a
  // restored window goes to the bottom of the z-order so it does not cover the user's app either.
  public static string Window(long hwndValue, string title, string action, string value) {
    var h = new IntPtr(hwndValue);
    const uint NoActivate = 0x0010, NoZOrder = 0x0004, NoSize = 0x0001, NoMove = 0x0002;
    var m = Regex.Match(value ?? "", @"^\s*(-?\d+)\s*,\s*(-?\d+)\s*$");
    switch (action) {
      case "move":
        if (!m.Success) throw new ArgumentException("move needs value=\"x,y\"");
        SetWindowPos(h, IntPtr.Zero, int.Parse(m.Groups[1].Value), int.Parse(m.Groups[2].Value), 0, 0, NoActivate | NoZOrder | NoSize); break;
      case "resize":
        if (!m.Success) throw new ArgumentException("resize needs value=\"width,height\"");
        SetWindowPos(h, IntPtr.Zero, 0, 0, int.Parse(m.Groups[1].Value), int.Parse(m.Groups[2].Value), NoActivate | NoZOrder | NoMove); break;
      case "minimize": ShowWindow(h, 7 /* SW_SHOWMINNOACTIVE */); break;
      case "restore":
        ShowWindow(h, 4 /* SW_SHOWNOACTIVATE */);
        SetWindowPos(h, new IntPtr(1) /* HWND_BOTTOM */, 0, 0, 0, 0, NoActivate | NoSize | NoMove); break;
      case "close": PostMessage(h, 0x0010 /* WM_CLOSE */, IntPtr.Zero, IntPtr.Zero); return "ok asked " + title + " to close";
      default: throw new ArgumentException("unknown window action " + action);
    }
    RECT r; GetWindowRect(h, out r);
    return "ok " + action + ": " + title + (IsIconic(h) ? " (minimized)" : string.Format(" @{0},{1} {2}x{3}", r.L, r.T, r.R - r.L, r.B - r.T));
  }

  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  struct SHELLEXECUTEINFO {
    public int cbSize; public uint fMask; public IntPtr hwnd; public string lpVerb, lpFile, lpParameters, lpDirectory;
    public int nShow; public IntPtr hInstApp, lpIDList; public string lpClass; public IntPtr hkeyClass; public uint dwHotKey;
    public IntPtr hIcon, hProcess;
  }
  [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool ShellExecuteEx(ref SHELLEXECUTEINFO i);
  [DllImport("kernel32.dll")] static extern uint GetProcessId(IntPtr h);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);

  // Starts an app (path, App Paths name, document or URL) shown without activation, and keeps
  // foreground changes locked while it starts. Returns the process id, or 0 when an existing
  // instance took the request over.
  public static int LaunchGaveBack; // times the last Launch handed the foreground back to the user
  public static int Launch(string file, string args) {
    var i = new SHELLEXECUTEINFO { lpFile = file, lpParameters = string.IsNullOrEmpty(args) ? null : args, nShow = 4 /* SW_SHOWNOACTIVATE */, fMask = 0x40 /* SEE_MASK_NOCLOSEPROCESS */ };
    i.cbSize = Marshal.SizeOf(i);
    var fg = new Foreground();
    int pid = 0;
    bool locked = LockSetForegroundWindow(1 /* LSFW_LOCK */);
    try {
      if (!ShellExecuteEx(ref i)) throw new InvalidOperationException("could not start " + file + " (error " + Marshal.GetLastWin32Error() + ")");
      if (i.hProcess != IntPtr.Zero) { pid = (int)GetProcessId(i.hProcess); CloseHandle(i.hProcess); }
      // An app started from the user's own foreground app (an agent in their terminal) may come
      // forward despite the lock and SW_SHOWNOACTIVATE: hand the foreground back as it happens.
      if (pid != 0) fg.Watch(IntPtr.Zero, (uint)pid);
      Thread.Sleep(1500); // first window shows inside the lock
    } finally {
      fg.StopWatch();
      if (locked) LockSetForegroundWindow(2 /* LSFW_UNLOCK */);
    }
    LaunchGaveBack = fg.Returned;
    return pid;
  }

  static string ViaUia(IUIAutomationElement el, string action, string value, IntPtr root) {
    string done;
    switch (action) {
      case "click": done = Click(el); break;
      case "type": {
        var vp = Pattern<IUIAutomationValuePattern>(el, PValue);
        if (vp == null) throw new InvalidOperationException("element has no value to set");
        if (vp.CurrentIsReadOnly != 0) throw new InvalidOperationException("element is read-only");
        vp.SetValue(value ?? ""); done = "set value"; break;
      }
      case "check": done = SetChecked(el, true); break;
      case "uncheck": done = SetChecked(el, false); break;
      case "select": done = Select(el, value, root); break;
      case "expand":
      case "collapse": {
        var ep = Pattern<IUIAutomationExpandCollapsePattern>(el, PExpand);
        if (ep == null) throw new InvalidOperationException("element cannot expand or collapse");
        if (action == "expand") ep.Expand(); else ep.Collapse();
        done = action; break;
      }
      case "scroll": {
        var sp = Pattern<IUIAutomationScrollItemPattern>(el, PScrollItem);
        if (sp == null) throw new InvalidOperationException("element cannot be scrolled into view");
        sp.ScrollIntoView(); done = "scroll into view"; break;
      }
      case "focus": el.SetFocus(); done = "focus"; break;
      default: throw new ArgumentException("unknown action " + action);
    }
    return done;
  }
}

// The activity indicator (uia.ps1 -Op indicator): "Sidehand: <what>" with a Stop/Resume button in the
// corner of the primary work area, one per desktop. It never takes the foreground or the keyboard:
// no-activate, topmost tool window (no taskbar button), shown with SetWindowPos(NOACTIVATE), clicks
// answered MA_NOACTIVATE, and no child controls that could take focus. State is in two files that
// every Sidehand process on the desktop reads: the stop file (exists while stopped) and the activity
// file (text; its write time is when the action ended, or a minute ahead while it runs).
public static class SidehandIndicator {
  delegate IntPtr WndProc(IntPtr h, uint msg, IntPtr w, IntPtr l);
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  struct WNDCLASS { public uint style; public WndProc proc; public int clsExtra, wndExtra; public IntPtr inst, icon, cursor, background; public string menu, name; }
  [StructLayout(LayoutKind.Sequential)] struct MSG { public IntPtr h; public uint msg; public IntPtr w, l; public uint time; public int x, y; }
  [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
  [StructLayout(LayoutKind.Sequential)]
  struct PAINTSTRUCT { public IntPtr dc; public bool erase; public RECT rc; public bool restore, incUpdate; [MarshalAs(UnmanagedType.ByValArray, SizeConst = 32)] public byte[] reserved; }
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern ushort RegisterClass(ref WNDCLASS c);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateWindowEx(uint ex, string cls, string name, uint style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr param);
  [DllImport("user32.dll")] static extern IntPtr DefWindowProc(IntPtr h, uint msg, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] static extern int GetMessage(out MSG m, IntPtr h, uint min, uint max);
  [DllImport("user32.dll")] static extern IntPtr DispatchMessage(ref MSG m);
  [DllImport("user32.dll")] static extern bool DestroyWindow(IntPtr h);
  [DllImport("user32.dll")] static extern void PostQuitMessage(int code);
  [DllImport("user32.dll")] static extern IntPtr SetTimer(IntPtr h, IntPtr id, uint ms, IntPtr f);
  [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr h, int id, uint mods, uint vk);
  [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hgt, uint flags);
  [DllImport("user32.dll")] static extern bool InvalidateRect(IntPtr h, IntPtr r, bool erase);
  [DllImport("user32.dll")] static extern IntPtr BeginPaint(IntPtr h, out PAINTSTRUCT p);
  [DllImport("user32.dll")] static extern bool EndPaint(IntPtr h, ref PAINTSTRUCT p);
  [DllImport("user32.dll")] static extern int FillRect(IntPtr dc, ref RECT r, IntPtr brush);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int DrawText(IntPtr dc, string s, int n, ref RECT r, uint format);
  [DllImport("user32.dll")] static extern bool SystemParametersInfo(uint action, uint p, out RECT r, uint ini);
  [DllImport("user32.dll")] static extern uint GetDpiForSystem();
  [DllImport("user32.dll")] static extern IntPtr LoadCursor(IntPtr inst, IntPtr id);
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr GetModuleHandle(string name);
  [DllImport("gdi32.dll")] static extern IntPtr CreateSolidBrush(uint rgb);
  [DllImport("gdi32.dll")] static extern uint SetTextColor(IntPtr dc, uint rgb);
  [DllImport("gdi32.dll")] static extern int SetBkMode(IntPtr dc, int mode);
  [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr o);
  [DllImport("gdi32.dll", CharSet = CharSet.Unicode)]
  static extern IntPtr CreateFont(int h, int w, int esc, int orient, int weight, uint italic, uint underline, uint strike, uint charset, uint outPrec, uint clipPrec, uint quality, uint pitch, string face);

  static WndProc proc; // referenced here so the collector never frees what the window calls
  static string activityPath, stopPath, text = "";
  static bool shown, stopped;
  static int idleTicks, width, height, scale;
  static IntPtr font, back, stopBrush, resumeBrush;

  public static void Run(string mutexName, string activity, string stop) {
    bool first;
    using (new Mutex(true, mutexName, out first)) {
      if (!first) return; // another Sidehand process shows it already
      activityPath = activity; stopPath = stop; proc = Proc;
      var c = new WNDCLASS { proc = proc, inst = GetModuleHandle(null), cursor = LoadCursor(IntPtr.Zero, new IntPtr(32512) /* IDC_ARROW */), name = "SidehandIndicator" };
      RegisterClass(ref c);
      scale = (int)GetDpiForSystem();
      width = 380 * scale / 96; height = 36 * scale / 96;
      font = CreateFont(-13 * scale / 96, 0, 0, 0, 400, 0, 0, 0, 1, 0, 0, 5 /* CLEARTYPE */, 0, "Segoe UI");
      back = CreateSolidBrush(0x202020); stopBrush = CreateSolidBrush(0x2828C0); resumeBrush = CreateSolidBrush(0x308030);
      RECT work; SystemParametersInfo(0x30 /* SPI_GETWORKAREA */, 0, out work, 0);
      int margin = 12 * scale / 96;
      var h = CreateWindowEx(0x08000000 | 0x8 | 0x80 /* NOACTIVATE | TOPMOST | TOOLWINDOW */, "SidehandIndicator", "", 0x80000000 /* WS_POPUP */,
        work.R - width - margin, work.B - height - margin, width, height, IntPtr.Zero, IntPtr.Zero, c.inst, IntPtr.Zero);
      // Ctrl+Alt+Pause; with Ctrl held, Pause arrives as VK_CANCEL (Break). A hotkey needs no focus.
      RegisterHotKey(h, 1, 0x4003 /* CONTROL | ALT | NOREPEAT */, 0x13 /* VK_PAUSE */);
      RegisterHotKey(h, 2, 0x4003, 0x03 /* VK_CANCEL */);
      SetTimer(h, new IntPtr(1), 200, IntPtr.Zero);
      Tick(h);
      MSG m;
      while (GetMessage(out m, IntPtr.Zero, 0, 0) > 0) DispatchMessage(ref m);
    }
  }

  static RECT Button() { int p = 6 * scale / 96; return new RECT { L = width - 80 * scale / 96, T = p, R = width - p, B = height - p }; }

  static IntPtr Proc(IntPtr h, uint msg, IntPtr w, IntPtr l) {
    switch (msg) {
      case 0x0021: return new IntPtr(3); // WM_MOUSEACTIVATE: MA_NOACTIVATE
      case 0x0113: Tick(h); return IntPtr.Zero; // WM_TIMER
      case 0x0312: SetStopped(true); Tick(h); return IntPtr.Zero; // WM_HOTKEY: stop only
      case 0x0202: { // WM_LBUTTONUP
        int x = (short)(l.ToInt64() & 0xFFFF), y = (short)((l.ToInt64() >> 16) & 0xFFFF);
        var b = Button();
        if (x >= b.L && x < b.R && y >= b.T && y < b.B) { SetStopped(!stopped); Tick(h); }
        return IntPtr.Zero;
      }
      case 0x000F: Paint(h); return IntPtr.Zero;
      case 0x0002: PostQuitMessage(0); return IntPtr.Zero; // WM_DESTROY
    }
    return DefWindowProc(h, msg, w, l);
  }

  static void SetStopped(bool on) {
    try { if (on) File.WriteAllText(stopPath, DateTime.Now.ToString("s")); else File.Delete(stopPath); }
    catch (IOException) { } catch (UnauthorizedAccessException) { }
  }

  static void Tick(IntPtr h) {
    bool wasStopped = stopped; string was = text;
    stopped = File.Exists(stopPath);
    var until = File.GetLastWriteTimeUtc(activityPath); // 1601 when there is none
    try { text = File.ReadAllText(activityPath); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    bool show = stopped || DateTime.UtcNow < until.AddSeconds(3);
    if (show != shown) {
      SetWindowPos(h, new IntPtr(-1) /* TOPMOST */, 0, 0, 0, 0, 0x10 | 0x2 | 0x1 | (show ? 0x40u : 0x80u) /* NOACTIVATE | NOMOVE | NOSIZE | SHOW or HIDE */);
      shown = show;
    }
    if (stopped != wasStopped || text != was) InvalidateRect(h, IntPtr.Zero, true);
    idleTicks = show ? 0 : idleTicks + 1;
    if (idleTicks > 150) DestroyWindow(h); // 30 s without activity: the next action starts it again
  }

  static void Paint(IntPtr h) {
    PAINTSTRUCT ps; var dc = BeginPaint(h, out ps);
    var all = new RECT { R = width, B = height };
    FillRect(dc, ref all, back);
    SelectObject(dc, font); SetBkMode(dc, 1 /* TRANSPARENT */); SetTextColor(dc, 0xFFFFFF);
    var b = Button();
    var t = new RECT { L = 10 * scale / 96, R = b.L - 6 * scale / 96, B = height };
    const uint Line = 0x20 | 0x4 | 0x800; // SINGLELINE | VCENTER | NOPREFIX
    DrawText(dc, stopped ? "Sidehand stopped: agents must ask you first" : "Sidehand: " + text, -1, ref t, Line | 0x8000 /* END_ELLIPSIS */);
    FillRect(dc, ref b, stopped ? resumeBrush : stopBrush);
    DrawText(dc, stopped ? "Resume" : "Stop", -1, ref b, Line | 0x1 /* CENTER */);
    EndPaint(h, ref ps);
  }
}
