//
//  ApplicationController.swift
//  ravenwallet
//
//  Created by Adrian Corscadden on 2016-10-21.
//  Copyright © 2018 Ravenwallet Team. All rights reserved.
//

import UIKit
import BRCore

private let timeSinceLastExitKey = "TimeSinceLastExit"
private let shouldRequireLoginTimeoutKey = "ShouldRequireLoginTimeoutKey"

class ApplicationController : Subscriber, Trackable {

    let window = UIWindow()
    private var startFlowController: StartFlowPresenter?
    private var modalPresenter: ModalPresenter?
    private var walletManagers = [String: WalletManager]()
    private var walletCoordinator: WalletCoordinator?
    private var exchangeUpdaters = [String: ExchangeUpdater]()
    private var feeUpdaters = [String: FeeUpdater]()
    private var primaryWalletManager: WalletManager {
        return walletManagers[Currencies.rvn.code]!
    }
    
    private var kvStoreCoordinator: KVStoreCoordinator?
    fileprivate var application: UIApplication?
    private let watchSessionManager = PhoneWCSessionManager()
    private var urlController: URLController?
    private var defaultsUpdater: UserDefaultsUpdater?
    private var reachability = ReachabilityMonitor()
    private let noAuthApiClient = BRAPIClient(authenticator: NoAuthAuthenticator())
    private var fetchCompletionHandler: ((UIBackgroundFetchResult) -> Void)?
    private var launchURL: URL?
    private var hasPerformedWalletDependentInitialization = false
    private var didInitWallet = false

    init() {
        guardProtected(queue: DispatchQueue.walletQueue) {
                self.initWallet(completion: self.didAttemptInitWallet)
        }
    }

    private func initWallet(completion: @escaping () -> Void) {
        let dispatchGroup = DispatchGroup()
        Store.state.currencies.forEach { currency in
            initWallet(currency: currency, dispatchGroup: dispatchGroup)
        }
        dispatchGroup.notify(queue: .main) {
            completion()
        }
    }

    private func initWallet(currency: CurrencyDef, dispatchGroup: DispatchGroup) {
        dispatchGroup.enter()
        guard let currency = currency as? Raven else { return }
        guard let walletManager = try? WalletManager(currency: currency, dbPath: currency.dbPath) else { return }
        walletManagers[currency.code] = walletManager
        walletManager.initWallet { success in
            guard success else {
                // always keep RVN wallet manager, even if not initialized, since it the primaryWalletManager and needed for onboarding
                if !currency.matches(Currencies.rvn) {
                    walletManager.db?.close()
                    walletManager.db?.delete()
                    self.walletManagers[currency.code] = nil
                }
                dispatchGroup.leave()
                return
            }
            self.exchangeUpdaters[currency.code] = ExchangeUpdater(currency: currency, walletManager: walletManager)
            walletManager.initPeerManager {
                dispatchGroup.leave()
            }
        }
    }

    private func didAttemptInitWallet() {
        DispatchQueue.main.async {
            self.didInitWallet = true
            if !self.hasPerformedWalletDependentInitialization {
                self.didInitWalletManager()
            }
        }
    }

    func launch(application: UIApplication, options: [UIApplicationLaunchOptionsKey: Any]?) {
        self.application = application
        //application.setMinimumBackgroundFetchInterval(UIApplicationBackgroundFetchIntervalMinimum)
        application.setMinimumBackgroundFetchInterval(UIApplicationBackgroundFetchIntervalNever)
        setup()
        handleLaunchOptions(options)
        reachability.didChange = { isReachable in
            if !isReachable {
                self.reachability.didChange = { isReachable in
                    if isReachable {
                        self.retryAfterIsReachable()
                    }
                }
            }
        }
//        updateAssetBundles()
        if !hasPerformedWalletDependentInitialization && didInitWallet {
            didInitWalletManager()
        }
    }

    private func setup() {
        setupDefaults()
        setupAppearance()
        setupRootViewController()
        window.makeKeyAndVisible()
        listenForPushNotificationRequest()
        offMainInitialization()
        
        Store.subscribe(self, name: .reinitWalletManager(nil), callback: {
            guard let trigger = $0 else { return }
            if case .reinitWalletManager(let callback) = trigger {
                if let callback = callback {
                    self.reinitWalletManager(callback: callback)
                }
            }
        })
    }
    
    private func reinitWalletManager(callback: @escaping () -> Void) {
        Store.removeAllSubscriptions()
        Store.perform(action: Reset())
//        UserDefaults.standard.removeObject(forKey: "Bip44")
        self.setup()
        
        DispatchQueue.walletQueue.async {
            self.walletManagers.values.forEach({ $0.resetForWipe() })
            self.walletManagers.removeAll()
            self.initWallet {
                DispatchQueue.main.async {
                    self.didInitWalletManager()
                    callback()
                }
            }
        }
    }

    func willEnterForeground() {
        let walletManager = primaryWalletManager
        guard !walletManager.noWallet else { return }
        if shouldRequireLogin() {
            Store.perform(action: RequireLogin())
        }
        DispatchQueue.walletQueue.async {
            self.walletManagers[UserDefaults.mostRecentSelectedCurrencyCode]?.peerManager?.connect()
        }
        exchangeUpdaters.values.forEach { $0.refresh(completion: {}) }
        feeUpdaters.values.forEach { $0.refresh() }
//        walletManager.apiClient?.kv?.syncAllKeys { print("KV finished syncing. err: \(String(describing: $0))") }
//        walletManager.apiClient?.updateFeatureFlags()
    }

    func retryAfterIsReachable() {
        let walletManager = primaryWalletManager
        guard !walletManager.noWallet else { return }
        DispatchQueue.walletQueue.async {
            self.walletManagers[UserDefaults.mostRecentSelectedCurrencyCode]?.peerManager?.connect()
        }
        exchangeUpdaters.values.forEach { $0.refresh(completion: {}) }
        feeUpdaters.values.forEach { $0.refresh() }
//        walletManager.apiClient?.kv?.syncAllKeys { print("KV finished syncing. err: \(String(describing: $0))") }
//        walletManager.apiClient?.updateFeatureFlags()
    }

    func didEnterBackground() {
        // disconnect synced peer managers
        Store.state.currencies.filter { $0.state.syncState == .success }.forEach { currency in
            DispatchQueue.walletQueue.async {
                self.walletManagers[currency.code]?.peerManager?.disconnect()
            }
        }
        //Save the backgrounding time if the user is logged in
        if !Store.state.isLoginRequired {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: timeSinceLastExitKey)
        }
//        primaryWalletManager.apiClient?.kv?.syncAllKeys { print("KV finished syncing. err: \(String(describing: $0))") }
    }

    func performFetch(_ completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        fetchCompletionHandler = completionHandler
    }

    func open(url: URL) -> Bool {
        if let urlController = urlController {
            return urlController.handleUrl(url)
        } else {
            launchURL = url
            return false
        }
    }

    private func didInitWalletManager() {
        guard let rootViewController = window.rootViewController as? RootNavigationController else { return }
        walletCoordinator = WalletCoordinator(walletManagers: walletManagers)
        Store.perform(action: PinLength.set(primaryWalletManager.pinLength))
        rootViewController.walletManager = primaryWalletManager
        if let homeScreen = rootViewController.viewControllers.first as? HomeScreenViewController {
            homeScreen.primaryWalletManager = primaryWalletManager
        }
        hasPerformedWalletDependentInitialization = true
        modalPresenter = ModalPresenter(walletManagers: walletManagers, window: window, apiClient: noAuthApiClient)
        startFlowController = StartFlowPresenter(walletManager: primaryWalletManager, rootViewController: rootViewController)
        
        walletManagers.forEach { (currencyCode, walletManager) in
            feeUpdaters[currencyCode] = FeeUpdater(walletManager: walletManager)
        }

        defaultsUpdater = UserDefaultsUpdater(walletManager: primaryWalletManager)
        urlController = URLController(walletManager: primaryWalletManager)
        if let url = launchURL {
            _ = urlController?.handleUrl(url)
            launchURL = nil
        }

//        if UIApplication.shared.applicationState != .background {
//            if primaryWalletManager.noWallet {
//                UserDefaults.hasShownWelcome = true
//                addWalletCreationListener()
//                Store.perform(action: ShowStartFlow())
//            } else {
//                DispatchQueue.walletQueue.async {
//                    self.walletManagers[UserDefaults.mostRecentSelectedCurrencyCode]?.peerManager?.connect()
//                }
//                startDataFetchers()
//            }
//
//        //For when watch app launches app in background
        if primaryWalletManager.noWallet {
            addWalletCreationListener()
            Store.perform(action: ShowStartFlow())
        } else {
            DispatchQueue.walletQueue.async {
                self.walletManagers[UserDefaults.mostRecentSelectedCurrencyCode]?.peerManager?.connect()
//                if self.fetchCompletionHandler != nil {
//                    self.performBackgroundFetch()
//                }
            }
            startDataFetchers()
            for (currencyCode, exchangeUpdater) in exchangeUpdaters {
                exchangeUpdater.refresh {
                    if currencyCode == Currencies.rvn.code {
                        self.watchSessionManager.walletManager = self.primaryWalletManager
                        self.watchSessionManager.rate = Currencies.rvn.state.currentRate
                    }
                }
            }
        }
    }

    private func shouldRequireLogin() -> Bool {
        let then = UserDefaults.standard.double(forKey: timeSinceLastExitKey)
        let timeout = UserDefaults.standard.double(forKey: shouldRequireLoginTimeoutKey)
        let now = Date().timeIntervalSince1970
        return now - then > timeout
    }

    private func setupDefaults() {
        if UserDefaults.standard.object(forKey: shouldRequireLoginTimeoutKey) == nil {
            UserDefaults.standard.set(60.0*3.0, forKey: shouldRequireLoginTimeoutKey) //Default 3 min timeout
        }
    }

    private func setupAppearance() {
        UINavigationBar.appearance().titleTextAttributes = [NSAttributedStringKey.font: UIFont.header]
    }

    private func setupRootViewController() {
        let home = HomeScreenViewController(primaryWalletManager: walletManagers[Currencies.rvn.code])
        let nc = RootNavigationController()
        nc.navigationBar.isTranslucent = false
        nc.navigationBar.tintColor = .white
        nc.pushViewController(home, animated: false)
        
        home.didSelectCurrency = { currency in
            guard let walletManager = self.walletManagers[currency.code] else { return }
            let accountViewController = AccountViewController(walletManager: walletManager)
            nc.pushViewController(accountViewController, animated: true)
        }
        
        home.didTapSupport = {
            self.modalPresenter?.presentFaq()
//            Wipping Backup for tests ... I'am Stupid
//            self.modalPresenter?.wipeWallet()
        }
        
        home.didTapSecurity = {
            self.modalPresenter?.presentSecurityCenter()
        }
        
        home.didTapSettings = {
            self.modalPresenter?.presentSettings()
        }
        
        //State restoration
        if let currency = Store.state.currencies.first(where: { $0.code == UserDefaults.selectedCurrencyCode }),
            let walletManager = self.walletManagers[currency.code] {
            let accountViewController = AccountViewController(walletManager: walletManager)
            nc.pushViewController(accountViewController, animated: true)
        }
        
////        Open Ravencoin Account View Controller without having to check UserDefaults
//        let walletManager = self.walletManagers[Currencies.rvn.code]
//        let accountViewController = AccountViewController(walletManager: walletManager!)
//        nc.pushViewController(accountViewController, animated: true)

        // Opens Wipping view controller for only one time in app's life cycle
//        if(!UserDefaults.standard.bool(forKey: "wipe1.0")) {
//            let startWipe = StartOneTimeWipeViewController {
//                guard let walletManager = self.walletManagers[Currencies.rvn.code] else { return }
//                let recover = EnterPhraseViewController(walletManager: walletManager, reason: .validateForOneTimeWipingWallet( {_ in
//                    self.modalPresenter?.wipeWallet()
//                }))
//                nc.pushViewController(recover, animated: true)
//            }
//
//            nc.pushViewController(startWipe, animated: true)
//
//            UserDefaults.standard.set(true, forKey: "wipe1.0")
//            UserDefaults.standard.synchronize()
//
//        }
        
        window.rootViewController = nc
    }

    private func startDataFetchers() {
//        primaryWalletManager.apiClient?.updateFeatureFlags()
//        initKVStoreCoordinator()
        feeUpdaters.values.forEach { $0.refresh() }
        defaultsUpdater?.refresh()
        primaryWalletManager.apiClient?.events?.up()
        exchangeUpdaters.forEach { (code, updater) in
            updater.refresh(completion: {
                if code == Currencies.rvn.code {
                    self.watchSessionManager.rate = Currencies.rvn.state.currentRate
                }
            })
        }
    }

    /// Handles new wallet creation or recovery
    private func addWalletCreationListener() {
        Store.subscribe(self, name: .didCreateOrRecoverWallet, callback: { _ in
            DispatchQueue.walletQueue.async {
                
                self.initWallet(completion: self.didInitWalletManager)
            }
        })
    }
    
//    private func updateAssetBundles() {
//        DispatchQueue.global(qos: .utility).async { [weak self] in
//            guard let myself = self else { return }
//            myself.noAuthApiClient.updateBundles { errors in
//                for (n, e) in errors {
//                    print("Bundle \(n) ran update. err: \(String(describing: e))")
//                }
//                DispatchQueue.main.async {
//                    let _ = myself.modalPresenter?.supportCenter // Initialize support center
//                }
//            }
//        }
//    }

//    private func initKVStoreCoordinator() {
////        guard let kvStore = primaryWalletManager.apiClient?.kv else { return }
//        guard kvStoreCoordinator == nil else { return }
//        kvStore.syncAllKeys { [weak self] error in
//            print("KV finished syncing. err: \(String(describing: error))")
//            self?.walletManagers[Currencies.rvn.code]?.kvStore = kvStore
//            self?.kvStoreCoordinator = KVStoreCoordinator(kvStore: kvStore)
//            self?.kvStoreCoordinator?.retreiveStoredWalletInfo()
//            self?.kvStoreCoordinator?.listenForWalletChanges()
//        }
//    }

    private func offMainInitialization() {
        DispatchQueue.global(qos: .background).async {
            let _ = Rate.symbolMap //Initialize currency symbol map
        }
    }

    private func handleLaunchOptions(_ options: [UIApplicationLaunchOptionsKey: Any]?) {
        if let url = options?[.url] as? URL {
            do {
                let file = try Data(contentsOf: url)
                if file.count > 0 {
                    Store.trigger(name: .openFile(file))
                }
            } catch let error {
                print("Could not open file at: \(url), error: \(error)")
            }
        }
    }

    func performBackgroundFetch() {
//        saveEvent("appController.performBackgroundFetch")
//        let group = DispatchGroup()
//        if let peerManager = walletManager?.peerManager, peerManager.syncProgress(fromStartHeight: peerManager.lastBlockHeight) < 1.0 {
//            group.enter()
//            store.lazySubscribe(self, selector: { $0.walletState.syncState != $1.walletState.syncState }, callback: { state in
//                if self.fetchCompletionHandler != nil {
//                    if state.walletState.syncState == .success {
//                        DispatchQueue.walletQueue.async {
//                            peerManager.disconnect()
//                            group.leave()
//                        }
//                    }
//                }
//            })
//        }
//
//        group.enter()
//        Async.parallel(callbacks: [
//            { self.exchangeUpdater?.refresh(completion: $0) },
//            { self.feeUpdater?.refresh(completion: $0) },
//            { self.walletManager?.apiClient?.events?.sync(completion: $0) },
//            { self.walletManager?.apiClient?.updateFeatureFlags(); $0() }
//            ], completion: {
//                group.leave()
//        })
//
//        DispatchQueue.global(qos: .utility).async {
//            if group.wait(timeout: .now() + 25.0) == .timedOut {
//                self.saveEvent("appController.backgroundFetchFailed")
//                self.fetchCompletionHandler?(.failed)
//            } else {
//                self.saveEvent("appController.backgroundFetchNewData")
//                self.fetchCompletionHandler?(.newData)
//            }
//            self.fetchCompletionHandler = nil
//        }
    }

    func willResignActive() {
        guard !Store.state.isPushNotificationsEnabled else { return }
        guard let pushToken = UserDefaults.pushToken else { return }
        primaryWalletManager.apiClient?.deletePushNotificationToken(pushToken)
    }
}

//MARK: - Push notifications
extension ApplicationController {
    func listenForPushNotificationRequest() {
        Store.subscribe(self, name: .registerForPushNotificationToken, callback: { _ in
            let settings = UIUserNotificationSettings(types: [.badge, .sound, .alert], categories: nil)
            self.application?.registerUserNotificationSettings(settings)
        })
    }

    func application(_ application: UIApplication, didRegister notificationSettings: UIUserNotificationSettings) {
        if !notificationSettings.types.isEmpty {
            application.registerForRemoteNotifications()
        }
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
//        guard let apiClient = walletManager?.apiClient else { return }
//        guard UserDefaults.pushToken != deviceToken else { return }
//        UserDefaults.pushToken = deviceToken
//        apiClient.savePushNotificationToken(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("didFailToRegisterForRemoteNotification: \(error)")
    }
}
