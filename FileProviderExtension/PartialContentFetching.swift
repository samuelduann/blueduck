import BlueDuckKit
import FileProvider

/// Downloads only the part of a file an app reads (for example a video player seeking), instead of the
/// whole object. The system calls this for POSIX reads of a file that isn't downloaded; other reads,
/// such as through file coordination, still go through `fetchContents`.
extension FileProviderExtension: NSFileProviderPartialContentFetching {
    func fetchPartialContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion,
                              request: NSFileProviderRequest, minimalRange requestedRange: NSRange, aligningTo alignment: Int,
                              options: NSFileProviderFetchContentsOptions,
                              completionHandler: @escaping (URL?, NSFileProviderItem?, NSRange, NSFileProviderMaterializationFlags, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        perform(progress, onError: { completionHandler(nil, nil, NSRange(location: 0, length: 0), [], $0) }) { [self] in
            let client = try requireClient()
            guard let record = store.record(itemIdentifier.rawValue), !record.isFolder else {
                throw NSFileProviderError(.noSuchItem)
            }
            let strict = options.contains(.strictVersioning)
            // The content version is the ETag (see FileProviderItem.itemVersion).
            let requestedETag = String(decoding: requestedVersion.contentVersion, as: UTF8.self)
            if requestedETag != record.etag && strict {
                throw NSFileProviderError(.versionNoLongerAvailable)
            }

            let range = PartialFetch.plan(offset: Int64(requestedRange.location), length: Int64(requestedRange.length),
                                          alignment: Int64(alignment), fileSize: record.size)
            // A stale request, an empty file, or a range covering the whole file is a normal download.
            if requestedETag != record.etag || range.count == record.size {
                let (url, updated) = try await downloadWhole(record, progress: progress)
                completionHandler(url, item(updated), NSRange(location: 0, length: Int(updated.size)), [], nil)
                return
            }

            let destination = temporaryFileURL()
            do {
                try await client.downloadRange(key: record.key, offset: range.lowerBound, length: Int64(range.count),
                                               into: destination, ifMatch: record.etag, progress: progress)
            } catch let error as S3Error where error.status == 412 || error.status == 416 {
                // The object changed in S3 since it was listed.
                try? FileManager.default.removeItem(at: destination)
                if strict { throw NSFileProviderError(.versionNoLongerAvailable) }
                let (url, updated) = try await downloadWhole(record, progress: progress)
                completionHandler(url, item(updated), NSRange(location: 0, length: Int(updated.size)), [], nil)
                return
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
            completionHandler(destination, item(record),
                              NSRange(location: Int(range.lowerBound), length: range.count), [], nil)
        }
        return progress
    }
}
