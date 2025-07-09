// BrowserExtensionActiveManager.swift
// BrowserExtensionActiveManager.swift
// Manages active extensions and their runtime objects

import BrowserExtensionShared
import Foundation
import WebKit

/// Weak reference wrapper for holding weak references in collections
class WeakBox<T> {
    private weak var _value: AnyObject?
    var value: T? {
        _value as? T
    }
    init(_ value: T?) {
        _value = value as AnyObject?
    }
}

/// Defines the role/type of a webview for script injection customization
public enum WebViewRole {
    case userFacing     // User-visible webview - gets content scripts + Chrome APIs
    case backgroundScript(UUID) // Background service worker - gets Chrome APIs + DOM nuke + console handler
}

/// Per-webview state tracking
class WebViewState {
    weak var webView: BrowserExtensionWKWebView?
    let userContentManager: BrowserExtensionUserContentManager
    let role: WebViewRole

    /// Used to ensure we don't register handlers more than once per world.
    var contentWorldsWithHandlers: Set<String> = []
    
    /// Track whether we've already injected background script support for this webview
    var hasBackgroundScriptSupport: Bool = false

    init(webView: BrowserExtensionWKWebView, userContentManager: BrowserExtensionUserContentManager, role: WebViewRole) {
        self.webView = webView
        self.userContentManager = userContentManager
        self.role = role
    }
}

/// Runtime data for an active extension
@MainActor
public class ActiveExtension {
    /// The extension's static data and manifest
    public let browserExtension: BrowserExtension
    
    /// The content world for this extension's scripts
    public let contentWorld: WKContentWorld
    
    /// When this extension was activated
    public let activatedAt: Date
    
    internal init(browserExtension: BrowserExtension, contentWorld: WKContentWorld) {
        self.browserExtension = browserExtension
        self.contentWorld = contentWorld
        self.activatedAt = Date()
    }
}

/// Protocol for managing active extensions
@MainActor
public protocol BrowserExtensionActiveManagerProtocol: AnyObject {
    /// Activate an extension with its runtime objects
    /// - Parameter browserExtension: The extension to activate
    func activate(_ browserExtension: BrowserExtension) async

    /// Deactivate an extension and clean up its runtime objects
    /// - Parameter extensionId: The unique identifier for the extension
    func deactivate(_ extensionId: UUID) async
    
    /// Get an active extension by ID
    /// - Parameter extensionId: The unique identifier for the extension
    /// - Returns: The active extension if found
    func activeExtension(for extensionId: UUID) -> ActiveExtension?
    
    /// Get all active extensions
    /// - Returns: Dictionary of extension IDs to active extensions
    func allActiveExtensions() -> [UUID: ActiveExtension]
    
    /// Check if an extension is active
    /// - Parameter extensionId: The unique identifier for the extension
    /// - Returns: True if the extension is active
    func isActive(_ extensionId: UUID) -> Bool
    
    /// Deactivate all extensions
    func deactivateAll() async

    /// Register a webview to receive injection script updates
    /// - Parameters:
    ///   - webView: The webview to register
    ///   - role: The role of the webview (userFacing or backgroundScript)
    func registerWebView(_ webView: BrowserExtensionWKWebView,
                         userContentManager: BrowserExtensionUserContentManager,
                         role: WebViewRole) async throws

    /// Unregister a webview from injection script updates
    /// - Parameter webView: The webview to unregister
    func unregisterWebView(_ webView: BrowserExtensionWKWebView)
}

/// Manages active extensions and their runtime objects
@MainActor
public class BrowserExtensionActiveManager: BrowserExtensionActiveManagerProtocol, BrowserExtensionRouterDataSource {
    
    private var activeExtensions: [UUID: ActiveExtension] = [:]
    private var webViewStates: [ObjectIdentifier: WebViewState] = [:]
    private let injectionScriptGenerator: BrowserExtensionContentScriptInjectionGeneratorProtocol
    private let userScriptFactory: BrowserExtensionUserScriptFactoryProtocol
    private var backgroundService: BrowserExtensionBackgroundServiceProtocol
    private let network: BrowserExtensionNetwork
    private let router: BrowserExtensionRouter
    private let logger: BrowserExtensionLogger
    private let callbackHandler: BrowserExtensionSecureCallbackHandler

    public init(
        injectionScriptGenerator: BrowserExtensionContentScriptInjectionGeneratorProtocol,
        userScriptFactory: BrowserExtensionUserScriptFactoryProtocol,
        backgroundService: BrowserExtensionBackgroundServiceProtocol,
        network: BrowserExtensionNetwork,
        router: BrowserExtensionRouter,
        logger: BrowserExtensionLogger
    ) {
        self.injectionScriptGenerator = injectionScriptGenerator
        self.userScriptFactory = userScriptFactory
        self.backgroundService = backgroundService
        self.network = network
        self.router = router
        self.logger = logger
        callbackHandler = BrowserExtensionSecureCallbackHandler(
            logger: logger,
            function: .invokeCallback)
        // Set ourselves as the data source for the router
        router.dataSource = self
        
        // Set ourselves as the delegate for the background service to provide content worlds
        self.backgroundService.activeManagerDelegate = self
    }
    
    /// Activate an extension with its runtime objects
    /// - Parameter browserExtension: The extension to activate
    public func activate(_ browserExtension: BrowserExtension) async {
        await logger.inContext("Activate extension \(browserExtension.id)") {
            let extensionId = browserExtension.id
            
            // Check if already active
            if activeExtensions[extensionId] != nil {
                logger.fatalError("Extension with ID \(extensionId) is already active")
            }
            logger.info("Activating extension with ID: \(extensionId)")
            
            // Create content world for this extension
            let worldName = "Extension-\(extensionId.uuidString)"
            let contentWorld = WKContentWorld.world(name: worldName)
            logger.debug("Created content world: \(worldName)")
            
            // Create active extension
            let activeExtension = ActiveExtension(browserExtension: browserExtension, contentWorld: contentWorld)
            activeExtensions[extensionId] = activeExtension
            
            // Register all existing webviews with the network for this extension
            for state in webViewStates.values {
                if let webView = state.webView {
                    network.add(webView: webView, browserExtension: browserExtension)
                }
            }
            
            // Update injection scripts in all registered webviews
            await updateInjectionScriptsInAllWebViews()
            logger.info("Successfully activated extension with ID: \(extensionId)")

            // TODO: In real life we need to track the listeners that background scripts have requested execution for and only launch it unconditionally after install or activate.
            do {
                let backgroundResult = try await backgroundService.startBackgroundScript(for: browserExtension)
                if let (backgroundWebView, contentManager) = backgroundResult {
                    // Register the background webview to get Chrome APIs injected
                    try await self.registerWebView(
                        backgroundWebView,
                        userContentManager: contentManager,
                        role: .backgroundScript(browserExtension.id))
                }
            } catch {
                logger.error("Failed to launch background service for \(browserExtension.baseURL.path): \(error)")
            }
        }
    }
    
    /// Deactivate an extension and clean up its runtime objects
    /// - Parameter extensionId: The unique identifier for the extension
    public func deactivate(_ extensionId: UUID) async {
        await logger.inContext("Deactivate extension \(extensionId)") {
            logger.info("Deactivating extension with ID: \(extensionId)")
            
            // Clean up console handlers for any background script webviews of this extension
            cleanupConsoleHandlersForExtension(extensionId)
            
            // Stop background script if it's running
            backgroundService.stopBackgroundScript(for: extensionId)
            
            // Remove scripts for this extension from all webviews
            removeScriptsForExtension(extensionId)
            
            activeExtensions.removeValue(forKey: extensionId)
            
            // Update injection scripts in all registered webviews
            await updateInjectionScriptsInAllWebViews()
            logger.info("Successfully deactivated extension with ID: \(extensionId)")
        }
    }
    
    /// Remove scripts for a specific extension from all webviews
    private func removeScriptsForExtension(_ extensionId: UUID) {
        logger.debug("Removing scripts for extension: \(extensionId)")
        
        // Remove scripts from all webviews
        for webViewState in webViewStates.values {
            let userContentManager = webViewState.userContentManager
            
            // Remove injection scripts
            userContentManager.remove(userScriptIdentifier: UserScripts.injectionScript(extensionId).identifier)
            
            // Remove Chrome API scripts (they're shared but we need to remove them to clean up)
            userContentManager.remove(userScriptIdentifier: UserScripts.chromeAPIs.identifier)
            
            // Remove the content world from the tracking set
            if let activeExtension = activeExtensions[extensionId],
               let worldName = activeExtension.contentWorld.name {
                webViewState.contentWorldsWithHandlers.remove(worldName)
            }
        }
    }
    
    /// Get an active extension by ID
    /// - Parameter extensionId: The unique identifier for the extension
    /// - Returns: The active extension if found
    public func activeExtension(for extensionId: UUID) -> ActiveExtension? {
        return activeExtensions[extensionId]
    }
    
    /// Get all active extensions
    /// - Returns: Dictionary of extension IDs to active extensions
    public func allActiveExtensions() -> [UUID: ActiveExtension] {
        return activeExtensions
    }
    
    /// Check if an extension is active
    /// - Parameter extensionId: The unique identifier for the extension
    /// - Returns: True if the extension is active
    public func isActive(_ extensionId: UUID) -> Bool {
        return activeExtensions[extensionId] != nil
    }
    
    /// Deactivate all extensions
    public func deactivateAll() async {
        // Clean up console handlers for all background script webviews
        for webViewState in webViewStates.values {
            if case .backgroundScript(let extensionId) = webViewState.role,
               let webView = webViewState.webView {
                cleanupConsoleHandlers(for: webView, extensionId: extensionId)
            }
        }
        
        // Stop all background scripts
        backgroundService.stopAllBackgroundScripts()
        
        // Remove scripts for all extensions from all webviews
        for extensionId in activeExtensions.keys {
            removeScriptsForExtension(extensionId)
        }
        
        activeExtensions.removeAll()
        
        // Update injection scripts in all registered webviews
        await updateInjectionScriptsInAllWebViews()
    }
    
    /// Register a webview to receive injection script updates
    /// - Parameters:
    ///   - webView: The webview to register
    ///   - role: The role of the webview (userFacing or backgroundScript)
    public func registerWebView(_ webView: BrowserExtensionWKWebView,
                                userContentManager: BrowserExtensionUserContentManager,
                                role: WebViewRole) async throws {
        await logger.inContext("Register webview \(webView)") {
            logger.debug("Registering webview \(webView) for injection script updates")
            // Clean up any deallocated webviews first
            cleanupDeallocatedWebViews()
            
            let id = ObjectIdentifier(webView)
            
            // Create or get webview state
            if webViewStates[id] == nil {
                webViewStates[id] = WebViewState(webView: webView,
                                                 userContentManager: userContentManager,
                                                 role: role)
            }

            // Register webview with network for each active extension
            for activeExtension in activeExtensions.values {
                network.add(webView: webView, browserExtension: activeExtension.browserExtension)
            }

            // Install current injection scripts
            logger.debug("About to update injection scripts for webview \(webView)")
            await updateInjectionScriptsInWebView(webView, userContentManager: userContentManager)
            logger.debug("Successfully registered webview with \(activeExtensions.count) active extension(s)")
        }
    }
    
    /// Unregister a webview from injection script updates
    /// - Parameter webView: The webview to unregister
    public func unregisterWebView(_ webView: BrowserExtensionWKWebView) {
        logger.debug("Unregistering webview from injection script updates")
        let id = ObjectIdentifier(webView)
        
        // Clean up console handlers for background scripts
        if let webViewState = webViewStates[id] {
            if case .backgroundScript(let extensionId) = webViewState.role {
                cleanupConsoleHandlers(for: webView, extensionId: extensionId)
            }
        }
        
        webViewStates.removeValue(forKey: id)
        
        // Remove webview from network
        network.remove(webView: webView)
    }
    
    // MARK: - Private methods
    
    /// Clean up any deallocated webviews from the registry
    private func cleanupDeallocatedWebViews() {
        let originalKeys = Set(webViewStates.keys)
        webViewStates = webViewStates.compactMapValues { state in
            state.webView != nil ? state : nil
        }
        let remainingKeys = Set(webViewStates.keys)
        let deallocatedKeys = originalKeys.subtracting(remainingKeys)
        
        if !deallocatedKeys.isEmpty {
            logger.debug("Cleaned up \(deallocatedKeys.count) deallocated webview(s)")
        }
    }
    
    /// Clean up console handlers for a specific extension's background script
    /// - Parameters:
    ///   - webView: The webview to clean up console handlers for
    ///   - extensionId: The extension ID for logging purposes
    private func cleanupConsoleHandlers(for webView: BrowserExtensionWKWebView, extensionId: UUID) {
        logger.debug("Cleaning up console handlers for extension \(extensionId)")
        
        // Remove console handlers from both .page and extension content worlds
        // We need to remove from both worlds since we added to both
        webView.be_configuration.be_userContentController.be_removeScriptMessageHandler(forName: "consoleLog", contentWorld: .page)
        
        // Also remove from extension content world if we can determine it
        // Use a snapshot of activeExtensions to avoid race conditions during cleanup
        let activeExtensionsSnapshot = activeExtensions
        if let activeExtension = activeExtensionsSnapshot[extensionId] {
            webView.be_configuration.be_userContentController.be_removeScriptMessageHandler(forName: "consoleLog", contentWorld: activeExtension.contentWorld)
        } else {
            // If extension is no longer active, try to remove from a reconstructed content world
            // This handles the race condition where extension is deactivated during cleanup
            let reconstructedContentWorld = WKContentWorld.world(name: "Extension-\(extensionId)")
            webView.be_configuration.be_userContentController.be_removeScriptMessageHandler(forName: "consoleLog", contentWorld: reconstructedContentWorld)
        }
        
        logger.debug("Successfully cleaned up console handlers for extension \(extensionId)")
    }
    
    /// Clean up console handlers for all background script webviews of a specific extension
    /// - Parameter extensionId: The extension ID to clean up console handlers for
    private func cleanupConsoleHandlersForExtension(_ extensionId: UUID) {
        logger.debug("Cleaning up console handlers for all webviews of extension \(extensionId)")
        
        for webViewState in webViewStates.values {
            if case .backgroundScript(let bgExtensionId) = webViewState.role,
               bgExtensionId == extensionId,
               let webView = webViewState.webView {
                cleanupConsoleHandlers(for: webView, extensionId: extensionId)
            }
        }
    }
    
    /// Update the injection scripts in all registered webviews
    private func updateInjectionScriptsInAllWebViews() async {
        // Clean up any deallocated webviews
        cleanupDeallocatedWebViews()

        // Update each webview
        for state in webViewStates.values {
            if let webView = state.webView {
                await updateInjectionScriptsInWebView(webView, userContentManager: state.userContentManager)
            }
        }
    }

    enum UserScripts {
        case injectionScript(UUID)
        case chromeAPIs

        var identifier: String {
            switch self {
            case .injectionScript(let uuid): return "Injection(\(uuid.uuidString))"
            case .chromeAPIs: return "chromeAPIs"
            }
        }
    }
    /// Update the injection scripts in a specific webview
    private func updateInjectionScriptsInWebView(_ webView: BrowserExtensionWKWebView,
                                                 userContentManager: BrowserExtensionUserContentManager) async {
        await userContentManager.performAtomicUpdate {
            await reallyUpdateInjections(webView: webView, userContentManager:userContentManager)
        }
    }

    private func reallyUpdateInjections(webView: BrowserExtensionWKWebView,
                                        userContentManager: BrowserExtensionUserContentManager) async {
        logger.debug("Updating injection scripts in webview \(webView) for \(activeExtensions.count) active extension(s)")
        
        let webViewId = ObjectIdentifier(webView)
        
        // Get or create webview state
        guard let webViewState = webViewStates[webViewId] else {
            logger.error("WebView state not found for webview")
            return
        }
        
        // Inject role-specific scripts first (only once per webview)
        switch webViewState.role {
        case .backgroundScript(let extensionId):
            // For background scripts, inject DOM nuke and console handler only once
            if !webViewState.hasBackgroundScriptSupport {
                // Get the content world for this background script extension
                if let activeExtension = activeExtensions[extensionId] {
                    injectBackgroundScriptSupport(webView,
                                                  userContentManager: userContentManager,
                                                  extensionId: extensionId,
                                                  contentWorld: activeExtension.contentWorld)
                    webViewState.hasBackgroundScriptSupport = true
                } else {
                    logger.error("Background script extension \(extensionId) not found in active extensions")
                }
            }
        case .userFacing:
            // User-facing webviews don't need special setup
            break
        }
        
        // For each active extension, add message handlers and inject scripts
        for (extensionId, activeExtension) in activeExtensions {
            logger.debug("Installing scripts for extension: \(extensionId)")
            // Add message handlers for this extension's content world (if not already added for this webview)
            let contentWorldName = activeExtension.contentWorld.name ?? "unnamed"
            if !webViewState.contentWorldsWithHandlers.contains(contentWorldName) {
                addMessageHandlersToWebView(webView,
                                            contentWorld: activeExtension.contentWorld,
                                            for: activeExtension.browserExtension)
                webViewState.contentWorldsWithHandlers.insert(contentWorldName)
            }
            
            // Inject chrome.runtime APIs JavaScript for this extension
            let isBackgroundScript = switch webViewState.role {
            case .backgroundScript: true
            case .userFacing: false
            }
            await injectChromeAPIs(activeExtension.browserExtension,
                                   webView: webView,
                                   contentManager: userContentManager,
                                   contentWorld: activeExtension.contentWorld,
                                   isBackgroundScript: isBackgroundScript)

            // Inject role-specific extension scripts
            switch webViewState.role {
            case .userFacing:
                // For user-facing webviews, inject content scripts
                let injectionScriptSource = injectionScriptGenerator.generateInjectionScript(for: activeExtension)
                
                userContentManager.add(userScript: .init(
                    code: injectionScriptSource,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: false,
                    worlds: [activeExtension.contentWorld],
                    identifier: UserScripts.injectionScript(activeExtension.browserExtension.id).identifier))

            case .backgroundScript(let backgroundExtensionId):
                // For background scripts, only execute if this extension owns this background webview
                if extensionId == backgroundExtensionId {
                    if let backgroundResource = activeExtension.browserExtension.backgroundScriptResource {
                        logger.debug("Executing background script content for extension \(activeExtension.browserExtension.id)")
                        do {
                            // Execute console override script first to ensure console.log is intercepted
                            let consoleOverrideScript = generateConsoleOverrideScript()
                            try await webView.be_evaluateJavaScript(consoleOverrideScript, in: nil, in: activeExtension.contentWorld)
                            logger.debug("Successfully executed console override script in extension content world")
                            
                            // Then execute the actual background script
                            try await webView.be_evaluateJavaScript(backgroundResource.jsContent, in: nil, in: activeExtension.contentWorld)
                            logger.debug("Successfully executed background script content")
                        } catch {
                            logger.error("Failed to execute background script content: \(error)")
                        }
                    } else {
                        logger.debug("No background script resource found for extension \(activeExtension.browserExtension.id)")
                    }
                }
            }
        }
        
        logger.debug("Finished updating injection scripts in webview")
    }
    
    /// Add message handlers to a specific content world for an extension
    private func addMessageHandlersToWebView(_ webView: BrowserExtensionWKWebView,
                                             contentWorld: WKContentWorld,
                                             for browserExtension: BrowserExtension) {
        logger.debug("Registering message handlers for content world: \(contentWorld.name ?? "unnamed")")
        
        // Add message handler for chrome.runtime.* native calls to this content world
        webView.be_configuration.be_userContentController.be_add(
            BrowserExtensionAPIRequestMessageHandler(
                callbackHandler: callbackHandler,
                dispatcher: BrowserExtensionDispatcher(),
                logger: logger,
                contextProvider: { [weak self, weak webView] in
                    guard let self, let webView else {
                        return nil
                    }
                    // TODO: Determine the tab and frame ID.
                    return self.context(for: webView, browserExtension: browserExtension, tab: nil, frameId: nil)
                }
            ),
            name: "requestBrowserExtension",
            contentWorld: contentWorld
        )

        // Add message handler for onMessage listeners to this content world
        webView.be_configuration.be_userContentController.be_add(
            BrowserExtensionListenerResponseHandler(
                router: router,
                logger: logger
            ),
            name: "listenerResponseBrowserExtension",
            contentWorld: contentWorld
        )
    }
    
    /// This is called when JS makes an API call (e.g.,
    /// chrome.runtime.sendMessage) so that the dispatcher can attach the
    /// sender's context when it calls the handler.
    private func context(for webView: BrowserExtensionWKWebView,
                         browserExtension: BrowserExtension,
                         tab: BrowserExtensionContext.MessageSender.Tab?,
                         frameId: Int?) -> BrowserExtensionContext {
        return BrowserExtensionContext(
            logger: logger,
            router: router,
            webView: webView,
            browserExtension: browserExtension,
            tab: tab,
            frameId: frameId
        )
    }
    
    /// Inject chrome.runtime APIs JavaScript for a specific extension
    private func injectChromeAPIs(_ browserExtension: BrowserExtension,
                                  webView: BrowserExtensionWKWebView,
                                  contentManager: BrowserExtensionUserContentManager,
                                  contentWorld: WKContentWorld,
                                  isBackgroundScript: Bool = false) async {
        // Generate the JavaScript API code
        let injectionScript = generatedAPIJavascript(.init(extensionId: browserExtension.id.uuidString))

        logger.debug("Injecting Chrome APIs for extension \(browserExtension.id) into webview \(webView) in content world: \(contentWorld.name ?? "unnamed")")
        
        if isBackgroundScript {
            // For background scripts, execute DOM nuke script first, then Chrome APIs
            await executeDOMNukeInContentWorld(webView, contentWorld: contentWorld)
            
            do {
                try await webView.be_evaluateJavaScript(injectionScript, in: nil, in: contentWorld)
                logger.debug("Successfully executed Chrome API script immediately for background script")
            } catch {
                logger.error("Failed to execute Chrome API script immediately: \(error)")
            }
        } else {
            // For user-facing webviews, add as user script
            contentManager.add(userScript: .init(
                code: injectionScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false,
                worlds: [contentWorld],
                identifier: UserScripts.chromeAPIs.identifier))
            logger.debug("Added Chrome API user script to webview \(webView) in content world: \(contentWorld.name ?? "unnamed")")
        }
    }
    
    // MARK: - Test Support Methods
    
    /// Inject chrome.runtime APIs for testing (bypasses normal activation flow)
    /// - Parameters:
    ///   - webView: The webview to inject APIs into
    ///   - browserExtension: The extension to inject APIs for
    ///   - contentWorld: The content world to inject into
    internal func injectRuntimeAPIsForTesting(into webView: BrowserExtensionWKWebView,
                                              contentManager: BrowserExtensionUserContentManager,
                                              for browserExtension: BrowserExtension,
                                              contentWorld: WKContentWorld) async {
        logger.info("Injecting chrome.runtime APIs for testing")
        addMessageHandlersToWebView(webView,
                                    contentWorld: contentWorld,
                                    for: browserExtension)

        await injectChromeAPIs(browserExtension,
                               webView: webView,
                               contentManager: contentManager,
                               contentWorld: contentWorld)
    }
    
    /// Inject only the JavaScript part for testing (without registering handlers)
    internal func injectJavaScriptOnlyForTesting(into webView: BrowserExtensionWKWebView,
                                                 contentManager: BrowserExtensionUserContentManager,
                                                 for browserExtension: BrowserExtension,
                                                 contentWorld: WKContentWorld) async {
        logger.info("Injecting chrome.runtime JavaScript for testing")
        await injectChromeAPIs(browserExtension,
                               webView: webView,
                               contentManager: contentManager,
                               contentWorld: contentWorld)
    }

    // MARK: - BrowserExtensionRouterDataSource
    
    /// Get the content world for a given extension ID
    public func contentWorld(for extensionId: String) async -> WKContentWorld? {
        logger.debug("ActiveManager asked for content world for extension: \(extensionId)")
        guard let extensionUUID = UUID(uuidString: extensionId),
              let activeExtension = activeExtensions[extensionUUID] else {
            logger.debug("No active extension found for ID: \(extensionId)")
            return nil
        }
        let contentWorld = activeExtension.contentWorld
        logger.debug("ActiveManager returning content world: \(contentWorld.name ?? "unnamed")")
        return contentWorld
    }
    
    // MARK: - Background Script Support

    private enum UserScriptIdentifier: String {
        case domNuke = "__be_domNuke"
        case consoleLog = "__be_consoleLog"
    }

    /// Inject background script-specific scripts (DOM nuke + console handler)
    private func injectBackgroundScriptSupport(_ webView: BrowserExtensionWKWebView,
                                               userContentManager: BrowserExtensionUserContentManager,
                                               extensionId: UUID,
                                               contentWorld: WKContentWorld) {
        // Add console.log message handler for this specific extension
        let consoleHandler = BrowserExtensionConsoleLogHandler(
            extensionId: extensionId,
            logger: logger
        )
        
        // Add console handler to both .page world and extension's content world
        // .page world for compatibility with existing web content
        webView.be_configuration.be_userContentController.be_add(
            consoleHandler,
            name: "consoleLog",
            contentWorld: .page
        )
        
        // Extension's content world for background scripts
        webView.be_configuration.be_userContentController.be_add(
            consoleHandler,
            name: "consoleLog",
            contentWorld: contentWorld
        )

        userContentManager.performAtomicUpdate {
            // DOM Nuke
            userContentManager.add(userScript: BrowserExtensionUserContentManager.UserScript(
                code: generateDOMNukeScript(),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false,
                worlds: [.defaultClient, contentWorld],
                identifier: UserScriptIdentifier.domNuke.rawValue))

            // console.log handler
            userContentManager.add(userScript: BrowserExtensionUserContentManager.UserScript(
                code: generateConsoleOverrideScript(),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false,
                worlds: [.page, contentWorld],
                identifier: UserScriptIdentifier.consoleLog.rawValue))
        }
    }
    
    /// Execute DOM nuke script directly in the extension's content world
    private func executeDOMNukeInContentWorld(_ webView: BrowserExtensionWKWebView, contentWorld: WKContentWorld) async {
        logger.debug("About to execute DOM nuke script in content world: \(contentWorld.name ?? "unnamed")")
        let domNukeScript = generateDOMNukeScript()
        do {
            _ = try await webView.be_evaluateJavaScript(domNukeScript, in: nil, in: contentWorld)
            logger.debug("Successfully executed DOM nuke script in content world")
        } catch {
            logger.error("Failed to execute DOM nuke script in content world: \(error)")
        }
    }
    
    /// Generate DOM nuke script to remove DOM globals from background script context
    private func generateDOMNukeScript() -> String {
        return BrowserExtensionTemplateLoader.loadTemplate(named: "dom-nuke", type: "js")
    }
    
    /// Generate console override script that overrides console.log to send messages to Swift
    private func generateConsoleOverrideScript() -> String {
        return BrowserExtensionTemplateLoader.loadTemplate(named: "console-override", type: "js")
    }
}

/// Message handler for console.log messages from background scripts
class BrowserExtensionConsoleLogHandler: NSObject, WKScriptMessageHandler {
    private let extensionId: UUID
    private let logger: BrowserExtensionLogger
    
    init(extensionId: UUID, logger: BrowserExtensionLogger) {
        self.extensionId = extensionId
        self.logger = logger
        super.init()
    }
    
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        // Security validation of console message content
        guard let logMessage = sanitizeConsoleMessage(message.body) else {
            logger.debug("Console [\(extensionId)]: [FILTERED] Invalid or potentially malicious console message")
            return
        }
        
        logger.info("Console [\(extensionId)]: \(logMessage)")
    }
    
    /// Sanitize console message content to prevent log injection and other security issues
    /// - Parameter messageBody: The raw message body from WKScriptMessage
    /// - Returns: Sanitized string or nil if message should be filtered
    private func sanitizeConsoleMessage(_ messageBody: Any) -> String? {
        let rawMessage: String
        
        // Convert message body to string safely
        if let stringMessage = messageBody as? String {
            rawMessage = stringMessage
        } else {
            rawMessage = String(describing: messageBody)
        }
        
        // Basic length validation to prevent DoS via large messages
        let maxLength = 10000
        let truncatedMessage = rawMessage.count > maxLength ? 
            String(rawMessage.prefix(maxLength)) + "... [TRUNCATED]" : rawMessage
        
        // Filter out potentially malicious patterns
        var sanitizedMessage = truncatedMessage
        
        // Remove/replace control characters that could cause log injection
        sanitizedMessage = sanitizedMessage.replacingOccurrences(of: "\r\n", with: " ")
        sanitizedMessage = sanitizedMessage.replacingOccurrences(of: "\n", with: " ")
        sanitizedMessage = sanitizedMessage.replacingOccurrences(of: "\r", with: " ")
        sanitizedMessage = sanitizedMessage.replacingOccurrences(of: "\t", with: " ")
        
        // Remove other potentially problematic control characters
        sanitizedMessage = sanitizedMessage.filter { char in
            // Keep printable ASCII characters and basic Unicode
            let scalar = char.unicodeScalars.first
            return scalar?.properties.isGraphemeBase == true || 
                   scalar?.properties.isGraphemeExtend == true || 
                   char.isWhitespace
        }
        
        // Additional validation - reject messages that look like log injection attempts
        let suspiciousPatterns = [
            "Console [", // Prevent spoofing our own log format
            "ERROR:", "DEBUG:", "INFO:", "WARN:", // Prevent log level spoofing
            "\u{001B}", // ANSI escape sequences
            "\u{0008}", // Backspace
            "\u{000C}", // Form feed
        ]
        
        for pattern in suspiciousPatterns {
            if sanitizedMessage.contains(pattern) {
                // Replace suspicious patterns with safe alternatives
                sanitizedMessage = sanitizedMessage.replacingOccurrences(of: pattern, with: "[FILTERED]")
            }
        }
        
        return sanitizedMessage.isEmpty ? "[EMPTY]" : sanitizedMessage
    }
}
