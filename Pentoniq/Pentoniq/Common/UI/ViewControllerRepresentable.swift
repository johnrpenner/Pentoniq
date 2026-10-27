//
//  ViewControllerRepresentable.swift
//  Pentoniq
//
//  Created by John Penner on 2026-10-15.
//
//  macOS branch changed in milestone 6: the audio unit's view is placed in a container that has
//  NO size preference of its own, so SwiftUI always gives it the whole window. (Handing the view
//  controller straight to SwiftUI let the plug-in's own size act as a cap, which is why the
//  panel stopped growing with the window.)

import SwiftUI

#if os(iOS) || os(visionOS)

struct AUViewControllerUI: UIViewControllerRepresentable {
    var auViewController: UIViewController?

    init(viewController: UIViewController?) {
        self.auViewController = viewController
    }
    
    func makeUIViewController(context: Context) -> UIViewController {
        guard let auViewController = self.auViewController else {
            return UIViewController()
        }
        
        let viewController = UIViewController()
        viewController.addChild(auViewController)

        let frame: CGRect = viewController.view.bounds
        auViewController.view.frame = frame
        
        viewController.view.addSubview(auViewController.view)
        auViewController.didMove(toParent: viewController)
        return viewController
    }
    
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        // No op
    }
}
#elseif os(macOS)

/// Holds the audio unit's view and keeps it exactly the size of the container.
final class FlexibleAUHostView: NSView {
    private let controller: NSViewController?   // keeps the plug-in's view controller alive

    init(viewController: NSViewController?) {
        controller = viewController
        super.init(frame: .zero)
        // The child's frame is set explicitly (below) every time this view changes size, rather than
        // by autoresizing masks: autoresizing from an initial size of zero is what left the panel
        // pinned to one edge and clipped.
        autoresizesSubviews = false
        wantsLayer = true
        layer?.masksToBounds = true
        if let child = viewController?.view {
            child.translatesAutoresizingMaskIntoConstraints = true
            child.frame = bounds
            addSubview(child)
        }
    }

    private func fitChild() {
        guard let child = subviews.first, child.frame != bounds else { return }
        child.frame = bounds
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        fitChild()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        fitChild()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        fitChild()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// No preferred size: SwiftUI offers the whole window.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func layout() {
        super.layout()
        fitChild()
    }
}

struct AUViewControllerUI: NSViewRepresentable {

    var auViewController: NSViewController?

    init(viewController: NSViewController?) {
        self.auViewController = viewController
    }
    
    func makeNSView(context: Context) -> FlexibleAUHostView {
        FlexibleAUHostView(viewController: auViewController)
    }
    
    func updateNSView(_ nsView: FlexibleAUHostView, context: Context) {
        // No op
    }
}
#endif
