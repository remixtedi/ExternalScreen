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

    /// Clockwise rotation applied when rendering the stream (0/90/180/270 degrees).
    /// Guarded by `textureLock` alongside `currentTexture` — set from the transport's
    /// background queue on displayConfig, read in `draw(in:)`.
    private var rotationDegrees: Int = 0

    /// Full-screen quad with texture coordinates permuted so the stream appears
    /// rotated clockwise by `degrees` on the drawable. Layout: x, y, u, v per vertex,
    /// triangle-strip order BL, BR, TL, TR.
    private static func quadVertices(rotatedBy degrees: Int) -> [Float] {
        switch degrees {
        case 90:
            return [
                -1.0, -1.0, 1.0, 1.0,
                 1.0, -1.0, 1.0, 0.0,
                -1.0,  1.0, 0.0, 1.0,
                 1.0,  1.0, 0.0, 0.0
            ]
        case 180:
            return [
                -1.0, -1.0, 1.0, 0.0,
                 1.0, -1.0, 0.0, 0.0,
                -1.0,  1.0, 1.0, 1.0,
                 1.0,  1.0, 0.0, 1.0
            ]
        case 270:
            return [
                -1.0, -1.0, 0.0, 0.0,
                 1.0, -1.0, 0.0, 1.0,
                -1.0,  1.0, 1.0, 0.0,
                 1.0,  1.0, 1.0, 1.0
            ]
        default:
            return [
                -1.0, -1.0, 0.0, 1.0,
                 1.0, -1.0, 1.0, 1.0,
                -1.0,  1.0, 0.0, 0.0,
                 1.0,  1.0, 1.0, 0.0
            ]
        }
    }

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

    /// Sets the clockwise rotation applied when rendering (0/90/180/270 degrees).
    /// Values that aren't multiples of 90 are ignored.
    func setRotation(_ degrees: Int) {
        let normalized = ((degrees % 360) + 360) % 360
        guard normalized % 90 == 0 else {
            print("MetalRenderer: Ignoring unsupported rotation \(degrees)")
            return
        }
        textureLock.lock()
        rotationDegrees = normalized
        textureLock.unlock()
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
        let rotation = rotationDegrees
        textureLock.unlock()

        guard let texture = texture else { return }
        guard let drawable = view.currentDrawable else { return }
        guard let renderPassDescriptor = view.currentRenderPassDescriptor else { return }

        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        renderPassDescriptor.colorAttachments[0].loadAction = .clear

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return }

        renderEncoder.setRenderPipelineState(pipelineState)
        if rotation == 0 {
            renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        } else {
            let rotatedVertices = Self.quadVertices(rotatedBy: rotation)
            renderEncoder.setVertexBytes(rotatedVertices, length: rotatedVertices.count * MemoryLayout<Float>.stride, index: 0)
        }
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
            // Cursor position/hotspot are in STREAM space (the host display's pixel
            // grid, matching the video texture), not drawable space — with rotation
            // the two differ (portrait stream on a landscape drawable). Build the
            // cursor quad in normalized stream coordinates, then map each corner
            // through the same rotation as the video quad so the overlay stays
            // attached to the content and rotates with it.
            let streamW = Float(texture.width)
            let streamH = Float(texture.height)
            let cursorW = Float(cTexture.width)
            let cursorH = Float(cTexture.height)

            // Top-left of cursor quad in stream pixels
            let px = cPos.x * streamW - cHotspot.x
            let py = cPos.y * streamH - cHotspot.y

            // Corners in normalized stream space with their texture coordinates.
            // Triangle-strip order: TL, TR, BL, BR.
            let corners: [(nx: Float, ny: Float, u: Float, v: Float)] = [
                (px / streamW, py / streamH, 0.0, 0.0),
                ((px + cursorW) / streamW, py / streamH, 1.0, 0.0),
                (px / streamW, (py + cursorH) / streamH, 0.0, 1.0),
                ((px + cursorW) / streamW, (py + cursorH) / streamH, 1.0, 1.0)
            ]

            var cursorVertices: [Float] = []
            cursorVertices.reserveCapacity(16)
            for corner in corners {
                let vx: Float
                let vy: Float
                switch rotation {
                case 90:  (vx, vy) = (1 - corner.ny, corner.nx)
                case 180: (vx, vy) = (1 - corner.nx, 1 - corner.ny)
                case 270: (vx, vy) = (corner.ny, 1 - corner.nx)
                default:  (vx, vy) = (corner.nx, corner.ny)
                }
                // Convert to NDC (y flipped: NDC +1 is top)
                cursorVertices.append(contentsOf: [vx * 2 - 1, 1 - vy * 2, corner.u, corner.v])
            }

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
