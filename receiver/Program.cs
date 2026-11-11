using System.Runtime.InteropServices;

namespace PhonePadReceiver;

internal static class Program
{
    // タイマ分解能を 1ms に上げる。これをしないとスムージング用タイマ (2ms) は
    // Windows 既定の約15.6ms に丸められ、カーソルが結局ガタつく。
    [DllImport("winmm.dll")]
    private static extern uint timeBeginPeriod(uint uPeriod);

    [DllImport("winmm.dll")]
    private static extern uint timeEndPeriod(uint uPeriod);

    [STAThread]
    private static void Main()
    {
        timeBeginPeriod(1);
        ApplicationConfiguration.Initialize();
        Application.Run(new TrayContext());
        timeEndPeriod(1);
    }
}

/// <summary>トレイ常駐。BLE レシーバーを起動し、状態をトレイに表示する。</summary>
internal sealed class TrayContext : ApplicationContext
{
    private readonly NotifyIcon _icon;
    private readonly ToolStripMenuItem _statusItem;
    private readonly BleClient _ble;
    private bool _balloonShown;

    /// <summary>診断ログ（ユーザープロファイル直下）。受信パケットと注入結果を残す。</summary>
    private static readonly string LogPath =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "phonepad-debug.log");

    private static void Log(string msg)
    {
        try
        {
            File.AppendAllText(LogPath, $"{DateTime.Now:HH:mm:ss.fff} {msg}{Environment.NewLine}");
        }
        catch { /* ログ失敗で本体を止めない */ }
    }

    public TrayContext()
    {
        Log("=== receiver started ===");
        InputInjector.Logger = Log;
        BleClient.Logger = Log;
        _statusItem = new ToolStripMenuItem("起動中…") { Enabled = false };
        var menu = new ContextMenuStrip();
        menu.Items.Add(_statusItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("再接続", null, (_, _) => _ble.Reconnect());
        menu.Items.Add("終了", null, (_, _) => ExitThread());

        _icon = new NotifyIcon
        {
            Icon = SystemIcons.Application,
            Text = "PhonePad Receiver",
            Visible = true,
            ContextMenuStrip = menu
        };

        _ble = new BleClient();
        _ble.StatusChanged += OnStatusChanged;
        _ble.Start();
    }

    private void OnStatusChanged(string status)
    {
        Log($"status: {status}");
        // BLE コールバックは UI スレッド外から来るので、アイコンのハンドル経由で投げる
        var text = $"PhonePad: {status}";
        try
        {
            _icon.Text = text.Length > 63 ? text[..63] : text;
        }
        catch { /* アイコン破棄後は無視 */ }
        _statusItem.Text = status;
        if (!_balloonShown && status.StartsWith("接続中（"))
        {
            _balloonShown = true;
            _icon.ShowBalloonTip(2000, "PhonePad", "iPhone と接続しました", ToolTipIcon.Info);
        }
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _ble.Dispose();
            _icon.Visible = false;
            _icon.Dispose();
        }
        base.Dispose(disposing);
    }
}
