//
//  VideoFrameDecoder.swift
//  ImprovedCubeCamera
//
//  Created by PHILIP SHEN on 3/19/18.
//  Copyright © 2018 PHILIP SHEN. All rights reserved.
//

import Foundation
import VideoToolbox

typealias FrameData = Array<UInt8>

protocol VideoFrameDecoderDelegate {
    func receivedDisplayableFrame(_ frame: CVPixelBuffer)
}

class VideoFrameDecoder {
    
    static var delegate: VideoFrameDecoderDelegate?
    
    private var formatDesc: CMVideoFormatDescription?
    private var decompressionSession: VTDecompressionSession?
    
    /*
     Ideally, whoever calls this function would be returned the displayable frame.
     Still figuring that one out. In the meantime this stuff works.
     */
    func interpretRawFrameData(_ frameData: inout FrameData) {
        var naluType = frameData[4] & 0x1F
        if naluType != 7 && formatDesc == nil { return }
        
        // Replace start code with the size
        var frameSize = CFSwapInt32HostToBig(UInt32(frameData.count - 4))
        memcpy(&frameData, &frameSize, 4)
        
        // The start indices for nested packets. Default to 0.
        var ppsStartIndex = 0
        var frameStartIndex = 0
        
        var sps: Array<UInt8>?
        var pps: Array<UInt8>?
        
        /*
         Generally, SPS, PPS, and IDR frames from the camera will come packaged together
         while B/P frames will come individually. For the sake of flexibility this code
         does not reflect this bitstream format specifically.
         */
        
        // SPS parameters
        if naluType == 7 {
            print("===== NALU type SPS")
            for i in 4..<40 {
                if frameData[i] == 0 && frameData[i+1] == 0 && frameData[i+2] == 0 && frameData[i+3] == 1 {
                    ppsStartIndex = i // Includes the start header
                    sps = Array(frameData[4..<i])
                    
                    // Set naluType to the nested packet's NALU type
                    naluType = frameData[i + 4] & 0x1F
                    break
                }
            }
        }
        
        // PPS parameters
        if naluType == 8 {
            print("===== NALU type PPS")
            for i in ppsStartIndex+4..<ppsStartIndex+34 {
                if frameData[i] == 0 && frameData[i+1] == 0 && frameData[i+2] == 0 && frameData[i+3] == 1 {
                    frameStartIndex = i
                    pps = Array(frameData[ppsStartIndex+4..<i])
                    
                    // Set naluType to the nested packet's NALU type
                    naluType = frameData[i+4] & 0x1F
                    break
                }
            }
            
            if sps != nil && pps != nil {
                if !createFormatDescription(sps: sps!, pps: pps!) {
                    print("===== ===== Failed to create formatDesc")
                    return
                }
                if !createDecompressionSession() {
                    print("===== ===== Failed to create decompressionSession")
                    return
                }
            }
        }
        
        if (naluType == 1 || naluType == 5) && decompressionSession != nil {
            print("===== NALU type \(naluType)")
            // If this is successful, the callback will be called
            // The callback will send the decoded, decompressed frame to the delegate
            decodeFrameData(Array(frameData[frameStartIndex...]))
        }
    }
    
    private func decodeFrameData(_ frameData: FrameData) {
        let bufferPointer = UnsafeMutablePointer<UInt8>(mutating: frameData)
        
        // Replace the start code with the size of the NALU
        var frameSize = CFSwapInt32HostToBig(UInt32(frameData.count - 4))
        memcpy(bufferPointer, &frameSize, 4)
        
        var outputBuffer: CVPixelBuffer?
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                                        memoryBlock: bufferPointer,
                                                        blockLength: frameData.count,
                                                        blockAllocator: kCFAllocatorNull,
                                                        customBlockSource: nil, offsetToData: 0, dataLength: frameData.count,
                                                        flags: 0, blockBufferOut: &blockBuffer)
        
        if status != kCMBlockBufferNoErr { return }
        
        var sampleBuffer: CMSampleBuffer?
        let sampleSizeArray = [frameData.count]
        
        status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault,
                                           dataBuffer: blockBuffer,
                                           formatDescription: formatDesc,
                                           sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                                           sampleSizeEntryCount: 1, sampleSizeArray: sampleSizeArray,
                                           sampleBufferOut: &sampleBuffer)
        
        if let buffer = sampleBuffer, status == kCMBlockBufferNoErr {
            let attachments: CFArray? = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true)
            
            if let attachmentsArray = attachments {
                let dic = unsafeBitCast(CFArrayGetValueAtIndex(attachmentsArray, 0), to: CFMutableDictionary.self)
                
                CFDictionarySetValue(dic,
                                     Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
                
                // Decompress
                var flagOut = VTDecodeInfoFlags(rawValue: 0)
                status = VTDecompressionSessionDecodeFrame(decompressionSession!, sampleBuffer: buffer,
                                                           flags: [], frameRefcon: &outputBuffer, infoFlagsOut: &flagOut)
                
                /* The "CMSampleBuffer" can be returned here and passed to an AVSampleBufferDisplayLayer.
                 I tried it and the picture was ugly. Instead I decompress with VideoToolbox and then
                 display the resultant CVPixelLayer. Looks great.
                 */
            }
        }
    }
    
    private func createFormatDescription(sps: [UInt8], pps: [UInt8]) -> Bool {
        formatDesc = nil
        
        let pointerSPS = UnsafePointer<UInt8>(sps)
        let pointerPPS = UnsafePointer<UInt8>(pps)
        
        let dataParamArray = [pointerSPS, pointerPPS]
        let parameterSetPointers = UnsafePointer<UnsafePointer<UInt8>>(dataParamArray)
        
        let sizeParamArray = [sps.count, pps.count]
        let parameterSetSizes = UnsafePointer<Int>(sizeParamArray)
        
        let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: parameterSetPointers, parameterSetSizes: parameterSetSizes, nalUnitHeaderLength: 4, formatDescriptionOut: &formatDesc)
        
        return status == noErr
    }
    
    private func createDecompressionSession() -> Bool {
        guard let desc = formatDesc else { return false }
        
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
        }
        
        let decoderParameters = NSMutableDictionary()
        let destinationPixelBufferAttributes = NSMutableDictionary()
        
        var outputCallback = VTDecompressionOutputCallbackRecord()
        outputCallback.decompressionOutputCallback = callback
        outputCallback.decompressionOutputRefCon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        
        let status = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault,
                                                  formatDescription: desc, decoderSpecification: decoderParameters,
                                                  imageBufferAttributes: destinationPixelBufferAttributes,outputCallback: &outputCallback,
                                                  decompressionSessionOut: &decompressionSession)
        
        if status == noErr {
            return true
        } else {
            return false
        }
    }
    
    private var callback: VTDecompressionOutputCallback = {(
        decompressionOutputRefCon: UnsafeMutableRawPointer?,
        sourceFrameRefCon: UnsafeMutableRawPointer?,
        status: OSStatus,
        infoFlags: VTDecodeInfoFlags,
        imageBuffer: CVPixelBuffer?,
        presentationTimeStamp: CMTime,
        duration: CMTime) in
        let decoder: VideoFrameDecoder = Unmanaged<VideoFrameDecoder>.fromOpaque(decompressionOutputRefCon!).takeUnretainedValue()
        if imageBuffer != nil && status == noErr {
            print("===== Image successfully decompressed")
            decoder.imageDecompressed(image: imageBuffer!)
        } else {
            print("===== Failed to decompress. VT Error \(status)")
        }
    }
    
    private func imageDecompressed(image: CVPixelBuffer) {
        VideoFrameDecoder.delegate?.receivedDisplayableFrame(image)
    }
    
}
