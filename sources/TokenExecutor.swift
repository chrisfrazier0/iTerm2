//
//  TokenExecutor.swift
//  iTerm2SharedARC
//
//  Created by George Nachman on 1/5/22.
//

import Foundation

protocol UnpauserDelegate: AnyObject {
    func unpause()
}

typealias TokenExecutorTask = () -> ()

// Delegate calls are run on the execution queue.
@objc(iTermTokenExecutorDelegate)
protocol TokenExecutorDelegate: AnyObject {
    // Should token execution be delayed? Do this in copy mode, for example.
    func tokenExecutorShouldQueueTokens() -> Bool

    // Should tokens be freed without use? Do this during a mute coprocess, for example.
    @objc(tokenExecutorShouldDiscardToken:withHighPriority:)
    func tokenExecutorShouldDiscard(token: VT100Token,
                                    highPriority: Bool) -> Bool

    // Called only when tokens are actually executed. `length` gives the number of bytes of input
    // that were executed.
    func tokenExecutorDidExecute(length: Int, throughput: Int)

    // Remove this eventually
    func tokenExecutorCursorCoordString() -> NSString

    // Synchronize state between threads.
    func tokenExecutorSync()

    // Side-effect state found.
    func tokenExecutorHandleSideEffectFlags(_ flags: Int64)

    // About to execute a batch of tokens.
    func tokenExecutorWillExecuteTokens()
}

// Uncomment the stack tracing code to debug stuck paused executors.
@objc(iTermTokenExecutorUnpauser)
class Unpauser: NSObject {
    private weak var delegate: UnpauserDelegate?
    private let mutex = Mutex()
    // @objc var stack: String
    #if DEBUG
    private var hasBeenUnpaused = false
    #endif

    init(_ delegate: UnpauserDelegate) {
        self.delegate = delegate
        // stack = Thread.callStackSymbols.joined(separator: "\n")
        super.init()
        // print("Pause \(self) from\n\(stack)")
    }

    @objc
    func unpause() {
        mutex.sync {
            #if DEBUG
            hasBeenUnpaused = true
            #endif
            // print("Unpause \(self)")
            guard let temp = delegate else {
                return
            }
            // stack = ""
            delegate = nil
            temp.unpause()
        }
    }

    deinit {
        #if DEBUG
        it_assert(hasBeenUnpaused)
        #endif
//        if stack != "" {
//            fatalError()
//        }
    }
}

func CVectorReleaseObjectsAndDestroy(_ vector: CVector) {
    var temp = vector
    CVectorReleaseObjects(&temp);
    CVectorDestroy(&temp)
}

@objc(iTermTokenExecutor)
class TokenExecutor: NSObject {
    @objc weak var delegate: TokenExecutorDelegate? {
        didSet {
            impl.delegate = delegate
        }
    }
    private let semaphore = DispatchSemaphore(value: Int(iTermAdvancedSettingsModel.bufferDepth()))
    private let impl: TokenExecutorImpl
    private let queue: DispatchQueue
    private static let isTokenExecutorSpecificKey = DispatchSpecificKey<Bool>()
    private var onExecutorQueue: Bool {
        return DispatchQueue.getSpecific(key: Self.isTokenExecutorSpecificKey) == true
    }
    @objc var isExecutingToken: Bool {
        #if DEBUG
        iTermGCD.assertMutationQueueSafe()
        #endif
        return impl.isExecutingToken
    }

    @objc(initWithTerminal:slownessDetector:queue:)
    init(_ terminal: VT100Terminal,
         slownessDetector: SlownessDetector,
         queue: DispatchQueue) {
        self.queue = queue
        queue.setSpecific(key: Self.isTokenExecutorSpecificKey, value: true)
        impl = TokenExecutorImpl(terminal,
                                 slownessDetector: slownessDetector,
                                 semaphore: semaphore,
                                 queue: queue)
    }

    // This takes ownership of vector.
    // You can call this on any queue.
    @objc
    func addTokens(_ vector: CVector, length: Int) {
        addTokens(vector, length: length, highPriority: false)
    }

    private static let addTokensTimingStats: TimingStats = {
        TimingStats(name: "TokenExecutor")
    }()
    // Flip this to true to measure how much time the TaskNotifier thread spends busy (reading,
    // parsing, and in select()) vs idle (blocked on TokenExecutor's semaphore).
    private let enableTimingStats = false

    // This takes ownership of vector.
    // You can call this on any queue when not high priority.
    // If high priority, then you must be on the main queue or have joined the main & mutation queue.
    // This blocks when the queue of tokens gets too large.
    @objc
    func addTokens(_ vector: CVector, length: Int, highPriority: Bool) {
        if gDebugLogging.boolValue { DLog("Add tokens with length \(length) highpri=\(highPriority)") }
        if length == 0 {
            return
        }
        if highPriority {
#if DEBUG
            iTermGCD.assertMutationQueueSafe()
#endif
            // Re-entrant code path so that the Inject trigger can do its job synchronously
            // (before other triggers run).
            reallyAddTokens(vector, length: length, highPriority: highPriority, semaphore: nil)
            return
        }
        // Normal code path for tokens from PTY. Use the semaphore to give backpressure to reading.
        let semaphore = self.semaphore
        if enableTimingStats {
            TokenExecutor.addTokensTimingStats.recordEnd()
        }
        _ = semaphore.wait(timeout: .distantFuture)
        if enableTimingStats {
            TokenExecutor.addTokensTimingStats.recordStart()
        }
        reallyAddTokens(vector, length: length, highPriority: highPriority, semaphore: semaphore)
        queue.async { [weak self] in
            self?.impl.didAddTokens()
        }
    }


    // Call this while a token is being executed to cause it to be re-executed next time execution
    // is scheduled.
    @objc
    func rollBackCurrentToken() {
        if gDebugLogging.boolValue { DLog("Roll back current token") }
#if DEBUG
        iTermGCD.assertMutationQueueSafe()
#endif
        impl.rollBackCurrentToken()
    }

    // Any queue
    @objc
    func addSideEffect(_ task: @escaping TokenExecutorTask) {
        if gDebugLogging.boolValue { DLog("add side effect") }
        impl.addSideEffect(task)
    }

    // Any queue
    @objc
    func addDeferredSideEffect(_ task: @escaping TokenExecutorTask) {
        impl.addDeferredSideEffect(task)
    }

    // Any queue
    @objc
    func setSideEffectFlag(value: Int64) {
        if gDebugLogging.boolValue { DLog("Set side-effect flag \(value)") }
        impl.setSideEffectFlag(value: value)
    }

    // This can run on the main queue, or else on the mutation queue when joined.
    @objc(executeSideEffectsImmediatelySyncingFirst:)
    func executeSideEffectsImmediately(syncFirst: Bool) {
        if gDebugLogging.boolValue { DLog("Execute side effects immediately syncFirst=\(syncFirst)") }
        impl.executeSideEffects(syncFirst: syncFirst)
    }

    // This takes ownership of vector.
    // You can call this on any queue
    private func reallyAddTokens(_ vector: CVector,
                                 length: Int,
                                 highPriority: Bool,
                                 semaphore: DispatchSemaphore?) {
        let tokenArray = TokenArray(vector, length: length, semaphore: semaphore)
        self.impl.addTokens(tokenArray, highPriority: highPriority)
    }

    // Call this on the token evaluation queue.
    @objc
    func pause() -> Unpauser {
        if gDebugLogging.boolValue { DLog("pause") }
        return impl.pause()
    }

    class GlobalUnpauserDelegate: UnpauserDelegate {
        func unpause() {
            iTermAtomicInt64Add(globalPauseCount, -1)
            NotificationCenter.default.post(name: TokenExecutorImpl.didUnpauseGloballyNotification, object: nil)
        }
    }

    static let globalPauseCount = iTermAtomicInt64Create()
    private static var globalUnpauserDelegate = GlobalUnpauserDelegate()
    static func globalPause() -> Unpauser {
        let newValue = iTermAtomicInt64Add(globalPauseCount, 1)
        if newValue == 1 && gDebugLogging.boolValue {
            DLog("Pause")
        }
        return Unpauser(globalUnpauserDelegate)
    }

    // You can call this on any queue.
    @objc
    func schedule() {
        if gDebugLogging.boolValue { DLog("schedule") }
        impl.schedule()
    }

    @objc func assertSynchronousSideEffectsAreSafe() {
        impl.assertSynchronousSideEffectsAreSafe()
    }

    // Note that the task may be run either synchronously or asynchronously.
    // High priority tasks run as soon as possible. If a token is currently
    // executing, it runs after that token's execution completes. Token
    // execution is guaranteed to not block and should not take "very long".
    // You can call this on any queue.
    @objc
    func scheduleHighPriorityTask(_ task: @escaping TokenExecutorTask) {
        if gDebugLogging.boolValue { DLog("schedule high-pri task") }
        self.impl.scheduleHighPriorityTask(task, syncAllowed: onExecutorQueue)
    }

    // Main queue only
    @objc
    func whilePaused(_ block: () -> ()) {
        self.impl.whilePaused(block, onExecutorQueue: onExecutorQueue)
    }
}

private class TokenExecutorImpl {
    static let didUnpauseGloballyNotification = Notification.Name("didUnpauseGloballyNotification")
    private let terminal: VT100Terminal
    private let queue: DispatchQueue
    private let slownessDetector: SlownessDetector
    private let semaphore: DispatchSemaphore
    private var taskQueue = iTermTaskQueue()
    private var sideEffects = iTermTaskQueue()
    private let tokenQueue = TwoTierTokenQueue()
    private var pauseCount = iTermAtomicInt64Create()
    private var executingCount = 0
    private let executingSideEffects = MutableAtomicObject(false)
    private var sideEffectScheduler: PeriodicScheduler! = nil
    private let throughputEstimator = iTermThroughputEstimator(historyOfDuration: 5.0 / 30.0,
                                                               secondsPerBucket: 1.0 / 30.0)
    private var commit = true
    // Access on mutation queue only
    private(set) var isExecutingToken = false
    weak var delegate: TokenExecutorDelegate?

    init(_ terminal: VT100Terminal,
         slownessDetector: SlownessDetector,
         semaphore: DispatchSemaphore,
         queue: DispatchQueue) {
        self.terminal = terminal
        self.queue = queue
        self.slownessDetector = slownessDetector
        self.semaphore = semaphore
        sideEffectScheduler = PeriodicScheduler(DispatchQueue.main, period: 1 / 30.0, action: { [weak self] in
            guard let self = self else {
                return
            }
            DispatchQueue.main.async { [weak self] in
                self?.executeSideEffects(syncFirst: true)
            }
        })
        NotificationCenter.default.addObserver(forName: Self.didUnpauseGloballyNotification,
                                               observer: self,
                                               object: nil) { [weak self] _ in
            guard let self else {
                return
            }
            self.queue.async {
                if !self.isPaused {
                    self.schedule()
                }
            }
        }
    }

    func pause() -> Unpauser {
#if DEBUG
        assertQueue()
#endif
        let newValue = iTermAtomicInt64Add(pauseCount, 1)
        if newValue == 1 && gDebugLogging.boolValue {
            DLog("Pause")
        }
        return Unpauser(self)
    }

    private var isPaused: Bool {
#if DEBUG
        assertQueue()
#endif
        return iTermAtomicInt64Get(pauseCount) > 0 || iTermAtomicInt64Get(TokenExecutor.globalPauseCount) > 0
    }

    func invalidate() {
#if DEBUG
        assertQueue()
#endif
        tokenQueue.removeAll()
    }

    // You can call this on any queue
    func addTokens(_ tokenArray: TokenArray, highPriority: Bool) {
        throughputEstimator.addByteCount(tokenArray.length)
        tokenQueue.addTokens(tokenArray, highPriority: highPriority)
    }

    func didAddTokens() {
        execute()
    }

    // You can call this on any queue.
    func schedule() {
        queue.async { [weak self] in
            self?.execute()
        }
    }

    // Any queue
    func scheduleHighPriorityTask(_ task: @escaping TokenExecutorTask, syncAllowed: Bool) {
        taskQueue.append(task)
        if syncAllowed {
#if DEBUG
            assertQueue()
#endif
            if executingCount == 0 {
                execute()
                return
            }
        }
        schedule()
    }

    // Main queue
    // Runs block synchronously while token executor is stopped.
    func whilePaused(_ block: () -> (), onExecutorQueue: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        if gDebugLogging.boolValue { DLog("Incr pending pauses if \(iTermPreferences.maximizeThroughput())") }
        var unpauser = iTermPreferences.maximizeThroughput() ? nil : TokenExecutor.globalPause()

        let sema = DispatchSemaphore(value: 0)
        let sema2 = DispatchSemaphore(value: 0)
        queue.async {
            sema2.signal()
            sema.wait()
        }
        if unpauser != nil {
            sema2.wait()
        } else {
            // When maximize throughput is on, we want to avoid pausing token execution but we can't
            // let it go on indefinitely. After a timeout, pause it and block for what should be a short
            // amount of time (until the current batch of tokens is done being executed).
            let timeout = 0.03
            if sema2.wait(timeout: .now() + timeout) == .timedOut {
                unpauser = TokenExecutor.globalPause()
                sema2.wait()
            }
        }
        block()
        if unpauser != nil {
            if gDebugLogging.boolValue { DLog("Decr pending pauses") }
        }
        unpauser?.unpause()
        sema.signal()
    }

    // Any queue
    func addSideEffect(_ task: @escaping TokenExecutorTask) {
        sideEffects.append(task)
        if gDebugLogging.boolValue { DLog("addSideEffect()") }
        sideEffectScheduler.markNeedsUpdate()
    }

    func addDeferredSideEffect(_ task: @escaping TokenExecutorTask) {
        sideEffects.append(task)
        sideEffectScheduler.markNeedsUpdate(deferred: sideEffectScheduler.period / 2)
    }

    // Any queue
    func setSideEffectFlag(value: Int64) {
        if (sideEffects.setFlag(value) & value) == 0 {
            sideEffectScheduler.markNeedsUpdate(deferred: sideEffectScheduler.period / 2)
        }
    }

    func assertSynchronousSideEffectsAreSafe() {
        precondition(sideEffects.count == 0 && !executingSideEffects.value)
    }

    // This can run on the main queue, or else on the mutation queue when joined.
    func executeSideEffects(syncFirst: Bool) {
        if gDebugLogging.boolValue { DLog("begin") }
        iTermGCD.assertMainQueueSafe()

        if executingSideEffects.getAndSet(true) {
            // Do not allow re-entrant side-effects.
            if gDebugLogging.boolValue { DLog("reentrancy detected! aborting") }
            return
        }
        if gDebugLogging.boolValue { DLog("dequeuing side effects") }
        var shouldSync = syncFirst
        while let task = sideEffects.dequeue() {
            if shouldSync {
                if gDebugLogging.boolValue { DLog("sync before first side effect") }
                delegate?.tokenExecutorSync()
                shouldSync = false
            }
            if gDebugLogging.boolValue { DLog("execute side effect") }
            task()
        }
        if gDebugLogging.boolValue { DLog("finished executing side effects") }
        executingSideEffects.set(false)

        // Do this last because it might join.
        let flags = sideEffects.resetFlags()
        if flags != 0 {
            if gDebugLogging.boolValue { DLog("flags=\(flags)") }
            if shouldSync {
                if gDebugLogging.boolValue { DLog("sync before handling flags") }
                delegate?.tokenExecutorSync()
            }
            delegate?.tokenExecutorHandleSideEffectFlags(flags)
        }
    }

#if DEBUG
    private func assertQueue() {
        iTermGCD.assertMutationQueueSafe()
    }
#endif

    private func execute() {
        DLog("execute()")
#if DEBUG
        assertQueue()
#endif
        executingCount += 1
        defer {
            executingCount -= 1
            executeHighPriorityTasks()
        }
        executeHighPriorityTasks()
        guard let delegate = delegate else {
            // This is necessary to avoid deadlock. If the terminal is disabled then the token queue
            // will hold semaphores that need to be signaled.
            if gDebugLogging.boolValue {
                DLog("empty queue")
            }
            tokenQueue.removeAll()
            return
        }
        let hadTokens = !tokenQueue.isEmpty
        var accumulatedLength = 0
        if !delegate.tokenExecutorShouldQueueTokens() {
            slownessDetector.measure(event: PTYSessionSlownessEventExecute) {
                var first = true
                if gDebugLogging.boolValue {
                    DLog("Will enumerate token arrays")
                }
                tokenQueue.enumerateTokenArrayGroups { (tokenArrayGroup, priority) in
                    if first {
                        delegate.tokenExecutorWillExecuteTokens()
                        first = false
                    }
                    if gDebugLogging.boolValue {
                        DLog("Begin executing a batch of tokens of sizes \(tokenArrayGroup.arrays.map(\.numberRemaining))")
                    }
                    defer {
                        if gDebugLogging.boolValue {
                            DLog("Done executing a batch of tokens. Vector has \(tokenArrayGroup.arrays.map(\.numberRemaining)) remaining.")
                        }
                    }
                    return executeTokenGroups(tokenArrayGroup,
                                              priority: priority,
                                              accumulatedLength: &accumulatedLength,
                                              delegate: delegate)
                }
                if gDebugLogging.boolValue { DLog("Finished enumerating token arrays") }
            }
        }
        if accumulatedLength > 0 || hadTokens {
            delegate.tokenExecutorDidExecute(length: accumulatedLength,
                                             throughput: throughputEstimator.estimatedThroughput)
        }
    }

    private func executeTokenGroups(_ group: TokenArrayGroup,
                                    priority: Int,
                                    accumulatedLength: inout Int,
                                    delegate: TokenExecutorDelegate) -> Bool {
        if gDebugLogging.boolValue { DLog("Begin for \(delegate)") }
        defer {
            if gDebugLogging.boolValue {
                DLog("execute tokens cleanup for \(delegate)")
            }
            executeHighPriorityTasks()
        }
        var quitVectorEarly = false
        var vectorHasNext = true
        while !isPaused && !quitVectorEarly && vectorHasNext {
            if gDebugLogging.boolValue {
                DLog("continuing to next token")
            }
            if let token = group.peek {
                executeHighPriorityTasks()
                commit = true
                var consume = true
                if execute(token: token,
                           priority: priority,
                           accumulatedLength: &accumulatedLength,
                           delegate: delegate) {
                    if gDebugLogging.boolValue {
                        DLog("quit early")
                    }
                    quitVectorEarly = true
                    consume = true
                } else {
                    consume = commit
                }
                if consume {
                    vectorHasNext = group.consume()
                } else {
                    vectorHasNext = false
                }
                if gDebugLogging.boolValue {
                    DLog("commit=\(commit) consume=\(consume) remaining=\(group.arrays.map(\.numberRemaining))")
                }
            }
        }
        if quitVectorEarly {
            if gDebugLogging.boolValue { DLog("quitVectorEarly") }
            return true
        }
        if isPaused {
            if gDebugLogging.boolValue { DLog("paused") }
            return false
        }
        if gDebugLogging.boolValue { DLog("normal termination") }
        accumulatedLength += group.length
        return true
    }

    func rollBackCurrentToken() {
        if gDebugLogging.boolValue { DLog("roll back current token") }
#if DEBUG
        assertQueue()
#endif
        commit = false
    }

    // Returns true to stop processing tokens in this vector and move on to the next one, if any.
    // Returns false to continue processing tokens in the vector, if any (and if not go to the next
    // vector).
    private func execute(token: VT100Token,
                         priority: Int,
                         accumulatedLength: inout Int,
                         delegate: TokenExecutorDelegate) -> Bool {
        if gDebugLogging.boolValue { DLog("Execute token \(token) cursor=\(delegate.tokenExecutorCursorCoordString())") }

        if delegate.tokenExecutorShouldDiscard(token: token, highPriority: priority == 0) {
            DLog("Discarding token")
            return false
        }

        isExecutingToken = true
        terminal.execute(token)
        isExecutingToken = false

        // Return true if we need to switch to a high priority queue.
        return (priority > 0) && tokenQueue.hasHighPriorityToken
    }

    private func executeHighPriorityTasks(until stopCondition: () -> Bool) {
        if gDebugLogging.boolValue { DLog("begin") }
#if DEBUG
        assertQueue()
#endif
        executingCount += 1
        defer {
            executingCount -= 1
        }
        while !stopCondition(), let task = taskQueue.dequeue() {
            if gDebugLogging.boolValue { DLog("execute task") }
            task()
        }
        if gDebugLogging.boolValue { DLog ("done")}
    }

    private func executeHighPriorityTasks() {
        if gDebugLogging.boolValue { DLog("begin") }
        while let task = taskQueue.dequeue() {
            if gDebugLogging.boolValue { DLog("execute task") }
            task()
        }
        if gDebugLogging.boolValue { DLog("done") }
    }
}

extension TokenExecutorImpl: CustomDebugStringConvertible {
    var debugDescription: String {
        return "<TokenExecutorImpl: \(Unmanaged.passUnretained(self).toOpaque()): queue=\(queue.debugDescription) taskQueue=\(taskQueue.count) sideEffects=\(sideEffects.count) pauseCount=\(iTermAtomicInt64Get(pauseCount)) globalPauseCount=\(iTermAtomicInt64Get(TokenExecutor.globalPauseCount)) throughput=\(throughputEstimator.estimatedThroughput) delegate=\(String(describing: delegate))>"
    }
}

extension TokenExecutorImpl: UnpauserDelegate {
    // You can call this on any queue.
    func unpause() {
        let newCount = iTermAtomicInt64Add(pauseCount, -1)
        precondition(newCount >= 0)
        if newCount == 0 && iTermAtomicInt64Get(TokenExecutor.globalPauseCount) == 0 {
            if gDebugLogging.boolValue { DLog("Unpause") }
            schedule()
        }
    }
}

extension TokenExecutor: IdempotentOperationScheduler {
    func scheduleIdempotentOperation(_ closure: @escaping () -> Void) {
        // Use a deferred side effect because this might happen during a prompt redraw and we want
        // to give it a chance to finish so we can avoid syncing with a half-finished prompt.
        addDeferredSideEffect(closure)
    }
}

// Run a closure but not too often.
@objc(iTermPeriodicScheduler)
class PeriodicScheduler: NSObject {
    private var updatePending: Bool {
        return mutex.sync { _updatePending }
    }
    private var _updatePending = false
    private var needsUpdate: Bool {
        get {
            return mutex.sync { _needsUpdate }
        }
        set {
            mutex.sync { _needsUpdate = newValue }
        }
    }
    private var _needsUpdate = false
    private let queue: DispatchQueue
    private let mutex = Mutex()
    let period: TimeInterval
    private let action: () -> ()
    private var scheduledDeferred = false  // guarded by mutex

    @objc(initWithQueue:period:block:)
    init(_ queue: DispatchQueue, period: TimeInterval, action: @escaping () -> ()) {
        self.queue = queue
        self.period = period
        self.action = action
    }

    @objc func markNeedsUpdate() {
        needsUpdate = true
        schedule(reset: false)
    }

    @objc func markNeedsUpdate(deferred delay: TimeInterval) {
        let needsScheduling = mutex.sync {
            _needsUpdate = true
            defer {
                scheduledDeferred = true
            }
            return scheduledDeferred
        }
        if needsScheduling {
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.mutex.sync {
                    self.scheduledDeferred = false
                }
                self.schedule(reset: false)
            }
        }
    }

    @objc func schedule() {
        schedule(reset: false)
    }

    private func schedule(reset: Bool) {
        mutex.sync {
            if reset {
                _updatePending = false
            }
            guard _needsUpdate else {
                // Nothing changed.
                return
            }
            let wasPending = _updatePending
            _updatePending = true

            if wasPending {
                // Too soon to update.
                return
            }

            resetAfterDelay()
            _needsUpdate = false
            action()
        }
    }

    private func resetAfterDelay() {
        queue.asyncAfter(deadline: .now() + period) { [weak self] in
            guard let self = self else {
                return
            }
            self.schedule(reset: true)
        }
    }
}

