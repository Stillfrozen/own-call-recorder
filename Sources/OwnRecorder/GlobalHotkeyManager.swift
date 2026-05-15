import AppKit
import Carbon
import Foundation

enum HotkeyError: Error {
    case invalidFormat(String)
    case unsupportedKey(String)
    case registerFailed(OSStatus)
}

final class GlobalHotkeyManager {
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?

    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var eventHandlerRef: EventHandlerRef?

    private let signature = fourCharCode("OREC")
    private let startID: UInt32 = 1
    private let stopID: UInt32 = 2

    func configure(startShortcut: String, stopShortcut: String) throws {
        unregisterAll()
        installHandlerIfNeeded()

        let start = try Self.parseShortcut(startShortcut)
        try registerHotkey(id: startID, keyCode: start.keyCode, modifiers: start.modifiers)

        let stop = try Self.parseShortcut(stopShortcut)
        try registerHotkey(id: stopID, keyCode: stop.keyCode, modifiers: stop.modifiers)

        Logger.shared.info("GlobalHotkeyManager: start=\(startShortcut), stop=\(stopShortcut)")
    }

    func unregisterAll() {
        for ref in hotKeyRefs.values {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
    }

    private func installHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, userData in
                guard let event, let userData else { return noErr }
                let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                manager.handleHotkeyEvent(event)
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &eventHandlerRef
        )

        if status != noErr {
            Logger.shared.error("GlobalHotkeyManager: InstallEventHandler failed (\(status))")
        }
    }

    private func registerHotkey(id: UInt32, keyCode: UInt32, modifiers: UInt32) throws {
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr, let ref else {
            throw HotkeyError.registerFailed(status)
        }
        hotKeyRefs[id] = ref
    }

    private func handleHotkeyEvent(_ event: EventRef) {
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard status == noErr, hotKeyID.signature == signature else { return }

        switch hotKeyID.id {
        case startID: onStart?()
        case stopID: onStop?()
        default: break
        }
    }

    static func parseShortcut(_ raw: String) throws -> (keyCode: UInt32, modifiers: UInt32) {
        let normalized = raw.lowercased().replacingOccurrences(of: " ", with: "")
        let parts = normalized.split(separator: "+").map(String.init)
        guard let keyPart = parts.last, !keyPart.isEmpty else {
            throw HotkeyError.invalidFormat(raw)
        }

        var modifiers: UInt32 = 0
        for token in parts.dropLast() {
            switch token {
            case "cmd", "command":
                modifiers |= UInt32(cmdKey)
            case "shift":
                modifiers |= UInt32(shiftKey)
            case "alt", "option":
                modifiers |= UInt32(optionKey)
            case "ctrl", "control":
                modifiers |= UInt32(controlKey)
            default:
                throw HotkeyError.invalidFormat(raw)
            }
        }

        guard let keyCode = keyCodeMap[keyPart] else {
            throw HotkeyError.unsupportedKey(keyPart)
        }
        return (keyCode, modifiers)
    }
}

private let keyCodeMap: [String: UInt32] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
    "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
    "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
    "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
    "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
    "space": 49,
]

private func fourCharCode(_ value: String) -> OSType {
    var result: UInt32 = 0
    for scalar in value.unicodeScalars.prefix(4) {
        result = (result << 8) + scalar.value
    }
    return result
}
