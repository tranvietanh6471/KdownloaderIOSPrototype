import Foundation

struct DownloadProgressItem: Identifiable, Equatable {
    enum State: Equatable {
        case queued
        case running
        case paused
        case processing
        case completed
        case failed
        case cancelled
    }

    let id: UUID
    var fileName: String
    var percent: Double?
    var sizeText: String?
    var speedText: String?
    var etaText: String?
    var detailText: String?
    var state: State

    init(
        id: UUID = UUID(),
        fileName: String,
        percent: Double? = nil,
        sizeText: String? = nil,
        speedText: String? = nil,
        etaText: String? = nil,
        detailText: String? = nil,
        state: State = .queued
    ) {
        self.id = id
        self.fileName = fileName
        self.percent = percent
        self.sizeText = sizeText
        self.speedText = speedText
        self.etaText = etaText
        self.detailText = detailText
        self.state = state
    }
}

struct DownloadResumeContext {
    let url: String
    let preset: DownloadPreset
    let afterDownloadBehavior: AfterDownloadBehavior
    let outputTitleHint: String?
    let runOutputURL: URL
}
