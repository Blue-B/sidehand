// WinForms test app for test/isolated (target or decoy). Logs every activation/focus/state event.
using System;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Forms;

class TestWinForms : Form {
  static string role, logPath;
  // Optional 3rd arg (demo/record.ps1 on the real desktop): if this window ever gets activated,
  // hand the foreground straight back to that window so the run cannot strand the user.
  static IntPtr handback;
  [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
  internal static void Log(string s) {
    try { File.AppendAllText(logPath, DateTime.UtcNow.Ticks + "\t" + role + "\t" + s + "\r\n"); } catch { }
  }

  [STAThread]
  static void Main(string[] a) {
    role = a[0]; logPath = a[1];
    if (a.Length > 2) handback = new IntPtr(long.Parse(a[2]));
    Application.EnableVisualStyles();
    // "drawn": a target whose UI is painted text only (like games and canvas apps), for OCR refs.
    if (role == "drawn") { role = "target"; Application.Run(new DrawnForm()); return; }
    Application.Run(new TestWinForms());
  }

  // The target starts inactive, so any later form.activated / focus+ is caused by the tool under test.
  // "launched" behaves like an ordinary app that activates itself when it opens (for launch tests).
  static bool launched;
  protected override bool ShowWithoutActivation { get { return role == "target" && !launched; } }

  TestWinForms() {
    if (role == "launched") { launched = true; role = "target"; }
    // "twin": a target whose app also has an unrelated second window (another browser window, say).
    if (role == "twin") { role = "target"; Shown += (s, e) => new OtherWindow().Show(); }
    Text = role == "decoy" ? "Sidehand Test Decoy" : launched ? "Sidehand Test Launched" : "Sidehand Test WinForms";
    StartPosition = FormStartPosition.Manual;
    Location = new Point(role == "decoy" ? 520 : 20, 20);
    Size = new Size(470, 380);
    Activated += (s, e) => { Log("form.activated"); if (handback != IntPtr.Zero) BeginInvoke(new Action(() => SetForegroundWindow(handback))); };
    Deactivate += (s, e) => Log("form.deactivate");
    Shown += (s, e) => Log("shown");

    var name = new TextBox { Name = "NameBox", AccessibleName = "Name", Location = new Point(10, 10), Width = 200 };
    var apply = new Button { Name = "ApplyBtn", Text = "Apply", Location = new Point(220, 8) };
    var status = new Label { Name = "Status", Text = "idle", Location = new Point(310, 12), AutoSize = true };
    var chk = new CheckBox { Name = "EnableChk", Text = "Enable", Location = new Point(10, 40) };
    var combo = new ComboBox { Name = "ModeCombo", AccessibleName = "Mode", DropDownStyle = ComboBoxStyle.DropDownList, Location = new Point(10, 70), Width = 150 };
    combo.Items.AddRange(new object[] { "Alpha", "Beta", "Gamma" });
    var list = new ListBox { Name = "ItemList", AccessibleName = "Items", Location = new Point(10, 100), Size = new Size(150, 60) };
    list.Items.AddRange(new object[] { "One", "Two", "Three" });
    var tree = new TreeView { Name = "FolderTree", AccessibleName = "Folders", Location = new Point(180, 100), Size = new Size(200, 90) };
    var root = tree.Nodes.Add("Root"); root.Nodes.Add("Child A"); root.Nodes.Add("Child B");
    var panel = new Panel { Name = "ScrollPanel", AccessibleName = "Long panel", Location = new Point(10, 200), Size = new Size(380, 100), AutoScroll = true, BorderStyle = BorderStyle.FixedSingle };
    var far = new Button { Name = "FarBtn", Text = "Far button", Location = new Point(10, 600) };
    panel.Controls.Add(far);
    // Pointer target: logs right-click, double-click, wheel, hover and drags.
    var pad = new Panel { Name = "Pad", AccessibleName = "Pad", Location = new Point(395, 10), Size = new Size(55, 180), BackColor = Color.Gainsboro };
    var padMenu = new ContextMenuStrip(); padMenu.Items.Add("Pad item"); padMenu.Opening += (s, e) => Log("contextmenu");
    pad.ContextMenuStrip = padMenu;
    Point down = Point.Empty; bool hovered = false;
    pad.MouseDown += (s, e) => { down = e.Location; Log("mouse down " + e.Button); };
    pad.MouseUp += (s, e) => { if (e.Button == MouseButtons.Right) Log("rightclick"); if (e.Button == MouseButtons.Left && Math.Abs(e.Y - down.Y) + Math.Abs(e.X - down.X) > 30) Log("drag"); };
    pad.MouseDoubleClick += (s, e) => Log("dblclick");
    pad.MouseWheel += (s, e) => Log("wheel " + e.Delta);
    pad.MouseMove += (s, e) => { if (!hovered) { hovered = true; Log("hover " + e.Button); } };
    name.KeyDown += (s, e) => Log("key " + e.KeyCode + (e.Control ? " ctrl" : ""));
    Resize += (s, e) => Log("state " + WindowState);
    Move += (s, e) => Log("moved");

    apply.Click += (s, e) => { status.Text = "applied:" + name.Text; Log("apply.click"); };
    far.Click += (s, e) => Log("far.click");
    name.TextChanged += (s, e) => { Log("text len=" + name.Text.Length); Log("text=" + name.Text); };
    chk.CheckedChanged += (s, e) => Log("check " + chk.Checked);
    combo.SelectedIndexChanged += (s, e) => Log("combo " + combo.SelectedItem);
    combo.DropDown += (s, e) => Log("combo.dropdown");
    combo.DropDownClosed += (s, e) => Log("combo.closed");
    list.SelectedIndexChanged += (s, e) => Log("list " + list.SelectedItem);
    tree.AfterExpand += (s, e) => Log("tree.expand");
    tree.AfterCollapse += (s, e) => Log("tree.collapse");
    panel.Scroll += (s, e) => Log("panel.scroll");
    foreach (Control c in new Control[] { name, apply, chk, combo, list, tree, far }) {
      var cc = c;
      c.GotFocus += (s, e) => Log("focus+ " + cc.Name);
      c.LostFocus += (s, e) => Log("focus- " + cc.Name);
    }
    Controls.AddRange(new Control[] { name, apply, status, chk, combo, list, tree, panel, pad });
  }
}

// Custom-drawn target: UI Automation sees one empty pane; the labels exist only as pixels.
// Logs which label a mouse message hit, or the point when it hit none.
class DrawnForm : Form {
  protected override bool ShowWithoutActivation { get { return true; } }
  static readonly string[] Labels = { "Open file", "Save report", "Export", "Settings" };
  static readonly Point[] At = { new Point(20, 20), new Point(220, 20), new Point(20, 150), new Point(220, 150) };
  readonly RectangleF[] hit = new RectangleF[Labels.Length];

  public DrawnForm() {
    Text = "Sidehand Test Drawn"; StartPosition = FormStartPosition.Manual; Location = new Point(20, 20); Size = new Size(470, 300);
    Activated += (s, e) => TestWinForms.Log("form.activated");
    Shown += (s, e) => TestWinForms.Log("shown");
    var font = new Font("Segoe UI", 12f);
    var canvas = new Panel { Dock = DockStyle.Fill, BackColor = Color.White };
    canvas.Paint += (s, e) => {
      for (int i = 0; i < Labels.Length; i++) {
        hit[i] = new RectangleF(At[i], e.Graphics.MeasureString(Labels[i], font));
        e.Graphics.DrawString(Labels[i], font, Brushes.Black, At[i]);
      }
    };
    Func<Point, string> which = p => {
      for (int i = 0; i < Labels.Length; i++) if (hit[i].Contains(p)) return Labels[i];
      return "none " + p.X + "," + p.Y;
    };
    bool hovered = false; Point down = Point.Empty;
    // MouseDown, not MouseClick: WinForms raises Click only when WindowFromPoint is the control, never while covered.
    canvas.MouseDown += (s, e) => { down = e.Location; TestWinForms.Log("drawn." + (e.Button == MouseButtons.Right ? "rightclick " : e.Clicks == 2 ? "dblclick " : "click ") + which(e.Location)); };
    canvas.MouseUp += (s, e) => { if (e.Button == MouseButtons.Left && Math.Abs(e.X - down.X) + Math.Abs(e.Y - down.Y) > 30) TestWinForms.Log("drawn.drag " + which(down) + " -> " + which(e.Location)); };
    canvas.MouseWheel += (s, e) => TestWinForms.Log("drawn.wheel " + e.Delta + " " + which(e.Location));
    canvas.MouseMove += (s, e) => { if (!hovered) { hovered = true; TestWinForms.Log("drawn.hover " + which(e.Location)); } };
    canvas.GotFocus += (s, e) => TestWinForms.Log("focus+ canvas");
    Controls.Add(canvas);
  }
}

// The twin target's second window: sidehand must never operate it through the target.
class OtherWindow : Form {
  protected override bool ShowWithoutActivation { get { return true; } }
  public OtherWindow() {
    Text = "Sidehand Test Other Window"; StartPosition = FormStartPosition.Manual; Location = new Point(20, 420); Size = new Size(300, 150);
    var list = new ListBox { AccessibleName = "Other items", Location = new Point(10, 10), Size = new Size(150, 60) };
    list.Items.AddRange(new object[] { "Elsewhere" });
    list.SelectedIndexChanged += (s, e) => TestWinForms.Log("other.list " + list.SelectedItem);
    Controls.Add(list);
  }
}
