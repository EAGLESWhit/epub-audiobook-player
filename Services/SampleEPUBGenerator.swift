import CoreGraphics
import Foundation
import UIKit
import ZIPFoundation

/// Generates a real, standards-compliant `.epub` archive on disk using `ZIPFoundation`
/// so users can immediately test the full unzip -> XMLParser -> TTS pipeline in the Simulator
/// alongside importing `.epub` files via `.fileImporter`.
enum SampleEPUBGenerator {
    static func createSampleEPUBFile() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let epubURL = tempDir.appendingPathComponent("The_Glass_Observatory_Sample.epub")

        if FileManager.default.fileExists(atPath: epubURL.path) {
            try? FileManager.default.removeItem(at: epubURL)
        }

        let archive = try Archive(url: epubURL, accessMode: .create)

        // 1. mimetype
        let mimetypeData = Data("application/epub+zip".utf8)
        try addEntry(to: archive, path: "mimetype", data: mimetypeData, compressionMethod: .none)

        // 2. META-INF/container.xml
        let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """
        try addEntry(to: archive, path: "META-INF/container.xml", data: Data(containerXML.utf8))

        // 3. OEBPS/cover.png
        if let coverData = renderSampleCoverPNG() {
            try addEntry(to: archive, path: "OEBPS/cover.png", data: coverData)
        }

        // 4. OEBPS/content.opf
        let opfXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" unique-identifier="BookId" version="3.0">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="BookId">urn:uuid:8b7c9e12-4c21-4d8a-9b34-123456789abc</dc:identifier>
            <dc:title>The Glass Observatory</dc:title>
            <dc:creator>Clara Vance</dc:creator>
            <dc:language>en</dc:language>
            <meta name="cover" content="cover-image"/>
          </metadata>
          <manifest>
            <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
            <item id="cover-image" href="cover.png" media-type="image/png" properties="cover-image"/>
            <item id="ch1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
            <item id="ch2" href="chapter2.xhtml" media-type="application/xhtml+xml"/>
            <item id="ch3" href="chapter3.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine toc="ncx">
            <itemref idref="ch1"/>
            <itemref idref="ch2"/>
            <itemref idref="ch3"/>
          </spine>
        </package>
        """
        try addEntry(to: archive, path: "OEBPS/content.opf", data: Data(opfXML.utf8))

        // 5. OEBPS/toc.ncx
        let ncxXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
          <head>
            <meta name="dtb:uid" content="urn:uuid:8b7c9e12-4c21-4d8a-9b34-123456789abc"/>
          </head>
          <docTitle><text>The Glass Observatory</text></docTitle>
          <navMap>
            <navPoint id="navPoint-1" playOrder="1">
              <navLabel><text>Chapter 1: Signals from the Horizon</text></navLabel>
              <content src="chapter1.xhtml"/>
            </navPoint>
            <navPoint id="navPoint-2" playOrder="2">
              <navLabel><text>Chapter 2: The Prism Archive</text></navLabel>
              <content src="chapter2.xhtml"/>
            </navPoint>
            <navPoint id="navPoint-3" playOrder="3">
              <navLabel><text>Chapter 3: Dawn Over Meridian</text></navLabel>
              <content src="chapter3.xhtml"/>
            </navPoint>
          </navMap>
        </ncx>
        """
        try addEntry(to: archive, path: "OEBPS/toc.ncx", data: Data(ncxXML.utf8))

        // 6. Three XHTML chapters
        let chapter1XHTML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
          <head><title>Chapter 1: Signals from the Horizon</title></head>
          <body>
            <h1>Chapter 1: Signals from the Horizon</h1>
            <p>High above the tidal cliffs of Meridian, the glass dome of the observatory caught the last amber rays of sunset.</p>
            <p>Elena adjusted the brass vernier dial and listened as the acoustic receiver translated starlight into a gentle, rhythmic hum.</p>
            <p>For three winters the coastal beacon had remained silent, yet tonight a clear harmonic pattern echoed across the northern frequency.</p>
            <p>She opened her leather journal, marked the coordinates in crisp ink, and prepared the telescope for a long night of discovery.</p>
            <p>Every pulse carried a story across the dark water, waiting to be decoded sentence by sentence.</p>
          </body>
        </html>
        """

        let chapter2XHTML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
          <head><title>Chapter 2: The Prism Archive</title></head>
          <body>
            <h1>Chapter 2: The Prism Archive</h1>
            <p>Beneath the main rotunda lay the Prism Archive, a circular library lined with thousands of crystalline cylinders.</p>
            <p>Each cylinder preserved spoken chronicles recorded by navigators who had crossed the outer archipelago centuries ago.</p>
            <p>When illuminated by a narrow beam of lantern light, the etched grooves projected both text and resonant voice into the quiet chamber.</p>
            <p>Elena selected the seventh chronicle from the cedar shelf and placed it carefully onto the reader cradle.</p>
            <p>Immediately, a familiar chart of the winter constellations unfolded in luminous silver lines above the table.</p>
          </body>
        </html>
        """

        let chapter3XHTML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
          <head><title>Chapter 3: Dawn Over Meridian</title></head>
          <body>
            <h1>Chapter 3: Dawn Over Meridian</h1>
            <p>By the time the first pale blue light crested the eastern ridge, the mystery of the northern signal was finally clear.</p>
            <p>It was not a warning from an abandoned lighthouse, but an automated synchronization chime from the deep-sea relay station.</p>
            <p>Elena brewed a cup of roasted chicory coffee and stepped out onto the windswept observation balcony.</p>
            <p>Below her, fishing boats raised their canvas sails as the harbor bell rang six times across the calm bay.</p>
            <p>She bookmarked the final page of her logbook, knowing the next voyage would begin before the tide turned.</p>
          </body>
        </html>
        """

        try addEntry(to: archive, path: "OEBPS/chapter1.xhtml", data: Data(chapter1XHTML.utf8))
        try addEntry(to: archive, path: "OEBPS/chapter2.xhtml", data: Data(chapter2XHTML.utf8))
        try addEntry(to: archive, path: "OEBPS/chapter3.xhtml", data: Data(chapter3XHTML.utf8))

        return epubURL
    }

    private static func addEntry(
        to archive: Archive,
        path: String,
        data: Data,
        compressionMethod: CompressionMethod = .deflate
    ) throws {
        try archive.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count),
            compressionMethod: compressionMethod
        ) { position, size in
            let start = Int(position)
            let end = min(data.count, start + size)
            return data.subdata(in: start..<end)
        }
    }

    private static func renderSampleCoverPNG() -> Data? {
        let size = CGSize(width: 600, height: 900)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            let cgContext = context.cgContext
            let colors = [
                UIColor(red: 0.08, green: 0.14, blue: 0.32, alpha: 1.0).cgColor,
                UIColor(red: 0.19, green: 0.35, blue: 0.58, alpha: 1.0).cgColor,
                UIColor(red: 0.85, green: 0.52, blue: 0.34, alpha: 1.0).cgColor
            ] as CFArray
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0.0, 0.58, 1.0]) {
                cgContext.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: 0, y: 0),
                    end: CGPoint(x: size.width, y: size.height),
                    options: []
                )
            }

            // Decorative observatory dome arcs
            UIColor.white.withAlphaComponent(0.18).setStroke()
            for radius in stride(from: 110.0, through: 290.0, by: 45.0) {
                let path = UIBezierPath(
                    arcCenter: CGPoint(x: size.width / 2, y: size.height * 0.44),
                    radius: radius,
                    startAngle: 0,
                    endAngle: .pi * 2,
                    clockwise: true
                )
                path.lineWidth = 2.5
                path.stroke()
            }

            // Title & Author typography
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center

            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 46, weight: .bold),
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph
            ]
            let subtitleAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 24, weight: .medium),
                .foregroundColor: UIColor.white.withAlphaComponent(0.85),
                .paragraphStyle: paragraph
            ]

            let titleString = "THE GLASS\nOBSERVATORY"
            titleString.draw(in: CGRect(x: 40, y: 140, width: size.width - 80, height: 150), withAttributes: titleAttrs)

            let authorString = "CLARA VANCE"
            authorString.draw(in: CGRect(x: 40, y: size.height - 130, width: size.width - 80, height: 50), withAttributes: subtitleAttrs)
        }
        return image.pngData()
    }
}
