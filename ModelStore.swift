import Foundation

/// Downloads and stores GGUF weights in Application Support.
final class ModelStore: NSObject {

    static let shared = ModelStore()

    private var session: URLSession!
    private var progressHandler: ((Int64, Int64) -> Void)?
    private var completionHandler: ((Result<URL, Error>) -> Void)?
    private var destinationURL: URL?
    private var expectedBytes: Int64 = 0
    private var didFinishMove = false

    override init() {
        super.init()
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 30
        configuration.waitsForConnectivity = true
        session = URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: nil
        )
    }

    func modelsDirectory() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("Models", isDirectory: true)

        if !FileManager.default.fileExists(atPath: base.path) {
            try? FileManager.default.createDirectory(
                at: base,
                withIntermediateDirectories: true
            )
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutable = base
            try? mutable.setResourceValues(values)
        }
        return base
    }

    func existingModel(named fileName: String, expectedBytes: Int64) -> URL? {
        let url = modelsDirectory().appendingPathComponent(fileName)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return nil
        }
        if expectedBytes > 0 && size.int64Value != expectedBytes {
            return nil
        }
        return url
    }

    func download(
        fileName: String,
        from url: URL,
        expectedBytes: Int64,
        progress: @escaping (Int64, Int64) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let destination = modelsDirectory().appendingPathComponent(fileName)

        if let existing = existingModel(named: fileName, expectedBytes: expectedBytes) {
            completion(.success(existing))
            return
        }

        self.destinationURL = destination
        self.expectedBytes = expectedBytes
        self.progressHandler = progress
        self.completionHandler = completion
        self.didFinishMove = false

        var request = URLRequest(url: url)
        request.setValue("CoeyAi/64 (iOS)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")

        let task = session.downloadTask(with: request)
        task.resume()
    }

    private func finish(_ result: Result<URL, Error>) {
        let handler = completionHandler
        completionHandler = nil
        progressHandler = nil
        DispatchQueue.main.async {
            handler?(result)
        }
    }
}

extension ModelStore: URLSessionDownloadDelegate {

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let total = totalBytesExpectedToWrite > 0
            ? totalBytesExpectedToWrite
            : expectedBytes
        let handler = progressHandler
        DispatchQueue.main.async {
            handler?(totalBytesWritten, total)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let destination = destinationURL else { return }
        let fileManager = FileManager.default

        do {
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: location, to: destination)
            didFinishMove = true

            if expectedBytes > 0,
               let attributes = try? fileManager.attributesOfItem(atPath: destination.path),
               let size = attributes[.size] as? NSNumber,
               size.int64Value != expectedBytes {
                try? fileManager.removeItem(at: destination)
                finish(.failure(
                    NSError(
                        domain: "CoeyModel",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey:
                            "The weights downloaded incompletely. Try again."]
                    )
                ))
                return
            }

            finish(.success(destination))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else {
            if !didFinishMove {
                finish(.failure(
                    NSError(
                        domain: "CoeyModel",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey:
                            "The download finished without a file."]
                    )
                ))
            }
            return
        }

        if (error as NSError).code == NSURLErrorCancelled {
            finish(.failure(
                NSError(
                    domain: "CoeyModel",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "The download was stopped."]
                )
            ))
            return
        }
        finish(.failure(error))
    }
}
