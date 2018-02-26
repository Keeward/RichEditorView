//
//  RichEditor.swift
//
//  Created by Caesar Wirth on 4/1/15.
//  Copyright (c) 2015 Caesar Wirth. All rights reserved.
//

import UIKit
import WebKit

/// RichEditorDelegate defines callbacks for the delegate of the RichEditorView
@objc public protocol RichEditorDelegate: class {

    /// Called when the inner height of the text being displayed changes
    /// Can be used to update the UI
    @objc optional func richEditor(_ editor: RichEditorView, heightDidChange height: Int)

    /// Called whenever the content inside the view changes
    @objc optional func richEditor(_ editor: RichEditorView, contentDidChange content: String)

    /// Called when the rich editor starts editing
    @objc optional func richEditorTookFocus(_ editor: RichEditorView)
    
    /// Called when the rich editor stops editing or loses focus
    @objc optional func richEditorLostFocus(_ editor: RichEditorView)
    
    /// Called when the RichEditorView has become ready to receive input
    /// More concretely, is called when the internal WKWebView loads for the first time, and contentHTML is set
    @objc optional func richEditorDidLoad(_ editor: RichEditorView)
    
    /// Called when the internal WKWebView begins loading a URL that it does not know how to respond to
    /// For example, if there is an external link, and then the user taps it
    @objc optional func richEditor(_ editor: RichEditorView, shouldInteractWith url: URL) -> Bool
    
    /// Called when custom actions are called by callbacks in the JS
    /// By default, this method is not used unless called by some custom JS that you add
    @objc optional func richEditor(_ editor: RichEditorView, handle action: String)
}

/// RichEditorView is a UIView that displays richly styled text, and allows it to be edited in a WYSIWYG fashion.
open class RichEditorView: UIView, UIScrollViewDelegate, WKNavigationDelegate, UIGestureRecognizerDelegate {

    // MARK: Public Properties

    /// The delegate that will receive callbacks when certain actions are completed.
    open weak var delegate: RichEditorDelegate?

    /// Input accessory view to display over they keyboard.
    /// Defaults to nil
    open override var inputAccessoryView: UIView? {
        get { return webView.cjw_inputAccessoryView }
        set { webView.cjw_inputAccessoryView = newValue }
    }

    /// The internal WKWebView that is used to display the text.
    open private(set) var webView: WKWebView

    /// Whether or not scroll is enabled on the view.
    open var isScrollEnabled: Bool = true {
        didSet {
            webView.scrollView.isScrollEnabled = isScrollEnabled
        }
    }

    /// Whether or not to allow user input in the view.
    
    open func isEditingEnabled(completion: @escaping (Bool) -> Void) {
        isContentEditable(completion: completion)
    }
    
    open func set(isEditingEnabled: Bool) {
        set(isContentEditable: isEditingEnabled, completion: nil)
    }

    /// The content HTML of the text being displayed.
    /// Is continually updated as the text is being edited.
    open private(set) var contentHTML: String = "" {
        didSet {
            delegate?.richEditor?(self, contentDidChange: contentHTML)
        }
    }

    /// The internal height of the text being displayed.
    /// Is continually being updated as the text is edited.
    open private(set) var editorHeight: Int = 0 {
        didSet {
            delegate?.richEditor?(self, heightDidChange: editorHeight)
        }
    }

    /// The value we hold in order to be able to set the line height before the JS completely loads.
    private var innerLineHeight: Int = 28

    private var scrollCaretNotified: Bool = false

    /// The line height of the editor. Defaults to 28.
    func lineHeight(completion: @escaping (Int) -> Void) {
        runJS("RE.getLineHeight();") { (jsResult) in
            if self.isEditorLoaded, let lineHeight = Int(jsResult) {
                completion(lineHeight)
            } else {
                completion(self.innerLineHeight)
            }
        }
    }
    
    func set(lineHeight: Int, completion: (() -> Void)?) {
        self.innerLineHeight = lineHeight
        runJS("RE.setLineHeight('\(lineHeight)px');") { _ in
            completion?()
        }
    }

    // MARK: Private Properties

    /// Whether or not the editor has finished loading or not yet.
    private var isEditorLoaded = false

    /// Value that stores whether or not the content should be editable when the editor is loaded.
    /// Is basically `isEditingEnabled` before the editor is loaded.
    private var editingEnabledVar = true

    /// The private internal tap gesture recognizer used to detect taps and focus the editor
    private let tapRecognizer = UITapGestureRecognizer()

    /// The inner height of the editor div.
    /// Fetches it from JS every time, so might be slow!
    private func clientHeight(completion: @escaping (Int) -> Void) {
        runJS("document.getElementById('editor').clientHeight;") { (jsResult) in
            completion(Int(jsResult) ?? 0)
        }
    }

    // MARK: Initialization
    
    public override init(frame: CGRect) {
        webView = WKWebView()
        super.init(frame: frame)
        setup()
    }

    required public init?(coder aDecoder: NSCoder) {
        webView = WKWebView()
        super.init(coder: aDecoder)
        setup()
    }
    
    private func setup() {
        backgroundColor = .red
        
        webView.frame = bounds
        webView.navigationDelegate = self
        // !!!: After converting to WebKit this property is not available
        // webView.keyboardDisplayRequiresUserAction = false
        // webView.scalesPageToFit = false
        webView.allowsBackForwardNavigationGestures = false
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // !!!: After converting to WebKit this property is not available
        // webView.dataDetectorTypes = UIDataDetectorTypes()
        webView.backgroundColor = .white
        
        webView.scrollView.isScrollEnabled = isScrollEnabled
        webView.scrollView.bounces = false
        webView.scrollView.delegate = self
        webView.scrollView.clipsToBounds = false
        
        webView.cjw_inputAccessoryView = nil
        
        self.addSubview(webView)
        
        if let filePath = Bundle(for: RichEditorView.self).path(forResource: "rich_editor", ofType: "html") {
            let url = URL(fileURLWithPath: filePath, isDirectory: false)
            let request = URLRequest(url: url)
            webView.load(request)
        }

        tapRecognizer.addTarget(self, action: #selector(viewWasTapped))
        tapRecognizer.delegate = self
        addGestureRecognizer(tapRecognizer)
    }

    // MARK: - Rich Text Editing

    // MARK: Properties

    /// The HTML that is currently loaded in the editor view, if it is loaded. If it has not been loaded yet, it is the
    /// HTML that will be loaded into the editor view once it finishes initializing.
    public func html(completion: @escaping (String) -> Void) {
        runJS("RE.getHtml();") { (jsResult) in
            completion(jsResult)
        }
    }
    
    public func set(html: String, completion: (() -> Void)?) {
        self.contentHTML = html
        if isEditorLoaded {
            runJS("RE.setHtml('\(html.escaped)');") { (jsResult) in
                self.updateHeight()
                completion?() 
            }
        } else {
            completion?()
        }
    }

    /// Text representation of the data that has been input into the editor view, if it has been loaded.
    public func text(completion: @escaping (String) -> Void) {
        runJS("RE.getText();") { (jsResult) in
            completion(jsResult)
        }
    }

    /// Private variable that holds the placeholder text, so you can set the placeholder before the editor loads.
    private var placeholderText: String = ""
    /// The placeholder text that should be shown when there is no user input.
    open var placeholder: String {
        return placeholderText
    }
    
    open func set(placeholder: String, completion: (() -> Void)?) {
        self.placeholderText = placeholder
        runJS("RE.setPlaceholderText('\(placeholder.escaped)');") { (jsResult) in
            completion?()
        }
    }


    /// The href of the current selection, if the current selection's parent is an anchor tag.
    /// Will be nil if there is no href, or it is an empty string.
    public func selectedHref(completion: @escaping (String?) -> Void) {
        hasRangeSelection { (has) in
            guard has else {
                completion(nil)
                return
            }
            self.runJS("RE.getSelectedHref();", completion: { (jsResult) in
                completion(jsResult == "" ? nil : jsResult)
            })
        }
    }

    /// Whether or not the selection has a type specifically of "Range".
    public func hasRangeSelection(completion: @escaping (Bool) -> Void) {
        runJS("RE.rangeSelectionExists();") { (jsResult) in
            completion(jsResult == "true" ? true : false)
        }
    }

    /// Whether or not the selection has a type specifically of "Range" or "Caret".
    public func hasRangeOrCaretSelection(completion: @escaping (Bool) -> Void) {
        runJS("RE.rangeOrCaretSelectionExists();") { (jsResult) in
            completion(jsResult == "true" ? true : false)
        }
    }

    // MARK: Methods

    public func removeFormat() {
        runJS("RE.removeFormat();", completion: nil)
    }
    
    public func setFontSize(_ size: Int) {
        runJS("RE.setFontSize('\(size)px');", completion: nil)
    }
    
    public func setEditorBackgroundColor(_ color: UIColor) {
        runJS("RE.setBackgroundColor('\(color.hex)');", completion: nil)
    }
    
    public func undo() {
        runJS("RE.undo();", completion: nil)
    }
    
    public func redo() {
        runJS("RE.redo();", completion: nil)
    }
    
    public func bold() {
        runJS("RE.setBold();", completion: nil)
    }
    
    public func italic() {
        runJS("RE.setItalic();", completion: nil)
    }
    
    // "superscript" is a keyword
    public func subscriptText() {
        runJS("RE.setSubscript();", completion: nil)
    }
    
    public func superscript() {
        runJS("RE.setSuperscript();", completion: nil)
    }
    
    public func strikethrough() {
        runJS("RE.setStrikeThrough();", completion: nil)
    }
    
    public func underline() {
        runJS("RE.setUnderline();", completion: nil)
    }
    
    public func setTextColor(_ color: UIColor) {
        runJS("RE.prepareInsert();") { _ in
            self.runJS("RE.setTextColor('\(color.hex)');", completion: nil)
        }
    }
    
    public func setTextBackgroundColor(_ color: UIColor) {
        runJS("RE.prepareInsert();") { _ in
            self.runJS("RE.setTextBackgroundColor('\(color.hex)');", completion: nil)
        }
    }
    
    public func header(_ h: Int) {
        runJS("RE.setHeading('\(h)');", completion: nil)
    }

    public func indent() {
        runJS("RE.setIndent();", completion: nil)
    }

    public func outdent() {
        runJS("RE.setOutdent();", completion: nil)
    }

    public func orderedList() {
        runJS("RE.setOrderedList();", completion: nil)
    }

    public func unorderedList() {
        runJS("RE.setUnorderedList();", completion: nil)
    }

    public func blockquote() {
        runJS("RE.setBlockquote()", completion: nil);
    }
    
    public func alignLeft() {
        runJS("RE.setJustifyLeft();", completion: nil)
    }
    
    public func alignCenter() {
        runJS("RE.setJustifyCenter();", completion: nil)
    }
    
    public func alignRight() {
        runJS("RE.setJustifyRight();", completion: nil)
    }
    
    public func insertImage(_ url: String, alt: String) {
        runJS("RE.prepareInsert();") { _ in
            self.runJS("RE.insertImage('\(url.escaped)', '\(alt.escaped)');", completion: nil)
        }
    }
    
    public func insertLink(_ href: String, title: String) {
        runJS("RE.prepareInsert();") { _ in
            self.runJS("RE.insertLink('\(href.escaped)', '\(title.escaped)');", completion: nil)
        }
    }
    
    public func focus() {
        runJS("RE.focus();", completion: nil)
    }

    public func focus(at: CGPoint) {
        runJS("RE.focusAtPoint(\(at.x), \(at.y));", completion: nil)
    }
    
    public func blur() {
        runJS("RE.blurFocus()", completion: nil)
    }
    
    /// Runs some JavaScript on the WKWebView and returns the result asyncronisely
    /// If there is no result, returns an empty string
    /// - parameter js: The JavaScript string to be run
    /// - completion: The result of the JavaScript that was run
    public func runJS(_ js: String, completion: ((String) -> Void)?) {
        webView.evaluateJavaScript(js, completionHandler: {
            (_ result: Any?, _ error: Error?) -> Void in
            var resultString: String = ""
            defer {
                completion?(resultString)
            }
            
            guard error == nil else {
                print("evaluateJavaScript error (async) : \(error?.localizedDescription ?? "")")
                return
            }
            
            if let result = result {
                resultString = "\(result)"
            }
        })
    }


    // MARK: - Delegate Methods


    // MARK: UIScrollViewDelegate

    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // We use this to keep the scroll view from changing its offset when the keyboard comes up
        if !isScrollEnabled {
            scrollView.bounds = webView.bounds
        }
    }


    // MARK: WKNavigationDelegate
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Handle pre-defined editor actions
        let callbackPrefix = "re-callback://"
        if navigationAction.request.url?.absoluteString.hasPrefix(callbackPrefix) == true {
            // When we get a callback, we need to fetch the command queue to run the commands
            // It comes in as a JSON array of commands that we need to parse
            runJS("RE.getCommandQueue();", completion: { (commands) in
                if let data = commands.data(using: .utf8) {
                    
                    let jsonCommands: [String]
                    do {
                        jsonCommands = try JSONSerialization.jsonObject(with: data) as? [String] ?? []
                    } catch {
                        jsonCommands = []
                        NSLog("RichEditorView: Failed to parse JSON Commands")
                    }
                    
                    jsonCommands.forEach(self.performCommand)
                }
                
                decisionHandler(.cancel)
            })
            
            return
        }
        
        // User is tapping on a link, so we should react accordingly
        if navigationAction.navigationType == .linkActivated {
            if let
                url = navigationAction.request.url,
                let shouldInteract = delegate?.richEditor?(self, shouldInteractWith: url)
            {
                decisionHandler(shouldInteract ? .allow : .cancel)
                return
            }
        }
        
        decisionHandler(.allow)
    }


    // MARK: UIGestureRecognizerDelegate

    /// Delegate method for our UITapGestureDelegate.
    /// Since the internal web view also has gesture recognizers, we have to make sure that we actually receive our taps.
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }


    // MARK: - Private Implementation Details
    
    private func isContentEditable(completion: @escaping (Bool) -> Void) {
        if isEditorLoaded {
            runJS("RE.editor.isContentEditable", completion: { (jsResult) in
                self.editingEnabledVar = Bool(jsResult) ?? false
                completion(self.editingEnabledVar)
            })
            return
        }
        completion(editingEnabledVar)
    }
    
    private func set(isContentEditable: Bool, completion: (() -> Void)?) {
        self.editingEnabledVar = isContentEditable
        if isEditorLoaded {
            let value = isContentEditable ? "true" : "false"
            runJS("RE.editor.contentEditable = \(value);") { _ in
                completion?()
            }
            return
        }
        completion?()
    }
    
    /// The position of the caret relative to the currently shown content.
    /// For example, if the cursor is directly at the top of what is visible, it will return 0.
    /// This also means that it will be negative if it is above what is currently visible.
    /// Can also return 0 if some sort of error occurs between JS and here.
    private func relativeCaretYPosition(completion: @escaping (Int) -> Void) {
        runJS("RE.getRelativeCaretYPosition();") { (jsResult) in
            completion(Int(jsResult) ?? 0)
        }
    }

    private func updateHeight() {
        runJS("document.getElementById('editor').clientHeight;") { (heightString) in
            let height = Int(heightString) ?? 0
            if self.editorHeight != height {
                self.editorHeight = height
            }
        }
    }

    /// Scrolls the editor to a position where the caret is visible.
    /// Called repeatedly to make sure the caret is always visible when inputting text.
    /// Works only if the `lineHeight` of the editor is available.
    private func scrollCaretToVisible(completion: (() -> Void)?) {
        guard !self.scrollCaretNotified else {
          return
        }

        self.scrollCaretNotified = true

        var clientHeight: Int = 0
        var lineHeight: Int = 0
        var relativeCaretYPosition: Int = 0
        
        let group = DispatchGroup()
        group.enter()
        self.clientHeight { (height) in
            clientHeight = height
            group.leave()
        }
        group.enter()
        self.lineHeight { (height) in
            lineHeight = height
            group.leave()
        }
        group.enter()
        self.relativeCaretYPosition { (yPosition) in
            relativeCaretYPosition = yPosition
            group.leave()
        }
        
        group.notify(queue: DispatchQueue.main) {
            defer {
                self.scrollCaretNotified = false
                completion?()
            }
            
            let scrollView = self.webView.scrollView
            
            let contentHeight = clientHeight > 0 ? CGFloat(clientHeight) : scrollView.frame.height
            scrollView.contentSize = CGSize(width: scrollView.frame.width, height: contentHeight)
            
            // XXX: Maybe find a better way to get the cursor height
            let lineHeight = CGFloat(lineHeight)
            let cursorHeight = lineHeight - 4
            let visiblePosition = CGFloat(relativeCaretYPosition)
            var offset: CGPoint?
            
            if visiblePosition + cursorHeight > scrollView.bounds.size.height {
                // Visible caret position goes further than our bounds
                offset = CGPoint(x: 0, y: (visiblePosition + lineHeight) - scrollView.bounds.height + scrollView.contentOffset.y)
                
            } else if visiblePosition < 0 {
                // Visible caret position is above what is currently visible
                var amount = scrollView.contentOffset.y + visiblePosition
                amount = amount < 0 ? 0 : amount
                offset = CGPoint(x: scrollView.contentOffset.x, y: amount)
                
            }
            
            if let offset = offset {
                scrollView.setContentOffset(offset, animated: true)
            }
        }
    }
    
    /// Called when actions are received from JavaScript
    /// - parameter method: String with the name of the method and optional parameters that were passed in
    private func performCommand(_ method: String) {
        let group = DispatchGroup()
        
        if method.hasPrefix("ready") {
            // If loading for the first time, we have to set the content HTML to be displayed
            if !isEditorLoaded {
                isEditorLoaded = true
                group.enter()
                self.set(html: contentHTML, completion: {
                    group.leave()
                })
                group.enter()
                self.set(isContentEditable: editingEnabledVar) {
                    group.leave()
                }
                group.enter()
                self.set(lineHeight: innerLineHeight) {
                    group.leave()
                }
                group.enter()
                self.set(placeholder: placeholderText) {
                    group.leave()
                }
                group.notify(queue: DispatchQueue.main) {
                    self.updateHeight()
                    self.delegate?.richEditorDidLoad?(self)
                }
            } else {
                updateHeight()
            }
        }
        else if method.hasPrefix("input") {
            group.enter()
            scrollCaretToVisible(completion: {
                group.leave()
            })
            group.enter()
            self.html(completion: { (content) in
                self.contentHTML = content
                group.leave()
            })
            group.notify(queue: DispatchQueue.main) {
                self.updateHeight()
            }
        }
        else if method.hasPrefix("updateHeight") {
            updateHeight()
        }
        else if method.hasPrefix("focus") {
            delegate?.richEditorTookFocus?(self)
        }
        else if method.hasPrefix("blur") {
            delegate?.richEditorLostFocus?(self)
        }
        else if method.hasPrefix("action/") {
            group.enter()
            runJS("RE.getHtml()") { (content) in
                self.contentHTML = content
                group.leave()
            }
            
            group.notify(queue: DispatchQueue.main) {
                // If there are any custom actions being called
                // We need to tell the delegate about it
                let actionPrefix = "action/"
                let range = method.range(of: actionPrefix)!
                let action = method.replacingCharacters(in: range, with: "")
                self.delegate?.richEditor?(self, handle: action)
            }
        }
    }

    /// Called by the UITapGestureRecognizer when the user taps the view.
    /// If we are not already the first responder, focus the editor.
    @objc private func viewWasTapped() {
        if !webView.containsFirstResponder {
            let point = tapRecognizer.location(in: webView)
            focus(at: point)
        }
    }
    
}
