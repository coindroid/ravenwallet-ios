//
//  TxListCell.swift
//  ravenwallet
//
//  Created by Ehsan Rezaie on 2018-02-19.
//  Copyright © 2018 breadwallet LLC. All rights reserved.
//

import UIKit

class TxListCell: UITableViewCell {

    // MARK: - Views
    
    private let timestamp = UILabel(font: .customBody(size: 16.0), color: .darkGray)
    private let descriptionLabel = UILabel(font: .customBody(size: 14.0), color: .lightGray)
    private let amount = UILabel(font: .customBold(size: 18.0))
    private let separator = UIView(color: .separatorGray)
    private let statusIndicator = TxStatusIndicator(width: 44.0)
    private var pendingConstraints = [NSLayoutConstraint]()
    private var completeConstraints = [NSLayoutConstraint]()
    private let failedIndicator = UIButton(type: .system)

    // MARK: Vars
    
    private var viewModel: TxListViewModel!
    
    // MARK: - Init
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupViews()
    }
    
    func setTransaction(_ viewModel: TxListViewModel, isBtcSwapped: Bool, rate: Rate, maxDigits: Int, isSyncing: Bool) {
        self.viewModel = viewModel
        
        timestamp.text = viewModel.shortTimestamp
        descriptionLabel.attributedText = viewModel.shortAttributeDescription
        amount.attributedText = viewModel.amount(rate: rate, isBtcSwapped: isBtcSwapped)
        
        statusIndicator.status = viewModel.status
        if viewModel.status == .complete {
            failedIndicator.isHidden = true
            statusIndicator.isHidden = true
            timestamp.isHidden = false
            NSLayoutConstraint.deactivate(pendingConstraints)
            NSLayoutConstraint.activate(completeConstraints)
        }
        else if viewModel.status == .invalid {
            failedIndicator.isHidden = false
            statusIndicator.isHidden = true
            timestamp.isHidden = true
            NSLayoutConstraint.deactivate(completeConstraints)
            NSLayoutConstraint.activate(pendingConstraints)
        }
        else {
            failedIndicator.isHidden = true
            statusIndicator.isHidden = false
            timestamp.isHidden = true
            NSLayoutConstraint.deactivate(completeConstraints)
            NSLayoutConstraint.activate(pendingConstraints)
        }
    }
    
    // MARK: - Private
    
    private func setupViews() {
        addSubviews()
        addConstraints()
        setupStyle()
    }
    
    private func addSubviews() {
        contentView.addSubview(timestamp)
        contentView.addSubview(descriptionLabel)
        contentView.addSubview(statusIndicator)
        contentView.addSubview(failedIndicator)
        contentView.addSubview(amount)
        contentView.addSubview(separator)
    }
    
    private func addConstraints() {
        timestamp.constrain([
            timestamp.topAnchor.constraint(equalTo: contentView.topAnchor, constant: C.padding[2]),
            timestamp.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: C.padding[2])
            ])
        
        descriptionLabel.constrain([
            descriptionLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -C.padding[2]),
            descriptionLabel.trailingAnchor.constraint(equalTo: timestamp.trailingAnchor)
            ])
        
        pendingConstraints = [
            descriptionLabel.centerYAnchor.constraint(equalTo: statusIndicator.centerYAnchor),
            descriptionLabel.leadingAnchor.constraint(equalTo: statusIndicator.trailingAnchor, constant: C.padding[1]),
            descriptionLabel.heightAnchor.constraint(equalToConstant: 48.0)
        ]
        
        completeConstraints = [
            descriptionLabel.topAnchor.constraint(equalTo: timestamp.bottomAnchor),
            descriptionLabel.leadingAnchor.constraint(equalTo: timestamp.leadingAnchor),
        ]
        
        statusIndicator.constrain([
            statusIndicator.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            statusIndicator.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: C.padding[2]),
            statusIndicator.widthAnchor.constraint(equalToConstant: statusIndicator.width),
            statusIndicator.heightAnchor.constraint(equalToConstant: statusIndicator.height)
            ])
        
        failedIndicator.constrain([
            failedIndicator.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            failedIndicator.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: C.padding[2]),
            failedIndicator.widthAnchor.constraint(equalToConstant: statusIndicator.width),
            failedIndicator.heightAnchor.constraint(equalToConstant: 20.0)])
        
        amount.constrain([
            amount.topAnchor.constraint(equalTo: contentView.topAnchor),
            amount.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            amount.leadingAnchor.constraint(equalTo: descriptionLabel.trailingAnchor, constant: C.padding[6]),
            amount.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -C.padding[2]),
            ])
        
        separator.constrainBottomCorners(height: 0.5)
    }
    
    private func setupStyle() {
        selectionStyle = .none
        amount.textAlignment = .right
        amount.setContentHuggingPriority(.required, for: .horizontal)
        timestamp.setContentHuggingPriority(.required, for: .vertical)
        descriptionLabel.lineBreakMode = .byTruncatingTail
        
        failedIndicator.setTitle(S.Transaction.failed, for: .normal)
        failedIndicator.titleLabel?.font = .customBold(size: 12.0)
        failedIndicator.setTitleColor(.white, for: .normal)
        failedIndicator.backgroundColor = .sentRed
        failedIndicator.layer.cornerRadius = 3
        failedIndicator.isHidden = true
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
