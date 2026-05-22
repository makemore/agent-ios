import Foundation
import Vision
import AppKit

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: ocr_image <path>\n".data(using: .utf8)!)
    exit(2)
}
let path = CommandLine.arguments[1]
guard let image = NSImage(contentsOfFile: path),
      let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let cg = bitmap.cgImage else {
    FileHandle.standardError.write("failed to load image\n".data(using: .utf8)!)
    exit(1)
}

let req = VNRecognizeTextRequest { request, error in
    guard let observations = request.results as? [VNRecognizedTextObservation] else { return }
    let sorted = observations.sorted { a, b in
        if abs(a.boundingBox.midY - b.boundingBox.midY) > 0.01 {
            return a.boundingBox.midY > b.boundingBox.midY
        }
        return a.boundingBox.minX < b.boundingBox.minX
    }
    for obs in sorted {
        guard let cand = obs.topCandidates(1).first else { continue }
        let bb = obs.boundingBox
        let yTop = 1.0 - bb.maxY
        let line = String(
            format: "[y=%.3f x=%.3f w=%.3f h=%.3f conf=%.2f] %@",
            yTop, bb.minX, bb.width, bb.height, cand.confidence, cand.string
        )
        print(line)
    }
}
req.recognitionLevel = .accurate
req.usesLanguageCorrection = true
req.recognitionLanguages = ["en-US"]

let handler = VNImageRequestHandler(cgImage: cg, options: [:])
try handler.perform([req])
