// WPF twin of TestWinForms: native UIA providers instead of Win32 proxies. Same event log format.
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;

class TestWpf {
  public class FileRow { public string File { get; set; } public override string ToString() { return File; } }
  static string role, logPath;
  static IntPtr handback; // see TestWinForms
  [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
  static void Log(string s) { try { File.AppendAllText(logPath, DateTime.UtcNow.Ticks + "\t" + role + "\t" + s + "\r\n"); } catch { } }

  [STAThread]
  static void Main(string[] a) {
    role = a[0]; logPath = a[1];
    if (a.Length > 2) handback = new IntPtr(long.Parse(a[2]));
    var w = new Window { Title = "Sidehand Test WPF " + role, Left = 40, Top = 420, Width = 460, Height = 600, ShowActivated = false };
    w.Activated += (s, e) => { Log("form.activated"); if (handback != IntPtr.Zero) w.Dispatcher.BeginInvoke(new Action(() => SetForegroundWindow(handback))); };
    w.Deactivated += (s, e) => Log("form.deactivate");
    var p = new StackPanel();
    var name = new TextBox { Name = "NameBox" }; System.Windows.Automation.AutomationProperties.SetName(name, "Name");
    var status = new TextBlock { Text = "idle" };
    // IsDefault is not exposed to UI Automation, so Enter in the Name box stays refused even with a default button.
    var apply = new Button { Content = "Apply", IsDefault = true };
    var chk = new CheckBox { Content = "Enable" };
    var combo = new ComboBox(); System.Windows.Automation.AutomationProperties.SetName(combo, "Mode");
    foreach (var x in new[] { "Alpha", "Beta", "Gamma" }) combo.Items.Add(x);
    var list = new ListBox { Height = 60 }; System.Windows.Automation.AutomationProperties.SetName(list, "Items");
    foreach (var x in new[] { "One", "Two", "Three" }) list.Items.Add(x);
    // Scrolls only through UI Automation (WPF ignores posted wheel messages).
    var rows = new ListBox { Height = 60 }; System.Windows.Automation.AutomationProperties.SetName(rows, "Rows");
    for (int i = 1; i <= 30; i++) rows.Items.Add("Row " + i);
    rows.AddHandler(ScrollViewer.ScrollChangedEvent, new ScrollChangedEventHandler((s, e) => { if (e.VerticalChange != 0) Log("rows.scroll"); }));
    // Double-click on a grid row begins editing; without real input that is the row's Invoke.
    var grid = new DataGrid { Height = 70, ItemsSource = new List<FileRow> { new FileRow { File = "report.txt" }, new FileRow { File = "notes.txt" } } };
    System.Windows.Automation.AutomationProperties.SetName(grid, "Files");
    grid.BeginningEdit += (s, e) => Log("grid.edit " + e.Row.Item);
    var tree = new TreeView { Height = 70 }; System.Windows.Automation.AutomationProperties.SetName(tree, "Folders");
    var root = new TreeViewItem { Header = "Root" }; root.Items.Add("Child A"); root.Items.Add("Child B"); tree.Items.Add(root);
    apply.Click += (s, e) => { status.Text = "applied:" + name.Text; Log("apply.click"); };
    name.TextChanged += (s, e) => Log("text len=" + name.Text.Length);
    chk.Checked += (s, e) => Log("check True");
    combo.SelectionChanged += (s, e) => Log("combo " + combo.SelectedItem);
    list.SelectionChanged += (s, e) => Log("list " + list.SelectedItem);
    root.Expanded += (s, e) => Log("tree.expand");
    // Pointer target, same events as the WinForms pad.
    var pad = new Label { Content = "Pad", Height = 50, Background = System.Windows.Media.Brushes.Gainsboro };
    System.Windows.Automation.AutomationProperties.SetName(pad, "Pad");
    pad.ContextMenu = new ContextMenu(); pad.ContextMenu.Items.Add(new MenuItem { Header = "Pad item" });
    pad.ContextMenuOpening += (s, e) => Log("contextmenu");
    Point down = new Point(); bool hovered = false;
    pad.MouseDown += (s, e) => { down = e.GetPosition(pad); Log("mouse down " + e.ChangedButton); if (e.ClickCount == 2) Log("dblclick"); };
    pad.MouseUp += (s, e) => { var p2 = e.GetPosition(pad); if (e.ChangedButton == System.Windows.Input.MouseButton.Right) Log("rightclick");
      if (e.ChangedButton == System.Windows.Input.MouseButton.Left && Math.Abs(p2.X - down.X) + Math.Abs(p2.Y - down.Y) > 30) Log("drag"); };
    pad.MouseWheel += (s, e) => Log("wheel " + e.Delta);
    pad.MouseMove += (s, e) => { if (e.LeftButton == System.Windows.Input.MouseButtonState.Released && !hovered) { hovered = true; Log("hover"); } };
    name.KeyDown += (s, e) => Log("key " + e.Key + ((System.Windows.Input.Keyboard.Modifiers & System.Windows.Input.ModifierKeys.Control) != 0 ? " ctrl" : ""));
    foreach (var c in new Control[] { name, apply, chk, combo, list, rows, grid, tree }) {
      var cc = c; var label = c.GetType().Name;
      c.GotKeyboardFocus += (s, e) => { if (e.NewFocus == cc) Log("focus+ " + label); };
    }
    foreach (UIElement c in new UIElement[] { name, apply, status, chk, combo, list, rows, grid, tree, pad }) p.Children.Add(c);
    w.Content = p;
    w.Loaded += (s, e) => Log("shown");
    new Application().Run(w);
  }
}
