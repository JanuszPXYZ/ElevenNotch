//
//  PublishedPersist.swift
//  ElevenNotch
//
//  Created by Janusz Polowczyk on 26/03/2026.
//

import Combine
import Foundation

protocol PersistenceProviding {
    func data(forKey: String) -> Data?
    func set(_ data: Data?, forKey: String)
}

final class FileStorage: PersistenceProviding {
    private static let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    private var configDir = documentsDir.appendingPathComponent("Config")



    func pathForKey(_ key: String) -> URL {
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        return configDir.appendingPathComponent(key)
    }

    func data(forKey key: String) -> Data? {
        try? Data(contentsOf: pathForKey(key))
    }

    func set(_ data: Data?, forKey key: String) {
        try? data?.write(to: pathForKey(key))
    }
}

@propertyWrapper
struct Persist<Value: Codable> {
    private let currentSubject: CurrentValueSubject<Value, Never>
    private let cancellables: Set<AnyCancellable>

    var projectedValue: AnyPublisher<Value, Never> {
        currentSubject.eraseToAnyPublisher()
    }

    init(key: String, defaultValue: Value, engine: PersistenceProviding) {
        if let data = engine.data(forKey: key),
           let object = try? JSONDecoder().decode(Value.self, from: data) {
            currentSubject = CurrentValueSubject<Value, Never>(object)
        } else {
            currentSubject = CurrentValueSubject<Value, Never>(defaultValue)
        }

        var cancellables: Set<AnyCancellable> = []
        currentSubject
            .receive(on: DispatchQueue.global())
            .map { try? JSONEncoder().encode($0) }
            .removeDuplicates()
            .sink { engine.set($0, forKey: key) }
            .store(in: &cancellables)
        self.cancellables = cancellables
    }

    var wrappedValue: Value {
        get { currentSubject.value }
        set { currentSubject.send(newValue) }
    }
}

@propertyWrapper
struct PublishedPersist<Value: Codable> {
    @Persist private var value: Value

    var projectedValue: AnyPublisher<Value, Never>{ $value }

    @available(*, unavailable, message: "Accessing wrappedValue will result in undefined behavior")

    var wrappedValue: Value {
        get { value }
        set { value = newValue }
    }

    static subscript<EnclosingSelf: ObservableObject>(_enclosingInstance object: EnclosingSelf, wrapped _: ReferenceWritableKeyPath<EnclosingSelf, Value>, storage storageKeyPath: ReferenceWritableKeyPath<EnclosingSelf, PublishedPersist<Value>>) -> Value {
        get { object[keyPath: storageKeyPath].value }
        set {
            (object.objectWillChange as? ObservableObjectPublisher)?.send()
            object[keyPath: storageKeyPath].value = newValue
        }
    }

    init(key: String, defaultValue: Value, engine: PersistenceProviding) {
        _value = .init(key: key, defaultValue: defaultValue, engine: engine)
    }
}

extension Persist {
    init(key: String, defaultValue: Value) {
        self.init(key: key, defaultValue: defaultValue, engine: FileStorage())
    }
}

extension PublishedPersist {
    init(key: String, defaultValue: Value) {
        self.init(key: key, defaultValue: defaultValue, engine: FileStorage())
    }
}
