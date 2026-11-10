import SwiftUI
import UIKit

/// マルチタッチを直接扱うトラックパッド面。
/// 1本指ドラッグ=移動、1本指タップ=左クリック、2本指タップ=右クリック、2本指ドラッグ=スクロール。
struct TrackpadView: UIViewRepresentable {
    var onMove: (Double, Double) -> Void
    var onTap: (Int) -> Void // 引数 = 指の本数 (1 or 2)
    var onScroll: (Int) -> Void // 垂直ステップ（正=上）

    func makeUIView(context: Context) -> TrackpadUIView {
        let view = TrackpadUIView()
        view.onMove = onMove
        view.onTap = onTap
        view.onScroll = onScroll
        return view
    }

    func updateUIView(_ uiView: TrackpadUIView, context: Context) {
        uiView.onMove = onMove
        uiView.onTap = onTap
        uiView.onScroll = onScroll
    }
}

final class TrackpadUIView: UIView {
    var onMove: ((Double, Double) -> Void)?
    var onTap: ((Int) -> Void)?
    var onScroll: ((Int) -> Void)?

    /// 移動の感度（指の動きに対する倍率）
    var sensitivity: Double = 1.8

    private struct TouchState {
        var last: CGPoint
        var start: CGPoint
        var beganAt: Date
        var maxTravel: CGFloat = 0
        /// 次の moved で現在位置を基準にし直す（2本→1本の切り替え直後用）
        var rebase = false
    }

    private var touches: [ObjectIdentifier: TouchState] = [:]
    private var twoFingerSession = false
    private var twoFingerTapFired = false
    private var lastCentroid: CGPoint?
    private var scrollRemainder: CGFloat = 0

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

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let p = touch.location(in: self)
            self.touches[ObjectIdentifier(touch)] = TouchState(last: p, start: p, beganAt: Date())
        }
        if self.touches.count >= 2 {
            twoFingerSession = true
            lastCentroid = centroid(of: self.touches.values.map { $0.last })
            scrollRemainder = 0
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let id = ObjectIdentifier(touch)
            guard var state = self.touches[id] else { continue }
            let p = touch.location(in: self)
            if state.rebase {
                state.rebase = false
                state.last = p
                state.start = p
            } else if !twoFingerSession {
                let dx = Double(p.x - state.last.x) * sensitivity
                let dy = Double(p.y - state.last.y) * sensitivity
                if dx != 0 || dy != 0 {
                    onMove?(dx, dy)
                }
            }
            state.maxTravel = max(state.maxTravel, hypot(p.x - state.start.x, p.y - state.start.y))
            state.last = p
            self.touches[id] = state
        }
        if twoFingerSession {
            let c = centroid(of: self.touches.values.map { $0.last })
            if let last = lastCentroid {
                scrollRemainder += last.y - c.y // 指が上 = 値が正 = 上スクロール
                let steps = Int(scrollRemainder / 12)
                if steps != 0 {
                    onScroll?(max(-8, min(8, steps)))
                    scrollRemainder -= CGFloat(steps) * 12
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
            if twoFingerSession {
                // 2本指セッション中は両指が短時間・ほぼ無移動で離れたら右クリック（1回だけ）
                if !twoFingerTapFired, duration < 0.35, state.maxTravel < 14 {
                    twoFingerTapFired = true
                    onTap?(2)
                }
            } else if duration < 0.35, state.maxTravel < 12 {
                onTap?(1)
            }
            self.touches.removeValue(forKey: id)
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
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            self.touches.removeValue(forKey: ObjectIdentifier(touch))
        }
        if self.touches.isEmpty {
            twoFingerSession = false
            twoFingerTapFired = false
            lastCentroid = nil
        }
    }
}
