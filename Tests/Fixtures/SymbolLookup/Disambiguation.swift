// Test fixture for symbol disambiguation - same names in different contexts

// swift-format-ignore: AlwaysUseLowerCamelCase

import Foundation

// MARK: - Same Property Name in Different Types

struct User {
    let id: UUID
    var name: String
    var email: String

    func validate() -> Bool {
        !name.isEmpty && email.contains("@")
    }

    func reset() {
        // User-specific reset
    }
}

struct Product {
    let id: UUID
    var name: String
    var price: Decimal

    func validate() -> Bool {
        price > 0
    }

    func reset() {
        // Product-specific reset
    }
}

struct Order {
    let id: UUID
    var items: [Product]
    var total: Decimal

    func validate() -> Bool {
        !items.isEmpty && total > 0
    }

    func reset() {
        // Order-specific reset
    }
}

// MARK: - Same Static Property Name

class NetworkManager {
    static let shared = NetworkManager()
    static let defaultTimeout: TimeInterval = 30

    var isConnected: Bool = false

    func connect() async {
        isConnected = true
    }

    func disconnect() {
        isConnected = false
    }
}

class CacheManager {
    static let shared = CacheManager()
    static let defaultTimeout: TimeInterval = 60

    var isConnected: Bool = false

    func connect() async {
        isConnected = true
    }

    func disconnect() {
        isConnected = false
    }
}

class DatabaseManager {
    static let shared = DatabaseManager()
    static let defaultTimeout: TimeInterval = 120

    var isConnected: Bool = false

    func connect() async {
        isConnected = true
    }

    func disconnect() {
        isConnected = false
    }
}

// MARK: - Same Nested Type Name

struct APIResponse<T> {
    struct Error {
        let code: Int
        let message: String
    }

    let data: T?
    let error: Error?
}

struct ValidationResult {
    struct Error {
        let field: String
        let reason: String
    }

    let isValid: Bool
    let errors: [Error]
}

struct ParseResult {
    struct Error {
        let position: Int
        let description: String
    }

    let value: Any?
    let error: Error?
}

// MARK: - Same Enum Case Names

enum UserStatus {
    case active
    case inactive
    case pending
    case deleted
}

enum OrderStatus {
    case active
    case inactive
    case pending
    case cancelled
    case shipped
}

enum SubscriptionStatus {
    case active
    case inactive
    case pending
    case expired
}

// MARK: - Same Method Name with Different Signatures

protocol DataSource {
    func fetch() async throws -> Data
    func fetch(id: String) async throws -> Data
    func fetch(ids: [String]) async throws -> [Data]
}

class LocalDataSource: DataSource {
    func fetch() async throws -> Data {
        Data()
    }

    func fetch(id: String) async throws -> Data {
        Data()
    }

    func fetch(ids: [String]) async throws -> [Data] {
        []
    }
}

class RemoteDataSource: DataSource {
    func fetch() async throws -> Data {
        Data()
    }

    func fetch(id: String) async throws -> Data {
        Data()
    }

    func fetch(ids: [String]) async throws -> [Data] {
        []
    }
}

// MARK: - Same Name in Different Scopes (Local vs Member)

class Calculator {
    var result: Double = 0

    func add(_ value: Double) {
        let result = self.result + value  // Local shadows member
        self.result = result
    }

    func multiply(_ value: Double) {
        var result = self.result  // Local shadows member
        result *= value
        self.result = result
    }
}

// MARK: - Same Name: Type vs Instance

struct Config {
    static var Config: String = "default"  // Static property named same as type

    var value: String

    init(value: String = Config.Config) {
        self.value = value
    }
}

// MARK: - Extension Methods with Same Name

extension User {
    func format() -> String {
        "\(name) <\(email)>"
    }
}

extension Product {
    func format() -> String {
        "\(name): $\(price)"
    }
}

extension Order {
    func format() -> String {
        "Order \(id): \(items.count) items, $\(total)"
    }
}

// MARK: - Protocol with Same Method Implemented Differently

protocol Describable {
    func describe() -> String
}

extension User: Describable {
    func describe() -> String {
        "User: \(name)"
    }
}

extension Product: Describable {
    func describe() -> String {
        "Product: \(name) at \(price)"
    }
}

// MARK: - Free Functions with Same Name (Different Modules would have this)

func process(_ user: User) -> String {
    "Processing user: \(user.name)"
}

func process(_ product: Product) -> String {
    "Processing product: \(product.name)"
}

func process(_ order: Order) -> String {
    "Processing order with \(order.items.count) items"
}
