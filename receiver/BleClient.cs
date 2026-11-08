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
    private bool _busy; // 接続処理中 or 接続済み
    private bool _disposed;

    /// <summary>状態表示用コールバック（UIスレッド保証なし。受け手で Invoke すること）</summary>
    public event Action<string>? StatusChanged;

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
        catch
        {
            CleanupDevice();
            _busy = false;
            if (!_disposed) Start();
        }
    }

    private async Task ConnectAsync(ulong address)
    {
        StatusChanged?.Invoke("接続中…");
        _device = await BluetoothLEDevice.FromBluetoothAddressAsync(address)
                  ?? throw new InvalidOperationException("device not found");
        _device.ConnectionStatusChanged += OnConnectionStatusChanged;

        var services = await _device.GetGattServicesForUuidAsync(ServiceUuid, BluetoothCacheMode.Uncached);
        if (services.Status != GattCommunicationStatus.Success || services.Services.Count == 0)
            throw new InvalidOperationException("service not found");
        var service = services.Services[0];

        await SubscribeAsync(service, MouseUuid, InputInjector.HandleMousePacket);
        await SubscribeAsync(service, TextUuid, InputInjector.HandleTextPacket);

        StatusChanged?.Invoke("接続中（PhonePad）");
    }

    private static async Task SubscribeAsync(GattDeviceService service, Guid uuid, Action<byte[]> handler)
    {
        var result = await service.GetCharacteristicsForUuidAsync(uuid, BluetoothCacheMode.Uncached);
        if (result.Status != GattCommunicationStatus.Success || result.Characteristics.Count == 0)
            throw new InvalidOperationException($"characteristic not found: {uuid}");
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
            throw new InvalidOperationException("subscribe failed");
    }

    private void OnConnectionStatusChanged(BluetoothLEDevice sender, object args)
    {
        if (sender.ConnectionStatus == BluetoothConnectionStatus.Disconnected)
        {
            CleanupDevice();
            _busy = false;
            StatusChanged?.Invoke("切断されました。再探索中…");
            if (!_disposed) Start();
        }
    }

    private void CleanupDevice()
    {
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
