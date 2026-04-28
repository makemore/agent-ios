import Foundation

/// Storage service for persisting data
public protocol StorageService {
    func get(_ key: String) -> String?
    func set(_ key: String, value: String?)
}

/// UserDefaults-based storage implementation
public class UserDefaultsStorage: StorageService {
    private let prefix: String
    private let defaults: UserDefaults
    
    public init(prefix: String = "", defaults: UserDefaults = .standard) {
        self.prefix = prefix
        self.defaults = defaults
    }
    
    private func storageKey(_ key: String) -> String {
        prefix.isEmpty ? key : "\(key)_\(prefix)"
    }
    
    public func get(_ key: String) -> String? {
        defaults.string(forKey: storageKey(key))
    }
    
    public func set(_ key: String, value: String?) {
        let fullKey = storageKey(key)
        if let value = value {
            defaults.set(value, forKey: fullKey)
        } else {
            defaults.removeObject(forKey: fullKey)
        }
    }
}

/// In-memory storage for testing
public class InMemoryStorage: StorageService {
    private var storage: [String: String] = [:]
    
    public init() {}
    
    public func get(_ key: String) -> String? {
        storage[key]
    }
    
    public func set(_ key: String, value: String?) {
        if let value = value {
            storage[key] = value
        } else {
            storage.removeValue(forKey: key)
        }
    }
}

