// Windows for the demo recording (demo/record.ps1):
//   stage    dark backdrop with the caption on top; keeps the rest of the desktop out of the frame
//   notes    the "user" window that keeps the keyboard for the whole demo
//   orders, expense, mail   ordinary WinForms apps the agents fill in from behind the note
//   live     live view of the covered apps (PrintWindow) with each agent's pointer and text caret
// usage: DemoApps <role> <x> <y> <w> <h> <log> [events folder]
// SIDEHAND_DEMO_ZOOM scales every font and size (for full-screen recordings that get downscaled).
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

static class Demo {
  [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
  public static string Role, LogPath;
  public static float S = 1f; // device pixels per 96-dpi pixel, times the zoom
  public static float Z = 1f;
  public static readonly Color[] Agent = { Color.FromArgb(56, 132, 255), Color.FromArgb(240, 120, 40), Color.FromArgb(163, 92, 240) };
  // SIDEHAND_DEMO_LANG=ko: every text in Korean, in Malgun Gothic (GDI+ does not fall back from Segoe UI to Hangul).
  public static readonly bool Ko = Environment.GetEnvironmentVariable("SIDEHAND_DEMO_LANG") == "ko";
  public static string L(string en, string ko) { return Ko ? ko : en; }
  public static readonly string[] Apps = { L("Contoso Orders", "Contoso 주문"), L("Expense report", "경비 보고서"), L("New message - Mail", "새 메일") };
  public static Font F(float pt, bool bold = false) {
    return Ko ? new Font("Malgun Gothic", pt * Z, bold ? FontStyle.Bold : FontStyle.Regular) : new Font(bold ? "Segoe UI Semibold" : "Segoe UI", pt * Z);
  }
  public static Font Px(float px, bool bold = false) {
    return Ko ? new Font("Malgun Gothic", px, bold ? FontStyle.Bold : FontStyle.Regular, GraphicsUnit.Pixel)
              : new Font(bold ? "Segoe UI Semibold" : "Segoe UI", px, GraphicsUnit.Pixel);
  }

  public static void Log(string s) {
    try { File.AppendAllText(LogPath, DateTime.UtcNow.Ticks + "\t" + Role + "\t" + s + "\r\n"); } catch { }
  }
  public static int P(float v) { return (int)Math.Round(v * S); }
  public static string ReadShared(string path) {
    try { using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite)) using (var r = new StreamReader(fs, Encoding.UTF8)) return r.ReadToEnd(); } catch { return null; }
  }

  [STAThread]
  static void Main(string[] a) {
    SetProcessDPIAware();
    Application.EnableVisualStyles();
    Role = a[0]; LogPath = a[5];
    string dir = a.Length > 6 ? a[6] : Path.GetDirectoryName(LogPath);
    float z;
    if (float.TryParse(Environment.GetEnvironmentVariable("SIDEHAND_DEMO_ZOOM"), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out z) && z > 0) Z = z;
    using (var g = Graphics.FromHwnd(IntPtr.Zero)) S = g.DpiX / 96f * Z;
    var r = new Rectangle(int.Parse(a[1]), int.Parse(a[2]), int.Parse(a[3]), int.Parse(a[4]));
    Form f;
    switch (Role) {
      case "stage": f = new Stage(dir); break;
      case "notes": f = new Notes(); break;
      case "orders": f = new Orders(); break;
      case "expense": f = new Expense(); break;
      case "mail": f = new Mail(); break;
      case "live": f = new Live(dir); break;
      default: throw new ArgumentException("unknown role " + Role);
    }
    f.StartPosition = FormStartPosition.Manual;
    f.Bounds = r;
    f.Activated += (s, e) => Log("form.activated");
    f.Deactivate += (s, e) => Log("form.deactivate");
    Application.Run(f);
  }
}

class DemoForm : Form {
  [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int value, int size);
  protected bool NoActivate = true, NeverActivate;
  protected int Tint = -1; // agent color for the title bar (Windows 11)
  protected override bool ShowWithoutActivation { get { return NoActivate; } }
  protected override CreateParams CreateParams {
    get {
      var cp = base.CreateParams;
      cp.ExStyle |= 0x8; // WS_EX_TOPMOST, set at creation so no activating SetWindowPos is needed
      if (NeverActivate) cp.ExStyle |= 0x08000000; // WS_EX_NOACTIVATE
      return cp;
    }
  }
  protected override void OnHandleCreated(EventArgs e) {
    base.OnHandleCreated(e);
    if (Tint < 0) return;
    var c = Demo.Agent[Tint];
    int bg = c.R | (c.G << 8) | (c.B << 16), fg = 0xFFFFFF;
    DwmSetWindowAttribute(Handle, 35 /* DWMWA_CAPTION_COLOR */, ref bg, 4);
    DwmSetWindowAttribute(Handle, 36 /* DWMWA_TEXT_COLOR */, ref fg, 4);
  }
}

// Draws "main line \n sub line" from caption.txt in the events folder across the top band.
class Stage : DemoForm {
  readonly string file;
  string text = "";
  public Stage(string dir) {
    NeverActivate = true;
    FormBorderStyle = FormBorderStyle.None;
    BackColor = Color.FromArgb(13, 17, 23);
    Text = "sidehand demo stage";
    ShowInTaskbar = false;
    DoubleBuffered = true;
    file = Path.Combine(dir, "caption.txt");
    var t = new Timer { Interval = 100 };
    t.Tick += (s, e) => { var c = Demo.ReadShared(file) ?? ""; if (c != text) { text = c; Invalidate(); } };
    t.Start();
  }
  protected override void OnPaint(PaintEventArgs e) {
    var g = e.Graphics; g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
    var lines = text.Replace("\r", "").Split('\n');
    float h = ClientSize.Height, x = ClientSize.Width * 0.016f;
    using (var big = Demo.Px(h * 0.030f, true))
    using (var small = Demo.Px(h * 0.019f)) {
      g.DrawString(lines[0], big, Brushes.White, x, h * 0.016f);
      if (lines.Length > 1) using (var b = new SolidBrush(Color.FromArgb(160, 172, 186))) g.DrawString(lines[1], small, b, x + 2, h * 0.060f);
    }
  }
}

class Notes : DemoForm {
  public Notes() {
    NoActivate = false; // the user's window: it holds the foreground for the whole demo
    Text = Demo.L("Your note", "내 메모");
    BackColor = Color.White;
    var hint = new Label {
      Text = Demo.L("You type here with your own keyboard and mouse.", "여기는 내가 내 키보드와 마우스로 쓰는 곳이에요."),
      Font = Demo.F(11f), ForeColor = Color.FromArgb(87, 96, 106),
      Location = new Point(Demo.P(16), Demo.P(12)), AutoSize = true
    };
    var box = new TextBox {
      Multiline = true, WordWrap = true, BorderStyle = BorderStyle.None,
      Font = Demo.F(15f), Location = new Point(Demo.P(16), Demo.P(44)),
      Anchor = AnchorStyles.Top | AnchorStyles.Bottom | AnchorStyles.Left | AnchorStyles.Right
    };
    Controls.Add(hint); Controls.Add(box);
    Load += (s, e) => box.Size = new Size(ClientSize.Width - Demo.P(32), ClientSize.Height - Demo.P(60));
    box.TextChanged += (s, e) => { try { File.WriteAllText(Demo.LogPath + ".notes.txt", box.Text); } catch { } };
    box.GotFocus += (s, e) => Demo.Log("focus+ notes");
  }
}

// A plain form: heading, labelled rows, a submit button and a status line.
class Sheet : DemoForm {
  int y = 70;
  readonly Label status;
  protected Sheet(int tint, string title, string heading, string waiting) {
    Tint = tint;
    Text = title;
    BackColor = Color.FromArgb(246, 248, 250);
    Font = Demo.F(12f);
    Controls.Add(new Label { Text = heading, Font = Demo.F(18f, true), Location = new Point(Demo.P(24), Demo.P(16)), AutoSize = true });
    status = new Label { Text = waiting, AutoSize = true, ForeColor = Color.FromArgb(87, 96, 106), Font = Demo.F(13f) };
  }
  void Watch(Control c, string name) { c.GotFocus += (s, e) => Demo.Log("focus+ " + name); }
  protected T Row<T>(string label, T c) where T : Control {
    Controls.Add(new Label { Text = label, Location = new Point(Demo.P(24), Demo.P(y + 4)), AutoSize = true, ForeColor = Color.FromArgb(87, 96, 106) });
    c.Location = new Point(Demo.P(150), Demo.P(y));
    c.AccessibleName = label;
    Controls.Add(c); Watch(c, label);
    y += Math.Max(46, (int)Math.Round(c.Height / Demo.S) + 16);
    return c;
  }
  protected CheckBox Check(string text) {
    var c = new CheckBox { Text = text, Location = new Point(Demo.P(150), Demo.P(y)), AutoSize = true };
    Controls.Add(c); Watch(c, text); y += 52;
    return c;
  }
  protected void Submit(string text, Func<string> result) {
    var b = new Button { Text = text, Location = new Point(Demo.P(150), Demo.P(y)), Size = new Size(Demo.P(200), Demo.P(40)), BackColor = Color.FromArgb(31, 136, 61), ForeColor = Color.White, FlatStyle = FlatStyle.Flat };
    b.FlatAppearance.BorderSize = 0;
    Controls.Add(b); Watch(b, text); y += 62;
    status.Location = new Point(Demo.P(24), Demo.P(y));
    Controls.Add(status);
    b.Click += (s, e) => { status.Text = result(); status.ForeColor = Color.FromArgb(26, 127, 55); Demo.Log("submit"); };
  }
  protected static ComboBox Combo(params object[] items) {
    var c = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = Demo.P(200) };
    c.Items.AddRange(items);
    return c;
  }
}

class Orders : Sheet {
  public Orders() : base(0, Demo.Apps[0], Demo.L("New order", "새 주문"), Demo.L("Waiting for an order", "주문 대기 중")) {
    var customer = Row(Demo.L("Customer", "고객"), new TextBox { Width = Demo.P(300) });
    var qty = Row(Demo.L("Quantity", "수량"), new TextBox { Width = Demo.P(80) });
    var region = Row(Demo.L("Region", "지역"), Demo.Ko ? Combo("서울", "부산", "인천", "제주") : Combo("Seoul", "Busan", "Incheon", "Jeju"));
    var express = Check(Demo.L("Express shipping", "특급 배송"));
    Submit(Demo.L("Submit order", "주문 제출"), () => Demo.Ko
      ? "주문 완료: " + customer.Text + ", " + qty.Text + "개, " + region.SelectedItem + (express.Checked ? ", 특급" : "")
      : "Order submitted: " + customer.Text + ", " + qty.Text + " units to " + region.SelectedItem + (express.Checked ? ", express" : ""));
  }
}

class Expense : Sheet {
  public Expense() : base(1, Demo.Apps[1], Demo.L("New expense", "새 경비"), Demo.L("Not submitted yet", "아직 제출 안 함")) {
    var vendor = Row(Demo.L("Vendor", "거래처"), new TextBox { Width = Demo.P(300) });
    var amount = Row(Demo.L("Amount (KRW)", "금액 (원)"), new TextBox { Width = Demo.P(140) });
    var category = Row(Demo.L("Category", "분류"), Demo.Ko ? Combo("출장", "식비", "사무용품", "소프트웨어") : Combo("Travel", "Meals", "Office", "Software"));
    Check(Demo.L("Receipt attached", "영수증 첨부"));
    Row(Demo.L("Memo", "메모"), new TextBox { Width = Demo.P(330) });
    Submit(Demo.L("Submit for approval", "결재 올리기"), () => Demo.Ko
      ? "결재 요청: " + vendor.Text + ", " + amount.Text + "원, " + category.SelectedItem
      : "Submitted: " + vendor.Text + ", " + amount.Text + " KRW, " + category.SelectedItem);
  }
}

class Mail : Sheet {
  public Mail() : base(2, Demo.Apps[2], Demo.L("New message", "새 메일"), Demo.L("Draft", "임시 저장")) {
    var to = Row(Demo.L("To", "받는 사람"), new TextBox { Width = Demo.P(330) });
    Row(Demo.L("Subject", "제목"), new TextBox { Width = Demo.P(330) });
    Row(Demo.L("Message", "내용"), new TextBox { Width = Demo.P(330), Height = Demo.P(120), Multiline = true, WordWrap = true });
    Submit(Demo.L("Send", "보내기"), () => Demo.L("Sent to ", "보냄: ") + to.Text);
  }
}

// Live view of the three covered apps. Each agent appends lines to agent<N>.txt in the events
// folder (demo/agent.mjs): plan <steps>, state <text>, move <x> <y>, click <x> <y>,
// focus [<x> <y> <w> <h>], step <k>, done. Coordinates are screen pixels. The pointer and caret
// are drawings that mark where each agent works; the window images are real PrintWindow captures.
class Live : DemoForm {
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindow(string cls, string title);
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
  [DllImport("user32.dll")] static extern bool ScreenToClient(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] static extern IntPtr ChildWindowFromPointEx(IntPtr h, POINT p, uint flags);
  [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, IntPtr l);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, StringBuilder l);
  [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
  [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }

  class Agent {
    public int I; public string Title, File, State = Demo.L("Waiting to start", "시작 대기 중"); public IntPtr H;
    public Bitmap Shot; public RECT Win; public long Read;
    public bool Seen; public PointF From, To; public long MoveAt, ClickAt; public Rectangle Focus;
    public int Steps, Step;
  }
  readonly Agent[] agents = new Agent[3];
  readonly string statsFile;
  string[] stats = new string[0];
  int tick;
  readonly Font fieldFont = Demo.F(12f);

  public Live(string dir) {
    NeverActivate = true;
    FormBorderStyle = FormBorderStyle.None;
    BackColor = Color.FromArgb(13, 17, 23);
    Text = "sidehand demo live view";
    ShowInTaskbar = false;
    DoubleBuffered = true;
    statsFile = Path.Combine(dir, "stats.txt");
    for (int i = 0; i < 3; i++) agents[i] = new Agent { I = i, Title = Demo.Apps[i], File = Path.Combine(dir, "agent" + (i + 1) + ".txt") };
    var t = new Timer { Interval = 33 };
    t.Tick += (s, e) => {
      foreach (var a in agents) Pump(a);
      if (tick++ % 3 == 0) { foreach (var a in agents) Capture(a); stats = (Demo.ReadShared(statsFile) ?? "").Split('\t'); }
      Invalidate();
    };
    t.Start();
    Shown += (s, e) => new YouTag().Show();
  }

  static long Now { get { return DateTime.UtcNow.Ticks / 10000; } }

  void Pump(Agent a) {
    if (!File.Exists(a.File)) return;
    string chunk;
    using (var fs = new FileStream(a.File, FileMode.Open, FileAccess.Read, FileShare.ReadWrite)) {
      if (fs.Length <= a.Read) return;
      fs.Seek(a.Read, SeekOrigin.Begin);
      var buf = new byte[fs.Length - a.Read];
      int n = fs.Read(buf, 0, buf.Length);
      int end = Array.LastIndexOf(buf, (byte)'\n', n - 1);
      if (end < 0) return;
      a.Read += end + 1;
      chunk = Encoding.UTF8.GetString(buf, 0, end + 1);
    }
    foreach (var raw in chunk.Split('\n')) {
      var f = raw.TrimEnd('\r').Split('\t');
      Func<int, int> N = k => int.Parse(f[k]);
      switch (f[0]) {
        case "plan": a.Steps = N(1); break;
        case "state": a.State = f[1]; break;
        case "step": a.Step = N(1); break;
        case "done": a.Focus = Rectangle.Empty; break;
        case "focus": a.Focus = f.Length > 4 ? new Rectangle(N(1), N(2), N(3), N(4)) : Rectangle.Empty; break;
        case "click": a.ClickAt = Now; break;
        case "move":
          var p = new PointF(N(1), N(2));
          a.From = a.Seen ? Pointer(a) : p; a.To = p; a.MoveAt = Now; a.Seen = true;
          break;
      }
    }
  }

  static PointF Pointer(Agent a) {
    float t = Math.Min(1f, (Now - a.MoveAt) / 450f);
    t = t < 0.5f ? 4 * t * t * t : 1 - (float)Math.Pow(-2 * t + 2, 3) / 2; // ease in-out
    return new PointF(a.From.X + (a.To.X - a.From.X) * t, a.From.Y + (a.To.Y - a.From.Y) * t);
  }

  void Capture(Agent a) {
    if (a.H == IntPtr.Zero) a.H = FindWindow(null, a.Title);
    if (a.H == IntPtr.Zero) return;
    RECT r; if (!GetWindowRect(a.H, out r) || r.R <= r.L) return;
    var bmp = new Bitmap(r.R - r.L, r.B - r.T);
    using (var g = Graphics.FromImage(bmp)) {
      var hdc = g.GetHdc();
      if (!PrintWindow(a.H, hdc, 2 /* PW_RENDERFULLCONTENT */)) PrintWindow(a.H, hdc, 0);
      g.ReleaseHdc(hdc);
    }
    if (a.Shot != null) a.Shot.Dispose();
    a.Shot = bmp; a.Win = r;
  }

  // Screen position of the end of the text in the edit control under the agent's focus rectangle.
  bool Caret(Agent a, out Point at, out int height) {
    at = Point.Empty; height = fieldFont.Height;
    if (a.Focus.IsEmpty || a.H == IntPtr.Zero) return false;
    var p = new POINT { X = a.Focus.X + a.Focus.Width / 2, Y = a.Focus.Y + a.Focus.Height / 2 };
    ScreenToClient(a.H, ref p);
    var edit = ChildWindowFromPointEx(a.H, p, 1 | 4 /* skip invisible, transparent */);
    if (edit == IntPtr.Zero || edit == a.H) return false;
    int len = (int)SendMessage(edit, 0x000E /* WM_GETTEXTLENGTH */, IntPtr.Zero, IntPtr.Zero);
    var q = new POINT();
    if (len > 0) {
      var sb = new StringBuilder(len + 1);
      SendMessage(edit, 0x000D /* WM_GETTEXT */, new IntPtr(len + 1), sb);
      long pos = (long)SendMessage(edit, 0x00D6 /* EM_POSFROMCHAR */, new IntPtr(len - 1), IntPtr.Zero);
      q.X = (short)(pos & 0xFFFF) + TextRenderer.MeasureText(sb[sb.Length - 1].ToString(), fieldFont, Size.Empty, TextFormatFlags.NoPadding).Width;
      q.Y = (short)((pos >> 16) & 0xFFFF);
    } else {
      q.X = (int)((long)SendMessage(edit, 0x00D4 /* EM_GETMARGINS */, IntPtr.Zero, IntPtr.Zero) & 0xFFFF) + 1;
      q.Y = 1;
    }
    ClientToScreen(edit, ref q);
    at = new Point(q.X, q.Y);
    return true;
  }

  static GraphicsPath Round(RectangleF r, float rad) {
    var p = new GraphicsPath(); float d = rad * 2;
    p.AddArc(r.X, r.Y, d, d, 180, 90); p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
    p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90); p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
    p.CloseFigure(); return p;
  }

  protected override void OnPaint(PaintEventArgs e) {
    var g = e.Graphics;
    g.SmoothingMode = SmoothingMode.AntiAlias;
    g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
    float W = ClientSize.Width, H = ClientSize.Height, u = H / 1000f, gap = 18 * u, head = 80 * u;
    var dim = Color.FromArgb(160, 172, 186);
    using (var title = Demo.Px(30 * u, true))
    using (var sub = Demo.Px(18 * u))
    using (var dimB = new SolidBrush(dim)) {
      g.DrawString(Demo.L("Live view of the windows behind your note", "메모 뒤에 가려진 창, 실시간 화면"), title, Brushes.White, 0, 0);
      g.DrawString(Demo.L("Real captures of the covered windows. The colored pointers and text cursors mark where each agent works.",
        "가려진 창을 그대로 캡처한 화면이에요. 색깔 포인터와 입력 커서는 각 에이전트가 일하는 위치예요."), sub, dimB, 2, 40 * u);
    }
    float cw = (W - gap) / 2, ch = (H - head - gap) / 2;
    for (int i = 0; i < 4; i++) {
      var cell = new RectangleF((i % 2) * (cw + gap), head + (i / 2) * (ch + gap), cw, ch);
      if (i < 3) DrawAgent(g, agents[i], cell, u); else DrawYou(g, cell, u);
    }
  }

  void DrawAgent(Graphics g, Agent a, RectangleF cell, float u) {
    var c = Demo.Agent[a.I];
    using (var path = Round(cell, 14 * u))
    using (var fill = new SolidBrush(Color.FromArgb(22, 27, 34)))
    using (var pen = new Pen(c, 3 * u)) { g.FillPath(fill, path); g.DrawPath(pen, path); }
    using (var name = Demo.Px(22 * u, true))
    using (var small = Demo.Px(17 * u))
    using (var cb = new SolidBrush(c))
    using (var dim = new SolidBrush(Color.FromArgb(201, 209, 217))) {
      g.FillEllipse(cb, cell.X + 16 * u, cell.Y + 18 * u, 16 * u, 16 * u);
      g.DrawString(Demo.L("Agent ", "에이전트 ") + (a.I + 1), name, cb, cell.X + 38 * u, cell.Y + 10 * u);
      var st = a.State;
      if (a.Steps > 0) st += "   (" + a.Step + "/" + a.Steps + ")";
      g.DrawString(st, small, dim, new RectangleF(cell.X + 18 * u, cell.Y + 44 * u, cell.Width - 30 * u, 26 * u));
    }
    if (a.Shot == null) return;
    var area = new RectangleF(cell.X + 14 * u, cell.Y + 78 * u, cell.Width - 28 * u, cell.Height - 92 * u);
    float sc = Math.Min(area.Width / a.Shot.Width, area.Height / a.Shot.Height);
    var dst = new RectangleF(area.X + (area.Width - a.Shot.Width * sc) / 2, area.Y, a.Shot.Width * sc, a.Shot.Height * sc);
    g.InterpolationMode = InterpolationMode.HighQualityBicubic;
    g.DrawImage(a.Shot, dst);
    Func<float, float, PointF> map = (x, y) => new PointF(dst.X + (x - a.Win.L) * sc, dst.Y + (y - a.Win.T) * sc);
    g.SetClip(dst);
    Point at; int fh;
    if (Caret(a, out at, out fh)) {
      var p = map(at.X, at.Y);
      using (var b = new SolidBrush(c)) g.FillRectangle(b, p.X - 1.5f * u, p.Y, 3.5f * u, Math.Max(fh * sc, 14 * u));
    }
    if (a.Seen) {
      var p = map(Pointer(a).X, Pointer(a).Y);
      long since = Now - a.ClickAt;
      if (since < 450) {
        float t = since / 450f, rad = (8 + 34 * t) * u;
        using (var pen = new Pen(Color.FromArgb((int)(220 * (1 - t)), c), 4 * u)) g.DrawEllipse(pen, p.X - rad, p.Y - rad, 2 * rad, 2 * rad);
      }
      DrawPointer(g, p, c, u, Demo.L("Agent ", "에이전트 ") + (a.I + 1));
    }
    g.ResetClip();
  }

  public static void DrawPointer(Graphics g, PointF p, Color c, float u, string label) {
    float k = 1.35f * u;
    var pts = new[] { new PointF(0, 0), new PointF(0, 22), new PointF(6, 17), new PointF(10, 26), new PointF(14, 24), new PointF(10, 16), new PointF(17, 16) };
    for (int i = 0; i < pts.Length; i++) pts[i] = new PointF(p.X + pts[i].X * k, p.Y + pts[i].Y * k);
    using (var b = new SolidBrush(c)) using (var pen = new Pen(Color.White, 2 * u) { LineJoin = LineJoin.Round }) { g.FillPolygon(b, pts); g.DrawPolygon(pen, pts); }
    using (var f = Demo.Px(15 * u, true)) {
      var sz = g.MeasureString(label, f);
      var r = new RectangleF(p.X + 20 * k, p.Y + 20 * k, sz.Width + 10 * u, sz.Height + 2 * u);
      using (var path = Round(r, r.Height / 2)) using (var b = new SolidBrush(c)) g.FillPath(b, path);
      g.DrawString(label, f, Brushes.White, r.X + 5 * u, r.Y + 1 * u);
    }
  }

  void DrawYou(Graphics g, RectangleF cell, float u) {
    using (var path = Round(cell, 14 * u))
    using (var fill = new SolidBrush(Color.FromArgb(22, 27, 34)))
    using (var pen = new Pen(Color.White, 3 * u)) { g.FillPath(fill, path); g.DrawPath(pen, path); }
    using (var name = Demo.Px(22 * u, true))
    using (var label = Demo.Px(19 * u))
    using (var big = Demo.Px(54 * u, true))
    using (var dim = new SolidBrush(Color.FromArgb(201, 209, 217))) {
      g.FillEllipse(Brushes.White, cell.X + 16 * u, cell.Y + 18 * u, 16 * u, 16 * u);
      g.DrawString(Demo.L("You", "나"), name, Brushes.White, cell.X + 38 * u, cell.Y + 10 * u);
      g.DrawString(Demo.L("Typing in your note, measured live", "내 메모에 입력 중, 실시간 측정"), label, dim, cell.X + 18 * u, cell.Y + 44 * u);
      string typed = stats.Length > 2 ? stats[0] : "0", got = stats.Length > 2 ? stats[1] : "0", fg = stats.Length > 2 ? stats[2] : "0";
      float y = cell.Y + 100 * u;
      g.DrawString(got + " / " + typed, big, Brushes.White, cell.X + 18 * u, y);
      g.DrawString(Demo.L("of your keystrokes reached your note", "내가 친 글자 중 메모에 들어간 글자"), label, dim, cell.X + 22 * u, y + 70 * u);
      y += 140 * u;
      using (var green = new SolidBrush(fg == "0" ? Color.FromArgb(63, 185, 80) : Color.FromArgb(248, 81, 73))) g.DrawString(fg, big, green, cell.X + 18 * u, y);
      g.DrawString(Demo.L("times another window jumped in front of you", "다른 창이 내 앞으로 튀어나온 횟수"), label, dim, cell.X + 22 * u, y + 70 * u);
    }
  }
}

// A "You" label that follows the real mouse pointer. Click-through and never activated.
class YouTag : Form {
  [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hh, uint f);
  public YouTag() {
    FormBorderStyle = FormBorderStyle.None; ShowInTaskbar = false; StartPosition = FormStartPosition.Manual;
    BackColor = Color.Magenta; TransparencyKey = Color.Magenta;
    float u = Screen.PrimaryScreen.Bounds.Height / 1000f * 0.75f;
    var f = Demo.Px(15 * u, true);
    var you = Demo.L("You", "나");
    var sz = TextRenderer.MeasureText(you, f);
    Size = new Size(sz.Width + (int)(14 * u), sz.Height + (int)(4 * u));
    Paint += (s, e) => {
      e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
      e.Graphics.FillRectangle(Brushes.White, 0, 0, Width, Height);
      using (var pen = new Pen(Color.FromArgb(13, 17, 23), 2)) e.Graphics.DrawRectangle(pen, 1, 1, Width - 3, Height - 3);
      TextRenderer.DrawText(e.Graphics, you, f, new Rectangle(0, 0, Width, Height), Color.FromArgb(13, 17, 23), TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
    };
    var t = new Timer { Interval = 15 };
    t.Tick += (s, e) => { var p = Cursor.Position; SetWindowPos(Handle, new IntPtr(-1), p.X + (int)(22 * u), p.Y + (int)(26 * u), 0, 0, 0x0001 | 0x0010 /* NOSIZE | NOACTIVATE */); };
    t.Start();
  }
  protected override bool ShowWithoutActivation { get { return true; } }
  protected override CreateParams CreateParams {
    get { var cp = base.CreateParams; cp.ExStyle |= 0x8 | 0x20 | 0x80 | 0x08000000; return cp; } // topmost, transparent, toolwindow, noactivate
  }
}
