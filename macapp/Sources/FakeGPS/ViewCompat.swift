import SwiftUI

/// 兼容 macOS 12 的 onChange：旧系统用单参数版本，macOS 14+ 用双参数版本。
/// 仅 `macos-12` 分支使用；master 分支直接用双参数原版。
extension View {
    @ViewBuilder
    func onChangeCompat<V: Equatable>(
        of value: V,
        perform action: @escaping (_ newValue: V) -> Void
    ) -> some View {
        if #available(macOS 14, *) {
            self.onChange(of: value) { _, newValue in action(newValue) }
        } else {
            self.onChange(of: value, perform: action)
        }
    }
}
