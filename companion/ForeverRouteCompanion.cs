// Forever Route Companion: a system-tray app that runs the route planner next to WoW Forever.
// It starts the automatic replanner (tools/autoplan.js) hidden at low priority, shows what it's doing, and tells you
// when a new route is ready to /reload. Open it from the tray icon for the log, Replan now, Pause and the folder.
using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

static class Program {
  [STAThread]
  static void Main() {
    bool first;
    using (var m = new Mutex(true, "ForeverRouteCompanion", out first)) {
      if (!first) return; // already running
      Application.EnableVisualStyles();
      Application.Run(new Companion());
    }
  }
}

class Companion : ApplicationContext {
  readonly string root = AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\');
  string Planner { get { return Path.GetDirectoryName(root); } }               // ...\ForeverRoutePlanner
  string LogFile { get { return Path.Combine(Planner, "autoplan.log"); } }
  readonly NotifyIcon tray = new NotifyIcon();
  Process child;
  bool paused, quitting;
  string status = "Starting";
  string lastInstalled = "";
  Window win;
  readonly System.Windows.Forms.Timer poll = new System.Windows.Forms.Timer();
  long logPos;

  public Companion() {
    tray.Icon = MakeIcon(Color.FromArgb(255, 210, 90));
    tray.Text = "Forever Route";
    tray.Visible = true;
    var menu = new ContextMenuStrip();
    menu.Items.Add("Open", null, (s, e) => ShowWindow());
    menu.Items.Add("Replan now", null, (s, e) => ReplanNow());
    menu.Items.Add("Pause / resume", null, (s, e) => TogglePause());
    menu.Items.Add("Open planner folder", null, (s, e) => Process.Start("explorer.exe", "\"" + Planner + "\""));
    var startup = new ToolStripMenuItem("Start with Windows") { Checked = StartsWithWindows() };
    startup.Click += (s, e) => { SetStartWithWindows(!startup.Checked); startup.Checked = StartsWithWindows(); };
    menu.Items.Add(startup);
    menu.Items.Add(new ToolStripSeparator());
    menu.Items.Add("Exit", null, (s, e) => Quit());
    tray.ContextMenuStrip = menu;
    tray.MouseClick += (s, e) => { if (e.Button == MouseButtons.Left) ShowWindow(); };
    tray.BalloonTipClicked += (s, e) => ShowWindow();
    if (File.Exists(LogFile)) logPos = new FileInfo(LogFile).Length; // only new lines from here on
    StartChild();
    poll.Interval = 1000; poll.Tick += (s, e) => Tick(); poll.Start();
  }

  // ---------- the planner process ----------
  string NodeExe() {
    var cfg = Path.Combine(root, "node.txt");
    if (File.Exists(cfg)) { var p = File.ReadAllText(cfg).Trim(); if (File.Exists(p)) return p; }
    return "node.exe";
  }
  void StartChild() {
    if (paused || quitting) return;
    try {
      var cfgs = Directory.GetFiles(Path.Combine(Planner, "routes"), "campaign-*.json"); // your settings (tools/make-character.js)
      if (cfgs.Length == 0) { AppendLog("no routes\\campaign-<name>.json yet: make one with tools\\make-character.js"); return; }
      var psi = new ProcessStartInfo(NodeExe(), "tools\\autoplan.js \"" + cfgs[0] + "\" \"" + AddonDir() + "\"") {
        WorkingDirectory = Planner, UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
      child = new Process { StartInfo = psi, EnableRaisingEvents = true };
      child.OutputDataReceived += (s, e) => { };
      child.ErrorDataReceived += (s, e) => { if (e.Data != null) AppendLog("! " + e.Data); };
      child.Exited += (s, e) => { if (!quitting && !paused) { AppendLog("planner stopped - restarting in 10 s"); Thread.Sleep(10000); StartChild(); } };
      child.Start(); child.BeginOutputReadLine(); child.BeginErrorReadLine();
      try { child.PriorityClass = ProcessPriorityClass.BelowNormal; } catch { }
      status = "Watching for your saves";
    } catch (Exception ex) { status = "Could not start the planner: " + ex.Message; AppendLog(status); }
  }
  // the game's _forever_ folder: game-dir.txt in the planner folder (tools/game-dir.js), else the folder above it
  string GameDir() {
    try { var t = File.ReadAllText(Path.Combine(Planner, "game-dir.txt")).Trim(); if (t.Length > 0) return t; } catch (Exception) { }
    return Path.GetDirectoryName(Planner);
  }
  string AddonDir() { return Path.Combine(GameDir(), "Interface", "AddOns", "ForeverRoute"); }
  void StopChild() {
    if (child == null || child.HasExited) return;
    try { Process.Start(new ProcessStartInfo("taskkill", "/T /F /PID " + child.Id) { CreateNoWindow = true, UseShellExecute = false }).WaitForExit(5000); } catch { }
  }
  void ReplanNow() { File.WriteAllText(Path.Combine(Planner, "replan-now.txt"), DateTime.Now.ToString("o")); AppendLog("you asked for a replan"); status = "Replan asked for"; }
  void TogglePause() {
    paused = !paused;
    if (paused) { StopChild(); status = "Paused - not replanning"; tray.Icon = MakeIcon(Color.Gray); }
    else { tray.Icon = MakeIcon(Color.FromArgb(255, 210, 90)); StartChild(); }
    AppendLog(paused ? "paused" : "resumed");
  }
  void Quit() { quitting = true; StopChild(); tray.Visible = false; ExitThread(); }

  // ---------- watching the planner's log ----------
  void Tick() {
    try {
      if (!File.Exists(LogFile)) return;
      var len = new FileInfo(LogFile).Length;
      if (len < logPos) logPos = 0;
      if (len == logPos) return;
      using (var fs = new FileStream(LogFile, FileMode.Open, FileAccess.Read, FileShare.ReadWrite)) {
        fs.Seek(logPos, SeekOrigin.Begin);
        var text = new StreamReader(fs).ReadToEnd(); logPos = len;
        foreach (var line in text.Split('\n')) { var l = line.TrimEnd('\r'); if (l.Length > 0) OnLine(l); }
      }
    } catch { }
  }
  void OnLine(string l) {
    if (win != null) win.Add(l);
    if (l.Contains("replanning") || l.Contains("full replan")) { status = l.Contains("full") ? "Planning zone choices (about 30 min)" : "Planning from your latest save (about 5 min)"; tray.Icon = MakeIcon(Color.FromArgb(120, 200, 255)); }
    var m = Regex.Match(l, @"(fast|full) plan installed \(([^)]*)\)");
    if (m.Success) {
      lastInstalled = DateTime.Now.ToString("HH:mm") + " - " + m.Groups[2].Value;
      status = "New route ready - /reload in game";
      tray.Icon = MakeIcon(Color.FromArgb(90, 220, 120));
      tray.ShowBalloonTip(6000, "Forever Route", "New route ready - /reload in game when it suits you.", ToolTipIcon.Info);
    }
    if (l.Contains("NOT installed")) { status = "Last plan had a problem (kept the old route)"; tray.Icon = MakeIcon(Color.FromArgb(255, 140, 80)); }
    var t = "Forever Route - " + status; tray.Text = t.Length > 63 ? t.Substring(0, 63) : t;
    if (win != null) win.SetStatus(status, lastInstalled);
  }
  void AppendLog(string l) { try { File.AppendAllText(LogFile, DateTime.Now.ToString("h:mm:ss tt") + "  " + l + Environment.NewLine); } catch { } }

  // ---------- the window ----------
  void ShowWindow() {
    if (win == null || win.IsDisposed) {
      win = new Window(() => ReplanNow(), () => TogglePause(), () => Process.Start("explorer.exe", "\"" + Planner + "\""));
      try { foreach (var l in Tail(LogFile, 200)) win.Add(l); } catch { }
    }
    win.SetStatus(status, lastInstalled);
    win.Show(); win.Activate();
  }
  static string[] Tail(string file, int n) {
    if (!File.Exists(file)) return new string[0];
    string[] all; using (var fs = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite)) all = new StreamReader(fs).ReadToEnd().Split('\n');
    var start = Math.Max(0, all.Length - n); var r = new string[all.Length - start]; Array.Copy(all, start, r, 0, r.Length); return r;
  }

  // ---------- start with Windows (per user, no admin) ----------
  const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
  static bool StartsWithWindows() { using (var k = Registry.CurrentUser.OpenSubKey(RunKey)) return k != null && k.GetValue("ForeverRouteCompanion") != null; }
  static void SetStartWithWindows(bool on) {
    using (var k = Registry.CurrentUser.OpenSubKey(RunKey, true)) {
      if (on) k.SetValue("ForeverRouteCompanion", "\"" + Application.ExecutablePath + "\""); else k.DeleteValue("ForeverRouteCompanion", false);
    }
  }

  // a round dark badge with a gold (or status-coloured) arrow
  static Icon MakeIcon(Color c) {
    var b = new Bitmap(32, 32);
    using (var g = Graphics.FromImage(b)) {
      g.SmoothingMode = SmoothingMode.AntiAlias;
      g.FillEllipse(new SolidBrush(Color.FromArgb(28, 30, 38)), 1, 1, 30, 30);
      g.DrawEllipse(new Pen(c, 2), 2, 2, 28, 28);
      g.FillPolygon(new SolidBrush(c), new[] { new Point(16, 6), new Point(25, 25), new Point(16, 20), new Point(7, 25) });
    }
    return Icon.FromHandle(b.GetHicon());
  }
}

class Window : Form {
  readonly Label status = new Label(), last = new Label();
  readonly TextBox log = new TextBox();
  public Window(Action replan, Action pause, Action folder) {
    Text = "Forever Route Companion"; Width = 720; Height = 460; StartPosition = FormStartPosition.CenterScreen;
    BackColor = Color.FromArgb(22, 24, 30); ForeColor = Color.FromArgb(230, 232, 238); Font = new Font("Segoe UI", 9.5f);
    status.SetBounds(14, 12, 680, 24); status.Font = new Font("Segoe UI Semibold", 12f); status.ForeColor = Color.FromArgb(255, 210, 90);
    last.SetBounds(14, 38, 680, 20); last.ForeColor = Color.FromArgb(150, 160, 180);
    var b1 = Btn("Replan now", 14, replan); var b2 = Btn("Pause / resume", 134, pause); var b3 = Btn("Open folder", 254, folder);
    log.SetBounds(14, 100, 676, 300); log.Multiline = true; log.ReadOnly = true; log.ScrollBars = ScrollBars.Vertical; log.WordWrap = true;
    log.BackColor = Color.FromArgb(14, 15, 20); log.ForeColor = Color.FromArgb(200, 205, 215); log.Font = new Font("Consolas", 9f); log.BorderStyle = BorderStyle.None;
    log.Anchor = AnchorStyles.Top | AnchorStyles.Bottom | AnchorStyles.Left | AnchorStyles.Right;
    Controls.AddRange(new Control[] { status, last, b1, b2, b3, log });
    FormClosing += (s, e) => { if (e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; Hide(); } }; // closing keeps it in the tray
  }
  Button Btn(string t, int x, Action a) {
    var b = new Button { Text = t, Left = x, Top = 64, Width = 112, Height = 26, FlatStyle = FlatStyle.Flat, BackColor = Color.FromArgb(40, 43, 54), ForeColor = Color.FromArgb(240, 220, 160) };
    b.FlatAppearance.BorderColor = Color.FromArgb(70, 74, 90); b.Click += (s, e) => a(); return b;
  }
  public void Add(string l) { if (InvokeRequired) { BeginInvoke(new Action(() => Add(l))); return; } if (string.IsNullOrWhiteSpace(l)) return; log.AppendText(l.TrimEnd('\r') + Environment.NewLine); }
  public void SetStatus(string s, string lastPlan) {
    if (InvokeRequired) { BeginInvoke(new Action(() => SetStatus(s, lastPlan))); return; }
    status.Text = s; last.Text = string.IsNullOrEmpty(lastPlan) ? "No new route installed since the companion started." : "Last route installed " + lastPlan;
  }
}
