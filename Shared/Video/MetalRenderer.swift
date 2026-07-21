import Foundation
import Metal
import MetalKit
import CoreVideo

/// Metal-based video renderer for displaying decoded frames
final class MetalRenderer: NSObject {

    // MARK: - Properties

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?

    private var currentTexture: MTLTexture?
    private let textureLock = NSLock()

    // Track frame count for periodic cache flush
    private var framesSinceLastFlush: Int = 0
    private let flushInterval: Int = 60  // Flush cache every 60 frames

    private weak var metalView: MTKView?

    // Vertex data for full-screen quad
    private let vertices: [Float] = [
        -1.0, -1.0, 0.0, 1.0,  // Bottom-left
         1.0, -1.0, 1.0, 1.0,  // Bottom-right
        -1.0,  1.0, 0.0, 0.0,  // Top-left
         1.0,  1.0, 1.0, 0.0   // Top-right
    ]
    private var vertexBuffer: MTLBuffer?

    // Cursor overlay state (Mac receiver mode)
    private var cursorPipelineState: MTLRenderPipelineState?
    private var cursorTexture: MTLTexture?
    private var cursorHotspot: (x: Float, y: Float) = (0, 0)
    private var cursorPosition: (x: Float, y: Float) = (0, 0)
    private var cursorVisible = false
    private let cursorLock = NSLock()
    private let textureLoader: MTKTextureLoader

    // MARK: - Initialization

    init?(metalView: MTKView) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("MetalRenderer: No Metal device available")
            return nil
        }

        guard let commandQueue = device.makeCommandQueue() else {
            print("MetalRenderer: Failed to create command queue")
            return nil
        }

        self.device = device
        self.commandQueue = commandQueue
        self.metalView = metalView
        self.textureLoader = MTKTextureLoader(device: device)

        // Create texture cache
        var cache: CVMetalTextureCache?
        let cacheStatus = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            device,
            nil,
            &cache
        )
        guard cacheStatus == kCVReturnSuccess, let cache = cache else {
            print("MetalRenderer: Failed to create texture cache")
            return nil
        }
        self.textureCache = cache

        // Create pipeline state
        guard let library = device.makeDefaultLibrary() else {
            print("MetalRenderer: Failed to create shader library")
            return nil
        }

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = library.makeFunction(name: "vertexShader")
        pipelineDescriptor.fragmentFunction = library.makeFunction(name: "fragmentShader")
        pipelineDescriptor.colorAttachments[0].pixelFormat = metalView.colorPixelFormat

        do {
            self.pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            print("MetalRenderer: Failed to create pipeline state: \(error)")
            return nil
        }

        let cursorDescriptor = MTLRenderPipelineDescriptor()
        cursorDescriptor.vertexFunction = library.makeFunction(name: "vertexShader")
        cursorDescriptor.fragmentFunction = library.makeFunction(name: "fragmentShader")
        cursorDescriptor.colorAttachments[0].pixelFormat = metalView.colorPixelFormat
        cursorDescriptor.colorAttachments[0].isBlendingEnabled = true
        cursorDescriptor.colorAttachments[0].rgbBlendOperation = .add
        cursorDescriptor.colorAttachments[0].alphaBlendOperation = .add
        cursorDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        cursorDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        cursorDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        cursorDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        do {
            self.cursorPipelineState = try device.makeRenderPipelineState(descriptor: cursorDescriptor)
        } catch {
            print("MetalRenderer: Failed to create cursor pipeline state: \(error)")
            self.cursorPipelineState = nil
        }

        super.init()

        // Create vertex buffer
        vertexBuffer = device.makeBuffer(
            bytes: vertices,
            length: vertices.count * MemoryLayout<Float>.stride,
            options: .storageModeShared
        )

        // Configure metal view
        metalView.device = device
        metalView.delegate = self
        metalView.framebufferOnly = true
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.isPaused = false
        metalView.enableSetNeedsDisplay = false

        // Match stream frame rate
        metalView.preferredFramesPerSecond = 60
    }

    deinit {
        // Clear texture reference
        textureLock.lock()
        currentTexture = nil
        textureLock.unlock()

        // Flush texture cache to release all cached textures
        if let cache = textureCache {
            CVMetalTextureCacheFlush(cache, 0)
        }
        textureCache = nil
    }

    // MARK: - Public Methods

    private static var displayCount = 0

    /// Updates the displayed frame with a new pixel buffer
    /// - Parameter pixelBuffer: The decoded video frame
    func display(pixelBuffer: CVPixelBuffer) {
        guard let textureCache = textureCache else {
            print("MetalRenderer: No texture cache")
            return
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)

        Self.displayCount += 1
        if Self.displayCount % 30 == 1 {
            print("MetalRenderer: Displaying frame \(Self.displayCount) - \(width)x\(height), format=\(pixelFormat)")
        }

        // Create Metal texture from pixel buffer
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTexture
        )

        guard status == kCVReturnSuccess, let cvTexture = cvTexture else {
            print("MetalRenderer: Failed to create texture from pixel buffer, status=\(status)")
            return
        }

        guard let texture = CVMetalTextureGetTexture(cvTexture) else {
            print("MetalRenderer: Failed to get Metal texture")
            return
        }

        textureLock.lock()
        currentTexture = texture
        textureLock.unlock()

        // Periodically flush the texture cache to prevent memory accumulation
        framesSinceLastFlush += 1
        if framesSinceLastFlush >= flushInterval {
            CVMetalTextureCacheFlush(textureCache, 0)
            framesSinceLastFlush = 0
        }
    }

    /// Clears the current texture and flushes the cache
    func clear() {
        textureLock.lock()
        currentTexture = nil
        textureLock.unlock()

        // Flush the texture cache when clearing
        if let cache = textureCache {
            CVMetalTextureCacheFlush(cache, 0)
        }
        framesSinceLastFlush = 0
    }

    /// Sets the cursor image from PNG data. Hotspot is in image pixel coordinates.
    func setCursorImage(pngData: Data, hotspotX: Float, hotspotY: Float) {
        do {
            let texture = try textureLoader.newTexture(
                data: pngData,
                options: [.SRGB: false, .textureUsage: MTLTextureUsage.shaderRead.rawValue]
            )
            cursorLock.lock()
            cursorTexture = texture
            cursorHotspot = (hotspotX, hotspotY)
            cursorLock.unlock()
        } catch {
            print("MetalRenderer: Failed to load cursor texture: \(error)")
        }
    }

    /// Updates the cursor position (normalized 0.0-1.0 in stream coordinates).
    func setCursorPosition(x: Float, y: Float, visible: Bool) {
        cursorLock.lock()
        cursorPosition = (x, y)
        cursorVisible = visible
        cursorLock.unlock()
    }

    /// Removes the cursor overlay entirely.
    func clearCursor() {
        cursorLock.lock()
        cursorTexture = nil
        cursorVisible = false
        cursorLock.unlock()
    }
}

// MARK: - MTKViewDelegate

extension MetalRenderer: MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Handle size changes if needed
    }

    func draw(in view: MTKView) {
        textureLock.lock()
        let texture = currentTexture
        textureLock.unlock()

        guard let texture = texture else { return }
        guard let drawable = view.currentDrawable else { return }
        guard let renderPassDescriptor = view.currentRenderPassDescriptor else { return }

        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        renderPassDescriptor.colorAttachments[0].loadAction = .clear

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return }

        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        renderEncoder.setFragmentTexture(texture, index: 0)
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        // Cursor overlay (Mac receiver mode)
        cursorLock.lock()
        let cTexture = cursorTexture
        let cVisible = cursorVisible
        let cPos = cursorPosition
        let cHotspot = cursorHotspot
        cursorLock.unlock()

        if cVisible, let cTexture = cTexture, let cursorPipeline = cursorPipelineState {
            let drawableW = Float(view.drawableSize.width)
            let drawableH = Float(view.drawableSize.height)
            let cursorW = Float(cTexture.width)
            let cursorH = Float(cTexture.height)

            // Top-left of cursor quad in drawable pixels
            let px = cPos.x * drawableW - cHotspot.x
            let py = cPos.y * drawableH - cHotspot.y

            // Convert to NDC (y flipped: NDC +1 is top)
            let x0 = (px / drawableW) * 2 - 1
            let x1 = ((px + cursorW) / drawableW) * 2 - 1
            let y0 = 1 - (py / drawableH) * 2
            let y1 = 1 - ((py + cursorH) / drawableH) * 2

            // Same layout as `vertices`: x, y, u, v — triangle strip
            let cursorVertices: [Float] = [
                x0, y1, 0.0, 1.0,  // Bottom-left
                x1, y1, 1.0, 1.0,  // Bottom-right
                x0, y0, 0.0, 0.0,  // Top-left
                x1, y0, 1.0, 0.0   // Top-right
            ]

            renderEncoder.setRenderPipelineState(cursorPipeline)
            renderEncoder.setVertexBytes(cursorVertices, length: cursorVertices.count * MemoryLayout<Float>.stride, index: 0)
            renderEncoder.setFragmentTexture(cTexture, index: 0)
            renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        renderEncoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
