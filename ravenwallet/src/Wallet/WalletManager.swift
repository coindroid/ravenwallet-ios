//
//  WalletManager.swift
//  ravenwallet
//
//  Created by Aaron Voisine on 10/13/16.
//  Copyright (c) 2018 Ravenwallet Team
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.

import Foundation
import UIKit
import SystemConfiguration
import Core
import AVFoundation

extension NSNotification.Name {
    public static let WalletDidWipe = NSNotification.Name("WalletDidWipe")
}

// A WalletManger instance manages a single wallet, and that wallet's individual connection to the Ravencoin network.
// After instantiating a WalletManager object, call myWalletManager.peerManager.connect() to begin syncing.

class WalletManager {
    let currency: CurrencyDef
    var masterPubKey = BRMasterPubKey()
    var earliestKeyTime: TimeInterval = 0
    var db: CoreDatabase?
    var wallet: BRWallet?
    private let progressUpdateInterval: TimeInterval = 0.5
    private let updateDebounceInterval: TimeInterval = 0.4
    private var progressTimer: Timer?
    
    // Last block height allows us to display the progress from where the sync stopped
    // during the previous app life cycle to the last block in the chain. e.g., if the previous
    // sync successfully sync'd up to block 100,000 and the current sync is at block 200,000 out of
    // 300,000 total blocks the percent will show 50% (half way between 100,000 and 300,000).
    //
    // 'lastBlockHeight' is updated in syncStopped() if there is no error.
    var lastBlockHeight: UInt32 {
        set { UserDefaults.setLastSyncedBlockHeight(height: newValue, for: currency)}
        get {return UserDefaults.lastSyncedBlockHeight(for: currency)}
    }
    
    private var retryTimer: RetryTimer?
    private var updateTimer: Timer?
    
    func initWallet(callback: @escaping (Bool) -> Void) {
        db?.loadTransactions { txns in
            guard self.masterPubKey != BRMasterPubKey() else {
                #if !Debug
                self.db?.delete()
                #endif
                return callback(false)
            }
            self.wallet = BRWallet(transactions: txns, masterPubKey: self.masterPubKey, listener: self)
            if let wallet = self.wallet {
                Store.perform(action: WalletChange(self.currency).setBalance(wallet.balance))
                Store.perform(action: WalletChange(self.currency).set(self.currency.state.mutate(receiveAddress: wallet.receiveAddress)))
            }
            callback(self.wallet != nil)
        }
    }
    
    func initWallet(transactions: [BRTxRef]) {
        guard self.masterPubKey != BRMasterPubKey() else {
            #if !Debug
            self.db?.delete()
            #endif
            return
        }
        self.wallet = BRWallet(transactions: transactions, masterPubKey: self.masterPubKey, listener: self)
        if let wallet = self.wallet {
            Store.perform(action: WalletChange(self.currency).setBalance(wallet.balance))
            Store.perform(action: WalletChange(self.currency).set(self.currency.state.mutate(receiveAddress: wallet.receiveAddress)))
        }
    }
    
    func initPeerManager(blocks: [BRBlockRef?]) {
        guard let wallet = self.wallet else { return }
        self.peerManager = BRPeerManager(currency: currency, wallet: wallet, earliestKeyTime: earliestKeyTime,
                                         blocks: blocks, peers: [], listener: self)
    }
    
    func initPeerManager(callback: @escaping () -> Void) {
        db?.loadBlocks { [unowned self] blocks in
            self.db?.loadPeers { peers in
                guard let wallet = self.wallet else { return }
                self.peerManager = BRPeerManager(currency: self.currency, wallet: wallet, earliestKeyTime: self.earliestKeyTime,
                                                 blocks: blocks, peers: peers, listener: self)
                callback()
            }
        }
    }
    
    var apiClient: BRAPIClient? {
        guard self.masterPubKey != BRMasterPubKey() else { return nil }
        return lazyAPIClient
    }
    
    var peerManager: BRPeerManager?
    
    private lazy var lazyAPIClient: BRAPIClient? = {
        guard let wallet = self.wallet else { return nil }
        return BRAPIClient(authenticator: self)
    }()
    
    var wordList: [NSString]? {
        guard let path = Bundle.main.path(forResource: "BIP39Words", ofType: "plist") else { return nil }
        return NSArray(contentsOfFile: path) as? [NSString]
    }
    
    lazy var allWordsLists: [[NSString]] = {
        var array: [[NSString]] = []
        Bundle.main.localizations.forEach { lang in
            if let path = Bundle.main.path(forResource: "BIP39Words", ofType: "plist", inDirectory: nil, forLocalization: lang) {
                if let words = NSArray(contentsOfFile: path) as? [NSString] {
                    array.append(words)
                }
            }
        }
        return array
    }()
    
    lazy var allWords: Set<String> = {
        var set: Set<String> = Set()
        Bundle.main.localizations.forEach { lang in
            if let path = Bundle.main.path(forResource: "BIP39Words", ofType: "plist", inDirectory: nil, forLocalization: lang) {
                if let words = NSArray(contentsOfFile: path) as? [NSString] {
                    set.formUnion(words.map { $0 as String })
                }
            }
        }
        return set
    }()
    
    var rawWordList: [UnsafePointer<CChar>?]? {
        guard let wordList = wordList, wordList.count == 2048 else { return nil }
        return wordList.map({ $0.utf8String })
    }
    
    init(currency: CurrencyDef, masterPubKey: BRMasterPubKey, earliestKeyTime: TimeInterval, dbPath: String? = nil) throws {
        self.currency = currency
        self.masterPubKey = masterPubKey
        self.earliestKeyTime = earliestKeyTime
        if let path = dbPath {
            self.db = CoreDatabase(dbPath: path)
        } else {
            self.db = CoreDatabase()
        }
    }
    
    func isPhraseValid(_ phrase: String) -> Bool {
        for wordList in allWordsLists {
            var words = wordList.map({ $0.utf8String })
            guard let nfkdPhrase = CFStringCreateMutableCopy(secureAllocator, 0, phrase as CFString) else { return false }
            CFStringNormalize(nfkdPhrase, .KD)
            if BRBIP39PhraseIsValid(&words, nfkdPhrase as String) != 0 {
                return true
            }
        }
        return false
    }
    
    func isWordValid(_ word: String) -> Bool {
        return allWords.contains(word)
    }
    
    var isWatchOnly: Bool {
        let mpkData = Data(masterPubKey: masterPubKey)
        return mpkData.count == 0
    }
    
    func isSyncing() -> Bool {
        if (self.peerManager == nil) {
            return false
        }
        let diffBlocks = Int(self.lastBlockHeight) - Int((self.peerManager?.lastBlockHeight)!)
        if abs(diffBlocks) > C.diffBlocks {
            return true
        }
        return false
    }
}

extension WalletManager : BRPeerManagerListener {
    
    func syncStarted() {
        DispatchQueue.main.async() {
            self.db?.setDBFileAttributes()
            self.progressTimer = Timer.scheduledTimer(timeInterval: self.progressUpdateInterval, target: self, selector: #selector(self.updateProgress), userInfo: nil, repeats: true)
            Store.perform(action: WalletChange(self.currency).setSyncingState(.syncing))
        }
    }
    
    func syncStopped(_ error: BRPeerManagerError?) {
        DispatchQueue.main.async() {
            if UIApplication.shared.applicationState != .active {
                DispatchQueue.walletQueue.async {
                    self.peerManager?.disconnect()
                }
                return
            }
            
            switch error {
            case .some(let .posixError(errorCode, description)):
                
                Store.perform(action: WalletChange(self.currency).setSyncingState(.connecting))
                if self.retryTimer == nil && self.networkIsReachable() {
                    self.retryTimer = RetryTimer()
                    self.retryTimer?.callback = strongify(self) { myself in
                        Store.trigger(name: .retrySync(self.currency))
                    }
                    self.retryTimer?.start()
                }
            case .none:
                self.retryTimer?.stop()
                self.retryTimer = nil
                if let height = self.peerManager?.lastBlockHeight {
                    self.lastBlockHeight = height
                }
                self.progressTimer?.invalidate()
                self.progressTimer = nil
                Store.perform(action: WalletChange(self.currency).setIsRescanning(false))
                Store.perform(action: WalletChange(self.currency).setSyncingState(.success))
            }
        }
    }
    
    func txStatusUpdate() {
        DispatchQueue.main.async { [weak self] in
            self?.requestTxUpdate()
        }
    }
    
    func saveBlocks(_ replace: Bool, _ blocks: [BRBlockRef?]) {
        db?.saveBlocks(replace, blocks)
    }
    
    func savePeers(_ replace: Bool, _ peers: [BRPeer]) {
        db?.savePeers(replace, peers)
    }
    
    func networkIsReachable() -> Bool {
        var flags: SCNetworkReachabilityFlags = []
        var zeroAddress = sockaddr()
        zeroAddress.sa_len = UInt8(MemoryLayout<sockaddr>.size)
        zeroAddress.sa_family = sa_family_t(AF_INET)
        guard let reachability = SCNetworkReachabilityCreateWithAddress(nil, &zeroAddress) else { return false }
        if !SCNetworkReachabilityGetFlags(reachability, &flags) { return false }
        return flags.contains(.reachable) && !flags.contains(.connectionRequired)
    }
    
    @objc private func updateProgress() {
        DispatchQueue.walletQueue.async {
            guard let progress = self.peerManager?.syncProgress(fromStartHeight: self.lastBlockHeight), let timestamp = self.peerManager?.lastBlockTimestamp else { return }
            DispatchQueue.main.async {
                Store.perform(action: WalletChange(self.currency).setProgress(progress: progress, timestamp: timestamp))
                if let wallet = self.wallet {
                    Store.perform(action: WalletChange(self.currency).setBalance(wallet.balance))
                }
            }
        }
    }
}

extension WalletManager : BRWalletListener {
    func balanceChanged(_ balance: UInt64) {
        DispatchQueue.main.async { [weak self] in
            guard let myself = self else { return }
            myself.checkForReceived(newBalance: balance)
            Store.perform(action: WalletChange(myself.currency).setBalance(balance))
            myself.requestTxUpdate()
        }
    }
    
    func txAdded(_ tx: BRTxRef) {
        db?.txAdded(tx)
        //add asset if not null
        if AssetValidator.shared.checkInvalidAsset(asset: tx.pointee.asset) {
            if(tx.pointee.asset!.pointee.type != NEW_ASSET && tx.pointee.asset!.pointee.type != REISSUE){
                DispatchQueue.main.async {
                    self.assetAdded(tx)
                }
            }
        }
    }
    
    func assetAdded(_ tx: BRTxRef) {
        let rvnTx = RvnTransaction(tx, walletManager: self, rate: self.currency.state.currentRate)
        if(tx.pointee.asset!.pointee.type == NEW_ASSET || tx.pointee.asset!.pointee.type == REISSUE){
            //BMEX should dont write asset if not confirmed
            if(rvnTx?.status == .pending || rvnTx?.status == .invalid){
                return
            }
        }
        for brTx in decomposeTransaction(brTxRef: tx) {
            if AssetValidator.shared.checkInvalidAsset(asset: brTx!.pointee.asset) {
                db?.assetAdded(brTx!, walletManager: self)
            }
        }
        //send get asset data for each asset
        if(tx.pointee.asset!.pointee.type == TRANSFER || tx.pointee.asset!.pointee.type == REISSUE){
            getAssetData(tx)
        }
    }
    
    func getAssetData(_ tx: BRTxRef) {
        if AssetValidator.shared.checkNullAsset(asset: tx.pointee.asset) {
            PeerManagerGetAssetData(self.peerManager!.cPtr, Unmanaged.passUnretained(self).toOpaque(), tx.pointee.asset.pointee.name, tx.pointee.asset.pointee.nameLen, {(info, asset) in
                guard let info = info, let asset = asset else { return }
                Unmanaged<WalletManager>.fromOpaque(info).takeUnretainedValue().db?.updateAssetData(asset)
            })
        }
    }
    
    func txUpdated(_ txHashes: [UInt256], blockHeight: UInt32, timestamp: UInt32) {
        db?.txUpdated(txHashes, blockHeight: blockHeight, timestamp: timestamp)
        let transactions = self.wallet?.transactions
        for tx in transactions! {
            if(txHashes.contains((tx?.pointee.txHash)!)){
                if AssetValidator.shared.checkInvalidAsset(asset: tx!.pointee.asset) {
                    if(tx!.pointee.asset!.pointee.type == NEW_ASSET || tx!.pointee.asset!.pointee.type == REISSUE){
                        DispatchQueue.main.async {
                            self.assetAdded(tx!)
                        }
                    }
                }
            }
        }
    }
    
    func txDeleted(_ txHash: UInt256, notifyUser: Bool, recommendRescan: Bool) {
        //verify asset
        db?.loadTransactions(callback: { transactions in
            for tx in transactions {
                if(txHash == tx?.pointee.txHash){
                    if AssetValidator.shared.checkInvalidAsset(asset: tx!.pointee.asset) {
                        if(tx!.pointee.asset!.pointee.type == TRANSFER){
                            self.db?.rejectAssetTx(tx!.pointee.asset)
                        }
                    }
                }
            }
        })
        // notify User to recommendScan
        if notifyUser {
            if recommendRescan {
                DispatchQueue.main.async { [weak self] in
                    guard let myself = self else { return }
                    Store.perform(action: WalletChange(myself.currency).setRecommendScan(recommendRescan)) }
            }
        }
        DispatchQueue.main.async { [weak self] in
            self?.requestTxUpdate()
        }
        //remove tx
        db?.txDeleted(txHash, notifyUser: notifyUser, recommendRescan: true)
    }
    
    private func checkForReceived(newBalance: UInt64) {
        if let oldBalance = currency.state.balance {
            if newBalance > oldBalance {
                let walletState = currency.state
                Store.perform(action: WalletChange(currency).set(walletState.mutate(receiveAddress: wallet?.receiveAddress)))
                if currency.state.syncState == .success {
                    showReceived(amount: newBalance - oldBalance)
                }
            }
        }
    }
    
    private func showReceived(amount: UInt64) {
        if let rate = currency.state.currentRate {
            let maxDigits = currency.state.maxDigits
            let amount = Amount(amount: amount, rate: rate, maxDigits: maxDigits, currency: currency)
            let primary = Store.state.isSwapped ? amount.localCurrency : amount.bits
            let secondary = Store.state.isSwapped ? amount.bits : amount.localCurrency
            let message = String(format: S.TransactionDetails.received, "\(primary) (\(secondary))")
            Store.trigger(name: .lightWeightAlert(message))
            showLocalNotification(message: message)
            ping()
        }
    }
    
    func requestTxUpdate() {
        if updateTimer == nil {
            updateTimer = Timer.scheduledTimer(timeInterval: updateDebounceInterval, target: self, selector: #selector(updateTransactions), userInfo: nil, repeats: false)
        }
    }
    
    @objc private func updateTransactions() {
        updateTimer?.invalidate()
        updateTimer = nil
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let myself = self else { return }
            guard let txRefs = myself.wallet?.transactions else { return }
            let transactions = myself.makeTransactionViewModels(transactions: txRefs,
                                                                rate: myself.currency.state.currentRate)
            if transactions.count > 0 {
                DispatchQueue.main.async {
                    Store.perform(action: WalletChange(myself.currency).setTransactions(transactions))
                }
            }
        }
    }
    
    func makeTransactionViewModels(transactions: [BRTxRef?], rate: Rate?) -> [Transaction] {
        let decomposedList = decomposeTransactionsList(transactions: transactions)
        return decomposedList.compactMap{ $0 }.sorted {
            if $0.pointee.timestamp == 0 {
                return true
            } else if $1.pointee.timestamp == 0 {
                return false
            } else {
                return $0.pointee.timestamp > $1.pointee.timestamp
            }
            }.compactMap {
                return RvnTransaction($0, walletManager: self, rate: rate)
        }
    }
    
    //    var outputs: [BRTxOutput] {
    //        return [BRTxOutput](UnsafeBufferPointer(start: self.pointee.outputs, count: self.pointee.outCount))
    //    }
    
    func decomposeTransaction(brTxRef:BRTxRef?) -> [BRTxRef?] {
        var decomposedTransactions: [BRTxRef?] = [BRTxRef?]()
        if(brTxRef?.pointee.asset != nil){
            var txsCount = 0
            var txListPointer:UnsafeMutablePointer<BRTransaction>!
            if brTxRef?.pointee.asset.pointee.type == NEW_ASSET ||  brTxRef?.pointee.asset.pointee.type == REISSUE {
                txsCount = BRTransactionDecompose(wallet?.cPtr, brTxRef, nil, 0);
                txListPointer = BRTransactionNew(txsCount)
                BRTransactionDecompose(wallet?.cPtr, brTxRef, txListPointer, txsCount);
            }
            else{
                decomposedTransactions.append(brTxRef)
                return decomposedTransactions
            }
            let txList = [BRTransaction](UnsafeBufferPointer<BRTransaction>(start: txListPointer, count: txsCount))
            for tx in txList {
                let txPointer = UnsafeMutablePointer<BRTransaction>.allocate(capacity: 1)
                txPointer.initialize(to: tx)
                if(txPointer.pointee.asset != nil){
                    if(txPointer.pointee.asset.pointee.name == nil){
                        continue
                    }
                }
                decomposedTransactions.append(txPointer)
            }
            return decomposedTransactions
        }
        else{
            decomposedTransactions.append(brTxRef)
            return decomposedTransactions
        }
    }
    
    func decomposeTransactionsList(transactions:[BRTxRef?]) -> [BRTxRef?] {
        var decomposedTransactionsList: [BRTxRef?] = [BRTxRef?]()
        for brTxRef in transactions {
            decomposedTransactionsList.append(contentsOf:decomposeTransaction(brTxRef: brTxRef))
        }
        return decomposedTransactionsList
    }
    
    private func ping() {
        guard let url = Bundle.main.url(forResource: "coinflip", withExtension: "aiff") else { return }
        var id: SystemSoundID = 0
        AudioServicesCreateSystemSoundID(url as CFURL , &id)
        AudioServicesAddSystemSoundCompletion(id, nil, nil, { soundId, _ in
            AudioServicesDisposeSystemSoundID(soundId)
        }, nil)
        AudioServicesPlaySystemSound(id)
    }
    
    private func showLocalNotification(message: String) {
        guard UIApplication.shared.applicationState == .background || UIApplication.shared.applicationState == .inactive else { return }
        guard Store.state.isPushNotificationsEnabled else { return }
        UIApplication.shared.applicationIconBadgeNumber = UIApplication.shared.applicationIconBadgeNumber + 1
        let notification = UILocalNotification()
        notification.alertBody = message
        notification.soundName = "coinflip.aiff"
        UIApplication.shared.presentLocalNotificationNow(notification)
    }
}
