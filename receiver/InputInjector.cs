using System.Diagnostics;
using System.Runtime.InteropServices;

namespace PhonePadReceiver;

/// <summary>SendInput によるマウス/キーボード注入。プロトコル解釈はここに集約する。</summary>
internal static class InputInjector
{
    /// <summary>診断ログの出力先（TrayContext がファイル書き込みを設定する）</summary>
    public static Action<string>? Logger;

    private static void Log(string msg)
    {
        try { Logger?.Invoke(msg); } catch { /* ログ失敗で本体を止めない */ }
    }

    // ---- Win32 ----

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT
    {
        public uint type;
        public InputUnion U;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion
    {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MOUSEINPUT
    {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT
    {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    private const uint INPUT_MOUSE = 0;
    private const uint INPUT_KEYBOARD = 1;

    private const uint MOUSEEVENTF_MOVE = 0x0001;
    private const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    private const uint MOUSEEVENTF_LEFTUP = 0x0004;
    private const uint MOUSEEVENTF_RIGHTDOWN = 0x0008;
    private const uint MOUSEEVENTF_RIGHTUP = 0x0010;
    private const uint MOUSEEVENTF_MIDDLEDOWN = 0x0020;
    private const uint MOUSEEVENTF_MIDDLEUP = 0x0040;
    private const uint MOUSEEVENTF_WHEEL = 0x0800;
    private const uint MOUSEEVENTF_HWHEEL = 0x1000;

    private const uint KEYEVENTF_KEYUP = 0x0002;
    private const uint KEYEVENTF_UNICODE = 0x0004;

    private static void Send(params INPUT[] inputs)
    {
        if (inputs.Length == 0) return;
        uint sent = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
        if (sent != (uint)inputs.Length)
        {
            // 注入できなかった分がある = OS側で弾かれた（権限/UIPI等）
            Log($"SendInput partial: {sent}/{inputs.Length} err={Marshal.GetLastWin32Error()}");
        }
    }

    private static INPUT Mouse(uint flags, int dx = 0, int dy = 0, uint data = 0) => new()
    {
        type = INPUT_MOUSE,
        U = new InputUnion
        {
            mi = new MOUSEINPUT { dx = dx, dy = dy, dwFlags = flags, mouseData = data }
        }
    };

    private static INPUT Key(ushort vk, ushort scan, uint flags) => new()
    {
        type = INPUT_KEYBOARD,
        U = new InputUnion
        {
            ki = new KEYBDINPUT { wVk = vk, wScan = scan, dwFlags = flags }
        }
    };

    // ---- 移動スムージング ----
    // BLE の通知は接続間隔（約30ms）ごとに固まって届く。受けた瞬間にそのまま
    // 注入すると到着のムラがカーソルのムラになる。
    // v2.2 の方式: 受信デルタを「目標位置」に積み、仮想位置が指数バネで追いつく。
    // 2ms 周期で少しずつ注入するので、バースト到着でもカーソルは連続して滑る。
    // 到着間隔からの速度推定はバースト時に暴れるため使わず、速さは時定数の
    // 調整（速い移動ほど追従を速く＝遅延を減らす）にだけ使う。
    // 前提: Program 側で timeBeginPeriod(1) 済み（無いとタイマは約15.6msに丸まる）。
    private const int TickMs = 2;
    private static readonly object _moveLock = new();
    private static double _tgtX, _tgtY;   // 受信済み累計（目標位置）
    private static double _posX, _posY;   // 仮想位置（バネで追従）
    private static int _sentX, _sentY;    // 実際に注入した累計
    private static double _speed;         // 目標の移動速度 EMA (px/ms)
    private static long _lastArrivalTs;
    private static long _lastTickTs;
    private static System.Threading.Timer? _moveTimer;

    private static double Ms(long ts) => ts * 1000.0 / Stopwatch.Frequency;

    private static void EnsureTimerLocked()
    {
        if (_moveTimer == null)
        {
            _lastTickTs = Stopwatch.GetTimestamp();
            _moveTimer = new System.Threading.Timer(MoveTick, null, TickMs, TickMs);
        }
    }

    private static void QueueMove(int dx, int dy)
    {
        lock (_moveLock)
        {
            long now = Stopwatch.GetTimestamp();
            if (_lastArrivalTs != 0)
            {
                double dt = Math.Clamp(Ms(now - _lastArrivalTs), 4, 100);
                double inst = Math.Sqrt((double)dx * dx + (double)dy * dy) / dt;
                _speed = _speed * 0.6 + inst * 0.4;
            }
            _lastArrivalTs = now;
            _tgtX += dx;
            _tgtY += dy;
            EnsureTimerLocked();
        }
    }

    private static void MoveTick(object? state)
    {
        int ex, ey, wheelV, wheelH;
        lock (_moveLock)
        {
            long now = Stopwatch.GetTimestamp();
            double dt = Math.Clamp(Ms(now - _lastTickTs), 0.5, 50);
            _lastTickTs = now;
            double tau = _speed > 1.5 ? 8 : _speed > 0.5 ? 13 : 20; // ms
            double k = 1 - Math.Exp(-dt / tau);
            _posX += (_tgtX - _posX) * k;
            _posY += (_tgtY - _posY) * k;
            if (Math.Abs(_tgtX - _posX) < 0.4) _posX = _tgtX;
            if (Math.Abs(_tgtY - _posY) < 0.4) _posY = _tgtY;
            int nx = (int)Math.Round(_posX);
            int ny = (int)Math.Round(_posY);
            ex = nx - _sentX;
            ey = ny - _sentY;
            _sentX = nx;
            _sentY = ny;
            wheelV = DrainWheel(ref _wheelV);
            wheelH = DrainWheel(ref _wheelH);
            if (ex == 0 && ey == 0 && _posX == _tgtX && _posY == _tgtY && _wheelV == 0 && _wheelH == 0)
            {
                _moveTimer?.Dispose();
                _moveTimer = null;
                _speed = 0;
            }
        }
        if (ex != 0 || ey != 0)
            Send(Mouse(MOUSEEVENTF_MOVE, ex, ey));
        if (wheelV != 0 || wheelH != 0)
        {
            var inputs = new List<INPUT>();
            if (wheelV != 0) inputs.Add(Mouse(MOUSEEVENTF_WHEEL, data: unchecked((uint)wheelV)));
            if (wheelH != 0) inputs.Add(Mouse(MOUSEEVENTF_HWHEEL, data: unchecked((uint)wheelH)));
            Send(inputs.ToArray());
        }
    }

    // ---- スクロール細分化 ----
    // 1ノッチ (120) を一発で送ると段付きになるため、溜めて同じティックで少しずつ出す。
    private static double _wheelV, _wheelH; // 単位はホイールデルタ（120 = 1ノッチ）

    private static void QueueWheel(int vUnits, int hUnits)
    {
        lock (_moveLock)
        {
            _wheelV += vUnits;
            _wheelH += hUnits;
            EnsureTimerLocked();
        }
    }

    private static int DrainWheel(ref double pending)
    {
        const int cap = 16; // 1ティック (2ms) あたりの上限。1ノッチは約8ティックで捌ける
        int emit = (int)Math.Clamp(Math.Round(pending), -cap, cap);
        pending -= emit;
        return emit;
    }

    // ---- Mouse characteristic packets ----

    public static void HandleMousePacket(byte[] p)
    {
        if (p.Length == 0) return;
        switch (p[0])
        {
            case 0x01 when p.Length >= 5: // MOVE（スムージング経由）
            {
                int dx = BitConverter.ToInt16(p, 1);
                int dy = BitConverter.ToInt16(p, 3);
                if (dx != 0 || dy != 0)
                    QueueMove(dx, dy);
                break;
            }
            case 0x02 when p.Length >= 3: // BUTTON: 0=左,1=右,2=中 / 1=down,0=up
            {
                Log($"MOUSE button btn={p[1]} state={p[2]}");
                bool down = p[2] != 0;
                uint flag = p[1] switch
                {
                    0 => down ? MOUSEEVENTF_LEFTDOWN : MOUSEEVENTF_LEFTUP,
                    1 => down ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_RIGHTUP,
                    2 => down ? MOUSEEVENTF_MIDDLEDOWN : MOUSEEVENTF_MIDDLEUP,
                    _ => 0
                };
                if (flag != 0) Send(Mouse(flag));
                break;
            }
            case 0x03 when p.Length >= 3: // SCROLL: 正=上/右、1単位=1ノッチ(120)。細分化キューへ
            {
                sbyte v = (sbyte)p[1];
                sbyte h = (sbyte)p[2];
                if (v != 0 || h != 0)
                    QueueWheel(v * 120, h * 120);
                break;
            }
        }
    }

    // ---- Text characteristic packets ----

    public static void HandleTextPacket(byte[] p)
    {
        if (p.Length == 0) return;
        Log($"TEXT recv len={p.Length} kind=0x{p[0]:X2} hex={Convert.ToHexString(p.Take(Math.Min(24, p.Length)).ToArray())}");
        switch (p[0])
        {
            case 0x01: // TYPE: UTF-8（サロゲートペアはコードユニット単位で送ると正しく入る）
            {
                string text = System.Text.Encoding.UTF8.GetString(p, 1, p.Length - 1);
                Log($"TEXT type: \"{text}\" ({text.Length} chars)");
                var inputs = new List<INPUT>(text.Length * 2);
                foreach (char c in text)
                {
                    inputs.Add(Key(0, c, KEYEVENTF_UNICODE));
                    inputs.Add(Key(0, c, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP));
                }
                Send(inputs.ToArray());
                break;
            }
            case 0x02 when p.Length >= 2: // BACKSPACE x n
            {
                int n = p[1];
                var inputs = new List<INPUT>(n * 2);
                for (int i = 0; i < n; i++)
                {
                    inputs.Add(Key(0x08, 0, 0));
                    inputs.Add(Key(0x08, 0, KEYEVENTF_KEYUP));
                }
                Send(inputs.ToArray());
                break;
            }
            case 0x03: // ENTER
                Send(Key(0x0D, 0, 0), Key(0x0D, 0, KEYEVENTF_KEYUP));
                break;
            case 0x04 when p.Length >= 2: // KEY: 0=Esc,1=Tab,2=←,3=→,4=↑,5=↓
            {
                ushort vk = p[1] switch
                {
                    0 => (ushort)0x1B,
                    1 => (ushort)0x09,
                    2 => (ushort)0x25,
                    3 => (ushort)0x27,
                    4 => (ushort)0x26,
                    5 => (ushort)0x28,
                    _ => (ushort)0
                };
                if (vk != 0) Send(Key(vk, 0, 0), Key(vk, 0, KEYEVENTF_KEYUP));
                break;
            }
            case 0x05 when p.Length >= 2: // SHORTCUT: OSショートカット（3本指ジェスチャー用）
            {
                switch (p[1])
                {
                    case 0: KeyCombo(0x5B, 0x09); break;             // Win+Tab（タスクビュー）
                    case 1: KeyCombo(0x5B, 0x44); break;             // Win+D（デスクトップ表示）
                    case 2: KeyCombo(0x12, 0x09); break;             // Alt+Tab（次のアプリ）
                    case 3: KeyCombo(0x12, 0x10, 0x09); break;       // Alt+Shift+Tab（前のアプリ）
                    case 4: KeyCombo(0x5B, 0x53); break;             // Win+S（検索）
                }
                break;
            }
        }
    }

    /// <summary>複合キー。同時押ししたいキーを順に down し、逆順に up する。</summary>
    private static void KeyCombo(params ushort[] vks)
    {
        var inputs = new List<INPUT>(vks.Length * 2);
        foreach (var vk in vks) inputs.Add(Key(vk, 0, 0));
        for (int i = vks.Length - 1; i >= 0; i--) inputs.Add(Key(vks[i], 0, KEYEVENTF_KEYUP));
        Send(inputs.ToArray());
    }
}
