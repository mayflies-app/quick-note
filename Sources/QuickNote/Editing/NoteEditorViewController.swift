import AppKit
import QuickNoteCore

@MainActor
final class NoteEditorViewController: NSViewController, NSTextViewDelegate {
    var language = AppLanguage.systemDefault()
    var onEdit: (() -> Void)?
    var onChange: (([NoteBlock]) -> Void)?
    var onFormatStateChange: ((EditorFormatState) -> Void)?
    var onSelectionChange: ((BlockKind) -> Void)?
    var onError: ((Error) -> Void)?
    var textView: NSTextView { editor }
    private let editor = NoteTextView(frame: .zero)
    private var emptyBlock = NoteBlock()
    private var isUpdating = false
    private var pendingInsertion: (NSRange, String?)?
    private let snapshotCache = EditorSnapshotCache()
    private var paragraphCache: [EditorParagraph]?
    private var paragraphCacheText: String?

    override func loadView() {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        editor.isRichText = true
        editor.importsGraphics = false
        editor.isEditable = true
        editor.isSelectable = true
        editor.allowsUndo = true
        editor.isContinuousSpellCheckingEnabled = true
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticLinkDetectionEnabled = true
        editor.usesFindBar = true
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainerInset = NSSize(width: 20, height: 14)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.minSize = NSSize(width: 0, height: 300)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.drawsBackground = false
        editor.backgroundColor = .clear
        editor.textColor = .textColor
        editor.font = NSFont.systemFont(ofSize: 17)
        editor.delegate = self
        editor.owner = self
        scroll.documentView = editor
        view = scroll
        editor.typingAttributes = baseAttributes(for: emptyBlock)
    }

    func load(blocks: [NoteBlock]) {
        _ = view
        isUpdating = true
        defer { isUpdating = false }
        let source = blocks.isEmpty ? [NoteBlock()] : blocks
        emptyBlock = source.last!
        let result = NSMutableAttributedString(string: "")
        for (index, block) in source.enumerated() {
            let text: NSMutableAttributedString
            if let richText = block.richText {
                do {
                    let rich = try NSAttributedString(data: richText, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
                    guard rich.string == block.text else { throw EditorDocumentCodec.CodecError.invalidRichText(block.id) }
                    text = NSMutableAttributedString(attributedString: rich)
                    EditorDocumentCodec.restoreSemanticColors(in: text, rtf: richText)
                } catch {
                    text = NSMutableAttributedString(string: block.text)
                    onError?(EditorDocumentCodec.CodecError.invalidRichText(block.id))
                }
            } else {
                text = NSMutableAttributedString(string: block.text)
            }
            if index < source.count - 1 { text.append(NSAttributedString(string: "\n")) }
            style(text, range: NSRange(location: 0, length: text.length), block: block)
            result.append(text)
        }
        if source.last?.text.isEmpty == true, result.length > 0 {
            result.addAttributes([
                EditorDocumentCodec.tailID: emptyBlock.id.uuidString,
                EditorDocumentCodec.tailKind: emptyBlock.kind.rawValue,
                EditorDocumentCodec.tailChecked: emptyBlock.isChecked,
                EditorDocumentCodec.tailIndent: emptyBlock.indentLevel
            ], range: NSRange(location: result.length - 1, length: 1))
        }
        editor.textStorage?.setAttributedString(result)
        snapshotCache.reset()
        paragraphCache = nil
        normalize(fullDocument: true)
        editor.setSelectedRange(NSRange(location: result.length, length: 0))
        updateTypingAttributes()
        editor.undoManager?.removeAllActions()
        editor.needsDisplay = true
    }

    func snapshot() throws -> [NoteBlock] {
        _ = view
        return try snapshotCache.snapshot(editor.attributedString(), emptyBlock: emptyBlock)
    }

    func commitPendingInput() {
        _ = view
        guard editor.hasMarkedText() else { return }
        let markedRange = editor.markedRange()
        isUpdating = true
        editor.unmarkText()
        isUpdating = false
        pendingInsertion = (markedRange, nil)
        paragraphCache = nil
        normalize()
        convertListPrefixIfNeeded()
        updateTypingAttributes()
        publish()
    }

    func focus() {
        _ = view
        view.window?.makeFirstResponder(editor)
    }

    func apply(_ kind: BlockKind) {
        modifySelectedParagraphs { block in
            block.kind = kind
            if kind != .checklist { block.isChecked = false }
        }
    }

    func toggleChecklist() { apply(currentParagraph().block.kind == .checklist ? .body : .checklist) }
    func toggleChecked() {
        modifySelectedParagraphs { block in
            if block.kind == .checklist { block.isChecked.toggle() }
        }
    }
    func toggleBold() { toggleFontTrait(.boldFontMask) }
    func toggleItalic() { toggleFontTrait(.italicFontMask) }
    var formatState: EditorFormatState {
        _ = view
        let block = currentParagraph().block
        let attributes = selectedAttributes()
        return EditorFormatState(kind: block.kind,
            bold: attributes.allSatisfy { fontTrait(.boldFontMask, in: $0) },
            italic: attributes.allSatisfy { fontTrait(.italicFontMask, in: $0) },
            underline: attributes.allSatisfy { ($0[.underlineStyle] as? Int ?? 0) != 0 },
            strikethrough: attributes.allSatisfy { ($0[.strikethroughStyle] as? Int ?? 0) != 0 },
            highlight: uniformHighlight(in: attributes),
            indentLevel: block.indentLevel,
            alignment: (attributes.first?[.paragraphStyle] as? NSParagraphStyle)?.alignment ?? .natural)
    }

    private func uniformHighlight(in attributes: [[NSAttributedString.Key: Any]]) -> EditorHighlight? {
        let first = attributes.first.flatMap { EditorHighlight.matching($0[.backgroundColor] as? NSColor) }
        return attributes.allSatisfy { EditorHighlight.matching($0[.backgroundColor] as? NSColor) == first } ? first : nil
    }

    private func selectedAttributes() -> [[NSAttributedString.Key: Any]] {
        let range = editor.selectedRange()
        guard range.length > 0 else { return [editor.typingAttributes] }
        var result: [[NSAttributedString.Key: Any]] = []
        editor.attributedString().enumerateAttributes(in: range) { attributes, _, _ in result.append(attributes) }
        return result
    }

    private func fontTrait(_ trait: NSFontTraitMask, in attributes: [NSAttributedString.Key: Any]) -> Bool {
        let font = attributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: 17)
        return NSFontManager.shared.traits(of: font).contains(trait) || (trait == .italicFontMask && ((attributes[.obliqueness] as? NSNumber)?.doubleValue ?? 0) > 0)
    }

    func toggleUnderline() { toggleDecoration(.underlineStyle) }
    func toggleStrikethrough() { toggleDecoration(.strikethroughStyle) }
    private func toggleDecoration(_ key: NSAttributedString.Key) {
        let enable = !selectedAttributes().allSatisfy { ($0[key] as? Int ?? 0) != 0 }
        changeInline { attributes in
            var result = attributes
            result[key] = enable ? NSUnderlineStyle.single.rawValue : 0
            return result
        }
    }

    func setHighlight(_ highlight: EditorHighlight?) {
        changeInline { attributes in
            var result = attributes
            result[.backgroundColor] = highlight?.color
            return result
        }
    }

    func setLink(_ url: URL?) {
        if editor.selectedRange().length == 0, let url {
            editor.insertText(NSAttributedString(string: url.absoluteString, attributes: editor.typingAttributes.merging([.link: url]) { _, new in new }), replacementRange: editor.selectedRange())
        } else {
            changeInline { attributes in
                var result = attributes
                result[.link] = url
                return result
            }
        }
    }

    func indent() { modifySelectedParagraphs { $0.indentLevel = min(8, $0.indentLevel + 1) } }
    func outdent() { modifySelectedParagraphs { $0.indentLevel = max(0, $0.indentLevel - 1) } }

    func setAlignment(_ alignment: NSTextAlignment) {
        _ = view
        registerUndo()
        let selection = editor.selectedRange()
        guard let storage = editor.textStorage else { return }
        for paragraph in selectedParagraphs(selection) {
            let attributes = paragraph.range.length > 0 ? storage.attributes(at: paragraph.range.location, effectiveRange: nil) : editor.typingAttributes
            let style = (attributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            style.alignment = alignment
            if paragraph.range.length > 0 { storage.addAttribute(.paragraphStyle, value: style, range: paragraph.range) }
            if paragraph.range.length == 0 || intersects(paragraph.range, NSRange(location: selection.location, length: 0)) { editor.typingAttributes[.paragraphStyle] = style }
        }
        publish()
    }

    func clearFormatting() {
        _ = view
        registerUndo()
        let selection = editor.selectedRange()
        guard let storage = editor.textStorage else { return }
        let tailKeys = [EditorDocumentCodec.tailID, EditorDocumentCodec.tailKind, EditorDocumentCodec.tailChecked, EditorDocumentCodec.tailIndent]
        let savedTail = storage.length > 0 ? storage.attributes(at: storage.length - 1, effectiveRange: nil).filter { tailKeys.contains($0.key) } : [:]
        var clearedEmptyTail = false
        var changedSemantics = false
        let paragraphs = selectedParagraphs(selection)
        storage.beginEditing()
        for var paragraph in paragraphs {
            let selectedContent = NSIntersectionRange(paragraph.contentRange, selection)
            let isWholeParagraph = selection.length == 0 || (paragraph.contentRange.length > 0 && selectedContent.length == paragraph.contentRange.length) || (paragraph.contentRange.length == 0 && NSIntersectionRange(paragraph.range, selection).length > 0)
            if isWholeParagraph {
                paragraph.block.kind = .body
                paragraph.block.isChecked = false
                paragraph.block.indentLevel = 0
                changedSemantics = true
                if paragraph.range.length == 0 { emptyBlock = paragraph.block; clearedEmptyTail = true }
                else { storage.setAttributes(baseAttributes(for: paragraph.block), range: paragraph.range) }
            } else {
                let range = NSIntersectionRange(paragraph.range, selection)
                guard range.length > 0 else { continue }
                let copy = storage.attributedSubstring(from: range)
                copy.enumerateAttributes(in: NSRange(location: 0, length: copy.length)) { attributes, run, _ in
                    var clean = baseAttributes(for: paragraph.block)
                    if let style = attributes[.paragraphStyle] { clean[.paragraphStyle] = style }
                    for key in EditorDocumentCodec.metadataKeys { if let value = attributes[key] { clean[key] = value } }
                    storage.setAttributes(clean, range: NSRange(location: range.location + run.location, length: run.length))
                }
            }
        }
        if clearedEmptyTail, storage.length > 0 {
            storage.addAttributes([EditorDocumentCodec.tailKind: emptyBlock.kind.rawValue, EditorDocumentCodec.tailChecked: false, EditorDocumentCodec.tailIndent: 0], range: NSRange(location: storage.length - 1, length: 1))
        } else if storage.length > 0, !savedTail.isEmpty {
            storage.addAttributes(savedTail, range: NSRange(location: storage.length - 1, length: 1))
        }
        storage.endEditing()
        if changedSemantics { paragraphCache = nil }
        if selection.location < storage.length {
            editor.typingAttributes = storage.attributes(at: selection.location, effectiveRange: nil)
        } else { editor.typingAttributes = baseAttributes(for: currentParagraph().block) }
        updateTypingAttributes()
        publish()
    }

    private func toggleFontTrait(_ trait: NSFontTraitMask) {
        let enable = !selectedAttributes().allSatisfy { fontTrait(trait, in: $0) }
        changeInline { attributes in
            var result = attributes
            let font = attributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: 17)
            result[.font] = EditorFont.stable(font, bold: trait == .boldFontMask ? enable : nil, italic: trait == .italicFontMask ? enable : nil)
            if trait == .italicFontMask { result[.obliqueness] = enable ? 0.2 : 0.0 }
            return result
        }
    }

    private func changeInline(_ change: ([NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any]) {
        _ = view
        let range = editor.selectedRange()
        if range.length == 0 {
            editor.typingAttributes = change(editor.typingAttributes)
            onFormatStateChange?(formatState)
            return
        }
        registerUndo()
        guard let storage = editor.textStorage else { return }
        let copy = NSAttributedString(attributedString: storage)
        storage.beginEditing()
        copy.enumerateAttributes(in: range) { attributes, run, _ in storage.setAttributes(change(attributes), range: run) }
        storage.endEditing()
        publish()
    }

    private func modifySelectedParagraphs(_ change: (inout NoteBlock) -> Void) {
        _ = view
        registerUndo()
        let selection = editor.selectedRange()
        guard let storage = editor.textStorage else { return }
        let paragraphs = selectedParagraphs(selection)
        storage.beginEditing()
        for var paragraph in paragraphs {
            let originalKind = paragraph.block.kind
            change(&paragraph.block)
            if paragraph.range.length == 0 {
                emptyBlock = paragraph.block
                if storage.length > 0 {
                    storage.addAttributes([
                        EditorDocumentCodec.tailID: paragraph.block.id.uuidString,
                        EditorDocumentCodec.tailKind: paragraph.block.kind.rawValue,
                        EditorDocumentCodec.tailChecked: paragraph.block.isChecked,
                        EditorDocumentCodec.tailIndent: paragraph.block.indentLevel
                    ], range: NSRange(location: storage.length - 1, length: 1))
                }
            }
            else { style(storage, range: paragraph.range, block: paragraph.block, forceSemanticFont: originalKind != paragraph.block.kind) }
        }
        storage.endEditing()
        paragraphCache = nil
        updateTypingAttributes()
        publish()
    }

    private func registerUndo() {
        let oldText = NSAttributedString(attributedString: editor.attributedString())
        let oldEmpty = emptyBlock
        let oldSelection = editor.selectedRange()
        editor.breakUndoCoalescing()
        editor.undoManager?.registerUndo(withTarget: self) { target in
            target.registerUndo()
            target.isUpdating = true
            target.emptyBlock = oldEmpty
            target.editor.textStorage?.setAttributedString(oldText)
            target.paragraphCache = nil
            target.snapshotCache.reset()
            target.editor.setSelectedRange(oldSelection)
            target.isUpdating = false
            target.updateTypingAttributes()
            target.publish()
        }
        editor.undoManager?.setActionName(L("设置格式"))
    }

    private func intersects(_ paragraph: NSRange, _ selection: NSRange) -> Bool {
        if selection.length == 0 {
            if selection.location == NSMaxRange(paragraph), NSMaxRange(paragraph) == editor.string.utf16.count, !editor.string.hasSuffix("\n") { return true }
            return selection.location >= paragraph.location && (selection.location < NSMaxRange(paragraph) || (paragraph.length == 0 && selection.location == paragraph.location))
        }
        return NSIntersectionRange(paragraph, selection).length > 0
    }

    private func currentParagraph() -> EditorParagraph {
        _ = view
        let text = editor.textStorage ?? NSTextStorage(attributedString: editor.attributedString())
        return EditorDocumentCodec.paragraph(at: min(editor.selectedRange().location, text.length), in: text, emptyBlock: emptyBlock)
    }

    private func selectedParagraphs(_ selection: NSRange) -> [EditorParagraph] {
        paragraphs(from: selection.location, through: NSMaxRange(selection), includingEnd: selection.length == 0)
    }

    private func paragraphs(from start: Int, through end: Int, includingEnd: Bool) -> [EditorParagraph] {
        guard let storage = editor.textStorage else { return [] }
        var paragraph = EditorDocumentCodec.paragraph(at: min(start, storage.length), in: storage, emptyBlock: emptyBlock)
        var result = [paragraph]
        while paragraph.range.length > 0 {
            let next = NSMaxRange(paragraph.range)
            guard next < end || (includingEnd && next <= end) else { break }
            let following = EditorDocumentCodec.paragraph(at: min(next, storage.length), in: storage, emptyBlock: emptyBlock)
            guard following.range.location > paragraph.range.location else { break }
            result.append(following)
            paragraph = following
        }
        return result
    }

    private func baseAttributes(for block: NoteBlock) -> [NSAttributedString.Key: Any] {
        var result = EditorDocumentCodec.attributes(for: block)
        result[.font] = EditorTypography.font(for: block.kind)
        result[.paragraphStyle] = EditorTypography.paragraphStyle(for: block)
        result[.foregroundColor] = EditorTypography.foregroundColor(for: block.kind)
        return result
    }

    private func paragraphStyle(for block: NoteBlock, existing: NSParagraphStyle?) -> NSParagraphStyle {
        EditorTypography.paragraphStyle(for: block, alignment: existing?.alignment ?? .natural)
    }

    func markerGeometry(at location: Int, number: Int = 1) -> EditorMarkerGeometry? {
        _ = view
        let paragraph = EditorDocumentCodec.paragraph(at: location, in: editor.attributedString(), emptyBlock: emptyBlock)
        return editor.markerGeometry(for: paragraph, number: number)
    }

    private func style(_ text: NSMutableAttributedString, range: NSRange, block: NoteBlock, forceSemanticFont: Bool = false) {
        guard range.length > 0 else { return }
        let base = baseAttributes(for: block)
        let copy = NSAttributedString(attributedString: text)
        text.addAttributes(EditorDocumentCodec.attributes(for: block), range: range)
        copy.enumerateAttributes(in: range) { existing, run, _ in
            var changes: [NSAttributedString.Key: Any] = [
                .paragraphStyle: paragraphStyle(for: block, existing: existing[.paragraphStyle] as? NSParagraphStyle)
            ]
            let baseFont = base[.font] as! NSFont
            if let font = existing[.font] as? NSFont {
                let oldKind = (existing[EditorDocumentCodec.kind] as? String).flatMap(BlockKind.init(rawValue:))
                let headings: [BlockKind] = [.title, .heading, .subheading]
                let leavingHeading = forceSemanticFont && oldKind.map(headings.contains) == true && !headings.contains(block.kind)
                let switchingMonostyle = forceSemanticFont && (block.kind == .code || oldKind == .code)
                changes[.font] = EditorFont.stable(switchingMonostyle ? baseFont : font,
                    size: forceSemanticFont ? baseFont.pointSize : nil,
                    bold: forceSemanticFont && headings.contains(block.kind) ? true : leavingHeading ? false : nil)
                if font.fontDescriptor.symbolicTraits.contains(.italic) { changes[.obliqueness] = 0.2 }
            } else { changes[.font] = baseFont }
            let oldKind = (existing[EditorDocumentCodec.kind] as? String).flatMap(BlockKind.init(rawValue:))
            let oldDefault = oldKind.map(EditorTypography.foregroundColor)
            if existing[.foregroundColor] == nil || (forceSemanticFont && (existing[.foregroundColor] as? NSColor) == oldDefault) {
                changes[.foregroundColor] = base[.foregroundColor]
            }
            text.addAttributes(changes, range: run)
        }
    }

    private func normalize(fullDocument: Bool = false) {
        guard let storage = editor.textStorage else { return }
        let insertion = pendingInsertion
        let affected: [EditorParagraph]
        if fullDocument {
            affected = EditorDocumentCodec.paragraphs(in: storage, emptyBlock: emptyBlock)
        } else if let (range, replacement) = insertion {
            let end = min(storage.length, range.location + (replacement?.utf16.count ?? range.length))
            affected = paragraphs(from: min(range.location, storage.length), through: end, includingEnd: true)
        } else { affected = selectedParagraphs(editor.selectedRange()) }
        var seen = Set<UUID>()
        if let first = affected.first, first.range.location > 0 {
            seen.insert(EditorDocumentCodec.paragraph(at: first.range.location - 1, in: storage, emptyBlock: emptyBlock).block.id)
        }
        storage.beginEditing()
        for var paragraph in affected {
            if !seen.insert(paragraph.block.id).inserted {
                paragraph.block.id = UUID()
                paragraph.block.isChecked = false
                seen.insert(paragraph.block.id)
            }
            var transitionToBody = false
            if let (range, replacement) = insertion, let replacement, replacement.contains("\n"),
               paragraph.range.location > range.location, paragraph.range.location <= range.location + replacement.utf16.count {
                paragraph.block.isChecked = false
                if [.title, .heading, .subheading].contains(paragraph.block.kind) {
                    paragraph.block.kind = .body
                    transitionToBody = true
                }
            }
            if paragraph.range.length > 0 {
                storage.addAttributes(EditorDocumentCodec.attributes(for: paragraph.block), range: paragraph.range)
                if transitionToBody { storage.addAttribute(.font, value: baseAttributes(for: paragraph.block)[.font]!, range: paragraph.range) }
                let existingStyle = storage.attribute(.paragraphStyle, at: paragraph.range.location, effectiveRange: nil) as? NSParagraphStyle
                storage.addAttribute(.paragraphStyle, value: paragraphStyle(for: paragraph.block, existing: existingStyle), range: paragraph.range)
            }
            if NSMaxRange(paragraph.range) == storage.length {
                emptyBlock = paragraph.block
                if paragraph.range.length == 0, storage.length > 0 {
                    storage.addAttributes([
                        EditorDocumentCodec.tailID: paragraph.block.id.uuidString,
                        EditorDocumentCodec.tailKind: paragraph.block.kind.rawValue,
                        EditorDocumentCodec.tailChecked: paragraph.block.isChecked,
                        EditorDocumentCodec.tailIndent: paragraph.block.indentLevel
                    ], range: NSRange(location: storage.length - 1, length: 1))
                }
            }
        }
        if let first = affected.first, let last = affected.last {
            let range = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
            if range.length > 0 { EditorFont.sanitize(storage, range: range) }
        }
        storage.endEditing()
        pendingInsertion = nil
    }

    private func updateTypingAttributes() {
        let block = currentParagraph().block
        var attributes = editor.typingAttributes
        for key in EditorDocumentCodec.metadataKeys { attributes.removeValue(forKey: key) }
        var base = baseAttributes(for: block)
        // NSTextView carries the selected run's inline formatting in its typing attributes.
        // Only reset the font when the semantic paragraph type changes.
        let previousKind = (editor.typingAttributes[EditorDocumentCodec.kind] as? String).flatMap(BlockKind.init(rawValue:))
        if previousKind == block.kind, attributes[.font] != nil { base.removeValue(forKey: .font) }
        if let color = attributes[.foregroundColor] as? NSColor,
           previousKind == block.kind || color != previousKind.map(EditorTypography.foregroundColor) {
            base.removeValue(forKey: .foregroundColor)
        }
        if let existing = attributes[.paragraphStyle] as? NSParagraphStyle { base[.paragraphStyle] = paragraphStyle(for: block, existing: existing) }
        attributes.merge(base) { _, new in new }
        editor.typingAttributes = attributes
        onSelectionChange?(block.kind)
        onFormatStateChange?(formatState)
    }

    private func publish() {
        editor.needsDisplay = true
        onEdit?()
        onFormatStateChange?(formatState)
        if let onChange {
            do { onChange(try snapshot()) } catch { onError?(error) }
        }
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard !isUpdating else { return true }
        pendingInsertion = (affectedCharRange, replacementString)
        if replacementString != nil { paragraphCache = nil }
        return true
    }

    func textDidChange(_ notification: Notification) {
        guard !isUpdating, !editor.hasMarkedText() else { return }
        if pendingInsertion?.1 != nil || (paragraphCache != nil && paragraphCacheText != editor.string) { paragraphCache = nil }
        normalize()
        convertListPrefixIfNeeded()
        updateTypingAttributes()
        publish()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !isUpdating, !editor.hasMarkedText() else { return }
        updateTypingAttributes()
    }

    fileprivate func handleReturn() -> Bool {
        let paragraph = currentParagraph()
        if [.bullet, .dashed, .numbered, .checklist].contains(paragraph.block.kind), paragraph.block.text.isEmpty {
            if paragraph.block.indentLevel > 0 { outdent() } else { apply(.body) }
            return true
        }
        return false
    }

    fileprivate func handleBackspace() -> Bool {
        guard !editor.hasMarkedText(), editor.selectedRange().length == 0 else { return false }
        let paragraph = currentParagraph()
        guard editor.selectedRange().location == paragraph.range.location, paragraph.block.text.isEmpty,
              [.bullet, .dashed, .numbered, .checklist].contains(paragraph.block.kind) else { return false }
        if paragraph.block.indentLevel > 0 { outdent() } else { apply(.body) }
        return true
    }

    fileprivate var isInList: Bool { [.bullet, .dashed, .numbered, .checklist].contains(currentParagraph().block.kind) }

    private func convertListPrefixIfNeeded() {
        guard !isUpdating else { return }
        let paragraph = currentParagraph()
        guard paragraph.block.kind == .body, editor.selectedRange().length == 0,
              editor.selectedRange().location == NSMaxRange(paragraph.contentRange) else { return }
        let prefixes: [String: BlockKind] = ["* ": .bullet, "- ": .dashed, "1. ": .numbered]
        guard let kind = prefixes[paragraph.block.text] else { return }
        // Conversion belongs to the same native undo group as the typed prefix.
        isUpdating = true
        editor.insertText("", replacementRange: paragraph.contentRange)
        isUpdating = false
        pendingInsertion = nil
        apply(kind)
    }

    fileprivate func toggleCheckbox(at location: Int) {
        editor.setSelectedRange(NSRange(location: location, length: 0))
        toggleChecked()
    }

    fileprivate var visibleParagraphs: [EditorParagraph] {
        if let paragraphCache, paragraphCacheText == editor.string { return paragraphCache }
        let paragraphs = EditorDocumentCodec.paragraphs(in: editor.attributedString(), emptyBlock: emptyBlock)
        paragraphCache = paragraphs
        paragraphCacheText = editor.string
        return paragraphs
    }
}

@MainActor
private final class NoteTextView: NSTextView {

    weak var owner: NoteEditorViewController?
    private let localUndoManager = UndoManager()
    override var undoManager: UndoManager? { window?.undoManager ?? localUndoManager }

    override func deleteBackward(_ sender: Any?) {
        if owner?.handleBackspace() == true { return }
        super.deleteBackward(sender)
    }

    override func insertNewline(_ sender: Any?) {
        if owner?.handleReturn() == true { return }
        super.insertNewline(sender)
    }

    override func keyDown(with event: NSEvent) {
        // Use the actual key event, rather than global modifier state left by
        // unrelated shortcuts. Direct insertTab commands always indent lists.
        if event.keyCode == 48, event.modifierFlags.contains(.option) {
            insertText("\t", replacementRange: selectedRange())
            return
        }
        super.keyDown(with: event)
    }

    override func insertLineBreak(_ sender: Any?) {
        insertText("\u{2028}", replacementRange: selectedRange())
    }

    override func insertTab(_ sender: Any?) {
        if owner?.isInList == true { owner?.indent() }
        else { super.insertTab(sender) }
    }

    override func insertBacktab(_ sender: Any?) {
        if owner?.isInList == true { owner?.outdent() }
        else { super.insertBacktab(sender) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let owner, EditorShortcuts.handle(event, editor: owner) { return true }
        return super.performKeyEquivalent(with: event)
    }

    fileprivate func markerGeometry(for paragraph: EditorParagraph, number: Int = 1) -> EditorMarkerGeometry? {
        guard EditorListLayout.markedKinds.contains(paragraph.block.kind), let layoutManager, let textContainer else { return nil }
        layoutManager.ensureLayout(for: textContainer)
        let font: NSFont
        let textStart: CGFloat
        let baseline: CGFloat
        if paragraph.range.location < (textStorage?.length ?? 0) {
            let glyph = layoutManager.glyphIndexForCharacter(at: paragraph.range.location)
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            guard fragment.height > 0 else { return nil }
            let position = layoutManager.location(forGlyphAt: glyph)
            textStart = textContainerOrigin.x + fragment.minX + position.x
            baseline = textContainerOrigin.y + fragment.minY + position.y
            font = textStorage?.attribute(.font, at: paragraph.range.location, effectiveRange: nil) as? NSFont ?? EditorTypography.font(for: paragraph.block.kind)
        } else {
            let fragment = layoutManager.extraLineFragmentRect
            guard fragment.height > 0 else { return nil }
            font = typingAttributes[.font] as? NSFont ?? EditorTypography.font(for: paragraph.block.kind)
            textStart = textContainerOrigin.x + textContainer.lineFragmentPadding + EditorListLayout.headIndent(for: paragraph.block)
            baseline = textContainerOrigin.y + fragment.minY + font.ascender
        }
        guard var geometry = EditorListLayout.geometry(kind: paragraph.block.kind, number: number, textStart: textStart, baseline: baseline, textFont: font) else { return nil }
        if paragraph.block.kind == .quote, paragraph.contentRange.length > 0 {
            let glyphs = layoutManager.glyphRange(forCharacterRange: paragraph.contentRange, actualCharacterRange: nil)
            let bounds = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
            // Alignment can place a short first line to the right of later lines.
            // Anchor the rule outside the complete content rather than that first line.
            var left = CGFloat.greatestFiniteMagnitude
            var glyph = glyphs.location
            while glyph < NSMaxRange(glyphs) {
                var lineRange = NSRange()
                let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineRange)
                left = min(left, fragment.minX + layoutManager.location(forGlyphAt: glyph).x)
                glyph = NSMaxRange(lineRange)
            }
            geometry.frame.origin.x = textContainerOrigin.x + left - 12
            geometry.frame.origin.y = textContainerOrigin.y + bounds.minY
            geometry.frame.size.height = max(16, bounds.height)
        }
        return geometry
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty, owner?.visibleParagraphs.first?.block.kind == .body {
            (AppLocalization.text("写下此刻的想法…", language: owner?.language ?? .systemDefault()) as NSString).draw(at: NSPoint(x: textContainerOrigin.x + 5, y: textContainerOrigin.y), withAttributes: [.font: NSFont.systemFont(ofSize: 17), .foregroundColor: NSColor.placeholderTextColor])
        }
        var counters: [Int: Int] = [:]
        for paragraph in owner?.visibleParagraphs ?? [] {
            let level = paragraph.block.indentLevel
            if paragraph.block.kind == .numbered {
                counters = counters.filter { $0.key <= level }
                counters[level, default: 0] += 1
            } else if [.bullet, .dashed, .checklist].contains(paragraph.block.kind) {
                counters = counters.filter { $0.key < level }
            } else { counters.removeAll() }
            guard EditorListLayout.markedKinds.contains(paragraph.block.kind) else { continue }
            guard let geometry = markerGeometry(for: paragraph, number: counters[level, default: 1]), geometry.frame.intersects(dirtyRect) else { continue }
            let rect = geometry.frame
            switch paragraph.block.kind {
            case .checklist:
                let path = NSBezierPath(ovalIn: rect.insetBy(dx: 0.65, dy: 0.65))
                path.lineWidth = 1.3
                (paragraph.block.isChecked ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setStroke()
                path.stroke()
                if paragraph.block.isChecked {
                    NSColor.controlAccentColor.setFill(); path.fill()
                    let check = NSBezierPath()
                    check.move(to: NSPoint(x: rect.minX + rect.width * 0.22, y: rect.minY + rect.height * 0.52))
                    check.line(to: NSPoint(x: rect.minX + rect.width * 0.43, y: rect.minY + rect.height * 0.72))
                    check.line(to: NSPoint(x: rect.minX + rect.width * 0.80, y: rect.minY + rect.height * 0.28))
                    check.lineWidth = 1.6; check.lineCapStyle = .round
                    NSColor.white.setStroke(); check.stroke()
                }
            case .bullet:
                NSColor.secondaryLabelColor.setFill()
                NSBezierPath(ovalIn: rect).fill()
            case .dashed:
                NSColor.secondaryLabelColor.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 0.75, yRadius: 0.75).fill()
            case .numbered:
                ("\(counters[level, default: 1])." as NSString).draw(at: rect.origin, withAttributes: [.font: geometry.font!, .foregroundColor: NSColor.secondaryLabelColor])
            case .quote:
                NSColor.labelColor.withAlphaComponent(0.20).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
            default: break
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        for paragraph in owner?.visibleParagraphs ?? [] where paragraph.block.kind == .checklist {
            if let geometry = markerGeometry(for: paragraph), geometry.frame.insetBy(dx: -4, dy: -4).contains(point) {
                owner?.toggleCheckbox(at: paragraph.range.location)
                return
            }
        }
        super.mouseDown(with: event)
    }
}
