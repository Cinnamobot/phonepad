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
    // 注入すると到着のムラがカーソルのムラになるため、到着ペースから速度を
    // 推定し、4ms 周期で均して再生する（本物のマウスの等間隔レポートに寄せる）。
    private const int TickMs = 4;
    private static readonly object _moveLock = new();
    private static double _pendX, _pendY;   // 受信済み・未送信の移動量
    private static double _velX, _velY;     // 推定速度 (px/ms)
    private static double _fracX, _fracY;   // 整数化で余った端数
    private static long _lastArrival;
    private static System.Threading.Timer? _moveTimer;

    private static void QueueMove(int dx, int dy)
    {
        lock (_moveLock)
        {
            long now = Environment.TickCount64;
            if (_lastArrival != 0)
            {
                double dt = Math.Clamp(now - _lastArrival, 4, 100);
                _velX = _velX * 0.5 + dx / dt * 0.5;
                _velY = _velY * 0.5 + dy / dt * 0.5;
            }
            else
            {
                _velX = dx / 30.0;
                _velY = dy / 30.0;
            }
            _lastArrival = now;
            _pendX += dx;
            _pendY += dy;
            _moveTimer ??= new System.Threading.Timer(MoveTick, null, TickMs, TickMs);
        }
    }

    private static void MoveTick(object? state)
    {
        int ex, ey;
        lock (_moveLock)
        {
            // 到着が止まったら速度を減衰させる（残量はクランプで守られる）
            if (Environment.TickCount64 - _lastArrival > 80)
            {
                _velX *= 0.7;
                _velY *= 0.7;
            }
            double sx = _velX * TickMs + _fracX;
            double sy = _velY * TickMs + _fracY;
            ex = (int)sx;
            ey = (int)sy;
            _fracX = sx - ex;
            _fracY = sy - ey;
            // 受け取った分以上は出さない。方向が食い違う瞬間はその軸を止める
            if (Math.Abs(ex) > Math.Abs(_pendX)) { ex = (int)Math.Round(_pendX); _fracX = 0; }
            if (Math.Abs(ey) > Math.Abs(_pendY)) { ey = (int)Math.Round(_pendY); _fracY = 0; }
            if (ex != 0 && Math.Sign(ex) != Math.Sign(_pendX)) { ex = 0; _fracX = 0; }
            if (ey != 0 && Math.Sign(ey) != Math.Sign(_pendY)) { ey = 0; _fracY = 0; }
            _pendX -= ex;
            _pendY -= ey;
        }
        if (ex != 0 || ey != 0)
            Send(Mouse(MOUSEEVENTF_MOVE, ex, ey));
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
            case 0x03 when p.Length >= 3: // SCROLL: 正=上/右、1単位=1ノッチ(120)
            {
                sbyte v = (sbyte)p[1];
                sbyte h = (sbyte)p[2];
                var inputs = new List<INPUT>();
                if (v != 0) inputs.Add(Mouse(MOUSEEVENTF_WHEEL, data: unchecked((uint)(v * 120))));
                if (h != 0) inputs.Add(Mouse(MOUSEEVENTF_HWHEEL, data: unchecked((uint)(h * 120))));
                Send(inputs.ToArray());
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
