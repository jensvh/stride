import AVFoundation
import CoreMedia
import SwiftUI
import UIKit

/// Shows the glasses' compressed (HEVC) camera frames. The toolkit can't turn
/// those into a UIImage; a sample-buffer layer decodes and shows them.
@MainActor
final class FramePreview {
    let layer = AVSampleBufferDisplayLayer()

    init() {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = UIColor.black.cgColor
    }

    func show(_ buffer: CMSampleBuffer) {
        // Show each frame as it arrives instead of waiting for its timestamp.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding { renderer.flush() }
        renderer.enqueue(buffer)
    }

    func flush() {
        layer.sampleBufferRenderer.flush(removingDisplayedImage: false, completionHandler: nil)
    }
}

struct FramePreviewView: UIViewRepresentable {
    let preview: FramePreview

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.backgroundColor = .black
        view.hosted = preview.layer
        return view
    }

    func updateUIView(_ view: LayerView, context: Context) {}

    final class LayerView: UIView {
        var hosted: CALayer? {
            didSet {
                oldValue?.removeFromSuperlayer()
                if let hosted { layer.addSublayer(hosted) }
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            hosted?.frame = bounds
        }
    }
}
