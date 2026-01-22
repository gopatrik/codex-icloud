import Foundation

final class DirectoryMonitor {
    private let url: URL
    private var fileDescriptor: CInt = -1
    private var source: DispatchSourceFileSystemObject?

    var onChange: (() -> Void)?
    var isActive: Bool { source != nil && fileDescriptor != -1 }

    init(url: URL) {
        self.url = url
    }

    func start() {
        stop()
        fileDescriptor = open(url.path, O_EVTONLY)
        guard fileDescriptor != -1 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .delete, .extend, .attrib, .rename],
            queue: DispatchQueue.global(qos: .utility)
        )

        source.setEventHandler { [weak self] in
            self?.onChange?()
        }

        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.fileDescriptor != -1 {
                close(self.fileDescriptor)
                self.fileDescriptor = -1
            }
            self.source = nil
        }

        self.source = source
        source.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    deinit {
        stop()
    }
}
