import AppKit
import Carbon

// What the closed case can do besides point, each mapped in Settings ▸ Gestures: a tap (a click unless mapped
// to something else), a double tap, and flicks up, down, left and right, each taught by the person who flicks
// it. All but the tap do nothing until given an action.
enum CaseGesture:String,CaseIterable {
    case tap,doubleTap,flickUp,flickDown,flickLeft,flickRight
    var title:String {
        switch self {
        case .tap:return "Tap";case .doubleTap:return "Double tap"
        case .flickUp:return "Flick up";case .flickDown:return "Flick down";case .flickLeft:return "Flick left";case .flickRight:return "Flick right"
        }
    }
    // For buttons and sheet titles: "Teach Flick Up".
    var name:String{title.split(separator:" ").map{$0.prefix(1).uppercased()+$0.dropFirst()}.joined(separator:" ")}
    var symbol:String {
        switch self {
        case .tap,.doubleTap:return "hand.tap"
        case .flickUp:return "arrow.up";case .flickDown:return "arrow.down";case .flickLeft:return "arrow.left";case .flickRight:return "arrow.right"
        }
    }
    // The way a flick goes, for captions and the teaching sheet.
    var way:String{switch self{case .flickUp:return "up";case .flickDown:return "down";case .flickLeft:return "left";case .flickRight:return "right";default:return ""}}
    // What it does with nothing chosen: a tap clicks, the rest do nothing.
    var standard:GestureAction{self == .tap ? .click:.nothing}
    static let flicks:[CaseGesture]=[.flickUp,.flickDown,.flickLeft,.flickRight]
}

// MARK: - Flicks

private func length(_ v:SIMD3<Double>)->Double{(v*v).sum().squareRoot()}

// One burst of turning: from just before the case turns at 60°/s or more until it has stayed under that for
// 80 ms. A flick is one burst, but so is a quick aim, a tap or a fidget, which is why flicks are taught: each
// person's flick has its own shape (a small wind-up the other way, a fast snap, a slower return, or a fast way
// out and back), and one rule for everyone recognised under a third of real ones.
struct ClosedCaseBurst {
    var samples:[(t:Double,w:SIMD3<Double>)]
    // Longer than any flick: never one.
    var long=false
    var since:Double{samples.first?.t ?? 0}
    var duration:Double{(samples.last?.t ?? 0)-since}
    var peak:Double{samples.map{length($0.w)}.max() ?? 0}
}

struct ClosedCaseBurstCutter {
    static let onset=60.0,preroll=0.04,quietFor=0.08,longest=1.2,maximumGap=0.1,rise=120.0
    // The burst so far, or the moment before one.
    private(set) var samples:[(t:Double,w:SIMD3<Double>)]=[]
    private(set) var active=false,peak=0.0
    // When the speed last rose past 120°/s: where a fast part began.
    private(set) var rose:Double?
    private var last:Double?,quietSince:Double?,below=true,long=false
    mutating func reset(){self=ClosedCaseBurstCutter()}
    // `w` has the gyro's resting offset taken out (°/s); `t` is in seconds. A burst comes back once it has ended.
    mutating func feed(t:Double,w:SIMD3<Double>)->ClosedCaseBurst? {
        guard t.isFinite,w.x.isFinite,w.y.isFinite,w.z.isFinite else{return nil}
        if let last,t<=last{return nil}
        if let last,t-last>Self.maximumGap{reset()}
        last=t
        let speed=length(w)
        if speed<Self.rise{below=true}else if below{below=false;rose=t}
        guard active else{
            samples.append((t,w));while let first=samples.first,t-first.t>Self.preroll{samples.removeFirst()}
            if speed>=Self.onset{active=true;peak=speed;quietSince=nil;long=false}
            return nil
        }
        if !long{samples.append((t,w))}
        peak=max(peak,speed)
        if let first=samples.first,t-first.t>Self.longest{long=true}
        guard speed<Self.onset else{quietSince=nil;return nil}
        quietSince=quietSince ?? t
        guard let quietSince,t-quietSince>=Self.quietFor else{return nil}
        var burst=samples
        while burst.count>2,let end=burst.last,length(end.w)<Self.onset{burst.removeLast()}
        let ended=ClosedCaseBurst(samples:burst,long:long)
        active=false;samples=[];peak=0;self.quietSince=nil;long=false
        return ended
    }
}

// One example of a flick: its burst evenly resampled to 24 points and divided by its peak, so a quicker or
// gentler flick of the same shape matches; its peak and length are kept to judge speed and size apart.
struct ClosedCaseFlickExample:Equatable {
    static let points=24
    var shape:[SIMD3<Double>],peak:Double,duration:Double
    init?(_ burst:ClosedCaseBurst) {
        let samples=burst.samples,peak=burst.peak
        guard samples.count>=2,peak>0,burst.duration>0 else{return nil}
        let start=burst.since,span=burst.duration
        var shape:[SIMD3<Double>]=[],j=0
        for k in 0..<Self.points {
            let t=start+span*Double(k)/Double(Self.points-1)
            while j<samples.count-2,samples[j+1].t<t{j+=1}
            let a=samples[j],b=samples[j+1],u=b.t<=a.t ? 0:min(1,max(0,(t-a.t)/(b.t-a.t)))
            shape.append((a.w+(b.w-a.w)*u)/peak)
        }
        self.shape=shape;self.peak=peak;self.duration=span
    }
    init(shape:[SIMD3<Double>],peak:Double,duration:Double){self.shape=shape;self.peak=peak;self.duration=duration}
    // Saved as peak, length, then the points' x, y and z.
    var stored:[Double]{[peak,duration]+shape.flatMap{[$0.x,$0.y,$0.z]}}
    init?(stored:[Double]) {
        guard stored.count==2+3*Self.points,stored.allSatisfy(\.isFinite),stored[0]>0,stored[1]>0 else{return nil}
        peak=stored[0];duration=stored[1]
        shape=(0..<Self.points).map{SIMD3(stored[2+3*$0],stored[3+3*$0],stored[4+3*$0])}
    }
    // Dynamic time warping: the mean gap between the two shapes along the best way of lining them up, each point
    // matched within 30% of the length of where it'd be. 0 is the same shape; the person's own flicks of one kind
    // come out 0.1–0.2 apart, other flicks and aiming 0.3 or more.
    static func distance(_ a:[SIMD3<Double>],_ b:[SIMD3<Double>])->Double {
        let n=a.count,m=b.count
        guard n>0,m>0 else{return .infinity}
        let band=max(Int((0.3*Double(max(n,m))).rounded()),abs(n-m)),width=m+1
        var cost=[Double](repeating:.infinity,count:(n+1)*width),steps=[Int](repeating:0,count:(n+1)*width)
        cost[0]=0
        for i in 1...n {
            let low=max(1,i-band),high=min(m,i+band)
            guard low<=high else{continue}
            for j in low...high {
                var best=cost[(i-1)*width+j-1],count=steps[(i-1)*width+j-1]
                for (c,s) in [(cost[(i-1)*width+j],steps[(i-1)*width+j]),(cost[i*width+j-1],steps[i*width+j-1])] where c<best || (c==best && s<count){best=c;count=s}
                cost[i*width+j]=best+length(a[i-1]-b[j-1]);steps[i*width+j]=count+1
            }
        }
        let end=n*width+m
        return steps[end]>0 ? cost[end]/Double(steps[end]):.infinity
    }
}

// A taught flick: the person's examples, how fast a burst must be to be one (55% of their gentlest, and at
// least 200°/s; aiming rarely turns faster), how long (half the shortest to twice the longest), and how close
// its shape must come to one of them: 1.5 times as far as the examples are from each other, between 0.18 and
// 0.28.
struct ClosedCaseFlickTemplate:Equatable {
    static let lowestTrigger=200.0,triggerShare=0.55,closest=0.18,farthest=0.28,spread=1.5
    let examples:[ClosedCaseFlickExample],reach:Double
    init?(examples:[ClosedCaseFlickExample]) {
        guard examples.count>=2 else{return nil}
        let nearest=examples.indices.map{i in examples.indices.filter{$0 != i}.map{ClosedCaseFlickExample.distance(examples[i].shape,examples[$0].shape)}.min() ?? .infinity}
        guard let widest=nearest.max(),widest.isFinite else{return nil}
        self.examples=examples;reach=min(Self.farthest,max(Self.closest,Self.spread*widest))
    }
    var trigger:Double{max(Self.lowestTrigger,Self.triggerShare*(examples.map(\.peak).min() ?? 0))}
    var durations:ClosedRange<Double>{0.5*(examples.map(\.duration).min() ?? 0)...2*(examples.map(\.duration).max() ?? 0)}
    func distance(_ example:ClosedCaseFlickExample)->Double{examples.map{ClosedCaseFlickExample.distance(example.shape,$0.shape)}.min() ?? .infinity}
    func fits(_ example:ClosedCaseFlickExample)->Bool{example.peak>=trigger && durations.contains(example.duration)}
    var stored:[[Double]]{examples.map(\.stored)}
    init?(stored:[[Double]]?) {
        guard let stored else{return nil}
        let examples=stored.compactMap{ClosedCaseFlickExample(stored:$0)}
        guard examples.count==stored.count else{return nil}
        self.init(examples:examples)
    }
}

// Finds taught flicks in the gyro. While a burst turns faster than 300°/s (or the gentlest taught flick's bar,
// if higher) it says so, so the pointer can hold still through what may be a flick; once the burst ends it is
// the flick whose shape it comes closest to, if it's fast and long enough for that flick, within its reach,
// and clearly closer to it than to any other (at most 80% as far). Over 56 s of recorded pointing, 21 s of
// holding and the recorded lid closes, nothing counts.
struct ClosedCaseFlickRecognizer {
    enum Event:Equatable{case fast(since:Double),flick(CaseGesture,since:Double,distance:Double),none(since:Double,reason:String)}
    static let holdSpeed=300.0,clearly=0.8,shortest=0.08
    var templates:[CaseGesture:ClosedCaseFlickTemplate]=[:]
    private var cutter=ClosedCaseBurstCutter(),warned=false
    mutating func reset(){cutter.reset();warned=false}
    private var holdAbove:Double{max(Self.holdSpeed,templates.values.map(\.trigger).min() ?? Self.holdSpeed)}
    // `stamp` is the sensor's microseconds.
    mutating func feed(stamp:Double,w:SIMD3<Double>)->[Event] {
        guard !templates.isEmpty else{return []}
        var events:[Event]=[]
        let ended=cutter.feed(t:stamp*1e-6,w:w)
        if cutter.active,!warned,cutter.peak>=holdAbove{warned=true;events.append(.fast(since:cutter.rose ?? cutter.samples.first?.t ?? stamp*1e-6))}
        guard let burst=ended else{return events}
        let held=warned;warned=false
        guard held || burst.peak>=(templates.values.map(\.trigger).min() ?? .infinity) else{return events}
        let found=Self.match(burst,among:templates)
        if let gesture=found.gesture{events.append(.flick(gesture,since:burst.since,distance:found.distance))}
        else{events.append(.none(since:burst.since,reason:found.reason))}
        return events
    }
    // The taught flick a burst is, with how far its shape was from it, or why it's none. With `anySpeed`, as
    // when teaching another flick, only the shape counts.
    static func match(_ burst:ClosedCaseBurst,among templates:[CaseGesture:ClosedCaseFlickTemplate],anySpeed:Bool=false)->(gesture:CaseGesture?,distance:Double,reason:String) {
        if burst.long{return (nil,.infinity,"longer than \(ClosedCaseBurstCutter.longest) s")}
        guard burst.duration>=shortest,let example=ClosedCaseFlickExample(burst) else{return (nil,.infinity,String(format:"too short, %.2f s",burst.duration))}
        let distances=templates.map{(gesture:$0.key,distance:$0.value.distance(example))}.sorted{$0.distance<$1.distance}
        guard let best=distances.first(where:{anySpeed || templates[$0.gesture]?.fits(example)==true}),let template=templates[best.gesture] else{
            return (nil,distances.first?.distance ?? .infinity,String(format:"too slow or the wrong length for any flick: %.0f°/s, %.2f s",example.peak,example.duration))
        }
        if best.distance>template.reach{return (nil,best.distance,String(format:"%@ but not close enough, %.2f (reach %.2f)",best.gesture.title,best.distance,template.reach))}
        if let other=distances.first(where:{$0.gesture != best.gesture}),best.distance>Self.clearly*other.distance {
            return (nil,best.distance,String(format:"between %@ (%.2f) and %@ (%.2f)",best.gesture.title,best.distance,other.gesture.title,other.distance))
        }
        return (best.gesture,best.distance,"")
    }
}

// Teaching one flick: four bursts that agree (each within 0.35 of another, all linked) make it. Each burst
// that joins the largest agreeing group fills a dot; one that doesn't says so. A burst too gentle (under
// 200°/s), too long, or shaped like another taught flick doesn't count. After 12 bursts without four
// agreeing, it gives up.
struct ClosedCaseFlickTeacher {
    enum Event:Equatable{case heard(Int),tooSlow,tooLong,different,sameAs(CaseGesture),learned(ClosedCaseFlickTemplate),failed}
    static let flicks=4,mostTries=12,agree=0.35,bar=200.0,gentle=100.0,kept=6
    let gesture:CaseGesture,others:[CaseGesture:ClosedCaseFlickTemplate]
    private var cutter=ClosedCaseBurstCutter(),candidates:[ClosedCaseFlickExample]=[],heard=0,done=false
    init(gesture:CaseGesture,others:[CaseGesture:ClosedCaseFlickTemplate]=[:]){self.gesture=gesture;self.others=others.filter{$0.key != gesture}}
    mutating func feed(stamp:Double,w:SIMD3<Double>)->[Event] {
        guard !done,let burst=cutter.feed(t:stamp*1e-6,w:w) else{return []}
        guard burst.peak>=Self.bar else{return burst.peak>=Self.gentle ? [.tooSlow]:[]}
        if burst.long{return [.tooLong]}
        guard burst.duration>=ClosedCaseFlickRecognizer.shortest,let example=ClosedCaseFlickExample(burst) else{return []}
        if !others.isEmpty,let same=ClosedCaseFlickRecognizer.match(burst,among:others,anySpeed:true).gesture{return [.sameAs(same)]}
        candidates.append(example)
        let group=Self.largestGroup(candidates)
        var events:[Event]=[]
        if group.count>heard{heard=group.count;events.append(.heard(heard))}else{events.append(.different)}
        if group.count>=Self.flicks,let template=ClosedCaseFlickTemplate(examples:group.prefix(Self.kept).map{candidates[$0]}) {
            done=true;events.append(.learned(template))
        } else if candidates.count>=Self.mostTries{done=true;events.append(.failed)}
        return events
    }
    // The largest set of examples linked by pairs within `agree`, in the order they came.
    static func largestGroup(_ examples:[ClosedCaseFlickExample])->[Int] {
        let n=examples.count
        var near=[[Int]](repeating:[],count:n)
        for i in 0..<n{for j in i+1..<max(i+1,n) where ClosedCaseFlickExample.distance(examples[i].shape,examples[j].shape)<=agree{near[i].append(j);near[j].append(i)}}
        var seen=Set<Int>(),best:[Int]=[]
        for i in 0..<n where !seen.contains(i) {
            var group=[i],k=0;seen.insert(i)
            while k<group.count{for j in near[group[k]] where !seen.contains(j){seen.insert(j);group.append(j)};k+=1}
            if group.count>best.count{best=group.sorted()}
        }
        return best
    }
}

// Keeps the pointer where a click or a flick left it, and every edge in reach. A tap turns the case a few
// degrees (about 5°, some 200 px), so once the pointer is let go it would jump to where the case now points;
// instead the difference is kept as an offset that fades only as the person moves, half as fast as the pointer
// moves, so it's gone once they've moved twice as far, and never while they hold still. A flick's turn is
// another matter: the gyro loses track of some of it (Bluetooth drops samples at 1000°/s), so after a flick
// the pointer carries on from where it was, for good, rather than drift toward wherever the lost turn says.
// That, and the gyro's slow drift, would leave an edge out of reach, so pushing past an edge at an aiming
// pace moves the aim with it, as a mouse does at the edge of its pad; a fast swing past one doesn't, so a
// quick turn out and back lands where it started. The pace is the fastest of the last moment (fading over
// 0.2 s), since a swing stands still for an instant where it turns back.
struct ClosedCasePointerAnchor {
    static let catchUp=0.5,slipBelow=1.0,slipAbove=3.0,paceFade=0.2
    // `offset` fades as the person moves; `base` stays.
    private(set) var offset=CGVector.zero,base=CGVector.zero
    private var last:CGPoint?,lastTime:Double?,pace=Double.infinity
    // `aim` is where the case points now; the pointer stays at `point`. `keep`: from now on, not fading.
    mutating func anchor(_ aim:CGPoint,at point:CGPoint,keep:Bool=false) {
        if keep{base=CGVector(dx:point.x-aim.x,dy:point.y-aim.y);offset = .zero}
        else{offset=CGVector(dx:point.x-aim.x-base.dx,dy:point.y-aim.y-base.dy)}
        last=aim
    }
    mutating func reset(){offset = .zero;base = .zero;last=nil;lastTime=nil;pace = .infinity}
    // `aim` may lie past the screen's edges (0…1), where the case points beyond them; `time` in seconds.
    mutating func apply(_ aim:CGPoint,at time:Double)->CGPoint {
        defer{last=aim;lastTime=time}
        if let last {
            let moved=hypot(aim.x-last.x,aim.y-last.y),size=hypot(offset.dx,offset.dy)
            if size>0{let keep=max(0,1-Self.catchUp*moved/size);offset.dx*=keep;offset.dy*=keep}
            if let lastTime,time>lastTime{
                let speed=moved/(time-lastTime)
                pace=pace.isFinite ? max(speed,pace*exp(-(time-lastTime)/Self.paceFade)):speed
            }
        }
        // Past an edge: at an aiming pace (screens a second) all of the overshoot moves the aim, none when swinging fast.
        let slip=min(1,max(0,(Self.slipAbove-pace)/(Self.slipAbove-Self.slipBelow)))
        func slide(_ excess:Double,_ offset:inout CGFloat,_ base:inout CGFloat) {
            var excess=excess*slip
            guard excess != 0 else{return}
            if offset*excess>0{let taken=abs(offset)<abs(excess) ? offset:excess;offset-=taken;excess-=taken}
            base-=excess
        }
        let x=aim.x+base.dx+offset.dx,y=aim.y+base.dy+offset.dy
        slide(x>1 ? x-1:x<0 ? x:0,&offset.dx,&base.dx)
        slide(y>1 ? y-1:y<0 ? y:0,&offset.dy,&base.dy)
        return CGPoint(x:min(1,max(0,aim.x+base.dx+offset.dx)),y:min(1,max(0,aim.y+base.dy+offset.dy)))
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

// The cursor's own motion, one frame per display refresh (ClosedCaseCursorOutput). Bluetooth brings the gyro in
// bursts, usually 20 ms apart but one gap in ten over 50 ms and some up to 150 ms, so a cursor that follows each
// burst as it lands stalls and then lurches. Instead every sample's point goes on a track in the sensor's own
// time, and each frame shows the track 40 ms behind the newest sample that could have arrived by then: what the
// hand did, at the pace it did it. The Mac's clock less the sensor's is the least delay seen over the last 5 s,
// eased so frames never skip or repeat. When a sample is later than 40 ms the track carries on at its recent
// speed, for up to 60 ms; whatever that guessed wrong, and any point rewritten after it was shown (a tap holding
// the pointer where it began), fades out over 60 ms. A deliberate change of course (a flick's return, a new
// calibration, the first aim once pointing starts) glides over 180 ms, slow at both ends. On recorded pointing
// that is half the frame-to-frame jerk of following bursts, and a fifth of the stalled frames.
struct ClosedCaseCursorTimeline {
    static let delay=0.04,ahead=0.06,settle=0.06,blend=0.18,keep=1.5,offsetSpan=5.0,speedSpan=0.05,ease=0.05
    // Where the cursor shows now, after the last frame.
    private(set) var shown:CGPoint?
    private var track:[(t:Double,point:CGPoint)]=[],offsets:[(host:Double,offset:Double)]=[]
    private var offset:Double?,lastFrame:Double?,lastS:Double?,lastTarget:CGPoint?
    private var carry=CGVector.zero,blendCarry=CGVector.zero,blendFrom = -Double.infinity,blendNext=false,blendAt:Double?,blendOnAdd=false
    // `t` is the sample's sensor time and `host` when it arrived, both in seconds.
    mutating func add(_ point:CGPoint,at t:Double,arrived host:Double) {
        guard point.x.isFinite,point.y.isFinite,t.isFinite,host.isFinite,t>(track.last?.t ?? -.infinity) else{return}
        // A glide from the next sample starts as soon as the frame passes the one before, so no part of the step shows.
        if blendOnAdd{blendOnAdd=false;blendAt=track.last?.t ?? t}
        track.append((t,point))
        let lag=host-t
        while let newest=offsets.last,newest.offset>=lag{offsets.removeLast()}
        offsets.append((host,lag))
        while offsets.count>1,let oldest=offsets.first,host-oldest.host>Self.offsetSpan{offsets.removeFirst()}
        if let first=track.first,t-first.t>2*Self.keep{track.removeFirst(track.firstIndex{t-$0.t<=Self.keep} ?? 0)}
    }
    // Every point from `t` on is `point` now: a hold heard after it began. `glide`: go there over 180 ms.
    mutating func rewrite(from t:Double,to point:CGPoint,glide:Bool) {
        var index=track.count-1
        while index>=0,track[index].t>=t{track[index].point=point;index-=1}
        if glide{blendNext=true}
    }
    // The next frame glides from where the cursor shows to the track; `fromNext`: once the next sample added shows.
    mutating func glide(fromNext:Bool=false){if fromNext{blendOnAdd=true}else{blendNext=true}}
    // What's on the track no longer holds (recentering, a new calibration): the new track glides in.
    mutating func reset(){track=[];lastS=nil;lastTarget=nil;carry = .zero;blendNext=true}
    // The cursor is at `point` (where pointing starts from, where a click put it): it glides on from there.
    mutating func place(_ point:CGPoint){shown=point;blendNext=true}
    private func estimate(_ s:Double)->CGPoint? {
        guard let newest=track.last,let oldest=track.first else{return nil}
        if s<=oldest.t{return oldest.point}
        if s<=newest.t {
            var low=0,high=track.count-1
            while high-low>1{let mid=(low+high)/2;if track[mid].t<s{low=mid}else{high=mid}}
            let a=track[low],b=track[high],u=b.t>a.t ? (s-a.t)/(b.t-a.t):1
            return CGPoint(x:a.point.x+(b.point.x-a.point.x)*u,y:a.point.y+(b.point.y-a.point.y)*u)
        }
        let from=track.last{newest.t-$0.t>=Self.speedSpan} ?? oldest
        guard newest.t>from.t else{return newest.point}
        let ahead=min(s-newest.t,Self.ahead)/(newest.t-from.t)
        return CGPoint(x:newest.point.x+(newest.point.x-from.point.x)*ahead,y:newest.point.y+(newest.point.y-from.point.y)*ahead)
    }
    mutating func step(at now:Double)->CGPoint? {
        guard let floor=offsets.first?.offset else{return shown}
        let dt=lastFrame.map{max(0,now-$0)} ?? 0
        let eased=offset.map{$0+max(-Self.ease*dt,min(Self.ease*dt,floor-$0))} ?? floor
        offset=eased
        let s=now-eased-Self.delay
        guard let target=estimate(s) else{return shown}
        let fade=exp(-dt/Self.settle)
        if let blendAt,s>=blendAt{self.blendAt=nil;blendNext=true}
        if blendNext {
            blendNext=false
            carry=CGVector(dx:carry.dx*fade,dy:carry.dy*fade)
            let from=shown ?? target
            blendCarry=CGVector(dx:from.x-target.x-carry.dx,dy:from.y-target.y-carry.dy);blendFrom=now
        } else if let lastS,let lastTarget,let redo=estimate(lastS) {
            carry=CGVector(dx:(carry.dx+lastTarget.x-redo.x)*fade,dy:(carry.dy+lastTarget.y-redo.y)*fade)
        }
        let u=min(1,max(0,(now-blendFrom)/Self.blend)),left=1-u*u*(3-2*u)
        if u>=1{blendCarry = .zero}
        let out=CGPoint(x:min(1,max(0,target.x+carry.dx+blendCarry.dx*left)),y:min(1,max(0,target.y+carry.dy+blendCarry.dy*left)))
        shown=out;lastS=s;lastTarget=target;lastFrame=now
        return out
    }
}

// Moves the cursor once per refresh of the pointer's display (60 Hz here, 120 Hz on ProMotion), from a display
// link on its own thread, so a busy main thread never holds it up and every frame shows one more frame of the
// timeline. The session adds to it from the main thread; the lock keeps the two apart. Without a display link, the
// session's 5 ms timer steps it instead.
final class ClosedCaseCursorOutput:NSObject {
    private let lock=NSLock()
    private var timeline=ClosedCaseCursorTimeline(),bounds:CGRect?,postUntil=0.0
    private var link:CADisplayLink?,display:CGDirectDisplayID?,loop:RunLoop?,frameCount=0
    var linked:Bool{link != nil}
    // Frames stepped so far, for the session log's rate.
    var frames:Int{lock.lock();defer{lock.unlock()};return frameCount}
    func with<T>(_ body:(inout ClosedCaseCursorTimeline)->T)->T{lock.lock();defer{lock.unlock()};return body(&timeline)}
    var shown:CGPoint?{with{$0.shown}}
    // Main thread, every tick: which screen, where it is, and until when to move the cursor (nil bounds: don't).
    func configure(screen:NSScreen?,bounds:CGRect?,postUntil:Double) {
        lock.lock();self.bounds=bounds;self.postUntil=postUntil;lock.unlock()
        let next=(screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map{CGDirectDisplayID($0.uint32Value)}
        guard next != display else{return}
        display=next;link?.invalidate();link=nil
        guard let screen,let loop=runLoop() else{return}
        let created=screen.displayLink(target:self,selector:#selector(refresh(_:)))
        created.add(to:loop,forMode:.common);link=created
    }
    func stop(){display=nil;link?.invalidate();link=nil}
    // The display link's thread, started once and kept for the session's life.
    private func runLoop()->RunLoop? {
        if let loop{return loop}
        let ready=DispatchSemaphore(value:0);var found:RunLoop?
        let thread=Thread{
            found=RunLoop.current
            RunLoop.current.add(NSMachPort(),forMode:.default)
            ready.signal()
            while true{RunLoop.current.run(mode:.default,before:.distantFuture)}
        }
        thread.name="AirPointer cursor";thread.qualityOfService = .userInteractive;thread.start()
        ready.wait();loop=found
        return found
    }
    @objc private func refresh(_ link:CADisplayLink){frame(at:ProcessInfo.processInfo.systemUptime)}
    // One frame of the timeline, posted as a mouse move.
    func frame(at now:Double) {
        lock.lock()
        let point=timeline.step(at:now),post=now<postUntil ? bounds:nil
        frameCount+=1
        lock.unlock()
        if let point,let post{CGEvent(mouseEventSource:nil,mouseType:.mouseMoved,mouseCursorPosition:screenPoint(point,bounds:post),mouseButton:.left)?.post(tap:.cghidEventTap)}
    }
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
    typealias Plan=(start:Double,axis:SIMD3<Double>,peak:Double,half:Double)
    // Gyro at 200 Hz: each planned swing is half a sine of that peak and length about its axis; still otherwise.
    func motion(_ seconds:Double,_ plan:[Plan])->[(Double,SIMD3<Double>)] {
        (0..<Int(seconds*200)).map{i in
            let t=Double(i)*0.005
            var w=SIMD3<Double>.zero
            for swing in plan where t>=swing.start && t<=swing.start+swing.half{w+=swing.axis*(swing.peak*sin(Double.pi*(t-swing.start)/swing.half))}
            return (1e9+t*1e6,w)
        }
    }
    // A flick: fast out, slower back; with a wind-up, first a small slow swing the other way.
    func flick(_ axis:SIMD3<Double>,at:Double,peak:Double=600,windUp:Bool=false)->[Plan] {
        let start=windUp ? at+0.12:at
        return (windUp ? [(at,-axis,0.3*peak,0.12)]:[])+[(start,axis,peak,0.14),(start+0.14,-axis,0.6*peak,0.22)]
    }
    func teach(_ gesture:CaseGesture,_ samples:[(Double,SIMD3<Double>)],others:[CaseGesture:ClosedCaseFlickTemplate]=[:])->(events:[ClosedCaseFlickTeacher.Event],template:ClosedCaseFlickTemplate?,at:Double?) {
        var teacher=ClosedCaseFlickTeacher(gesture:gesture,others:others),events:[ClosedCaseFlickTeacher.Event]=[],template:ClosedCaseFlickTemplate?,at:Double?
        for (stamp,w) in samples{for event in teacher.feed(stamp:stamp,w:w){events.append(event);if case .learned(let found)=event{template=found;at=stamp}}}
        return (events,template,at)
    }
    func heard(_ events:[ClosedCaseFlickTeacher.Event])->[Int]{events.compactMap{if case .heard(let n)=$0{return n};return nil}}
    func run(_ samples:[(Double,SIMD3<Double>)],_ templates:[CaseGesture:ClosedCaseFlickTemplate])->[ClosedCaseFlickRecognizer.Event] {
        var recognizer=ClosedCaseFlickRecognizer();recognizer.templates=templates
        return samples.flatMap{recognizer.feed(stamp:$0.0,w:$0.1)}
    }
    func found(_ events:[ClosedCaseFlickRecognizer.Event])->[CaseGesture]{events.compactMap{if case .flick(let g,_,_)=$0{return g};return nil}}
    let up=SIMD3(1.0,0,0),side=SIMD3(0.0,1,0)
    let kinds:[(CaseGesture,SIMD3<Double>,Bool)]=[(.flickUp,up,false),(.flickDown,-up,false),(.flickLeft,side,true),(.flickRight,-side,true)]
    // Four flicks a little different each time teach it, a dot each; each flick knows the others.
    func four(_ axis:SIMD3<Double>,_ windUp:Bool)->[Plan]{[520.0,600,680,560].enumerated().flatMap{flick(axis,at:0.5+Double($0.offset)*0.9,peak:$0.element,windUp:windUp)}}
    var taught:[CaseGesture:ClosedCaseFlickTemplate]=[:]
    for (gesture,axis,windUp) in kinds {
        let lesson=teach(gesture,motion(4.5,four(axis,windUp)),others:taught)
        guard let template=lesson.template,heard(lesson.events)==[1,2,3,4] else{
            throw LessonError.message("Four flicks must teach \(gesture.title), a dot each: \(lesson.events).")
        }
        guard ClosedCaseFlickTemplate(stored:template.stored)==template else{throw LessonError.message("A taught flick must round-trip.")}
        taught[gesture]=template
    }
    // Each is itself, flicked at another speed, and not any other.
    for (gesture,axis,windUp) in kinds {
        let events=run(motion(2,flick(axis,at:0.5,peak:640,windUp:windUp)),taught)
        guard found(events)==[gesture] else{throw LessonError.message("A \(gesture.title.lowercased()) must be recognised as one: \(events).")}
    }
    // Before it's recognised, a burst turning fast says so, from when its fast part began, so the pointer can
    // hold from there; the flick then says when its burst began, wind-up and all.
    let told=run(motion(2,flick(-side,at:0.5,peak:640,windUp:true)),taught)
    guard case .fast(let fastSince)?=told.first,fastSince>1e3+0.6,fastSince<1e3+0.7,
          case .flick(.flickRight,let since,_)?=told.last,since<1e3+0.5,since>1e3+0.45 else{
        throw LessonError.message("A held-through flick must say it's fast, from where its fast part began, then when it began: \(told).")
    }
    guard found(run(motion(2,flick(up,at:0.5,peak:150)),taught)).isEmpty else{throw LessonError.message("A slow flick must not count.")}
    guard found(run(motion(2,[(0.5,up,500,0.25)]),taught)).isEmpty else{throw LessonError.message("One swing with no swing back must not count.")}
    guard found(run(motion(2,flick((up+side)/2.0.squareRoot(),at:0.5)),taught)).isEmpty else{throw LessonError.message("A flick between two taught ways must count as neither.")}
    guard found(run(motion(4,(0..<4).flatMap{flick(up,at:0.5+Double($0)*0.3)}),taught)).isEmpty else{
        throw LessonError.message("Flicking on and on without a pause is one long burst, and must not count.")
    }
    // Teaching: a flick shaped like another taught one is turned down, a stray one fills no dot, a gentle one says so.
    let same=teach(.flickLeft,motion(4.5,four(up,false)),others:taught.filter{$0.key == .flickUp})
    guard same.template==nil,same.events.contains(.sameAs(.flickUp)) else{throw LessonError.message("Teaching a flick like another must say which: \(same.events).")}
    let stray=teach(.flickUp,motion(6,flick(up,at:0.5)+flick(side,at:1.4,windUp:true)+flick(up,at:2.4,peak:560)+flick(up,at:3.3,peak:650)+flick(up,at:4.2,peak:520)))
    guard stray.template != nil,heard(stray.events)==[1,2,3,4],stray.events.contains(.different) else{
        throw LessonError.message("A stray flick while teaching must fill no dot, and the rest still teach it: \(stray.events).")
    }
    guard teach(.flickUp,motion(2,flick(up,at:0.5,peak:150))).events.contains(.tooSlow) else{throw LessonError.message("A flick too gentle to learn must say so.")}
    var detail="flicks: each of four taught from four of the person's own, recognised at other speeds as itself and nothing else; not slow, one-way, in-between or endless ones; teaching refuses one like another"
    if let fixtures {
        // Real flicks (Tests/FlickFixtures.csv): taught from the first four of each, the rest are themselves.
        let recorded=try loadClosedCaseTapFixtures(fixtures.deletingLastPathComponent().appendingPathComponent("FlickFixtures.csv"))
        let rest=SIMD3(0.215,0.907,0.232)
        func gyro(_ name:String)throws->[(Double,SIMD3<Double>)] {
            guard let segment=recorded.first(where:{$0.name==name}) else{throw LessonError.message("The \(name) fixture is missing.")}
            return segment.rows.sorted{$0[2]<$1[2]}.map{($0[2],SIMD3($0[4],$0[5],$0[6])*1e-5-rest)}
        }
        let ups=try gyro("flickUp"),downs=try gyro("flickDown"),more=try gyro("flickDownAgain")
        let upLesson=teach(.flickUp,ups),downLesson=teach(.flickDown,downs,others:upLesson.template.map{[.flickUp:$0]} ?? [:])
        guard let upTaught=upLesson.template,let downTaught=downLesson.template,let upAt=upLesson.at,let downAt=downLesson.at else{
            throw LessonError.message("Real flicks must teach up and down: \(upLesson.events), \(downLesson.events).")
        }
        let real:[CaseGesture:ClosedCaseFlickTemplate]=[.flickUp:upTaught,.flickDown:downTaught]
        let laterUps=found(run(ups.filter{$0.0>upAt},real)),laterDowns=found(run(downs.filter{$0.0>downAt},real)+run(more,real))
        guard !laterUps.isEmpty,laterUps.allSatisfy({$0 == .flickUp}),laterDowns.count>=7,laterDowns.allSatisfy({$0 == .flickDown}) else{
            throw LessonError.message("Real flicks after teaching must be themselves: up \(laterUps), down \(laterDowns).")
        }
        // Recorded pointing, holding and closing the lid: never a flick, whichever are taught.
        for segment in try loadClosedCaseTapFixtures(fixtures).filter({["pointing","held","lidclose"].contains($0.name)}) {
            let samples=segment.rows.filter{$0[1]==12}.sorted{$0[2]<$1[2]}.map{($0[2],SIMD3($0[4],$0[5],$0[6])*1e-5)}
            for templates in [real,taught] where !found(run(samples,templates)).isEmpty{throw LessonError.message("Recorded \(segment.name) gave a flick: \(run(samples,templates)).")}
        }
        detail+=String(format:"; real flicks taught from four, then %d more up and %d down each themselves; none in recorded pointing, holding or lid closes",laterUps.count,laterDowns.count)
    }
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
    // After a flick the pointer carries on from where it was, for good.
    var kept=ClosedCasePointerAnchor();kept.anchor(CGPoint(x:0.6,y:0.5),at:CGPoint(x:0.5,y:0.5),keep:true)
    var carried=CGPoint.zero
    for i in 0...100{carried=kept.apply(CGPoint(x:0.6,y:0.5+0.002*Double(i)),at:Double(i)*0.005)}
    guard abs(carried.x-0.5)<1e-9,abs(carried.y-0.7)<1e-9 else{throw LessonError.message("After a flick the pointer must carry on from where it was: \(carried).")}
    // Pushing past an edge at an aiming pace moves the aim along (here 0.15 past it, at half a screen a
    // second), so coming back leaves the edge at once; a fast swing past it and back lands where it started.
    for i in 0...260{carried=kept.apply(CGPoint(x:0.6+0.0025*Double(i),y:0.7),at:1+Double(i)*0.005)}
    guard abs(carried.x-1)<1e-9,abs(kept.base.dx+0.25)<1e-6 else{throw LessonError.message("Pushing past an edge must reach it and move the aim along: \(carried), \(kept.base).")}
    for i in 1...20{carried=kept.apply(CGPoint(x:1.25-0.005*Double(i),y:0.7),at:3+Double(i)*0.005)}
    guard abs(carried.x-0.9)<1e-6 else{throw LessonError.message("Coming back from past an edge must leave it at once: \(carried).")}
    var swung=ClosedCasePointerAnchor();var swing=CGPoint.zero
    let out=(0...20).map{0.5+0.04*Double($0)}
    for (i,x) in (out+out.reversed()).enumerated(){swing=swung.apply(CGPoint(x:x,y:0.5),at:Double(i)*0.005)}
    guard abs(swing.x-0.5)<1e-9,swung.base == .zero else{throw LessonError.message("A fast swing past an edge and back must land where it started: \(swing).")}
    // The timeline: samples every 5 ms of a steady sweep, delivered in bursts as Bluetooth does (a few at a time,
    // sometimes 15 at once after a 70 ms wait), play back at 60 Hz in even steps, with no stalls.
    func frames(_ timeline:inout ClosedCaseCursorTimeline,from start:Double,count:Int)->[CGPoint]{(1...count).compactMap{timeline.step(at:start+Double($0)/60)}}
    var even=ClosedCaseCursorTimeline(),pending:[(t:Double,point:CGPoint,host:Double)]=[],burstSizes=[2,3,4,15,3,1,8,3,4,2,12,3],shownPath:[CGPoint]=[]
    var index=0,size=0
    for k in 0..<600 {
        let t=100+Double(k)*0.005,point=CGPoint(x:0.1+0.3*Double(k)*0.005,y:0.5)
        size+=1;let burst=burstSizes[index%burstSizes.count]
        pending.append((t,point,0))
        if size>=burst{let arrived=t+0.004;for i in pending.count-size..<pending.count{pending[i].host=arrived};index+=1;size=0}
    }
    var next=0
    for frame in 0..<150 {
        let now=100.2+Double(frame)/60
        while next<pending.count,pending[next].host>0,pending[next].host<=now{even.add(pending[next].point,at:pending[next].t,arrived:pending[next].host);next+=1}
        if let point=even.step(at:now),frame>=20{shownPath.append(point)}
    }
    let stepsX=zip(shownPath,shownPath.dropFirst()).map{$1.x-$0.x},ideal=0.3/60
    guard stepsX.count>100,stepsX.allSatisfy({abs($0-ideal)<0.35*ideal}) else{
        throw LessonError.message("Bursty samples must play back in even steps: \(stepsX.map{String(format:"%.4f",$0)}).")
    }
    // A hold heard 20 ms after it began (a tap) never shows the twitch it held through.
    var tapped=ClosedCaseCursorTimeline(),most=0.0
    for k in 0..<240 {
        let t=200+Double(k)*0.005,twitch=k>=120 ? 0.05*min(1,Double(k-120)/8):0
        // Until the tap is heard the twitch goes on the track; from then on the session adds where it holds.
        tapped.add(CGPoint(x:k<=124 ? 0.5+twitch:0.5,y:0.5),at:t,arrived:t+0.002)
        if k==124{tapped.rewrite(from:200.6,to:CGPoint(x:0.5,y:0.5),glide:false)}
        if k%3==0{most=max(most,tapped.step(at:t+0.002)?.x ?? 0)}
    }
    guard most<0.5+1e-6 else{throw LessonError.message("A tap's twitch must never show: the cursor reached \(most).")}
    // Moving across the screen (recentering, a flick's return) glides over 180 ms at 60 Hz, with no frame's step
    // much bigger than its neighbours', starting and ending slowly.
    var across=ClosedCaseCursorTimeline()
    for k in 0..<10{across.add(CGPoint(x:0.1,y:0.5),at:300+Double(k)*0.005,arrived:300.05)}
    _=across.step(at:300.1);across.reset()
    for k in 0..<200{across.add(CGPoint(x:0.9,y:0.5),at:300.05+Double(k)*0.005,arrived:300.055+Double(k)*0.005)}
    let path=[CGPoint(x:0.1,y:0.5)]+frames(&across,from:300.1,count:15),steps=zip(path,path.dropFirst()).map{$1.x-$0.x}
    guard steps.allSatisfy({$0 >= -1e-9}),steps.max() ?? 1<0.15,steps.first ?? 1<0.05,abs((path.last?.x ?? 0)-0.9)<1e-6,
          zip(steps,steps.dropFirst()).allSatisfy({abs($1-$0)<0.06}) else{
        throw LessonError.message("Moving across the screen must glide, not jump: \(steps.map{String(format:"%.3f",$0)}).")
    }
    // Letting go of a hold glides from the next sample on, however late that sample shows.
    var letGo=ClosedCaseCursorTimeline(),biggest=0.0,previous:CGPoint?
    for k in 0..<160 {
        let t=400+Double(k)*0.005
        if k==60{letGo.glide(fromNext:true)}
        letGo.add(CGPoint(x:k<60 ? 0.3:0.7,y:0.5),at:t,arrived:t+0.002)
        if k%3==0,let point=letGo.step(at:t+0.002){if let previous{biggest=max(biggest,abs(point.x-previous.x))};previous=point}
    }
    guard biggest<0.06,abs((previous?.x ?? 0)-0.7)<1e-6 else{throw LessonError.message("Letting go of a hold must glide: a step of \(biggest).")}
    // Pointing starts from where the system cursor is and glides on from there.
    var placed=ClosedCaseCursorTimeline()
    for k in 0..<60{placed.add(CGPoint(x:0.5,y:0.5),at:500+Double(k)*0.005,arrived:500.005+Double(k)*0.005)}
    placed.place(CGPoint(x:0.2,y:0.2))
    guard let first=placed.step(at:500.15),first.x<0.25,let last=frames(&placed,from:500.15,count:14).last,abs(last.x-0.5)<1e-6 else{
        throw LessonError.message("Pointing must start from where the cursor is and glide to the aim.")
    }
    // The display link steps the cursor once per refresh of the screen, at 60 Hz or more, without posting here.
    if let screen=NSScreen.main {
        let output=ClosedCaseCursorOutput()
        output.configure(screen:screen,bounds:nil,postUntil:0)
        let began=Date();while Date().timeIntervalSince(began)<0.5{RunLoop.current.run(until:Date().addingTimeInterval(0.05))}
        let rate=Double(output.frames)/0.5;output.stop()
        guard output.frames>0,rate>=50,rate<=260 else{throw LessonError.message("The cursor must step once per display refresh, at 60 Hz or more: \(rate) Hz.")}
        detail+=String(format:"; cursor steps at %.0f Hz with the display",rate)
    }
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
    return "gestures: "+detail+"; double tap; the pointer stays where it clicked until moved and where a flick left it, and pushing past an edge moves the aim along; bursty samples play back evenly at 60 Hz, a tap\u{2019}s twitch never shows, and changes of course glide; actions stored and risky shortcuts refused"
}
