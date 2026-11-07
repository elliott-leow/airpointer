import AppKit
import Carbon

// Gestures with the closed case, each of which does nothing until Settings gives it an action:
// Yes, a fast flick up and back (or down and back); No, a fast flick to one side and back; and a double tap.
enum CaseGesture:String,CaseIterable {
    case yes,no,doubleTap
    var title:String{switch self{case .yes:return "Yes";case .no:return "No";case .doubleTap:return "Double tap"}}
    var movement:String {
        switch self {
        case .yes:return "Flick the case up and straight back, quickly."
        case .no:return "Flick the case to one side and straight back, quickly."
        case .doubleTap:return "Tap the front twice, quickly."
        }
    }
}

// One taught flick: the axis the case turns about, in the case's own frame, and how fast it has to turn (°/s).
struct ClosedCaseFlick:Equatable {
    var axis:SIMD3<Double>,peak:Double
    var stored:[Double]{[axis.x,axis.y,axis.z,peak]}
    init(axis:SIMD3<Double>,peak:Double){let n=(axis*axis).sum().squareRoot();self.axis=n>0 ? axis/n:axis;self.peak=peak}
    init?(stored:[Double]?) {
        guard let stored,stored.count==4,stored.allSatisfy(\.isFinite),stored[3]>0 else{return nil}
        let axis=SIMD3(stored[0],stored[1],stored[2]);guard (axis*axis).sum()>0.25 else{return nil}
        self.init(axis:axis,peak:max(ClosedCaseFlickDetector.lowestPeak,stored[3]))
    }
}

// A flick is a fast swing about one axis that comes straight back: out and back each last 50-300 ms and turn
// 8° or more, the return is at least half as fast and ends near where the flick began, the case was fairly
// steady just before it, and it stays on its axis. Aiming is one sweep, or a sweep with a small correction,
// so it never qualifies; a tap's twitch is far too short. Over 56 s of recorded pointing and the recorded
// taps, no flick is found about any of 200 random axes at 200°/s, while flicks of 200-400°/s always are.
struct ClosedCaseFlickDetector {
    enum Event:Equatable{case flick(CaseGesture,since:Double)}
    // Rotation rates in degrees per second, angles in degrees, times in seconds.
    static let defaultPeak=200.0,lowestPeak=150.0,shortestSwing=0.05,longestSwing=0.3,longestReturn=0.35,smallestSwing=8.0
    static let calmShare=0.4,offAxisShare=0.5,returnShare=0.5,balance=0.4,cooldown=0.6,maximumGap=0.1
    var flicks:[CaseGesture:ClosedCaseFlick]=[:]
    private enum Phase{case idle,out,back}
    private struct Track {
        var phase=Phase.idle,sign=1.0,start=0.0,backStart=0.0,peak=0.0,returnPeak=0.0,offPeak=0.0,outAngle=0.0,backAngle=0.0,calmBefore=Double.infinity
    }
    private var tracks:[CaseGesture:Track]=[:],recent:[(t:Double,w:SIMD3<Double>)]=[],last:Double?,lastFlick = -Double.infinity

    mutating func reset(){tracks=[:];recent=[];last=nil}
    private func length(_ v:SIMD3<Double>)->Double{(v*v).sum().squareRoot()}
    // `w` has the gyro's resting offset taken out; `stamp` is the sensor's microseconds.
    mutating func feed(stamp:Double,w:SIMD3<Double>)->[Event] {
        let t=stamp*1e-6
        guard t.isFinite,w.x.isFinite,w.y.isFinite,w.z.isFinite else{return []}
        if let last,t<=last{return []}
        let dt=last.map{t-$0} ?? 0
        if dt>Self.maximumGap{tracks=[:]}
        last=t
        defer{recent.append((t,w));while let first=recent.first,t-first.t>0.3{recent.removeFirst()}}
        var events:[Event]=[]
        for gesture in CaseGesture.allCases {
            guard let flick=flicks[gesture] else{continue}
            var k=tracks[gesture] ?? Track()
            let s=(w*flick.axis).sum(),off=length(w-flick.axis*s)
            switch k.phase {
            case .idle:
                guard abs(s)>=0.5*flick.peak,t-lastFlick>=Self.cooldown else{break}
                let before=recent.filter{$0.t>=t-0.2 && $0.t<=t-0.05}.map{length($0.w)}
                k=Track(phase:.out,sign:s>0 ? 1:-1,start:t,peak:abs(s),offPeak:off,calmBefore:before.max() ?? .infinity)
            case .out:
                k.offPeak=max(k.offPeak,off)
                if k.sign*s>0{k.peak=max(k.peak,abs(s));k.outAngle+=abs(s)*dt}
                else if k.peak>=flick.peak,(Self.shortestSwing...Self.longestSwing).contains(t-k.start),k.outAngle>=Self.smallestSwing,k.calmBefore<=Self.calmShare*k.peak {
                    k.phase = .back;k.backStart=t;k.returnPeak=abs(s)
                } else{k=Track()}
            case .back:
                k.offPeak=max(k.offPeak,off)
                if -k.sign*s>0{k.returnPeak=max(k.returnPeak,abs(s));k.backAngle+=abs(s)*dt}
                if (k.returnPeak>=0.3*k.peak && (k.sign*s>=0 || abs(s)<0.15*k.peak)) || t-k.backStart>Self.longestReturn {
                    let swing=max(k.outAngle,k.backAngle)
                    if k.returnPeak>=Self.returnShare*k.peak,(Self.shortestSwing...Self.longestReturn).contains(t-k.backStart),
                       abs(k.outAngle-k.backAngle)<=Self.balance*swing,k.offPeak<=Self.offAxisShare*max(k.peak,k.returnPeak) {
                        events.append(.flick(gesture,since:k.start));lastFlick=t
                    }
                    k=Track()
                }
            }
            tracks[gesture]=k
        }
        if !events.isEmpty{tracks=[:]}
        return Array(events.prefix(1))
    }
}

// Learns a flick from three that agree, without knowing its axis first: each starts when the case turns fast
// from a steady moment, its axis is the turn there and back, and it must pass the detector's own rules.
// Flicks up or down (left or right) count as one axis. The speed it then needs is 60% of the typical one.
struct ClosedCaseFlickLearner {
    enum Event:Equatable{case flick(agreeing:Int,total:Int),tooSlow,learned(ClosedCaseFlick),failed}
    static let flicks=3,mostFlicks=8,agree=0.85,onset=100.0,peakShare=0.6
    private typealias Detector=ClosedCaseFlickDetector
    private struct Swing{var axis:SIMD3<Double>,peak:Double}
    private var phase=0,axis=SIMD3<Double>.zero,start=0.0,backStart=0.0,peak=0.0,returnPeak=0.0,outAngle=0.0,backAngle=0.0,calmBefore=0.0
    private var outTurn=SIMD3<Double>.zero,backTurn=SIMD3<Double>.zero,offPeak=0.0
    private var recent:[(t:Double,w:SIMD3<Double>)]=[],last:Double?,lastSwing = -Double.infinity,lastSlow = -Double.infinity
    private var swings:[Swing]=[],done=false

    private static func length(_ v:SIMD3<Double>)->Double{(v*v).sum().squareRoot()}
    private static func unit(_ v:SIMD3<Double>)->SIMD3<Double>{v/max(length(v),1e-9)}
    mutating func feed(stamp:Double,w:SIMD3<Double>)->[Event] {
        let t=stamp*1e-6,length=Self.length
        guard !done,t.isFinite,w.x.isFinite,w.y.isFinite,w.z.isFinite else{return []}
        if let last,t<=last{return []}
        let dt=last.map{t-$0} ?? 0
        if dt>Detector.maximumGap{phase=0}
        last=t
        defer{recent.append((t,w));while let first=recent.first,t-first.t>0.3{recent.removeFirst()}}
        let s=phase==0 ? length(w):(w*axis).sum(),off=phase==0 ? 0:length(w-axis*s)
        switch phase {
        case 0:
            guard s>=Self.onset,t-lastSwing>=Detector.cooldown else{return []}
            let before=recent.filter{$0.t>=t-0.2 && $0.t<=t-0.05}.map{length($0.w)}
            guard let calm=before.max() else{return []}
            phase=1;axis=Self.unit(w);start=t;peak=s;returnPeak=0;outAngle=0;backAngle=0;calmBefore=calm;outTurn = .zero;backTurn = .zero;offPeak=0
        case 1:
            offPeak=max(offPeak,off)
            if s>0{peak=max(peak,s);outAngle+=s*dt;outTurn+=w*dt}
            else if (Detector.shortestSwing...Detector.longestSwing).contains(t-start),outAngle>=Detector.smallestSwing,calmBefore<=Detector.calmShare*peak{phase=2;backStart=t;returnPeak = -s}
            else{phase=0}
        default:
            offPeak=max(offPeak,off)
            if s<0{returnPeak=max(returnPeak,-s);backAngle += -s*dt;backTurn+=w*dt}
            guard (returnPeak>=0.3*peak && (s>=0 || -s<0.15*peak)) || t-backStart>Detector.longestReturn else{return []}
            phase=0
            let swing=max(outAngle,backAngle)
            guard returnPeak>=Detector.returnShare*peak,(Detector.shortestSwing...Detector.longestReturn).contains(t-backStart),
                  abs(outAngle-backAngle)<=Detector.balance*swing,offPeak<=Detector.offAxisShare*max(peak,returnPeak) else{return []}
            lastSwing=t
            guard peak>=Detector.lowestPeak else{
                if t-lastSlow>=Detector.cooldown{lastSlow=t;return [.tooSlow]}
                return []
            }
            swings.append(Swing(axis:Self.unit(outTurn-backTurn),peak:peak))
            return finish()
        }
        return []
    }
    // The flicks that share an axis (either way round) with the best-supported one.
    private mutating func finish()->[Event] {
        let axes=swings.map(\.axis)
        guard let seed=axes.max(by:{a,b in axes.filter{abs(($0*a).sum())>=Self.agree}.count<axes.filter{abs(($0*b).sum())>=Self.agree}.count}) else{return []}
        let members=swings.filter{abs(($0.axis*seed).sum())>=Self.agree}
        var events:[Event]=[.flick(agreeing:members.count,total:swings.count)]
        if members.count>=Self.flicks {
            let sum=members.reduce(SIMD3<Double>.zero){$0+(($1.axis*seed).sum()<0 ? -$1.axis:$1.axis)}
            let peaks=members.map(\.peak).sorted(),typical=peaks[peaks.count/2]
            done=true;events.append(.learned(ClosedCaseFlick(axis:sum,peak:max(Detector.lowestPeak,typical*Self.peakShare))))
        } else if swings.count>=Self.mostFlicks{done=true;events.append(.failed)}
        return events
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
    case nothing,rightClick,playPause,recenter
    case keys(GestureShortcut)
    static func key(_ code:Int,_ name:String,_ modifiers:NSEvent.ModifierFlags=[])->GestureAction{.keys(GestureShortcut(key:UInt16(code),modifiers:modifiers,name:name))}
    // The choices Settings offers, in order, before a custom shortcut.
    static let presets:[(title:String,action:GestureAction)]=[
        ("Nothing",.nothing),
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
        case .rightClick:return ["kind":"rightClick"]
        case .playPause:return ["kind":"playPause"]
        case .recenter:return ["kind":"recenter"]
        case .keys(let s):return ["kind":"keys","key":Int(s.key),"modifiers":s.modifiers.intersection(GestureShortcut.relevant).rawValue,"name":s.name]
        }
    }
    init(stored:[String:Any]?) {
        switch stored?["kind"] as? String {
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
    // Gyro samples at 200 Hz: still, then `shape` from one second on.
    func motion(_ seconds:Double,_ shape:(Double)->SIMD3<Double>)->[(Double,SIMD3<Double>)] {
        (0..<Int(seconds*200)).map{i in let t=Double(i)*0.005;return (1e9+t*1e6,shape(t))}
    }
    // A flick about `axis`: out at `peak` for `half` seconds, then back.
    func flick(_ axis:SIMD3<Double>,peak:Double,half:Double,at:Double=1,back:Double=1,offAxis:SIMD3<Double> = .zero)->(Double)->SIMD3<Double> {
        {t in
            let u=t-at
            guard u>=0,u<=2*half else{return SIMD3(0.3,-0.2,0.1)}
            let s=u<=half ? peak*sin(Double.pi*u/half):back*peak*sin(Double.pi*u/half)
            return axis*s+offAxis*abs(s)+SIMD3(0.3,-0.2,0.1)
        }
    }
    func run(_ samples:[(Double,SIMD3<Double>)],_ flicks:[CaseGesture:ClosedCaseFlick])->[ClosedCaseFlickDetector.Event] {
        var detector=ClosedCaseFlickDetector();detector.flicks=flicks
        return samples.flatMap{detector.feed(stamp:$0.0,w:$0.1)}
    }
    let up=SIMD3(1.0,0,0),side=SIMD3(0.0,1,0)
    let both:[CaseGesture:ClosedCaseFlick]=[.yes:ClosedCaseFlick(axis:up,peak:200),.no:ClosedCaseFlick(axis:side,peak:200)]
    func named(_ events:[ClosedCaseFlickDetector.Event])->[CaseGesture]{events.map{if case .flick(let g,_)=$0{return g};return .doubleTap}}
    guard named(run(motion(3,flick(up,peak:250,half:0.1)),both))==[.yes],named(run(motion(3,flick(up,peak:-300,half:0.08)),both))==[.yes],
          named(run(motion(3,flick(side,peak:300,half:0.12)),both))==[.no] else{throw LessonError.message("A fast flick up and back, or to the side and back, must be a Yes or a No.")}
    guard run(motion(3,flick(up,peak:120,half:0.1)),both).isEmpty else{throw LessonError.message("A slow flick must not count.")}
    guard run(motion(3,flick(up,peak:300,half:0.1,back:0)),both).isEmpty,run(motion(3,flick(up,peak:300,half:0.1,back:0.3)),both).isEmpty else{
        throw LessonError.message("A sweep, or a sweep with a small correction, must not count as a flick.")
    }
    guard run(motion(3,flick(up,peak:300,half:0.015)),both).isEmpty else{throw LessonError.message("A tap’s short twitch must not count as a flick.")}
    guard run(motion(3,flick(up,peak:250,half:0.1,offAxis:SIMD3(0,0,1))),both).isEmpty else{throw LessonError.message("A flick about another axis must not count.")}
    let twice=motion(4){t in flick(up,peak:250,half:0.1)(t)+(t>=1.3 ? flick(up,peak:250,half:0.1,at:1.3)(t)-SIMD3(0.3,-0.2,0.1):.zero)}
    guard run(twice,both).count==1 else{throw LessonError.message("A second flick right after one must not count again.")}
    // The recorded pointing and taps, about many axes: never a flick.
    var recorded=0
    if let fixtures {
        let segments=try loadClosedCaseTapFixtures(fixtures).filter{$0.name=="pointing" || $0.name=="held"}
        var seed:UInt64=7
        func random()->Double{seed=seed&*6364136223846793005&+1442695040888963407;return Double(seed>>11)/Double(1<<53)*2-1}
        for _ in 0..<24 {
            var a=SIMD3(random(),random(),random());a/=length(a)
            var b=SIMD3(random(),random(),random());b-=a*(a*b).sum();b/=length(b)
            let flicks:[CaseGesture:ClosedCaseFlick]=[.yes:ClosedCaseFlick(axis:a,peak:ClosedCaseFlickDetector.defaultPeak),.no:ClosedCaseFlick(axis:b,peak:ClosedCaseFlickDetector.defaultPeak)]
            for segment in segments {
                let rows:[[Double]]=segment.rows.filter{$0[1]==12}.sorted{$0[2]<$1[2]}
                let gyro:[(Double,SIMD3<Double>)]=rows.map{row in (row[2],SIMD3<Double>(row[4],row[5],row[6])*1e-5)}
                let found=run(gyro,flicks)
                guard found.isEmpty else{throw LessonError.message("Recorded \(segment.name) gave a flick about a random axis.")}
            }
        }
        recorded=segments.count
    }
    // Teaching: three flicks along one axis, starting either way, teach it; a stray one is left out.
    var learner=ClosedCaseFlickLearner(),learned:ClosedCaseFlick?,heard:[Int]=[]
    let axis=SIMD3(0.6,0.8,0.0),stray=SIMD3(0.0,0.0,1.0)
    let teach=motion(9){t in
        let plan:[(Double,SIMD3<Double>,Double)]=[(1.0,axis,260.0),(2.5,stray,260.0),(4.0,-axis,240.0),(5.5,axis,300.0)]
        for (start,a,peak) in plan where t>=start && t<=start+0.3{return flick(a,peak:peak,half:0.1,at:start)(t)}
        return SIMD3(0.3,-0.2,0.1)
    }
    for sample in teach{for event in learner.feed(stamp:sample.0,w:sample.1-SIMD3(0.3,-0.2,0.1)){
        if case .flick(let agreeing,_)=event{heard.append(agreeing)}
        if case .learned(let found)=event{learned=found}
    }}
    guard let learned,abs((learned.axis*axis).sum())>0.98,abs(learned.peak-0.6*260)<1,heard.last==3 else{
        throw LessonError.message("Three flicks along one axis must teach it, leaving a stray flick out.")
    }
    var slow=ClosedCaseFlickLearner(),saidSlow=false
    for sample in motion(3,flick(axis,peak:130,half:0.15)){if slow.feed(stamp:sample.0,w:sample.1-SIMD3(0.3,-0.2,0.1)).contains(.tooSlow){saidSlow=true}}
    guard saidSlow else{throw LessonError.message("A flick that’s too slow to learn must say so.")}
    // Double tap: two close taps are one gesture; one tap clicks once its window has passed.
    var gate=ClosedCaseDoubleTap();let a=CGPoint(x:0.2,y:0.3),b=CGPoint(x:0.4,y:0.5)
    guard gate.tap(since:1,point:a,now:10).isEmpty,gate.tap(since:1.2,point:b,now:10.2)==[.double(a)],!gate.waiting,
          gate.tap(since:2,point:a,now:11).isEmpty,gate.expire(now:11.3)==nil,gate.expire(now:11.36)==a,
          gate.tap(since:3,point:a,now:12).isEmpty,gate.tap(since:3.5,point:b,now:12.5)==[.click(a)],gate.waiting else{
        throw LessonError.message("Two quick taps must be one double tap, and a single tap must click after its window.")
    }
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
    return "gestures: flicks up and to the side at 200-300°/s, not slow ones, sweeps, corrections, twitches or other axes\(recorded>0 ? ", none in \(recorded) recorded segments about 24 random axis pairs":""); three flicks teach an axis without a stray one; double tap; cursor glide; actions stored and risky shortcuts refused"
}
