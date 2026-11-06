import Foundation
import CoreMotion

// Bring-up probe for AirPods 5 (--headphone-motion-probe SECONDS): does macOS's own headphone
// motion API stream gravity and user acceleration from these earbuds, and does it keep streaming
// with them in the case? Writes headphone-motion.log beside the app's other data. No pointer, no clicks.
final class HeadphoneMotionProbe:NSObject,CMHeadphoneMotionManagerDelegate {
    private let manager=CMHeadphoneMotionManager()
    private let log:FileHandle
    private var count=0,second=0,inSecond=0,last:CMDeviceMotion?
    private let started=Date()
    init(log:FileHandle){self.log=log}
    func write(_ line:String){
        let stamp=String(format:"%7.3f ",Date().timeIntervalSince(started))
        try? log.write(contentsOf:Data((stamp+line+"\n").utf8));print(stamp+line)
    }
    func run(seconds:Double){
        write("authorization=\(CMHeadphoneMotionManager.authorizationStatus().rawValue) (0 not determined, 1 restricted, 2 denied, 3 authorized)")
        write("deviceMotionAvailable=\(manager.isDeviceMotionAvailable)")
        manager.delegate=self
        manager.startDeviceMotionUpdates(to:.main){[weak self] motion,error in
            guard let self else{return}
            if let error{self.write("error: \(error.localizedDescription)");return}
            guard let motion else{return}
            self.count+=1;self.inSecond+=1;self.last=motion
            let s=Int(Date().timeIntervalSince(self.started))
            if s != self.second{self.summary(motion);self.second=s;self.inSecond=0}
        }
        let until=Date().addingTimeInterval(seconds)
        while Date()<until{RunLoop.main.run(until:Date().addingTimeInterval(0.1))}
        manager.stopDeviceMotionUpdates()
        write("done: \(count) samples in \(Int(seconds)) s")
    }
    private func summary(_ m:CMDeviceMotion){
        let g=m.gravity,a=m.userAcceleration,r=m.rotationRate,q=m.attitude.quaternion
        write(String(format:"rate=%d/s gravity=(%.3f %.3f %.3f) userAccel=(%.3f %.3f %.3f) rotation=(%.2f %.2f %.2f) rad/s q=(%.3f %.3f %.3f %.3f) location=%d",
                     inSecond,g.x,g.y,g.z,a.x,a.y,a.z,r.x,r.y,r.z,q.w,q.x,q.y,q.z,m.sensorLocation.rawValue))
    }
    func headphoneMotionManagerDidConnect(_ manager:CMHeadphoneMotionManager){write("headphones connected")}
    func headphoneMotionManagerDidDisconnect(_ manager:CMHeadphoneMotionManager){write("headphones disconnected")}
}

func runHeadphoneMotionProbe(seconds:Double){
    let url=airPointerDataFolder.appendingPathComponent("headphone-motion.log")
    try? FileManager.default.createDirectory(at:airPointerDataFolder,withIntermediateDirectories:true)
    FileManager.default.createFile(atPath:url.path,contents:nil)
    guard let handle=try? FileHandle(forWritingTo:url) else{fputs("Couldn't open \(url.path)\n",stderr);exit(1)}
    HeadphoneMotionProbe(log:handle).run(seconds:seconds)
    try? handle.close()
}
