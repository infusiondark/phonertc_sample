import Foundation
import AVFoundation

@objc(PhoneRTCPlugin)
class PhoneRTCPlugin : CDVPlugin {
    var sessions: [String: Session] = [:]
    var peerConnectionFactory: RTCPeerConnectionFactory
    
    var videoConfig: VideoConfig?
    var videoCapturer: RTCVideoCapturer?
    var videoSource: RTCVideoSource?
    var localVideoView: RTCEAGLVideoView?
    var remoteVideoViews: [RTCEAGLVideoView] = []
    
    var localVideoTrack: RTCVideoTrack?
    var localAudioTrack: RTCAudioTrack?
    
    override init(webView: UIWebView) {
        peerConnectionFactory = RTCPeerConnectionFactory()
        RTCPeerConnectionFactory.initializeSSL()
        
        super.init(webView: webView)
    }
    
    func createSessionObject(command: CDVInvokedUrlCommand) {
        let sessionKey = NSUUID().UUIDString
        
        // create session config from the JS params
        let config = SessionConfig(data: command.arguments[0])
        
        // make sure the OK callback is permanent as we
        // use it to send messages to the JS
        let message: AnyObject = [
            "type": "__set_session_key",
            "sessionKey": sessionKey
        ]
        
        let data = NSJSONSerialization.dataWithJSONObject(message,
            options: NSJSONWritingOptions.allZeros,
            error: nil)
       
        sendMessage(command.callbackId, message: data!)
        
        // create a session object and initialize it
        let session = Session(
            plugin: self,
            peerConnectionFactory: peerConnectionFactory,
            config: config,
            callbackId: command.callbackId,
            sessionKey: sessionKey
        )
        
        sessions[sessionKey] = session
    }
    
    func call(command: CDVInvokedUrlCommand) {
        let container: AnyObject = command.arguments[0]
        let sessionKey = container.objectForKey("sessionKey")! as String
   
        dispatch_async(dispatch_get_main_queue()) {
            self.sessions[sessionKey]!.call()
        }
    }
    
    func receiveMessage(command: CDVInvokedUrlCommand) {
        let container: AnyObject = command.arguments[0]
        let sessionKey = container.objectForKey("sessionKey")! as String
        let message = container.objectForKey("message")! as String
        
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0)) {
            self.sessions[sessionKey]!.receiveMessage(message)
        }
    }
    
    func renegotiate(command: CDVInvokedUrlCommand) {
        let container: AnyObject = command.arguments[0]
        let sessionKey = container.objectForKey("sessionKey")! as String
        let config: AnyObject = container.objectForKey("config")!
        
        dispatch_async(dispatch_get_main_queue()) {
            let session = self.sessions[sessionKey]!
            session.config = SessionConfig(data: config)
            session.createOrUpdateStream()
        }
    }
    
    func disconnect(command: CDVInvokedUrlCommand) {
        let container: AnyObject = command.arguments[0]
        let sessionKey = container.objectForKey("sessionKey")! as String

        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0)) {
            if (self.sessions[sessionKey] != nil) {
                self.sessions[sessionKey]!.disconnect(true)
            }
        }
    }
    
    func setVideoView(command: CDVInvokedUrlCommand) {
        let config: AnyObject = command.arguments[0]
        
        dispatch_async(dispatch_get_main_queue()) {
            // create session config from the JS params
            let videoConfig = VideoConfig(data: config)
            
            // make sure that it's not junk
            if videoConfig.container.width == 0 || videoConfig.container.height == 0 {
                return
            }
            
            self.videoConfig = videoConfig
            
            // add local video view
            if self.videoConfig!.local != nil {
                if self.localVideoTrack == nil {
                    self.initLocalVideoTrack()
                }
                
                if self.videoConfig!.local == nil {
                    // remove the local video view if it exists and
                    // the new config doesn't have the `local` property
                    if self.localVideoView != nil {
                        self.localVideoView!.hidden = true
                        self.localVideoView!.removeFromSuperview()
                        self.localVideoView = nil
                    }
                } else {
                    let params = self.videoConfig!.local!
                    
                    // if the local video view already exists, just
                    // change its position according to the new config.
                    if self.localVideoView != nil {
                        self.localVideoView!.frame = CGRectMake(
                            CGFloat(params.x + self.videoConfig!.container.x),
                            CGFloat(params.y + self.videoConfig!.container.y),
                            CGFloat(params.width),
                            CGFloat(params.height)
                        )
                    } else {
                        // otherwise, create the local video view
                        self.localVideoView = self.createVideoView(params: params)
                        self.localVideoView!.videoTrack = self.localVideoTrack!
                    }
                }
                
                self.refreshVideoContainer()
            }
        }
    }
    
    func hideVideoView(command: CDVInvokedUrlCommand) {
        dispatch_async(dispatch_get_main_queue()) {
            self.localVideoView!.hidden = true;
            
            for remoteVideoView in self.remoteVideoViews {
                remoteVideoView.hidden = true;
            }
        }
    }
    
    func showVideoView(command: CDVInvokedUrlCommand) {
        dispatch_async(dispatch_get_main_queue()) {
            self.localVideoView!.hidden = false;
            
            for remoteVideoView in self.remoteVideoViews {
                remoteVideoView.hidden = false;
            } 
        }
    }
    
    func sendMessage(callbackId: String, message: NSData) {
        let json = NSJSONSerialization.JSONObjectWithData(message,
            options: NSJSONReadingOptions.MutableLeaves,
            error: nil) as NSDictionary
        
        let pluginResult = CDVPluginResult(status: CDVCommandStatus_OK, messageAsDictionary: json)
        pluginResult.setKeepCallbackAsBool(true);
        
        self.commandDelegate.sendPluginResult(pluginResult, callbackId:callbackId)
    }
    
    func createVideoView(params: VideoLayoutParams? = nil) -> RTCEAGLVideoView {
        var view: RTCEAGLVideoView
        
        if params != nil {
            let frame = CGRectMake(
                CGFloat(params!.x + self.videoConfig!.container.x),
                CGFloat(params!.y + self.videoConfig!.container.y),
                CGFloat(params!.width),
                CGFloat(params!.height)
            )
            
            view = RTCEAGLVideoView(frame: frame)
        } else {
            view = RTCEAGLVideoView()
        }
        
        view.userInteractionEnabled = false
        
        self.webView.addSubview(view)
        self.webView.bringSubviewToFront(view)
        
        return view
    }
    
    func initLocalAudioTrack() {
        localAudioTrack = peerConnectionFactory.audioTrackWithID("ARDAMSa0")
    }
    
    func initLocalVideoTrack() {
        var cameraID: String?
        for captureDevice in AVCaptureDevice.devicesWithMediaType(AVMediaTypeVideo) {
            // TODO: Make this camera option configurable
            if captureDevice.position == AVCaptureDevicePosition.Front {
                cameraID = captureDevice.localizedName
            }
        }
        
        self.videoCapturer = RTCVideoCapturer(deviceName: cameraID)
        self.videoSource = self.peerConnectionFactory.videoSourceWithCapturer(
            self.videoCapturer,
            constraints: RTCMediaConstraints()
        )
    
        self.localVideoTrack = self.peerConnectionFactory
            .videoTrackWithID("ARDAMSv0", source: self.videoSource)
    }
    
    func addRemoteVideoTrack(videoTrack: RTCVideoTrack) {
        if self.videoConfig == nil {
            return
        }
        
        // add a video view without position/size as it will get
        // resized and re-positioned in refreshVideoContainer
        let videoView = createVideoView()
        
        videoView.videoTrack = videoTrack
        self.remoteVideoViews.append(videoView)
        
        refreshVideoContainer()
        
        if self.localVideoView != nil {
            self.webView.bringSubviewToFront(self.localVideoView!)
        }
    }
    
    func removeRemoteVideoTrack(videoTrack: RTCVideoTrack) {
        dispatch_async(dispatch_get_main_queue()) {
            for var i = 0; i < self.remoteVideoViews.count; i++ {
                let videoView = self.remoteVideoViews[i]
                if videoView.videoTrack == videoTrack {
                    videoView.hidden = true
                    videoView.removeFromSuperview()
                    self.remoteVideoViews.removeAtIndex(i)
                    self.refreshVideoContainer()
                    return
                }
            }
        }
    }
    
    func refreshVideoContainer() {
        let n = self.remoteVideoViews.count
        
        if n == 0 {
            return
        }
        
        let rows = n < 9 ? 2 : 3
        let videosInRow = n == 2 ? 2 : Int(ceil(Float(n) / Float(rows)))
        
        let videoSize = Int(Float(self.videoConfig!.container.width) / Float(videosInRow))
        let actualRows = Int(ceil(Float(n) / Float(videosInRow)))
 
        var y = getCenter(actualRows,
            videoSize: videoSize,
            containerSize: self.videoConfig!.container.height)
                + self.videoConfig!.container.y
      
        var videoViewIndex = 0
        
        for var row = 0; row < rows && videoViewIndex < n; row++ {
            var x = getCenter(row < row - 1 || n % rows == 0 ?
                                videosInRow : n - (min(n, videoViewIndex + videosInRow) - 1),
                videoSize: videoSize,
                containerSize: self.videoConfig!.container.width)
                    + self.videoConfig!.container.x
            
            for var video = 0; video < videosInRow && videoViewIndex < n; video++ {
                let videoView = self.remoteVideoViews[videoViewIndex++]
                videoView.frame = CGRectMake(
                    CGFloat(x),
                    CGFloat(y),
                    CGFloat(videoSize),
                    CGFloat(videoSize)
                )

                x += Int(videoSize)
            }
            
            y += Int(videoSize)
        }
    }
    
    func getCenter(videoCount: Int, videoSize: Int, containerSize: Int) -> Int {
        return lroundf(Float(containerSize - videoSize * videoCount) / 2.0)
    }
    
    func onSessionDisconnect(sessionKey: String) {
        self.sessions.removeValueForKey(sessionKey)
        
        if self.sessions.count == 0 {
            dispatch_sync(dispatch_get_main_queue()) {
                if self.localVideoView != nil {
                    self.localVideoView!.hidden = true
                    self.localVideoView!.removeFromSuperview()
                
                    self.localVideoView = nil
                }
            }
            
            self.localVideoTrack = nil
            self.localAudioTrack = nil
            
            self.videoSource = nil
            self.videoCapturer = nil
        }
    }
}