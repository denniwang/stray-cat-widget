import AppKit
import AVFoundation
import CoreAudio
import CoreImage
import ImageIO
import ServiceManagement
import UniformTypeIdentifiers
import Vision

// MARK: - Settings

/// User-adjustable settings, persisted in UserDefaults.
enum Settings {
    private static let d = UserDefaults.standard

#if DEMO_CAPTURE
    /// Temporary switch for capturing the cat and break overlays in demo recordings.
    static var demoMode = false
    /// Use a bundled cat GIF and short break sequence for deterministic recordings.
    static var demoSequenceMode = false
    static var overlaySharingType: NSWindow.SharingType { demoMode ? .readOnly : .none }
#else
    static var overlaySharingType: NSWindow.SharingType { .none }
#endif

    static func register() {
        d.register(defaults: [
            "breaksEnabled": true, "breakMinutes": 60, "breakSeconds": 15,
            "snoozeMinutes": 5, "dimPercent": 82,
            "catEnabled": true, "catEveryMinutes": 8, "catStaySeconds": 6,
            "popupOnlineGifs": false, "popupOnlineURL": "",
            "showBreakMessage": true, "holdDuringShare": true, "holdDuringCalls": true,
            "requireAwayForBreak": false,
            "warnSeconds": 15, "onlineGifs": true, "onlineURL": "cats",
        ])
    }

    static var popupOnlineGifs: Bool { get { d.bool(forKey: "popupOnlineGifs") } set { d.set(newValue, forKey: "popupOnlineGifs") } }
    static var popupOnlineURL: String { get { d.string(forKey: "popupOnlineURL") ?? "" } set { d.set(newValue, forKey: "popupOnlineURL") } }
    static var holdDuringShare: Bool { get { d.bool(forKey: "holdDuringShare") } set { d.set(newValue, forKey: "holdDuringShare") } }
    static var holdDuringCalls: Bool { get { d.bool(forKey: "holdDuringCalls") } set { d.set(newValue, forKey: "holdDuringCalls") } }
    static var warnSeconds: Int { get { d.integer(forKey: "warnSeconds") } set { d.set(newValue, forKey: "warnSeconds") } }
    static var onlineGifs: Bool { get { d.bool(forKey: "onlineGifs") } set { d.set(newValue, forKey: "onlineGifs") } }
    static var onlineURL: String { get { d.string(forKey: "onlineURL") ?? "" } set { d.set(newValue, forKey: "onlineURL") } }
    static var showBreakMessage: Bool { get { d.bool(forKey: "showBreakMessage") } set { d.set(newValue, forKey: "showBreakMessage") } }
    static var requireAwayForBreak: Bool { get { d.bool(forKey: "requireAwayForBreak") } set { d.set(newValue, forKey: "requireAwayForBreak") } }

    static func shouldShowOnboarding() -> Bool {
        let key = "hasCompletedOnboarding"
        if d.bool(forKey: key) { return false }

        // Existing installs with saved preferences or custom pictures skip the welcome window.
        let domain = Bundle.main.bundleIdentifier.flatMap { d.persistentDomain(forName: $0) } ?? [:]
        let priorKeys = [
            "breaksEnabled", "breakMinutes", "breakSeconds", "snoozeMinutes", "dimPercent",
            "catEnabled", "catEveryMinutes", "catStaySeconds", "showBreakMessage",
            "holdDuringShare", "holdDuringCalls", "warnSeconds", "onlineGifs", "onlineURL",
        ]
        let hasSavedPreferences = priorKeys.contains { domain[$0] != nil }
        let hasCustomImages = !galleryFiles(for: .popup).isEmpty || !galleryFiles(for: .breakScreen).isEmpty
        if hasSavedPreferences || hasCustomImages || SMAppService.mainApp.status == .enabled {
            d.set(true, forKey: key)
            return false
        }
        return true
    }

    static func markOnboardingComplete() { d.set(true, forKey: "hasCompletedOnboarding") }

    /// Which place a gallery is used.
    enum Slot: String {
        case popup, breakScreen
        var legacyKey: String { "\(rawValue)ImagePath" }
    }

    private static var imageRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("StrayCat", isDirectory: true)
    }

    private static func folder(for slot: Slot) -> URL {
        imageRoot.appendingPathComponent(slot.rawValue, isDirectory: true)
    }

    /// Files in the slot's gallery, in a stable order.
    static func galleryFiles(for slot: Slot) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder(for: slot), includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return files.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static var lastShown: [Slot: URL] = [:]

    /// A random image from the slot's gallery (never the same one twice in a row when there is a choice),
    /// or nil to use the drawn cat.
    static func randomImage(for slot: Slot) -> AnimatedImage? {
        var files = galleryFiles(for: slot)
        if files.count > 1, let last = lastShown[slot] { files.removeAll { $0 == last } }
        while let pick = files.randomElement() {
            if let image = AnimatedImage(url: pick) {
                lastShown[slot] = pick
                return image
            }
            files.removeAll { $0 == pick }  // unreadable file: try another
        }
        return nil
    }

    /// Copies the chosen files into Application Support so they survive the originals being moved.
    static func addImages(_ urls: [URL], to slot: Slot) throws {
        let dir = folder(for: slot)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var tooBig: [String] = []
        for url in urls {
            let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            if bytes > maxImageBytes { tooBig.append(url.lastPathComponent); continue }
            let dest = dir.appendingPathComponent("\(UUID().uuidString.prefix(8))-\(url.lastPathComponent)")
            try FileManager.default.copyItem(at: url, to: dest)
        }
        if !tooBig.isEmpty {
            throw NSError(domain: "StrayCat", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Skipped files over 30 MB: " + tooBig.joined(separator: ", ")])
        }
    }

    static let maxImageBytes = 30 * 1024 * 1024

    static func removeImage(_ url: URL) { try? FileManager.default.removeItem(at: url) }

    static func clearImages(for slot: Slot) {
        try? FileManager.default.removeItem(at: folder(for: slot))
    }

    /// Moves the single image chosen in the previous version into the gallery.
    static func migrateLegacyImages() {
        for slot in [Slot.popup, .breakScreen] {
            guard let path = d.string(forKey: slot.legacyKey) else { continue }
            d.removeObject(forKey: slot.legacyKey)
            if FileManager.default.fileExists(atPath: path) { try? addImages([URL(fileURLWithPath: path)], to: slot) }
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    static var breaksEnabled: Bool { get { d.bool(forKey: "breaksEnabled") } set { d.set(newValue, forKey: "breaksEnabled") } }
    static var breakMinutes: Int { get { d.integer(forKey: "breakMinutes") } set { d.set(newValue, forKey: "breakMinutes") } }
    static var breakSeconds: Int { get { d.integer(forKey: "breakSeconds") } set { d.set(newValue, forKey: "breakSeconds") } }
    static var snoozeMinutes: Int { get { d.integer(forKey: "snoozeMinutes") } set { d.set(newValue, forKey: "snoozeMinutes") } }
    static var dimPercent: Int { get { d.integer(forKey: "dimPercent") } set { d.set(newValue, forKey: "dimPercent") } }
    static var catEnabled: Bool { get { d.bool(forKey: "catEnabled") } set { d.set(newValue, forKey: "catEnabled") } }
    static var catEveryMinutes: Int { get { d.integer(forKey: "catEveryMinutes") } set { d.set(newValue, forKey: "catEveryMinutes") } }
    static var catStaySeconds: Int { get { d.integer(forKey: "catStaySeconds") } set { d.set(newValue, forKey: "catStaySeconds") } }

    /// Time between break reminders.
    static var breakInterval: TimeInterval { TimeInterval(breakMinutes * 60) }
    /// Random delay between cat visits (±50% around the chosen average).
    static var peekDelayRange: ClosedRange<TimeInterval> {
        let m = TimeInterval(catEveryMinutes * 60)
        return (m * 0.5)...(m * 1.5)
    }
    /// How long the cat lingers once it has popped in (±25%).
    static var peekStayRange: ClosedRange<TimeInterval> {
        let s = TimeInterval(catStaySeconds)
        return (s * 0.75)...(s * 1.25)
    }
}

// MARK: - Animation helper

/// Runs `update` with an eased 0...1 value over `duration` seconds.
@discardableResult
func tween(duration: TimeInterval, easeOut: Bool = true,
           update: @escaping (CGFloat) -> Void, done: @escaping () -> Void = {}) -> Timer {
    let start = Date()
    return Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { timer in
        let raw = min(1, CGFloat(Date().timeIntervalSince(start) / duration))
        let t = easeOut ? 1 - pow(1 - raw, 3) : raw * raw * (3 - 2 * raw)
        update(t)
        if raw >= 1 {
            timer.invalidate()
            done()
        }
    }
}

// MARK: - Animated images

/// A decoded still or animated image (GIF, APNG, or any format ImageIO reads).
/// Frames are downscaled on load so long GIFs stay light on memory.
final class AnimatedImage {
    static let maxFrames = 150
    private let frames: [CGImage]
    private let delays: [TimeInterval]
    private let total: TimeInterval
    let size: CGSize
    let fileURL: URL

    init?(url: URL) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(src)
        guard count > 0 else { return nil }
        let maxPixel = count > 60 ? 360 : 640
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        var frames: [CGImage] = []
        var delays: [TimeInterval] = []
        for i in 0..<min(count, AnimatedImage.maxFrames) {
            guard let img = CGImageSourceCreateThumbnailAtIndex(src, i, options as CFDictionary) else { continue }
            frames.append(img)
            delays.append(AnimatedImage.delay(src, i))
        }
        guard let first = frames.first else { return nil }
        self.frames = frames
        self.delays = delays
        self.total = delays.reduce(0, +)
        self.size = CGSize(width: first.width, height: first.height)
        self.fileURL = url
    }

    private static func delay(_ src: CGImageSource, _ index: Int) -> TimeInterval {
        let props = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any]
        let dicts = [props?[kCGImagePropertyGIFDictionary], props?[kCGImagePropertyPNGDictionary]]
            .compactMap { $0 as? [CFString: Any] }
        let keys = [kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime,
                    kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime]
        for d in dicts {
            for key in keys {
                if let v = d[key] as? Double, v > 0.011 { return v }
            }
        }
        // Browsers treat missing or ~0 delays as 100 ms.
        return 0.1
    }

    /// The frame to show `time` seconds after the animation started (loops forever).
    func frame(at time: TimeInterval) -> CGImage {
        guard frames.count > 1, total > 0 else { return frames[0] }
        var t = time.truncatingRemainder(dividingBy: total)
        for (i, d) in delays.enumerated() {
            if t < d { return frames[i] }
            t -= d
        }
        return frames[frames.count - 1]
    }
}

// MARK: - Online GIFs

/// Picks a random GIF from a web page you choose, e.g. a Tenor search page. Tenor's API is closed to new
/// users, so this reads the page's HTML for GIF links instead. It will stop working if the site changes.
enum OnlineGIF {
    private static var cache: [URL: (date: Date, urls: [URL])] = [:]
    private static let maxBytes = 8 * 1024 * 1024
    private static let maxCachedGIFs = 10
    private static let diskCacheLock = NSLock()
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    /// GIFs that have loaded successfully are kept in Application Support for offline use.
    private static var diskCacheDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StrayCat", isDirectory: true)
            .appendingPathComponent("OnlineGIFCache", isDirectory: true)
    }

    /// Accepts a full URL, or plain words (turned into a Tenor search such as .../search/aura-gifs).
    static func resolve(_ input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let lower = text.lowercased()
        if lower.hasPrefix("http://") { text = "https://" + text.dropFirst("http://".count) }
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            guard let url = URL(string: text), url.host != nil else { return nil }
            return url
        }
        let slug = lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: "-")
        guard !slug.isEmpty,
              let encoded = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "https://tenor.com/search/\(encoded)-gifs")
    }

    static func random(from input: String, completion: @escaping (AnimatedImage?) -> Void) {
        guard let page = resolve(input) else { completion(nil); return }
        if page.pathExtension.lowercased() == "gif" { download([page], completion); return }
        if let hit = cache[page], Date().timeIntervalSince(hit.date) < 600 {
            download(hit.urls.shuffled(), completion)
            return
        }
        var request = URLRequest(url: page)
        request.timeoutInterval = 8
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            guard (response as? HTTPURLResponse)?.statusCode == 200, let data, data.count < 6_000_000 else {
                DispatchQueue.main.async { completeWithCachedGIF(completion) }
                return
            }
            let urls = gifLinks(in: String(decoding: data, as: UTF8.self))
            DispatchQueue.main.async {
                guard !urls.isEmpty else { completeWithCachedGIF(completion); return }
                cache[page] = (Date(), urls)
                download(urls.shuffled(), completion)
            }
        }.resume()
    }

    /// Absolute https links to .gif files found in the page, without duplicates.
    static func gifLinks(in html: String) -> [URL] {
        let text = html.replacingOccurrences(of: "\\/", with: "/")
        guard let regex = try? NSRegularExpression(pattern: #"https://[^"'\s\\<>()]+?\.gif"#, options: [.caseInsensitive]) else { return [] }
        var seen = Set<String>()
        var out: [URL] = []
        for m in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let r = Range(m.range, in: text) else { continue }
            let link = String(text[r])
            if seen.insert(link).inserted, let url = URL(string: link) { out.append(url) }
        }
        return out
    }

    /// Tries up to three candidates, skipping any that fail, are too large, or won't decode.
    private static func download(_ candidates: [URL], _ completion: @escaping (AnimatedImage?) -> Void) {
        var queue = Array(candidates.prefix(3))
        func next() {
            guard !queue.isEmpty else { completeWithCachedGIF(completion); return }
            var request = URLRequest(url: queue.removeFirst())
            request.timeoutInterval = 12
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            URLSession.shared.dataTask(with: request) { data, response, _ in
                var image: AnimatedImage?
                if (response as? HTTPURLResponse)?.statusCode == 200, let data, data.count <= maxBytes {
                    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("straycat-\(UUID().uuidString).gif")
                    if (try? data.write(to: tmp)) != nil {
                        image = AnimatedImage(url: tmp)
                        if image != nil {
                            if let cachedURL = storeInDiskCache(data), let cachedImage = AnimatedImage(url: cachedURL) {
                                image = cachedImage
                                try? FileManager.default.removeItem(at: tmp)
                            }
                            // Keep the temporary source if the persistent cache was unavailable so
                            // the user can still copy the GIF file from the preview.
                        } else {
                            try? FileManager.default.removeItem(at: tmp)
                        }
                    }
                }
                DispatchQueue.main.async { if let image { completion(image) } else { next() } }
            }.resume()
        }
        next()
    }

    /// Returns a random readable GIF from the last ten successful downloads.
    private static func completeWithCachedGIF(_ completion: @escaping (AnimatedImage?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let files = cachedGIFFiles().shuffled()
            var image: AnimatedImage?
            for file in files {
                if let decoded = AnimatedImage(url: file) {
                    image = decoded
                    break
                }
                try? FileManager.default.removeItem(at: file)
            }
            DispatchQueue.main.async { completion(image) }
        }
    }

    /// Adds a validated download and prunes the oldest files to keep the disk cache bounded.
    private static func storeInDiskCache(_ data: Data) -> URL? {
        diskCacheLock.lock()
        defer { diskCacheLock.unlock() }

        let directory = diskCacheDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let timestamp = Int(Date().timeIntervalSince1970 * 1_000)
            let destination = directory.appendingPathComponent("\(timestamp)-\(UUID().uuidString).gif")
            try data.write(to: destination, options: .atomic)

            let files = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
            for oldFile in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).prefix(max(0, files.count - maxCachedGIFs)) {
                try? FileManager.default.removeItem(at: oldFile)
            }
            return destination
        } catch {
            // Keep the online result usable even if Application Support is unavailable.
            return nil
        }
    }

    private static func cachedGIFFiles() -> [URL] {
        diskCacheLock.lock()
        defer { diskCacheLock.unlock() }
        return (try? FileManager.default.contentsOfDirectory(
            at: diskCacheDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles))?
            .filter { $0.pathExtension.lowercased() == "gif" } ?? []
    }
}

// MARK: - Screen share guard

/// Best-effort detection of "someone can see my screen right now". macOS has no public API for this,
/// so it combines signals: Zoom's share helper process, and any app holding the microphone (calls).
enum ShareGuard {
    static func isSharing() -> Bool {
        if Settings.holdDuringShare && zoomIsSharing() { return true }
        if Settings.holdDuringCalls && microphoneInUse() { return true }
        return false
    }

    /// Zoom starts a "CptHost" helper only while it is sharing the screen.
    private static func zoomIsSharing() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axco", "comm"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let names = String(decoding: data, as: UTF8.self).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        return names.contains("CptHost")
    }

    /// True when any process is capturing from the default input device.
    static func microphoneInUse() -> Bool {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr,
              device != 0 else { return false }
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        addr.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &running) == noErr && running != 0
    }
}

// MARK: - Cat

/// Draws a sitting stray cat. `peek` (0...1) controls how far it has risen into view
/// from the bottom edge of the view, so the hosting window never has to leave the screen.
final class CatView: NSView {
    var peek: CGFloat = 0 { didSet { needsDisplay = true } }
    var facingLeft = false
    var onClick: (() -> Void)?
    var onImageClick: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?
    /// When set, this is drawn instead of the built-in cat.
    var customImage: AnimatedImage? {
        didSet {
            needsDisplay = true
            if window != nil { updateTrackingAreas() }
        }
    }

    private var animTimer: Timer?
    private let epoch = Date()
    private var hoverDimAlpha: CGFloat = 0
    private var hoverDimFrom: CGFloat = 0
    private var hoverDimTarget: CGFloat = 0
    private var hoverDimStartedAt: TimeInterval?
    private let hoverDimDuration: TimeInterval = 0.2

    /// Coat colors (fur, stripes, light patches) for the drawn cat; one is picked per appearance.
    private static let coats: [(fur: NSColor, stripe: NSColor, light: NSColor)] = {
        func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor { NSColor(calibratedRed: r, green: g, blue: b, alpha: 1) }
        return [
            (c(0.52, 0.47, 0.43), c(0.28, 0.25, 0.23), c(0.80, 0.76, 0.70)),  // grey tabby
            (c(0.86, 0.52, 0.22), c(0.62, 0.32, 0.12), c(0.96, 0.84, 0.68)),  // ginger
            (c(0.17, 0.16, 0.18), c(0.08, 0.08, 0.09), c(0.42, 0.40, 0.44)),  // black
            (c(0.92, 0.90, 0.86), c(0.66, 0.62, 0.58), c(1.00, 0.98, 0.95)),  // white
            (c(0.66, 0.50, 0.34), c(0.34, 0.22, 0.14), c(0.90, 0.80, 0.66)),  // brown tabby
            (c(0.62, 0.64, 0.70), c(0.38, 0.40, 0.46), c(0.86, 0.87, 0.91)),  // blue-grey
        ]
    }()
    private let coat = CatView.coats.randomElement()!
    private var fur: NSColor { coat.fur }
    private var stripe: NSColor { coat.stripe }
    private var light: NSColor { coat.light }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        animTimer?.invalidate()
        guard window != nil else { return }
        animTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.updateHoverDimAnimation()
            self?.needsDisplay = true
        }
    }

    deinit { animTimer?.invalidate() }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let onImageClick, displayedImageRect()?.contains(point) == true {
            onImageClick()
        } else {
            onClick?()
        }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: displayedImageRect() ?? bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .assumeInside],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }

    func setGIFHovered(_ isHovered: Bool) {
        hoverDimFrom = hoverDimAlpha
        hoverDimTarget = isHovered ? 0.28 : 0
        hoverDimStartedAt = Date().timeIntervalSinceReferenceDate
        if window == nil {
            hoverDimAlpha = hoverDimTarget
            hoverDimStartedAt = nil
        }
        needsDisplay = true
    }

    func displayedImageRect(for image: AnimatedImage? = nil) -> NSRect? {
        guard let image = image ?? customImage,
              image.size.width > 0, image.size.height > 0,
              bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        return NSRect(x: (bounds.width - size.width) / 2,
                      y: -(1 - peek) * bounds.height,
                      width: size.width, height: size.height)
    }

    private func updateHoverDimAnimation() {
        guard let startedAt = hoverDimStartedAt else { return }
        let progress = CGFloat(min(1, (Date().timeIntervalSinceReferenceDate - startedAt) / hoverDimDuration))
        let easedProgress = progress * progress * (3 - 2 * progress)
        hoverDimAlpha = hoverDimFrom + (hoverDimTarget - hoverDimFrom) * easedProgress
        if progress >= 1 {
            hoverDimAlpha = hoverDimTarget
            hoverDimStartedAt = nil
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if let image = customImage {
            // Aspect-fit, resting on the bottom edge; not mirrored so text in an image stays readable.
            guard let rect = displayedImageRect(for: image) else { return }
            ctx.interpolationQuality = .high
            ctx.draw(image.frame(at: Date().timeIntervalSince(epoch)), in: rect)
            if hoverDimAlpha > 0 {
                ctx.setFillColor(NSColor(calibratedWhite: 0.58, alpha: hoverDimAlpha).cgColor)
                ctx.fill(rect)
            }
            return
        }
        let s = min(bounds.width, bounds.height) / 160
        ctx.saveGState()
        ctx.translateBy(x: facingLeft ? bounds.width : 0, y: -(1 - peek) * bounds.height)
        if facingLeft { ctx.scaleBy(x: -1, y: 1) }
        ctx.scaleBy(x: s, y: s)
        drawCat()
        ctx.restoreGState()
    }

    private func drawCat() {
        let t = Date().timeIntervalSince(epoch)
        let wag = CGFloat(sin(t * 2.2)) * 9
        let blinking = fmod(t, 3.4) < 0.14

        // Tail
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: 116, y: 12))
        tail.curve(to: NSPoint(x: 150 + wag, y: 70),
                   controlPoint1: NSPoint(x: 150, y: 8),
                   controlPoint2: NSPoint(x: 160 + wag, y: 40))
        tail.lineWidth = 10
        tail.lineCapStyle = .round
        fur.setStroke()
        tail.stroke()

        // Body
        fur.setFill()
        NSBezierPath(ovalIn: NSRect(x: 33, y: -14, width: 94, height: 92)).fill()
        // Chest patch
        light.setFill()
        NSBezierPath(ovalIn: NSRect(x: 62, y: 8, width: 36, height: 50)).fill()
        // Front paws
        light.setFill()
        NSBezierPath(ovalIn: NSRect(x: 52, y: -4, width: 22, height: 26)).fill()
        NSBezierPath(ovalIn: NSRect(x: 86, y: -4, width: 22, height: 26)).fill()

        // Ears (left one has a torn notch, like a proper stray)
        fur.setFill()
        let leftEar = NSBezierPath()
        leftEar.move(to: NSPoint(x: 42, y: 108))
        leftEar.line(to: NSPoint(x: 44, y: 150))
        leftEar.line(to: NSPoint(x: 55, y: 143))
        leftEar.line(to: NSPoint(x: 60, y: 149))
        leftEar.line(to: NSPoint(x: 74, y: 128))
        leftEar.close()
        leftEar.fill()
        let rightEar = NSBezierPath()
        rightEar.move(to: NSPoint(x: 118, y: 108))
        rightEar.line(to: NSPoint(x: 116, y: 150))
        rightEar.line(to: NSPoint(x: 86, y: 128))
        rightEar.close()
        rightEar.fill()
        NSColor(calibratedRed: 0.85, green: 0.6, blue: 0.62, alpha: 1).setFill()
        let innerR = NSBezierPath()
        innerR.move(to: NSPoint(x: 112, y: 116))
        innerR.line(to: NSPoint(x: 111, y: 140))
        innerR.line(to: NSPoint(x: 94, y: 126))
        innerR.close()
        innerR.fill()

        // Head
        fur.setFill()
        NSBezierPath(ovalIn: NSRect(x: 38, y: 68, width: 84, height: 70)).fill()

        // Forehead stripes
        stripe.setStroke()
        for dx in [-9.0, 0.0, 9.0] {
            let p = NSBezierPath()
            p.move(to: NSPoint(x: 80 + dx, y: 137))
            p.line(to: NSPoint(x: 80 + dx * 0.8, y: 123))
            p.lineWidth = 3.5
            p.lineCapStyle = .round
            p.stroke()
        }

        // Eyes
        for cx in [62.0, 98.0] {
            let h: CGFloat = blinking ? 2 : 17
            let eye = NSRect(x: cx - 9, y: 103 - h / 2, width: 18, height: h)
            NSColor(calibratedRed: 0.86, green: 0.82, blue: 0.2, alpha: 1).setFill()
            NSBezierPath(ovalIn: eye).fill()
            if !blinking {
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: cx - 2, y: 105 - 7.5, width: 4, height: 15)).fill()
            }
        }

        // Nose and mouth
        NSColor(calibratedRed: 0.85, green: 0.5, blue: 0.55, alpha: 1).setFill()
        let nose = NSBezierPath()
        nose.move(to: NSPoint(x: 75, y: 92))
        nose.line(to: NSPoint(x: 85, y: 92))
        nose.line(to: NSPoint(x: 80, y: 86))
        nose.close()
        nose.fill()
        stripe.setStroke()
        let mouth = NSBezierPath()
        mouth.move(to: NSPoint(x: 80, y: 86))
        mouth.line(to: NSPoint(x: 80, y: 82))
        mouth.move(to: NSPoint(x: 72, y: 80))
        mouth.curve(to: NSPoint(x: 80, y: 82), controlPoint1: NSPoint(x: 75, y: 77), controlPoint2: NSPoint(x: 78, y: 77))
        mouth.curve(to: NSPoint(x: 88, y: 80), controlPoint1: NSPoint(x: 82, y: 77), controlPoint2: NSPoint(x: 85, y: 77))
        mouth.lineWidth = 1.5
        mouth.stroke()

        // Whiskers
        light.setStroke()
        let whiskers = NSBezierPath()
        for dy in [-3.0, 3.0] {
            whiskers.move(to: NSPoint(x: 64, y: 88 + dy)); whiskers.line(to: NSPoint(x: 34, y: 90 + dy * 2.5))
            whiskers.move(to: NSPoint(x: 96, y: 88 + dy)); whiskers.line(to: NSPoint(x: 126, y: 90 + dy * 2.5))
        }
        whiskers.lineWidth = 1.2
        whiskers.stroke()
    }
}

// MARK: - Peeking cat

/// A compact speech bubble that points toward the cat and keeps its message readable on any wallpaper.
final class CatSpeechBubbleView: NSView {
    let tailOnRight: Bool
    let label: NSTextField
    var onClick: (() -> Void)?
    private static let textFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    private static let maxTextWidth: CGFloat = 164

    static func fittingSize(for text: String) -> NSSize {
        let textBounds = (text as NSString).boundingRect(
            with: NSSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: textFont]
        )
        let textWidth = min(maxTextWidth, max(1, ceil(textBounds.width)))
        let textHeight = max(16, ceil(textBounds.height))
        return NSSize(width: textWidth + 40, height: textHeight + 20)
    }

    init(frame: NSRect, text: String, tailOnRight: Bool) {
        self.tailOnRight = tailOnRight
        label = NSTextField(wrappingLabelWithString: text)
        super.init(frame: frame)
        wantsLayer = true

        let textSize = Self.fittingSize(for: text)
        let bodyX: CGFloat = tailOnRight ? 0 : 12
        label.font = Self.textFont
        label.textColor = .white
        label.alignment = .center
        label.maximumNumberOfLines = 3
        label.lineBreakMode = .byWordWrapping
        label.frame = NSRect(x: bodyX + 14,
                             y: (frame.height - textSize.height) / 2,
                             width: frame.width - 40,
                             height: textSize.height)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let tailWidth: CGFloat = 12
        let bodyRect = NSRect(x: tailOnRight ? 0 : tailWidth,
                              y: 0,
                              width: bounds.width - tailWidth,
                              height: bounds.height)
        let radius: CGFloat = 18
        let tailY = bodyRect.midY
        let body = NSBezierPath(roundedRect: bodyRect, xRadius: radius, yRadius: radius)
        NSColor(calibratedWhite: 0.12, alpha: 0.94).setFill()
        body.fill()
        NSColor(calibratedWhite: 1, alpha: 0.12).setStroke()
        body.lineWidth = 1
        body.stroke()

        let tail = NSBezierPath()
        if tailOnRight {
            tail.move(to: NSPoint(x: bodyRect.maxX, y: tailY + 8))
            tail.line(to: NSPoint(x: bounds.maxX, y: tailY))
            tail.line(to: NSPoint(x: bodyRect.maxX, y: tailY - 8))
        } else {
            tail.move(to: NSPoint(x: bodyRect.minX, y: tailY + 8))
            tail.line(to: NSPoint(x: bounds.minX, y: tailY))
            tail.line(to: NSPoint(x: bodyRect.minX, y: tailY - 8))
        }
        tail.close()
        NSColor(calibratedWhite: 0.12, alpha: 0.94).setFill()
        tail.fill()
        NSColor(calibratedWhite: 1, alpha: 0.12).setStroke()
        let tailEdge = NSBezierPath()
        if tailOnRight {
            tailEdge.move(to: NSPoint(x: bodyRect.maxX, y: tailY + 8))
            tailEdge.line(to: NSPoint(x: bounds.maxX, y: tailY))
            tailEdge.line(to: NSPoint(x: bodyRect.maxX, y: tailY - 8))
        } else {
            tailEdge.move(to: NSPoint(x: bodyRect.minX, y: tailY + 8))
            tailEdge.line(to: NSPoint(x: bounds.minX, y: tailY))
            tailEdge.line(to: NSPoint(x: bodyRect.minX, y: tailY - 8))
        }
        tailEdge.lineWidth = 1
        tailEdge.stroke()
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// Hosts the cat and its optional break countdown bubble in one animated corner window.
final class CatPopupContentView: NSView {
    let cat: CatView
    let bubble: CatSpeechBubbleView?
    private let catOnRight: Bool
    private let bubbleBaseFrame: NSRect
    var peek: CGFloat = 0 {
        didSet {
            cat.peek = peek
            guard let bubble else { return }
            let reveal = min(1, max(0, (peek - 0.08) / 0.92))
            let fromCat: CGFloat = catOnRight ? 1 : -1
            bubble.alphaValue = reveal
            bubble.setFrameOrigin(NSPoint(x: bubbleBaseFrame.minX + fromCat * (1 - reveal) * 12,
                                          y: bubbleBaseFrame.minY + (1 - reveal) * 4))
        }
    }

    init(frame: NSRect, image: AnimatedImage?, catOnRight: Bool, message: String?) {
        self.catOnRight = catOnRight
        let catWidth: CGFloat = 170
        let catX = catOnRight ? frame.width - catWidth : 0
        let bubbleX = catOnRight ? 0 : catWidth
        let bubbleSize = message.map(CatSpeechBubbleView.fittingSize(for:)) ?? .zero
        let bubbleFrame = NSRect(x: bubbleX, y: 100 - bubbleSize.height / 2,
                                 width: bubbleSize.width, height: bubbleSize.height)
        bubbleBaseFrame = bubbleFrame
        cat = CatView(frame: NSRect(x: catX, y: 0, width: catWidth, height: catWidth))
        cat.facingLeft = catOnRight
        cat.customImage = image
        if let message {
            bubble = CatSpeechBubbleView(frame: bubbleFrame, text: message, tailOnRight: catOnRight)
        } else {
            bubble = nil
        }
        super.init(frame: frame)
        addSubview(cat)
        if let bubble {
            bubble.alphaValue = 0
            addSubview(bubble)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Shows the cat in a bottom corner, slides it up, waits, and slides it back down.
/// Only one cat exists at a time, every animation can be cancelled, and appearances are rate-limited,
/// so repeated "Call the cat" clicks (or a held key) can't stack, flicker, or corrupt a later cat.
final class CatPeeker {
    private var window: NSWindow?
    private var animation: Timer?
    private var stayWork: DispatchWorkItem?
    private(set) var busy = false
    private var lastEnd = Date.distantPast
    /// Minimum quiet time after a cat leaves before another can appear.
    private let cooldown: TimeInterval = 5

    func peek(previewImage: AnimatedImage? = nil, bypassCooldown: Bool = false,
              stayDuration: TimeInterval? = nil, nextBreak: Date? = nil) {
        #if DEMO_CAPTURE
        let canShowWhileSharing = Settings.demoMode || !ShareGuard.isSharing()
        #else
        let canShowWhileSharing = !ShareGuard.isSharing()
        #endif
        guard !busy, (bypassCooldown || Date().timeIntervalSince(lastEnd) >= cooldown),
              canShowWhileSharing, let screen = NSScreen.main else { return }
        busy = true

        let message: String? = nextBreak.map { deadline in
            let minutes = max(1, Int((deadline.timeIntervalSinceNow / 60).rounded(.up)))
            let unit = minutes == 1 ? "min" : "mins"
            return "You have \(minutes) \(unit) left till a break, meow!"
        }
        let bubbleSize = message.map(CatSpeechBubbleView.fittingSize(for:)) ?? .zero
        let size = message == nil ? NSSize(width: 170, height: 170)
            : NSSize(width: 170 + bubbleSize.width, height: 180)
        let margin: CGFloat = 28
        let onRight = Bool.random()
        let area = screen.visibleFrame
        let x = onRight ? area.maxX - size.width - margin : area.minX + margin
        let rect = NSRect(x: x, y: area.minY, width: size.width, height: size.height)

        let w = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.level = .floating
        w.sharingType = Settings.overlaySharingType
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let image = previewImage ?? Settings.randomImage(for: .popup)
        let content = CatPopupContentView(frame: NSRect(origin: .zero, size: rect.size),
                                         image: image, catOnRight: onRight, message: message)
        let cat = content.cat
        w.contentView = content
        w.orderFrontRegardless()
        window = w

        if previewImage == nil && Settings.popupOnlineGifs {
            OnlineGIF.random(from: Settings.popupOnlineURL) { [weak self, weak cat, weak w] image in
                guard let self, let cat, self.window === w, let image else { return }
                cat.customImage = image
            }
        }

        var leaving = false
        // Slides the cat down from wherever it currently is, then tears everything down.
        let leave = { [weak self, weak content, weak w] in
            guard let self, let content, self.window === w, !leaving else { return }
            leaving = true
            self.stayWork?.cancel()
            self.animation?.invalidate()
            let from = content.peek
            self.animation = tween(duration: 0.5, easeOut: false, update: { content.peek = from * (1 - $0) }, done: { [weak self] in
                guard self?.window === w else { return }
                self?.teardown()
            })
        }
        cat.onClick = leave
        content.bubble?.onClick = leave

        animation = tween(duration: 0.7, update: { content.peek = $0 }, done: { [weak self] in
            guard let self, self.window === w else { return }
            let work = DispatchWorkItem { leave() }
            self.stayWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (stayDuration ?? .random(in: Settings.peekStayRange)), execute: work)
        })
    }

    private func teardown() {
        animation?.invalidate()
        animation = nil
        stayWork?.cancel()
        stayWork = nil
        window?.orderOut(nil)
        window = nil
        busy = false
        lastEnd = Date()
    }

    /// Removes the cat immediately (used when a break starts).
    func dismissNow() { teardown() }

    /// Shows the onboarding sample as a real corner visit, even if the normal cooldown is active.
    func preview(image: AnimatedImage?, nextBreak: Date? = nil) {
        if busy { dismissNow() }
        peek(previewImage: image, bypassCooldown: true, stayDuration: 5, nextBreak: nextBreak)
    }

#if DEMO_CAPTURE
    func setSharingType(_ sharingType: NSWindow.SharingType) {
        window?.sharingType = sharingType
    }
#endif
}

// MARK: - Heads-up before a break

/// A small card in the top-right corner that counts down to the break without dimming anything.
/// It never takes focus, and is excluded from screen capture.
final class HeadsUp {
    enum Outcome { case start, skip, snooze, interrupted }

    private var panel: NSPanel?
    private var timer: Timer?
    private var remaining = 0
    private var onDone: ((Outcome) -> Void)?
    private let number = NSTextField(labelWithString: "")

    var isShowing: Bool { panel != nil }

#if DEMO_CAPTURE
    func setSharingType(_ sharingType: NSWindow.SharingType) {
        panel?.sharingType = sharingType
    }
#endif

    func show(seconds: Int, onDone: @escaping (Outcome) -> Void) {
        guard !isShowing, let screen = NSScreen.main else { return }
        self.onDone = onDone
        remaining = seconds

        let size = NSSize(width: 320, height: 118)
        let area = screen.visibleFrame
        let origin = NSPoint(x: area.maxX - size.width - 16, y: area.maxY - size.height - 12)
        let p = NSPanel(contentRect: NSRect(origin: origin, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.sharingType = Settings.overlaySharingType
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let card = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        card.material = .hudWindow
        card.blendingMode = .behindWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 16
        card.layer?.masksToBounds = true
        p.contentView = card

        let title = NSTextField(labelWithString: "Break coming up")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.frame = NSRect(x: 18, y: 84, width: 200, height: 18)
        card.addSubview(title)

        number.font = .monospacedDigitSystemFont(ofSize: 40, weight: .light)
        number.alignment = .right
        number.frame = NSRect(x: size.width - 98, y: 60, width: 80, height: 48)
        card.addSubview(number)

        let sub = NSTextField(labelWithString: "Finish up what you're doing")
        sub.font = .systemFont(ofSize: 11)
        sub.textColor = .secondaryLabelColor
        sub.frame = NSRect(x: 18, y: 66, width: 200, height: 14)
        card.addSubview(sub)

        func button(_ title: String, _ x: CGFloat, _ width: CGFloat, _ outcome: Outcome) -> NSButton {
            let handler = ActionBox { [weak self] in self?.finish(outcome) }
            let b = NSButton(title: title, target: handler, action: #selector(ActionBox.fire))
            objc_setAssociatedObject(b, &ActionBox.key, handler, .OBJC_ASSOCIATION_RETAIN)
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.frame = NSRect(x: x, y: 14, width: width, height: 26)
            return b
        }
        card.addSubview(button("Skip", 14, 70, .skip))
        card.addSubview(button("Snooze \(Settings.snoozeMinutes) min", 90, 120, .snooze))
        let start = button("Start now", 216, 90, .start)
        start.keyEquivalent = ""
        card.addSubview(start)

        number.stringValue = "\(remaining)"
        p.alphaValue = 0
        p.orderFrontRegardless()
        p.animator().alphaValue = 1
        panel = p

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.remaining -= 1
            if self.remaining <= 0 { self.finish(.start); return }
            self.number.stringValue = "\(self.remaining)"
            // A screen share that begins during the warning cancels it; the break then waits for the share to end.
            if self.remaining % 3 == 0 && ShareGuard.isSharing() { self.finish(.interrupted) }
        }
    }

    /// Closes the card without reporting an outcome (for example, when the user turns breaks off).
    func cancel() {
        timer?.invalidate()
        timer = nil
        onDone = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func finish(_ outcome: Outcome) {
        guard isShowing else { return }
        let done = onDone
        cancel()
        done?(outcome)
    }
}

// MARK: - Break overlay

/// Content view for dim-only breaks: any click dismisses.
private final class DismissView: NSView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// Checks camera frames locally during opted-in breaks. Frames are analyzed in memory and discarded.
private final class BreakPresenceMonitor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    enum State: Equatable {
        case waiting
        case away
        case personDetected
        case unavailable(String)

        var message: String {
            switch self {
            case .waiting: return "Waiting for camera…"
            case .away: return "No person in view — timer running"
            case .personDetected: return "Person in view — timer paused"
            case .unavailable(let message): return message
            }
        }
    }

    private let captureQueue = DispatchQueue(label: "local.dennis.straycat.break-camera")
    private let analysisQueue = DispatchQueue(label: "local.dennis.straycat.break-vision")
    private let stateLock = NSLock()
    private let humanRequest = VNDetectHumanRectanglesRequest()
    private let imageContext = CIContext()
    private let onStateChange: (State, CGImage?) -> Void
    private var session: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var state: State = .waiting
    private var monitoringSince: Date?
    private var lastFrameAt: Date?
    private var lastAnalysisAt = Date.distantPast
    private var lastPreviewAt = Date.distantPast
    private var stopped = false

    init(onStateChange: @escaping (State, CGImage?) -> Void) {
        self.onStateChange = onStateChange
        super.init()
        humanRequest.upperBodyOnly = true
    }

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                guard let self else { return }
                if allowed {
                    self.configureAndStart()
                } else {
                    self.publish(.unavailable("Camera access is off — regular timer continues"))
                }
            }
        case .denied, .restricted:
            publish(.unavailable("Camera access is off — regular timer continues"))
        @unknown default:
            publish(.unavailable("Camera unavailable — regular timer continues"))
        }
    }

    /// Returns a fail-open state if the camera stops delivering frames.
    func countdownState() -> State {
        stateLock.lock()
        var current = state
        if case .unavailable = current {
            stateLock.unlock()
            return current
        }
        let reference = lastFrameAt ?? monitoringSince
        let feedIsStale = reference.map { Date().timeIntervalSince($0) > 6 } ?? false
        if feedIsStale {
            current = .unavailable("Camera feed paused — regular timer continues")
            state = current
        }
        stateLock.unlock()
        if feedIsStale { notify(current, previewFrame: nil) }
        return current
    }

    func stop() {
        stateLock.lock()
        stopped = true
        stateLock.unlock()

        captureQueue.async { [weak self] in
            guard let self, let session = self.session else { return }
            self.videoOutput?.setSampleBufferDelegate(nil, queue: nil)
            if session.isRunning { session.stopRunning() }
            self.videoOutput = nil
            self.session = nil
        }
    }

    private func configureAndStart() {
        captureQueue.async { [weak self] in
            guard let self, !self.isStopped else { return }
            guard let camera = AVCaptureDevice.default(for: .video) else {
                self.publish(.unavailable("No camera found — regular timer continues"))
                return
            }

            let session = AVCaptureSession()
            session.beginConfiguration()
            do {
                if session.canSetSessionPreset(.medium) { session.sessionPreset = .medium }
                let input = try AVCaptureDeviceInput(device: camera)
                guard session.canAddInput(input) else {
                    throw NSError(domain: "StrayCatCamera", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Camera input unavailable"])
                }
                session.addInput(input)

                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
                output.setSampleBufferDelegate(self, queue: analysisQueue)
                guard session.canAddOutput(output) else {
                    throw NSError(domain: "StrayCatCamera", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "Camera video unavailable"])
                }
                session.addOutput(output)
                session.commitConfiguration()
                self.session = session
                self.videoOutput = output
                self.publish(.waiting, resetWatchdog: true)
                session.startRunning()
            } catch {
                session.commitConfiguration()
                self.publish(.unavailable("Camera unavailable — regular timer continues"))
            }
        }
    }

    private var isStopped: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopped
    }

    private func publish(_ next: State, frameAt: Date? = nil, resetWatchdog: Bool = false) {
        stateLock.lock()
        guard !stopped else {
            stateLock.unlock()
            return
        }
        if resetWatchdog {
            monitoringSince = Date()
            lastFrameAt = nil
        }
        if let frameAt { lastFrameAt = frameAt }
        let changed = state != next
        state = next
        stateLock.unlock()
        if changed { notify(next, previewFrame: nil) }
    }

    private func publishFrame(_ frame: CGImage?, at time: Date) {
        stateLock.lock()
        guard !stopped else {
            stateLock.unlock()
            return
        }
        lastFrameAt = time
        let current = state
        stateLock.unlock()
        if let frame { notify(current, previewFrame: frame) }
    }

    private func notify(_ state: State, previewFrame: CGImage?) {
        DispatchQueue.main.async { [weak self] in self?.onStateChange(state, previewFrame) }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let now = Date()
        let shouldAnalyze = now.timeIntervalSince(lastAnalysisAt) >= 1
        let shouldRefreshPreview = now.timeIntervalSince(lastPreviewAt) >= 0.2
        guard shouldAnalyze || shouldRefreshPreview else { return }

        if shouldAnalyze {
            lastAnalysisAt = now
            do {
                let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, options: [:])
                try handler.perform([humanRequest])
                let personVisible = (humanRequest.results ?? []).contains { $0.confidence >= 0.4 }
                publish(personVisible ? .personDetected : .away, frameAt: now)
            } catch {
                publish(.unavailable("Camera check failed — regular timer continues"), frameAt: now)
            }
        } else {
            publishFrame(nil, at: now)
        }

        if shouldRefreshPreview {
            lastPreviewAt = now
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let image = CIImage(cvPixelBuffer: pixelBuffer)
            let frame = imageContext.createCGImage(image, from: image.extent)
            publishFrame(frame, at: now)
        }
    }
}

private final class OverlayWindow: NSWindow {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }
}

/// Dims every display with a shielding-level window (above full-screen apps, the Dock, and the menu bar)
/// and counts down a short break.
final class BreakOverlay {
    private var windows: [OverlayWindow] = []
    private var countdownTimer: Timer?
    private var remaining = Settings.breakSeconds
    private var presenceDuration = Settings.breakSeconds
    private var presenceMonitor: BreakPresenceMonitor?
    private var presenceRequired = false
    private var timerTicks = 0
    private var closeFadeDuration: TimeInterval = 0.6
    private let countdownLabel = NSTextField(labelWithString: "")
    private let presenceStatusLabel = NSTextField(labelWithString: "")
    private let cameraPreviewBorder = NSView()
    private let cameraPreviewImage = NSImageView()
    private var onFinish: ((_ snoozed: Bool) -> Void)?
    private weak var breakCat: CatView?
    private weak var copyHintPill: NSView?
    private weak var copyHintLabel: NSTextField?
    private var isHoveringBreakGIF = false

    var isShowing: Bool { !windows.isEmpty }

#if DEMO_CAPTURE
    func setSharingType(_ sharingType: NSWindow.SharingType) {
        windows.forEach { $0.sharingType = sharingType }
    }
#endif

    func show(durationOverride: Int? = nil, imageOverride: AnimatedImage? = nil,
              showMessageOverride: Bool? = nil, onFinish: @escaping (_ snoozed: Bool) -> Void) {
        guard !isShowing else { return }
        self.onFinish = onFinish
        remaining = durationOverride ?? Settings.breakSeconds
        presenceDuration = remaining
        timerTicks = 0
        presenceRequired = durationOverride == nil && Settings.requireAwayForBreak
        closeFadeDuration = durationOverride == nil ? 0.6 : 0.15
        // Camera-confirmed breaks need a visible countdown and camera status even in dim-only mode.
        let showMessage = showMessageOverride ?? (Settings.showBreakMessage || presenceRequired)

        let shielding = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        let mainScreen = NSScreen.main
        for screen in NSScreen.screens {
            let w = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.setFrame(screen.frame, display: true)
            w.level = shielding
            w.sharingType = Settings.overlaySharingType
            w.isOpaque = false
            w.backgroundColor = NSColor.black.withAlphaComponent(CGFloat(Settings.dimPercent) / 100)
            w.hasShadow = false
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            w.onEscape = { [weak self] in self?.finish(snoozed: false) }
            w.alphaValue = 0
            let content = DismissView(frame: NSRect(origin: .zero, size: screen.frame.size))
            w.contentView = content
            if showMessage {
                if screen == mainScreen {
                    buildPrompt(in: content, imageOverride: imageOverride, showPresenceStatus: presenceRequired)
                }
            } else {
                // Dim only: click anywhere (or press Esc) to dismiss early.
                content.onClick = { [weak self] in self?.finish(snoozed: false) }
            }
            w.makeKeyAndOrderFront(nil)
            w.orderFrontRegardless()
            windows.append(w)
        }

        // Swap in a random online GIF once it arrives; the local/drawn cat shows until then (or if it fails).
#if DEMO_CAPTURE
        let shouldFetchOnlineGif = imageOverride == nil && !Settings.demoSequenceMode && Settings.onlineGifs && showMessage
#else
        let shouldFetchOnlineGif = imageOverride == nil && Settings.onlineGifs && showMessage
#endif
        if shouldFetchOnlineGif {
            OnlineGIF.random(from: Settings.onlineURL) { [weak self] image in
                guard let self, self.isShowing, let image else { return }
                guard let cat = self.breakCat else { return }
                cat.customImage = image
                if let parent = cat.superview { self.installCopyHint(for: image, cat: cat, in: parent) }
            }
        }

        NSApp.activate(ignoringOtherApps: true)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = durationOverride == nil ? 1.2 : 0.15
            windows.forEach { $0.animator().alphaValue = 1 }
        }

        updateCountdown()
        if presenceRequired {
            setPresenceStatus(.waiting)
            let monitor = BreakPresenceMonitor { [weak self] state, frame in
                guard let self, self.isShowing, self.presenceRequired, self.presenceMonitor != nil else { return }
                self.setPresenceStatus(state, previewFrame: frame)
            }
            presenceMonitor = monitor
            monitor.start()
        }
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.timerTicks += 1
            if self.timerTicks % 5 == 0 && ShareGuard.isSharing() { self.finish(snoozed: false); return }

            if let monitor = self.presenceMonitor {
                switch monitor.countdownState() {
                case .waiting:
                    return
                case .personDetected:
                    if self.remaining != self.presenceDuration {
                        self.remaining = self.presenceDuration
                        self.updateCountdown()
                    }
                    return
                case .away:
                    break
                case .unavailable(let message):
                    self.setPresenceStatus(.unavailable(message))
                    monitor.stop()
                    self.presenceMonitor = nil
                }
            }

            self.remaining -= 1
            if self.remaining <= 0 { self.finish(snoozed: false) } else { self.updateCountdown() }
        }
    }

    private func setPresenceStatus(_ state: BreakPresenceMonitor.State, previewFrame: CGImage? = nil) {
        presenceStatusLabel.stringValue = state.message
        if let previewFrame {
            cameraPreviewImage.image = NSImage(cgImage: previewFrame,
                                               size: NSSize(width: previewFrame.width, height: previewFrame.height))
        }
        switch state {
        case .personDetected:
            cameraPreviewBorder.layer?.borderColor = NSColor.systemRed.cgColor
        case .away:
            cameraPreviewBorder.layer?.borderColor = NSColor.systemGreen.cgColor
        case .waiting:
            cameraPreviewBorder.layer?.borderColor = NSColor.white.withAlphaComponent(0.5).cgColor
        case .unavailable:
            presenceStatusLabel.textColor = NSColor.systemYellow.withAlphaComponent(0.9)
            cameraPreviewBorder.layer?.borderColor = NSColor.systemYellow.cgColor
        }
        if case .unavailable = state { return }
        presenceStatusLabel.textColor = NSColor.white.withAlphaComponent(0.72)
    }

    private func updateCountdown() {
        countdownLabel.stringValue = "\(remaining)"
    }

    private func buildPrompt(in view: NSView, imageOverride: AnimatedImage? = nil,
                             showPresenceStatus: Bool = false) {
        let b = view.bounds
        let cx = b.midX
        let cat = CatView(frame: NSRect(x: cx - 120, y: b.midY + 80, width: 240, height: 240))
        cat.peek = 1
        if let imageOverride {
            cat.customImage = imageOverride
        } else {
#if DEMO_CAPTURE
            if Settings.demoSequenceMode {
                cat.customImage = Bundle.main.url(forResource: "demo-cat", withExtension: "gif").flatMap(AnimatedImage.init(url:))
            } else {
                cat.customImage = Settings.randomImage(for: .breakScreen) ?? Settings.randomImage(for: .popup)
            }
#else
            cat.customImage = Settings.randomImage(for: .breakScreen) ?? Settings.randomImage(for: .popup)
#endif
        }
        breakCat = cat
        view.addSubview(cat)
        cat.onImageClick = { [weak self] in self?.copyBreakGIF() }
        cat.onHoverChanged = { [weak self, weak cat] isHovering in
            cat?.setGIFHovered(isHovering)
            self?.setCopyHintHover(isHovering)
        }
        installCopyHint(for: cat.customImage, cat: cat, in: view)

        func label(_ text: String, size: CGFloat, weight: NSFont.Weight, y: CGFloat, alpha: CGFloat = 1) -> NSTextField {
            let l = NSTextField(labelWithString: text)
            l.font = .systemFont(ofSize: size, weight: weight)
            l.textColor = NSColor.white.withAlphaComponent(alpha)
            l.alignment = .center
            l.frame = NSRect(x: 0, y: y, width: b.width, height: size * 1.4)
            return l
        }
        view.addSubview(label("Time for a break", size: 44, weight: .semibold, y: b.midY - 40))
        let subtitle = showPresenceStatus
            ? "Step out of view; the timer pauses if it sees you."
            : "Look away from the screen. Stretch, breathe, drink some water."
        view.addSubview(label(subtitle, size: 18, weight: .regular, y: b.midY - 80, alpha: 0.75))

        presenceStatusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        presenceStatusLabel.textColor = NSColor.white.withAlphaComponent(0.72)
        presenceStatusLabel.alignment = .center
        presenceStatusLabel.frame = NSRect(x: 0, y: b.midY - 116, width: b.width, height: 18)
        presenceStatusLabel.isHidden = !showPresenceStatus
        view.addSubview(presenceStatusLabel)

        let previewSize = NSSize(width: 224, height: 150)
        cameraPreviewBorder.frame = NSRect(x: b.width - previewSize.width - 28,
                                           y: b.height - previewSize.height - 48,
                                           width: previewSize.width, height: previewSize.height)
        cameraPreviewBorder.wantsLayer = true
        cameraPreviewBorder.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.8).cgColor
        cameraPreviewBorder.layer?.borderWidth = 4
        cameraPreviewBorder.layer?.borderColor = NSColor.white.withAlphaComponent(0.5).cgColor
        cameraPreviewBorder.layer?.cornerRadius = 12
        cameraPreviewBorder.layer?.masksToBounds = true
        cameraPreviewBorder.isHidden = !showPresenceStatus
        cameraPreviewImage.frame = cameraPreviewBorder.bounds.insetBy(dx: 4, dy: 4)
        cameraPreviewImage.imageScaling = .scaleProportionallyUpOrDown
        cameraPreviewImage.image = nil
        cameraPreviewBorder.addSubview(cameraPreviewImage)
        view.addSubview(cameraPreviewBorder)

        let cameraTitle = label("CAMERA VIEW", size: 10, weight: .semibold,
                                y: cameraPreviewBorder.frame.maxY + 5, alpha: 0.72)
        cameraTitle.frame.origin.x = cameraPreviewBorder.frame.minX
        cameraTitle.frame.size.width = previewSize.width
        cameraTitle.alignment = .left
        cameraTitle.isHidden = !showPresenceStatus
        view.addSubview(cameraTitle)

        countdownLabel.font = .monospacedDigitSystemFont(ofSize: 64, weight: .light)
        countdownLabel.textColor = .white
        countdownLabel.alignment = .center
        countdownLabel.frame = NSRect(x: 0, y: b.midY - (showPresenceStatus ? 194 : 170),
                                      width: b.width, height: showPresenceStatus ? 72 : 80)
        view.addSubview(countdownLabel)

        let skip = NSButton(title: "Skip", target: self, action: #selector(skipTapped))
        skip.bezelStyle = .rounded
        let buttonY = b.midY - (showPresenceStatus ? 246 : 230)
        skip.frame = NSRect(x: cx - 125, y: buttonY, width: 120, height: 32)
        let snooze = NSButton(title: "Snooze 5 min", target: self, action: #selector(snoozeTapped))
        snooze.bezelStyle = .rounded
        snooze.frame = NSRect(x: cx + 5, y: buttonY, width: 120, height: 32)
        view.addSubview(skip)
        view.addSubview(snooze)
        view.addSubview(label("Press Esc to skip", size: 12, weight: .regular,
                              y: buttonY - 40, alpha: 0.4))
    }

    private func installCopyHint(for image: AnimatedImage?, cat: CatView, in view: NSView) {
        guard copyHintLabel == nil,
              let image,
              FileManager.default.fileExists(atPath: image.fileURL.path),
              let imageRect = cat.displayedImageRect(for: image) else { return }

        let pill = NSView()
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.68).cgColor
        pill.layer?.cornerRadius = 14
        pill.layer?.borderWidth = 0.7
        pill.layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
        let inView = cat.convert(imageRect, to: view)
        pill.frame = NSRect(x: inView.midX - 82, y: inView.minY - 38, width: 164, height: 28)
        pill.alphaValue = 0
        pill.isHidden = true

        let label = NSTextField(labelWithString: "Click to copy GIF")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: pill.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: pill.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(lessThanOrEqualTo: pill.trailingAnchor, constant: -12)
        ])

        view.addSubview(pill)
        copyHintPill = pill
        copyHintLabel = label
        if isHoveringBreakGIF { setCopyHintHover(true) }
    }

    private func setCopyHintHover(_ isHovering: Bool) {
        isHoveringBreakGIF = isHovering
        guard let hint = copyHintPill else { return }
        if isHovering, hint.isHidden {
            hint.alphaValue = 0
            hint.isHidden = false
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            hint.animator().alphaValue = isHovering ? 1 : 0
        }, completionHandler: { [weak self, weak hint] in
            guard let self, let hint,
                  self.copyHintPill === hint,
                  !self.isHoveringBreakGIF else { return }
            hint.isHidden = true
        })
    }

    private func copyBreakGIF() {
        guard let url = breakCat?.customImage?.fileURL,
              FileManager.default.fileExists(atPath: url.path) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.writeObjects([url as NSURL]) else { return }
        let hint = copyHintLabel
        hint?.stringValue = "Copied"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self, weak hint] in
            guard let self, let hint,
                  self.copyHintLabel === hint,
                  hint.stringValue == "Copied" else { return }
            hint.stringValue = "Click to copy GIF"
        }
    }

    @objc private func skipTapped() { finish(snoozed: false) }
    @objc private func snoozeTapped() { finish(snoozed: true) }

    private func finish(snoozed: Bool) {
        guard isShowing else { return }
        countdownTimer?.invalidate()
        countdownTimer = nil
        presenceMonitor?.stop()
        presenceMonitor = nil
        presenceRequired = false
        cameraPreviewImage.image = nil
        let closing = windows
        windows = []
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = closeFadeDuration
            closing.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: {
            closing.forEach { $0.orderOut(nil) }
        })
        let cb = onFinish
        onFinish = nil
        isHoveringBreakGIF = false
        breakCat = nil
        copyHintPill = nil
        copyHintLabel = nil
        cb?(snoozed)
    }
}

// MARK: - Gallery thumbnail

/// A gallery thumbnail. Hovering shows a larger (animated) preview and a red × button to delete it.
final class ThumbView: NSView {
    private static let side: CGFloat = 64
    private static var cache: [URL: NSImage] = [:]

    private let file: URL
    private let onDelete: () -> Void
    private let imageView = NSImageView()
    private let deleteButton = NSButton()
    private var popover: NSPopover?

    init(file: URL, onDelete: @escaping () -> Void) {
        self.file = file
        self.onDelete = onDelete
        super.init(frame: NSRect(x: 0, y: 0, width: ThumbView.side, height: ThumbView.side))
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor

        imageView.frame = bounds
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.image = ThumbView.thumbnail(for: file)
        addSubview(imageView)

        let config = NSImage.SymbolConfiguration(paletteColors: [.white, .systemRed])
            .applying(.init(pointSize: 18, weight: .bold))
        deleteButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Delete image")?
            .withSymbolConfiguration(config)
        deleteButton.isBordered = false
        deleteButton.imageScaling = .scaleProportionallyUpOrDown
        deleteButton.frame = NSRect(x: ThumbView.side - 24, y: ThumbView.side - 24, width: 22, height: 22)
        deleteButton.target = self
        deleteButton.action = #selector(deleteTapped)
        deleteButton.isHidden = true
        addSubview(deleteButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: ThumbView.side, height: ThumbView.side) }

    /// First frame, downscaled once and cached so rebuilding the strip stays cheap.
    private static func thumbnail(for url: URL) -> NSImage? {
        if let cached = cache[url] { return cached }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: side * 2,
              ] as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
        cache[url] = image
        return image
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        deleteButton.isHidden = false
        showPreview()
    }

    override func mouseExited(with event: NSEvent) {
        deleteButton.isHidden = true
        closePreview()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { closePreview() }
    }

    private func showPreview() {
        guard popover == nil, let full = NSImage(contentsOf: file), full.size.width > 0, full.size.height > 0 else { return }
        let scale = min(260 / max(full.size.width, full.size.height), 2)
        let size = NSSize(width: max(full.size.width * scale, 40), height: max(full.size.height * scale, 40))

        let preview = NSImageView(frame: NSRect(origin: .zero, size: size))
        preview.image = full
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.animates = true  // plays GIFs

        let controller = NSViewController()
        controller.view = preview
        let pop = NSPopover()
        pop.contentViewController = controller
        pop.contentSize = size
        pop.behavior = .applicationDefined
        pop.animates = false
        pop.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
        popover = pop
    }

    private func closePreview() {
        popover?.close()
        popover = nil
    }

    @objc private func deleteTapped() {
        closePreview()
        onDelete()
    }
}

// MARK: - Settings window

/// Ensures the standard Select All shortcut reaches AppKit's shared text-field editor.
final class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command,
           event.charactersIgnoringModifiers?.lowercased() == "a",
           let editor = firstResponder as? NSTextView,
           editor.isFieldEditor {
            editor.selectAll(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// A small form that edits `Settings`. Every change is saved and applied immediately.
final class SettingsWindowController: NSWindowController {
    private struct Row {
        let title: String
        let unit: String
        let range: ClosedRange<Int>
        let get: () -> Int
        let set: (Int) -> Void
    }

    private let onChange: () -> Void
    /// Each control registers a closure that re-reads its value, so the window never shows stale state.
    private var refreshers: [() -> Void] = []

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        let w = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 10),
                               styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Stray Cat Settings"
        w.isReleasedWhenClosed = false
        super.init(window: w)
        build()
        w.center()

        // Refresh when the window comes to the front (the login item can be changed in System Settings)
        // and whenever the stored values change.
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: w, queue: .main) { [weak self] _ in
            self?.refresh()
        }
        nc.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func refresh() { refreshers.forEach { $0() } }

    func present() {
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let tabs = NSTabView()
        let panes = [
            ("Breaks", breaksPane()),
            ("Cat", catPane()),
            ("General", generalPane()),
        ]
        var tallest: CGFloat = 0
        for (title, stack) in panes {
            tallest = max(tallest, stack.fittingSize.height)
            let container = NSView()
            stack.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: container.topAnchor),
                stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            ])
            let item = NSTabViewItem(identifier: title)
            item.label = title
            item.view = container
            tabs.addTabViewItem(item)
        }
        window?.contentView = tabs
        window?.setContentSize(NSSize(width: 500, height: tallest + 64))
    }

    private func pane(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        return stack
    }

    private func hint(_ text: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .secondaryLabelColor
        l.preferredMaxLayoutWidth = 400
        return l
    }

    private func breaksPane() -> NSStackView {
        let local = pane([imageRow("My images", slot: .breakScreen), thumbnailStrip(slot: .breakScreen)])
        let web = pane([
            textRow("GIF search", placeholder: "cats, cozy, or a Tenor URL", secure: false,
                    get: { Settings.onlineURL }) { Settings.onlineURL = $0 },
            hint("Type a few words or paste a Tenor page. A random GIF from the search appears each break."),
        ])
        [local, web].forEach { $0.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }
        refreshers.append {
            local.isHidden = Settings.onlineGifs
            web.isHidden = !Settings.onlineGifs
        }
        local.isHidden = Settings.onlineGifs
        web.isHidden = !Settings.onlineGifs

        return pane([
            toggle("Remind me to take breaks", get: { Settings.breaksEnabled }) { Settings.breaksEnabled = $0 },
            row(Row(title: "Remind every", unit: "min", range: 1...240,
                    get: { Settings.breakMinutes }, set: { Settings.breakMinutes = $0 })),
            row(Row(title: "Warn me first", unit: "sec (0 = off)", range: 0...120,
                    get: { Settings.warnSeconds }, set: { Settings.warnSeconds = $0 })),
            row(Row(title: "Break lasts", unit: "sec", range: 5...600,
                    get: { Settings.breakSeconds }, set: { Settings.breakSeconds = $0 })),
            row(Row(title: "Snooze for", unit: "min", range: 1...60,
                    get: { Settings.snoozeMinutes }, set: { Settings.snoozeMinutes = $0 })),
            row(Row(title: "Screen dimming", unit: "%", range: 10...100,
                    get: { Settings.dimPercent }, set: { Settings.dimPercent = $0 })),
            toggle("Show message and countdown (off = just dim)", get: { Settings.showBreakMessage }) { Settings.showBreakMessage = $0 },
            toggle("Use camera presence check during breaks", get: { Settings.requireAwayForBreak }) { Settings.requireAwayForBreak = $0 },
            hint("The timer counts down only while no person is visible to the camera. Detection runs on this Mac; video is not saved or uploaded. It cannot verify whether you have physically left your desk. If the camera is unavailable, the regular timer continues."),
            header("Picture on the break screen"),
            picker("Show", items: ["My images (or a random cat)", "Random GIF from the web"],
                   get: { Settings.onlineGifs ? 1 : 0 }) { [weak self] in
                Settings.onlineGifs = ($0 == 1)
                self?.refresh()
            },
            local,
            web,
        ])
    }

    private func catPane() -> NSStackView {
        let local = pane([imageRow("My images", slot: .popup), thumbnailStrip(slot: .popup)])
        let web = pane([
            textRow("GIF search", placeholder: "cats, loafing, tiny desk cats", secure: false,
                    get: { Settings.popupOnlineURL }) { Settings.popupOnlineURL = $0 },
            hint("Use a few words or a Tenor search page. A random GIF from the search appears with each visit."),
        ])
        [local, web].forEach { $0.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) }
        refreshers.append {
            local.isHidden = Settings.popupOnlineGifs
            web.isHidden = !Settings.popupOnlineGifs
        }
        local.isHidden = Settings.popupOnlineGifs
        web.isHidden = !Settings.popupOnlineGifs

        return pane([
            toggle("Let the cat visit", get: { Settings.catEnabled }) { Settings.catEnabled = $0 },
            row(Row(title: "Visits about every", unit: "min", range: 1...120,
                    get: { Settings.catEveryMinutes }, set: { Settings.catEveryMinutes = $0 })),
            row(Row(title: "Stays for about", unit: "sec", range: 2...60,
                    get: { Settings.catStaySeconds }, set: { Settings.catStaySeconds = $0 })),
            picker("Show", items: ["My images or drawn cat", "Random GIF from the web"],
                   get: { Settings.popupOnlineGifs ? 1 : 0 }) { [weak self] in
                Settings.popupOnlineGifs = ($0 == 1)
                self?.refresh()
            },
            local,
            web,
        ])
    }

    private func generalPane() -> NSStackView {
        pane([
            loginToggle(),
            header("While you're sharing your screen"),
            toggle("Hide the cat and hold off breaks", get: { Settings.holdDuringShare }) { Settings.holdDuringShare = $0 },
            toggle("Also hold off whenever the microphone is in use", get: { Settings.holdDuringCalls }) { Settings.holdDuringCalls = $0 },
            hint("Detects Zoom screen shares and any app using the microphone. Other screen shares can't be detected."),
        ])
    }

    /// A label plus a pop-up menu.
    private func picker(_ title: String, items: [String], get: @escaping () -> Int, _ set: @escaping (Int) -> Void) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let pop = NSPopUpButton(frame: .zero, pullsDown: false)
        pop.addItems(withTitles: items)
        pop.selectItem(at: get())
        let handler = ActionBox { [weak self] in
            set(pop.indexOfSelectedItem)
            self?.onChange()
        }
        pop.target = handler
        pop.action = #selector(ActionBox.fire)
        objc_setAssociatedObject(pop, &ActionBox.key, handler, .OBJC_ASSOCIATION_RETAIN)
        refreshers.append { pop.selectItem(at: get()) }
        let h = NSStackView(views: [label, pop])
        h.spacing = 8
        return h
    }

    /// An "Add…" / "Clear" pair for a gallery of images, showing how many are in it.
    private func imageRow(_ title: String, slot: Settings.Slot) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.widthAnchor.constraint(equalToConstant: 150).isActive = true

        let count = NSTextField(labelWithString: "")
        count.textColor = .secondaryLabelColor
        count.widthAnchor.constraint(equalToConstant: 80).isActive = true

        let clear = NSButton(title: "Clear", target: nil, action: nil)
        let update = {
            let n = Settings.galleryFiles(for: slot).count
            count.stringValue = n == 0 ? "Random cat" : "\(n) image\(n == 1 ? "" : "s")"
            clear.isEnabled = n > 0
        }

        let addHandler = ActionBox { [weak self] in
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.image]
            panel.allowsMultipleSelection = true
            panel.message = "Choose images for “\(title)”. One is picked at random each time."
            NSApp.activate(ignoringOtherApps: true)
            guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
            do {
                try Settings.addImages(panel.urls, to: slot)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn't add those images"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
            update()
            self?.onChange()
        }
        let add = NSButton(title: "Add…", target: addHandler, action: #selector(ActionBox.fire))
        objc_setAssociatedObject(add, &ActionBox.key, addHandler, .OBJC_ASSOCIATION_RETAIN)

        let clearHandler = ActionBox { [weak self] in
            Settings.clearImages(for: slot)
            update()
            self?.onChange()
        }
        clear.target = clearHandler
        clear.action = #selector(ActionBox.fire)
        objc_setAssociatedObject(clear, &ActionBox.key, clearHandler, .OBJC_ASSOCIATION_RETAIN)

        update()
        refreshers.append(update)

        let h = NSStackView(views: [label, count, add, clear])
        h.spacing = 8
        return h
    }

    /// Thumbnails of a gallery. Hover one for a larger preview and a red × to delete it.
    private func thumbnailStrip(slot: Settings.Slot) -> NSView {
        let strip = NSStackView()
        strip.spacing = 8
        strip.edgeInsets = NSEdgeInsets(top: 4, left: 2, bottom: 4, right: 2)

        let scroll = NSScrollView()
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = strip
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: 420).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 88).isActive = true

        let empty = NSTextField(labelWithString: "No images added. A random drawn cat is used.")
        empty.textColor = .secondaryLabelColor

        var shown: [URL]?
        let update = { [weak self] in
            let files = Settings.galleryFiles(for: slot)
            guard files != shown else { return }  // refresh runs on every settings change; skip no-ops
            shown = files
            strip.arrangedSubviews.forEach { $0.removeFromSuperview() }
            if files.isEmpty { strip.addArrangedSubview(empty) }
            for file in files {
                strip.addArrangedSubview(ThumbView(file: file) {
                    Settings.removeImage(file)
                    self?.refresh()
                    self?.onChange()
                })
            }
            strip.layoutSubtreeIfNeeded()
            strip.frame.size = strip.fittingSize
        }
        update()
        refreshers.append(update)
        return scroll
    }

    /// A label plus an editable text field that saves when you press Return or click away.
    private func textRow(_ title: String, placeholder: String, secure: Bool, get: @escaping () -> String,
                         _ set: @escaping (String) -> Void) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let field: NSTextField = secure ? NSSecureTextField(string: get()) : NSTextField(string: get())
        field.placeholderString = placeholder
        field.widthAnchor.constraint(equalToConstant: 240).isActive = true
        let handler = ActionBox { [weak self] in
            set(field.stringValue.trimmingCharacters(in: .whitespaces))
            self?.onChange()
        }
        field.target = handler
        field.action = #selector(ActionBox.fire)
        objc_setAssociatedObject(field, &ActionBox.key, handler, .OBJC_ASSOCIATION_RETAIN)
        refreshers.append { if field.currentEditor() == nil { field.stringValue = get() } }
        let h = NSStackView(views: [label, field])
        h.spacing = 8
        return h
    }

    private func header(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .boldSystemFont(ofSize: 13)
        return l
    }

    private func toggle(_ title: String, get: @escaping () -> Bool, _ set: @escaping (Bool) -> Void) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        b.state = get() ? .on : .off
        let handler = ActionBox { [weak self] in
            set(b.state == .on)
            self?.onChange()
        }
        b.target = handler
        b.action = #selector(ActionBox.fire)
        objc_setAssociatedObject(b, &ActionBox.key, handler, .OBJC_ASSOCIATION_RETAIN)
        refreshers.append { b.state = get() ? .on : .off }
        return b
    }

    /// "Start at login" is backed by the system login-item registration, not UserDefaults,
    /// so the checkbox always reflects what macOS actually has.
    private func loginToggle() -> NSButton {
        let service = SMAppService.mainApp
        let b = NSButton(checkboxWithTitle: "Start Stray Cat when I log in", target: nil, action: nil)
        let sync = { b.state = service.status == .enabled ? .on : .off }
        sync()

        let handler = ActionBox {
            do {
                if b.state == .on { try service.register() } else { try service.unregister() }
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn't change the login item"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
            if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            sync()
        }
        b.target = handler
        b.action = #selector(ActionBox.fire)
        objc_setAssociatedObject(b, &ActionBox.key, handler, .OBJC_ASSOCIATION_RETAIN)
        refreshers.append(sync)
        return b
    }

    private func row(_ r: Row) -> NSView {
        let label = NSTextField(labelWithString: r.title)
        label.frame.size.width = 150
        label.widthAnchor.constraint(equalToConstant: 150).isActive = true

        let field = NSTextField(string: "\(r.get())")
        field.alignment = .right
        field.widthAnchor.constraint(equalToConstant: 56).isActive = true

        let stepper = NSStepper()
        stepper.minValue = Double(r.range.lowerBound)
        stepper.maxValue = Double(r.range.upperBound)
        stepper.increment = 1
        stepper.integerValue = r.get()
        stepper.valueWraps = false

        let unit = NSTextField(labelWithString: r.unit)
        unit.textColor = .secondaryLabelColor

        let apply = { [weak self] (value: Int) in
            let v = min(max(value, r.range.lowerBound), r.range.upperBound)
            field.integerValue = v
            stepper.integerValue = v
            r.set(v)
            self?.onChange()
        }
        let stepperHandler = ActionBox { apply(stepper.integerValue) }
        stepper.target = stepperHandler
        stepper.action = #selector(ActionBox.fire)
        objc_setAssociatedObject(stepper, &ActionBox.key, stepperHandler, .OBJC_ASSOCIATION_RETAIN)
        let fieldHandler = ActionBox { apply(field.integerValue) }
        field.target = fieldHandler
        field.action = #selector(ActionBox.fire)
        objc_setAssociatedObject(field, &ActionBox.key, fieldHandler, .OBJC_ASSOCIATION_RETAIN)

        refreshers.append {
            field.integerValue = r.get()
            stepper.integerValue = r.get()
        }

        let h = NSStackView(views: [label, field, stepper, unit])
        h.spacing = 8
        return h
    }
}

/// Lets closures be used as AppKit target/action handlers.
final class ActionBox: NSObject {
    nonisolated(unsafe) static var key: UInt8 = 0
    private let body: () -> Void
    init(_ body: @escaping () -> Void) { self.body = body }
    @objc func fire() { body() }
}

private final class AnimatedPreviewView: NSView {
    var image: AnimatedImage? { didSet { epoch = Date(); needsDisplay = true } }
    private var epoch = Date()
    private var timer: Timer?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        guard window != nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            self?.needsDisplay = true
        }
    }

    func stopAnimating() {
        timer?.invalidate()
        timer = nil
    }

    deinit { timer?.invalidate() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(rect: bounds).fill()
        guard let image, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let rect = CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                          width: size.width, height: size.height)
        ctx.saveGState()
        ctx.clip(to: bounds)
        ctx.interpolationQuality = .high
        ctx.draw(image.frame(at: Date().timeIntervalSince(epoch)), in: rect)
        ctx.restoreGState()
    }
}

private final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let onPreviewPopup: (AnimatedImage?) -> Void
    private let onPreviewBreak: (AnimatedImage?) -> Void
    private let onFinish: (_ popupSearch: String, _ breakSearch: String) -> Void
    private let popupPreview = AnimatedPreviewView(frame: .zero)
    private let breakPreview = AnimatedPreviewView(frame: .zero)
    private let popupSearch = NSTextField(string: "")
    private let breakSearch = NSTextField(string: "")
    private let popupStatus = NSTextField(labelWithString: "")
    private let breakStatus = NSTextField(labelWithString: "")
    private let gifSearchPane = NSStackView()
    private weak var rootStack: NSStackView?
    private var didFinish = false

    init(onPreviewPopup: @escaping (AnimatedImage?) -> Void,
         onPreviewBreak: @escaping (AnimatedImage?) -> Void,
         onFinish: @escaping (_ popupSearch: String, _ breakSearch: String) -> Void) {
        self.onPreviewPopup = onPreviewPopup
        self.onPreviewBreak = onPreviewBreak
        self.onFinish = onFinish
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 480),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Welcome to Stray Cat"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        build()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func finishWithDefaults() { finish() }

    private func build() {
        popupPreview.image = bundledPreview("onboarding-popup")
        breakPreview.image = bundledPreview("onboarding-break")

        let title = NSTextField(labelWithString: "A little company for your Mac")
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        let subtitle = NSTextField(wrappingLabelWithString:
            "A cat drops by now and then. When it’s time to rest, Stray Cat helps you look away."
        )
        subtitle.textColor = .secondaryLabelColor
        subtitle.preferredMaxLayoutWidth = 660
        subtitle.alignment = .center

        let examples = NSStackView(views: [
            previewCard(title: "Cat visits", caption: "A little pop-up in the corner.", preview: popupPreview),
            previewCard(title: "Break time", caption: "A gentle pause with a countdown.", preview: breakPreview),
        ])
        examples.orientation = .horizontal
        examples.alignment = .top
        examples.spacing = 16

        let customize = NSButton(title: "Find GIFs (optional)", target: self, action: #selector(toggleGIFSearch))
        customize.bezelStyle = .rounded

        let popupRow = searchRow("Cat visits", field: popupSearch, buttonTitle: "Preview", action: #selector(previewPopupGIF))
        let breakRow = searchRow("Break screen", field: breakSearch, buttonTitle: "Preview", action: #selector(previewBreakGIF))
        let searchHint = NSTextField(wrappingLabelWithString:
            "Search for a GIF if you like. Preview shows it on your screen; Start saves your searches."
        )
        searchHint.font = .systemFont(ofSize: 11)
        searchHint.textColor = .secondaryLabelColor
        searchHint.preferredMaxLayoutWidth = 650
        gifSearchPane.orientation = .vertical
        gifSearchPane.alignment = .leading
        gifSearchPane.spacing = 5
        gifSearchPane.addArrangedSubview(popupRow)
        gifSearchPane.addArrangedSubview(popupStatus)
        gifSearchPane.addArrangedSubview(breakRow)
        gifSearchPane.addArrangedSubview(breakStatus)
        gifSearchPane.addArrangedSubview(searchHint)
        gifSearchPane.isHidden = true

        let start = NSButton(title: "Start", target: self, action: #selector(startTapped))
        start.bezelStyle = .rounded
        start.controlSize = .large
        start.keyEquivalent = "\r"
        let footnote = NSTextField(labelWithString: "You can change settings anytime from the cat in your menu bar.")
        footnote.font = .systemFont(ofSize: 11)
        footnote.textColor = .secondaryLabelColor

        let root = NSStackView(views: [title, subtitle, examples, customize, gifSearchPane, start, footnote])
        root.orientation = .vertical
        root.alignment = .centerX
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 20, right: 24)
        window?.contentView = root
        window?.setContentSize(NSSize(width: 740, height: max(480, root.fittingSize.height)))
        rootStack = root
    }

    private func previewCard(title: String, caption: String, preview: AnimatedPreviewView) -> NSView {
        preview.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            preview.widthAnchor.constraint(equalToConstant: 318),
            preview.heightAnchor.constraint(equalToConstant: 176),
        ])
        preview.wantsLayer = true
        preview.layer?.cornerRadius = 8
        preview.layer?.masksToBounds = true

        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        let detail = NSTextField(labelWithString: caption)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        let card = NSStackView(views: [preview, heading, detail])
        card.orientation = .vertical
        card.alignment = .leading
        card.spacing = 6
        card.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        card.layer?.cornerRadius = 11
        return card
    }

    private func searchRow(_ title: String, field: NSTextField, buttonTitle: String, action: Selector) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.widthAnchor.constraint(equalToConstant: 100).isActive = true
        field.placeholderString = "cats, loafing, tiny desk cats"
        field.widthAnchor.constraint(equalToConstant: 390).isActive = true
        field.target = self
        field.action = action
        let button = NSButton(title: buttonTitle, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        let row = NSStackView(views: [label, field, button])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func bundledPreview(_ name: String) -> AnimatedImage? {
        Bundle.main.url(forResource: name, withExtension: "gif").flatMap(AnimatedImage.init(url:))
    }

    @objc private func toggleGIFSearch() {
        gifSearchPane.isHidden.toggle()
        if let rootStack {
            rootStack.layoutSubtreeIfNeeded()
            window?.setContentSize(NSSize(width: 740, height: max(480, rootStack.fittingSize.height)))
        }
        window?.center()
    }

    @objc private func previewPopupGIF() {
        preview(query: popupSearch.stringValue, into: popupPreview, status: popupStatus,
                action: onPreviewPopup, defaultStatus: "Showing the sample cat visit.",
                resultStatus: "Showing a random cat visit on your screen.")
    }
    @objc private func previewBreakGIF() {
        preview(query: breakSearch.stringValue, into: breakPreview, status: breakStatus,
                action: onPreviewBreak, defaultStatus: "Starting a three-second sample break.",
                resultStatus: "Starting a three-second break.")
    }

    private func preview(query: String, into target: AnimatedPreviewView, status: NSTextField,
                         action: @escaping (AnimatedImage?) -> Void, defaultStatus: String,
                         resultStatus: String) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            status.stringValue = defaultStatus
            action(target.image)
            return
        }
        status.stringValue = "Looking for a GIF…"
        OnlineGIF.random(from: query) { [weak self, weak target, weak status] image in
            guard let self, !self.didFinish else { return }
            guard let image else {
                status?.stringValue = "No match found. Showing the sample instead."
                action(target?.image)
                return
            }
            target?.image = image
            status?.stringValue = resultStatus
            action(image)
        }
    }

    @objc private func startTapped() { finish() }

    private func finish() {
        guard !didFinish else { return }
        didFinish = true
        popupPreview.stopAnimating()
        breakPreview.stopAnimating()
        onFinish(popupSearch.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                 breakSearch.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        window?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) { finish() }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let peeker = CatPeeker()
    private let overlay = BreakOverlay()
    private let headsUp = HeadsUp()
    private var onboardingController: OnboardingWindowController?
    private var onboardingActive = false
    private var scheduledFeaturesStarted = false
    private var peekTimer: Timer?
    private var breakTimer: Timer?
    private var nextBreak: Date?
    private var breakWaiting = false
    private var shareWatch: Timer?
    private var lastBreakEnd = Date.distantPast
    private let nextBreakItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private lazy var settingsController = SettingsWindowController { [weak self] in self?.settingsChanged() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.register()
        #if DEMO_CAPTURE
        let launchArguments = ProcessInfo.processInfo.arguments
        Settings.demoSequenceMode = launchArguments.contains("--demo-sequence")
        Settings.demoMode = launchArguments.contains("--demo-mode") || Settings.demoSequenceMode
        #endif
        Settings.migrateLegacyImages()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🐈"

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(nextBreakItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Call the cat", action: #selector(peekNow), keyEquivalent: "c"))
        menu.addItem(NSMenuItem(title: "Start break countdown", action: #selector(startCountdown), keyEquivalent: "t"))
        menu.addItem(NSMenuItem(title: "Take a break now", action: #selector(breakNow), keyEquivalent: "b"))
#if DEMO_CAPTURE
        menu.addItem(.separator())
        let demoModeItem = NSMenuItem(title: "Demo Mode (capture overlays while sharing)", action: #selector(toggleDemoMode(_:)), keyEquivalent: "")
        demoModeItem.state = Settings.demoMode ? .on : .off
        menu.addItem(demoModeItem)
#endif
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Stray Cat", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.items.forEach { if $0.action != nil && $0.action != #selector(NSApplication.terminate(_:)) { $0.target = self } }
        statusItem.menu = menu

        // If macOS hides our menu bar items (crowded bar, notch, or a per-app toggle in
        // System Settings > Menu Bar), open Settings so the app is still reachable.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            let visible = self.statusItem.button?.window?.isVisible == true
                && self.statusItem.button?.window?.occlusionState.contains(.visible) == true
            if !visible && !self.onboardingActive { self.openSettings() }
        }

        // A cat that is already up when a screen share starts leaves immediately.
        shareWatch = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self, self.peeker.busy, ShareGuard.isSharing() else { return }
            self.peeker.dismissNow()
        }

        var showOnboarding = Settings.shouldShowOnboarding()
#if DEMO_CAPTURE
        if launchArguments.contains("--demo-sequence") { showOnboarding = false }
#endif
        if showOnboarding {
            onboardingActive = true
            onboardingController = OnboardingWindowController(
                onPreviewPopup: { [weak self] image in self?.previewPopup(image: image) },
                onPreviewBreak: { [weak self] image in self?.previewBreak(image: image) },
                onFinish: { [weak self] popupSearch, breakSearch in
                    self?.finishOnboarding(popupSearch: popupSearch, breakSearch: breakSearch)
                }
            )
            onboardingController?.present()
        } else {
            startScheduledFeatures()
        }
#if DEMO_CAPTURE
        if launchArguments.contains("--demo-sequence") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                self?.startBreak(warn: true, countdown: 3)
            }
        }
#endif
    }

    private func finishOnboarding(popupSearch: String, breakSearch: String) {
        if !popupSearch.isEmpty {
            Settings.popupOnlineURL = popupSearch
            Settings.popupOnlineGifs = true
        }
        if !breakSearch.isEmpty {
            Settings.onlineURL = breakSearch
            Settings.onlineGifs = true
        }
        Settings.markOnboardingComplete()
        onboardingActive = false
        startScheduledFeatures()
    }

    private func previewPopup(image: AnimatedImage?) {
        peeker.preview(image: image, nextBreak: nextBreak)
    }

    private func previewBreak(image: AnimatedImage?) {
        overlay.show(durationOverride: 3, imageOverride: image, showMessageOverride: true) { _ in }
    }

    private func startScheduledFeatures() {
        guard !scheduledFeaturesStarted else { return }
        scheduledFeaturesStarted = true
        scheduleBreak(after: Settings.breakInterval)
        schedulePeek()
        if Settings.catEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self else { return }
                self.peeker.peek(nextBreak: self.nextBreak)
            }
        }
    }

    private func schedulePeek() {
        peekTimer?.invalidate()
        peekTimer = nil
        guard Settings.catEnabled else { return }
        peekTimer = Timer.scheduledTimer(withTimeInterval: .random(in: Settings.peekDelayRange), repeats: false) { [weak self] _ in
            guard let self else { return }
            if !self.overlay.isShowing && !self.headsUp.isShowing { self.peeker.peek(nextBreak: self.nextBreak) }
            self.schedulePeek()
        }
    }

    private func scheduleBreak(after delay: TimeInterval) {
        breakTimer?.invalidate()
        breakTimer = nil
        nextBreak = nil
        breakWaiting = false
        guard Settings.breaksEnabled else { return }
        nextBreak = Date().addingTimeInterval(delay)
        breakTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.startBreak()
        }
    }

    /// Starts the break flow: an optional heads-up countdown first, then the dimmed break screen.
    private func startBreak(warn: Bool = true, countdown: Int? = nil) {
        guard !onboardingActive, !overlay.isShowing, !headsUp.isShowing else { return }
        // Never dim the screen while it may be visible to other people; retry shortly.
#if DEMO_CAPTURE
        let canStartWhileSharing = Settings.demoMode
#else
        let canStartWhileSharing = false
#endif
        if !canStartWhileSharing && ShareGuard.isSharing() {
            breakWaiting = true
            breakTimer?.invalidate()
            nextBreak = Date().addingTimeInterval(30)
            breakTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in self?.startBreak() }
            return
        }
        breakWaiting = false
        peeker.dismissNow()

        let warnSeconds = countdown ?? Settings.warnSeconds
        if warn && warnSeconds > 0 {
            breakTimer?.invalidate()
            breakTimer = nil
            nextBreak = Date().addingTimeInterval(TimeInterval(warnSeconds))
            headsUp.show(seconds: warnSeconds) { [weak self] outcome in
                switch outcome {
                case .start: self?.beginBreak()
                case .skip: self?.scheduleBreak(after: Settings.breakInterval)
                case .snooze: self?.scheduleBreak(after: TimeInterval(Settings.snoozeMinutes * 60))
                case .interrupted: self?.startBreak()  // a share is on: waits and retries
                }
            }
            return
        }
        beginBreak()
    }

    private func beginBreak() {
        nextBreak = nil
        overlay.show { [weak self] snoozed in
            self?.lastBreakEnd = Date()
            self?.scheduleBreak(after: snoozed ? TimeInterval(Settings.snoozeMinutes * 60) : Settings.breakInterval)
        }
    }

    /// Re-arms both timers so edited intervals and toggles take effect right away.
    private func settingsChanged() {
        if !overlay.isShowing && !headsUp.isShowing { scheduleBreak(after: Settings.breakInterval) }
        if headsUp.isShowing && !Settings.breaksEnabled {
            headsUp.cancel()
            nextBreak = nil
        }
        schedulePeek()
    }

    @objc private func peekNow() {
        if !onboardingActive && !overlay.isShowing && !headsUp.isShowing { peeker.peek(nextBreak: nextBreak) }
    }

#if DEMO_CAPTURE
    @objc private func toggleDemoMode(_ sender: NSMenuItem) {
        Settings.demoMode.toggle()
        sender.state = Settings.demoMode ? .on : .off
        let sharingType = Settings.overlaySharingType
        peeker.setSharingType(sharingType)
        headsUp.setSharingType(sharingType)
        overlay.setSharingType(sharingType)
    }
#endif

    @objc private func breakNow() {
        // Ignore repeats while a break is up or has only just ended (its fade-out counts as ending).
        guard !overlay.isShowing, !headsUp.isShowing, Date().timeIntervalSince(lastBreakEnd) > 3 else { return }
        startBreak(warn: false)
    }
    @objc private func startCountdown() {
        guard !overlay.isShowing, !headsUp.isShowing, Date().timeIntervalSince(lastBreakEnd) > 3 else { return }
        // Always shows the countdown, even if "Warn me first" is set to 0.
        startBreak(countdown: max(Settings.warnSeconds, 15))
    }
    @objc private func openSettings() {
        if onboardingActive { onboardingController?.finishWithDefaults() }
        settingsController.present()
    }

    /// Launching the app again (Finder, Spotlight, `open`) opens Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if onboardingActive {
            onboardingController?.present()
            return true
        }
        openSettings()
        return true
    }

    func menuWillOpen(_ menu: NSMenu) {
        if onboardingActive {
            nextBreakItem.title = "Finish setup to start reminders"
        } else if headsUp.isShowing {
            nextBreakItem.title = "Break starting soon"
        } else if overlay.isShowing {
            nextBreakItem.title = "Break in progress"
        } else if breakWaiting {
            nextBreakItem.title = "Break waiting for screen share to end"
        } else if let nextBreak {
            let mins = max(0, Int((nextBreak.timeIntervalSinceNow / 60).rounded(.up)))
            nextBreakItem.title = "Next break in \(mins) min"
        } else {
            nextBreakItem.title = "Break reminders are off"
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
