import SwiftUI
import WhiplashCore

struct MainView: View {
    let roleStore: RoleStore
    let settingsStore: SettingsStore
    @State private var flow = InputFlow()
    @State private var showSettings = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            InputView(flow: flow, roleStore: roleStore, settingsStore: settingsStore)
                .navigationTitle("Whiplash")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showSettings = true } label: {
                            Image(systemName: "gearshape")
                        }
                    }
                }
                .sheet(isPresented: $showSettings) {
                    NavigationStack {
                        iOSSettingsView(roleStore: roleStore, settingsStore: settingsStore)
                            .navigationTitle("設定")
                            .toolbar {
                                ToolbarItem(placement: .topBarTrailing) {
                                    Button("完了") { showSettings = false }
                                }
                            }
                    }
                }
        }
        .onAppear { flow.pickUpContext() }
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                flow.pickUpContext()
            }
        }
    }
}
