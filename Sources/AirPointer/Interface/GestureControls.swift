import AppKit
import Carbon

// What a gesture does, chosen in Settings: Nothing, a preset key or click, or a shortcut pressed after
// choosing Custom Shortcut…. A shortcut that quits or closes things, the pointer shortcut, or one another
// gesture already sends is turned down with the reason, and the old choice stays.
final class GestureActionControl:NSStackView {
    let gesture:CaseGesture
    var onChange:((GestureAction)->Void)?
    // Says why a shortcut was turned down, or how to record one; nil puts back the row's usual line.
    var onNote:((String?)->Void)?
    // The shortcuts the other gestures send, so two never send the same one.
    var others:()->[GestureShortcut]={[]}
    private let popup=NSPopUpButton(frame:.zero,pullsDown:false)
    private(set) var action=GestureAction.nothing
    private var monitor:Any?,resignObserver:Any?
    private static let customTitle="Custom Shortcut…"

    init(gesture:CaseGesture) {
        self.gesture=gesture
        super.init(frame:.zero)
        translatesAutoresizingMaskIntoConstraints=false;orientation = .horizontal;spacing=8
        popup.target=self;popup.action=#selector(chosen);popup.setAccessibilityLabel("What \(gesture.title) does")
        // One width whatever is chosen, so the row's caption keeps the width it wrapped to.
        popup.translatesAutoresizingMaskIntoConstraints=false;popup.widthAnchor.constraint(equalToConstant:176).isActive=true
        addArrangedSubview(popup)
        rebuild()
    }
    required init?(coder:NSCoder){fatalError("init(coder:) is not used")}
    deinit{stopListening()}

    func set(_ next:GestureAction){guard monitor==nil else{return};action=next;rebuild()}
    private func rebuild() {
        popup.removeAllItems()
        for preset in GestureAction.presets{popup.addItem(withTitle:preset.title)}
        popup.menu?.addItem(.separator())
        if action.shortcut != nil,!GestureAction.presets.contains(where:{$0.action==action}){popup.addItem(withTitle:action.title)}
        popup.addItem(withTitle:Self.customTitle)
        popup.selectItem(withTitle:action.title)
    }
    @objc private func chosen() {
        guard let title=popup.titleOfSelectedItem else{return}
        if title==Self.customTitle{begin();return}
        if let preset=GestureAction.presets.first(where:{$0.title==title}){action=preset.action;onNote?(nil);onChange?(action)}
    }
    // Records the next key pressed, with its modifiers. esc or clicking elsewhere keeps the old choice.
    private func begin() {
        guard monitor==nil else{return}
        PointerShortcutKeys.shared.suspended=true
        popup.removeAllItems();popup.addItem(withTitle:"Press keys…");popup.setAccessibilityLabel("Waiting for the shortcut \(gesture.title) sends")
        onNote?("Press the shortcut \(gesture.title) should send, or esc to keep \(action.title).")
        monitor=NSEvent.addLocalMonitorForEvents(matching:[.keyDown,.leftMouseDown]){[weak self] event in self?.handle(event) ?? event}
        resignObserver=NotificationCenter.default.addObserver(forName:NSApplication.didResignActiveNotification,object:nil,queue:.main){[weak self] _ in self?.finish(nil)}
    }
    private func handle(_ event:NSEvent)->NSEvent? {
        if event.type == .leftMouseDown{finish(nil);return event}
        guard !event.isARepeat else{return nil}
        let modifiers=event.modifierFlags.intersection(GestureShortcut.relevant)
        if event.keyCode==UInt16(kVK_Escape),modifiers.isEmpty{finish(nil);return nil}
        let shortcut=GestureShortcut(key:event.keyCode,modifiers:modifiers,name:Self.name(of:event))
        if let refusal=GestureShortcut.refusal(shortcut,pointer:PointerShortcut.current,others:others()){onNote?(refusal);return nil}
        finish(.keys(shortcut))
        return nil
    }
    private func finish(_ next:GestureAction?) {
        stopListening()
        PointerShortcutKeys.shared.suspended=false
        popup.setAccessibilityLabel("What \(gesture.title) does")
        if let next{action=next}
        rebuild();onNote?(nil)
        if let next{onChange?(next)}
    }
    private func stopListening() {
        if let monitor{NSEvent.removeMonitor(monitor);self.monitor=nil}
        if let resignObserver{NotificationCenter.default.removeObserver(resignObserver);self.resignObserver=nil}
    }
    static func name(of event:NSEvent)->String {
        switch Int(event.keyCode) {
        case kVK_Space:return "Space"
        case kVK_Return,kVK_ANSI_KeypadEnter:return "Return"
        case kVK_Tab:return "Tab"
        case kVK_Delete:return "Delete"
        case kVK_ForwardDelete:return "Forward Delete"
        case kVK_LeftArrow:return "←"
        case kVK_RightArrow:return "→"
        case kVK_UpArrow:return "↑"
        case kVK_DownArrow:return "↓"
        case kVK_PageUp:return "Page Up"
        case kVK_PageDown:return "Page Down"
        case kVK_Home:return "Home"
        case kVK_End:return "End"
        default:break
        }
        if let special=event.specialKey,let number=(1...20).first(where:{NSEvent.SpecialKey(rawValue:NSF1FunctionKey+$0-1)==special}){return "F\(number)"}
        let text=event.charactersIgnoringModifiers?.trimmingCharacters(in:.whitespacesAndNewlines).uppercased() ?? ""
        return text.isEmpty ? "Key \(event.keyCode)":text
    }
}

// One dot for each flick heard, like setup's tap dots, on the window's own background.
final class GestureDots:NSView {
    var heard=0{didSet{if heard != oldValue{needsDisplay=true;label()}}}
    let count:Int
    init(count:Int){self.count=count;super.init(frame:.zero);setAccessibilityElement(true);setAccessibilityRole(.image);label()}
    required init?(coder:NSCoder){fatalError("init(coder:) is not used")}
    override var intrinsicContentSize:NSSize{NSSize(width:CGFloat(count)*28+CGFloat(count-1)*20,height:28)}
    private func label(){setAccessibilityLabel("\(heard) of \(count) flicks heard")}
    override func draw(_ dirtyRect:NSRect) {
        let size:CGFloat=28,gap:CGFloat=20,left=round(bounds.midX-(CGFloat(count)*size+CGFloat(count-1)*gap)/2),y=round(bounds.midY-size/2)
        for index in 0..<count {
            let disc=NSRect(x:left+CGFloat(index)*(size+gap),y:y,width:size,height:size)
            if index<heard{HomePalette.ink.setFill();NSBezierPath(ovalIn:disc).fill()}
            else{let ring=NSBezierPath(ovalIn:disc.insetBy(dx:1,dy:1));ring.lineWidth=2;HomePalette.rule.setStroke();ring.stroke()}
        }
    }
}

// Teaching Yes or No: a sheet on the main window that fills a dot for each flick, then learns the movement.
// One primary: Done once learned, Try Again after a failure; Cancel otherwise.
final class GestureTeachSheet:NSObject {
    let gesture:CaseGesture
    let window:NSWindow
    var onDone:(()->Void)?,onCancel:(()->Void)?,onRetry:(()->Void)?
    private let title=rkLabel("",17,.semibold)
    private let body=rkWrap("",13,.secondaryLabelColor)
    private let dots=GestureDots(count:ClosedCaseFlickLearner.flicks)
    private let note=rkWrap("",12,.secondaryLabelColor)
    private lazy var cancel=RemoteButton("Cancel",style:.secondary,height:32,target:self,action:#selector(cancelPressed))
    private lazy var primary=RemoteButton("Listening…",style:.primary,height:32,target:self,action:#selector(primaryPressed))
    // learned carries what the gesture now does, so the sheet can say it.
    enum State:Equatable{case listening(heard:Int,mixed:Bool,slow:Bool),learned(GestureAction),failed(String),unavailable(String)}
    private(set) var state=State.listening(heard:0,mixed:false,slow:false)

    init(gesture:CaseGesture) {
        self.gesture=gesture
        window=NSWindow(contentRect:NSRect(x:0,y:0,width:420,height:290),styleMask:[.titled],backing:.buffered,defer:false)
        super.init()
        window.title="Teach \(gesture.title)"
        let root=RemoteSurface(HomePalette.canvas)
        rkSetText(title,"Teach \(gesture.title)")
        rkSetText(body,"\(gesture.movement) Do it three times, with a short pause between. The pointer pauses while you teach it.")
        let buttons=rkHStack([rkSpacer(),cancel,primary],spacing:8)
        let stack=rkVStack([title,body,dots,note,buttons],spacing:12,align:.leading)
        stack.setCustomSpacing(20,after:body);stack.setCustomSpacing(20,after:dots);stack.setCustomSpacing(20,after:note)
        root.addSubview(stack);stack.translatesAutoresizingMaskIntoConstraints=false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo:root.topAnchor,constant:24),stack.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:24),
            stack.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-24),stack.bottomAnchor.constraint(lessThanOrEqualTo:root.bottomAnchor,constant:-20),
            dots.widthAnchor.constraint(equalTo:stack.widthAnchor),body.widthAnchor.constraint(equalTo:stack.widthAnchor),
            note.widthAnchor.constraint(equalTo:stack.widthAnchor),buttons.widthAnchor.constraint(equalTo:stack.widthAnchor),
        ])
        // Wrapping labels start zero wide and would measure one word a line, stretching the sheet; give them its width.
        body.preferredMaxLayoutWidth=372;note.preferredMaxLayoutWidth=372
        window.contentView=root
        let size=NSSize(width:420,height:290);window.setContentSize(size);window.contentMinSize=size;window.contentMaxSize=size
        render()
    }
    func update(_ next:State){state=next;render()}
    private func render() {
        primary.isEnabled=true;cancel.isHidden=false
        switch state {
        case .listening(let heard,let mixed,let slow):
            dots.heard=heard;primary.title="Listening…";primary.isEnabled=false
            rkSetText(note,slow ? "Flick faster: a quick snap of the wrist, then straight back.":mixed ? "Flick the same way each time.":"Hold the case upright, the way you point with it.")
        case .learned(let action):
            dots.heard=dots.count;primary.title="Done";cancel.isHidden=true
            rkSetText(note,action == .nothing ? "Learned. Now choose what \(gesture.title) does.":"Learned. \(gesture.title) now does \(action.title).")
        case .failed(let reason):
            dots.heard=0;primary.title="Try Again";rkSetText(note,reason)
        case .unavailable(let reason):
            dots.heard=0;primary.title="Done";cancel.isHidden=true;rkSetText(note,reason)
        }
        window.defaultButtonCell=primary.isEnabled ? primary.cell as? NSButtonCell:nil
    }
    @objc private func primaryPressed() {
        switch state {
        case .failed:update(.listening(heard:0,mixed:false,slow:false));onRetry?()
        default:onDone?()
        }
    }
    @objc private func cancelPressed(){onCancel?()}
}
