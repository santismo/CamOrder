import Foundation

public enum ProjectDocumentError: LocalizedError {
    case missingProjectJSON(URL)
    case invalidProjectPackage(URL)

    public var errorDescription: String? {
        switch self {
        case .missingProjectJSON(let url):
            return "No project.json was found in \(url.path)."
        case .invalidProjectPackage(let url):
            return "\(url.lastPathComponent) is not a CamOrder Studio project folder."
        }
    }
}

public struct ProjectDocument {
    public static let fileExtension = "camorderstudio"
    public static let projectFileName = "project.json"

    public let folderURL: URL
    public var project: CamOrderProject

    public init(folderURL: URL, project: CamOrderProject) {
        self.folderURL = folderURL
        self.project = project
    }

    public static func create(at folderURL: URL, project: CamOrderProject) throws -> ProjectDocument {
        try createFolderStructure(at: folderURL)
        let document = ProjectDocument(folderURL: folderURL, project: project)
        try document.save()
        return document
    }

    public static func open(at folderURL: URL) throws -> ProjectDocument {
        guard folderURL.pathExtension == fileExtension else {
            throw ProjectDocumentError.invalidProjectPackage(folderURL)
        }
        let projectURL = folderURL.appendingPathComponent(projectFileName)
        guard FileManager.default.fileExists(atPath: projectURL.path) else {
            throw ProjectDocumentError.missingProjectJSON(folderURL)
        }
        let data = try Data(contentsOf: projectURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let project = try decoder.decode(CamOrderProject.self, from: data)
        return ProjectDocument(folderURL: folderURL, project: project)
    }

    public func save() throws {
        try Self.createFolderStructure(at: folderURL)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(project)
        try data.write(to: folderURL.appendingPathComponent(Self.projectFileName), options: .atomic)
    }

    public static func createFolderStructure(at folderURL: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        for relativePath in ["media/video", "media/audio", "media/proxies", "exports", "logs"] {
            try fileManager.createDirectory(at: folderURL.appendingPathComponent(relativePath), withIntermediateDirectories: true)
        }
    }

    public func absoluteURL(for relativePath: String) -> URL {
        folderURL.appendingPathComponent(relativePath)
    }
}
