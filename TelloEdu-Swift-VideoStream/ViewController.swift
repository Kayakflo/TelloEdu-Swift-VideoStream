//
//  ViewController.swift
//  TelloEdu-Swift-VideoStream
//
//  Created by Florian Kriegel on 07.06.19.
//  Copyright © 2019 Florian Kriegel. All rights reserved.
//

import UIKit
import SwiftSocket
import VideoToolbox

class ViewController: UIViewController, VideoFrameDecoderDelegate {
    var commandClient: UDPClient!
    var streamServer: UDPServer!
    var frameDecoder: VideoFrameDecoder!
    var isConnected = false

    @IBOutlet weak var videoView: UIImageView!
    @IBOutlet weak var startBtn: UIButton!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        VideoFrameDecoder.delegate = self
        frameDecoder = VideoFrameDecoder()
    }

    @IBAction func startBtn(_ sender: Any) {
        if isConnected {
            isConnected = !isConnected
            disconnect()
            startBtn.setTitle("Connect & Start Video Stream", for: .normal)
        } else {
            isConnected = !isConnected
            connect()
            startStreamServer()
            startBtn.setTitle("Disconnect & Stop Video Stream", for: .normal)
        }
    }
    
    func connect() {
        commandClient = UDPClient(address: "192.168.10.1", port: 8889)
        commandClient.send(string: "command")
        commandClient.send(string: "streamon")
    }
    
    func startStreamServer() {
        streamServer = UDPServer(address: "0.0.0.0", port: 11111)
        DispatchQueue.global(qos: .userInteractive).async {
            var currentImg: [Byte] = []
            while self.isConnected {
                let (data, remoteip, remoteport) = self.streamServer.recv(2048)
                if let d = data {
                    currentImg = currentImg + d
                    
                    if d.count < 1460 && currentImg.count > 40 {
                        self.frameDecoder.interpretRawFrameData(&currentImg)
                        currentImg = []
                    }
                }
            }
        }
    }
    
    func disconnect() {
        commandClient.send(string: "streamoff")

        commandClient.close()
        streamServer.close()

        commandClient = nil
        streamServer = nil
    }
    
    internal func receivedDisplayableFrame(_ frame: CVPixelBuffer) {
        var cgImage: CGImage?
        VTCreateCGImageFromCVPixelBuffer(frame, options: nil, imageOut: &cgImage)
        
        if let cgImage = cgImage {
            DispatchQueue.main.async {
                self.videoView.image = UIImage(cgImage: cgImage)
            }
        } else {
            print("Fail")
        }
    }
}

