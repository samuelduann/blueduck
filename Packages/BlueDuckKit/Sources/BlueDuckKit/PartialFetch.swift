/// Decides which byte range to download when the system asks for part of a file.
public enum PartialFetch {
    /// Smallest range fetched per request, so small sequential reads don't each cost an S3 round trip.
    public static let chunkSize: Int64 = 8 * 1024 * 1024

    /// Expands the requested range to one that starts on an `alignment` boundary, is at least
    /// `chunkSize` long, and either ends on an `alignment` boundary or at the end of the file.
    ///
    /// When the expanded range would leave less than one chunk at the end of the file, it is
    /// extended to the end so the tail doesn't need a separate request.
    /// - Returns: the range to fetch; a range of `0..<fileSize` means the whole file.
    public static func plan(offset: Int64, length: Int64, alignment: Int64, fileSize: Int64,
                            chunkSize: Int64 = chunkSize) -> Range<Int64> {
        guard fileSize > 0 else { return 0..<0 }
        let align = max(alignment, 1)
        let offset = min(max(offset, 0), fileSize)
        let start = offset / align * align
        var end = max(offset + max(length, 0), start + chunkSize)
        end = (end + align - 1) / align * align
        if end >= fileSize || fileSize - end < chunkSize {
            end = fileSize
        }
        return start..<end
    }
}
