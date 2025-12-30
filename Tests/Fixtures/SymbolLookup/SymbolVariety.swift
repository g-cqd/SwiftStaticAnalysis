// Test fixture for symbol lookup with variety of symbol types

import Foundation

// MARK: - Protocols

public protocol Cacheable {
    associatedtype Key: Hashable
    func cache(forKey key: Key)
    func retrieve(forKey key: Key) -> Self?
}

protocol InternalService {
    var isRunning: Bool { get }
    func start() async throws
    func stop() async
}

// MARK: - Classes

public final class NetworkMonitor {
    public static let shared = NetworkMonitor()

    public private(set) var isConnected: Bool = false

    private init() {}

    public func checkConnection() async -> Bool {
        isConnected = true
        return isConnected
    }

    public func disconnect() {
        isConnected = false
    }
}

class DataManager: InternalService {
    static let defaultManager = DataManager()

    var isRunning: Bool = false
    private var cache: [String: Any] = [:]

    func start() async throws {
        isRunning = true
    }

    func stop() async {
        isRunning = false
        cache.removeAll()
    }

    func store(_ value: Any, forKey key: String) {
        cache[key] = value
    }

    func fetch(forKey key: String) -> Any? {
        cache[key]
    }
}

// MARK: - Structs

public struct User: Codable, Hashable {
    public let id: UUID
    public var name: String
    public var email: String

    public init(id: UUID = UUID(), name: String, email: String) {
        self.id = id
        self.name = name
        self.email = email
    }
}

struct Configuration {
    static let `default` = Configuration()

    var timeout: TimeInterval = 30
    var retryCount: Int = 3
    var baseURL: URL?

    mutating func reset() {
        timeout = 30
        retryCount = 3
        baseURL = nil
    }
}

// MARK: - Enums

public enum NetworkError: Error, LocalizedError {
    case connectionFailed
    case timeout(seconds: Int)
    case invalidResponse(statusCode: Int)
    case decodingFailed(underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .connectionFailed: return "Connection failed"
        case .timeout(let seconds): return "Timeout after \(seconds)s"
        case .invalidResponse(let code): return "Invalid response: \(code)"
        case .decodingFailed(let error): return "Decoding failed: \(error)"
        }
    }
}

enum CachePolicy {
    case never
    case memory(duration: TimeInterval)
    case disk(maxSize: Int)

    var shouldCache: Bool {
        if case .never = self { return false }
        return true
    }
}

// MARK: - Actors

actor CacheManager: Cacheable {
    typealias Key = String

    private var storage: [String: Data] = [:]

    func cache(forKey key: String) {
        // Implementation
    }

    func retrieve(forKey key: String) -> CacheManager? {
        nil
    }

    func store(_ data: Data, forKey key: String) {
        storage[key] = data
    }

    func load(forKey key: String) -> Data? {
        storage[key]
    }

    func clear() {
        storage.removeAll()
    }
}

// MARK: - Nested Types

public struct APIClient {
    public struct Request {
        public let method: Method
        public let path: String
        public var headers: [String: String] = [:]

        public enum Method: String {
            case get = "GET"
            case post = "POST"
            case put = "PUT"
            case delete = "DELETE"
        }
    }

    public struct Response {
        public let statusCode: Int
        public let data: Data?
        public let headers: [String: String]

        public var isSuccess: Bool {
            (200..<300).contains(statusCode)
        }
    }

    public let baseURL: URL

    public init(baseURL: URL) {
        self.baseURL = baseURL
    }

    public func execute(_ request: Request) async throws -> Response {
        Response(statusCode: 200, data: nil, headers: [:])
    }
}

// MARK: - Generic Types

public struct Container<T> {
    public var value: T

    public init(value: T) {
        self.value = value
    }

    public func map<U>(_ transform: (T) -> U) -> Container<U> {
        Container<U>(value: transform(value))
    }
}

public class Observable<Value> {
    public typealias Observer = (Value) -> Void

    private var observers: [UUID: Observer] = [:]
    private var _value: Value

    public var value: Value {
        get { _value }
        set {
            _value = newValue
            notifyObservers()
        }
    }

    public init(_ initialValue: Value) {
        self._value = initialValue
    }

    @discardableResult
    public func observe(_ observer: @escaping Observer) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    public func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    private func notifyObservers() {
        for observer in observers.values {
            observer(_value)
        }
    }
}

// MARK: - Extensions

extension User {
    static let guest = User(name: "Guest", email: "guest@example.com")

    var displayName: String {
        name.isEmpty ? "Anonymous" : name
    }

    func validate() throws {
        guard !name.isEmpty else {
            throw ValidationError.emptyName
        }
        guard email.contains("@") else {
            throw ValidationError.invalidEmail
        }
    }

    enum ValidationError: Error {
        case emptyName
        case invalidEmail
    }
}

extension Array where Element == User {
    func sortedByName() -> [User] {
        sorted { $0.name < $1.name }
    }
}

// MARK: - Free Functions

public func createDefaultUser() -> User {
    User(name: "Default", email: "default@example.com")
}

func internalHelper(_ value: Int) -> Int {
    value * 2
}

private func privateHelper() -> String {
    "helper"
}

// MARK: - Global Variables

public let defaultTimeout: TimeInterval = 30
var internalCounter: Int = 0
private var privateState: Bool = false

// MARK: - Typealiases

public typealias UserID = UUID
public typealias Completion<T> = (Result<T, Error>) -> Void
typealias InternalHandler = () -> Void
