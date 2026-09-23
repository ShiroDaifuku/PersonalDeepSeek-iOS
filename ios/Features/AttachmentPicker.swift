import SwiftUI
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers

struct PendingAttachment: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let mimeType: String
    let data: Data

    var isImage: Bool { mimeType.hasPrefix("image/") }
    var dataURL: String { "data:\(mimeType);base64,\(data.base64EncodedString())" }
    var textContent: String? {
        guard mimeType == "text/plain" || mimeType == "application/json" else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func image(data: Data, name: String = "image.jpg") -> PendingAttachment? {
        guard let original = UIImage(data: data) else { return nil }
        let maximumDimension: CGFloat = 1_600
        let scale = min(1, maximumDimension / max(original.size.width, original.size.height))
        let size = CGSize(width: max(1, original.size.width * scale), height: max(1, original.size.height * scale))
        let image = scale < 1 ? UIGraphicsImageRenderer(size: size).image { _ in original.draw(in: CGRect(origin: .zero, size: size)) } : original
        var jpeg: Data?
        for quality in [0.82, 0.68, 0.52, 0.38] {
            jpeg = image.jpegData(compressionQuality: quality)
            if (jpeg?.count ?? .max) <= 1_200_000 { break }
        }
        guard let jpeg else { return nil }
        return PendingAttachment(name: name, mimeType: "image/jpeg", data: jpeg)
    }
}

struct AttachmentStrip: View {
    let attachments: [PendingAttachment]
    let remove: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(attachments) { item in
                    ZStack(alignment: .topTrailing) {
                        Group {
                            if item.isImage, let image = UIImage(data: item.data) {
                                Image(uiImage: image).resizable().scaledToFill()
                            } else {
                                VStack(spacing: 4) {
                                    Image(systemName: "doc.fill").font(.title2)
                                    Text(item.name).font(.caption2).lineLimit(2)
                                }.padding(6)
                            }
                        }
                        .frame(width: 76, height: 76)
                        .background(.secondary.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        Button { remove(item.id) } label: {
                            Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.7))
                        }
                        .offset(x: 5, y: -5)
                        .accessibilityLabel("移除 \(item.name)")
                    }
                }
            }.padding(.horizontal).padding(.top, 6)
        }
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    let completion: (Data?) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = .camera
        controller.cameraCaptureMode = .photo
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: CameraPicker
        init(parent: CameraPicker) { self.parent = parent }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.completion(nil); parent.dismiss() }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let data = (info[.originalImage] as? UIImage)?.jpegData(compressionQuality: 0.82)
            parent.completion(data)
            parent.dismiss()
        }
    }
}

enum CameraAuthorization {
    static func request() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .video)
        default: false
        }
    }
}
