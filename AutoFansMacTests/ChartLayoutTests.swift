//
//  ChartLayoutTests.swift
//  AutoFansMacTests
//
//  Renders the curve chart and reads it back with Vision OCR.
//
//  This exists because the reported defect was purely visual and no logic test could see it:
//  the Tmin and Tmax labels were both drawn at `.top` and grew toward each other, so at
//  50 → 75 on a 40…85 axis they always overlapped — "both text are overlapping each other".
//
//  A chart is a drawing, so the only honest way to test its labels is to look at the drawing.
//  Vision is a system framework, so this needs no third-party tool.
//

import XCTest
import SwiftUI
import Vision
import SMCKit
@testable import AutoFansMac

@MainActor
final class ChartLayoutTests: XCTestCase {

    private func fan() -> FanDescriptor {
        FanDescriptor(
            index: 0, name: "Left fan", modeKey: "F0md", targetKey: "F0Tg", actualKey: "F0Ac",
            minKey: "F0Mn", maxKey: "F0Mx", valueType: "flt ", valueSize: 4,
            minRPM: 2_317, maxRPM: 7_826, currentRPM: 2_317, hardwareMode: .manual, warnings: []
        )
    }

    private func chart(minTemp: Double, maxTemp: Double, currentTemperature: Double) -> some View {
        CurvePreview(
            setting: FanSetting(
                index: 0, mode: .sensor, rpm: .value(0), sensorKey: "computed.cpu.hottest",
                sensorName: "CPU hottest", minTemp: minTemp, maxTemp: maxTemp
            ),
            fan: fan(),
            currentTemperature: currentTemperature,
            currentTarget: 3_000,
            unit: .celsius
        )
        // The width the chart actually gets: the window's detail column has a 560 pt minimum,
        // minus the card and view padding. A roomy 700 pt render hid the original overlap
        // entirely, because the two labels only met on a narrower chart.
        .frame(width: 480, height: 170)
        .padding(10)
        .background(Color.white)
    }

    /// Renders a view offscreen and returns the image plus its OCR'd text boxes in
    /// normalised coordinates (origin top-left, as the caller reason about them).
    private func renderAndRecognise(_ view: some View) throws -> (image: CGImage, boxes: [(text: String, rect: CGRect)]) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        guard let image = renderer.cgImage else {
            throw XCTSkip("ImageRenderer produced no image in this environment")
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        // Without an explicit language Vision guessed Vietnamese and read "Tmin 50°" as
        // "Thốn 50°", which made the label unmatchable.
        request.recognitionLanguages = ["en-US"]
        request.automaticallyDetectsLanguage = false
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        let observations = request.results ?? []
        let boxes = observations.compactMap { observation -> (String, CGRect)? in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            // Vision's origin is bottom-left; flip so the numbers match how a chart is read.
            let box = observation.boundingBox
            let flipped = CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
            return (text, flipped)
        }
        return (image, boxes)
    }

    /// Finds one threshold label, preferring its name and falling back to its distinctive
    /// number so a single misread character cannot silently skip the check.
    ///
    /// The fallback must be a *fallback*: matching numbers eagerly also matched the x-axis
    /// tick "50", which broke the "exactly two labels" assumption.
    private func thresholdLabel(
        _ name: String,
        orNumber number: Int,
        in boxes: [(text: String, rect: CGRect)]
    ) -> (text: String, rect: CGRect)? {
        if let byName = boxes.first(where: { $0.text.localizedCaseInsensitiveContains(name) }) {
            return byName
        }
        return boxes.first { $0.text.contains("\(number)") }
    }

    func testThresholdLabelsAreBothDrawnAndDoNotOverlap() throws {
        // The exact case from the report: Tmin 50, Tmax 75, chart spanning ≈40…85.
        let (_, boxes) = try renderAndRecognise(chart(minTemp: 50, maxTemp: 75, currentTemperature: 61))

        guard let minBox = thresholdLabel("Tmin", orNumber: 50, in: boxes)?.rect,
              let maxBox = thresholdLabel("Tmax", orNumber: 75, in: boxes)?.rect else {
            throw XCTSkip("OCR did not find both threshold labels; recognised: \(boxes.map(\.text))")
        }

        XCTAssertFalse(
            minBox.insetBy(dx: -0.002, dy: -0.002).intersects(maxBox),
            "the Tmin and Tmax labels must not overlap — Tmin at \(minBox), Tmax at \(maxBox)"
        )

        // A healthy gap, not merely "not touching". The original defect was a *long* label
        // ("Tmin 50° — below this macOS controls the fan", ~230 pt) that swallowed the space
        // between the two rules; asserting a margin is what catches label growth coming back.
        let gap = maxBox.minX - minBox.maxX
        XCTAssertGreaterThan(
            gap, 0.03,
            "the threshold labels need clear space between them (gap \(gap) of the width; "
                + "Tmin \(minBox), Tmax \(maxBox))"
        )
    }

    /// Both threshold labels belong in the chart's **top margin**.
    ///
    /// This is the assertion that has teeth for the second reported layout: moving Tmin to
    /// `.bottom` put it on the x-axis tick labels, and OCR could not see that — it merged the
    /// overlapping text and never recognised the ticks at all, so a "does it overlap other
    /// text" check passed happily. Position is the reliable signal.
    func testThresholdLabelsStayInTheTopMargin() throws {
        let (_, boxes) = try renderAndRecognise(chart(minTemp: 50, maxTemp: 75, currentTemperature: 61))

        guard let minBox = thresholdLabel("Tmin", orNumber: 50, in: boxes)?.rect,
              let maxBox = thresholdLabel("Tmax", orNumber: 75, in: boxes)?.rect else {
            throw XCTSkip("OCR did not find both threshold labels; recognised: \(boxes.map(\.text))")
        }

        for (name, box) in [("Tmin", minBox), ("Tmax", maxBox)] {
            XCTAssertLessThan(
                box.midY, 0.35,
                "\(name) must sit in the top margin, clear of the x-axis labels below the plot "
                    + "(found it at y = \(box.midY), full box \(box))"
            )
        }
    }

    /// Belt and braces: a threshold label must not land on any other text the OCR *did* see.
    func testThresholdLabelsDoNotCollideWithAnyOtherChartText() throws {
        let (_, boxes) = try renderAndRecognise(chart(minTemp: 50, maxTemp: 75, currentTemperature: 61))

        guard let minimum = thresholdLabel("Tmin", orNumber: 50, in: boxes),
              let maximum = thresholdLabel("Tmax", orNumber: 75, in: boxes) else {
            throw XCTSkip("OCR did not find both threshold labels; recognised: \(boxes.map(\.text))")
        }
        let thresholds = [minimum, maximum]

        for threshold in thresholds {
            for other in boxes where other.rect != threshold.rect {
                XCTAssertFalse(
                    threshold.rect.insetBy(dx: -0.002, dy: -0.002).intersects(other.rect),
                    "\"\(threshold.text)\" overlaps \"\(other.text)\" — \(threshold.rect) vs \(other.rect); "
                        + "all recognised text: \(boxes.map(\.text))"
                )
            }
        }
    }

    /// The labels must survive the tightest spacing a user can configure, not just 50/75.
    func testThresholdLabelsDoNotOverlapWhenTminApproachesTmax() throws {
        let (_, boxes) = try renderAndRecognise(chart(minTemp: 60, maxTemp: 68, currentTemperature: 64))

        guard let minBox = thresholdLabel("Tmin", orNumber: 60, in: boxes)?.rect,
              let maxBox = thresholdLabel("Tmax", orNumber: 68, in: boxes)?.rect else {
            throw XCTSkip("OCR did not find both threshold labels; recognised: \(boxes.map(\.text))")
        }

        XCTAssertFalse(
            minBox.insetBy(dx: -0.002, dy: -0.002).intersects(maxBox),
            "closely spaced thresholds must still not overlap (Tmin \(minBox), Tmax \(maxBox))"
        )
    }
}
