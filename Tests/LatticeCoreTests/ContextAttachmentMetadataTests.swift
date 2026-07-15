import Foundation
import Testing
@testable import LatticeCore

@Suite("Context attachment multimodal metadata")
struct ContextAttachmentMetadataTests {
    @Test func legacyDecodingPreservesMissingAndDerivesKindFromExtension() throws {
        let imageID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let fileID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let legacyJSON = Data(
            """
            [
              {"id":"\(imageID.uuidString)","path":"/tmp/photo.PNG","isMissing":false},
              {"id":"\(fileID.uuidString)","path":"imported://notes.txt","isMissing":true}
            ]
            """.utf8
        )

        let decoded = try JSONDecoder().decode([ContextAttachment].self, from: legacyJSON)
        #expect(decoded.count == 2)

        let image = decoded[0]
        #expect(image.id == imageID)
        #expect(image.path == "/tmp/photo.PNG")
        #expect(!image.isMissing)
        #expect(image.kind == .image)
        #expect(image.isImage)
        #expect(image.source == .legacy)
        #expect(image.contentTypeIdentifier == nil)
        #expect(image.mimeType == nil)
        #expect(image.byteCount == nil)
        #expect(image.pixelDimensions == nil)

        let missing = decoded[1]
        #expect(missing.id == fileID)
        #expect(missing.isMissing)
        #expect(missing.kind == .file)
        #expect(!missing.isImage)
        #expect(missing.source == .legacy)
        #expect(missing.name == "notes.txt")
    }

    @Test func roundTripEncodingPreservesTypedMetadataWithoutBytes() throws {
        let attachment = ContextAttachment(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            path: "/Users/me/shots/window.png",
            isMissing: false,
            kind: .image,
            contentTypeIdentifier: "public.png",
            mimeType: "image/png",
            byteCount: 2048,
            pixelDimensions: ContextAttachmentPixelDimensions(width: 128, height: 64),
            source: .screenshot
        )

        let encoded = try JSONEncoder().encode(attachment)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["id"] as? String == attachment.id.uuidString)
        #expect(object["path"] as? String == attachment.path)
        #expect(object["isMissing"] as? Bool == false)
        #expect(object["kind"] as? String == "image")
        #expect(object["contentTypeIdentifier"] as? String == "public.png")
        #expect(object["mimeType"] as? String == "image/png")
        #expect(object["byteCount"] as? Int == 2048)
        #expect(object["source"] as? String == "screenshot")
        #expect(object["data"] == nil)
        #expect(object["base64"] == nil)
        #expect(object["bytes"] == nil)
        #expect(object["contents"] == nil)

        let decoded = try JSONDecoder().decode(ContextAttachment.self, from: encoded)
        #expect(decoded == attachment)
        #expect(decoded.pixelDimensions?.width == 128)
        #expect(decoded.pixelDimensions?.height == 64)
    }

    @Test func legacyInitializerRemainsSourceCompatible() {
        let attachment = ContextAttachment(path: "/tmp/readme.md")
        #expect(attachment.path == "/tmp/readme.md")
        #expect(!attachment.isMissing)
        #expect(attachment.kind == .file)
        #expect(attachment.source == .legacy)
        #expect(attachment.name == "readme.md")

        let missing = ContextAttachment(id: UUID(), path: "token://gone", isMissing: true)
        #expect(missing.isMissing)
        #expect(missing.source == .legacy)
        #expect(missing.kind == .file)
    }

    @Test func classifiesCommonImageAndFileTypesFromEvidence() {
        let pngEvidence = ContextAttachmentInspectionEvidence(
            fileExists: true,
            byteCount: 120,
            contentTypeIdentifier: "public.png",
            mimeType: "image/png",
            pixelDimensions: ContextAttachmentPixelDimensions(width: 10, height: 12),
            typeEvidenceFromContent: true
        )
        let png = ContextAttachmentClassifier.classify(path: "/tmp/mystery.bin", evidence: pngEvidence)
        #expect(!png.isMissing)
        #expect(png.kind == .image)
        #expect(png.contentTypeIdentifier == "public.png")
        #expect(png.mimeType == "image/png")
        #expect(png.byteCount == 120)
        #expect(png.pixelDimensions?.width == 10)
        #expect(png.pixelDimensions?.height == 12)

        let textEvidence = ContextAttachmentInspectionEvidence(
            fileExists: true,
            byteCount: 40,
            contentTypeIdentifier: "public.plain-text",
            mimeType: "text/plain",
            typeEvidenceFromContent: true
        )
        let text = ContextAttachmentClassifier.classify(path: "/tmp/notes.txt", evidence: textEvidence)
        #expect(text.kind == .file)
        #expect(text.mimeType == "text/plain")
        #expect(text.pixelDimensions == nil)

        let extensionOnly = ContextAttachmentClassifier.classify(
            path: "/tmp/photo.jpeg",
            evidence: ContextAttachmentInspectionEvidence(fileExists: true, byteCount: 9)
        )
        #expect(extensionOnly.kind == .image)
        #expect(extensionOnly.contentTypeIdentifier == "public.jpeg")
        #expect(extensionOnly.mimeType == "image/jpeg")

        let authoritativeText = ContextAttachmentClassifier.classify(
            path: "/tmp/not-really.png",
            evidence: ContextAttachmentInspectionEvidence(
                fileExists: true,
                byteCount: 4,
                contentTypeIdentifier: "public.plain-text",
                mimeType: "text/plain",
                typeEvidenceFromContent: true
            )
        )
        #expect(authoritativeText.kind == .file)
    }

    @Test func missingFilesAreTruthfullyMarked() {
        let missing = ContextAttachmentClassifier.classify(
            path: "/tmp/does-not-exist-lattice-test.png",
            evidence: ContextAttachmentInspectionEvidence(fileExists: false)
        )
        #expect(missing.isMissing)
        #expect(missing.kind == .image)
        #expect(missing.byteCount == nil)
        #expect(missing.pixelDimensions == nil)

        let nilEvidence = ContextAttachmentClassifier.classify(path: "/tmp/report.pdf", evidence: nil)
        #expect(nilEvidence.isMissing)
        #expect(nilEvidence.kind == .file)

        let inspector = ClosureContextAttachmentInspector { _ in
            ContextAttachmentInspectionEvidence(fileExists: false)
        }
        let attachment = ContextAttachment.inspecting(
            path: "/tmp/missing-shot.png",
            source: .paste,
            inspector: inspector
        )
        #expect(attachment.isMissing)
        #expect(attachment.kind == .image)
        #expect(attachment.source == .paste)
        #expect(attachment.byteCount == nil)
    }

    @Test func dimensionsAndSizePopulateWhenEvidenceProvidesThem() {
        let inspector = ClosureContextAttachmentInspector { path in
            #expect(path.hasSuffix("canvas.png"))
            return ContextAttachmentInspectionEvidence(
                fileExists: true,
                byteCount: 4096,
                contentTypeIdentifier: "public.png",
                mimeType: "image/png",
                pixelDimensions: ContextAttachmentPixelDimensions(width: 320, height: 200),
                typeEvidenceFromContent: true
            )
        }

        let attachment = ContextAttachment.inspecting(
            url: URL(fileURLWithPath: "/tmp/canvas.png"),
            source: .drop,
            inspector: inspector
        )
        #expect(!attachment.isMissing)
        #expect(attachment.kind == .image)
        #expect(attachment.byteCount == 4096)
        #expect(attachment.pixelDimensions?.width == 320)
        #expect(attachment.pixelDimensions?.height == 200)
        #expect(attachment.source == .drop)
        #expect(attachment.isImage)
    }

    @Test func oversizeValidationRejectsLargeBytesAndPixels() {
        let limits = ContextAttachmentValidationPolicy(maximumByteCount: 1_000, maximumPixelEdge: 100)

        let oversizeBytes = ContextAttachment(
            path: "/tmp/big.png",
            kind: .image,
            contentTypeIdentifier: "public.png",
            mimeType: "image/png",
            byteCount: 5_000,
            pixelDimensions: ContextAttachmentPixelDimensions(width: 50, height: 50),
            source: .picker
        )
        let byteIssues = ContextAttachmentValidator.issues(for: oversizeBytes, limits: limits)
        #expect(byteIssues == [.oversizeBytes(actual: 5_000, limit: 1_000)])
        #expect(!ContextAttachmentValidator.isAcceptable(oversizeBytes, limits: limits))

        let oversizePixels = ContextAttachment(
            path: "/tmp/wide.png",
            kind: .image,
            byteCount: 100,
            pixelDimensions: ContextAttachmentPixelDimensions(width: 400, height: 20),
            source: .screenshot
        )
        let pixelIssues = ContextAttachmentValidator.issues(for: oversizePixels, limits: limits)
        #expect(pixelIssues == [.oversizePixels(width: 400, height: 20, limit: 100)])

        let missing = ContextAttachment(path: "/tmp/gone.png", isMissing: true)
        #expect(ContextAttachmentValidator.issues(for: missing, limits: limits) == [.missing])

        let ok = ContextAttachment(
            path: "/tmp/ok.png",
            kind: .image,
            byteCount: 100,
            pixelDimensions: ContextAttachmentPixelDimensions(width: 32, height: 32),
            source: .picker
        )
        #expect(ContextAttachmentValidator.isAcceptable(ok, limits: limits))
    }

    @Test func headerSniffDetectsPNGWithoutExtension() throws {
        let pngHeader = Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52
        ])
        let sniffed = try #require(ContextAttachmentTypeMap.sniff(header: pngHeader))
        #expect(sniffed.contentTypeIdentifier == "public.png")
        #expect(sniffed.mimeType == "image/png")

        let textHeader = Data("hello lattice".utf8)
        #expect(ContextAttachmentTypeMap.sniff(header: textHeader) == nil)

        #expect(ContextAttachmentTypeMap.kind(forPathExtension: "png") == .image)
        #expect(ContextAttachmentTypeMap.kind(forPathExtension: "swift") == .file)
    }

    @Test func fileInspectorRejectsImageExtensionWithoutDecodableImageContent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-context-spoof-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let disguised = directory.appendingPathComponent("notes.png")
        try Data("not an image".utf8).write(to: disguised)

        let attachment = ContextAttachment.inspecting(
            url: disguised,
            source: .picker,
            inspector: FileContextAttachmentInspector()
        )

        #expect(!attachment.isMissing)
        #expect(attachment.kind == .file)
        #expect(attachment.mimeType == "application/octet-stream")
        #expect(attachment.pixelDimensions == nil)
    }

    @Test func fileInspectorClassifiesRealPNGAndTextFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-context-attachment-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Minimal valid 1×1 PNG.
        let pngURL = directory.appendingPathComponent("pixel.png")
        let pngData = Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
            0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41,
            0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
            0x00, 0x00, 0x03, 0x00, 0x01, 0x00, 0x05, 0xFE,
            0x02, 0xFE, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45,
            0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82
        ])
        try pngData.write(to: pngURL)
        let extensionlessImageURL = directory.appendingPathComponent("pixel.bin")
        try pngData.write(to: extensionlessImageURL)

        let textURL = directory.appendingPathComponent("notes.txt")
        try Data("bounded metadata only".utf8).write(to: textURL)

        let inspector = FileContextAttachmentInspector()
        let image = ContextAttachment.inspecting(url: pngURL, source: .picker, inspector: inspector)
        #expect(!image.isMissing)
        #expect(image.kind == .image)
        #expect(image.isImage)
        #expect(image.byteCount == Int64(pngData.count))
        #expect(image.mimeType == "image/png" || image.contentTypeIdentifier == "public.png")
        #expect(image.pixelDimensions?.width == 1)
        #expect(image.pixelDimensions?.height == 1)
        #expect(image.source == .picker)

        let extensionlessImage = ContextAttachment.inspecting(url: extensionlessImageURL, source: .drop, inspector: inspector)
        #expect(extensionlessImage.kind == .image)
        #expect(extensionlessImage.mimeType == "image/png")

        let file = ContextAttachment.inspecting(url: textURL, source: .drop, inspector: inspector)
        #expect(!file.isMissing)
        #expect(file.kind == .file)
        #expect(!file.isImage)
        #expect(file.byteCount == Int64("bounded metadata only".utf8.count))
        #expect(file.pixelDimensions == nil)
        #expect(file.source == .drop)

        let missingPath = directory.appendingPathComponent("absent.bin").path
        let missing = ContextAttachment.inspecting(
            path: missingPath,
            source: .imported,
            inspector: inspector
        )
        #expect(missing.isMissing)
        #expect(missing.source == .imported)
        #expect(missing.byteCount == nil)
    }

    @Test func encodedPayloadNeverIncludesFileContents() throws {
        let attachment = ContextAttachment.inspecting(
            path: "/tmp/secret.png",
            source: .paste,
            inspector: ClosureContextAttachmentInspector { _ in
                ContextAttachmentInspectionEvidence(
                    fileExists: true,
                    byteCount: 12,
                    contentTypeIdentifier: "public.png",
                    mimeType: "image/png",
                    pixelDimensions: ContextAttachmentPixelDimensions(width: 2, height: 2),
                    typeEvidenceFromContent: true
                )
            }
        )
        let data = try JSONEncoder().encode(attachment)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("base64"))
        #expect(!json.contains("iVBOR")) // PNG base64 signature fragment
        #expect(!json.contains("fileContents"))
    }
}
