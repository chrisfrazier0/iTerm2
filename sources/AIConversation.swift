//
//  AIConversation.swift
//  iTerm2
//
//  Created by George Nachman on 6/5/25.
//

struct AIConversation {
    private class Delegate: AITermControllerDelegate {
        private(set) var busy = false
        var completion: ((Result<String, Error>) -> ())?
        var streaming: ((LLM.StreamingUpdate) -> ())?
        var registrationNeeded: ((@escaping (AITermController.Registration) -> ()) -> ())?
        var createVectorStoreCompletion: ((Result<String, Error>) -> ())?
        var uploadFileCompletion: ((Result<String, Error>) -> ())?
        var addFilesToVectorStoreCompletion: ((Error?) -> ())?

        func aitermControllerWillSendRequest(_ sender: AITermController) {
            busy = true
        }

        func aitermController(_ sender: AITermController, offerChoice choice: String) {
            busy = false
            completion?(Result.success(choice))
        }

        func aitermController(_ sender: AITermController, didFailWithError error: Error) {
            busy = false
            completion?(Result.failure(error))
        }

        func aitermControllerRequestRegistration(_ sender: AITermController,
                                                 completion: @escaping (AITermController.Registration) -> ()) {
            registrationNeeded?(completion)
        }

        func aitermController(_ sender: AITermController, didStreamUpdate update: String?) {
            if let update {
                streaming?(.append(update))
            } else {
                completion?(.success(""))
            }
        }

        func aitermController(_ sender: AITermController, didStreamAttachment attachment: LLM.Message.Attachment) {
            streaming?(.appendAttachment(attachment))
        }

        func aitermController(_ sender: AITermController,
                              didCreateVectorStore id: String,
                              withName name: String) {
            busy = false
            createVectorStoreCompletion?(Result.success(id))
        }

        func aitermController(_ sender: AITermController,
                              didFailToCreateVectorStoreWithError error: Error) {
            busy = false
            createVectorStoreCompletion?(Result.failure(error))

        }

        func aitermController(_ sender: AITermController,
                              didUploadFileWithID id: String) {
            busy = false
            uploadFileCompletion?(Result.success(id))
        }
        func aitermController(_ sender: AITermController,
                              didFailToUploadFileWithError error: Error) {
            busy = false
            uploadFileCompletion?(Result.failure(error))
        }
        func aitermControllerDidAddFilesToVectorStore(_ sender: AITermController) {
            busy = false
            addFilesToVectorStoreCompletion?(nil)
        }

        func aitermControllerDidFailToAddFilesToVectorStore(_ sender: AITermController, error: Error) {
            busy = false
            addFilesToVectorStoreCompletion?(error)
        }

    }

    var messages: [AITermController.Message]
    private var controller: AITermController
    private var delegate = Delegate()
    private(set) weak var registrationProvider: AIRegistrationProvider?
    var maxTokens: Int {
        return Int(iTermPreferences.int(forKey: kPreferenceKeyAITokenLimit) - iTermAdvancedSettingsModel.aiResponseMaxTokens())
    }
    var busy: Bool { delegate.busy }

    init(_ other: AIConversation) {
        self.init(registrationProvider: other.registrationProvider,
                  messages: other.messages,
                  previousResponseID: other.controller.previousResponseID)
        controller.define(functions: other.controller.functions)
    }

    init(registrationProvider: AIRegistrationProvider?,
         messages: [AITermController.Message] = [],
         previousResponseID: String? = nil) {
        self.registrationProvider = registrationProvider
        self.messages = messages
        controller = AITermController(registration: AITermControllerRegistrationHelper.instance.registration)
        controller.previousResponseID = previousResponseID
        controller.delegate = delegate
        let maxTokens = self.maxTokens
        controller.truncate = { truncate(messages: $0, maxTokens: maxTokens) }
    }

    var supportsStreaming: Bool {
        return controller.supportsStreaming
    }
    func removeAllFunctions() {
        controller.removeAllFunctions()
    }

    func define<T: Codable>(function decl: ChatGPTFunctionDeclaration,
                            arguments: T.Type,
                            implementation: @escaping LLM.Function<T>.Impl) {
        controller.define(function: decl, arguments: arguments, implementation: implementation)
    }

    var hostedTools: HostedTools {
        get {
            controller.hostedTools
        }
        set {
            controller.hostedTools = newValue
        }
    }

    var systemMessage: String? {
        didSet {
            if messages.first?.role == .system {
                messages.removeFirst()
            }
            if let systemMessage {
                messages.insert(LLM.Message(role: .system,
                                            content: systemMessage),
                                at: 0)
            }
        }
    }
    mutating func add(_ aiMessage: AITermController.Message) {
        while messages.last?.role == aiMessage.role {
            messages.removeLast()
        }
        messages.append(aiMessage)
    }

    mutating func add(text: String, role: LLM.Role = .user) {
        add(AITermController.Message(role: role, content: text))
    }

    private func cancel() {
        controller.cancel()
        delegate.completion = { _ in }
        delegate.streaming = nil
        delegate.registrationNeeded = { _ in }
        delegate.createVectorStoreCompletion = nil
        delegate.uploadFileCompletion = nil
        delegate.addFilesToVectorStoreCompletion = nil
    }

    func prepare(completion: @escaping (Error?) -> ()) {
        if delegate.busy {
            cancel()
        }
        delegate.registrationNeeded = { [weak registrationProvider] regCompletion in
            if let registrationProvider {
                registrationProvider.registrationProviderRequestRegistration() { registration in
                    if let registration {
                        regCompletion(registration)
                        completion(nil)
                    } else {
                        completion(AIError("You must provide a valid API key to use AI features in iTerm2."))
                    }
                }
            } else {
                DLog("No registration provider found")
                completion(AIError("You must provide a valid API key to use AI features in iTerm2"))
            }
        }
    }

    func createVectorStore(name: String, completion: @escaping (Result<String, Error>) -> ()) {
        if delegate.busy {
            cancel()
        }
        prepare { error in
            if let error {
                completion(.failure(error))
            } else {
                controller.request(createVectorStoreNamed: name)
            }
        }
        delegate.createVectorStoreCompletion = completion
        controller.request(createVectorStoreNamed: name)
    }

    func uploadFile(name: String,
                    content: Data,
                    completion: @escaping (Result<String, Error>) -> ()) {
        if delegate.busy {
            cancel()
        }
        prepare { error in
            if let error {
                completion(.failure(error))
            } else {
                controller.request(uploadFileNamed: name, content: content)
            }
        }
        delegate.uploadFileCompletion = completion
        controller.request(uploadFileNamed: name, content: content)
    }

    func addFilesToVectorStore(fileIDs: [String],
                               vectorStoreID: String,
                               completion: @escaping (Error?) -> ()) {
        if delegate.busy {
            cancel()
        }
        prepare { error in
            if let error {
                completion(error)
            } else {
                controller.request(addFiles: fileIDs, toVectorStore: vectorStoreID)
            }
        }
        delegate.addFilesToVectorStoreCompletion = completion
        controller.request(addFiles: fileIDs, toVectorStore: vectorStoreID)
    }

    mutating func complete(_ completion: @escaping (Result<AIConversation, Error>) -> ()) {
        complete(streaming: nil, completion: completion)
    }

    mutating func complete(streaming: ((LLM.StreamingUpdate) -> ())?,
                           completion: @escaping (Result<AIConversation, Error>) -> ()) {
        precondition(!messages.isEmpty)

        let controller = self.controller
        let messages = self.truncatedMessages
        prepare { error in
            if let error {
                completion(.failure(error))
            } else {
                controller.request(
                    messages: messages,
                    stream: streaming != nil && controller.supportsStreaming)
            }
        }

        var amended = AIConversation(self)
        var accumulator = LLM.Message.Body.uninitialized
        if let streaming {
            delegate.streaming = { [weak controller] update in
                if let previousResponseID = controller?.previousResponseID {
                    amended.controller.previousResponseID = previousResponseID
                }
                switch update {
                case .append(let string):
                    accumulator.append(.text(string))
                case .appendAttachment(let attachment):
                    accumulator.append(.attachment(attachment))
                }
                streaming(update)
            }
        }

        delegate.completion = { [weak controller] result in
            switch result {
            case .success(let text):
                if !text.isEmpty {
                    accumulator.append(.text(text))
                }
                if let previousResponseID = controller?.previousResponseID {
                    amended.controller.previousResponseID = previousResponseID
                }
                let message = AITermController.Message(role: .assistant,
                                                       body: accumulator)
                amended.messages.append(message)
                completion(.success(amended))
            break
            case .failure(let error):
                completion(.failure(error))
            break
            }
        }
        controller.request(messages: truncatedMessages, stream: streaming != nil)
    }

    private var truncatedMessages: [AITermController.Message] {
        if controller.previousResponseID != nil, let lastMessage = messages.last {
            return truncate(messages: [lastMessage], maxTokens: maxTokens)
        }
        return truncate(messages: messages, maxTokens: maxTokens)
    }
}
