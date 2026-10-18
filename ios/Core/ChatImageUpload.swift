import CryptoKit
import Foundation
import ImageIO

enum ChatImageError: LocalizedError, Sendable, Equatable {
    case invalidImage, tooLarge, uploadFailed(Int), invalidUploadResponse
    var errorDescription: String? {
        switch self {
        case .invalidImage: "图片内容无效或无法解码，请重新选择或拍摄。图片未作为纯文字发送。"
        case .tooLarge: "单张聊天图片超过 10 MB，请缩小后重试。"
        case .uploadFailed(let code): "图片上传失败（\(code)），请检查网络、Key 和余额后重试。"
        case .invalidUploadResponse: "图片上传未返回有效 file_id，已停止本轮回答。"
        }
    }
}

/// Per-APIClient bounded cache, never persisted to SwiftData/Memory or logs.
/// Images auto-expire server-side after one hour; no permanent uploads.
actor ChatImageUpload {
    private struct Entry { let fileID: String; let expires: Date }
    private var cache: [String: Entry] = [:]

    static func decodedImage(_ dataURL: String) throws -> (data: Data, mime: String) {
        guard dataURL.utf8.count <= 15_000_000 else { throw ChatImageError.tooLarge }
        guard let separator = dataURL.firstIndex(of: ","),
              ["data:image/jpeg;base64", "data:image/png;base64", "data:image/gif;base64", "data:image/webp;base64"].contains(String(dataURL[..<separator])),
              let data = Data(base64Encoded: String(dataURL[dataURL.index(after: separator)...])), !data.isEmpty else {
            throw ChatImageError.invalidImage
        }
        guard data.count <= 10 * 1024 * 1024 else { throw ChatImageError.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { throw ChatImageError.invalidImage }
        let mime: String
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { mime = "image/jpeg" }
        else if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { mime = "image/png" }
        else if data.starts(with: Array("GIF8".utf8)) { mime = "image/gif" }
        else if data.starts(with: Array("RIFF".utf8)), data.count > 12,
                data[8..<12].elementsEqual(Array("WEBP".utf8)) { mime = "image/webp" }
        else { throw ChatImageError.invalidImage }
        return (data, mime)
    }

    func prepare(_ urls: [String], key: String, session: URLSession) async throws -> [String: String] {
        var mapped: [String: String] = [:]
        for url in urls where mapped[url] == nil {
            try Task.checkCancellation()
            let image = try Self.decodedImage(url)
            let identity = SHA256.hash(data: Data((key + url).utf8)).map { String(format: "%02x", $0) }.joined()
            if let entry = cache[identity], entry.expires > Date() { mapped[url] = entry.fileID; continue }
            let boundary = "DeepSeekImage-" + UUID().uuidString
            let bytes = Self.multipart(data: image.data, mime: image.mime, boundary: boundary)
            var request = URLRequest(url: URL(string: "https://api.deepseek.com/files")!)
            request.httpMethod = "POST"; request.timeoutInterval = 90; request.httpBody = bytes
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else { throw ChatImageError.invalidUploadResponse }
            guard (200..<300).contains(response.statusCode) else { throw ChatImageError.uploadFailed(response.statusCode) }
            guard data.count < 64_000, let result = try? JSONDecoder().decode(UploadResponse.self, from: data),
                  result.id.hasPrefix("file-api-"), result.id.count <= 200,
                  result.expires_at > Date().timeIntervalSince1970,
                  result.expires_at <= Date().addingTimeInterval(3720).timeIntervalSince1970,
                  result.id.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") }) else {
                throw ChatImageError.invalidUploadResponse
            }
            if let size = result.bytes, size != image.data.count { throw ChatImageError.invalidUploadResponse }
            cache = cache.filter { $0.value.expires > Date() }
            if cache.count >= 12 { cache.removeAll() }
            cache[identity] = .init(fileID: result.id, expires: min(Date().addingTimeInterval(3300), Date(timeIntervalSince1970: result.expires_at - 60)))
            mapped[url] = result.id
        }
        return mapped
    }

    static func multipart(data: Data, mime: String, boundary: String) -> Data {
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }
        for (name, value) in [("purpose", "user_data"), ("expires_after[anchor]", "created_at"), ("expires_after[seconds]", "3600")] {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        let ext = mime == "image/jpeg" ? "jpg" : String(mime.dropFirst(6))
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"image.\(ext)\"\r\nContent-Type: \(mime)\r\n\r\n")
        body.append(data); append("\r\n--\(boundary)--\r\n")
        return body
    }
    private struct UploadResponse: Decodable { let id: String; let expires_at: TimeInterval; let bytes: Int? }
}
