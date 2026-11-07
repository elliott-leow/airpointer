import AppKit
import Carbon

// What the closed case can do besides point, each mapped in Settings ▸ Gestures: a tap (a click unless mapped
// to something else), a double tap, and fast, big flicks up, down, left and right. All but the tap do nothing
// until given an action.
enum CaseGesture:String,CaseIterable {
    case tap,doubleTap,flickUp,flickDown,flickLeft,flickRight
    var title:String {
        switch self {
        case .tap:return "Tap";case .doubleTap:return "Double tap"
        case .flickUp:return "Flick up";case .flickDown:return "Flick down";case .flickLeft:return "Flick left";case .flickRight:return "Flick right"
        }
    }
    var symbol:String {
        switch self {
        case .tap,.doubleTap:return "hand.tap"
        case .flickUp:return "arrow.up";case .flickDown:return "arrow.down";case .flickLeft:return "arrow.left";case .flickRight:return "arrow.right"
        }
    }
    // What it does with nothing chosen: a tap clicks, the rest do nothing.
    var standard:GestureAction{self == .tap ? .click:.nothing}
    static let flicks:[CaseGesture]=[.flickUp,.flickDown,.flickLeft,.flickRight]
    var axis:FlickAxis?{switch self{case .flickUp,.flickDown:return .vertical;case .flickLeft,.flickRight:return .horizontal;default:return nil}}
}

// The two axes flicks swing about, each taught on its own. The raw values are what Settings saved when these
// were the Yes nod and No shake, so what was taught then still counts.
enum FlickAxis:String,CaseIterable {
    case vertical="yes",horizontal="no"
    var title:String{self == .vertical ? "Up and Down":"Left and Right"}
    var movement:String {
        self == .vertical ? "Flick the case up and back, or down and back, fast and big."
            :"Flick the case left and back, or right and back, fast and big."
    }
    var other:FlickAxis{self == .vertical ? .horizontal:.vertical}
}

// One taught gesture: the axis the case swings about, in the case's own frame, and how fast its faster
// swing has to be (°/s), kept between 300 and 340. Aiming never comes near 300°/s, so a higher bar adds no
// safety and only misses everyday flicks, which are far gentler than eager taught ones (those reach
// 1100°/s, everyday ones 370°/s). Teaching can lower the bar for a gentle hand, never raise it; bars saved
// higher come back capped. The struct keeps the name it had when gestures were single flicks.
struct ClosedCaseFlick:Equatable {
    var axis:SIMD3<Double>,peak:Double
    var stored:[Double]{[axis.x,axis.y,axis.z,peak]}
    init(axis:SIMD3<Double>,peak:Double) {
        let n=(axis*axis).sum().squareRoot();self.axis=n>0 ? axis/n:axis
        self.peak=min(ClosedCaseFlickDetector.highestPeak,max(ClosedCaseFlickDetector.lowestPeak,peak))
    }
    init?(stored:[Double]?) {
        guard let stored,stored.count==4,stored.allSatisfy(\.isFinite),stored[3]>0 else{return nil}
        let axis=SIMD3(stored[0],stored[1],stored[2]);guard (axis*axis).sum()>0.25 else{return nil}
        self.init(axis:axis,peak:stored[3])
    }
}

// A flick is a fast, big swing and its return about the vertical or horizontal axis, once or several times (a
// nod or a shake). Its direction is the first swing's: the session reads it against the calibrated up and
// right. Each swing is measured along the axis. A pair of swings, one way then back, counts when the faster is fast
// (340°/s untaught, or 70% of the person's own), the slower is at least 35% of it, both turn 15° or more and
// one 30° or more, each lasts 50-600 ms, neither wanders off its axis, and the case was steady before the
// first. The pair's own axis then has to match this gesture's clearly better than the other's, and only one
// gesture counts until the case settles again. Aiming never swings that fast and that far back and forth:
// over 56 s of recorded pointing and the recorded taps, nothing counts about any of 200 random axis pairs,
// while the recorded natural nod and shake (Tests/GestureFixtures.csv) each count once.
struct ClosedCaseFlickDetector {
    // `turn` is the first swing's rotation, to tell up from down and left from right.
    enum Event:Equatable{case flick(FlickAxis,turn:SIMD3<Double>,since:Double)}
    // Rotation rates in degrees per second, angles in degrees, times in seconds.
    // Tuned on real use: everyday flicks go out at 370–870°/s and come back at 20–45% of that, often
    // starting while the hand still moves at up to 100°/s from the last one.
    static let defaultPeak=340.0,lowestPeak=300.0,highestPeak=340.0,onset=40.0,calm=100.0,slowerShare=0.2
    static let shortestSwing=0.05,longestSwing=0.6,smallestSwing=15.0,largeSwing=30.0,offAxisShare=0.65
    static let alignment=0.7,margin=0.08,settle=0.2,settleBelow=80.0,fade=0.15,maximumGap=0.1
    var flicks:[FlickAxis:ClosedCaseFlick]=[:]
    struct Swing{var sign:Double,start:Double,end=0.0,peak:Double,angle=0.0,turn=SIMD3<Double>.zero,off:Double,quietSince:Double?=nil}
    private struct Track{var swing:Swing?,previous:Swing?,steady=false}
    private var tracks:[FlickAxis:Track]=[:],recent:[(t:Double,w:SIMD3<Double>)]=[],last:Double?
    private var settling=false,quietSince:Double?

    mutating func reset(){tracks=[:];recent=[];last=nil;settling=false;quietSince=nil}
    private static func length(_ v:SIMD3<Double>)->Double{(v*v).sum().squareRoot()}
    // Whether a pair of swings is fast, big and clean enough to be a gesture with this speed bar.
    static func qualifies(_ first:Swing,_ second:Swing,secondLasted:Double,bar:Double)->Bool {
        let faster=max(first.peak,second.peak),slower=min(first.peak,second.peak)
        return faster>=bar && slower>=slowerShare*faster && (shortestSwing...longestSwing).contains(first.end-first.start) &&
            secondLasted>=shortestSwing && min(first.angle,second.angle)>=smallestSwing && max(first.angle,second.angle)>=largeSwing &&
            first.off<=offAxisShare*first.peak && second.off<=offAxisShare*second.peak
    }
    // `w` has the gyro's resting offset taken out; `stamp` is the sensor's microseconds.
    mutating func feed(stamp:Double,w:SIMD3<Double>)->[Event] {
        let t=stamp*1e-6,speed=Self.length(w)
        guard t.isFinite,w.x.isFinite,w.y.isFinite,w.z.isFinite else{return []}
        if let last,t<=last{return []}
        let dt=last.map{t-$0} ?? 0
        if dt>Self.maximumGap{tracks=[:]}
        last=t
        defer{recent.append((t,w));while let first=recent.first,t-first.t>0.3{recent.removeFirst()}}
        if speed<Self.settleBelow{quietSince=quietSince ?? t}else{quietSince=nil}
        if settling {
            guard let quietSince,t-quietSince>=Self.settle else{return []}
            settling=false;tracks=[:]
        }
        for gesture in FlickAxis.allCases {
            guard let flick=flicks[gesture] else{continue}
            var k=tracks[gesture] ?? Track()
            let s=(w*flick.axis).sum(),off=Self.length(w-flick.axis*s)
            guard var swing=k.swing else{
                if abs(s)>=Self.onset {
                    let before=recent.filter{$0.t>=t-0.25 && $0.t<=t-0.05}.map{Self.length($0.w)}
                    k.steady=(before.max() ?? .infinity)<=Self.calm
                    k.swing=Swing(sign:s>0 ? 1:-1,start:t,peak:abs(s),off:off);k.previous=nil
                }
                tracks[gesture]=k;continue
            }
            if swing.sign*s <= -Self.onset {
                swing.end=t;k.previous=swing
                swing=Swing(sign:-swing.sign,start:t,peak:abs(s),off:off)
            } else if abs(s)<Self.onset {
                swing.quietSince=swing.quietSince ?? t
                if t-(swing.quietSince ?? t)>Self.fade{tracks[gesture]=Track();continue}
            } else{swing.quietSince=nil}
            if swing.sign*s>0{swing.peak=max(swing.peak,abs(s));swing.angle+=abs(s)*dt;swing.turn+=w*dt;swing.off=max(swing.off,off)}
            k.swing=swing;tracks[gesture]=k
            guard k.steady,let previous=k.previous,Self.qualifies(previous,swing,secondLasted:t-swing.start,bar:flick.peak) else{continue}
            // The pair's own axis decides between Yes and No.
            let pair=previous.turn-swing.turn,n=Self.length(pair)
            guard n>0 else{continue}
            let scores=flicks.map{(gesture:$0.key,fit:abs(($0.value.axis*pair).sum())/n)}.sorted{$0.fit>$1.fit}
            guard scores[0].gesture==gesture,scores[0].fit>=Self.alignment,scores[0].fit-(scores.count>1 ? scores[1].fit:0)>=Self.margin else{continue}
            settling=true;quietSince=nil;tracks=[:]
            return [.flick(gesture,turn:previous.turn,since:previous.start)]
        }
        return []
    }
}

// Which flick a detected one is: up or down along the calibrated up, left or right along the calibrated right.
func closedCaseFlickGesture(_ axis:FlickAxis,turn:SIMD3<Double>,up:SIMD3<Double>?,right:SIMD3<Double>?)->CaseGesture? {
    let reference=axis == .vertical ? up:right
    guard let reference else{return nil}
    let along=(turn*reference).sum()
    guard along != 0 else{return nil}
    return axis == .vertical ? (along>0 ? .flickUp:.flickDown):(along>0 ? .flickRight:.flickLeft)
}

// Learns a gesture from three of its swing pairs that agree, without knowing its axis first. A burst runs
// from a steady moment until the case settles; its axis is the one it turned about most; every pair of swings
// along that axis that is fast and big (judged with a bar of 250°/s) is one example, so a natural "yes, yes,
// yes" teaches it at once, and nods with pauses between do too. The dots fill while the person nods. Nods
// up-first or down-first are one axis. The speed then needed is 70% of the typical faster swing, kept
// between 300 and 340°/s. A burst that swings clearly but too gently says so.
struct ClosedCaseFlickLearner {
    enum Event:Equatable{case flick(agreeing:Int,total:Int),tooSlow,learned(ClosedCaseFlick),failed}
    static let flicks=3,mostFlicks=10,agree=0.85,learningBar=250.0,peakShare=0.7,longestBurst=4.0,checkEvery=0.15
    private typealias Detector=ClosedCaseFlickDetector
    struct Example{var axis:SIMD3<Double>,peak:Double}
    private var burst:[(t:Double,w:SIMD3<Double>)]=[],recent:[(t:Double,w:SIMD3<Double>)]=[],last:Double?,quietSince:Double?,steady=false
    private var examples:[Example]=[],live:[Example]=[],heard=0,checkedAt=0.0,done=false

    private static func length(_ v:SIMD3<Double>)->Double{(v*v).sum().squareRoot()}
    mutating func feed(stamp:Double,w:SIMD3<Double>)->[Event] {
        let t=stamp*1e-6,speed=Self.length(w)
        guard !done,t.isFinite,w.x.isFinite,w.y.isFinite,w.z.isFinite else{return []}
        if let last,t<=last{return []}
        last=t
        defer{recent.append((t,w));while let first=recent.first,t-first.t>0.3{recent.removeFirst()}}
        if speed>=Detector.onset {
            quietSince=nil
            if burst.isEmpty{steady=(recent.filter{$0.t>=t-0.25 && $0.t<=t-0.05}.map{Self.length($0.w)}.max() ?? .infinity)<=Detector.calm;checkedAt=t}
            burst.append((t,w))
            if let first=burst.first,t-first.t>Self.longestBurst{return finishBurst()}
            // While the burst goes on, every so often: the pairs so far, so the dots fill as the person nods.
            if t-checkedAt>=Self.checkEvery{checkedAt=t;return update()}
            return []
        }
        guard !burst.isEmpty else{return []}
        burst.append((t,w));quietSince=quietSince ?? t
        return t-(quietSince ?? t)>=Detector.settle ? finishBurst():[]
    }
    // The axis a burst turned about most: the largest eigenvector of the sum of w·wᵀ.
    static func principalAxis(_ samples:[SIMD3<Double>])->SIMD3<Double>? {
        var m=[SIMD3<Double>](repeating:.zero,count:3)
        for w in samples{m[0]+=w*w.x;m[1]+=w*w.y;m[2]+=w*w.z}
        var v=SIMD3(1.0,0.7,0.3)
        for _ in 0..<60 {
            let next=SIMD3((m[0]*v).sum(),(m[1]*v).sum(),(m[2]*v).sum()),n=length(next)
            guard n>0 else{return nil}
            v=next/n
        }
        return v
    }
    // Every fast, big pair of swings along `axis`, one after another without sharing a swing.
    static func pairs(_ samples:[(t:Double,w:SIMD3<Double>)],axis:SIMD3<Double>,bar:Double)->[Example] {
        typealias Swing=ClosedCaseFlickDetector.Swing
        var swings:[Swing]=[],current:Swing?,last:Double?
        for (t,w) in samples {
            let dt=last.map{t-$0} ?? 0;last=t
            let s=(w*axis).sum(),off=length(w-axis*s)
            if var swing=current {
                if swing.sign*s <= -Detector.onset{swing.end=t;swings.append(swing);current=Swing(sign:-swing.sign,start:t,peak:abs(s),off:off);continue}
                if swing.sign*s>0{swing.peak=max(swing.peak,abs(s));swing.angle+=abs(s)*dt;swing.turn+=w*dt;swing.off=max(swing.off,off)}
                current=swing
            } else if abs(s)>=Detector.onset{current=Swing(sign:s>0 ? 1:-1,start:t,peak:abs(s),off:off)}
        }
        if var swing=current{swing.end=last ?? swing.start;swings.append(swing)}
        var found:[Example]=[],index=0
        while index+1<swings.count {
            let first=swings[index],second=swings[index+1]
            if Detector.qualifies(first,second,secondLasted:second.end-second.start,bar:bar) {
                let turn=first.turn-second.turn,n=length(turn)
                if n>0{found.append(Example(axis:turn/n,peak:max(first.peak,second.peak)))}
                index+=2
            } else{index+=1}
        }
        return found
    }
    // The examples that share an axis (either way round) with the best-supported one.
    static func agreeing(_ examples:[Example])->[Example] {
        let axes=examples.map(\.axis)
        guard let seed=axes.max(by:{a,b in axes.filter{abs(($0*a).sum())>=agree}.count<axes.filter{abs(($0*b).sum())>=agree}.count}) else{return []}
        return examples.filter{abs(($0.axis*seed).sum())>=agree}.map{(($0.axis*seed).sum()<0) ? Example(axis:-$0.axis,peak:$0.peak):$0}
    }
    private mutating func update()->[Event] {
        live=steady ? Self.principalAxis(burst.map(\.w)).map{Self.pairs(burst,axis:$0,bar:Self.learningBar)} ?? []:[]
        let all=examples+live,members=Self.agreeing(all)
        var events:[Event]=[]
        if members.count>heard{heard=members.count;events.append(.flick(agreeing:members.count,total:all.count))}
        if members.count>=Self.flicks {
            let peaks=members.map(\.peak).sorted(),typical=peaks[peaks.count/2],sum=members.reduce(SIMD3<Double>.zero){$0+$1.axis}
            done=true;events.append(.learned(ClosedCaseFlick(axis:sum,peak:typical*Self.peakShare)))
        } else if all.count>=Self.mostFlicks{done=true;events.append(.failed)}
        return events
    }
    private mutating func finishBurst()->[Event] {
        defer{burst=[];live=[];quietSince=nil}
        var events=update()
        guard !done else{return events}
        if live.isEmpty,let axis=Self.principalAxis(burst.map(\.w)),(burst.map{abs(($0.w*axis).sum())}.max() ?? 0)>=120{events.append(.tooSlow)}
        examples+=live
        return events
    }
}

// Keeps the pointer where a click or a flick left it. A tap or a flick turns the case a few degrees (a tap
// about 5°, some 200 px), so once the pointer is let go it would jump to where the case now points. Instead the
// difference is kept as an offset that fades only as the person moves: half as fast as the pointer moves, so
// it's gone once they've moved twice as far, and never while they hold still. Pointing past a screen edge, where
// the aim can't move further, it fades over about a second, so every edge stays reachable.
struct ClosedCasePointerAnchor {
    static let catchUp=0.5,edgeFade=1.0,edge=0.001
    private(set) var offset=CGVector.zero
    private var last:CGPoint?,lastTime:Double?
    // `aim` is where the case points now; the pointer stays at `point`.
    mutating func anchor(_ aim:CGPoint,at point:CGPoint){offset=CGVector(dx:point.x-aim.x,dy:point.y-aim.y);last=aim}
    mutating func reset(){offset = .zero;last=nil;lastTime=nil}
    mutating func apply(_ aim:CGPoint,at time:Double)->CGPoint {
        defer{last=aim;lastTime=time}
        let size=hypot(offset.dx,offset.dy)
        if size>0,let last {
            let keep=max(0,1-Self.catchUp*hypot(aim.x-last.x,aim.y-last.y)/size)
            offset.dx*=keep;offset.dy*=keep
            if let lastTime,time>lastTime {
                let fade=exp(-(time-lastTime)/Self.edgeFade)
                if (aim.x<=Self.edge && offset.dx>0) || (aim.x>=1-Self.edge && offset.dx<0){offset.dx*=fade}
                if (aim.y<=Self.edge && offset.dy>0) || (aim.y>=1-Self.edge && offset.dy<0){offset.dy*=fade}
            }
        }
        return CGPoint(x:min(1,max(0,aim.x+offset.dx)),y:min(1,max(0,aim.y+offset.dy)))
    }
}

// Tells one tap from two. With a double tap bound, a tap waits `window` for a second before it clicks; two
// taps that close together are the double tap and don't click. With nothing bound, the session doesn't use this.
struct ClosedCaseDoubleTap {
    enum Outcome:Equatable{case click(CGPoint),double(CGPoint)}
    static let window=0.35
    private var pending:(since:Double,point:CGPoint,expires:Double)?
    var waiting:Bool{pending != nil}
    // `since` is when the tap began (sensor seconds); `now` and expiry are host uptime.
    mutating func tap(since:Double,point:CGPoint,now:Double)->[Outcome] {
        if let held=pending {
            pending=nil
            if since-held.since<=Self.window{return [.double(held.point)]}
            pending=(since,point,now+Self.window);return [.click(held.point)]
        }
        pending=(since,point,now+Self.window);return []
    }
    mutating func expire(now:Double)->CGPoint? {
        guard let held=pending,now>=held.expires else{return nil}
        pending=nil;return held.point
    }
    mutating func reset(){pending=nil}
}

// Moves the cursor between motion updates. Motion arrives in bursts, often 20-60 ms apart, and posting the
// cursor only then makes it jump. Each step eases toward the latest aim, carried forward at its recent speed
// for up to 30 ms, so a short gap keeps moving and a longer one settles where the aim was heading.
struct ClosedCaseCursorGlide {
    static let follow=0.02,lead=0.03
    private(set) var position:CGPoint?
    private var target:CGPoint?,targetAt=0.0,velocity=CGVector.zero,steppedAt:Double?
    mutating func aim(_ point:CGPoint,at now:Double) {
        if let target,now>targetAt {
            let dt=now-targetAt
            if dt<0.15 {
                let blend=min(1,dt/0.05)
                velocity.dx+=((point.x-target.x)/dt-velocity.dx)*blend
                velocity.dy+=((point.y-target.y)/dt-velocity.dy)*blend
            } else{velocity = .zero}
        }
        target=point;targetAt=now
    }
    // A held point (a click, a gesture) goes straight there and stays put.
    mutating func snap(_ point:CGPoint,at now:Double){position=point;target=point;targetAt=now;velocity = .zero;steppedAt=now}
    mutating func step(at now:Double)->CGPoint? {
        guard let target else{return nil}
        let ahead=min(max(now-targetAt,0),Self.lead)
        let goal=CGPoint(x:min(1,max(0,target.x+velocity.dx*ahead)),y:min(1,max(0,target.y+velocity.dy*ahead)))
        guard let position,let steppedAt else{position=goal;steppedAt=now;return goal}
        let alpha=1-exp(-max(0,now-steppedAt)/Self.follow)
        let next=CGPoint(x:position.x+(goal.x-position.x)*alpha,y:position.y+(goal.y-position.y)*alpha)
        self.position=next;self.steppedAt=now
        return next
    }
    mutating func reset(){position=nil;target=nil;velocity = .zero;steppedAt=nil}
}

// MARK: - Actions

// A key and its modifiers, as a gesture sends it.
struct GestureShortcut:Equatable {
    var key:UInt16,modifiers:NSEvent.ModifierFlags,name:String
    static let relevant:NSEvent.ModifierFlags=[.control,.option,.shift,.command]
    var label:String {
        [(NSEvent.ModifierFlags.control,"⌃"),(.option,"⌥"),(.shift,"⇧"),(.command,"⌘")].filter{modifiers.contains($0.0)}.map(\.1).joined()+name
    }
    // Shortcuts a stray gesture must never send, because they quit, close or lock things.
    private static let risky:[(UInt16,NSEvent.ModifierFlags)]=[
        (UInt16(kVK_ANSI_Q),[.command]),(UInt16(kVK_ANSI_Q),[.command,.shift]),(UInt16(kVK_ANSI_Q),[.command,.control]),
        (UInt16(kVK_ANSI_Q),[.command,.option,.shift]),(UInt16(kVK_ANSI_W),[.command]),(UInt16(kVK_ANSI_W),[.command,.option]),
        (UInt16(kVK_ANSI_W),[.command,.shift]),(UInt16(kVK_Escape),[.command,.option]),(UInt16(kVK_Delete),[.command]),
        (UInt16(kVK_Tab),[.command]),
    ]
    // Why this can't be a gesture's shortcut, or nil if it can.
    static func refusal(_ shortcut:GestureShortcut,pointer:PointerShortcut,others:[GestureShortcut])->String? {
        let mods=shortcut.modifiers.intersection(relevant)
        if pointer.key==shortcut.key,pointer.modifiers.intersection(relevant)==mods{return "That’s the pointer shortcut. Choose another."}
        if risky.contains(where:{$0.0==shortcut.key && $0.1==mods}){return "That quits, closes or locks things, so a stray gesture could lose your work. Choose another."}
        if others.contains(where:{$0.key==shortcut.key && $0.modifiers.intersection(relevant)==mods}){return "Another gesture already sends that. Choose another."}
        return nil
    }
}

enum GestureAction:Equatable {
    case nothing,click,rightClick,playPause,recenter
    case keys(GestureShortcut)
    static func key(_ code:Int,_ name:String,_ modifiers:NSEvent.ModifierFlags=[])->GestureAction{.keys(GestureShortcut(key:UInt16(code),modifiers:modifiers,name:name))}
    // The choices Settings offers, in order, before a custom shortcut.
    static let presets:[(title:String,action:GestureAction)]=[
        ("Nothing",.nothing),("Click",.click),
        ("Return",key(kVK_Return,"Return")),("Escape",key(kVK_Escape,"Esc")),("Space",key(kVK_Space,"Space")),
        ("Left Arrow",key(kVK_LeftArrow,"←")),("Right Arrow",key(kVK_RightArrow,"→")),
        ("Up Arrow",key(kVK_UpArrow,"↑")),("Down Arrow",key(kVK_DownArrow,"↓")),
        ("Page Up",key(kVK_PageUp,"Page Up")),("Page Down",key(kVK_PageDown,"Page Down")),
        ("Mission Control",key(kVK_UpArrow,"↑",[.control])),("Play or Pause",.playPause),
        ("Right Click",.rightClick),("Recenter",.recenter),
    ]
    var title:String {
        if let preset=Self.presets.first(where:{$0.action==self}){return preset.title}
        if case .keys(let shortcut)=self{return shortcut.label}
        return "Nothing"
    }
    var shortcut:GestureShortcut?{if case .keys(let shortcut)=self{return shortcut};return nil}

    var stored:[String:Any] {
        switch self {
        case .nothing:return ["kind":"nothing"]
        case .click:return ["kind":"click"]
        case .rightClick:return ["kind":"rightClick"]
        case .playPause:return ["kind":"playPause"]
        case .recenter:return ["kind":"recenter"]
        case .keys(let s):return ["kind":"keys","key":Int(s.key),"modifiers":s.modifiers.intersection(GestureShortcut.relevant).rawValue,"name":s.name]
        }
    }
    init(stored:[String:Any]?) {
        switch stored?["kind"] as? String {
        case "click":self = .click
        case "rightClick":self = .rightClick
        case "playPause":self = .playPause
        case "recenter":self = .recenter
        case "keys":
            guard let key=stored?["key"] as? Int,(0...0x7f).contains(key),let raw=stored?["modifiers"] as? UInt,let name=stored?["name"] as? String else{self = .nothing;return}
            self = .keys(GestureShortcut(key:UInt16(key),modifiers:NSEvent.ModifierFlags(rawValue:raw).intersection(GestureShortcut.relevant),name:name))
        default:self = .nothing
        }
    }

    // Sends the action from AirPointer as if typed or clicked; `at` is the cursor in screen coordinates.
    func perform(at point:CGPoint?,recenter:()->Void) {
        switch self {
        case .nothing:return
        case .recenter:recenter()
        case .click:
            guard let point else{return}
            for type in [CGEventType.leftMouseDown,.leftMouseUp]{CGEvent(mouseEventSource:nil,mouseType:type,mouseCursorPosition:point,mouseButton:.left)?.post(tap:.cghidEventTap)}
        case .rightClick:
            guard let point else{return}
            for type in [CGEventType.rightMouseDown,.rightMouseUp]{CGEvent(mouseEventSource:nil,mouseType:type,mouseCursorPosition:point,mouseButton:.right)?.post(tap:.cghidEventTap)}
        case .playPause:
            // The media key, as the keyboard's own play key sends it.
            for down in [true,false] {
                let data1=(16<<16)|((down ? 0xa:0xb)<<8) // NX_KEYTYPE_PLAY
                NSEvent.otherEvent(with:.systemDefined,location:.zero,modifierFlags:NSEvent.ModifierFlags(rawValue:down ? 0xa00:0xb00),timestamp:0,
                                   windowNumber:0,context:nil,subtype:8,data1:data1,data2:-1)?.cgEvent?.post(tap:.cghidEventTap)
            }
        case .keys(let shortcut):
            let source=CGEventSource(stateID:.hidSystemState)
            var flags=CGEventFlags()
            if shortcut.modifiers.contains(.control){flags.insert(.maskControl)}
            if shortcut.modifiers.contains(.option){flags.insert(.maskAlternate)}
            if shortcut.modifiers.contains(.shift){flags.insert(.maskShift)}
            if shortcut.modifiers.contains(.command){flags.insert(.maskCommand)}
            if [kVK_LeftArrow,kVK_RightArrow,kVK_UpArrow,kVK_DownArrow].contains(Int(shortcut.key)){flags.formUnion([.maskSecondaryFn,.maskNumericPad])}
            for down in [true,false] {
                guard let event=CGEvent(keyboardEventSource:source,virtualKey:shortcut.key,keyDown:down) else{continue}
                event.flags=flags;event.post(tap:.cghidEventTap)
            }
        }
    }
}

// MARK: - Checks

func runClosedCaseGestureChecks(fixtures:URL?) throws -> String {
    func length(_ v:SIMD3<Double>)->Double{(v*v).sum().squareRoot()}
    typealias Plan=(start:Double,axis:SIMD3<Double>,peak:Double,half:Double)
    // Gyro at 200 Hz: each planned swing is half a sine of that peak and length about its axis; still otherwise.
    func motion(_ seconds:Double,_ plan:[Plan],drift:SIMD3<Double> = .zero)->[(Double,SIMD3<Double>)] {
        (0..<Int(seconds*200)).map{i in
            let t=Double(i)*0.005
            var w=drift
            for swing in plan where t>=swing.start && t<=swing.start+swing.half{w+=swing.axis*(swing.peak*sin(Double.pi*(t-swing.start)/swing.half))}
            return (1e9+t*1e6,w)
        }
    }
    // A nod: fast one way, slower back, `cycles` times, starting at `at`.
    func nod(_ axis:SIMD3<Double>,at:Double=1,fast:Double=450,slow:Double=260,cycles:Int=1)->[Plan] {
        (0..<cycles).flatMap{c->[Plan] in
            let start=at+Double(c)*0.55
            return [(start,-axis,fast,0.2),(start+0.2,axis,slow,0.35)]
        }
    }
    func run(_ samples:[(Double,SIMD3<Double>)],_ flicks:[FlickAxis:ClosedCaseFlick])->[ClosedCaseFlickDetector.Event] {
        var detector=ClosedCaseFlickDetector();detector.flicks=flicks
        return samples.flatMap{detector.feed(stamp:$0.0,w:$0.1)}
    }
    func named(_ events:[ClosedCaseFlickDetector.Event])->[FlickAxis]{events.map{if case .flick(let a,_,_)=$0{return a};return .vertical}}
    let up=SIMD3(0.0,1,0),side=SIMD3(1.0,0,0)
    let both:[FlickAxis:ClosedCaseFlick]=[.vertical:ClosedCaseFlick(axis:up,peak:340),.horizontal:ClosedCaseFlick(axis:side,peak:340)]
    guard named(run(motion(3,nod(up)),both))==[.vertical],named(run(motion(3,nod(side,fast:700)),both))==[.horizontal] else{
        throw LessonError.message("A fast, big flick up and back must be vertical, and one to the side horizontal.")
    }
    guard named(run(motion(5,nod(up,cycles:5)),both))==[.vertical] else{throw LessonError.message("Flicking several times in a row must count once.")}
    // Direction: `nod` swings against its axis first, so a nod about +up is a flick down, about -up a flick up.
    func direction(_ plan:[Plan])->CaseGesture? {
        guard case .flick(let axis,let turn,_)? = run(motion(3,plan),both).first else{return nil}
        return closedCaseFlickGesture(axis,turn:turn,up:up,right:side)
    }
    let down=direction(nod(up)),upward=direction(nod(-up)),left=direction(nod(side,fast:600)),right=direction(nod(-side,fast:600))
    guard down == .flickDown,upward == .flickUp,left == .flickLeft,right == .flickRight else{
        throw LessonError.message("A flick’s first swing must say up, down, left or right.")
    }
    guard closedCaseFlickGesture(.vertical,turn:up,up:nil,right:side)==nil else{throw LessonError.message("Without calibration a flick has no direction.")}
    // Sensor seconds: the nod's first swing starts 1 s into a stream stamped from 1000 s.
    guard case .flick(_,_,let since)? = run(motion(3,nod(up)),both).first,abs(since-1001)<0.02 else{
        throw LessonError.message("A gesture must say when it began, so the pointer can go back there: \(String(describing:run(motion(3,nod(up)),both).first)).")
    }
    guard run(motion(3,nod(up,fast:260,slow:200)),both).isEmpty else{throw LessonError.message("A slow nod must not count.")}
    guard run(motion(3,[(1,-up,600,0.04),(1.04,up,400,0.04)]),both).isEmpty else{throw LessonError.message("A fast twitch too small to see must not count.")}
    guard run(motion(3,[(1,-up,500,0.25)]),both).isEmpty else{throw LessonError.message("One swing with no swing back must not count.")}
    let diagonal=(up+side)/length(up+side)
    guard run(motion(3,nod(diagonal)),both).isEmpty else{throw LessonError.message("A nod between the two axes must count as neither.")}
    guard run(motion(3,nod(up),drift:SIMD3(0,0,130)),both).isEmpty else{throw LessonError.message("A nod that doesn’t start from a steady aim must not count.")}
    var detail="flicks at 340°/s or more, up, down, left and right by their first swing, one per burst, not slow, small, one-way, diagonal or unsteady ones"
    if let fixtures {
        // The recorded natural nod and shake: their own axes, then one Yes and one No.
        let gestures=try loadClosedCaseTapFixtures(fixtures.deletingLastPathComponent().appendingPathComponent("GestureFixtures.csv"))
        func gyro(_ name:String)throws->[(Double,SIMD3<Double>)] {
            guard let segment=gestures.first(where:{$0.name==name}) else{throw LessonError.message("The \(name) fixture is missing.")}
            return segment.rows.sorted{$0[2]<$1[2]}.map{($0[2],SIMD3($0[4],$0[5],$0[6])*1e-5)}
        }
        let nodRows=try gyro("nod"),shakeRows=try gyro("shake")
        guard let yesAxis=ClosedCaseFlickLearner.principalAxis(nodRows.map(\.1).filter{length($0)>=40}),
              let noAxis=ClosedCaseFlickLearner.principalAxis(shakeRows.map(\.1).filter{length($0)>=40}) else{throw LessonError.message("The recorded gestures have no axis.")}
        let taught:[FlickAxis:ClosedCaseFlick]=[.vertical:ClosedCaseFlick(axis:yesAxis,peak:ClosedCaseFlickDetector.defaultPeak),.horizontal:ClosedCaseFlick(axis:noAxis,peak:ClosedCaseFlickDetector.defaultPeak)]
        guard named(run(nodRows,taught))==[.vertical],named(run(shakeRows,taught))==[.horizontal] else{
            throw LessonError.message("The recorded nod must be one Yes and the recorded shake one No: got \(named(run(nodRows,taught))) and \(named(run(shakeRows,taught))).")
        }
        var learner=ClosedCaseFlickLearner(),taughtYes:ClosedCaseFlick?
        for (stamp,w) in nodRows{for event in learner.feed(stamp:stamp,w:w){if case .learned(let found)=event{taughtYes=found}}}
        guard let taughtYes,abs((taughtYes.axis*yesAxis).sum())>0.95 else{throw LessonError.message("The recorded nod must teach Yes on its own.")}
        // The recorded pointing and taps, about many axis pairs: never a gesture.
        let segments=try loadClosedCaseTapFixtures(fixtures).filter{$0.name=="pointing" || $0.name=="held"}
        var seed:UInt64=7
        func random()->Double{seed=seed&*6364136223846793005&+1442695040888963407;return Double(seed>>11)/Double(1<<53)*2-1}
        for _ in 0..<24 {
            var a=SIMD3(random(),random(),random());a/=length(a)
            var b=SIMD3(random(),random(),random());b-=a*(a*b).sum();b/=length(b)
            let flicks:[FlickAxis:ClosedCaseFlick]=[.vertical:ClosedCaseFlick(axis:a,peak:ClosedCaseFlickDetector.defaultPeak),.horizontal:ClosedCaseFlick(axis:b,peak:ClosedCaseFlickDetector.defaultPeak)]
            for segment in segments {
                let rows:[[Double]]=segment.rows.filter{$0[1]==12}.sorted{$0[2]<$1[2]}
                let samples:[(Double,SIMD3<Double>)]=rows.map{row in (row[2],SIMD3<Double>(row[4],row[5],row[6])*1e-5)}
                guard run(samples,flicks).isEmpty else{throw LessonError.message("Recorded \(segment.name) gave a gesture about a random axis.")}
            }
        }
        detail+="; the recorded nod and shake each once, and nothing in recorded pointing or taps about 24 random axis pairs"
    }
    // Teaching: one natural "yes, yes, yes" teaches it; so do single nods with pauses, leaving a stray shake out;
    // a gentle one says so.
    let axis=SIMD3(0.6,0.8,0.0),stray=SIMD3(0.0,0.0,1.0)
    func teach(_ plan:[Plan],seconds:Double)->(counts:[Int],learned:ClosedCaseFlick?) {
        var learner=ClosedCaseFlickLearner(),counts:[Int]=[],learned:ClosedCaseFlick?
        for (stamp,w) in motion(seconds,plan){for event in learner.feed(stamp:stamp,w:w){
            if case .flick(let agreeing,_)=event{counts.append(agreeing)}
            if case .learned(let found)=event{learned=found}
        }}
        return (counts,learned)
    }
    let once=teach(nod(axis,at:1,fast:460,cycles:3),seconds:4)
    guard let onceLearned=once.learned,abs((onceLearned.axis*axis).sum())>0.98,abs(onceLearned.peak-max(300,0.7*460))<15,once.counts==[1,2,3] else{
        throw LessonError.message("Nodding three times in one go must teach it, a dot at a time: \(once).")
    }
    let eager=teach(nod(axis,at:1,fast:700,cycles:3),seconds:4)
    guard eager.learned?.peak==ClosedCaseFlickDetector.highestPeak,ClosedCaseFlick(stored:[0,1,0,775])?.peak==ClosedCaseFlickDetector.highestPeak,
          ClosedCaseFlick(stored:[0,1,0,120])?.peak==ClosedCaseFlickDetector.lowestPeak else{
        throw LessonError.message("Teaching eagerly must not set a bar that misses everyday flicks: \(String(describing:eager.learned)).")
    }
    let apart=teach(nod(axis,at:1,fast:420)+nod(stray,at:3,fast:500)+nod(-axis,at:5,fast:480)+nod(axis,at:7,fast:460),seconds:10)
    guard let apartLearned=apart.learned,abs((apartLearned.axis*axis).sum())>0.98,apart.counts.last==3 else{
        throw LessonError.message("Nods with pauses must teach it, leaving a stray shake out: \(apart).")
    }
    var gentle=ClosedCaseFlickLearner(),saidSlow=false
    for (stamp,w) in motion(4,nod(axis,fast:200,slow:150)){if gentle.feed(stamp:stamp,w:w).contains(.tooSlow){saidSlow=true}}
    guard saidSlow else{throw LessonError.message("A nod too gentle to learn must say so.")}
    detail+="; bars kept to 300–340°/s however eagerly taught; one natural yes-yes-yes teaches it, a dot a nod, and so do nods with pauses, without a stray one"
    // Double tap: two close taps are one gesture; one tap clicks once its window has passed.
    var gate=ClosedCaseDoubleTap();let a=CGPoint(x:0.2,y:0.3),b=CGPoint(x:0.4,y:0.5)
    guard gate.tap(since:1,point:a,now:10).isEmpty,gate.tap(since:1.2,point:b,now:10.2)==[.double(a)],!gate.waiting,
          gate.tap(since:2,point:a,now:11).isEmpty,gate.expire(now:11.3)==nil,gate.expire(now:11.36)==a,
          gate.tap(since:3,point:a,now:12).isEmpty,gate.tap(since:3.5,point:b,now:12.5)==[.click(a)],gate.waiting else{
        throw LessonError.message("Two quick taps must be one double tap, and a single tap must click after its window.")
    }
    // The anchor: held still, the pointer stays where it was clicked; moving, it catches up with the aim.
    var anchor=ClosedCasePointerAnchor()
    anchor.anchor(CGPoint(x:0.6,y:0.5),at:CGPoint(x:0.5,y:0.5))
    var held=CGPoint.zero
    for i in 0..<200{held=anchor.apply(CGPoint(x:0.6,y:0.5),at:Double(i)*0.005)}
    guard abs(held.x-0.5)<1e-9 else{throw LessonError.message("After a click the pointer must stay where it clicked: \(held).")}
    var moved=CGPoint.zero
    for i in 0...100{moved=anchor.apply(CGPoint(x:0.6,y:0.5+0.002*Double(i)),at:1+Double(i)*0.005)}
    guard abs(moved.y-0.7)<1e-9,abs(moved.x-0.6)<1e-6 else{throw LessonError.message("Moving twice the offset must bring the pointer back to the aim: \(moved).")}
    var edgeAnchor=ClosedCasePointerAnchor();edgeAnchor.anchor(CGPoint(x:0,y:0.5),at:CGPoint(x:0.1,y:0.5))
    var atEdge=CGPoint.zero
    for i in 0..<800{atEdge=edgeAnchor.apply(CGPoint(x:0,y:0.5),at:Double(i)*0.005)}
    guard atEdge.x<0.003 else{throw LessonError.message("Pointing past an edge must reach it: \(atEdge).")}
    // The glide eases toward the aim, carries on through a short gap, and settles after a long one.
    var glide=ClosedCaseCursorGlide()
    glide.aim(CGPoint(x:0.5,y:0.5),at:0);_=glide.step(at:0)
    glide.aim(CGPoint(x:0.6,y:0.5),at:0.02)
    let soon=glide.step(at:0.025)?.x ?? 0,later=glide.step(at:0.06)?.x ?? 0,settled=glide.step(at:0.4)?.x ?? 0
    guard soon>0.5,soon<0.6,later>soon,abs(settled-0.66)<0.01 else{throw LessonError.message("The cursor must glide toward the aim and settle a little ahead of a moving aim.")}
    glide.snap(CGPoint(x:0.1,y:0.1),at:0.5);guard glide.step(at:0.6)==CGPoint(x:0.1,y:0.1) else{throw LessonError.message("A held point must stay put.")}
    // Actions: stored and loaded, and risky or taken shortcuts refused.
    for preset in GestureAction.presets{guard GestureAction(stored:preset.action.stored)==preset.action else{throw LessonError.message("\(preset.title) didn’t round-trip.")}}
    let custom=GestureAction.keys(GestureShortcut(key:UInt16(kVK_ANSI_K),modifiers:[.command,.shift],name:"K"))
    guard GestureAction(stored:custom.stored)==custom,custom.title=="⇧⌘K",GestureAction(stored:["kind":"keys","key":999]) == .nothing else{
        throw LessonError.message("A custom shortcut must round-trip, and a broken one must load as Nothing.")
    }
    let pointer=PointerShortcut(modifiers:[.control,.option],key:UInt16(kVK_ANSI_P),keyName:"P")
    guard GestureShortcut.refusal(GestureShortcut(key:UInt16(kVK_ANSI_Q),modifiers:[.command],name:"Q"),pointer:pointer,others:[]) != nil,
          GestureShortcut.refusal(GestureShortcut(key:UInt16(kVK_ANSI_P),modifiers:[.control,.option],name:"P"),pointer:pointer,others:[]) != nil,
          GestureShortcut.refusal(custom.shortcut!,pointer:pointer,others:[custom.shortcut!]) != nil,
          GestureShortcut.refusal(custom.shortcut!,pointer:pointer,others:[]) == nil else{
        throw LessonError.message("Gesture shortcuts must refuse quitting, the pointer shortcut and a shortcut another gesture sends.")
    }
    return "gestures: "+detail+"; double tap; the pointer stays where it clicked until moved; cursor glide; actions stored and risky shortcuts refused"
}
