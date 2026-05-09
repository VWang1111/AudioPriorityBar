import Foundation

struct StoredDevice: Codable, Equatable {
    let uid: String
    let name: String
    let isInput: Bool
    var lastSeen: Date

    var lastSeenRelative: String {
        let now = Date()
        let interval = now.timeIntervalSince(lastSeen)

        if interval < 60 {
            return "now"
        } else if interval < 3600 {
            let mins = Int(interval / 60)
            return "\(mins)m ago"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours)h ago"
        } else if interval < 604800 {
            let days = Int(interval / 86400)
            return "\(days)d ago"
        } else if interval < 2592000 {
            let weeks = Int(interval / 604800)
            return "\(weeks)w ago"
        } else {
            let months = Int(interval / 2592000)
            return "\(months)mo ago"
        }
    }
}

class PriorityManager {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private let inputPrioritiesKey = "inputPriorities"
    private let speakerPrioritiesKey = "speakerPriorities"
    private let headphonePrioritiesKey = "headphonePriorities"
    private let deviceCategoriesKey = "deviceCategories"
    private let currentModeKey = "currentMode"
    private let customModeKey = "customMode"
    private let hiddenDevicesKey = "hiddenDevices"
    private let knownDevicesKey = "knownDevices"

    // MARK: - Known Devices (Persistent Memory)

    func getKnownDevices() -> [StoredDevice] {
        guard let data = defaults.data(forKey: knownDevicesKey),
              let devices = try? JSONDecoder().decode([StoredDevice].self, from: data) else {
            return []
        }
        return devices
    }

    func rememberDevice(_ uid: String, name: String, isInput: Bool) {
        var known = getKnownDevices()
        let now = Date()
        if let index = known.firstIndex(where: { $0.uid == uid }) {
            // Update name and lastSeen
            known[index] = StoredDevice(uid: uid, name: name, isInput: isInput, lastSeen: now)
        } else {
            known.append(StoredDevice(uid: uid, name: name, isInput: isInput, lastSeen: now))
        }
        saveKnownDevices(known)
    }

    func getStoredDevice(uid: String) -> StoredDevice? {
        getKnownDevices().first { $0.uid == uid }
    }

    func forgetDevice(_ uid: String) {
        var known = getKnownDevices()
        known.removeAll { $0.uid == uid }
        saveKnownDevices(known)
    }

    private func saveKnownDevices(_ devices: [StoredDevice]) {
        if let data = try? JSONEncoder().encode(devices) {
            defaults.set(data, forKey: knownDevicesKey)
        }
    }

    /// Some devices (notably HDMI/DisplayPort display audio like the Samsung
    /// C34J79x) report a fresh UID every reconnect, so without this we
    /// accumulate dozens of duplicate "known device" entries with the same
    /// name. Group by (name, isInput); for each duplicate group, keep the one
    /// that's currently connected (or the most recently seen if none are), and
    /// migrate UIDs in every priority/hide/category list so the survivor
    /// inherits the user's settings.
    func consolidateDuplicates(connectedUIDs: Set<String>) {
        let known = getKnownDevices()
        var groups: [String: [StoredDevice]] = [:]
        for device in known {
            let key = "\(device.isInput ? "in" : "out")|\(device.name)"
            groups[key, default: []].append(device)
        }

        var survivors: [StoredDevice] = []
        var migrations: [(from: String, to: String)] = []

        for (_, entries) in groups {
            guard entries.count > 1 else {
                survivors.append(contentsOf: entries)
                continue
            }
            let connected = entries.filter { connectedUIDs.contains($0.uid) }
            // Two devices with the same name both physically present is rare
            // but possible — assume they're distinct hardware and leave alone.
            if connected.count > 1 {
                survivors.append(contentsOf: entries)
                continue
            }
            let survivor = connected.first ?? entries.max(by: { $0.lastSeen < $1.lastSeen })!
            survivors.append(survivor)
            for entry in entries where entry.uid != survivor.uid {
                migrations.append((from: entry.uid, to: survivor.uid))
            }
        }

        guard !migrations.isEmpty else { return }

        // Preserve original ordering of survivors as much as possible by
        // re-walking the original list and keeping the first survivor seen per
        // group key.
        var seenSurvivorUIDs = Set(survivors.map { $0.uid })
        var orderedSurvivors: [StoredDevice] = []
        for device in known where seenSurvivorUIDs.contains(device.uid) {
            orderedSurvivors.append(device)
            seenSurvivorUIDs.remove(device.uid)
        }
        saveKnownDevices(orderedSurvivors)

        for (from, to) in migrations {
            migrateUID(from: from, to: to)
        }
    }

    private func migrateUID(from oldUID: String, to newUID: String) {
        let arrayKeys = [
            inputPrioritiesKey, speakerPrioritiesKey, headphonePrioritiesKey,
            hiddenMicsKey, hiddenSpeakersKey, hiddenHeadphonesKey, neverUseKey
        ]
        for key in arrayKeys {
            guard var arr = defaults.array(forKey: key) as? [String] else { continue }
            if arr.contains(newUID) {
                arr.removeAll { $0 == oldUID }
            } else if let idx = arr.firstIndex(of: oldUID) {
                arr[idx] = newUID
            } else {
                continue
            }
            defaults.set(arr, forKey: key)
        }
        if var categories = defaults.dictionary(forKey: deviceCategoriesKey) as? [String: String],
           let cat = categories[oldUID] {
            categories.removeValue(forKey: oldUID)
            if categories[newUID] == nil {
                categories[newUID] = cat
            }
            defaults.set(categories, forKey: deviceCategoriesKey)
        }
    }

    // MARK: - Mode Management

    var currentMode: OutputCategory {
        get {
            guard let raw = defaults.string(forKey: currentModeKey),
                  let mode = OutputCategory(rawValue: raw) else {
                return .speaker
            }
            return mode
        }
        set {
            defaults.set(newValue.rawValue, forKey: currentModeKey)
        }
    }

    var isCustomMode: Bool {
        get { defaults.bool(forKey: customModeKey) }
        set { defaults.set(newValue, forKey: customModeKey) }
    }

    // MARK: - Device Categories

    func getCategory(for device: AudioDevice) -> OutputCategory {
        let categories = defaults.dictionary(forKey: deviceCategoriesKey) as? [String: String] ?? [:]
        if let raw = categories[device.uid], let category = OutputCategory(rawValue: raw) {
            return category
        }
        // Default headphone-like devices to headphone category
        if HeadphoneDetection.isHeadphone(deviceName: device.name) {
            return .headphone
        }
        return .speaker
    }

    func setCategory(_ category: OutputCategory, for device: AudioDevice) {
        var categories = defaults.dictionary(forKey: deviceCategoriesKey) as? [String: String] ?? [:]
        categories[device.uid] = category.rawValue
        defaults.set(categories, forKey: deviceCategoriesKey)
    }

    // MARK: - Never Use Devices (never auto-selected)

    private let neverUseKey = "neverUseDevices"

    func isNeverUse(_ device: AudioDevice) -> Bool {
        let list = defaults.array(forKey: neverUseKey) as? [String] ?? []
        return list.contains(device.uid)
    }

    func setNeverUse(_ device: AudioDevice, neverUse: Bool) {
        var list = defaults.array(forKey: neverUseKey) as? [String] ?? []
        if neverUse {
            if !list.contains(device.uid) {
                list.append(device.uid)
            }
        } else {
            list.removeAll { $0 == device.uid }
        }
        defaults.set(list, forKey: neverUseKey)
    }

    // MARK: - Hidden Devices (per category)

    private let hiddenMicsKey = "hiddenMics"
    private let hiddenSpeakersKey = "hiddenSpeakers"
    private let hiddenHeadphonesKey = "hiddenHeadphones"

    func isHidden(_ device: AudioDevice) -> Bool {
        let key = hiddenKey(for: device)
        let hidden = defaults.array(forKey: key) as? [String] ?? []
        return hidden.contains(device.uid)
    }

    func isHidden(_ device: AudioDevice, inCategory category: OutputCategory) -> Bool {
        let key = category == .speaker ? hiddenSpeakersKey : hiddenHeadphonesKey
        let hidden = defaults.array(forKey: key) as? [String] ?? []
        return hidden.contains(device.uid)
    }

    func hideDevice(_ device: AudioDevice) {
        let key = hiddenKey(for: device)
        var hidden = defaults.array(forKey: key) as? [String] ?? []
        if !hidden.contains(device.uid) {
            hidden.append(device.uid)
            defaults.set(hidden, forKey: key)
        }
    }

    func hideDevice(_ device: AudioDevice, inCategory category: OutputCategory) {
        let key = category == .speaker ? hiddenSpeakersKey : hiddenHeadphonesKey
        var hidden = defaults.array(forKey: key) as? [String] ?? []
        if !hidden.contains(device.uid) {
            hidden.append(device.uid)
            defaults.set(hidden, forKey: key)
        }
    }

    func unhideDevice(_ device: AudioDevice) {
        let key = hiddenKey(for: device)
        var hidden = defaults.array(forKey: key) as? [String] ?? []
        hidden.removeAll { $0 == device.uid }
        defaults.set(hidden, forKey: key)
    }

    func unhideDevice(_ device: AudioDevice, fromCategory category: OutputCategory) {
        let key = category == .speaker ? hiddenSpeakersKey : hiddenHeadphonesKey
        var hidden = defaults.array(forKey: key) as? [String] ?? []
        hidden.removeAll { $0 == device.uid }
        defaults.set(hidden, forKey: key)
    }

    private func hiddenKey(for device: AudioDevice) -> String {
        if device.type == .input {
            return hiddenMicsKey
        } else {
            let category = getCategory(for: device)
            return category == .speaker ? hiddenSpeakersKey : hiddenHeadphonesKey
        }
    }

    // MARK: - Priority Management

    func sortByPriority(_ devices: [AudioDevice], type: AudioDeviceType) -> [AudioDevice] {
        let key = priorityKey(for: type, category: nil)
        return sortDevices(devices, usingKey: key)
    }

    func sortByPriority(_ devices: [AudioDevice], category: OutputCategory) -> [AudioDevice] {
        let key = priorityKey(for: .output, category: category)
        return sortDevices(devices, usingKey: key)
    }

    func savePriorities(_ devices: [AudioDevice], type: AudioDeviceType) {
        let key = priorityKey(for: type, category: nil)
        savePriorities(devices, key: key)
    }

    func savePriorities(_ devices: [AudioDevice], category: OutputCategory) {
        let key = priorityKey(for: .output, category: category)
        savePriorities(devices, key: key)
    }

    // MARK: - Private Helpers

    private func priorityKey(for type: AudioDeviceType, category: OutputCategory?) -> String {
        switch type {
        case .input:
            return inputPrioritiesKey
        case .output:
            switch category {
            case .speaker, .none:
                return speakerPrioritiesKey
            case .headphone:
                return headphonePrioritiesKey
            }
        }
    }

    private func sortDevices(_ devices: [AudioDevice], usingKey key: String) -> [AudioDevice] {
        let priorities = defaults.array(forKey: key) as? [String] ?? []

        return devices.sorted { a, b in
            let indexA = priorities.firstIndex(of: a.uid) ?? Int.max
            let indexB = priorities.firstIndex(of: b.uid) ?? Int.max
            return indexA < indexB
        }
    }

    private func savePriorities(_ devices: [AudioDevice], key: String) {
        // Merge new ordering into the existing saved list so that disconnected,
        // hidden, and never-use devices keep their saved positions even when the
        // user reorders only the subset currently visible in the menu.
        let newOrder = devices.map { $0.uid }
        let displayed = Set(newOrder)
        let existing = defaults.array(forKey: key) as? [String] ?? []

        var result: [String] = []
        var newIter = newOrder.makeIterator()

        for oldUID in existing {
            if displayed.contains(oldUID) {
                if let next = newIter.next() {
                    result.append(next)
                }
            } else {
                result.append(oldUID)
            }
        }

        // Append any new UIDs that weren't in the existing saved list (e.g.
        // first time we've seen this device).
        while let next = newIter.next() {
            if !result.contains(next) {
                result.append(next)
            }
        }

        defaults.set(result, forKey: key)
    }
}
