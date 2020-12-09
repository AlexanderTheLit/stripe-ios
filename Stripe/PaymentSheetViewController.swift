//
//  PaymentSheetViewController.swift
//  Stripe
//
//  Created by Yuki Tokuhiro on 9/12/20.
//  Copyright © 2020 Stripe, Inc. All rights reserved.
//

import Foundation
import UIKit
import PassKit

protocol PaymentSheetViewControllerDelegate: AnyObject {
    func paymentSheetViewControllerShouldConfirm(_ paymentSheetViewController: PaymentSheetViewController, with paymentOption: PaymentOption, completion: @escaping (PaymentResult) -> ())
    func paymentSheetViewControllerDidFinish(_ paymentSheetViewController: PaymentSheetViewController, result: PaymentResult)
    func paymentSheetViewControllerDidCancel(_ paymentSheetViewController: PaymentSheetViewController)
}

class PaymentSheetViewController: UIViewController {
    // MARK: - Read-only Properties
    let savedPaymentMethods: [STPPaymentMethod]
    let isApplePayEnabled: Bool
    let configuration: PaymentSheet.Configuration

    // MARK: - Writable Properties
    weak var delegate: PaymentSheetViewControllerDelegate?
    private(set) var paymentIntent: STPPaymentIntent
    private enum Mode {
        case selectingSaved
        case addingNew
    }
    private var mode: Mode
    private(set) var error: Error?
    private var isPaymentInFlight: Bool = false
    private(set) var isDismissable: Bool = true

    // MARK: - Views

    private lazy var addPaymentMethodViewController: AddPaymentMethodViewController = {
        return AddPaymentMethodViewController(paymentMethodTypes: paymentIntent.paymentMethodTypesSet,
                                              isGuestMode: configuration.customer == nil,
                                              billingAddressCollection: configuration.billingAddressCollectionLevel,
                                              merchantDisplayName: configuration.merchantDisplayName,
                                              delegate: self)
    }()
    private lazy var savedPaymentOptionsViewController: SavedPaymentOptionsViewController = {
        return SavedPaymentOptionsViewController(savedPaymentMethods: savedPaymentMethods,
                                                 customerID: configuration.customer?.id,
                                                 isApplePayEnabled: isApplePayEnabled,
                                                 delegate: self)

    }()
    internal lazy var navigationBar: SheetNavigationBar = {
        let navBar = SheetNavigationBar()
        navBar.delegate = self
        return navBar
    }()
    private lazy var applePayHeader: UIView = {
        return ApplePayHeaderView(didTap: didTapApplePayButton)
    }()
    private lazy var headerLabel: UILabel = {
        return PaymentSheetUI.makeHeaderLabel()
    }()
    private lazy var paymentContainerView: UIView = {
        return UIView()
    }()
    private lazy var errorLabel: UILabel = {
        return PaymentSheetUI.makeErrorLabel()
    }()
    private lazy var buyButton: ConfirmButton = {
        let button = ConfirmButton(
            style: .stripe,
            callToAction: .pay(amount: paymentIntent.amount, currency: paymentIntent.currency),
            didTap: didTapBuyButton)
        return button
    }()

    // MARK: - Init

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    required init(paymentIntent: STPPaymentIntent,
                  savedPaymentMethods: [STPPaymentMethod],
                  configuration: PaymentSheet.Configuration,
                  isApplePayEnabled: Bool,
                  delegate: PaymentSheetViewControllerDelegate) {
        self.paymentIntent = paymentIntent
        self.savedPaymentMethods = savedPaymentMethods
        self.configuration = configuration
        self.isApplePayEnabled = isApplePayEnabled
        self.delegate = delegate

        if savedPaymentMethods.isEmpty {
            self.mode = .addingNew
        } else {
            self.mode = .selectingSaved
        }

        super.init(nibName: nil, bundle: nil)
    }

    // MARK: UIViewController Methods

    override func viewDidLoad() {
        super.viewDidLoad()

        // One stack view contains all our subviews
        let stackView = UIStackView(arrangedSubviews: [headerLabel, applePayHeader, paymentContainerView, errorLabel])
        stackView.spacing = PaymentSheetUI.defaultPadding
        stackView.axis = .vertical

        // Except the buy button, which is pinned to the bottom
        [stackView, buyButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }

        // Get our margins in order
        view.preservesSuperviewLayoutMargins = true
        // Hack: Payment container needs to extend to the edges, so we'll 'cancel out' the layout margins with negative padding
        paymentContainerView.layoutMargins = UIEdgeInsets(top: 0, left: -PaymentSheetUI.defaultSheetMargins.leading, bottom: 0, right: -PaymentSheetUI.defaultSheetMargins.trailing)

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: view.layoutMarginsGuide.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: buyButton.topAnchor, constant: -PaymentSheetUI.defaultPadding),

            buyButton.bottomAnchor.constraint(equalTo: view.layoutMarginsGuide.bottomAnchor),
            buyButton.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            buyButton.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
        ])

        updateUI()
    }

    // MARK: Private Methods

    // state -> view
    private func updateUI() {
        // Disable interaction if necessary
        if isPaymentInFlight {
            sendEventToSubviews(.shouldDisableUserInteraction, from: view)
            view.isUserInteractionEnabled = false
            isDismissable = false
        } else {
            sendEventToSubviews(.shouldEnableUserInteraction, from: view)
            view.isUserInteractionEnabled = true
            isDismissable = true
        }

        // Update our views (starting from the top of the screen):
        navigationBar.setStyle({
            switch mode {
            case .selectingSaved:
                return .close
            case .addingNew:
                return savedPaymentMethods.isEmpty ? .close : .back
            }
        }())

        // Content header
        applePayHeader.isHidden = {
            switch mode {
            case .selectingSaved:
                return true
            case .addingNew:
                // We already showed Apple Pay in the saved payment methods carousel, so don't show it here
                return !(isApplePayEnabled && savedPaymentMethods.isEmpty)
            }
        }()
        headerLabel.isHidden = !applePayHeader.isHidden
        let localizedAmount = String.localizedAmountDisplayString(for: paymentIntent.amount, currency: paymentIntent.currency)
        headerLabel.text = STPLocalizedString("Pay \(localizedAmount) using", "")

        // Content
        switchContentIfNecessary(
            to: mode == .selectingSaved ? savedPaymentOptionsViewController : addPaymentMethodViewController,
            containerView: paymentContainerView
        )

        // Error
        self.errorLabel.text = self.error?.localizedDescription
        UIView.animate(withDuration: PaymentSheetUI.defaultAnimationDuration) {
            self.errorLabel.setHiddenIfNecessary(self.error == nil)
        }

        // Buy button
        let buyButtonStyle: ConfirmButton.Style
        var buyButtonStatus: ConfirmButton.Status
        switch mode {
        case .selectingSaved:
            if case .applePay = savedPaymentOptionsViewController.selectedPaymentOption {
                buyButtonStyle = .applePay
            } else {
                buyButtonStyle = .stripe
            }
            buyButtonStatus = .enabled
        case .addingNew:
            buyButtonStyle = .stripe
            buyButtonStatus = addPaymentMethodViewController.paymentOption == nil ? .disabled : .enabled
        }
        if isPaymentInFlight {
            buyButtonStatus = .processing
        }
        self.buyButton.update(state: buyButtonStatus,
                              style: buyButtonStyle,
                              animated: true,
                              completion: nil)
    }

    @objc
    private func didTapApplePayButton() {
        pay(with: .applePay)
    }

    @objc
    private func didTapBuyButton() {
        switch mode {
        case .addingNew:
            guard let newPaymentOption = addPaymentMethodViewController.paymentOption else {
                assertionFailure()
                return
            }
            pay(with: newPaymentOption)
        case .selectingSaved:
            guard let selectedPaymentOption = savedPaymentOptionsViewController.selectedPaymentOption else {
                assertionFailure()
                return
            }
            pay(with: selectedPaymentOption)
        }
    }

    private func pay(with paymentOption: PaymentOption) {
        view.endEditing(true)
        isPaymentInFlight = true
        // Clear any errors
        error = nil
        updateUI()

        // Confirm the payment with the payment option
        let startTime = NSDate.timeIntervalSinceReferenceDate
        self.delegate?.paymentSheetViewControllerShouldConfirm(self, with: paymentOption) {
            result in
            let elapsedTime = NSDate.timeIntervalSinceReferenceDate - startTime
            DispatchQueue.main.asyncAfter(deadline: .now() + max(PaymentSheetUI.minimumFlightTime - elapsedTime, 0)) {
                self.isPaymentInFlight = false
                switch result {
                case .canceled(let paymentIntent):
                    // Update state
                    self.paymentIntent = paymentIntent ?? self.paymentIntent
                    // Do nothing, keep customer on payment sheet
                    self.updateUI()
                case .failed(let error, let paymentIntent):
                    // Update state
                    self.paymentIntent = paymentIntent ?? self.paymentIntent
                    self.error = error
                    // Handle error
                    if PaymentSheetError.isUnrecoverable(error: error) {
                        self.delegate?.paymentSheetViewControllerDidFinish(self, result: result)
                    } else {
                        sendEventToSubviews(.shouldDisplayError(error), from: self.view)
                    }
                    self.updateUI()
                    UIAccessibility.post(notification: .layoutChanged, argument: self.errorLabel)
                case .completed:
                    // We're done!
                    let delay: TimeInterval = self.presentedViewController?.isBeingDismissed == true ? 1 : 0
                    // Hack: PaymentHandler calls the completion block while SafariVC is still being dismissed - "wait" until it's finished before updating UI
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        self.buyButton.update(state: .succeeded, animated: true)
                        DispatchQueue.main.asyncAfter(deadline: .now() + PaymentSheetUI.delayBetweenSuccessAndDismissal) {
                            // Wait a bit before closing the sheet
                            self.delegate?.paymentSheetViewControllerDidFinish(self, result: .completed(paymentIntent: self.paymentIntent))
                        }
                    }
                }
            }
        }
    }
}

// MARK: - BottomSheetContentViewController
/// :nodoc:
extension PaymentSheetViewController: BottomSheetContentViewController {
    var allowsDragToDismiss: Bool {
        return isDismissable
    }

    func didTapOrSwipeToDismiss() {
        if isDismissable {
            delegate?.paymentSheetViewControllerDidCancel(self)
        }
    }
}

// MARK: - SavedPaymentOptionsViewControllerDelegate
/// :nodoc:
extension PaymentSheetViewController: SavedPaymentOptionsViewControllerDelegate {
    func didUpdateSelection(viewController: SavedPaymentOptionsViewController, paymentMethodSelection: SavedPaymentOptionsViewController.Selection) {
        if case .add = paymentMethodSelection {
            mode = .addingNew
            error = nil // Clear any errors
        }
        updateUI()
    }
}

// MARK: - AddPaymentMethodViewControllerDelegate
/// :nodoc:
extension PaymentSheetViewController: AddPaymentMethodViewControllerDelegate {
    func didUpdatePaymentMethodParams(_ viewController: AddPaymentMethodViewController) {
        updateUI()
    }

}

// MARK: - SheetNavigationBarDelegate
/// :nodoc:
extension PaymentSheetViewController: SheetNavigationBarDelegate {
    func sheetNavigationBarDidClose(_ sheetNavigationBar: SheetNavigationBar) {
        delegate?.paymentSheetViewControllerDidCancel(self)
    }

    func sheetNavigationBarDidBack(_ sheetNavigationBar: SheetNavigationBar) {
        // This is quite hardcoded. Could make some generic "previous state" or "previous VC" that we always go back to
        switch mode {
        case .addingNew:
            error = nil
            mode = .selectingSaved
            updateUI()
        default:
            assertionFailure()
        }
    }
}