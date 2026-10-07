#if os(iOS) || os(macOS)
    import AVKit
    import SwiftUI

    /// The system AirPlay button (`AVRoutePickerView`): tap it to send the music to a HomePod, an Apple TV or a
    /// Bluetooth speaker.
    ///
    /// On iOS the music follows the chosen route. On macOS the picker lists the outputs, but a custom `AVAudioEngine`
    /// plays to the system output device, so the app (or the user in the menu bar) must make the chosen route the
    /// system output for the engine to follow it.
    ///
    /// `tint` and `activeTint` color the button on iOS; macOS draws its own button and ignores them.
    public struct AirPlayPicker {
        public var tint: Color?
        public var activeTint: Color?

        public init(tint: Color? = nil, activeTint: Color? = nil) {
            self.tint = tint
            self.activeTint = activeTint
        }

        /// The view the representable wraps, built without SwiftUI so a test can inspect it.
        @MainActor func makePlatformView() -> AVRoutePickerView {
            let view = AVRoutePickerView()
            #if os(iOS)
                view.prioritizesVideoDevices = false
                if let tint { view.tintColor = UIColor(tint) }
                if let activeTint { view.activeTintColor = UIColor(activeTint) }
            #endif
            return view
        }
    }

    #if os(iOS)
        extension AirPlayPicker: UIViewRepresentable {
            public func makeUIView(context: Context) -> AVRoutePickerView { makePlatformView() }
            public func updateUIView(_ view: AVRoutePickerView, context: Context) {
                if let tint { view.tintColor = UIColor(tint) }
                if let activeTint { view.activeTintColor = UIColor(activeTint) }
            }
        }
    #else
        extension AirPlayPicker: NSViewRepresentable {
            public func makeNSView(context: Context) -> AVRoutePickerView { makePlatformView() }
            public func updateNSView(_ view: AVRoutePickerView, context: Context) {}
        }
    #endif
#endif
