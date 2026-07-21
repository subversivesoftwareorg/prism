import SwiftUI

struct MainTabView: View {
    @State private var store = ProxyStore()
    @State private var selectedTab = 0

    @AppStorage("autoStartProxy") private var autoStartProxy = false

    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardView()
                .tabItem { Label("Dashboard", systemImage: "gauge.with.dots.needle.33percent") }
                .tag(0)

            LiveTrafficView()
                .tabItem { Label("Traffic", systemImage: "arrow.left.arrow.right") }
                .tag(1)

            DomainsView()
                .tabItem {
                    Label("Domains", systemImage: "globe")
                }
                .badge(store.trackingDomainCount)
                .tag(2)

            SummariesView()
                .tabItem { Label("Summaries", systemImage: "clock.arrow.circlepath") }
                .tag(3)
        }
        .environment(store)
        .frame(minWidth: 800, minHeight: 550)
        .onAppear {
            if autoStartProxy && !store.isRunning {
                store.startProxy()
            }
        }
    }
}
