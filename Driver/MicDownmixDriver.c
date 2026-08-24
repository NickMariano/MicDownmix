//==================================================================================================
//  MicDownmixDriver.c
//
//  An AudioServerPlugIn that publishes a single virtual device, "MicDownmix".
//
//  The device is a loopback: whatever is written to its output stream appears on its input
//  stream. The MicDownmix menu bar app is the writer; Discord (or anything else) is the reader.
//
//  The streams' physical format is 16-bit signed integer, mono, 48 kHz. The virtual format is
//  32-bit float. The HAL performs the scalar conversion between the two, which is a per-sample
//  operation on a mono stream and involves no channel map inference. All multi-channel work
//  happens in the app, by hand, before any sample reaches this driver.
//==================================================================================================

#include <CoreAudio/AudioServerPlugIn.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <string.h>

//==================================================================================================
#pragma mark Configuration
//==================================================================================================

#define kDevice_Name            "MicDownmix"
#define kDevice_Manufacturer    "StealthPyro"
#define kDevice_UID             "com.stealthpyro.MicDownmix.device"
#define kDevice_ModelUID        "com.stealthpyro.MicDownmix.model"
#define kBox_UID                "com.stealthpyro.MicDownmix.box"
#define kPlugIn_BundleID        "com.stealthpyro.MicDownmix.driver"

// The rates the device offers. The app sets the virtual device to whatever the source interface runs
// at, so both ends agree and nothing has to resample. Restricting this to 48 kHz meant anyone whose
// interface could not do 48 kHz simply could not use the app.
#define kSampleRateCount        7
static const Float64 kSampleRates[kSampleRateCount] = {
    16000.0, 22050.0, 32000.0, 44100.0, 48000.0, 88200.0, 96000.0
};
#define kDefaultSampleRate      48000.0
#define kChannelCount           1
#define kBitsPerSample          16
#define kBytesPerFrame          (kChannelCount * (kBitsPerSample / 8))

// One second of audio. Also the zero timestamp period.
#define kRingFrames             48000
#define kRingSamples            (kRingFrames * kChannelCount)

//==================================================================================================
#pragma mark Object IDs
//==================================================================================================

enum
{
    kObjectID_PlugIn            = kAudioObjectPlugInObject,
    kObjectID_Box               = 2,
    kObjectID_Device            = 3,
    kObjectID_Stream_Input      = 4,
    kObjectID_Stream_Output     = 5
};

//==================================================================================================
#pragma mark State
//==================================================================================================

static pthread_mutex_t  gPlugIn_StateMutex      = PTHREAD_MUTEX_INITIALIZER;
static UInt32           gPlugIn_RefCount        = 0;
static AudioServerPlugInHostRef gPlugIn_Host    = NULL;

static bool             gBox_Acquired           = true;

static Float64          gDevice_SampleRate      = kDefaultSampleRate;
static UInt64           gDevice_IOIsRunning     = 0;
static Float64          gDevice_HostTicksPerFrame = 0.0;
static UInt64           gDevice_NumberTimeStamps = 0;
static UInt64           gDevice_AnchorHostTime  = 0;

static bool             gStream_Input_IsActive  = true;
static bool             gStream_Output_IsActive = true;

// The loopback ring. Written by WriteMix, read by ReadInput, in the physical (Int16) format.
static int16_t          gRingBuffer[kRingSamples];

//==================================================================================================
#pragma mark Prototypes
//==================================================================================================

static HRESULT  MicDownmix_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface);
static ULONG    MicDownmix_AddRef(void* inDriver);
static ULONG    MicDownmix_Release(void* inDriver);

static OSStatus MicDownmix_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus MicDownmix_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID);
static OSStatus MicDownmix_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
static OSStatus MicDownmix_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus MicDownmix_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus MicDownmix_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo);
static OSStatus MicDownmix_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo);

static Boolean  MicDownmix_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID, const AudioObjectPropertyAddress* inAddress);
static OSStatus MicDownmix_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable);
static OSStatus MicDownmix_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize);
static OSStatus MicDownmix_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);
static OSStatus MicDownmix_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData);

static OSStatus MicDownmix_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus MicDownmix_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus MicDownmix_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed);
static OSStatus MicDownmix_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace);
static OSStatus MicDownmix_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo);
static OSStatus MicDownmix_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer);
static OSStatus MicDownmix_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo);

//==================================================================================================
#pragma mark The Interface
//==================================================================================================

static AudioServerPlugInDriverInterface gAudioServerPlugInDriverInterface =
{
    NULL,
    MicDownmix_QueryInterface,
    MicDownmix_AddRef,
    MicDownmix_Release,
    MicDownmix_Initialize,
    MicDownmix_CreateDevice,
    MicDownmix_DestroyDevice,
    MicDownmix_AddDeviceClient,
    MicDownmix_RemoveDeviceClient,
    MicDownmix_PerformDeviceConfigurationChange,
    MicDownmix_AbortDeviceConfigurationChange,
    MicDownmix_HasProperty,
    MicDownmix_IsPropertySettable,
    MicDownmix_GetPropertyDataSize,
    MicDownmix_GetPropertyData,
    MicDownmix_SetPropertyData,
    MicDownmix_StartIO,
    MicDownmix_StopIO,
    MicDownmix_GetZeroTimeStamp,
    MicDownmix_WillDoIOOperation,
    MicDownmix_BeginIOOperation,
    MicDownmix_DoIOOperation,
    MicDownmix_EndIOOperation
};

static AudioServerPlugInDriverInterface*    gAudioServerPlugInDriverInterfacePtr    = &gAudioServerPlugInDriverInterface;
static AudioServerPlugInDriverRef           gAudioServerPlugInDriverRef             = &gAudioServerPlugInDriverInterfacePtr;

//==================================================================================================
#pragma mark Format helpers
//==================================================================================================

static bool MicDownmix_IsSupportedSampleRate(Float64 inRate)
{
    for(UInt32 theIndex = 0; theIndex < kSampleRateCount; ++theIndex)
    {
        if(kSampleRates[theIndex] == inRate) { return true; }
    }
    return false;
}

/// Recomputes how many host clock ticks one frame takes. Must be called with the state mutex held.
static void MicDownmix_RecomputeTiming(void)
{
    struct mach_timebase_info theTimeBaseInfo;
    mach_timebase_info(&theTimeBaseInfo);
    Float64 theHostClockFrequency =
        ((Float64)theTimeBaseInfo.denom / (Float64)theTimeBaseInfo.numer) * 1000000000.0;
    gDevice_HostTicksPerFrame = theHostClockFrequency / gDevice_SampleRate;
}

static void MicDownmix_FillPhysicalFormat(AudioStreamBasicDescription* outFormat)
{
    memset(outFormat, 0, sizeof(AudioStreamBasicDescription));
    outFormat->mSampleRate          = gDevice_SampleRate;
    outFormat->mFormatID            = kAudioFormatLinearPCM;
    outFormat->mFormatFlags         = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    outFormat->mBytesPerPacket      = kBytesPerFrame;
    outFormat->mFramesPerPacket     = 1;
    outFormat->mBytesPerFrame       = kBytesPerFrame;
    outFormat->mChannelsPerFrame    = kChannelCount;
    outFormat->mBitsPerChannel      = kBitsPerSample;
}

static void MicDownmix_FillVirtualFormat(AudioStreamBasicDescription* outFormat)
{
    memset(outFormat, 0, sizeof(AudioStreamBasicDescription));
    outFormat->mSampleRate          = gDevice_SampleRate;
    outFormat->mFormatID            = kAudioFormatLinearPCM;
    outFormat->mFormatFlags         = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    outFormat->mBytesPerPacket      = kChannelCount * sizeof(Float32);
    outFormat->mFramesPerPacket     = 1;
    outFormat->mBytesPerFrame       = kChannelCount * sizeof(Float32);
    outFormat->mChannelsPerFrame    = kChannelCount;
    outFormat->mBitsPerChannel      = 32;
}

//==================================================================================================
#pragma mark Factory
//==================================================================================================

void*   MicDownmixDriver_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID);
void*   MicDownmixDriver_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID)
{
    #pragma unused(inAllocator)
    void* theAnswer = NULL;
    if(CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID))
    {
        theAnswer = gAudioServerPlugInDriverRef;
    }
    return theAnswer;
}

static HRESULT MicDownmix_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface)
{
    if((inDriver != gAudioServerPlugInDriverRef) || (outInterface == NULL))
    {
        return kAudioHardwareBadObjectError;
    }

    CFUUIDRef theRequestedUUID = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    if(theRequestedUUID == NULL)
    {
        return kAudioHardwareIllegalOperationError;
    }

    HRESULT theAnswer = S_OK;
    if(CFEqual(theRequestedUUID, IUnknownUUID) || CFEqual(theRequestedUUID, kAudioServerPlugInDriverInterfaceUUID))
    {
        pthread_mutex_lock(&gPlugIn_StateMutex);
        ++gPlugIn_RefCount;
        pthread_mutex_unlock(&gPlugIn_StateMutex);
        *outInterface = gAudioServerPlugInDriverRef;
    }
    else
    {
        theAnswer = E_NOINTERFACE;
    }

    CFRelease(theRequestedUUID);
    return theAnswer;
}

static ULONG MicDownmix_AddRef(void* inDriver)
{
    if(inDriver != gAudioServerPlugInDriverRef)
    {
        return 0;
    }

    pthread_mutex_lock(&gPlugIn_StateMutex);
    if(gPlugIn_RefCount < UINT32_MAX)
    {
        ++gPlugIn_RefCount;
    }
    ULONG theAnswer = gPlugIn_RefCount;
    pthread_mutex_unlock(&gPlugIn_StateMutex);
    return theAnswer;
}

static ULONG MicDownmix_Release(void* inDriver)
{
    if(inDriver != gAudioServerPlugInDriverRef)
    {
        return 0;
    }

    pthread_mutex_lock(&gPlugIn_StateMutex);
    if(gPlugIn_RefCount > 0)
    {
        --gPlugIn_RefCount;
    }
    ULONG theAnswer = gPlugIn_RefCount;
    pthread_mutex_unlock(&gPlugIn_StateMutex);
    return theAnswer;
}

//==================================================================================================
#pragma mark Lifecycle
//==================================================================================================

static OSStatus MicDownmix_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost)
{
    if(inDriver != gAudioServerPlugInDriverRef)
    {
        return kAudioHardwareBadObjectError;
    }

    gPlugIn_Host = inHost;

    MicDownmix_RecomputeTiming();

    memset(gRingBuffer, 0, sizeof(gRingBuffer));

    return 0;
}

static OSStatus MicDownmix_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID)
{
    #pragma unused(inDriver, inDescription, inClientInfo, outDeviceObjectID)
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus MicDownmix_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID)
{
    #pragma unused(inDriver, inDeviceObjectID)
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus MicDownmix_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo)
{
    #pragma unused(inClientInfo)
    if(inDriver != gAudioServerPlugInDriverRef) { return kAudioHardwareBadObjectError; }
    if(inDeviceObjectID != kObjectID_Device) { return kAudioHardwareBadObjectError; }
    return 0;
}

static OSStatus MicDownmix_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo)
{
    #pragma unused(inClientInfo)
    if(inDriver != gAudioServerPlugInDriverRef) { return kAudioHardwareBadObjectError; }
    if(inDeviceObjectID != kObjectID_Device) { return kAudioHardwareBadObjectError; }
    return 0;
}

static OSStatus MicDownmix_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo)
{
    #pragma unused(inChangeAction, inChangeInfo)
    if(inDriver != gAudioServerPlugInDriverRef) { return kAudioHardwareBadObjectError; }
    if(inDeviceObjectID != kObjectID_Device) { return kAudioHardwareBadObjectError; }

    // inChangeAction carries the new sample rate, as passed to RequestDeviceConfigurationChange.
    Float64 theNewRate = (Float64)inChangeAction;
    if(!MicDownmix_IsSupportedSampleRate(theNewRate)) { return kAudioHardwareUnsupportedOperationError; }

    pthread_mutex_lock(&gPlugIn_StateMutex);
    gDevice_SampleRate = theNewRate;
    MicDownmix_RecomputeTiming();
    // The ring holds whatever the previous rate left behind; at a new rate those samples are
    // meaningless, so start from silence rather than a burst of noise.
    memset(gRingBuffer, 0, sizeof(gRingBuffer));
    gDevice_NumberTimeStamps = 0;
    gDevice_AnchorHostTime = mach_absolute_time();
    pthread_mutex_unlock(&gPlugIn_StateMutex);

    return 0;
}

static OSStatus MicDownmix_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo)
{
    #pragma unused(inChangeAction, inChangeInfo)
    if(inDriver != gAudioServerPlugInDriverRef) { return kAudioHardwareBadObjectError; }
    if(inDeviceObjectID != kObjectID_Device) { return kAudioHardwareBadObjectError; }
    return 0;
}

//==================================================================================================
#pragma mark Property implementation
//
//  HasProperty, GetPropertyDataSize and GetPropertyData are all served by a single core routine.
//  When outData is NULL the routine only reports the size, which is what the first two need. This
//  keeps the three entry points from drifting apart, which is the classic way a HAL plug-in ends
//  up with a device that half exists.
//==================================================================================================

// Writes a value of type T into outData if there is room, and always reports the size.
#define REPORT_SCALAR(T, EXPR)                                          \
    do {                                                                \
        if(inDataSize < sizeof(T)) { return kAudioHardwareBadPropertySizeError; } \
        if(outData != NULL) { *((T*)outData) = (EXPR); }                \
        *outDataSize = sizeof(T);                                       \
        return 0;                                                       \
    } while(0)

static OSStatus MicDownmix_GetProperty(AudioObjectID inObjectID, const AudioObjectPropertyAddress* inAddress, UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    switch(inObjectID)
    {
        //==========================================================================================
        case kObjectID_PlugIn:
        //==========================================================================================
            switch(inAddress->mSelector)
            {
                case kAudioObjectPropertyBaseClass:
                    REPORT_SCALAR(AudioClassID, kAudioObjectClassID);

                case kAudioObjectPropertyClass:
                    REPORT_SCALAR(AudioClassID, kAudioPlugInClassID);

                case kAudioObjectPropertyOwner:
                    REPORT_SCALAR(AudioObjectID, kAudioObjectUnknown);

                case kAudioObjectPropertyManufacturer:
                    REPORT_SCALAR(CFStringRef, CFSTR(kDevice_Manufacturer));

                case kAudioObjectPropertyOwnedObjects:
                {
                    // The box, and the device once the box is acquired.
                    AudioObjectID theOwned[2];
                    UInt32 theCount = 0;
                    theOwned[theCount++] = kObjectID_Box;
                    if(gBox_Acquired) { theOwned[theCount++] = kObjectID_Device; }

                    UInt32 theRoom = inDataSize / sizeof(AudioObjectID);
                    if(theRoom > theCount) { theRoom = theCount; }
                    if(outData != NULL) { memcpy(outData, theOwned, theRoom * sizeof(AudioObjectID)); }
                    *outDataSize = (outData != NULL) ? (theRoom * sizeof(AudioObjectID)) : (theCount * sizeof(AudioObjectID));
                    return 0;
                }

                case kAudioPlugInPropertyBoxList:
                    if(inDataSize < sizeof(AudioObjectID)) { *outDataSize = sizeof(AudioObjectID); return 0; }
                    if(outData != NULL) { *((AudioObjectID*)outData) = kObjectID_Box; }
                    *outDataSize = sizeof(AudioObjectID);
                    return 0;

                case kAudioPlugInPropertyTranslateUIDToBox:
                {
                    if(inDataSize < sizeof(AudioObjectID)) { return kAudioHardwareBadPropertySizeError; }
                    if(outData != NULL) { *((AudioObjectID*)outData) = kAudioObjectUnknown; }
                    *outDataSize = sizeof(AudioObjectID);
                    return 0;
                }

                case kAudioPlugInPropertyDeviceList:
                {
                    UInt32 theCount = gBox_Acquired ? 1 : 0;
                    if(outData != NULL && inDataSize >= sizeof(AudioObjectID) && theCount > 0)
                    {
                        *((AudioObjectID*)outData) = kObjectID_Device;
                        *outDataSize = sizeof(AudioObjectID);
                    }
                    else
                    {
                        *outDataSize = theCount * sizeof(AudioObjectID);
                    }
                    return 0;
                }

                case kAudioPlugInPropertyTranslateUIDToDevice:
                {
                    if(inDataSize < sizeof(AudioObjectID)) { return kAudioHardwareBadPropertySizeError; }
                    if(outData != NULL) { *((AudioObjectID*)outData) = kAudioObjectUnknown; }
                    *outDataSize = sizeof(AudioObjectID);
                    return 0;
                }

                case kAudioPlugInPropertyResourceBundle:
                    REPORT_SCALAR(CFStringRef, CFSTR(""));

                default:
                    return kAudioHardwareUnknownPropertyError;
            }
            break;

        //==========================================================================================
        case kObjectID_Box:
        //==========================================================================================
            switch(inAddress->mSelector)
            {
                case kAudioObjectPropertyBaseClass:     REPORT_SCALAR(AudioClassID, kAudioObjectClassID);
                case kAudioObjectPropertyClass:         REPORT_SCALAR(AudioClassID, kAudioBoxClassID);
                case kAudioObjectPropertyOwner:         REPORT_SCALAR(AudioObjectID, kObjectID_PlugIn);
                case kAudioObjectPropertyName:          REPORT_SCALAR(CFStringRef, CFSTR(kDevice_Name));
                case kAudioObjectPropertyModelName:     REPORT_SCALAR(CFStringRef, CFSTR(kDevice_Name));
                case kAudioObjectPropertyManufacturer:  REPORT_SCALAR(CFStringRef, CFSTR(kDevice_Manufacturer));
                case kAudioObjectPropertyIdentify:      REPORT_SCALAR(UInt32, 0);
                case kAudioBoxPropertyBoxUID:           REPORT_SCALAR(CFStringRef, CFSTR(kBox_UID));
                case kAudioBoxPropertyTransportType:    REPORT_SCALAR(UInt32, kAudioDeviceTransportTypeVirtual);
                case kAudioBoxPropertyHasAudio:         REPORT_SCALAR(UInt32, 1);
                case kAudioBoxPropertyHasVideo:         REPORT_SCALAR(UInt32, 0);
                case kAudioBoxPropertyHasMIDI:          REPORT_SCALAR(UInt32, 0);
                case kAudioBoxPropertyIsProtected:      REPORT_SCALAR(UInt32, 0);
                case kAudioBoxPropertyAcquired:         REPORT_SCALAR(UInt32, gBox_Acquired ? 1 : 0);
                case kAudioBoxPropertyAcquisitionFailed:REPORT_SCALAR(UInt32, 0);

                case kAudioObjectPropertyOwnedObjects:
                case kAudioBoxPropertyDeviceList:
                {
                    UInt32 theCount = gBox_Acquired ? 1 : 0;
                    if(outData != NULL && inDataSize >= sizeof(AudioObjectID) && theCount > 0)
                    {
                        *((AudioObjectID*)outData) = kObjectID_Device;
                        *outDataSize = sizeof(AudioObjectID);
                    }
                    else
                    {
                        *outDataSize = theCount * sizeof(AudioObjectID);
                    }
                    return 0;
                }

                default:
                    return kAudioHardwareUnknownPropertyError;
            }
            break;

        //==========================================================================================
        case kObjectID_Device:
        //==========================================================================================
            switch(inAddress->mSelector)
            {
                case kAudioObjectPropertyBaseClass:     REPORT_SCALAR(AudioClassID, kAudioObjectClassID);
                case kAudioObjectPropertyClass:         REPORT_SCALAR(AudioClassID, kAudioDeviceClassID);
                case kAudioObjectPropertyOwner:         REPORT_SCALAR(AudioObjectID, kObjectID_PlugIn);
                case kAudioObjectPropertyName:          REPORT_SCALAR(CFStringRef, CFSTR(kDevice_Name));
                case kAudioObjectPropertyModelName:     REPORT_SCALAR(CFStringRef, CFSTR(kDevice_Name));
                case kAudioObjectPropertyManufacturer:  REPORT_SCALAR(CFStringRef, CFSTR(kDevice_Manufacturer));
                case kAudioDevicePropertyDeviceUID:     REPORT_SCALAR(CFStringRef, CFSTR(kDevice_UID));
                case kAudioDevicePropertyModelUID:      REPORT_SCALAR(CFStringRef, CFSTR(kDevice_ModelUID));
                case kAudioDevicePropertyTransportType:  REPORT_SCALAR(UInt32, kAudioDeviceTransportTypeVirtual);
                case kAudioDevicePropertyClockDomain:    REPORT_SCALAR(UInt32, 0);
                case kAudioDevicePropertyDeviceIsAlive:  REPORT_SCALAR(UInt32, 1);
                case kAudioDevicePropertyDeviceIsRunning:REPORT_SCALAR(UInt32, (gDevice_IOIsRunning > 0) ? 1 : 0);
                case kAudioDevicePropertyDeviceCanBeDefaultDevice: REPORT_SCALAR(UInt32, 1);
                // Never volunteer to be the system alert device; this is a microphone.
                case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: REPORT_SCALAR(UInt32, 0);
                case kAudioDevicePropertyLatency:        REPORT_SCALAR(UInt32, 0);
                case kAudioDevicePropertySafetyOffset:   REPORT_SCALAR(UInt32, 0);
                case kAudioDevicePropertyNominalSampleRate: REPORT_SCALAR(Float64, gDevice_SampleRate);
                case kAudioDevicePropertyZeroTimeStampPeriod: REPORT_SCALAR(UInt32, kRingFrames);
                case kAudioDevicePropertyIsHidden:       REPORT_SCALAR(UInt32, 0);

                // Buffer frame size is owned by the HAL for plug-in devices, not by the plug-in.

                case kAudioDevicePropertyAvailableNominalSampleRates:
                {
                    // Every rate is offered as an exact point range, not a span: the device runs at
                    // one of these, it does not resample between them.
                    UInt32 theRoom = inDataSize / sizeof(AudioValueRange);
                    if(theRoom > kSampleRateCount) { theRoom = kSampleRateCount; }
                    if(outData != NULL)
                    {
                        AudioValueRange* theRanges = (AudioValueRange*)outData;
                        for(UInt32 theIndex = 0; theIndex < theRoom; ++theIndex)
                        {
                            theRanges[theIndex].mMinimum = kSampleRates[theIndex];
                            theRanges[theIndex].mMaximum = kSampleRates[theIndex];
                        }
                        *outDataSize = theRoom * sizeof(AudioValueRange);
                    }
                    else
                    {
                        *outDataSize = kSampleRateCount * sizeof(AudioValueRange);
                    }
                    return 0;
                }

                case kAudioDevicePropertyStreams:
                {
                    AudioObjectID theStreams[2];
                    UInt32 theCount = 0;
                    switch(inAddress->mScope)
                    {
                        case kAudioObjectPropertyScopeGlobal:
                            theStreams[theCount++] = kObjectID_Stream_Input;
                            theStreams[theCount++] = kObjectID_Stream_Output;
                            break;
                        case kAudioObjectPropertyScopeInput:
                            theStreams[theCount++] = kObjectID_Stream_Input;
                            break;
                        case kAudioObjectPropertyScopeOutput:
                            theStreams[theCount++] = kObjectID_Stream_Output;
                            break;
                        default:
                            break;
                    }
                    UInt32 theRoom = inDataSize / sizeof(AudioObjectID);
                    if(theRoom > theCount) { theRoom = theCount; }
                    if(outData != NULL)
                    {
                        memcpy(outData, theStreams, theRoom * sizeof(AudioObjectID));
                        *outDataSize = theRoom * sizeof(AudioObjectID);
                    }
                    else
                    {
                        *outDataSize = theCount * sizeof(AudioObjectID);
                    }
                    return 0;
                }

                case kAudioObjectPropertyOwnedObjects:
                {
                    // Same as the stream list; the device owns no controls.
                    AudioObjectPropertyAddress theStreamsAddress = *inAddress;
                    theStreamsAddress.mSelector = kAudioDevicePropertyStreams;
                    return MicDownmix_GetProperty(inObjectID, &theStreamsAddress, inDataSize, outDataSize, outData);
                }

                case kAudioObjectPropertyControlList:
                    // No volume or mute controls. Nothing downstream needs them and every control
                    // is another property surface that can be got wrong.
                    *outDataSize = 0;
                    return 0;

                case kAudioDevicePropertyRelatedDevices:
                {
                    if(outData != NULL && inDataSize >= sizeof(AudioObjectID))
                    {
                        *((AudioObjectID*)outData) = kObjectID_Device;
                        *outDataSize = sizeof(AudioObjectID);
                    }
                    else
                    {
                        *outDataSize = sizeof(AudioObjectID);
                    }
                    return 0;
                }

                case kAudioDevicePropertyPreferredChannelsForStereo:
                {
                    if(inDataSize < (2 * sizeof(UInt32))) { return kAudioHardwareBadPropertySizeError; }
                    if(outData != NULL)
                    {
                        // A mono device: both halves of the stereo pair are channel 1.
                        ((UInt32*)outData)[0] = 1;
                        ((UInt32*)outData)[1] = 1;
                    }
                    *outDataSize = 2 * sizeof(UInt32);
                    return 0;
                }

                case kAudioDevicePropertyPreferredChannelLayout:
                {
                    UInt32 theSize = offsetof(AudioChannelLayout, mChannelDescriptions) + (kChannelCount * sizeof(AudioChannelDescription));
                    if(outData != NULL)
                    {
                        if(inDataSize < theSize) { return kAudioHardwareBadPropertySizeError; }
                        AudioChannelLayout* theLayout = (AudioChannelLayout*)outData;
                        memset(theLayout, 0, theSize);
                        theLayout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
                        theLayout->mNumberChannelDescriptions = kChannelCount;
                        theLayout->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Mono;
                    }
                    *outDataSize = theSize;
                    return 0;
                }

                case kAudioDevicePropertyIcon:
                    return kAudioHardwareUnknownPropertyError;

                default:
                    return kAudioHardwareUnknownPropertyError;
            }
            break;

        //==========================================================================================
        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output:
        //==========================================================================================
        {
            bool theIsInput = (inObjectID == kObjectID_Stream_Input);
            switch(inAddress->mSelector)
            {
                case kAudioObjectPropertyBaseClass: REPORT_SCALAR(AudioClassID, kAudioObjectClassID);
                case kAudioObjectPropertyClass:     REPORT_SCALAR(AudioClassID, kAudioStreamClassID);
                case kAudioObjectPropertyOwner:     REPORT_SCALAR(AudioObjectID, kObjectID_Device);

                case kAudioObjectPropertyOwnedObjects:
                    *outDataSize = 0;
                    return 0;

                case kAudioStreamPropertyIsActive:
                    REPORT_SCALAR(UInt32, (theIsInput ? gStream_Input_IsActive : gStream_Output_IsActive) ? 1 : 0);

                case kAudioStreamPropertyDirection:
                    // 1 means input, 0 means output.
                    REPORT_SCALAR(UInt32, theIsInput ? 1 : 0);

                case kAudioStreamPropertyTerminalType:
                    REPORT_SCALAR(UInt32, theIsInput ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeSpeaker);

                case kAudioStreamPropertyStartingChannel:
                    REPORT_SCALAR(UInt32, 1);

                case kAudioStreamPropertyLatency:
                    REPORT_SCALAR(UInt32, 0);

                case kAudioStreamPropertyVirtualFormat:
                {
                    if(inDataSize < sizeof(AudioStreamBasicDescription)) { return kAudioHardwareBadPropertySizeError; }
                    if(outData != NULL) { MicDownmix_FillVirtualFormat((AudioStreamBasicDescription*)outData); }
                    *outDataSize = sizeof(AudioStreamBasicDescription);
                    return 0;
                }

                case kAudioStreamPropertyPhysicalFormat:
                {
                    if(inDataSize < sizeof(AudioStreamBasicDescription)) { return kAudioHardwareBadPropertySizeError; }
                    if(outData != NULL) { MicDownmix_FillPhysicalFormat((AudioStreamBasicDescription*)outData); }
                    *outDataSize = sizeof(AudioStreamBasicDescription);
                    return 0;
                }

                case kAudioStreamPropertyAvailableVirtualFormats:
                {
                    UInt32 theRoom = inDataSize / sizeof(AudioStreamRangedDescription);
                    if(theRoom > kSampleRateCount) { theRoom = kSampleRateCount; }
                    if(outData != NULL)
                    {
                        AudioStreamRangedDescription* theDescs = (AudioStreamRangedDescription*)outData;
                        for(UInt32 theIndex = 0; theIndex < theRoom; ++theIndex)
                        {
                            MicDownmix_FillVirtualFormat(&theDescs[theIndex].mFormat);
                            theDescs[theIndex].mFormat.mSampleRate = kSampleRates[theIndex];
                            theDescs[theIndex].mSampleRateRange.mMinimum = kSampleRates[theIndex];
                            theDescs[theIndex].mSampleRateRange.mMaximum = kSampleRates[theIndex];
                        }
                        *outDataSize = theRoom * sizeof(AudioStreamRangedDescription);
                    }
                    else
                    {
                        *outDataSize = kSampleRateCount * sizeof(AudioStreamRangedDescription);
                    }
                    return 0;
                }

                case kAudioStreamPropertyAvailablePhysicalFormats:
                {
                    UInt32 theRoom = inDataSize / sizeof(AudioStreamRangedDescription);
                    if(theRoom > kSampleRateCount) { theRoom = kSampleRateCount; }
                    if(outData != NULL)
                    {
                        AudioStreamRangedDescription* theDescs = (AudioStreamRangedDescription*)outData;
                        for(UInt32 theIndex = 0; theIndex < theRoom; ++theIndex)
                        {
                            MicDownmix_FillPhysicalFormat(&theDescs[theIndex].mFormat);
                            theDescs[theIndex].mFormat.mSampleRate = kSampleRates[theIndex];
                            theDescs[theIndex].mSampleRateRange.mMinimum = kSampleRates[theIndex];
                            theDescs[theIndex].mSampleRateRange.mMaximum = kSampleRates[theIndex];
                        }
                        *outDataSize = theRoom * sizeof(AudioStreamRangedDescription);
                    }
                    else
                    {
                        *outDataSize = kSampleRateCount * sizeof(AudioStreamRangedDescription);
                    }
                    return 0;
                }

                default:
                    return kAudioHardwareUnknownPropertyError;
            }
            break;
        }

        default:
            return kAudioHardwareBadObjectError;
    }

    return kAudioHardwareUnknownPropertyError;
}

#undef REPORT_SCALAR

//==================================================================================================
#pragma mark Property entry points
//==================================================================================================

static Boolean MicDownmix_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID, const AudioObjectPropertyAddress* inAddress)
{
    #pragma unused(inClientPID)
    if((inDriver != gAudioServerPlugInDriverRef) || (inAddress == NULL)) { return false; }

    UInt32 theSize = 0;
    pthread_mutex_lock(&gPlugIn_StateMutex);
    OSStatus theError = MicDownmix_GetProperty(inObjectID, inAddress, UINT32_MAX, &theSize, NULL);
    pthread_mutex_unlock(&gPlugIn_StateMutex);
    return theError == 0;
}

static OSStatus MicDownmix_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable)
{
    #pragma unused(inClientPID)
    if((inDriver != gAudioServerPlugInDriverRef) || (inAddress == NULL) || (outIsSettable == NULL))
    {
        return kAudioHardwareBadObjectError;
    }

    UInt32 theSize = 0;
    pthread_mutex_lock(&gPlugIn_StateMutex);
    OSStatus theError = MicDownmix_GetProperty(inObjectID, inAddress, UINT32_MAX, &theSize, NULL);
    pthread_mutex_unlock(&gPlugIn_StateMutex);
    if(theError != 0) { return theError; }

    switch(inAddress->mSelector)
    {
        // The only genuinely settable things. Everything else is fixed by design: one rate, one
        // channel, one format.
        case kAudioStreamPropertyIsActive:
            *outIsSettable = (inObjectID == kObjectID_Stream_Input) || (inObjectID == kObjectID_Stream_Output);
            break;
        case kAudioBoxPropertyAcquired:
            *outIsSettable = (inObjectID == kObjectID_Box);
            break;
        // Accept writes of the one supported value so that clients which set these as a matter of
        // course do not see an error.
        case kAudioDevicePropertyNominalSampleRate:
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            *outIsSettable = true;
            break;
        default:
            *outIsSettable = false;
            break;
    }
    return 0;
}

static OSStatus MicDownmix_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize)
{
    #pragma unused(inClientPID, inQualifierDataSize, inQualifierData)
    if((inDriver != gAudioServerPlugInDriverRef) || (inAddress == NULL) || (outDataSize == NULL))
    {
        return kAudioHardwareBadObjectError;
    }

    pthread_mutex_lock(&gPlugIn_StateMutex);
    OSStatus theError = MicDownmix_GetProperty(inObjectID, inAddress, UINT32_MAX, outDataSize, NULL);
    pthread_mutex_unlock(&gPlugIn_StateMutex);
    return theError;
}

static OSStatus MicDownmix_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData)
{
    #pragma unused(inClientPID, inQualifierDataSize, inQualifierData)
    if((inDriver != gAudioServerPlugInDriverRef) || (inAddress == NULL) || (outDataSize == NULL) || (outData == NULL))
    {
        return kAudioHardwareBadObjectError;
    }

    pthread_mutex_lock(&gPlugIn_StateMutex);
    OSStatus theError = MicDownmix_GetProperty(inObjectID, inAddress, inDataSize, outDataSize, outData);
    pthread_mutex_unlock(&gPlugIn_StateMutex);

    // CFString values are handed out with a +1 retain, as the HAL expects to release them.
    if(theError == 0 && *outDataSize == sizeof(CFStringRef))
    {
        switch(inAddress->mSelector)
        {
            case kAudioObjectPropertyName:
            case kAudioObjectPropertyModelName:
            case kAudioObjectPropertyManufacturer:
            case kAudioDevicePropertyDeviceUID:
            case kAudioDevicePropertyModelUID:
            case kAudioBoxPropertyBoxUID:
            case kAudioPlugInPropertyResourceBundle:
                CFRetain(*((CFStringRef*)outData));
                break;
            default:
                break;
        }
    }

    return theError;
}

static OSStatus MicDownmix_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData)
{
    #pragma unused(inClientPID, inQualifierDataSize, inQualifierData)
    if((inDriver != gAudioServerPlugInDriverRef) || (inAddress == NULL) || (inData == NULL))
    {
        return kAudioHardwareBadObjectError;
    }

    switch(inAddress->mSelector)
    {
        case kAudioStreamPropertyIsActive:
        {
            if(inDataSize != sizeof(UInt32)) { return kAudioHardwareBadPropertySizeError; }
            bool theNewValue = (*((const UInt32*)inData)) != 0;
            pthread_mutex_lock(&gPlugIn_StateMutex);
            if(inObjectID == kObjectID_Stream_Input)       { gStream_Input_IsActive = theNewValue; }
            else if(inObjectID == kObjectID_Stream_Output) { gStream_Output_IsActive = theNewValue; }
            else { pthread_mutex_unlock(&gPlugIn_StateMutex); return kAudioHardwareBadObjectError; }
            pthread_mutex_unlock(&gPlugIn_StateMutex);
            return 0;
        }

        case kAudioBoxPropertyAcquired:
        {
            if(inObjectID != kObjectID_Box) { return kAudioHardwareBadObjectError; }
            if(inDataSize != sizeof(UInt32)) { return kAudioHardwareBadPropertySizeError; }
            // The box is permanently acquired; a virtual device has nothing to claim or release.
            return 0;
        }

        case kAudioDevicePropertyNominalSampleRate:
        {
            if(inDataSize != sizeof(Float64)) { return kAudioHardwareBadPropertySizeError; }
            Float64 theNewRate = *((const Float64*)inData);
            if(!MicDownmix_IsSupportedSampleRate(theNewRate))
            {
                return kAudioHardwareUnsupportedOperationError;
            }

            pthread_mutex_lock(&gPlugIn_StateMutex);
            bool theSame = (gDevice_SampleRate == theNewRate);
            pthread_mutex_unlock(&gPlugIn_StateMutex);
            if(theSame) { return 0; }

            // The rate cannot change underneath running IO. Asking the host to schedule it means IO
            // is stopped, PerformDeviceConfigurationChange applies it, and IO restarts.
            if(gPlugIn_Host != NULL)
            {
                gPlugIn_Host->RequestDeviceConfigurationChange(
                    gPlugIn_Host, kObjectID_Device, (UInt64)theNewRate, NULL);
            }
            return 0;
        }

        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
        {
            if(inDataSize != sizeof(AudioStreamBasicDescription)) { return kAudioHardwareBadPropertySizeError; }
            const AudioStreamBasicDescription* theNewFormat = (const AudioStreamBasicDescription*)inData;
            if((theNewFormat->mFormatID != kAudioFormatLinearPCM) ||
               (theNewFormat->mChannelsPerFrame != kChannelCount) ||
               !MicDownmix_IsSupportedSampleRate(theNewFormat->mSampleRate))
            {
                return kAudioDeviceUnsupportedFormatError;
            }

            // A format whose rate differs is a rate change, and goes through the host like one.
            pthread_mutex_lock(&gPlugIn_StateMutex);
            bool theRateDiffers = (gDevice_SampleRate != theNewFormat->mSampleRate);
            pthread_mutex_unlock(&gPlugIn_StateMutex);
            if(theRateDiffers && (gPlugIn_Host != NULL))
            {
                gPlugIn_Host->RequestDeviceConfigurationChange(
                    gPlugIn_Host, kObjectID_Device, (UInt64)theNewFormat->mSampleRate, NULL);
            }
            return 0;
        }

        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

//==================================================================================================
#pragma mark IO
//==================================================================================================

// The absolute sample time one past the last frame the writer has produced. ReadInput uses this to
// emit silence rather than replaying the ring when the app stops feeding the device. Tracking the
// write head this way keeps reads non-destructive, so any number of clients can read the device.
static _Atomic uint64_t gRing_WriteEndSampleTime = 0;

static OSStatus MicDownmix_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    #pragma unused(inClientID)
    if(inDriver != gAudioServerPlugInDriverRef) { return kAudioHardwareBadObjectError; }
    if(inDeviceObjectID != kObjectID_Device) { return kAudioHardwareBadObjectError; }

    pthread_mutex_lock(&gPlugIn_StateMutex);
    if(gDevice_IOIsRunning == 0)
    {
        // First client in. Reset the timeline and clear any audio left from a previous session.
        gDevice_NumberTimeStamps = 0;
        gDevice_AnchorHostTime = mach_absolute_time();
        memset(gRingBuffer, 0, sizeof(gRingBuffer));
        atomic_store(&gRing_WriteEndSampleTime, 0);
    }
    ++gDevice_IOIsRunning;
    pthread_mutex_unlock(&gPlugIn_StateMutex);

    return 0;
}

static OSStatus MicDownmix_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    #pragma unused(inClientID)
    if(inDriver != gAudioServerPlugInDriverRef) { return kAudioHardwareBadObjectError; }
    if(inDeviceObjectID != kObjectID_Device) { return kAudioHardwareBadObjectError; }

    pthread_mutex_lock(&gPlugIn_StateMutex);
    if(gDevice_IOIsRunning > 0) { --gDevice_IOIsRunning; }
    pthread_mutex_unlock(&gPlugIn_StateMutex);

    return 0;
}

static OSStatus MicDownmix_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed)
{
    #pragma unused(inClientID)
    if(inDriver != gAudioServerPlugInDriverRef) { return kAudioHardwareBadObjectError; }
    if(inDeviceObjectID != kObjectID_Device) { return kAudioHardwareBadObjectError; }

    pthread_mutex_lock(&gPlugIn_StateMutex);

    UInt64 theCurrentHostTime = mach_absolute_time();
    Float64 theHostTicksPerRingBuffer = gDevice_HostTicksPerFrame * ((Float64)kRingFrames);
    Float64 theHostTickOffset = ((Float64)(gDevice_NumberTimeStamps + 1)) * theHostTicksPerRingBuffer;
    UInt64 theNextHostTime = gDevice_AnchorHostTime + ((UInt64)theHostTickOffset);

    if(theNextHostTime <= theCurrentHostTime)
    {
        ++gDevice_NumberTimeStamps;
    }

    *outSampleTime = (Float64)(gDevice_NumberTimeStamps * kRingFrames);
    *outHostTime = gDevice_AnchorHostTime + (UInt64)(((Float64)gDevice_NumberTimeStamps) * theHostTicksPerRingBuffer);
    *outSeed = 1;

    pthread_mutex_unlock(&gPlugIn_StateMutex);

    return 0;
}

static OSStatus MicDownmix_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace)
{
    #pragma unused(inClientID)
    if(inDriver != gAudioServerPlugInDriverRef) { return kAudioHardwareBadObjectError; }
    if(inDeviceObjectID != kObjectID_Device) { return kAudioHardwareBadObjectError; }

    // Only the two required operations. The physical format is ordinary packed 16-bit signed
    // integer, which the HAL converts to and from the Float32 virtual format itself; that is a
    // per-sample scalar conversion on a mono stream with no channel map involved.
    bool theWillDo = false;
    bool theWillDoInPlace = true;
    switch(inOperationID)
    {
        case kAudioServerPlugInIOOperationReadInput:
        case kAudioServerPlugInIOOperationWriteMix:
            theWillDo = true;
            theWillDoInPlace = true;
            break;
        default:
            break;
    }

    if(outWillDo != NULL) { *outWillDo = theWillDo; }
    if(outWillDoInPlace != NULL) { *outWillDoInPlace = theWillDoInPlace; }

    return 0;
}

static OSStatus MicDownmix_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{
    #pragma unused(inClientID, inOperationID, inIOBufferFrameSize, inIOCycleInfo)
    if(inDriver != gAudioServerPlugInDriverRef) { return kAudioHardwareBadObjectError; }
    if(inDeviceObjectID != kObjectID_Device) { return kAudioHardwareBadObjectError; }
    return 0;
}

static OSStatus MicDownmix_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{
    #pragma unused(inClientID, inOperationID, inIOBufferFrameSize, inIOCycleInfo)
    if(inDriver != gAudioServerPlugInDriverRef) { return kAudioHardwareBadObjectError; }
    if(inDeviceObjectID != kObjectID_Device) { return kAudioHardwareBadObjectError; }
    return 0;
}

static OSStatus MicDownmix_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer)
{
    #pragma unused(inStreamObjectID, inClientID, ioSecondaryBuffer)
    if(inDriver != gAudioServerPlugInDriverRef) { return kAudioHardwareBadObjectError; }
    if(inDeviceObjectID != kObjectID_Device) { return kAudioHardwareBadObjectError; }
    if(ioMainBuffer == NULL) { return 0; }

    // Both buffers are in the stream's physical format, which is mono 16-bit signed integer.
    int16_t* theBuffer = (int16_t*)ioMainBuffer;

    switch(inOperationID)
    {
        case kAudioServerPlugInIOOperationWriteMix:
        {
            uint64_t theStart = (uint64_t)inIOCycleInfo->mOutputTime.mSampleTime;
            for(UInt32 theFrame = 0; theFrame < inIOBufferFrameSize; ++theFrame)
            {
                gRingBuffer[(theStart + theFrame) % kRingFrames] = theBuffer[theFrame];
            }
            atomic_store(&gRing_WriteEndSampleTime, theStart + inIOBufferFrameSize);
            break;
        }

        case kAudioServerPlugInIOOperationReadInput:
        {
            uint64_t theStart = (uint64_t)inIOCycleInfo->mInputTime.mSampleTime;
            uint64_t theWriteEnd = atomic_load(&gRing_WriteEndSampleTime);
            for(UInt32 theFrame = 0; theFrame < inIOBufferFrameSize; ++theFrame)
            {
                uint64_t theSampleTime = theStart + theFrame;
                // Anything the writer has not produced yet, or has already been lapped in the
                // ring, reads as silence rather than as stale audio.
                bool theIsValid = (theSampleTime < theWriteEnd) && ((theWriteEnd - theSampleTime) <= kRingFrames);
                theBuffer[theFrame] = theIsValid ? gRingBuffer[theSampleTime % kRingFrames] : 0;
            }
            break;
        }

        default:
            break;
    }

    return 0;
}
