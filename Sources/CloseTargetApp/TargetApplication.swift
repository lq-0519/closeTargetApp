import Foundation

struct TargetApplication: Codable, Hashable, Identifiable {
    let id: UUID
    var displayName: String
    var bundleIdentifier: String?
    var path: String

    init(
        id: UUID = UUID(),
        displayName: String,
        bundleIdentifier: String?,
        path: String
    ) {
        self.id = id
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.path = path
    }
}
