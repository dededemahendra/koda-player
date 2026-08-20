import AppKit
import CMPV
import OpenGL.GL
import OpenGL.GL3

/// Resolves OpenGL entry points for libmpv's render API.
private func openGLProcAddress(_ context: UnsafeMutableRawPointer?, _ name: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
    guard let name,
          let bundle = CFBundleGetBundleWithIdentifier("com.apple.opengl" as CFString) else { return nil }
    let symbol = CFStringCreateWithCString(kCFAllocatorDefault, name, kCFStringEncodingASCII)
    return CFBundleGetFunctionPointerForName(bundle, symbol)
}

/// Called by mpv (on an arbitrary thread) whenever a new frame is ready to draw.
private func renderUpdateCallback(_ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let view = Unmanaged<MPVVideoView>.fromOpaque(context).takeUnretainedValue()
    view.requestRender()
}

/// The surface mpv draws video into.
///
/// mpv hands us decoded frames through `MPV_RENDER_API_TYPE_OPENGL`; drawing happens on a
/// dedicated queue so a heavy 4K frame never stalls the UI. AppKit controls layered on top
/// of this view composite normally because the whole hierarchy is layer backed.
final class MPVVideoView: NSOpenGLView {
    private var renderContext: OpaquePointer?
    private let renderQueue = DispatchQueue(label: "com.koda.player.render", qos: .userInteractive)
    /// Guards the render context's lifetime against the render queue.
    private let renderLock = NSLock()
    /// Separate from `renderLock` on purpose: the main thread updates the drawable size on
    /// every resize, and `renderLock` is held across a vsync-blocking `flushBuffer`. Sharing
    /// one lock would let a stalled swap block the main thread.
    private let sizeLock = NSLock()
    private var hasDumpedFrame = false
    private let startedAt = Date()

    /// Backing-store pixel size, cached so the render thread never touches AppKit geometry.
    private var _drawableSize = CGSize(width: 1, height: 1)
    private var drawableSize: CGSize {
        get { sizeLock.lock(); defer { sizeLock.unlock() }; return _drawableSize }
        set { sizeLock.lock(); _drawableSize = newValue; sizeLock.unlock() }
    }

    init(player: MPVPlayer) {
        let attributes: [NSOpenGLPixelFormatAttribute] = [
            UInt32(NSOpenGLPFAOpenGLProfile), UInt32(NSOpenGLProfileVersion3_2Core),
            UInt32(NSOpenGLPFAAccelerated),
            UInt32(NSOpenGLPFADoubleBuffer),
            UInt32(NSOpenGLPFAAllowOfflineRenderers),
            UInt32(NSOpenGLPFAColorSize), 24,
            UInt32(NSOpenGLPFAAlphaSize), 8,
            UInt32(NSOpenGLPFADepthSize), 0,
            0
        ]
        guard let pixelFormat = NSOpenGLPixelFormat(attributes: attributes) else {
            fatalError("Could not create an OpenGL pixel format for video output")
        }
        super.init(frame: .zero, pixelFormat: pixelFormat)!

        wantsBestResolutionOpenGLSurface = true
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize

        openGLContext?.makeCurrentContext()
        var swapInterval: GLint = 1
        openGLContext?.setValues(&swapInterval, for: .swapInterval)

        createRenderContext(for: player)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    deinit {
        destroyRenderContext()
    }

    // MARK: - Render context

    private func createRenderContext(for player: MPVPlayer) {
        guard let mpv = player.handle else { return }

        var initParams = mpv_opengl_init_params(
            get_proc_address: openGLProcAddress,
            get_proc_address_ctx: nil
        )
        var advancedControl: CInt = 1

        let apiType = UnsafeMutableRawPointer(mutating: (MPV_RENDER_API_TYPE_OPENGL as NSString).utf8String)

        withUnsafeMutablePointer(to: &initParams) { initParamsPointer in
            withUnsafeMutablePointer(to: &advancedControl) { advancedPointer in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: apiType),
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: initParamsPointer),
                    mpv_render_param(type: MPV_RENDER_PARAM_ADVANCED_CONTROL, data: advancedPointer),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
                ]
                let result = mpv_render_context_create(&renderContext, mpv, &params)
                if result < 0 {
                    fatalError("mpv render context failed: \(String(cString: mpv_error_string(result)))")
                }
            }
        }

        mpv_render_context_set_update_callback(
            renderContext,
            renderUpdateCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    func destroyRenderContext() {
        renderLock.lock()
        defer { renderLock.unlock() }
        guard let renderContext else { return }
        mpv_render_context_set_update_callback(renderContext, nil, nil)
        mpv_render_context_free(renderContext)
        self.renderContext = nil
    }

    // MARK: - Drawing

    /// Coalesces mpv's update notifications into one draw per frame.
    /// `force` redraws the last frame even when mpv has nothing new — needed on resize,
    /// where skipping the draw would leave a stretched or blank surface behind.
    func requestRender(force: Bool = false) {
        renderQueue.async { [weak self] in
            self?.drawFrame(force: force)
        }
    }

    private func drawFrame(force: Bool = false) {
        renderLock.lock()
        defer { renderLock.unlock() }

        guard let context = openGLContext, let cglContext = context.cglContextObj else { return }
        guard let renderContext else {
            // Nothing to draw yet (or already torn down) — paint the letterbox black.
            clear()
            return
        }
        let hasNewFrame = mpv_render_context_update(renderContext) & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0
        guard hasNewFrame || force else { return }

        CGLLockContext(cglContext)
        defer { CGLUnlockContext(cglContext) }
        context.makeCurrentContext()

        let size = drawableSize
        var fbo = mpv_opengl_fbo(
            fbo: 0,
            w: Int32(size.width),
            h: Int32(size.height),
            internal_format: 0
        )
        var flipY: CInt = 1

        withUnsafeMutablePointer(to: &fbo) { fboPointer in
            withUnsafeMutablePointer(to: &flipY) { flipPointer in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: fboPointer),
                    mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: flipPointer),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
                ]
                mpv_render_context_render(renderContext, &params)
            }
        }

        dumpFrameIfRequested()
        context.flushBuffer()
        mpv_render_context_report_swap(renderContext)
    }

    /// Diagnostic hook: set `KODA_FRAME_DUMP=/path/frame.png` to write a rendered frame
    /// straight out of the GL back buffer. Handy for checking the render path on a machine
    /// where you can't watch the screen. `KODA_FRAME_DUMP_DELAY` (seconds, default 2) skips
    /// the first renders, which happen before any video frame has been decoded.
    private func dumpFrameIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["KODA_FRAME_DUMP"], !hasDumpedFrame else { return }
        let delay = ProcessInfo.processInfo.environment["KODA_FRAME_DUMP_DELAY"].flatMap(Double.init) ?? 2
        guard Date().timeIntervalSince(startedAt) >= delay else { return }
        let size = drawableSize
        let width = Int(size.width)
        let height = Int(size.height)
        guard width > 1, height > 1 else { return }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        glReadBuffer(GLenum(GL_BACK))
        glPixelStorei(GLenum(GL_PACK_ALIGNMENT), 1)
        glReadPixels(0, 0, GLsizei(width), GLsizei(height), GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), &pixels)

        // OpenGL hands back rows bottom-up; flip them for the image.
        let rowBytes = width * 4
        var flipped = [UInt8](repeating: 0, count: pixels.count)
        for row in 0..<height {
            let source = (height - 1 - row) * rowBytes
            flipped.replaceSubrange(row * rowBytes..<(row + 1) * rowBytes, with: pixels[source..<source + rowBytes])
        }

        hasDumpedFrame = true
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: rowBytes, bitsPerPixel: 32
        ) else { return }
        flipped.withUnsafeBufferPointer { buffer in
            guard let base = bitmap.bitmapData, let source = buffer.baseAddress else { return }
            base.update(from: source, count: buffer.count)
        }
        if let png = bitmap.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }

    /// Paints the letterbox area black so resizing never flashes the window background.
    private func clear() {
        guard let context = openGLContext, let cglContext = context.cglContextObj else { return }
        CGLLockContext(cglContext)
        defer { CGLUnlockContext(cglContext) }
        context.makeCurrentContext()
        glClearColor(0, 0, 0, 1)
        glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
        context.flushBuffer()
    }

    // MARK: - Geometry

    override func reshape() {
        super.reshape()
        updateDrawableSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
        requestRender(force: true)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
        requestRender(force: true)
    }

    private func updateDrawableSize() {
        let backing = convertToBacking(bounds).size
        drawableSize = CGSize(width: max(1, backing.width), height: max(1, backing.height))
        openGLContext?.update()
    }

    override func draw(_ dirtyRect: NSRect) {
        // AppKit-driven redraws (first display, live resize) go through the same path.
        requestRender(force: true)
    }

    // Input is handled by the container view, not here.
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
