import SwiftUI
import UIKit

/// 3本指ジェスチャー（ノートPCタッチパッド準拠）
enum ThreeFingerGesture {
    case tap, swipeUp, swipeDown, swipeLeft, swipeRight
}

/// マルチタッチを直接扱うトラックパッド面。挙動はノートPCのタッチパッドに合わせる。
/// 1本指ドラッグ=移動（速度で加速）、1本指タップ=左クリック、
/// タップ直後にもう一度触れて動かす（トン、ツー）=左ボタンを押したままドラッグ、
/// 2本指タップ=右クリック、2本指ドラッグ=スクロール、3本指=タップ/スワイプ。
struct TrackpadView: UIViewRepresentable {
    var onMove: (Double, Double) -> Void
    var onTap: (Int) -> Void // 引数 = 指の本数 (1 or 2)
    var onScroll: (Int, Int) -> Void // (垂直, 水平) ステップ（正=上/右）
    var onHoldChange: (Bool) -> Void // 2タップ目ドラッグの左ボタン down/up
    var onThreeFinger: (ThreeFingerGesture) -> Void

    func makeUIView(context: Context) -> TrackpadUIView {
        let view = TrackpadUIView()
        view.onMove = onMove
        view.onTap = onTap
        view.onScroll = onScroll
        view.onHoldChange = onHoldChange
        view.onThreeFinger = onThreeFinger
        return view
    }

    func updateUIView(_ uiView: TrackpadUIView, context: Context) {
        uiView.onMove = onMove
        uiView.onTap = onTap
        uiView.onScroll = onScroll
        uiView.onHoldChange = onHoldChange
        uiView.onThreeFinger = onThreeFinger
    }
}

final class TrackpadUIView: UIView {
    var onMove: ((Double, Double) -> Void)?
    var onTap: ((Int) -> Void)?
    var onScroll: ((Int, Int) -> Void)?
    var onHoldChange: ((Bool) -> Void)?
    var onThreeFinger: ((ThreeFingerGesture) -> Void)?

    /// ポインタ加速（タッチパッド準拠）: ゆっくり動かすと細かく、速いと大きく。
    /// gain = slowGain + (maxGain - slowGain) * speed / (speed + knee)
    private let slowGain = 1.1
    private let maxGain = 3.6
    private let gainKnee = 550.0 // pt/sec

    private func accelGain(speed: Double) -> Double {
        slowGain + (maxGain - slowGain) * speed / (speed + gainKnee)
    }

    private struct TouchState {
        var last: CGPoint
        var start: CGPoint
        var beganAt: Date
        var maxTravel: CGFloat = 0
        var lastMoveAt: Date
        /// 加速ゲイン用の速度推定（指数移動平均で平滑化）
        var smoothedSpeed: Double = 0
        /// 次の moved で現在位置を基準にし直す（2本→1本の切り替え直後用）
        var rebase = false
    }

    private var touches: [ObjectIdentifier: TouchState] = [:]
    private var twoFingerSession = false
    private var twoFingerTapFired = false
    private var lastCentroid: CGPoint?
    private var scrollRemainder: CGFloat = 0
    private var scrollRemainderX: CGFloat = 0

    // 2タップ目ドラッグ（タップ直後の再タッチで左ボタンを押下状態にする）
    private var lastTapEndedAt: Date?
    private var heldTouchID: ObjectIdentifier?
    private var buttonHeld = false
    private let haptics = UIImpactFeedbackGenerator(style: .medium)
    /// タップ終了からこの時間内に再タッチしたらドラッグ開始とみなす
    private let dragChainWindow: TimeInterval = 0.35

    // 3本指ジェスチャー
    private var threeFingerSession = false
    private var threeFingerFired = false
    private var threeStartCentroid: CGPoint?
    private var threeBeganAt = Date.distantPast

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 20
        layer.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func centroid(of points: [CGPoint]) -> CGPoint {
        let n = CGFloat(points.count)
        return CGPoint(
            x: points.reduce(0) { $0 + $1.x } / n,
            y: points.reduce(0) { $0 + $1.y } / n
        )
    }

    // MARK: - 2タップ目ドラッグ

    private func releaseHold() {
        if buttonHeld {
            buttonHeld = false
            heldTouchID = nil
            onHoldChange?(false)
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let p = touch.location(in: self)
            self.touches[ObjectIdentifier(touch)] = TouchState(last: p, start: p, beganAt: Date(), lastMoveAt: Date())
        }
        if self.touches.count >= 3, !threeFingerSession {
            // 3本指セッション開始。スクロール/ドラッグとは競合させない
            threeFingerSession = true
            threeFingerFired = false
            threeStartCentroid = centroid(of: self.touches.values.map { $0.last })
            threeBeganAt = Date()
            releaseHold()
        }
        if self.touches.count >= 2 {
            twoFingerSession = true
            lastCentroid = centroid(of: self.touches.values.map { $0.last })
            scrollRemainder = 0
            scrollRemainderX = 0
            // 2本目が来たらドラッグは中断（ボタンが押ささったままにならないよう離す）
            releaseHold()
        } else if self.touches.count == 1, let id = self.touches.keys.first,
                  let last = lastTapEndedAt,
                  Date().timeIntervalSince(last) <= dragChainWindow {
            // トン、ツー: 直前のタップに続く再タッチは「ボタンを押したまま」として始める。
            // そのまま離せば2回目のクリック（=ダブルクリック）になる。
            lastTapEndedAt = nil
            buttonHeld = true
            heldTouchID = id
            haptics.impactOccurred()
            onHoldChange?(true)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let now = Date()
        for touch in touches {
            let id = ObjectIdentifier(touch)
            guard var state = self.touches[id] else { continue }
            let p = touch.location(in: self)
            if state.rebase {
                state.rebase = false
                state.last = p
                state.start = p
                state.lastMoveAt = now
                state.smoothedSpeed = 0
            } else if !twoFingerSession {
                // 合体タッチ（中間サンプル）を全部たどる。イベントの最終点だけだと
                // 高速時に軌跡が折れ線になって「荒く」感じる
                let samples = event?.coalescedTouches(for: touch) ?? [touch]
                var totalDx = 0.0
                var totalDy = 0.0
                var prev = state.last
                for s in samples {
                    let sp = s.location(in: self)
                    totalDx += Double(sp.x - prev.x)
                    totalDy += Double(sp.y - prev.y)
                    prev = sp
                }
                let span: TimeInterval
                if samples.count > 1, let first = samples.first, let last = samples.last {
                    span = max(last.timestamp - first.timestamp, 0.001)
                } else {
                    span = max(now.timeIntervalSince(state.lastMoveAt), 0.001)
                }
                let instantSpeed = hypot(totalDx, totalDy) / span // pt/sec
                // 速度推定を平滑化しないとゲインが暴れてカーソルがガタつく
                state.smoothedSpeed = state.smoothedSpeed * 0.65 + instantSpeed * 0.35
                let gain = accelGain(speed: state.smoothedSpeed)
                let dx = totalDx * gain
                let dy = totalDy * gain
                if dx != 0 || dy != 0 {
                    onMove?(dx, dy)
                }
                state.lastMoveAt = now
            }
            state.maxTravel = max(state.maxTravel, hypot(p.x - state.start.x, p.y - state.start.y))
            state.last = p
            self.touches[id] = state
        }
        if threeFingerSession, !threeFingerFired, let start = threeStartCentroid {
            let c = centroid(of: self.touches.values.map { $0.last })
            let dx = c.x - start.x
            let dy = c.y - start.y
            if max(abs(dx), abs(dy)) >= 48 {
                threeFingerFired = true
                if abs(dx) > abs(dy) {
                    onThreeFinger?(dx > 0 ? .swipeRight : .swipeLeft)
                } else {
                    onThreeFinger?(dy > 0 ? .swipeDown : .swipeUp)
                }
            }
        } else if twoFingerSession {
            let c = centroid(of: self.touches.values.map { $0.last })
            if let last = lastCentroid {
                scrollRemainder += last.y - c.y // 指が上 = 値が正 = 上スクロール
                scrollRemainderX += c.x - last.x // 指が右 = 値が正 = 右スクロール
                let vSteps = Int(scrollRemainder / 12)
                let hSteps = Int(scrollRemainderX / 12)
                if vSteps != 0 || hSteps != 0 {
                    onScroll?(max(-8, min(8, vSteps)), max(-8, min(8, hSteps)))
                    scrollRemainder -= CGFloat(vSteps) * 12
                    scrollRemainderX -= CGFloat(hSteps) * 12
                }
            }
            lastCentroid = c
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let now = Date()
        for touch in touches {
            let id = ObjectIdentifier(touch)
            guard let state = self.touches[id] else { continue }
            let duration = now.timeIntervalSince(state.beganAt)
            let wasHeld = buttonHeld && heldTouchID == id
            if wasHeld { releaseHold() }
            if threeFingerSession {
                // 3本指タップ判定（最初に離れた指で1回だけ。短時間・ほぼ無移動）
                if !threeFingerFired {
                    threeFingerFired = true
                    if now.timeIntervalSince(threeBeganAt) < 0.4, state.maxTravel < 16 {
                        onThreeFinger?(.tap)
                    }
                }
            } else if twoFingerSession {
                // 2本指セッション中は両指が短時間・ほぼ無移動で離れたら右クリック（1回だけ）
                if !twoFingerTapFired, duration < 0.35, state.maxTravel < 14 {
                    twoFingerTapFired = true
                    onTap?(2)
                }
            } else if wasHeld {
                // 2タップ目ドラッグとして処理済み（down→up で完結）。タップにはしない
            } else if duration < 0.35, state.maxTravel < 12 {
                onTap?(1)
                // 次の再タッチがドラッグ開始になるよう、タップ終了時刻を残す
                lastTapEndedAt = now
            }
            self.touches.removeValue(forKey: id)
        }
        if self.touches.count < 3, threeFingerSession {
            threeFingerSession = false
            threeStartCentroid = nil
        }
        if self.touches.count == 1, twoFingerSession {
            // 2本→1本に減ったらセッションを切り替え、残った指を移動として基準化し直す
            twoFingerSession = false
            twoFingerTapFired = false
            lastCentroid = nil
            if let remaining = self.touches.keys.first,
               var state = self.touches[remaining] {
                state.rebase = true
                state.maxTravel = 0
                self.touches[remaining] = state
            }
        }
        if self.touches.isEmpty {
            twoFingerSession = false
            twoFingerTapFired = false
            lastCentroid = nil
            releaseHold()
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        // キャンセル時もボタンが押ささったままにならないよう必ず離す
        releaseHold()
        for touch in touches {
            self.touches.removeValue(forKey: ObjectIdentifier(touch))
        }
        if self.touches.count < 3 {
            threeFingerSession = false
            threeStartCentroid = nil
        }
        if self.touches.isEmpty {
            twoFingerSession = false
            twoFingerTapFired = false
            lastCentroid = nil
        }
    }
}
