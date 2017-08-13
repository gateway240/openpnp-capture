#include "platformdeviceinfo.h"
#include "platformstream.h"
#include "platformcontext.h"
#include <Accelerate/Accelerate.h>

// **********************************************************************
//   ObjC++ callback handler implementation
// **********************************************************************

@implementation PlatformAVCaptureDelegate
- (void)captureOutput:(AVCaptureOutput *)out
        didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer
        fromConnection:(AVCaptureConnection *)connection
{
	//UNUSED_PARAMETER(out);
	//UNUSED_PARAMETER(sampleBuffer);
	//UNUSED_PARAMETER(connection);
}

- (void)captureOutput:(AVCaptureOutput *)captureOutput
        didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
        fromConnection:(AVCaptureConnection *)connection
{
	//UNUSED_PARAMETER(captureOutput);
	//UNUSED_PARAMETER(connection);

    // check the number of samples/frames
	CMItemCount count = CMSampleBufferGetNumSamples(sampleBuffer);
	if (count < 1)
    {
		return;
    }

    // sanity check on the stream pointer
    if (m_stream != nullptr)
    {
        CMFormatDescriptionRef desc = CMSampleBufferGetFormatDescription(sampleBuffer);
        FourCharCode fourcc = CMFormatDescriptionGetMediaSubType(desc);
        CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(desc);

        #if 0
        // generate 4cc string
        char fourCCString[5];
        for(uint32_t i=0; i<4; i++)
        {
            fourCCString[i] = static_cast<char>(fourcc & 0xFF);
            fourcc >>= 8;
        }
        fourCCString[4] = 0;
        LOG(LOG_DEBUG, "%d x %d %s\n", dims.width, dims.height, fourCCString);
        #endif


        // https://stackoverflow.com/questions/34569750/get-pixel-value-from-cvpixelbufferref-in-swift
        // get lock to pixel buffer so we can read the actual frame buffer data
        CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
        if (CVPixelBufferLockBaseAddress(pixelBuffer, 0) == kCVReturnSuccess)
        {
            const uint8_t *pixelPtr = static_cast<const uint8_t*>(CVPixelBufferGetBaseAddress(pixelBuffer));
            uint32_t frameBytes = CVPixelBufferGetHeight(pixelBuffer) *
                  CVPixelBufferGetBytesPerRow(pixelBuffer);

            m_stream->callback(pixelPtr, frameBytes);

            CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
        }
    }

#if 0
	CMItemCount count = CMSampleBufferGetNumSamples(sampleBuffer);
	if (count < 1 || !capture)
		return;

	obs_source_frame *frame = &capture->frame;

	CMTime target_pts =
		CMSampleBufferGetOutputPresentationTimeStamp(sampleBuffer);
	CMTime target_pts_nano = CMTimeConvertScale(target_pts, NANO_TIMESCALE,
			kCMTimeRoundingMethod_Default);
	frame->timestamp = target_pts_nano.value;

	if (!update_frame(capture, frame, sampleBuffer)) {
		obs_source_output_video(capture->source, nullptr);
		return;
	}

	obs_source_output_video(capture->source, frame);

	CVImageBufferRef img = CMSampleBufferGetImageBuffer(sampleBuffer);
	CVPixelBufferUnlockBaseAddress(img, kCVPixelBufferLock_ReadOnly);
#endif
}

@end


// **********************************************************************
//   PlatformStream implementation
// **********************************************************************

Stream* createPlatformStream()
{
    return new PlatformStream();
}

PlatformStream::PlatformStream() :
    Stream()
{
    m_nativeSession = nullptr;
}

PlatformStream::~PlatformStream()
{
    close();
}

void PlatformStream::close()
{
    LOG(LOG_INFO, "closing stream\n");
    
    if (m_nativeSession != nullptr)
    {
        [m_nativeSession stopRunning];
        //FIXME: how do we handle deallocation of objc++ 
        //       objects? 
        m_nativeSession = nullptr;
    }

    m_isOpen = false;
}

bool PlatformStream::open(Context *owner, deviceInfo *device, uint32_t width, uint32_t height, uint32_t fourCC)
{
    if (m_isOpen)
    {
        LOG(LOG_INFO,"open() was called on an active stream.\n");
        close();
    }

    if (owner == nullptr)
    {
        LOG(LOG_ERR,"open() was with owner=NULL!\n");        
        return false;
    }

    if (device == nullptr)
    {
        LOG(LOG_ERR,"open() was with device=NULL!\n");
        return false;
    }

    platformDeviceInfo *dinfo = dynamic_cast<platformDeviceInfo*>(device);
    if (dinfo == NULL)
    {
        LOG(LOG_CRIT, "Could not cast deviceInfo* to platfromDeviceInfo*!\n");
        return false;
    }

    if (dinfo->m_captureDevice == nullptr)
    {
        LOG(LOG_CRIT, "m_captureDevice is a NULL pointer!\n");
        return false;        
    }

    // get a pointer to the native OBJC device.
    AVCaptureDevice* nativeDevice = (__bridge AVCaptureDevice*) (void*) dinfo->m_captureDevice;

    // create a new session manager and open a capture session
    m_nativeSession = [AVCaptureSession new];

    NSError* error = nil;
    AVCaptureDeviceInput* input = [AVCaptureDeviceInput deviceInputWithDevice:nativeDevice error:&error];
    if (!input) 
    {
        LOG(LOG_ERR, "Error opening native device %s\n", error.localizedDescription.UTF8String);
        return false;
    }

    // add the device to the session object
    // it seems this must go before everything else!
    [m_nativeSession addInput:input];

    LOG(LOG_DEBUG, "Setup for capture format (%d x %d)...\n", width, height);

    //[nativeDevice lockForConfiguration];
    AVCaptureDeviceFormat *bestFormat = nil;
    for(uint32_t i=0; i<dinfo->m_platformFormats.size(); i++)
    {
        CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(dinfo->m_platformFormats[i].formatDescription);
        if ((dims.width == width) && (dims.height == height))
        {
            // check fourCC
            uint32_t myFourCC = CMFormatDescriptionGetMediaSubType(dinfo->m_platformFormats[i].formatDescription);
            if (myFourCC == fourCC)
            {
                bestFormat = dinfo->m_platformFormats[i];
            }
        } 
    }

    if (bestFormat == nil)
    {
        LOG(LOG_ERR,"could not find a suitable format\n");
        return false;
    }
    
    //FIXME: error checking..
    [nativeDevice lockForConfiguration:NULL];
    nativeDevice.activeFormat = bestFormat;
    
    m_width = width;
    m_height = height;
    m_owner = owner;
    m_frameBuffer.resize(m_width*m_height*3);
    m_tmpBuffer.resize(m_width*m_height*3);

    AVCaptureVideoDataOutput* output = [AVCaptureVideoDataOutput new];
    [m_nativeSession addOutput:output];
    output.videoSettings = nil;

#if 0
    //auto myFormat = nativeDevice.activeFormat.formatDescription;
    //NSLog(@"%@", myFormat);

    //for (NSString *key in [myFormat allKeys]) 
    //{
        //NSString *v = [output.videoSettings objectForKey:key];
        //LOG(LOG_DEBUG,"key: %s %s\n", key.UTF8String, v.UTF8String);
        //NSLog(@"%@",[myFormat objectForKey:key]);
    //}

    // dump all video settings
    LOG(LOG_DEBUG,"Dumping videoSettings:\n");
    for (NSString *key in [output.videoSettings allKeys]) 
    {
        //NSString *v = [output.videoSettings objectForKey:key];
        //LOG(LOG_DEBUG,"key: %s %s\n", key.UTF8String, v.UTF8String);
        NSLog(@"%@",[output.videoSettings objectForKey:key]);
    }

    output.videoSettings = [NSDictionary dictionaryWithObjectsAndKeys:
        [output.videoSettings objectForKey:AVVideoCodecKey], AVVideoCodecKey,
        [NSNumber numberWithUnsignedInt:kCVPixelFormatType_32BGRA], (id)kCVPixelBufferPixelFormatTypeKey,
        //[NSNumber numberWithInt:width], AVVideoWidthKey,
        //[NSNumber numberWithInt:height], AVVideoHeightKey,
        //[NSNumber numberWithUnsignedInt:width], AVVideoWidthKey,
        //[NSNumber numberWithUnsignedInt:height], AVVideoHeightKey,
         nil];

#endif

    output.videoSettings = [NSDictionary dictionaryWithObjectsAndKeys:
        [NSNumber numberWithUnsignedInt:kCVPixelFormatType_32ARGB], (id)kCVPixelBufferPixelFormatTypeKey,
        nil];

    // discard data if the output queue is blocked
    [output setAlwaysDiscardsLateVideoFrames:true];

    // a serial dispatch queue must be used to guarantee that video frames will be delivered in order
    m_queue = dispatch_queue_create("VideoDataOutputQueue", DISPATCH_QUEUE_SERIAL);

    // create the callback handling delegate
    m_captureDelegate = [PlatformAVCaptureDelegate new];
    if (m_captureDelegate == nullptr)
    {
        LOG(LOG_ERR, "cannot create PlatformAVCaptureDelegate\n.");
        return false;
    }

    // register the stream with the callback delegate so it can be
    // called throug the stream->callback() method 
    m_captureDelegate->m_stream = this;
    [output setSampleBufferDelegate:m_captureDelegate queue:m_queue];

    // start capturing
    [m_nativeSession startRunning];

    // unlock must be after startRunning call
    // otherwise the session object will
    // override our settings :-/
    [nativeDevice unlockForConfiguration];

    m_isOpen = true;
    m_frames = 0; // reset the frame counter
    return true;
}

uint32_t PlatformStream::getFOURCC()
{
    return 0;
}

std::string PlatformStream::genFOURCCstring(uint32_t v)
{
    std::string result;
    for(uint32_t i=0; i<4; i++)
    {
        result += static_cast<char>(v & 0xFF);
        v >>= 8;
    }
    return result;
}

/** get the limits of a camera/stream property (exposure, zoom etc) */
bool PlatformStream::getPropertyLimits(uint32_t propID, int32_t *min, int32_t *max)
{
    return false;
}

/** set property (exposure, zoom etc) of camera/stream */
bool PlatformStream::setProperty(uint32_t propID, int32_t value)
{
    return false;
}

/** set automatic state of property (exposure, zoom etc) of camera/stream */
bool PlatformStream::setAutoProperty(uint32_t propID, bool enabled)
{
    return false;
}

void PlatformStream::callback(const uint8_t *ptr, uint32_t bytes)
{
    // here we get 32-bit ARGB buffers, which we need to
    // convert to 24-bit RGB buffers
    
    if (m_tmpBuffer.size() != (m_width*m_height*3))
    {
        // error: temporary buffer is not the right size!
        return;
    }

    vImage_Buffer src;
    vImage_Buffer dst;
    src.data = (void*)ptr;  // fugly
    src.width = m_width;
    src.height = m_height;
    src.rowBytes = m_width*4;
    dst.data = &m_tmpBuffer[0];
    dst.width = m_width;
    dst.height = m_height;
    dst.rowBytes = m_width*3;

    vImageConvert_ARGB8888toRGB888(&src, &dst, 0);
    submitBuffer(&m_tmpBuffer[0], m_tmpBuffer.size());
}
