import SwiftUI

struct TrafficLightGlassCapsule: View {
    var body: some View {
        Color.clear
            .glassEffect(.regular, in: Capsule())
    }
}
