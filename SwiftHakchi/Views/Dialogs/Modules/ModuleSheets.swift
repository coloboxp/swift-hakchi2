import SwiftUI

/// Sheets opened from the Modules menu (repository manager, Bluetooth)
struct ModuleSheets: ViewModifier {
    @ObservedObject var appState: AppState
    @ObservedObject private var router = ModuleRouter.shared

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $router.showRepositoryManager) {
                RepositoryManagerView()
            }
            .sheet(isPresented: $router.showBluetooth) {
                BluetoothView()
                    .environmentObject(appState)
            }
    }
}
