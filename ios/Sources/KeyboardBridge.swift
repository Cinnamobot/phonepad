import SwiftUI
import UIKit

/// 隠し UITextField で iOS キーボード（フリック入力含む）を出し、
/// 「確定済みテキスト」の差分だけをコールバックする。
/// IME 未確定（marked）部分は送らない。確定が進むたびに差分（削除→追加入力）を返す。
struct KeyboardBridge: UIViewRepresentable {
    @Binding var isOpen: Bool
    /// (backspaces, typeText) — PC 側の現在テキストを新しい確定テキストに合わせるための差分
    var onCommit: (Int, String) -> Void
    var onEnter: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCommit: onCommit, onEnter: onEnter)
    }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.delegate = context.coordinator
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.smartInsertDeleteType = .no
        field.returnKeyType = .send
        field.alpha = 0.02 // 完全に 0 だとキーボードが出ないことがある
        context.coordinator.field = field
        field.addTarget(
            context.coordinator,
            action: #selector(Coordinator.textChanged),
            for: .editingChanged
        )
        return field
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        context.coordinator.onCommit = onCommit
        context.coordinator.onEnter = onEnter
        if isOpen, !uiView.isFirstResponder {
            uiView.becomeFirstResponder()
        } else if !isOpen, uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var onCommit: (Int, String) -> Void
        var onEnter: () -> Void
        weak var field: UITextField?
        /// PC 側に送った確定済みテキスト
        private var sent = ""

        init(onCommit: @escaping (Int, String) -> Void, onEnter: @escaping () -> Void) {
            self.onCommit = onCommit
            self.onEnter = onEnter
        }

        /// テキストのうち IME 未確定部分を除いた「確定済み」文字列
        private func committedText(of field: UITextField) -> String {
            let text = field.text ?? ""
            guard let marked = field.markedTextRange else { return text }
            let start = field.offset(from: field.beginningOfDocument, to: marked.start)
            guard start >= 0, start <= text.count else { return text }
            let idx = text.index(text.startIndex, offsetBy: start)
            return String(text[..<idx])
        }

        @objc func textChanged() {
            guard let field else { return }
            let committed = committedText(of: field)
            guard committed != sent else { return }
            // 共通プレフィックスを残し、残りを削除→追加として送る
            let common = zip(sent, committed).prefix { $0 == $1 }.count
            let backspaces = sent.count - common
            let suffix = String(committed.dropFirst(common))
            sent = committed
            onCommit(backspaces, suffix)
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            onEnter()
            textField.text = ""
            sent = ""
            return false
        }
    }
}
