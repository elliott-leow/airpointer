import AppKit

// The closed-case steps between connecting and ready: shut the lid, turn the
// case upright while it settles, then point at the calibration dots.
enum ClosedCaseStep:Equatable {case openLid,closeLid,turnUpright,holdStill,calibrate,recenter}
enum HomeControlPhase:Equatable {case needsInputs,connecting,needsAccessibility,ready,running,paused(String),closedCase(ClosedCaseStep)}

extension NSScreen {
    // Stays the same across unplugging and reordering, unlike the place in NSScreen.screens.
    var displayID:String? {
        guard let number=deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid=CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else{return nil}
        return CFUUIDCreateString(nil,uuid) as String
    }
}

struct PointerSettingsState:Equatable {
    var screens:[String]=[]
    var screen=0
    // The display someone picked in Settings. While it's unplugged the pointer uses another, and this waits for it to return.
    var screenID:String?=nil
    // Paired AirPods Pro and AirPods 5 by name; -1 until one is chosen among several.
    var pairs:[String]=[]
    var pair=0
    var speed=1.0
    var clickSound=true
    // The way this person's taps push the sensor, when setup learned one other than the usual.
    var tapDirection:[Double]?=nil
    // What each gesture does when it isn't its standard (a tap clicks, the rest do nothing), and the flick
    // axes Settings taught.
    var gestureActions:[CaseGesture:GestureAction]=[:]
    var taughtFlicks:[FlickAxis:ClosedCaseFlick]=[:]

    // Slider legacy: 10…60 stored as pointerSensitivity; speed is that value / 25.
    private static let sensitivityKey="pointerSensitivity"
    private static let clickSoundKey="tapClickSound"
    private static let tapDirectionKey="tapDirection"
    private static let gestureActionsKey="gestureActions",taughtFlicksKey="taughtFlicks"
    private static let screenKey="pointerScreen"
    private static let screenIDKey="pointerScreenID"

    static func screenIndex(chosen:String?,current:Int,in displays:[String?])->Int {
        if let chosen,let found=displays.firstIndex(of:chosen){return found}
        return max(0,min(current,displays.count-1))
    }

    static func loadPersisted()->PointerSettingsState {
        var value=PointerSettingsState()
        if let saved=UserDefaults.standard.object(forKey:sensitivityKey) as? Double,saved.isFinite{
            value.speed=min(60,max(10,saved))/25
        }
        value.clickSound=UserDefaults.standard.object(forKey:clickSoundKey) as? Bool ?? true
        value.tapDirection=(UserDefaults.standard.array(forKey:tapDirectionKey) as? [Double]).flatMap{$0.count==3 ? $0:nil}
        let actions=UserDefaults.standard.dictionary(forKey:gestureActionsKey) ?? [:],flicks=UserDefaults.standard.dictionary(forKey:taughtFlicksKey) ?? [:]
        for gesture in CaseGesture.allCases {
            if let stored=actions[gesture.rawValue] as? [String:Any]{let action=GestureAction(stored:stored);if action != gesture.standard{value.gestureActions[gesture]=action}}
        }
        for axis in FlickAxis.allCases{if let flick=ClosedCaseFlick(stored:flicks[axis.rawValue] as? [Double]){value.taughtFlicks[axis]=flick}}
        if let saved=UserDefaults.standard.object(forKey:screenKey) as? Int{value.screen=max(0,saved)}
        value.screenID=UserDefaults.standard.string(forKey:screenIDKey)
        return value
    }

    mutating func clampSpeed(){speed=min(60,max(10,speed*25))/25}

    func persist(){
        UserDefaults.standard.set(min(60,max(10,speed*25)),forKey:Self.sensitivityKey)
        UserDefaults.standard.set(clickSound,forKey:Self.clickSoundKey)
        if let tapDirection{UserDefaults.standard.set(tapDirection,forKey:Self.tapDirectionKey)}else{UserDefaults.standard.removeObject(forKey:Self.tapDirectionKey)}
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues:gestureActions.filter{$0.value != $0.key.standard}.map{($0.key.rawValue,$0.value.stored)}),forKey:Self.gestureActionsKey)
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues:taughtFlicks.map{($0.key.rawValue,$0.value.stored)}),forKey:Self.taughtFlicksKey)
        UserDefaults.standard.set(screen,forKey:Self.screenKey)
        if let screenID{UserDefaults.standard.set(screenID,forKey:Self.screenIDKey)}else{UserDefaults.standard.removeObject(forKey:Self.screenIDKey)}
    }
}

func runPointerSettingsChecks()throws {
    let defaults=UserDefaults.standard
    let keys=["pointerSensitivity","tapClickSound","pointerScreen","pointerScreenID","tapDirection","gestureActions","taughtFlicks"]
    let prior=Dictionary(uniqueKeysWithValues:keys.map{($0,defaults.object(forKey:$0))})
    defer{for key in keys{if let value=prior[key]{defaults.set(value,forKey:key)}else{defaults.removeObject(forKey:key)}}}
    defaults.removeObject(forKey:"pointerSensitivity")
    defaults.removeObject(forKey:"tapClickSound")
    defaults.removeObject(forKey:"pointerScreen")
    defaults.removeObject(forKey:"pointerScreenID")
    defaults.removeObject(forKey:"tapDirection")
    defaults.removeObject(forKey:"gestureActions");defaults.removeObject(forKey:"taughtFlicks")
    let fresh=PointerSettingsState.loadPersisted()
    guard fresh.speed==1,fresh.clickSound,fresh.screen==0,fresh.screenID==nil,fresh.tapDirection==nil,fresh.gestureActions.isEmpty,fresh.taughtFlicks.isEmpty else{
        throw LessonError.message("Default pointer settings should be speed 1, click sound on, screen 0.")
    }
    var sample=PointerSettingsState(screen:1,screenID:"side",speed:1.4,clickSound:false,tapDirection:[0.6,0,-0.8])
    sample.gestureActions=[.flickUp:GestureAction.presets.first{$0.title=="Page Up"}!.action,.tap:.nothing,.doubleTap:.keys(GestureShortcut(key:40,modifiers:[.command,.shift],name:"K"))]
    sample.taughtFlicks=[.horizontal:ClosedCaseFlick(axis:SIMD3(0,1,0),peak:360)]
    sample.clampSpeed();sample.persist()
    let loaded=PointerSettingsState.loadPersisted()
    guard abs(loaded.speed-1.4)<1e-9,!loaded.clickSound,loaded.screen==1,loaded.screenID=="side",loaded.tapDirection==[0.6,0,-0.8],
          loaded.gestureActions==sample.gestureActions,loaded.taughtFlicks==sample.taughtFlicks else{
        throw LessonError.message("Pointer settings did not round-trip through UserDefaults.")
    }
    // The chosen display wherever it now sits; with it unplugged, a display that exists; with no choice, the same place.
    guard PointerSettingsState.screenIndex(chosen:"side",current:0,in:["main","other","side"])==2,
          PointerSettingsState.screenIndex(chosen:"side",current:2,in:["main","other"])==1,
          PointerSettingsState.screenIndex(chosen:"side",current:1,in:[nil,"other"])==1,
          PointerSettingsState.screenIndex(chosen:nil,current:1,in:["main","other"])==1,
          PointerSettingsState.screenIndex(chosen:"side",current:3,in:[])==0 else{
        throw LessonError.message("The chosen display wasn’t found after the displays changed.")
    }
}

// MARK: - Copy

private struct HomeControlKey:Equatable {let phase:HomeControlPhase;let inputs:Bool}

private func hmCommand(_ phase:HomeControlPhase)->(title:String,hint:String?) {
    switch phase {
    case .needsInputs:return ("Connect AirPods",nil)
    case .connecting:return ("Cancel","esc")
    case .needsAccessibility:return ("Allow",nil)
    case .ready:return ("Start Pointing",PointerShortcut.current.label)
    case .running:return ("Pause",PointerShortcut.current.label)
    case .paused:return ("Resume",PointerShortcut.current.label)
    case .closedCase(.openLid):return ("Cancel","esc")
    case .closedCase(.closeLid):return ("Lid Closed","Return")
    case .closedCase(.turnUpright),.closedCase(.holdStill):return ("Cancel","esc")
    case .closedCase(.calibrate):return ("Start Calibration",nil)
    case .closedCase(.recenter):return ("Recenter",nil)
    }
}
private func hmHero(_ phase:HomeControlPhase)->(String,String) {
    switch phase {
    case .needsInputs:return ("Connect your AirPods","Hold the closed case with both AirPods inside. Connect, then open the lid.")
    case .connecting:return ("Looking for your AirPods…","Keep the lid open for a moment.")
    case .needsAccessibility:return ("Allow control","Press Allow to open the Accessibility list, then drag AirPointer into it so it can move the pointer and click.")
    case .ready:return ("Ready to point","Hold the closed case upright and aim at the screen.")
    case .running:return ("Pointing","Aim with the case. Tap its front to click.")
    case .paused(let reason):return ("Paused",reason=="Paused" || reason.isEmpty ? "Resume when you’re ready.":reason)
    case .closedCase(.openLid):return ("Open the lid","AirPointer connects when you open it. Keep both AirPods inside.")
    case .closedCase(.closeLid):return ("Close the lid","Keep both AirPods inside. AirPointer goes on by itself, or press Return.")
    case .closedCase(.turnUpright):return ("Turn it upright","Give the closed case a quarter turn clockwise.")
    case .closedCase(.holdStill):return ("Set it down","Put the closed case on a flat surface for a moment.")
    case .closedCase(.calibrate):return ("Point at the dots","Aim at each dot on your screen and hold still. Esc cancels.")
    case .closedCase(.recenter):return ("Point at the center","Your edges are saved, so one dot is enough. Esc cancels.")
    }
}

// MARK: - Building blocks

// A vertical page column whose full-width rows track the column's width.
private final class PageColumn:NSStackView {
    init(spacing:CGFloat=12) {
        super.init(frame:.zero)
        orientation = .vertical;alignment = .leading;self.spacing=spacing
        translatesAutoresizingMaskIntoConstraints=false
    }
    required init?(coder:NSCoder){fatalError("init(coder:) is not used")}
    func addFull(_ view:NSView) {
        view.translatesAutoresizingMaskIntoConstraints=false
        addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo:widthAnchor).isActive=true
    }
    // The column pins leading edges, so centered rows sit in a full-width holder.
    func addCentered(_ view:NSView) {
        let holder=NSView();view.translatesAutoresizingMaskIntoConstraints=false;holder.addSubview(view)
        NSLayoutConstraint.activate([
            view.centerXAnchor.constraint(equalTo:holder.centerXAnchor),
            view.topAnchor.constraint(equalTo:holder.topAnchor),view.bottomAnchor.constraint(equalTo:holder.bottomAnchor),
            view.leadingAnchor.constraint(greaterThanOrEqualTo:holder.leadingAnchor),
        ])
        addFull(holder)
    }
    func gap(_ value:CGFloat){if let last=arrangedSubviews.last{setCustomSpacing(value,after:last)}}
    @discardableResult func addHeader(_ text:String)->NSTextField {
        gap(24)
        let label=hmEyebrow(text);addFull(label);setCustomSpacing(8,after:label)
        return label
    }
}
private func hmEyebrow(_ text:String)->NSTextField {
    let label=rkLabel(text,11,.semibold,.secondaryLabelColor)
    label.attributedStringValue=NSAttributedString(string:text.uppercased(),attributes:[.font:NSFont.systemFont(ofSize:11,weight:.semibold),.foregroundColor:NSColor.secondaryLabelColor,.kern:0.6])
    label.setAccessibilityLabel(text)
    return label
}
private func hmScrollPage(top:CGFloat=8)->(NSScrollView,PageColumn) {
    let scroll=NSScrollView();scroll.drawsBackground=false;scroll.hasVerticalScroller=true;scroll.autohidesScrollers=true
    scroll.borderType = .noBorder;scroll.scrollerStyle = .overlay;scroll.translatesAutoresizingMaskIntoConstraints=false
    let document=RemoteFlipped();document.translatesAutoresizingMaskIntoConstraints=false
    scroll.documentView=document
    let column=PageColumn();document.addSubview(column)
    let clip=scroll.contentView
    NSLayoutConstraint.activate([
        document.leadingAnchor.constraint(equalTo:clip.leadingAnchor),
        document.trailingAnchor.constraint(equalTo:clip.trailingAnchor),
        document.topAnchor.constraint(equalTo:clip.topAnchor),
        column.leadingAnchor.constraint(equalTo:document.leadingAnchor,constant:24),
        column.trailingAnchor.constraint(equalTo:document.trailingAnchor,constant:-24),
        column.topAnchor.constraint(equalTo:document.topAnchor,constant:top),
        column.bottomAnchor.constraint(equalTo:document.bottomAnchor,constant:-24),
    ])
    return (scroll,column)
}
private func hmRow(_ leading:[NSView],trailing:[NSView]=[],spacing:CGFloat=8)->NSStackView {
    let row=rkHStack(leading+[rkSpacer()]+trailing,spacing:spacing)
    return row
}
private func hmSettingRow(_ title:String,_ caption:String?,_ control:NSView)->NSStackView {
    hmSettingRow(title,detail:caption.map{rkWrap($0,12)},control)
}
private func hmSettingRow(_ title:String,detail:NSView?,_ control:NSView)->NSStackView {
    let text=rkVStack([rkLabel(title,13,.medium)],spacing:2)
    if let detail{text.addArrangedSubview(detail)}
    text.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
    control.setContentHuggingPriority(.required,for:.horizontal)
    let row=rkHStack([text,rkSpacer(),control],spacing:16)
    row.heightAnchor.constraint(greaterThanOrEqualToConstant:44).isActive=true
    return row
}

// A dismissible line at the top of the window for things that went wrong.
private final class NoticeBar:NSView {
    private let text=rkWrap("",12,.labelColor)
    private let icon=rkSymbolView("exclamationmark.circle",13,.secondaryLabelColor)
    private let close=NSButton()
    init() {
        super.init(frame:.zero);translatesAutoresizingMaskIntoConstraints=false
        close.image=rkSymbol("xmark",10,.semibold);close.isBordered=false;close.imagePosition = .imageOnly
        close.contentTintColor = .secondaryLabelColor;close.target=self;close.action=#selector(dismiss)
        close.setAccessibilityLabel("Dismiss")
        // The message takes the width left over, so the dismiss button sits at the trailing edge.
        text.setContentHuggingPriority(.init(1),for:.horizontal);close.setContentHuggingPriority(.required,for:.horizontal)
        let row=rkHStack([icon,text,close],spacing:10);row.alignment = .firstBaseline;row.distribution = .fill
        let surface=RemoteSurface(HomePalette.raised,radius:10)
        rkPin(surface,in:self,insets:NSEdgeInsets(top:4,left:16,bottom:8,right:16))
        rkPin(row,in:surface,insets:NSEdgeInsets(top:10,left:12,bottom:10,right:10))
        isHidden=true
    }
    required init?(coder:NSCoder){fatalError("init(coder:) is not used")}
    func set(_ value:String?) {
        let value=value?.trimmingCharacters(in:.whitespacesAndNewlines)
        isHidden=value?.isEmpty ?? true
        if let value,!value.isEmpty,text.stringValue != value {
            text.stringValue=value
            NSAccessibility.post(element:text,notification:.announcementRequested,userInfo:[.announcement:value,.priority:NSAccessibilityPriorityLevel.high.rawValue])
        }
    }
    @objc private func dismiss(){isHidden=true}
}

// MARK: - Window

private enum HomePage:Equatable {case pointer,settings}

// A key window where bare Esc goes to the page unless a field is being edited.
final class HomeWindow:NSWindow {
    var onEscape:(()->Void)?
    override func sendEvent(_ event:NSEvent) {
        if event.type == .keyDown,!event.isARepeat,
           event.modifierFlags.intersection([.command,.control,.option]).isEmpty {
            let editing=firstResponder is NSTextView || firstResponder is NSTextField
            if event.keyCode==53,!editing,let onEscape{onEscape();return}
        }
        super.sendEvent(event)
    }
}

final class AirPointerHome:NSObject,NSWindowDelegate {
    let window:HomeWindow
    var onControl:(()->Void)?
    var onRecenter:(()->Void)?
    var onLearnGrip:(()->Void)?
    var onDisconnect:(()->Void)?
    var onSetup:(()->Void)?
    var onTeachTap:(()->Void)?
    var onTeachGesture:((FlickAxis)->Void)?
    var onSettings:(()->Void)?
    var onPointerSettingsChange:((PointerSettingsState)->Void)?
    var onClose:(()->Void)?

    fileprivate var phase=HomeControlPhase.needsInputs
    fileprivate var inputsReady=false
    fileprivate var pointerSettings=PointerSettingsState()

    let pad:AimPadView
    private let pageHost=NSView()
    private let notice=NoticeBar()
    private lazy var pointerPage=PointerPage(home:self)
    private lazy var settingsPage=SettingsPage(home:self)
    fileprivate private(set) var page=HomePage.pointer
    private var controlKey:HomeControlKey?

    init(pad:AimPadView=AimPadView()) {
        self.pad=pad;pad.setAccessibilityElement(true);pad.setAccessibilityRole(.image)
        window=HomeWindow(contentRect:NSRect(x:0,y:0,width:440,height:700),styleMask:[.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
        super.init()
        window.title="AirPointer";window.titleVisibility = .hidden
        window.isReleasedWhenClosed=false;window.delegate=self
        window.titlebarAppearsTransparent=true;window.titlebarSeparatorStyle = .none
        window.backgroundColor=HomePalette.canvas
        window.contentMinSize=NSSize(width:400,height:620);window.contentMaxSize=NSSize(width:560,height:4000)
        let toolbar=NSToolbar(identifier:"AirPointerRemote")
        toolbar.delegate=self;toolbar.displayMode = .iconOnly;toolbar.allowsUserCustomization=false
        if #available(macOS 15,*){toolbar.allowsDisplayModeCustomization=false}
        window.toolbar=toolbar;window.toolbarStyle = .unified
        let root=RemoteSurface(HomePalette.canvas)
        let stack=rkVStack([notice,pageHost],spacing:0,align:.leading)
        pageHost.translatesAutoresizingMaskIntoConstraints=false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo:root.safeAreaLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo:root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo:root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo:root.bottomAnchor),
            notice.widthAnchor.constraint(equalTo:stack.widthAnchor),
            pageHost.widthAnchor.constraint(equalTo:stack.widthAnchor),
        ])
        window.contentView=root
        window.setContentSize(NSSize(width:440,height:700))
        window.center()
        window.onEscape={[weak self] in self?.handleEscape()}
        present(.pointer)
    }

    // MARK: Public API

    func show() {
        if window.isMiniaturized{window.deminiaturize(nil)}
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps:true)
    }

    // Called about 12 times a second: returns early unless something visible changed.
    func updateControl(phase:HomeControlPhase,inputsReady:Bool) {
        let key=HomeControlKey(phase:phase,inputs:inputsReady)
        guard key != controlKey else{return}
        let announce=controlKey != nil && phase != self.phase
        controlKey=key
        self.phase=phase;self.inputsReady=inputsReady
        pointerPage.render()
        if announce{NSAccessibility.post(element:window,notification:.announcementRequested,userInfo:[.announcement:hmHero(phase).0,.priority:NSAccessibilityPriorityLevel.high.rawValue])}
    }

    func updateHold(_ progress:CGFloat?){pointerPage.updateHold(progress)}
    func setNotice(_ text:String?){notice.set(text)}
    func selectPointer(){present(.pointer)}
    func selectSettings() {
        guard page != .settings else{return}
        present(.settings)
        NSAccessibility.post(element:window,notification:.announcementRequested,userInfo:[.announcement:"Settings",.priority:NSAccessibilityPriorityLevel.medium.rawValue])
    }
    func updatePointerSettings(_ value:PointerSettingsState) {
        guard value != pointerSettings else{return}
        pointerSettings=value;settingsPage.apply();pointerPage.render()
    }

    // MARK: Shared with pages

    fileprivate func changePointerSettings(_ value:PointerSettingsState) {
        pointerSettings=value;settingsPage.apply();pointerPage.render();onPointerSettingsChange?(value)
    }

    fileprivate func present(_ next:HomePage) {
        if next != page {
            if let responder=window.firstResponder as? NSView,responder.isDescendant(of:pageHost){_ = window.makeFirstResponder(nil)}
        }
        page=next
        let view:NSView
        switch next {
        case .pointer:pointerPage.render();view=pointerPage.view
        case .settings:settingsPage.apply();view=settingsPage.view
        }
        guard pageHost.subviews.first !== view else{return}
        pageHost.subviews.forEach{$0.removeFromSuperview()}
        rkPin(view,in:pageHost)
    }

    // MARK: Actions and keys

    @objc fileprivate func openSettings(){onSettings?()}

    private func handleEscape() {
        switch phase {
        case .running,.connecting,.closedCase(.openLid),.closedCase(.turnUpright),.closedCase(.holdStill):onControl?();return
        default:break
        }
        if page == .settings{present(.pointer)}
    }

    func windowWillClose(_ notification:Notification) {
        onClose?()
    }
}

private extension NSToolbarItem.Identifier {
    static let homeSettings=NSToolbarItem.Identifier("AirPointerSettings")
}

extension AirPointerHome:NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar:NSToolbar)->[NSToolbarItem.Identifier]{[.flexibleSpace,.homeSettings]}
    func toolbarAllowedItemIdentifiers(_ toolbar:NSToolbar)->[NSToolbarItem.Identifier]{toolbarDefaultItemIdentifiers(toolbar)}
    func toolbar(_ toolbar:NSToolbar,itemForItemIdentifier identifier:NSToolbarItem.Identifier,willBeInsertedIntoToolbar flag:Bool)->NSToolbarItem? {
        let item=NSToolbarItem(itemIdentifier:identifier)
        if identifier == .homeSettings {
            item.image=rkSymbol("gearshape",15);item.label="Settings";item.toolTip="Settings (⌘,)"
            item.isBordered=true;item.target=self;item.action=#selector(openSettings)
        } else{return nil}
        return item
    }
}

// MARK: - Pointer

private final class PointerPage:NSObject {
    unowned let home:AirPointerHome
    let view:NSScrollView
    private let stage=RemoteSurface(HomePalette.stage,radius:18)
    private let art=CaseStepView()
    private let chip=StatusChip()
    private let title=rkTitle("",26,align:.center)
    private let subtitle=rkWrap("",13,align:.center)
    private let primary=RemoteButton("Start Pointing",height:48)
    private let recenter=RemoteButton("Recenter",style:.tertiary,symbol:"scope",height:32)
    private let recalibrate=RemoteButton("Recalibrate…",style:.tertiary,symbol:"dot.viewfinder",height:32)
    private let disconnect=RemoteButton("Disconnect",style:.tertiary,symbol:"xmark.circle",height:32)
    private let secondary=NSStackView()
    private var showingPad:Bool?

    init(home:AirPointerHome) {
        self.home=home
        let page=hmScrollPage(top:4);view=page.0
        super.init()
        let column=page.1
        stage.translatesAutoresizingMaskIntoConstraints=false
        stage.heightAnchor.constraint(equalToConstant:228).isActive=true
        art.fill=0.86
        for view in [art,home.pad] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints=false;stage.addSubview(view)
        }
        NSLayoutConstraint.activate([
            art.topAnchor.constraint(equalTo:stage.topAnchor,constant:8),art.bottomAnchor.constraint(equalTo:stage.bottomAnchor,constant:-8),
            art.leadingAnchor.constraint(equalTo:stage.leadingAnchor),art.trailingAnchor.constraint(equalTo:stage.trailingAnchor),
            home.pad.centerXAnchor.constraint(equalTo:stage.centerXAnchor),home.pad.centerYAnchor.constraint(equalTo:stage.centerYAnchor),
            home.pad.heightAnchor.constraint(equalTo:stage.heightAnchor,constant:-32),
            home.pad.widthAnchor.constraint(equalTo:home.pad.heightAnchor,multiplier:1.6),
        ])
        column.addFull(stage);column.gap(18)
        column.addCentered(chip);column.gap(12)
        column.addFull(title);column.gap(6)
        column.addFull(subtitle);column.gap(22)
        primary.target=self;primary.action=#selector(primaryPressed)
        column.addFull(primary);column.gap(8)
        recenter.target=self;recenter.action=#selector(recenterPressed)
        recalibrate.target=self;recalibrate.action=#selector(recalibratePressed)
        disconnect.target=self;disconnect.action=#selector(disconnectPressed)
        recenter.toolTip="Recenter on where you’re aiming";recalibrate.toolTip="Point at three dots so AirPointer knows where your screen is"
        disconnect.toolTip="End the connection. To reconnect, connect again and open the lid."
        secondary.orientation = .horizontal;secondary.spacing=4
        secondary.addArrangedSubview(recenter);secondary.addArrangedSubview(recalibrate);secondary.addArrangedSubview(disconnect)
        column.addCentered(secondary)
        render()
    }

    func render() {
        let phase=home.phase
        let hero=hmHero(phase),command=hmCommand(phase)
        rkSetText(title,hero.0);rkSetText(subtitle,hero.1)
        if primary.title != command.title{primary.title=command.title}
        if primary.hint != command.hint{primary.hint=command.hint}
        // The hint names the key: Return confirms the closed lid, esc cancels.
        let key=command.hint=="Return" ? "\r":command.hint=="esc" ? "\u{1b}":""
        if primary.keyEquivalent != key{primary.keyEquivalent=key}
        // Until the closed case is upright and held, the stage shows the step to do with it.
        let connected:Bool
        switch phase {
        // Closed before Connect and while asking for Accessibility, the lid opening while Connect waits, then the open case.
        case .needsInputs:connected=false;art.step = .closed
        case .closedCase(.openLid):connected=false;art.step = .opening
        case .connecting:connected=false;art.step = .open
        case .closedCase(.closeLid):connected=false;art.step = .close
        case .closedCase(.turnUpright):connected=false;art.step = .turn
        case .closedCase(.holdStill):connected=false;art.step = .closed
        case .needsAccessibility:connected=home.inputsReady;art.step = .closed
        default:connected=true
        }
        let live:Bool
        switch phase {
        case .needsInputs:chip.set("Not connected",dot:false);live=false
        case .connecting:chip.set("Connecting…",dot:false);live=false
        case .closedCase(.openLid):chip.set("Waiting for the lid",dot:false);live=false
        case .needsAccessibility:chip.set(connected ? "Connected":"Not connected",dot:connected);live=false
        case .ready:chip.set("Connected");live=false
        case .running:chip.set("Pointing",live:true);live=true
        case .paused:chip.set("Paused");live=false
        case .closedCase(.closeLid):chip.set("Connected");live=false
        case .closedCase(.turnUpright):chip.set("Connected");live=false
        case .closedCase(.holdStill):chip.set("Keep it still",dot:false);live=false
        case .closedCase(.calibrate):chip.set("Calibrating",dot:false);live=false
        case .closedCase(.recenter):chip.set("Recentering",dot:false);live=false
        }
        if showingPad != connected {
            showingPad=connected
            home.pad.isHidden = !connected;art.isHidden=connected
        }
        home.pad.live=live;home.pad.setAccessibilityLabel(live ? "Pointer preview, live":"Pointer preview")
        let screens=home.pointerSettings.screens
        home.pad.caption=screens.indices.contains(home.pointerSettings.screen) && screens.count>1 ? screens[home.pointerSettings.screen]:""
        // Centered rows live in holders; hiding the holder collapses the row.
        // The closed case stays connected through Pause until Disconnect.
        switch phase {
        case .running,.paused:recenter.isHidden=false;recalibrate.isHidden=false;disconnect.isHidden=false;secondary.superview?.isHidden=false
        case .ready:recenter.isHidden=true;recalibrate.isHidden=false;disconnect.isHidden=false;secondary.superview?.isHidden=false
        case .closedCase(.calibrate):recenter.isHidden=true;recalibrate.isHidden=true;disconnect.isHidden=false;secondary.superview?.isHidden=false
        // Saved edges might not suit a new grip, so all three dots stay one click away.
        case .closedCase(.recenter):recenter.isHidden=true;recalibrate.isHidden=false;disconnect.isHidden=false;secondary.superview?.isHidden=false
        default:secondary.superview?.isHidden=true
        }
    }

    func updateHold(_ progress:CGFloat?){art.holdProgress=progress}
    @objc private func primaryPressed(){home.onControl?()}
    @objc private func recenterPressed(){home.onRecenter?()}
    @objc private func recalibratePressed(){home.onLearnGrip?()}
    @objc private func disconnectPressed(){home.onDisconnect?()}
}

// MARK: - Settings

private final class SettingsPage:NSObject {
    unowned let home:AirPointerHome
    let view:NSScrollView
    private let screens=NSPopUpButton()
    private let pairs=NSPopUpButton()
    private let speed=NSSlider(value:1,minValue:0.4,maxValue:2.4,target:nil,action:nil)
    private let clickSound=InkSwitch()
    private let shortcutControl=PointerShortcutControl()
    private let speedValue=rkLabel("1.0×",13,.medium)
    private var gestureControls:[CaseGesture:GestureActionControl]=[:]
    private static let gestureCaptions:[CaseGesture:String]=[
        .tap:"Tap the front of the case.",
        .doubleTap:"Tap the front twice. While this does something, a single tap waits a moment to be sure.",
        .flickUp:"Flick the case up and back, fast and big.",.flickDown:"Flick the case down and back, fast and big.",
        .flickLeft:"Flick the case left and back, fast and big.",.flickRight:"Flick the case right and back, fast and big.",
    ]
    // Teaching follows each pair of flicks.
    private static let teachRows:[CaseGesture:FlickAxis]=[.flickDown:.vertical,.flickRight:.horizontal]

    init(home:AirPointerHome) {
        self.home=home
        let page=hmScrollPage(top:2);view=page.0
        super.init()
        let column=page.1
        // With no section tabs, this is the way back besides esc and ⌘1.
        let back=RemoteButton("Pointer",style:.tertiary,symbol:"chevron.left",height:28,target:self,action:#selector(backPressed))
        back.setAccessibilityLabel("Back to Pointer")
        column.addFull(hmRow([back]));column.gap(4)
        column.addFull(rkLabel("Settings",22,.bold))
        column.addHeader("AirPods")
        pairs.target=self;pairs.action=#selector(changed(_:));pairs.setAccessibilityLabel("AirPods to connect to")
        column.addFull(hmSettingRow("Connect to",nil,pairs))
        column.addHeader("Screen")
        screens.target=self;screens.action=#selector(changed(_:));screens.setAccessibilityLabel("Screen to control")
        column.addFull(hmSettingRow("Point at",nil,screens))
        column.addHeader("Pointer speed")
        speed.target=self;speed.action=#selector(changed(_:));speed.isContinuous=true;speed.setAccessibilityLabel("Pointer speed")
        speedValue.font = .monospacedDigitSystemFont(ofSize:13,weight:.medium)
        speedValue.setContentHuggingPriority(.required,for:.horizontal)
        let ends=hmRow([rkLabel("Slower",12,.regular,.secondaryLabelColor)],trailing:[rkLabel("Faster",12,.regular,.secondaryLabelColor)])
        let track=rkVStack([speed,ends],spacing:2,align:.leading)
        ends.widthAnchor.constraint(equalTo:speed.widthAnchor).isActive=true
        speed.widthAnchor.constraint(equalTo:track.widthAnchor).isActive=true
        track.setHuggingPriority(.init(1),for:.horizontal)
        let slider=rkHStack([track,speedValue],spacing:14);slider.alignment = .top
        column.addFull(slider)
        column.addHeader("Tap to click")
        clickSound.setAccessibilityLabel("Click sound");clickSound.onChange={[weak self] _ in self?.changed(nil)}
        column.addFull(hmSettingRow("Click sound","Plays on this Mac when a tap on the case clicks.",clickSound))
        let teachTap=RemoteButton("Teach Tap…",style:.secondary,height:32,target:self,action:#selector(teachTap))
        column.addFull(hmSettingRow("Your tap","Tap the case three times so AirPointer knows how your taps feel.",teachTap))
        column.addHeader("Gestures")
        for gesture in CaseGesture.allCases {
            let control=GestureActionControl(gesture:gesture),caption=Self.gestureCaptions[gesture] ?? "",note=rkWrap(caption,12)
            control.onChange={[weak self] _ in self?.changed(nil)}
            control.onNote={text in rkSetText(note,text ?? caption)}
            control.others={[weak self] in (self?.gestureControls ?? [:]).filter{$0.key != gesture}.compactMap{$0.value.action.shortcut}}
            gestureControls[gesture]=control
            // The movement in a line, with Teach under it; what it does on the right, like every setting.
            let detail=rkVStack([note],spacing:8,align:.leading)
            if let axis=Self.teachRows[gesture] {
                let teach=RemoteButton("Teach \(axis.title)…",style:.secondary,height:28,target:self,action:#selector(teachGesture(_:)))
                teach.identifier=NSUserInterfaceItemIdentifier(axis.rawValue)
                detail.addArrangedSubview(teach)
            }
            let row=hmSettingRow(gesture.title,detail:detail,control)
            // The caption spans the text column, so it wraps to the width it's drawn at.
            if let text=row.arrangedSubviews.first{detail.widthAnchor.constraint(equalTo:text.widthAnchor).isActive=true}
            note.widthAnchor.constraint(equalTo:detail.widthAnchor).isActive=true
            column.addFull(row)
        }
        column.addHeader("Calibration")
        let recalibrate=RemoteButton("Recalibrate…",style:.secondary,height:32,target:self,action:#selector(recalibrate))
        column.addFull(hmSettingRow("Your screen","Point at three dots so AirPointer knows where your screen is.",recalibrate))
        column.addHeader("Shortcut")
        column.addFull(hmSettingRow("Turn the pointer on or off",detail:shortcutControl.note,shortcutControl))
        column.addFull(RemoteRule())
        let setup=RemoteButton("Run Setup Again…",style:.secondary,height:32,target:self,action:#selector(setup))
        column.addFull(hmSettingRow("Setup","Walk through connecting, permissions and calibration again.",setup))
        apply()
    }

    func apply() {
        let state=home.pointerSettings
        if screens.itemTitles != state.screens{screens.removeAllItems();screens.addItems(withTitles:state.screens)}
        if screens.itemArray.indices.contains(state.screen){screens.selectItem(at:state.screen)}
        screens.isEnabled=state.screens.count>1
        let pairTitles=state.pairs.isEmpty ? ["No supported AirPods found"]:state.pair<0 ? ["Choose your AirPods"]+state.pairs:state.pairs
        if pairs.itemTitles != pairTitles{pairs.removeAllItems();pairs.addItems(withTitles:pairTitles)}
        pairs.selectItem(at:max(0,state.pair));pairs.isEnabled=state.pairs.count>1
        speed.doubleValue=state.speed
        rkSetText(speedValue,String(format:"%.1f×",state.speed))
        speed.setAccessibilityValueDescription(String(format:"%.1f times normal speed",state.speed))
        clickSound.setOn(state.clickSound,animated:false)
        for (gesture,control) in gestureControls{control.set(state.gestureActions[gesture] ?? gesture.standard)}
    }
    @objc private func changed(_ sender:Any?) {
        var value=home.pointerSettings
        value.screen=max(0,screens.indexOfSelectedItem);value.speed=(speed.doubleValue*10).rounded()/10;value.clickSound=clickSound.isOn
        if !value.pairs.isEmpty{value.pair=pairs.indexOfSelectedItem-(value.pair<0 ? 1:0)}
        for (gesture,control) in gestureControls{value.gestureActions[gesture]=control.action == gesture.standard ? nil:control.action}
        home.changePointerSettings(value)
    }
    @objc private func backPressed(){home.present(.pointer)}
    @objc private func recalibrate(){home.onLearnGrip?()}
    @objc private func setup(){home.onSetup?()}
    @objc private func teachTap(){home.onTeachTap?()}
    @objc private func teachGesture(_ sender:NSButton){
        if let raw=sender.identifier?.rawValue,let axis=FlickAxis(rawValue:raw){home.onTeachGesture?(axis)}
    }
}
