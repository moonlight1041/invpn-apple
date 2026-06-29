import Foundation
import Compression

// MARK: - Gzip frame helper
//
// Wraps Apple's Compression framework (COMPRESSION_ZLIB = raw DEFLATE, RFC 1951) in a
// standard gzip frame (RFC 1952). Output is byte-compatible with Python's gzip.compress /
// gzip.decompress (which both use raw DEFLATE inside a gzip container).
//
// CRC32: standard table-based implementation, polynomial 0xEDB88320.
//
// gunzip assumption: FLG byte == 0 (no FEXTRA/FNAME/FCOMMENT/FHCRC extra header fields).
// Python's gzip.compress(data, compresslevel=9) always writes FLG=0, so this holds for
// all envelopes produced by the backend.

enum Gzip {

    // MARK: - CRC32

    private static let table: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) == 0 ? c >> 1 : (c >> 1) ^ 0xEDB8_8320
            }
            return c
        }
    }()

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            let idx = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = (crc >> 8) ^ table[idx]
        }
        return ~crc
    }

    // MARK: - Compress → gzip

    /// Gzip-compress `data`.
    /// Encodes with raw DEFLATE (COMPRESSION_ZLIB on Apple platforms), then wraps in a
    /// gzip frame: 10-byte header + deflate bytes + CRC32(LE,4) + ISIZE(LE,4).
    static func gzip(_ data: Data) throws -> Data {
        let srcCount = data.count
        // Allocate a generous output buffer; DEFLATE can expand slightly for
        // incompressible data.
        let dstCapacity = max(srcCount + (srcCount / 4) + 1024, 256)
        var deflated = [UInt8](repeating: 0, count: dstCapacity)

        let compressedSize: Int = data.withUnsafeBytes { srcBuf in
            guard let src = srcBuf.baseAddress else { return 0 }
            return compression_encode_buffer(
                &deflated, dstCapacity,
                src.assumingMemoryBound(to: UInt8.self), srcCount,
                nil,
                COMPRESSION_ZLIB
            )
        }
        guard compressedSize > 0 else { throw TelemetryCryptoError.gzip }

        var out = Data(capacity: 10 + compressedSize + 8)

        // Gzip header (RFC 1952 §2.3):
        //   ID1=0x1F  ID2=0x8B  CM=8(deflate)  FLG=0  MTIME=0(4B)  XFL=0  OS=255(unknown)
        out.append(contentsOf: [0x1F, 0x8B, 0x08, 0x00,
                                 0x00, 0x00, 0x00, 0x00,
                                 0x00, 0xFF] as [UInt8])

        // Raw deflate bytes
        out.append(contentsOf: deflated.prefix(compressedSize))

        // CRC32 of the original data, little-endian
        let crc = crc32(data)
        out.append(UInt8((crc      ) & 0xFF))
        out.append(UInt8((crc >>  8) & 0xFF))
        out.append(UInt8((crc >> 16) & 0xFF))
        out.append(UInt8((crc >> 24) & 0xFF))

        // ISIZE = original length mod 2^32, little-endian
        let isize = UInt32(truncatingIfNeeded: srcCount)
        out.append(UInt8((isize      ) & 0xFF))
        out.append(UInt8((isize >>  8) & 0xFF))
        out.append(UInt8((isize >> 16) & 0xFF))
        out.append(UInt8((isize >> 24) & 0xFF))

        return out
    }

    // MARK: - Decompress ← gzip

    /// Gunzip a gzip-framed buffer.
    /// Validates magic bytes, skips the 10-byte header (FLG=0 assumed), reads ISIZE
    /// from the 4-byte trailer to size the output buffer, then raw-INFLATEs the deflate
    /// body via COMPRESSION_ZLIB.
    static func gunzip(_ data: Data) throws -> Data {
        let base = data.startIndex
        let count = data.count

        // Validate gzip magic (RFC 1952 §2.3.1)
        guard count >= 18,
              data[base]     == 0x1F,
              data[base + 1] == 0x8B
        else { throw TelemetryCryptoError.gzip }

        // Gzip header is 10 bytes (FLG=0 → no extra fields)
        let deflateStart = base + 10
        // Last 8 bytes of a gzip file: CRC32(4) + ISIZE(4)
        let trailerStart = base + count - 8
        guard deflateStart < trailerStart else { throw TelemetryCryptoError.gzip }

        // Read ISIZE (uncompressed size, little-endian uint32) from bytes [n-4 .. n-1]
        let isizeOff = base + count - 4
        let isize = UInt32(data[isizeOff    ])        |
                   (UInt32(data[isizeOff + 1]) <<  8) |
                   (UInt32(data[isizeOff + 2]) << 16) |
                   (UInt32(data[isizeOff + 3]) << 24)
        let outCount = Int(isize)

        // Edge case: empty original data
        if outCount == 0 { return Data() }

        var output = [UInt8](repeating: 0, count: outCount)
        let deflateSlice = data[deflateStart ..< trailerStart]

        let decompressedSize: Int = deflateSlice.withUnsafeBytes { srcBuf in
            guard let src = srcBuf.baseAddress else { return 0 }
            return compression_decode_buffer(
                &output, outCount,
                src.assumingMemoryBound(to: UInt8.self), deflateSlice.count,
                nil,
                COMPRESSION_ZLIB
            )
        }
        guard decompressedSize == outCount else { throw TelemetryCryptoError.gzip }
        return Data(output)
    }
}
