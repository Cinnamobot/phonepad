namespace PhonePadReceiver;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        ApplicationConfiguration.Initialize();
        Application.Run(new TrayContext());
    }
}

/// <summary>トレイ常駐。BLE レシーバーを起動し、状態をトレイに表示する。</summary>
internal sealed class TrayContext : ApplicationContext
{
    private readonly NotifyIcon _icon;
    private readonly ToolStripMenuItem _statusItem;
    private readonly BleClient _ble;
    private bool _balloonShown;

    public TrayContext()
    {
        _statusItem = new ToolStripMenuItem("起動中…") { Enabled = false };
        var menu = new ContextMenuStrip();
        menu.Items.Add(_statusItem);
        menu.Items.Add(new ToolStripSeparator());
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
