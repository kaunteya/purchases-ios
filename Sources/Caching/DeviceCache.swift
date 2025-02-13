//
//  Copyright RevenueCat Inc. All Rights Reserved.
//
//  Licensed under the MIT License (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//      https://opensource.org/licenses/MIT
//
//  DeviceCache.swift
//
//  Created by Joshua Liebowitz on 7/13/21.
//

import Foundation

// swiftlint:disable file_length
class DeviceCache {

    var cachedAppUserID: String? { return self._cachedAppUserID.value }
    var cachedLegacyAppUserID: String? { return self._cachedLegacyAppUserID.value }
    var cachedOfferings: Offerings? { self.offeringsCachedObject.cachedInstance }

    private let sandboxEnvironmentDetector: SandboxEnvironmentDetector
    private let userDefaults: SynchronizedUserDefaults
    private let offeringsCachedObject: InMemoryCachedObject<Offerings>

    private let _cachedAppUserID: Atomic<String?>
    private let _cachedLegacyAppUserID: Atomic<String?>

    private var userDefaultsObserver: NSObjectProtocol?

    init(sandboxEnvironmentDetector: SandboxEnvironmentDetector,
         userDefaults: UserDefaults,
         offeringsCachedObject: InMemoryCachedObject<Offerings> = .init()) {
        self.sandboxEnvironmentDetector = sandboxEnvironmentDetector
        self.offeringsCachedObject = offeringsCachedObject
        self.userDefaults = .init(userDefaults: userDefaults)
        self._cachedAppUserID = .init(userDefaults.string(forKey: .appUserDefaults))
        self._cachedLegacyAppUserID = .init(userDefaults.string(forKey: .legacyGeneratedAppUserDefaults))

        Logger.verbose(Strings.purchase.device_cache_init(self))
    }

    deinit {
        Logger.verbose(Strings.purchase.device_cache_deinit(self))
    }

    // MARK: - appUserID

    func cache(appUserID: String) {
        self.userDefaults.write {
            $0.setValue(appUserID, forKey: CacheKeys.appUserDefaults)
        }
        self._cachedAppUserID.value = appUserID
    }

    func clearCaches(oldAppUserID: String, andSaveWithNewUserID newUserID: String) {
        self.userDefaults.write { userDefaults in
            userDefaults.removeObject(forKey: CacheKeys.legacyGeneratedAppUserDefaults)
            userDefaults.removeObject(
                forKey: CacheKeyBases.customerInfoAppUserDefaults + oldAppUserID
            )

            // Clear CustomerInfo cache timestamp for oldAppUserID.
            userDefaults.removeObject(forKey: CacheKeyBases.customerInfoLastUpdated + oldAppUserID)

            // Clear offerings cache.
            self.offeringsCachedObject.clearCache()

            // Delete attributes if synced for the old app user id.
            if Self.unsyncedAttributesByKey(userDefaults, appUserID: oldAppUserID).isEmpty {
                var attributes = Self.storedAttributesForAllUsers(userDefaults)
                attributes.removeValue(forKey: oldAppUserID)
                userDefaults.setValue(attributes, forKey: CacheKeys.subscriberAttributes)
            }

            // Cache new appUserID.
            userDefaults.setValue(newUserID, forKey: CacheKeys.appUserDefaults)
            self._cachedAppUserID.value = newUserID
            self._cachedLegacyAppUserID.value = nil
        }
    }

    // MARK: - CustomerInfo

    func cachedCustomerInfoData(appUserID: String) -> Data? {
        return self.userDefaults.read {
            $0.data(forKey: CacheKeyBases.customerInfoAppUserDefaults + appUserID)
        }
    }

    func cache(customerInfo: Data, appUserID: String) {
        self.userDefaults.write {
            $0.set(customerInfo, forKey: CacheKeyBases.customerInfoAppUserDefaults + appUserID)
            Self.setCustomerInfoCacheTimestampToNow($0, appUserID: appUserID)
        }
    }

    func isCustomerInfoCacheStale(appUserID: String, isAppBackgrounded: Bool) -> Bool {
        return self.userDefaults.read {
            guard let cachesLastUpdated = Self.customerInfoLastUpdated($0, appUserID: appUserID) else {
                return true
            }

            let timeSinceLastCheck = cachesLastUpdated.timeIntervalSinceNow * -1
            let cacheDurationInSeconds = self.cacheDurationInSeconds(
                isAppBackgrounded: isAppBackgrounded,
                isSandbox: self.sandboxEnvironmentDetector.isSandbox
            )

            return timeSinceLastCheck >= cacheDurationInSeconds
        }
    }

    func clearCachedOfferings() {
        self.offeringsCachedObject.clearCache()
    }

    func clearCustomerInfoCacheTimestamp(appUserID: String) {
        self.userDefaults.write {
            Self.clearCustomerInfoCacheTimestamp($0, appUserID: appUserID)
        }
    }

    func setCustomerInfoCache(timestamp: Date, appUserID: String) {
        self.userDefaults.write {
            Self.setCustomerInfoCache($0, timestamp: timestamp, appUserID: appUserID)
        }
    }

    func clearCustomerInfoCache(appUserID: String) {
        self.userDefaults.write {
            Self.clearCustomerInfoCacheTimestamp($0, appUserID: appUserID)
            $0.removeObject(forKey: CacheKeyBases.customerInfoAppUserDefaults + appUserID)
        }
    }

    func setCacheTimestampToNowToPreventConcurrentCustomerInfoUpdates(appUserID: String) {
        self.userDefaults.write {
            Self.setCustomerInfoCacheTimestampToNow($0, appUserID: appUserID)
        }
    }

    // MARK: - offerings

    func cache(offerings: Offerings) {
        offeringsCachedObject.cache(instance: offerings)
    }

    func isOfferingsCacheStale(isAppBackgrounded: Bool) -> Bool {
        return offeringsCachedObject.isCacheStale(
            durationInSeconds: self.cacheDurationInSeconds(isAppBackgrounded: isAppBackgrounded,
                                                           isSandbox: self.sandboxEnvironmentDetector.isSandbox)
        )
    }

    func clearOfferingsCacheTimestamp() {
        offeringsCachedObject.clearCacheTimestamp()
    }

    func setOfferingsCacheTimestampToNow() {
        offeringsCachedObject.updateCacheTimestamp(date: Date())
    }

    // MARK: - subscriber attributes

    func store(subscriberAttribute: SubscriberAttribute, appUserID: String) {
        store(subscriberAttributesByKey: [subscriberAttribute.key: subscriberAttribute], appUserID: appUserID)
    }

    func store(subscriberAttributesByKey: [String: SubscriberAttribute], appUserID: String) {
        guard !subscriberAttributesByKey.isEmpty else {
            return
        }

        self.userDefaults.write {
            Self.store($0, subscriberAttributesByKey: subscriberAttributesByKey, appUserID: appUserID)
        }
    }

    func subscriberAttribute(attributeKey: String, appUserID: String) -> SubscriberAttribute? {
        return self.userDefaults.read {
            Self.storedSubscriberAttributes($0, appUserID: appUserID)[attributeKey]
        }
    }

    func unsyncedAttributesByKey(appUserID: String) -> [String: SubscriberAttribute] {
        return self.userDefaults.read {
            Self.unsyncedAttributesByKey($0, appUserID: appUserID)
        }
    }

    func numberOfUnsyncedAttributes(appUserID: String) -> Int {
        return self.unsyncedAttributesByKey(appUserID: appUserID).count
    }

    func cleanupSubscriberAttributes() {
        self.userDefaults.write {
            Self.migrateSubscriberAttributes($0)
            Self.deleteSyncedSubscriberAttributesForOtherUsers($0)
        }
    }

    func unsyncedAttributesForAllUsers() -> [String: [String: SubscriberAttribute]] {
        self.userDefaults.read {
            let attributesDict = $0.dictionary(forKey: CacheKeys.subscriberAttributes) ?? [:]
            var attributes: [String: [String: SubscriberAttribute]] = [:]
            for (appUserID, attributesDictForUser) in attributesDict {
                var attributesForUser: [String: SubscriberAttribute] = [:]
                let attributesDictForUser = attributesDictForUser as? [String: [String: Any]] ?? [:]
                for (attributeKey, attributeDict) in attributesDictForUser {
                    if let attribute = SubscriberAttribute(dictionary: attributeDict), !attribute.isSynced {
                        attributesForUser[attributeKey] = attribute
                    }
                }
                if attributesForUser.count > 0 {
                    attributes[appUserID] = attributesForUser
                }
            }
            return attributes
        }
    }

    func deleteAttributesIfSynced(appUserID: String) {
        self.userDefaults.write {
            guard Self.unsyncedAttributesByKey($0, appUserID: appUserID).isEmpty else {
                return
            }
            Self.deleteAllAttributes($0, appUserID: appUserID)
        }
    }

    func copySubscriberAttributes(oldAppUserID: String, newAppUserID: String) {
        self.userDefaults.write {
            let unsyncedAttributesToCopy = Self.unsyncedAttributesByKey($0, appUserID: oldAppUserID)
            guard !unsyncedAttributesToCopy.isEmpty else {
                return
            }

            Logger.info(Strings.attribution.copying_attributes(oldAppUserID: oldAppUserID, newAppUserID: newAppUserID))
            Self.store($0, subscriberAttributesByKey: unsyncedAttributesToCopy, appUserID: newAppUserID)
            Self.deleteAllAttributes($0, appUserID: oldAppUserID)
        }
    }

    // MARK: - attribution

    func latestAdvertisingIdsByNetworkSent(appUserID: String) -> [AttributionNetwork: String] {
        return self.userDefaults.read {
            let key = CacheKeyBases.attributionDataDefaults + appUserID
            let latestAdvertisingIdsByRawNetworkSent = $0.object(forKey: key) as? [String: String] ?? [:]

            let latestSent: [AttributionNetwork: String] =
                 latestAdvertisingIdsByRawNetworkSent.compactMapKeys { networkKey in
                     guard let networkRawValue = Int(networkKey),
                        let attributionNetwork = AttributionNetwork(rawValue: networkRawValue) else {
                            Logger.error(
                                Strings.attribution.latest_attribution_sent_user_defaults_invalid(
                                    networkKey: networkKey
                                )
                            )
                             return nil
                        }
                        return attributionNetwork
                    }

            return latestSent
        }
    }

    func set(latestAdvertisingIdsByNetworkSent: [AttributionNetwork: String], appUserID: String) {
        self.userDefaults.write {
            let latestAdIdsByRawNetworkStringSent = latestAdvertisingIdsByNetworkSent.mapKeys { String($0.rawValue) }
            $0.setValue(latestAdIdsByRawNetworkStringSent,
                        forKey: CacheKeyBases.attributionDataDefaults + appUserID)
        }
    }

    func clearLatestNetworkAndAdvertisingIdsSent(appUserID: String) {
        self.userDefaults.write {
            $0.removeObject(forKey: CacheKeyBases.attributionDataDefaults + appUserID)
        }
    }

    private func cacheDurationInSeconds(isAppBackgrounded: Bool, isSandbox: Bool) -> TimeInterval {
        return CacheDuration.duration(status: .init(backgrounded: isAppBackgrounded),
                                      environment: .init(sandbox: isSandbox))
    }

    // MARK: - Products Entitlements

    var isProductEntitlementMappingCacheStale: Bool {
        return self.userDefaults.read {
            guard let cacheLastUpdated = Self.productEntitlementMappingLastUpdated($0) else {
                return true
            }

            let cacheAge = Date().timeIntervalSince(cacheLastUpdated)
            return cacheAge > DeviceCache.productEntitlementMappingCacheDuration.seconds
        }
    }

    func store(productEntitlementMapping: ProductEntitlementMapping) {
        self.userDefaults.write {
            Self.store($0, productEntitlementMapping: productEntitlementMapping)
        }
    }

    var cachedProductEntitlementMapping: ProductEntitlementMapping? {
        return self.userDefaults.read(Self.productEntitlementMapping)
    }

    // MARK: - Helper functions

    internal enum CacheKeys: String {

        case legacyGeneratedAppUserDefaults = "com.revenuecat.userdefaults.appUserID"
        case appUserDefaults = "com.revenuecat.userdefaults.appUserID.new"
        case subscriberAttributes = "com.revenuecat.userdefaults.subscriberAttributes"
        case productEntitlementMapping = "com.revenuecat.userdefaults.productEntitlementMapping"
        case productEntitlementMappingLastUpdated = "com.revenuecat.userdefaults.productEntitlementMappingLastUpdated"

    }

    fileprivate enum CacheKeyBases {

        static let keyBase = "com.revenuecat.userdefaults."
        static let customerInfoAppUserDefaults = "\(keyBase)purchaserInfo."
        static let customerInfoLastUpdated = "\(keyBase)purchaserInfoLastUpdated."
        static let legacySubscriberAttributes = "\(keyBase)subscriberAttributes."
        static let attributionDataDefaults = "\(keyBase)attribution."

    }

}

// @unchecked because:
// - Class is not `final` (it's mocked). This implicitly makes subclasses `Sendable` even if they're not thread-safe.
extension DeviceCache: @unchecked Sendable {}

// MARK: - Private

// All methods that modify or read from the UserDefaults data source but require external mechanisms for ensuring
// mutual exclusion.
private extension DeviceCache {

    static func appUserIDsWithLegacyAttributes(_ userDefaults: UserDefaults) -> [String] {
        var appUserIDsWithLegacyAttributes: [String] = []

        let userDefaultsDict = userDefaults.dictionaryRepresentation()
        for key in userDefaultsDict.keys where key.starts(with: CacheKeyBases.keyBase) {
            let appUserID = key.replacingOccurrences(of: CacheKeyBases.legacySubscriberAttributes, with: "")
            appUserIDsWithLegacyAttributes.append(appUserID)
        }

        return appUserIDsWithLegacyAttributes
    }

    static func cachedAppUserID(_ userDefaults: UserDefaults) -> String? {
        userDefaults.string(forKey: CacheKeys.appUserDefaults.rawValue)
    }

    static func storedAttributesForAllUsers(_ userDefaults: UserDefaults) -> [String: Any] {
        let attributes = userDefaults.dictionary(forKey: CacheKeys.subscriberAttributes) ?? [:]
        return attributes
    }

    static func customerInfoLastUpdated(
        _ userDefaults: UserDefaults,
        appUserID: String
    ) -> Date? {
        return userDefaults.object(forKey: CacheKeyBases.customerInfoLastUpdated + appUserID) as? Date
    }

    static func clearCustomerInfoCacheTimestamp(
        _ userDefaults: UserDefaults,
        appUserID: String
    ) {
        userDefaults.removeObject(forKey: CacheKeyBases.customerInfoLastUpdated + appUserID)
    }

    static func unsyncedAttributesByKey(
        _ userDefaults: UserDefaults,
        appUserID: String
    ) -> [String: SubscriberAttribute] {
        let allSubscriberAttributesByKey = Self.storedSubscriberAttributes(
            userDefaults,
            appUserID: appUserID
        )
        var unsyncedAttributesByKey: [String: SubscriberAttribute] = [:]
        for attribute in allSubscriberAttributesByKey.values where !attribute.isSynced {
            unsyncedAttributesByKey[attribute.key] = attribute
        }
        return unsyncedAttributesByKey
    }

    static func store(
        _ userDefaults: UserDefaults,
        subscriberAttributesByKey: [String: SubscriberAttribute],
        appUserID: String
    ) {
        var groupedSubscriberAttributes = Self.storedAttributesForAllUsers(userDefaults)
        var subscriberAttributesForAppUserID = groupedSubscriberAttributes[appUserID] as? [String: Any] ?? [:]
        for (key, attributes) in subscriberAttributesByKey {
            subscriberAttributesForAppUserID[key] = attributes.asDictionary()
        }
        groupedSubscriberAttributes[appUserID] = subscriberAttributesForAppUserID
        userDefaults.setValue(groupedSubscriberAttributes, forKey: .subscriberAttributes)
    }

    static func deleteAllAttributes(
        _ userDefaults: UserDefaults,
        appUserID: String
    ) {
        var groupedAttributes = Self.storedAttributesForAllUsers(userDefaults)
        let attributesForAppUserID = groupedAttributes.removeValue(forKey: appUserID)
        guard attributesForAppUserID != nil else {
            Logger.warn(Strings.identity.deleting_attributes_none_found)
            return
        }
        userDefaults.setValue(groupedAttributes, forKey: .subscriberAttributes)
    }

    static func setCustomerInfoCache(
        _ userDefaults: UserDefaults,
        timestamp: Date,
        appUserID: String
    ) {
        userDefaults.setValue(timestamp, forKey: CacheKeyBases.customerInfoLastUpdated + appUserID)
    }

    static func setCustomerInfoCacheTimestampToNow(
        _ userDefaults: UserDefaults,
        appUserID: String
    ) {
        Self.setCustomerInfoCache(userDefaults, timestamp: Date(), appUserID: appUserID)
    }

    static func subscriberAttributes(
        _ userDefaults: UserDefaults,
        appUserID: String
    ) -> [String: Any] {
        return Self.storedAttributesForAllUsers(userDefaults)[appUserID] as? [String: Any] ?? [:]
    }

    static func storedSubscriberAttributes(
        _ userDefaults: UserDefaults,
        appUserID: String
    ) -> [String: SubscriberAttribute] {
        let allAttributesObjectsByKey = Self.subscriberAttributes(userDefaults, appUserID: appUserID)
        var allSubscriberAttributesByKey: [String: SubscriberAttribute] = [:]
        for (key, attributeDict) in allAttributesObjectsByKey {
            if let dictionary = attributeDict as? [String: Any],
                let attribute = SubscriberAttribute(dictionary: dictionary) {
                allSubscriberAttributesByKey[key] = attribute
            }
        }

        return allSubscriberAttributesByKey
    }

    static func migrateSubscriberAttributes(_ userDefaults: UserDefaults) {
        let appUserIDsWithLegacyAttributes = Self.appUserIDsWithLegacyAttributes(userDefaults)
        var attributesInNewFormat = userDefaults.dictionary(forKey: CacheKeys.subscriberAttributes) ?? [:]
        for appUserID in appUserIDsWithLegacyAttributes {
            let legacyAttributes = userDefaults.dictionary(
                forKey: CacheKeyBases.legacySubscriberAttributes + appUserID) ?? [:]
            let existingAttributes = Self.subscriberAttributes(userDefaults,
                                                               appUserID: appUserID)
            let allAttributesForUser = legacyAttributes.merging(existingAttributes)
            attributesInNewFormat[appUserID] = allAttributesForUser

            let legacyAttributesKey = CacheKeyBases.legacySubscriberAttributes + appUserID
            userDefaults.removeObject(forKey: legacyAttributesKey)

        }
        userDefaults.setValue(attributesInNewFormat, forKey: CacheKeys.subscriberAttributes)
    }

    static func deleteSyncedSubscriberAttributesForOtherUsers(
        _ userDefaults: UserDefaults
    ) {
        let allStoredAttributes: [String: [String: Any]]
        = userDefaults.dictionary(forKey: CacheKeys.subscriberAttributes)
        as? [String: [String: Any]] ?? [:]

        var filteredAttributes: [String: Any] = [:]

        let currentAppUserID = Self.cachedAppUserID(userDefaults)!

        filteredAttributes[currentAppUserID] = allStoredAttributes[currentAppUserID]

        for appUserID in allStoredAttributes.keys where appUserID != currentAppUserID {
            var unsyncedAttributesForUser: [String: [String: Any]] = [:]
            let allStoredAttributesForAppUserID = allStoredAttributes[appUserID] as? [String: [String: Any]] ?? [:]
            for (attributeKey, storedAttributesForUser) in allStoredAttributesForAppUserID {
                if let attribute = SubscriberAttribute(dictionary: storedAttributesForUser), !attribute.isSynced {
                    unsyncedAttributesForUser[attributeKey] = storedAttributesForUser
                }
            }

            if !unsyncedAttributesForUser.isEmpty {
                filteredAttributes[appUserID] = unsyncedAttributesForUser
            }
        }

        userDefaults.setValue(filteredAttributes, forKey: .subscriberAttributes)
    }

    static func productEntitlementMappingLastUpdated(_ userDefaults: UserDefaults) -> Date? {
        return userDefaults.date(forKey: .productEntitlementMappingLastUpdated)
    }

    static func productEntitlementMapping(_ userDefaults: UserDefaults) -> ProductEntitlementMapping? {
        return userDefaults.value(forKey: .productEntitlementMapping)
    }

    static func store(
        _ userDefaults: UserDefaults,
        productEntitlementMapping mapping: ProductEntitlementMapping
    ) {
        guard let data = try? JSONEncoder.default.encode(value: mapping, logErrors: true) else {
            return
        }

        userDefaults.setValue(data, forKey: .productEntitlementMapping)
        userDefaults.setValue(Date(), forKey: .productEntitlementMappingLastUpdated)
    }

}

fileprivate extension UserDefaults {

    func value<T: Decodable>(forKey key: DeviceCache.CacheKeys) -> T? {
        guard let data = self.data(forKey: key.rawValue) else {
            return nil
        }

        return try? JSONDecoder.default.decode(jsonData: data)
    }

    func setValue(_ value: Any?, forKey key: DeviceCache.CacheKeys) {
        self.setValue(value, forKey: key.rawValue)
    }

    func string(forKey defaultName: DeviceCache.CacheKeys) -> String? {
        return self.string(forKey: defaultName.rawValue)
    }

    func removeObject(forKey defaultName: DeviceCache.CacheKeys) {
        self.removeObject(forKey: defaultName.rawValue)
    }

    func dictionary(forKey defaultName: DeviceCache.CacheKeys) -> [String: Any]? {
        return self.dictionary(forKey: defaultName.rawValue)
    }

    func date(forKey defaultName: DeviceCache.CacheKeys) -> Date? {
        return self.object(forKey: defaultName.rawValue) as? Date
    }

}

private extension DeviceCache {

    enum CacheDuration {

        // swiftlint:disable:next nesting
        enum AppStatus {

            case foreground
            case background

            init(backgrounded: Bool) {
                self = backgrounded ? .background : .foreground
            }

        }

        // swiftlint:disable:next nesting
        enum Environment {

            case production
            case sandbox

            init(sandbox: Bool) {
                self = sandbox ? .sandbox : .production
            }

        }

        static func duration(status: AppStatus, environment: Environment) -> TimeInterval {
            switch (environment, status) {
            case (.production, .foreground): return 60 * 5.0
            case (.production, .background): return 60 * 60 * 25.0

            case (.sandbox, .foreground): return 60 * 5.0
            case (.sandbox, .background): return 60 * 5.0
            }
        }

    }

    static let productEntitlementMappingCacheDuration: DispatchTimeInterval = .hours(25)

}

// swiftlint:enable file_length
