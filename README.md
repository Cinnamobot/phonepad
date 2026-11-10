# PhonePad

iPhone を Windows PC のトラックパッド＋キーボードにする自作セット。
Bluetooth LE (BLE) のみで接続し、ネットは使わない。

- **iPhone アプリ (ios/)**: トラックパッド面とフリック入力。BLE ペリフェラルとして入力イベントを送信
- **Windows レシーバー (receiver/)**: トレイ常駐。BLE セントラルとして受信し、`SendInput` でマウス/キー入力を注入

## 操作

| 操作 | 動作 |
|---|---|
| 1本指でなぞる | カーソル移動（相対）。速度で加速する（ゆっくり=細かく、速く=大きく）タッチパッド準拠 |
| 1本指タップ | 左クリック |
| タップ→すぐ再タッチして動かす（トン、ツー） | 左ボタンを押したままドラッグ（離すと解放）。軽い振動で開始が分かる。そのまま離せばダブルクリック |
| 2本指タップ | 右クリック |
| 2本指ドラッグ | スクロール |
| 3本指タップ | Win+S（検索） |
| 3本指スワイプ 上/下 | Win+Tab（タスクビュー）/ Win+D（デスクトップ表示） |
| 3本指スワイプ 右/左 | Alt+Tab（次のアプリ）/ Alt+Shift+Tab（前のアプリ） |
| キーボードボタン | iOS キーボードを開く。フリック入力した確定文字がそのまま PC に打たれる |
| Esc / Tab / 矢印キー | レシーバー側で対応キーとして入力 |

## プロトコル (BLE GATT)

- Service: `A1B2C3D4-E5F6-4789-ABCD-000000000001`
- Mouse characteristic (notify): `A1B2C3D4-E5F6-4789-ABCD-000000000002`
- Text characteristic (notify): `A1B2C3D4-E5F6-4789-ABCD-000000000003`

Mouse パケット（先頭バイトが種別）:

- `0x01` MOVE: `[1..2]=dx int16 LE, [3..4]=dy int16 LE`
- `0x02` BUTTON: `[1]=button (0=左,1=右,2=中), [2]=state (1=down, 0=up)`
- `0x03` SCROLL: `[1]=垂直 int8（正=上）, [2]=水平 int8`

Text パケット（先頭バイトがコマンド）:

- `0x01` TYPE: 残り = UTF-8 文字列（確定済みテキストのみ送る。IME 未確定分は送らない）
- `0x02` BACKSPACE: `[1]=回数`
- `0x03` ENTER
- `0x04` KEY: `[1]=特殊キー (0=Esc, 1=Tab, 2=←, 3=→, 4=↑, 5=↓)`
- `0x05` SHORTCUT: `[1]=OSショートカット (0=Win+Tab, 1=Win+D, 2=Alt+Tab, 3=Alt+Shift+Tab, 4=Win+S)`

## ビルド

GitHub Actions (`.github/workflows/build.yml`) が両方をビルドする。Mac は不要。

- iOS: macOS ランナーで XcodeGen → 未署名 `.ipa` を生成（アーティファクト `PhonePad-ipa`）
- Windows: `PhonePadReceiver.exe`（単一ファイル、.NET 同梱）を生成（アーティファクト `PhonePadReceiver-exe`）

## インストールと使い方

1. Windows で `PhonePadReceiver.exe` を起動（トレイに常駐し、自動で iPhone を探し始める）
2. iPhone に `.ipa` をサイドローディングでインストール（Sideloadly / AltStore 等）
   - 無料 Apple ID の署名は7日で切れる。AltStore / SideStore の自動更新を使うと楽
   - iPhone のキーボード設定で「日本語（フリック）」を有効にしておく
3. Windows の Bluetooth をオンにし、iPhone アプリを開いて「待ち受け開始」
4. レシーバーが自動接続する（アプリ側の表示が「接続中」になる）
5. トラックパッド面をなぞればカーソルが動く

## 注意

- v1 は暗号化なしの素の GATT。自宅デスク前提の設計なので、外で使うときは要注意
- iPhone アプリはフォアグラウンド動作が前提
- ペアリング（ボンディング）は使わない。接続はアプリを開くたびにレシーバーが自動で行う
