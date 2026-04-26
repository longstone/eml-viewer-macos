//
//  CFBReader.swift
//  eml-viewer
//
//  Minimal reader for the Compound File Binary (CFB / OLE2) container
//  used by Microsoft Outlook .msg files. Enough to walk the directory
//  tree and pull stream contents out by path. No write support.
//
//  Spec reference: [MS-CFB].
//

import Foundation

struct CFBDirEntry {
    let index: UInt32
    let name: String
    let type: UInt8           // 0 empty, 1 storage, 2 stream, 5 root
    let leftID: UInt32
    let rightID: UInt32
    let childID: UInt32
    let startSector: UInt32
    let size: UInt64
}

final class CFBReader {

    // Sector chain sentinels
    private static let FREESECT:    UInt32 = 0xFFFFFFFF
    private static let ENDOFCHAIN:  UInt32 = 0xFFFFFFFE
    private static let FATSECT:     UInt32 = 0xFFFFFFFD
    private static let DIFSECT:     UInt32 = 0xFFFFFFFC
    private static let NOSTREAM:    UInt32 = 0xFFFFFFFF

    private let data: Data
    private let sectorSize: Int
    private let miniSectorSize: Int
    private let miniStreamCutoff: Int
    private let fat: [UInt32]
    private let miniFAT: [UInt32]
    private let miniStream: Data
    let entries: [CFBDirEntry]
    /// parentIndex -> [childIndex]
    let childrenByParent: [UInt32: [UInt32]]

    /// Returns nil if the bytes don't look like a CFB container.
    init?(data: Data) {
        guard data.count >= 512 else { return nil }
        let magic: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
        guard [UInt8](data.prefix(8)) == magic else { return nil }

        self.data = data
        let sectorShift      = data.u16LE(at: 0x1E)
        let miniSectorShift  = data.u16LE(at: 0x20)
        let numFATSectors    = Int(data.u32LE(at: 0x2C))
        let firstDirSector   =      data.u32LE(at: 0x30)
        self.miniStreamCutoff = Int(data.u32LE(at: 0x38))
        let firstMiniFAT     =      data.u32LE(at: 0x3C)
        let numMiniFAT       = Int(data.u32LE(at: 0x40))
        let firstDIFAT       =      data.u32LE(at: 0x44)
        let numDIFATSectors  = Int(data.u32LE(at: 0x48))

        let sectorSize = 1 << Int(sectorShift)
        self.sectorSize = sectorSize
        self.miniSectorSize = 1 << Int(miniSectorShift)

        // --- Build DIFAT (list of FAT sector numbers) ---
        var difat: [UInt32] = []
        difat.reserveCapacity(109 + numDIFATSectors * (sectorSize / 4 - 1))
        for i in 0..<109 {
            difat.append(data.u32LE(at: 0x4C + i * 4))
        }
        var nextDIFAT = firstDIFAT
        var safety = numDIFATSectors + 16
        while nextDIFAT != Self.ENDOFCHAIN, nextDIFAT != Self.FREESECT, safety > 0 {
            let base = (Int(nextDIFAT) + 1) * sectorSize
            let perSector = sectorSize / 4 - 1
            for i in 0..<perSector {
                if base + i * 4 + 4 > data.count { break }
                difat.append(data.u32LE(at: base + i * 4))
            }
            if base + perSector * 4 + 4 > data.count { break }
            nextDIFAT = data.u32LE(at: base + perSector * 4)
            safety -= 1
        }

        // --- Build FAT ---
        var fat: [UInt32] = []
        fat.reserveCapacity(numFATSectors * (sectorSize / 4))
        for sec in difat where sec != Self.FREESECT {
            let base = (Int(sec) + 1) * sectorSize
            let count = sectorSize / 4
            for i in 0..<count {
                let off = base + i * 4
                if off + 4 > data.count { break }
                fat.append(data.u32LE(at: off))
            }
        }
        self.fat = fat

        // --- Build mini-FAT ---
        let miniFATBytes = Self.readChain(data: data,
                                          sectorSize: sectorSize,
                                          fat: fat,
                                          startSector: firstMiniFAT,
                                          expectedSectors: numMiniFAT)
        var miniFAT: [UInt32] = []
        miniFAT.reserveCapacity(miniFATBytes.count / 4)
        var idx = 0
        while idx + 4 <= miniFATBytes.count {
            miniFAT.append(miniFATBytes.u32LE(at: idx))
            idx += 4
        }
        self.miniFAT = miniFAT

        // --- Read directory ---
        let dirBytes = Self.readChain(data: data,
                                      sectorSize: sectorSize,
                                      fat: fat,
                                      startSector: firstDirSector,
                                      expectedSectors: nil)
        let entryCount = dirBytes.count / 128
        var entries: [CFBDirEntry] = []
        entries.reserveCapacity(entryCount)
        for i in 0..<entryCount {
            let off = i * 128
            let nameLen = Int(dirBytes.u16LE(at: off + 0x40))
            let name: String = {
                guard nameLen >= 2, nameLen <= 64 else { return "" }
                // name is UTF-16LE, includes terminating null.
                let raw = dirBytes.subdata(in: off..<(off + nameLen - 2))
                return String(data: raw, encoding: .utf16LittleEndian) ?? ""
            }()
            let entry = CFBDirEntry(
                index: UInt32(i),
                name: name,
                type: dirBytes[off + 0x42],
                leftID:  dirBytes.u32LE(at: off + 0x44),
                rightID: dirBytes.u32LE(at: off + 0x48),
                childID: dirBytes.u32LE(at: off + 0x4C),
                startSector: dirBytes.u32LE(at: off + 0x74),
                size:   dirBytes.u64LE(at: off + 0x78)
            )
            entries.append(entry)
        }
        self.entries = entries

        // --- Build mini stream from root entry ---
        if let root = entries.first, root.type == 5 {
            self.miniStream = Self.readChain(data: data,
                                             sectorSize: sectorSize,
                                             fat: fat,
                                             startSector: root.startSector,
                                             expectedSectors: nil,
                                             maxBytes: Int(root.size))
        } else {
            self.miniStream = Data()
        }

        // --- Walk the tree to compute parent->children mapping ---
        var childrenByParent: [UInt32: [UInt32]] = [:]
        func collect(_ id: UInt32, parent: UInt32) {
            guard id != Self.NOSTREAM, Int(id) < entries.count else { return }
            childrenByParent[parent, default: []].append(id)
            let e = entries[Int(id)]
            collect(e.leftID, parent: parent)
            collect(e.rightID, parent: parent)
            if e.type == 1 || e.type == 5 {
                collect(e.childID, parent: id)
            }
        }
        if let root = entries.first {
            collect(root.childID, parent: 0)
        }
        self.childrenByParent = childrenByParent
    }

    // MARK: - Public helpers

    func children(of parentIndex: UInt32) -> [CFBDirEntry] {
        (childrenByParent[parentIndex] ?? []).compactMap {
            Int($0) < entries.count ? entries[Int($0)] : nil
        }
    }

    func child(of parentIndex: UInt32, named name: String) -> CFBDirEntry? {
        children(of: parentIndex).first { $0.name == name }
    }

    /// Reads a stream's raw bytes (regular FAT or mini-FAT, based on size).
    func readStream(_ entry: CFBDirEntry) -> Data {
        guard entry.type == 2 else { return Data() }
        let size = Int(entry.size)
        if size < miniStreamCutoff {
            return Self.readMiniChain(miniStream: miniStream,
                                      miniSectorSize: miniSectorSize,
                                      miniFAT: miniFAT,
                                      startSector: entry.startSector,
                                      maxBytes: size)
        } else {
            return Self.readChain(data: data,
                                  sectorSize: sectorSize,
                                  fat: fat,
                                  startSector: entry.startSector,
                                  expectedSectors: nil,
                                  maxBytes: size)
        }
    }

    // MARK: - Internal chain walkers

    private static func readChain(data: Data,
                                  sectorSize: Int,
                                  fat: [UInt32],
                                  startSector: UInt32,
                                  expectedSectors: Int?,
                                  maxBytes: Int? = nil) -> Data {
        var out = Data()
        var current = startSector
        var visited: Set<UInt32> = []
        var remaining = maxBytes
        while current != ENDOFCHAIN, current != FREESECT,
              Int(current) < fat.count || maxBytes != nil {
            if !visited.insert(current).inserted { break } // cycle guard
            let base = (Int(current) + 1) * sectorSize
            let end = min(base + sectorSize, data.count)
            if base >= data.count { break }
            var slice = data.subdata(in: base..<end)
            if let rem = remaining {
                if slice.count > rem { slice = slice.prefix(rem) }
                remaining = rem - slice.count
                out.append(slice)
                if remaining! <= 0 { break }
            } else {
                out.append(slice)
            }
            if Int(current) >= fat.count { break }
            current = fat[Int(current)]
            if let exp = expectedSectors, visited.count >= exp * 2 { break }
        }
        return out
    }

    private static func readMiniChain(miniStream: Data,
                                      miniSectorSize: Int,
                                      miniFAT: [UInt32],
                                      startSector: UInt32,
                                      maxBytes: Int) -> Data {
        var out = Data()
        var current = startSector
        var visited: Set<UInt32> = []
        var remaining = maxBytes
        while current != ENDOFCHAIN, current != FREESECT,
              Int(current) < miniFAT.count, remaining > 0 {
            if !visited.insert(current).inserted { break }
            let base = Int(current) * miniSectorSize
            let end = min(base + miniSectorSize, miniStream.count)
            if base >= miniStream.count { break }
            var slice = miniStream.subdata(in: base..<end)
            if slice.count > remaining { slice = slice.prefix(remaining) }
            out.append(slice)
            remaining -= slice.count
            current = miniFAT[Int(current)]
        }
        return out
    }
}

// MARK: - Little-endian helpers on Data

extension Data {
    func u16LE(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }
    func u32LE(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return  UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }
    func u64LE(at offset: Int) -> UInt64 {
        guard offset + 8 <= count else { return 0 }
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(self[offset + i]) << (8 * i) }
        return v
    }
}
