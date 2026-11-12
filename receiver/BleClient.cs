using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.Advertisement;
using Windows.Devices.Bluetooth.GenericAttributeProfile;
using Windows.Storage.Streams;

namespace PhonePadReceiver;

/// <summary>
/// BLE セントラル。PhonePad サービスを広告する iPhone を探し、接続して notify を購読する。
/// 切断されたら自動で探索に戻る。
/// </summary>
internal sealed class BleClient : IDisposable
{
    public static readonly Guid ServiceUuid = Guid.Parse("A1B2C3D4-E5F6-4789-ABCD-000000000001");
    public static readonly Guid MouseUuid = Guid.Parse("A1B2C3D4-E5F6-4789-ABCD-000000000002");
    public static readonly Guid TextUuid = Guid.Parse("A1B2C3D4-E5F6-4789-ABCD-000000000003");

    private readonly BluetoothLEAdvertisementWatcher _watcher;
    private BluetoothLEDevice? _device;
    private GattSession? _session;
    private bool _busy; // 接続処理中 or 接続済み
    private bool _disposed;
    private int _fastDropStreak;      // 短命な接続が続いた回数（再接続バックオフ用）
    private DateTime _connectedAtUtc; // 接続が確立した時刻

    /// <summary>診断ログの出力先（TrayContext がファイル書き込みを設定する）</summary>
    public static Action<string>? Logger;

    private static void Log(string msg)
    {
        try { Logger?.Invoke(msg); } catch { /* ログ失敗で本体を止めない */ }
    }

    /// <summary>状態表示用コールバック（UIスレッド保証なし。受け手で Invoke すること）</summary>
    public event Action<string>? StatusChanged;

    /// <summary>手動再接続（トレイメニュー用）。接続を捨てて探索からやり直す。</summary>
    public void Reconnect()
    {
        Log("manual reconnect requested");
        CleanupDevice();
        _busy = false;
        _fastDropStreak = 0;
        _connectedAtUtc = default;
        try { _watcher.Stop(); } catch { /* ignore */ }
        if (!_disposed) Start();
    }

    public BleClient()
    {
        _watcher = new BluetoothLEAdvertisementWatcher
        {
            ScanningMode = BluetoothLEScanningMode.Active
        };
        _watcher.Received += OnAdvertisementReceived;
    }

    public void Start()
    {
        StatusChanged?.Invoke("iPhone を探しています…");
        _watcher.Start();
    }

    private async void OnAdvertisementReceived(
        BluetoothLEAdvertisementWatcher sender,
        BluetoothLEAdvertisementReceivedEventArgs args)
    {
        if (_busy) return;
        if (!args.Advertisement.ServiceUuids.Contains(ServiceUuid)) return;
        _busy = true;
        _watcher.Stop();
        try
        {
            await ConnectAsync(args.BluetoothAddress);
        }
        catch (Exception ex)
        {
            Log($"connect failed: {ex.GetType().Name}: {ex.Message}");
            _fastDropStreak++;
            CleanupDevice();
            _busy = false;
            ScheduleRestart();
        }
    }

    /// <summary>
    /// 探索再開。短命な接続・失敗が続く場合は間隔を空ける（即リトライの連発は
    /// 相手の状態遷移と衝突して余計に不安定になるため）。
    /// </summary>
    private async void ScheduleRestart()
    {
        int delay = _fastDropStreak <= 0 ? 0 : Math.Min(1000 * (1 << Math.Min(_fastDropStreak, 4)), 15000);
        Log($"restart scan in {delay}ms (fastDropStreak={_fastDropStreak})");
        if (delay > 0)
        {
            try { await Task.Delay(delay); } catch { return; }
        }
        if (!_disposed) Start();
    }

    private async Task ConnectAsync(ulong address)
    {
        StatusChanged?.Invoke("接続中…");
        _device = await BluetoothLEDevice.FromBluetoothAddressAsync(address)
                  ?? throw new InvalidOperationException("device not found");
        _device.ConnectionStatusChanged += OnConnectionStatusChanged;

        var service = await GetServiceAsync(_device);

        // GATT セッションを維持する。これをしないと Windows が「使われていない接続」と
        // 判断してセッション側から切りに来ることがあり、切断・再接続の連発になる。
        _session = await GattSession.FromDeviceIdAsync(_device.BluetoothDeviceId);
        if (_session != null)
        {
            _session.MaintainConnection = true;
            Log("gatt session maintained");
        }
        else
        {
            Log("gatt session: null (continuing without maintain)");
        }

        await SubscribeAsync(service, MouseUuid, InputInjector.HandleMousePacket);
        await SubscribeAsync(service, TextUuid, InputInjector.HandleTextPacket);

        _connectedAtUtc = DateTime.UtcNow;
        StatusChanged?.Invoke("接続中（PhonePad）");
    }

    /// <summary>
    /// サービス参照。まず OS キャッシュを使い（列挙の往復が少なく速い）、
    /// 駄目なら実問い合わせにフォールバックする。
    /// </summary>
    private static async Task<GattDeviceService> GetServiceAsync(BluetoothLEDevice device)
    {
        var cached = await device.GetGattServicesForUuidAsync(ServiceUuid, BluetoothCacheMode.Cached);
        if (cached.Status == GattCommunicationStatus.Success && cached.Services.Count > 0)
            return cached.Services[0];
        var fresh = await device.GetGattServicesForUuidAsync(ServiceUuid, BluetoothCacheMode.Uncached);
        if (fresh.Status != GattCommunicationStatus.Success || fresh.Services.Count == 0)
        {
            Log($"service lookup FAILED: cached={cached.Status} uncached={fresh.Status}");
            throw new InvalidOperationException("service not found");
        }
        return fresh.Services[0];
    }

    private static async Task SubscribeAsync(GattDeviceService service, Guid uuid, Action<byte[]> handler)
    {
        var result = await service.GetCharacteristicsForUuidAsync(uuid, BluetoothCacheMode.Cached);
        if (result.Status != GattCommunicationStatus.Success || result.Characteristics.Count == 0)
        {
            var fresh = await service.GetCharacteristicsForUuidAsync(uuid, BluetoothCacheMode.Uncached);
            if (fresh.Status == GattCommunicationStatus.Success && fresh.Characteristics.Count > 0)
            {
                result = fresh;
            }
            else
            {
                Log($"subscribe FAILED (characteristic lookup): {uuid} cached={result.Status} uncached={fresh.Status}");
                throw new InvalidOperationException($"characteristic not found: {uuid}");
            }
        }
        var ch = result.Characteristics[0];
        ch.ValueChanged += (_, args) =>
        {
            var reader = DataReader.FromBuffer(args.CharacteristicValue);
            var bytes = new byte[reader.UnconsumedBufferLength];
            reader.ReadBytes(bytes);
            handler(bytes);
        };
        var status = await ch.WriteClientCharacteristicConfigurationDescriptorAsync(
            GattClientCharacteristicConfigurationDescriptorValue.Notify);
        if (status != GattCommunicationStatus.Success)
        {
            Log($"subscribe FAILED (CCCD write): {uuid} status={status}");
            throw new InvalidOperationException("subscribe failed");
        }
        Log($"subscribed OK: {uuid}");
    }

    private void OnConnectionStatusChanged(BluetoothLEDevice sender, object args)
    {
        Log($"connection status: {sender.ConnectionStatus}");
        if (sender.ConnectionStatus == BluetoothConnectionStatus.Disconnected)
        {
            // 5秒未満で落ちたら「短命」と数えてバックオフを伸ばす
            if (_connectedAtUtc != default && DateTime.UtcNow - _connectedAtUtc < TimeSpan.FromSeconds(5))
                _fastDropStreak++;
            else
                _fastDropStreak = 0;
            _connectedAtUtc = default;
            CleanupDevice();
            _busy = false;
            StatusChanged?.Invoke("切断されました。再探索中…");
            ScheduleRestart();
        }
    }

    private void CleanupDevice()
    {
        if (_session != null)
        {
            try { _session.Dispose(); } catch { /* ignore */ }
            _session = null;
        }
        if (_device != null)
        {
            _device.ConnectionStatusChanged -= OnConnectionStatusChanged;
            _device.Dispose();
            _device = null;
        }
    }

    public void Dispose()
    {
        _disposed = true;
        try { _watcher.Stop(); } catch { /* ignore */ }
        CleanupDevice();
    }
}
