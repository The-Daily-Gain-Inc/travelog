import Foundation

/// Thin Google Drive v3 REST client using the signed-in user's OAuth token.
struct DriveService {
    struct DriveFile: Decodable {
        let id: String
        let name: String
        let mimeType: String
        let createdTime: Date?
        let size: String?
    }

    private struct FileList: Decodable {
        let files: [DriveFile]
        let nextPageToken: String?
    }

    static let folderMime = "application/vnd.google-apps.folder"

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601WithFractionalSeconds
        return d
    }()

    private func query(_ q: String, token: String) async throws -> [DriveFile] {
        var all: [DriveFile] = []
        var pageToken: String? = nil
        repeat {
            var comps = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
            var items = [
                URLQueryItem(name: "q", value: q),
                URLQueryItem(name: "fields", value: "nextPageToken,files(id,name,mimeType,createdTime,size)"),
                URLQueryItem(name: "pageSize", value: "1000"),
                URLQueryItem(name: "orderBy", value: "name"),
            ]
            if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            comps.queryItems = items
            var req = URLRequest(url: comps.url!)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let page = try Self.decoder.decode(FileList.self, from: data)
            all += page.files
            pageToken = page.nextPageToken
        } while pageToken != nil
        return all
    }

    /// Finds the root folder by name (anywhere in My Drive), or nil.
    func findRootFolder(named name: String, token: String) async throws -> DriveFile? {
        let escaped = name.replacingOccurrences(of: "'", with: "\\'")
        return try await query(
            "name = '\(escaped)' and mimeType = '\(Self.folderMime)' and trashed = false",
            token: token
        ).first
    }

    func subfolders(of folderId: String, token: String) async throws -> [DriveFile] {
        try await query(
            "'\(folderId)' in parents and mimeType = '\(Self.folderMime)' and trashed = false",
            token: token
        )
    }

    func mediaFiles(in folderId: String, token: String) async throws -> [DriveFile] {
        try await query(
            "'\(folderId)' in parents and (mimeType contains 'image/' or mimeType contains 'video/') and trashed = false",
            token: token
        )
    }

    func downloadURL(for fileId: String) -> URL {
        URL(string: "https://www.googleapis.com/drive/v3/files/\(fileId)?alt=media")!
    }
}

extension JSONDecoder.DateDecodingStrategy {
    static let iso8601WithFractionalSeconds = custom { decoder in
        let s = try decoder.singleValueContainer().decode(String.self)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date: \(s)"))
    }
}
