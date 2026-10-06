import SwiftUI

@main
struct SoundGalleryApp: App {
    @State private var model = GalleryModel()

    var body: some Scene {
        WindowGroup {
            GalleryView(model: model)
        }
        #if os(macOS)
            .defaultSize(width: 980, height: 760)
        #endif
    }
}
