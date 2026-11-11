// GHOST desktop launcher hub (GhostHub).
//
// A thin WinForms shell over the SAME PowerShell scripts GHOST.bat dispatches
// to: every action spawns powershell.exe in its own console window so all
// interactive prompts (choice gates, Read-Host, pause) keep working unchanged.
// Menu data lives in src\desktop\menu.json (read at RUNTIME, so menu edits
// land without a rebuild) and its parity with GHOST.bat's :DispatchOne table
// is enforced by tests/ghost_hub_menu.Tests.ps1.
//
// Build: tools\build_ghost_exe.ps1 (in-box .NET Framework csc.exe, no SDK).
// The exe must sit in the repo root next to GHOST.bat - it is a launcher over
// the tree, not a self-contained bundle. UAC elevation comes from the
// requireAdministrator app.manifest baked in at build time.
//
// Language note: C# 5 ONLY - the in-box Framework csc.exe (v4.0.30319) rejects
// string interpolation, null-conditionals, expression-bodied members, etc.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Security.Principal;
using System.Text;
using System.Web.Script.Serialization;

using System.Windows.Forms;

namespace GhostHub
{
    internal sealed class StepDef
    {
        public string Title;
        public string Script;
        public string[] Args = new string[0];
        public int DelaySec = 3;
    }

    internal sealed class RowDef
    {
        public int Gid;
        public string Label = "";
        public string Tail = "";
        public string Mode = "";
        public string Title = "";
        public string PsFlags = "-NoProfile";
        public string Script = "";
        public string[] Args = new string[0];
        public string[] Notes = new string[0];
        public bool WaitForClose;
        public string ConfirmTitle = "";
        public string ConfirmText = "";
        public List<StepDef> Steps = new List<StepDef>();
    }

    internal sealed class SectionDef
    {
        public string Name = "";
        public List<RowDef> Rows = new List<RowDef>();
    }

    internal sealed class GhostHubForm : Form
    {
        // echo of the console menu's banner, kept deliberately small
        private const string AppTitle = "GHOST - Guided Hardware and OS Scrubbing Toolkit";

        private readonly string _repoRoot;
        private readonly List<SectionDef> _sections = new List<SectionDef>();
        private readonly List<Button> _navButtons = new List<Button>();

        private ListView _list;
        private TextBox _details;
        private Label _staleLabel;
        private ToolStripStatusLabel _status;
        private Timer _staggerTimer;
        private List<StepDef> _staggerQueue;
        private int _staggerGid;

        public GhostHubForm(string repoRoot, List<SectionDef> sections, string staleMessage)
        {
            _repoRoot = repoRoot;
            _sections = sections;
            BuildUi(staleMessage);
        }

        // ------------------------------------------------------------------ UI

        private void BuildUi(string staleMessage)
        {
            Text = AppTitle;
            ClientSize = new System.Drawing.Size(880, 560);
            MinimumSize = new System.Drawing.Size(720, 480);
            StartPosition = FormStartPosition.CenterScreen;

            // --- banner -----------------------------------------------------
            Panel banner = new Panel();
            banner.Dock = DockStyle.Top;
            banner.Height = 58;
            banner.BackColor = System.Drawing.Color.FromArgb(24, 26, 32);
            Label title = new Label();
            title.Text = "GHOST";
            title.ForeColor = System.Drawing.Color.FromArgb(102, 190, 255);
            title.Font = new System.Drawing.Font("Segoe UI", 16f, System.Drawing.FontStyle.Bold);
            title.AutoSize = true;
            title.Location = new System.Drawing.Point(14, 6);
            Label sub = new Label();
            sub.Text = "desktop launcher  -  build " + ExeVersion() + "  -  every action runs the same scripts as GHOST.bat";
            sub.ForeColor = System.Drawing.Color.FromArgb(158, 158, 158);
            sub.AutoSize = true;
            sub.Location = new System.Drawing.Point(108, 32);
            banner.Controls.Add(title);
            banner.Controls.Add(sub);
            if (!string.IsNullOrEmpty(staleMessage))
            {
                _staleLabel = new Label();
                _staleLabel.Text = staleMessage;
                _staleLabel.ForeColor = System.Drawing.Color.FromArgb(255, 120, 120);
                _staleLabel.AutoSize = true;
                _staleLabel.Location = new System.Drawing.Point(14, 34);
                banner.Height = 74;
                sub.Location = new System.Drawing.Point(14, 10);
                banner.Controls.Add(_staleLabel);
            }

            // --- nav buttons ------------------------------------------------
            Panel nav = new Panel();
            nav.Dock = DockStyle.Top;
            nav.Height = 42;
            nav.Padding = new Padding(8, 6, 8, 6);
            foreach (SectionDef sec in _sections)
            {
                SectionDef captured = sec;
                Button b = new Button();
                b.Text = sec.Name;
                b.AutoSize = true;
                b.Padding = new Padding(8, 2, 8, 2);
                b.FlatStyle = FlatStyle.Flat;
                b.Cursor = Cursors.Hand;
                b.Click += delegate { SelectSection(captured, b); };
                nav.Controls.Add(b);
                _navButtons.Add(b);
            }
            nav.Resize += delegate { LayoutNav(nav); };

            // --- action list ------------------------------------------------
            _list = new ListView();
            _list.View = View.Details;
            _list.FullRowSelect = true;
            _list.HideSelection = false;
            _list.MultiSelect = false;
            _list.Dock = DockStyle.Fill;
            _list.Columns.Add("Action", 340);
            _list.Columns.Add("Details", 430);
            _list.Columns.Add("gid", 50);
            _list.SelectedIndexChanged += delegate { ShowDetails(); };
            _list.DoubleClick += delegate { RunSelected(); };

            // --- details panel ---------------------------------------------
            _details = new TextBox();
            _details.Multiline = true;
            _details.ReadOnly = true;
            _details.ScrollBars = ScrollBars.Vertical;
            _details.Dock = DockStyle.Bottom;
            _details.Height = 118;
            _details.Font = new System.Drawing.Font("Consolas", 9f);
            _details.BackColor = System.Drawing.SystemColors.Window;

            // --- run bar ----------------------------------------------------
            Panel runBar = new Panel();
            runBar.Dock = DockStyle.Bottom;
            runBar.Height = 44;
            Button run = new Button();
            run.Text = "Run";
            run.Width = 110;
            run.Location = new System.Drawing.Point(14, 6);
            run.Font = new System.Drawing.Font("Segoe UI", 9f, System.Drawing.FontStyle.Bold);
            run.Click += delegate { RunSelected(); };
            Label hint = new Label();
            hint.Text = "double-click a row also runs it  -  scripts open their own console window";
            hint.AutoSize = true;
            hint.ForeColor = System.Drawing.Color.Gray;
            hint.Location = new System.Drawing.Point(136, 14);
            runBar.Controls.Add(run);
            runBar.Controls.Add(hint);

            // --- status strip -----------------------------------------------
            StatusStrip strip = new StatusStrip();
            _status = new ToolStripStatusLabel("Ready.");
            strip.Items.Add(_status);

            // Docking is applied in reverse add-order: Fill first, then the
            // bottom panels from inner to outer, then the top panels.
            Controls.Add(_list);
            Controls.Add(_details);
            Controls.Add(runBar);
            Controls.Add(strip);
            Controls.Add(nav);
            Controls.Add(banner);

            if (_sections.Count > 0)
            {
                SelectSection(_sections[0], _navButtons[0]);
            }
        }

        private void LayoutNav(Panel nav)
        {
            // simple left-to-right flow: 8px gaps, vertical centering
            int x = nav.Padding.Left;
            foreach (Control c in nav.Controls)
            {
                c.Location = new System.Drawing.Point(x, (nav.Height - c.PreferredSize.Height) / 2);
                x += c.PreferredSize.Width + 8;
            }
        }

        private void SelectSection(SectionDef sec, Button source)
        {
            foreach (Button b in _navButtons)
            {
                bool on = ReferenceEquals(b, source);
                b.BackColor = on
                    ? System.Drawing.Color.FromArgb(102, 190, 255)
                    : System.Drawing.SystemColors.Control;
                b.ForeColor = on ? System.Drawing.Color.White : System.Drawing.SystemColors.ControlText;
            }
            _list.BeginUpdate();
            _list.Items.Clear();
            foreach (RowDef r in sec.Rows)
            {
                ListViewItem item = new ListViewItem(r.Label);
                item.SubItems.Add(r.Tail);
                item.SubItems.Add(r.Gid.ToString());
                item.Tag = r;
                _list.Items.Add(item);
            }
            _list.EndUpdate();
            if (_list.Items.Count > 0) { _list.Items[0].Selected = true; }
            SetStatus(sec.Name + "  -  " + sec.Rows.Count + " actions");
        }

        private RowDef SelectedRow()
        {
            if (_list.SelectedItems.Count == 0) { return null; }
            return _list.SelectedItems[0].Tag as RowDef;
        }

        private void ShowDetails()
        {
            RowDef r = SelectedRow();
            if (r == null)
            {
                _details.Text = "";
                return;
            }
            StringBuilder sb = new StringBuilder();
            sb.Append(r.Label).Append("   [gid ").Append(r.Gid).Append("]")
              .Append(string.IsNullOrEmpty(r.Tail) ? "" : "  " + r.Tail)
              .AppendLine();
            sb.Append("mode: ").Append(r.Mode);
            if (r.Mode == "detached" && !string.IsNullOrEmpty(r.Title))
            {
                sb.Append("  -  window \"").Append(r.Title).Append("\"");
            }
            sb.AppendLine();
            if (!string.IsNullOrEmpty(r.Script))
            {
                sb.Append("script: ").Append(r.Script);
                foreach (string a in EffectiveArgs(r)) { sb.Append(' ').Append(a); }
                sb.AppendLine();
            }
            if (r.Steps.Count > 0)
            {
                sb.Append("steps: ").Append(r.Steps.Count).AppendLine();
            }
            if (!string.IsNullOrEmpty(r.ConfirmText))
            {
                sb.Append("asks first: ").Append(r.ConfirmText).AppendLine();
            }
            foreach (string n in r.Notes)
            {
                // %VAR% expanded to match what GHOST.bat's echo lines print
                sb.Append(" - ").AppendLine(Environment.ExpandEnvironmentVariables(n));
            }
            _details.Text = sb.ToString();
        }

        // ------------------------------------------------------------- run logic

        private string[] EffectiveArgs(RowDef r)
        {
            // :RunWith's -WaitForClose is a script argument in the .bat table
            if (r.WaitForClose)
            {
                List<string> all = new List<string>(r.Args);
                all.Add("-WaitForClose");
                return all.ToArray();
            }
            return r.Args;
        }

        private void RunSelected()
        {
            RowDef r = SelectedRow();
            if (r == null) { return; }
            try
            {
                RunRow(r);
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, ex.Message, "GHOST - launch failed",
                    MessageBoxButtons.OK, MessageBoxIcon.Error);
                Log("error gid=" + r.Gid + " " + ex.Message);
            }
        }

        private void RunRow(RowDef r)
        {
            switch (r.Mode)
            {
                case "inline":
                case "zcode-reset":
                    Spawn(r, r.Label, true);
                    break;
                case "inline-note":
                    Spawn(r, r.Label, true);
                    break;
                case "confirm-reset":
                case "confirm-run":
                    if (ConfirmRow(r))
                    {
                        Spawn(r, r.Label, true);
                    }
                    else
                    {
                        SetStatus("Cancelled - nothing was run.");
                        Log("cancel gid=" + r.Gid);
                    }
                    break;
                case "detached":
                    Spawn(r, string.IsNullOrEmpty(r.Title) ? r.Label : r.Title, false);
                    break;
                case "windows-staggered":
                    StartStaggered(r);
                    break;
                case "chain-pause":
                    SpawnChain(r);
                    break;
                default:
                    throw new InvalidOperationException(
                        "unknown menu mode '" + r.Mode + "' for gid " + r.Gid +
                        " - rebuild GHOST.exe via Maintenance: Build GHOST desktop app");
            }
        }

        private bool ConfirmRow(RowDef r)
        {
            // Same sentences as the .bat choice gates; default button = No
            // (the .bat's Enter-default was Y - a GUI click is deliberate, so
            // we take the safer default for destructive resets).
            string text = "About to run: " +
                (string.IsNullOrEmpty(r.ConfirmTitle) ? r.Label : r.ConfirmTitle) +
                "\r\n\r\n" + r.ConfirmText +
                "\r\n\r\nContinue? Yes = run, No = cancel";
            DialogResult dr = MessageBox.Show(this, text, "GHOST - confirm",
                MessageBoxButtons.YesNo, MessageBoxIcon.Warning,
                MessageBoxDefaultButton.Button2);
            return dr == DialogResult.Yes;
        }

        /// <summary>One powershell.exe console window: title + script invocation.</summary>
        /// <param name="keepOpen">true = -NoExit (the GUI equivalent of the .bat's pause).</param>
        private void Spawn(RowDef r, string title, bool keepOpen)
        {
            string command = BuildCommand(title, r.Script, EffectiveArgs(r));
            string flags = keepOpen ? "-NoExit " + r.PsFlags : r.PsFlags;
            StartConsole(flags, command, keepOpen, r.Gid, title);
            SetStatus("gid " + r.Gid + " running in a new console window" +
                (keepOpen ? " - close the window when done" : "") + ".");
        }

        private void StartStaggered(RowDef r)
        {
            // gid 18: five launcher windows, one every delaySec (the .bat's
            // `timeout /t 3` between start calls). First window immediately.
            if (r.Steps.Count == 0)
            {
                throw new InvalidOperationException("gid " + r.Gid + " has no steps");
            }
            _staggerGid = r.Gid;
            _staggerQueue = new List<StepDef>(r.Steps);
            StepDef first = _staggerQueue[0];
            _staggerQueue.RemoveAt(0);
            SpawnStep(r.Gid, first);
            ScheduleNextStagger();
            SetStatus("gid " + r.Gid + " launching " + r.Steps.Count +
                " windows - one every " + first.DelaySec + "s.");
        }

        private void ScheduleNextStagger()
        {
            if (_staggerQueue == null || _staggerQueue.Count == 0) { return; }
            if (_staggerTimer == null)
            {
                _staggerTimer = new Timer();
                _staggerTimer.Tick += delegate
                {
                    _staggerTimer.Stop();
                    StepDef s = _staggerQueue[0];
                    _staggerQueue.RemoveAt(0);
                    SpawnStep(_staggerGid, s);
                    ScheduleNextStagger();
                };
            }
            _staggerTimer.Interval = Math.Max(1, _staggerQueue[0].DelaySec) * 1000;
            _staggerTimer.Start();
        }

        private void SpawnStep(int gid, StepDef s)
        {
            string title = string.IsNullOrEmpty(s.Title) ? "GHOST" : s.Title;
            string command = BuildCommand(title, s.Script, s.Args);
            StartConsole("-NoProfile", command, false, gid, title);
        }

        private void SpawnChain(RowDef r)
        {
            // gids 35/51/61: five sequential -Status runs + pause in ONE
            // console, mirroring the .bat's command block ending in `pause`.
            StringBuilder sb = new StringBuilder();
            foreach (StepDef s in r.Steps)
            {
                if (sb.Length > 0) { sb.Append("; "); }
                sb.Append(BuildInvocation(s.Script, s.Args));
            }
            sb.Append("; Read-Host 'Press Enter to close'");
            string command = "$host.UI.RawUI.WindowTitle=" + PsQuote(r.Label) + "; " + sb;
            StartConsole("-NoProfile", command, false, r.Gid, r.Label);
            SetStatus("gid " + r.Gid + " running " + r.Steps.Count + " steps in one console window.");
        }

        private string BuildCommand(string title, string script, string[] args)
        {
            return "$host.UI.RawUI.WindowTitle=" + PsQuote(title) + "; " +
                   BuildInvocation(script, args);
        }

        private string BuildInvocation(string script, string[] args)
        {
            StringBuilder sb = new StringBuilder("& ");
            sb.Append(PsQuote(Path.Combine(_repoRoot, script)));
            if (args != null)
            {
                foreach (string a in args)
                {
                    sb.Append(' ');
                    // bare when token-safe (matches how the .bat passes %2 %3 %4),
                    // single-quoted otherwise
                    if (a.Length == 0 || a.IndexOf(' ') >= 0 || a.IndexOf('\'') >= 0)
                    {
                        sb.Append(PsQuote(a));
                    }
                    else
                    {
                        sb.Append(a);
                    }
                }
            }
            return sb.ToString();
        }

        private static string PsQuote(string s)
        {
            return "'" + (s == null ? "" : s.Replace("'", "''")) + "'";
        }

        private void StartConsole(string psFlags, string psCommand, bool keepOpen, int gid, string title)
        {
            ProcessStartInfo pi = new ProcessStartInfo();
            pi.FileName = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.System),
                "WindowsPowerShell\\v1.0\\powershell.exe");
            // The -Command payload carries only single quotes, so the outer
            // double quotes are safe for native argument passing.
            pi.Arguments = (keepOpen ? "-NoExit " : "") + psFlags +
                " -ExecutionPolicy Bypass -Command \"" + psCommand + "\"";
            pi.WorkingDirectory = _repoRoot;
            pi.UseShellExecute = true;

            Process p = new Process();
            p.StartInfo = pi;
            p.EnableRaisingEvents = true;
            p.Exited += delegate
            {
                try
                {
                    Log("close gid=" + gid + " exit=" + p.ExitCode + " title=" + title);
                }
                catch
                {
                    // logging must never take the app down
                }
                try
                {
                    BeginInvoke((MethodInvoker)delegate
                    {
                        SetStatus("gid " + gid + " window closed (exit code " +
                            SafeExitCode(p) + ").");
                    });
                }
                catch
                {
                    // form already closed - nothing to update
                }
            };
            p.Start();
            Log("spawn gid=" + gid + " keepOpen=" + keepOpen + " title=" + title);
        }

        private static int SafeExitCode(Process p)
        {
            try { return p.ExitCode; }
            catch { return -1; }
        }

        private void SetStatus(string text)
        {
            if (_status != null) { _status.Text = text; }
        }

        // ----------------------------------------------------------- plumbing

        private static string ExeVersion()
        {
            return Assembly.GetExecutingAssembly().GetName().Version.ToString(3);
        }

        private static readonly string LogDir =
            Path.Combine(Environment.GetFolderPath(
                Environment.SpecialFolder.LocalApplicationData), "ghost-hub");

        internal static void Log(string message)
        {
            try
            {
                Directory.CreateDirectory(LogDir);
                File.AppendAllText(Path.Combine(LogDir, "hub.log"),
                    DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " " + message +
                    Environment.NewLine);
            }
            catch
            {
                // audit log is best-effort; never block a launch on it
            }
        }
    }

    internal static class Program
    {
        [STAThread]
        internal static void Main()
        {
            // The requireAdministrator manifest should force UAC already;
            // this guard catches a stripped/absent manifest (e.g. the exe was
            // copied from an unexpected build) instead of failing deep inside
            // the scripts with cryptic access-denied errors.
            using (WindowsIdentity id = WindowsIdentity.GetCurrent())
            {
                WindowsPrincipal principal = new WindowsPrincipal(id);
                if (!principal.IsInRole(WindowsBuiltInRole.Administrator))
                {
                    MessageBox.Show(
                        "GHOST.exe must run as Administrator (its scripts need it).\r\n" +
                        "Right-click GHOST.exe and choose Run as administrator.",
                        "GHOST - elevation required",
                        MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    return;
                }
            }

            string repoRoot = AppDomain.CurrentDomain.BaseDirectory;
            string menuPath = Path.Combine(repoRoot, "src", "desktop", "menu.json");
            List<SectionDef> sections;
            try
            {
                sections = LoadMenu(menuPath);
            }
            catch (Exception ex)
            {
                GhostHubForm.Log("menu-load-failed " + ex.Message);
                MessageBox.Show(
                    "Could not load the menu data:\r\n" + menuPath + "\r\n\r\n" +
                    ex.Message + "\r\n\r\n" +
                    "Rebuild GHOST.exe from GHOST.bat: Maintenance [5] Build GHOST desktop app\r\n" +
                    "(or run tools\\build_ghost_exe.ps1 directly).",
                    "GHOST - menu data missing",
                    MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }

            string stale = StaleMessage(repoRoot);
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new GhostHubForm(repoRoot, sections, stale));
        }

        // ---------------------------------------------------------------- menu

        private static List<SectionDef> LoadMenu(string menuPath)
        {
            string json = File.ReadAllText(menuPath);
            JavaScriptSerializer ser = new JavaScriptSerializer();
            // DeserializeObject is the documented-shape API (Dictionary<string,object>
            // roots, arrays, primitives); Deserialize<T> makes no such guarantee for
            // nested values, so every lookup below goes through the tolerant helpers.
            Dictionary<string, object> root = AsDict(ser.DeserializeObject(json));
            if (root == null) { throw new InvalidDataException("menu.json root is not an object"); }
            object[] rawSections = GetArray(root, "sections");
            List<SectionDef> result = new List<SectionDef>();
            if (rawSections == null) { throw new InvalidDataException("no \"sections\" array"); }
            foreach (object so in rawSections)
            {
                Dictionary<string, object> sd = AsDict(so);
                if (sd == null) { throw new InvalidDataException("section entry is not an object"); }
                SectionDef sec = new SectionDef();
                sec.Name = GetStr(sd, "name", "(unnamed)");
                object[] rawRows = GetArray(sd, "rows");
                if (rawRows == null) { throw new InvalidDataException("section '" + sec.Name + "' has no rows"); }
                foreach (object ro in rawRows)
                {
                    Dictionary<string, object> rd = AsDict(ro);
                    if (rd == null) { throw new InvalidDataException("menu row in section '" + sec.Name + "' is not an object"); }
                    RowDef row = new RowDef();
                    row.Gid = GetInt(rd, "gid", 0);
                    row.Label = GetStr(rd, "label", "");
                    row.Tail = GetStr(rd, "tail", "");
                    row.Mode = GetStr(rd, "mode", "");
                    row.Title = GetStr(rd, "title", "");
                    row.PsFlags = GetStr(rd, "psFlags", "-NoProfile");
                    row.Script = GetStr(rd, "script", "");
                    row.Args = GetStrArray(rd, "args");
                    row.Notes = GetStrArray(rd, "notes");
                    row.WaitForClose = GetBool(rd, "waitForClose", false);
                    row.ConfirmTitle = GetStr(rd, "confirmTitle", "");
                    row.ConfirmText = GetStr(rd, "confirmText", "");
                    object[] rawSteps = GetArray(rd, "steps");
                    if (rawSteps != null)
                    {
                        foreach (object sto in rawSteps)
                        {
                            Dictionary<string, object> std = AsDict(sto);
                            if (std == null) { throw new InvalidDataException("step entry in gid " + row.Gid + " is not an object"); }
                            StepDef step = new StepDef();
                            step.Title = GetStr(std, "title", "");
                            step.Script = GetStr(std, "script", "");
                            step.Args = GetStrArray(std, "args");
                            step.DelaySec = GetInt(std, "delaySec", 3);
                            row.Steps.Add(step);
                        }
                    }
                    sec.Rows.Add(row);
                }
                result.Add(sec);
            }
            if (result.Count == 0) { throw new InvalidDataException("menu.json has no sections"); }
            return result;
        }

        // JSON graph helpers - DeserializeObject's shape is documented
        // (Dictionary<string,object> / arrays / primitives), but the concrete
        // runtime types of nested values are not something to assume, so the
        // lookups are tolerant (2026-11-10 launch bug: the "sections" value was
        // not an object[] and a strict `as object[]` nulled it out).

        private static Dictionary<string, object> AsDict(object o)
        {
            if (o == null) { return null; }
            Dictionary<string, object> typed = o as Dictionary<string, object>;
            if (typed != null) { return typed; }
            System.Collections.IDictionary raw = o as System.Collections.IDictionary;
            if (raw != null)
            {
                Dictionary<string, object> copy = new Dictionary<string, object>();
                foreach (System.Collections.DictionaryEntry entry in raw)
                {
                    copy.Add(Convert.ToString(entry.Key), entry.Value);
                }
                return copy;
            }
            return null;
        }

        private static object[] GetArray(IDictionary<string, object> d, string key)
        {
            object v;
            if (!d.TryGetValue(key, out v) || v == null) { return null; }
            object[] typed = v as object[];
            if (typed != null) { return typed; }
            System.Collections.ArrayList list = v as System.Collections.ArrayList;
            if (list != null) { return list.ToArray(); }
            System.Collections.IEnumerable enumerable = v as System.Collections.IEnumerable;
            if (enumerable != null)
            {
                List<object> copied = new List<object>();
                foreach (object item in enumerable) { copied.Add(item); }
                return copied.ToArray();
            }
            return null;
        }

        private static string GetStr(IDictionary<string, object> d, string key, string fallback)
        {
            object v;
            if (!d.TryGetValue(key, out v) || v == null) { return fallback; }
            return Convert.ToString(v);
        }

        private static int GetInt(IDictionary<string, object> d, string key, int fallback)
        {
            object v;
            if (!d.TryGetValue(key, out v) || v == null) { return fallback; }
            return Convert.ToInt32(v);
        }

        private static bool GetBool(IDictionary<string, object> d, string key, bool fallback)
        {
            object v;
            if (!d.TryGetValue(key, out v) || v == null) { return fallback; }
            return Convert.ToBoolean(v);
        }

        private static string[] GetStrArray(IDictionary<string, object> d, string key)
        {
            object[] a = GetArray(d, key);
            if (a == null) { return new string[0]; }
            string[] result = new string[a.Length];
            for (int i = 0; i < a.Length; i++) { result[i] = Convert.ToString(a[i]); }
            return result;
        }

        // ------------------------------------------------------------- stale

        private static string StaleMessage(string repoRoot)
        {
            try
            {
                string changelog = Path.Combine(repoRoot, "CHANGELOG.md");
                if (!File.Exists(changelog)) { return null; }
                string text = File.ReadAllText(changelog);
                // first released version section (skips [Unreleased])
                System.Text.RegularExpressions.Match m = System.Text.RegularExpressions.Regex.Match(
                    text, @"## \[(\d+\.\d+\.\d+)\]");
                if (!m.Success) { return null; }
                string latest = m.Groups[1].Value;
                string exe = Assembly.GetExecutingAssembly().GetName().Version.ToString(3);
                if (string.Equals(latest, exe, StringComparison.OrdinalIgnoreCase))
                {
                    return null;
                }
                return "stale build: GHOST.exe is v" + exe +
                    " but this tree ships v" + latest +
                    "  -  rebuild via Maintenance: Build GHOST desktop app";
            }
            catch
            {
                return null;
            }
        }
    }
}
