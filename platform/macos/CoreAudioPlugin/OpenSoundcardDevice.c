#include "OpenSoundcardDevice.h"

#include "opensoundcard_ffi.h"

#include <CoreAudio/AudioHardwareBase.h>
#include <CoreAudioTypes/CoreAudioBaseTypes.h>
#include <mach/mach_time.h>
#include <math.h>
#include <stdatomic.h>
#include <string.h>

typedef struct OpenSoundcardDeviceState {
  void *engine;
  atomic_uint running_client_count;
  UInt64 host_time_anchor;
  Float64 host_ticks_per_frame;
  UInt64 clock_seed;
  bool initialized;
} OpenSoundcardDeviceState;

static OpenSoundcardDeviceState g_device = {
    .engine = NULL,
    .running_client_count = 0,
    .host_time_anchor = 0,
    .host_ticks_per_frame = 0.0,
    .clock_seed = 1,
    .initialized = false,
};

static bool OpenSoundcardObjectExists(AudioObjectID object_id) {
  return object_id == kAudioObjectPlugInObject ||
         object_id == OPENSOUNDCARD_DEVICE_OBJECT_ID ||
         object_id == OPENSOUNDCARD_INPUT_STREAM_OBJECT_ID;
}

static bool OpenSoundcardIsGlobalScope(AudioObjectPropertyScope scope) {
  return scope == kAudioObjectPropertyScopeGlobal ||
         scope == kAudioObjectPropertyScopeWildcard;
}

static bool OpenSoundcardIsInputScope(AudioObjectPropertyScope scope) {
  return scope == kAudioObjectPropertyScopeInput ||
         scope == kAudioObjectPropertyScopeWildcard;
}

static bool
OpenSoundcardScopeExposesInputStream(AudioObjectPropertyScope scope) {
  return scope == kAudioObjectPropertyScopeGlobal ||
         scope == kAudioObjectPropertyScopeInput ||
         scope == kAudioObjectPropertyScopeWildcard;
}

static bool OpenSoundcardIsMainElement(AudioObjectPropertyElement element) {
  return element == kAudioObjectPropertyElementMain ||
         element == kAudioObjectPropertyElementWildcard;
}

static UInt64 OpenSoundcardHostTicksForSeconds(Float64 seconds) {
  mach_timebase_info_data_t timebase;
  if (mach_timebase_info(&timebase) != KERN_SUCCESS || timebase.numer == 0) {
    return 0;
  }

  const Float64 nanoseconds = seconds * 1000000000.0;
  return (UInt64)((nanoseconds * (Float64)timebase.denom) /
                  (Float64)timebase.numer);
}

static Float64 OpenSoundcardHostTicksPerFrame(void) {
  const UInt64 ticks_per_second = OpenSoundcardHostTicksForSeconds(1.0);
  if (ticks_per_second == 0) {
    return 1.0;
  }

  return (Float64)ticks_per_second / OPENSOUNDCARD_SAMPLE_RATE;
}

static AudioStreamBasicDescription OpenSoundcardStreamFormat(void) {
  AudioStreamBasicDescription format;
  memset(&format, 0, sizeof(format));
  format.mSampleRate = OPENSOUNDCARD_SAMPLE_RATE;
  format.mFormatID = kAudioFormatLinearPCM;
  format.mFormatFlags = kAudioFormatFlagIsFloat |
                        kAudioFormatFlagsNativeEndian |
                        kAudioFormatFlagIsPacked;
  format.mBytesPerPacket = sizeof(Float32) * OPENSOUNDCARD_CHANNEL_COUNT;
  format.mFramesPerPacket = 1;
  format.mBytesPerFrame = sizeof(Float32) * OPENSOUNDCARD_CHANNEL_COUNT;
  format.mChannelsPerFrame = OPENSOUNDCARD_CHANNEL_COUNT;
  format.mBitsPerChannel = 32;
  return format;
}

static AudioStreamRangedDescription OpenSoundcardRangedStreamFormat(void) {
  AudioStreamRangedDescription ranged_format;
  ranged_format.mFormat = OpenSoundcardStreamFormat();
  ranged_format.mSampleRateRange.mMinimum = OPENSOUNDCARD_SAMPLE_RATE;
  ranged_format.mSampleRateRange.mMaximum = OPENSOUNDCARD_SAMPLE_RATE;
  return ranged_format;
}

static OSStatus OpenSoundcardCopyFixedProperty(UInt32 data_size,
                                               UInt32 *out_data_size,
                                               void *out_data,
                                               const void *source,
                                               UInt32 source_size) {
  if (out_data_size == NULL || out_data == NULL) {
    return kAudioHardwareBadPropertySizeError;
  }

  *out_data_size = source_size;
  if (data_size < source_size) {
    return kAudioHardwareBadPropertySizeError;
  }

  memcpy(out_data, source, source_size);
  return kAudioHardwareNoError;
}

static OSStatus OpenSoundcardCopyUInt32(UInt32 data_size, UInt32 *out_data_size,
                                        void *out_data, UInt32 value) {
  return OpenSoundcardCopyFixedProperty(data_size, out_data_size, out_data,
                                        &value, sizeof(value));
}

static OSStatus OpenSoundcardCopyFloat64(UInt32 data_size,
                                         UInt32 *out_data_size, void *out_data,
                                         Float64 value) {
  return OpenSoundcardCopyFixedProperty(data_size, out_data_size, out_data,
                                        &value, sizeof(value));
}

static OSStatus OpenSoundcardCopyObjectID(UInt32 data_size,
                                          UInt32 *out_data_size, void *out_data,
                                          AudioObjectID value) {
  return OpenSoundcardCopyFixedProperty(data_size, out_data_size, out_data,
                                        &value, sizeof(value));
}

static OSStatus OpenSoundcardCopyCFString(UInt32 data_size,
                                          UInt32 *out_data_size, void *out_data,
                                          const char *value) {
  if (out_data_size == NULL || out_data == NULL || value == NULL) {
    return kAudioHardwareBadPropertySizeError;
  }

  *out_data_size = sizeof(CFStringRef);
  if (data_size < sizeof(CFStringRef)) {
    return kAudioHardwareBadPropertySizeError;
  }

  CFStringRef string =
      CFStringCreateWithCString(NULL, value, kCFStringEncodingUTF8);
  if (string == NULL) {
    return kAudioHardwareUnspecifiedError;
  }

  *((CFStringRef *)out_data) = string;
  return kAudioHardwareNoError;
}

static OSStatus OpenSoundcardCopyDeviceList(UInt32 data_size,
                                            UInt32 *out_data_size,
                                            void *out_data) {
  const AudioObjectID devices[] = {OPENSOUNDCARD_DEVICE_OBJECT_ID};
  return OpenSoundcardCopyFixedProperty(data_size, out_data_size, out_data,
                                        devices, sizeof(devices));
}

static OSStatus OpenSoundcardCopyStreamList(UInt32 data_size,
                                            UInt32 *out_data_size,
                                            void *out_data,
                                            AudioObjectPropertyScope scope) {
  if (out_data_size == NULL) {
    return kAudioHardwareBadPropertySizeError;
  }

  if (OpenSoundcardScopeExposesInputStream(scope)) {
    const AudioObjectID streams[] = {OPENSOUNDCARD_INPUT_STREAM_OBJECT_ID};
    return OpenSoundcardCopyFixedProperty(data_size, out_data_size, out_data,
                                          streams, sizeof(streams));
  }

  *out_data_size = 0;
  return kAudioHardwareNoError;
}

static OSStatus OpenSoundcardCopyEmptyObjectList(UInt32 data_size,
                                                 UInt32 *out_data_size,
                                                 void *out_data) {
  (void)data_size;
  (void)out_data;
  if (out_data_size == NULL) {
    return kAudioHardwareBadPropertySizeError;
  }

  *out_data_size = 0;
  return kAudioHardwareNoError;
}

static OSStatus OpenSoundcardCopyDeviceForUID(UInt32 qualifier_data_size,
                                              const void *qualifier_data,
                                              UInt32 data_size,
                                              UInt32 *out_data_size,
                                              void *out_data) {
  AudioObjectID device_id = kAudioObjectUnknown;

  if (qualifier_data_size == sizeof(CFStringRef) && qualifier_data != NULL) {
    CFStringRef uid = *((const CFStringRef *)qualifier_data);
    if (uid != NULL && CFStringCompare(uid, CFSTR(OPENSOUNDCARD_DEVICE_UID),
                                       0) == kCFCompareEqualTo) {
      device_id = OPENSOUNDCARD_DEVICE_OBJECT_ID;
    }
  }

  return OpenSoundcardCopyObjectID(data_size, out_data_size, out_data,
                                   device_id);
}

static OSStatus
OpenSoundcardCopyPreferredStereoChannels(UInt32 data_size,
                                         UInt32 *out_data_size, void *out_data,
                                         AudioObjectPropertyScope scope) {
  if (!OpenSoundcardIsInputScope(scope)) {
    return kAudioHardwareUnknownPropertyError;
  }

  const UInt32 channels[] = {1, 2};
  return OpenSoundcardCopyFixedProperty(data_size, out_data_size, out_data,
                                        channels, sizeof(channels));
}

static OSStatus OpenSoundcardCopyAvailableSampleRates(UInt32 data_size,
                                                      UInt32 *out_data_size,
                                                      void *out_data) {
  const AudioValueRange rates[] = {{
      .mMinimum = OPENSOUNDCARD_SAMPLE_RATE,
      .mMaximum = OPENSOUNDCARD_SAMPLE_RATE,
  }};
  return OpenSoundcardCopyFixedProperty(data_size, out_data_size, out_data,
                                        rates, sizeof(rates));
}

static OSStatus OpenSoundcardCopyStreamFormat(UInt32 data_size,
                                              UInt32 *out_data_size,
                                              void *out_data) {
  const AudioStreamBasicDescription format = OpenSoundcardStreamFormat();
  return OpenSoundcardCopyFixedProperty(data_size, out_data_size, out_data,
                                        &format, sizeof(format));
}

static OSStatus OpenSoundcardCopyAvailableStreamFormats(UInt32 data_size,
                                                        UInt32 *out_data_size,
                                                        void *out_data) {
  const AudioStreamRangedDescription format = OpenSoundcardRangedStreamFormat();
  return OpenSoundcardCopyFixedProperty(data_size, out_data_size, out_data,
                                        &format, sizeof(format));
}

static UInt32 OpenSoundcardDeviceRunning(void) {
  return atomic_load_explicit(&g_device.running_client_count,
                              memory_order_relaxed) > 0
             ? 1
             : 0;
}

bool OpenSoundcardDeviceInitialize(void) {
  if (g_device.initialized) {
    return true;
  }

  g_device.engine = osc_engine_create(OPENSOUNDCARD_CHANNEL_COUNT,
                                      OPENSOUNDCARD_ENGINE_CAPACITY_FRAMES,
                                      OPENSOUNDCARD_SAMPLE_RATE);
  if (g_device.engine == NULL) {
    return false;
  }

  atomic_store_explicit(&g_device.running_client_count, 0,
                        memory_order_relaxed);
  g_device.host_time_anchor = mach_absolute_time();
  g_device.host_ticks_per_frame = OpenSoundcardHostTicksPerFrame();
  g_device.clock_seed = 1;
  g_device.initialized = true;
  return true;
}

void OpenSoundcardDeviceDestroy(void) {
  if (g_device.engine != NULL) {
    osc_engine_destroy(g_device.engine);
    g_device.engine = NULL;
  }

  g_device.initialized = false;
}

Boolean
OpenSoundcardDeviceHasProperty(AudioObjectID object_id,
                               const AudioObjectPropertyAddress *address) {
  if (address == NULL || !OpenSoundcardObjectExists(object_id) ||
      !OpenSoundcardIsMainElement(address->mElement)) {
    return false;
  }

  switch (object_id) {
  case kAudioObjectPlugInObject:
    if (!OpenSoundcardIsGlobalScope(address->mScope)) {
      return false;
    }
    switch (address->mSelector) {
    case kAudioObjectPropertyBaseClass:
    case kAudioObjectPropertyClass:
    case kAudioObjectPropertyOwner:
    case kAudioObjectPropertyOwnedObjects:
    case kAudioPlugInPropertyBundleID:
    case kAudioPlugInPropertyDeviceList:
    case kAudioPlugInPropertyTranslateUIDToDevice:
      return true;
    default:
      return false;
    }

  case OPENSOUNDCARD_DEVICE_OBJECT_ID:
    switch (address->mSelector) {
    case kAudioObjectPropertyBaseClass:
    case kAudioObjectPropertyClass:
    case kAudioObjectPropertyOwner:
    case kAudioObjectPropertyName:
    case kAudioObjectPropertyModelName:
    case kAudioObjectPropertyManufacturer:
    case kAudioDevicePropertyDeviceUID:
    case kAudioDevicePropertyModelUID:
    case kAudioDevicePropertyTransportType:
    case kAudioDevicePropertyRelatedDevices:
    case kAudioDevicePropertyClockDomain:
    case kAudioDevicePropertyDeviceIsAlive:
    case kAudioDevicePropertyDeviceIsRunning:
    case kAudioDevicePropertyDeviceCanBeDefaultDevice:
    case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
    case kAudioDevicePropertyLatency:
    case kAudioObjectPropertyControlList:
    case kAudioDevicePropertySafetyOffset:
    case kAudioDevicePropertyNominalSampleRate:
    case kAudioDevicePropertyAvailableNominalSampleRates:
    case kAudioDevicePropertyIsHidden:
    case kAudioDevicePropertyWantsControlsRestored:
    case kAudioDevicePropertyWantsStreamFormatsRestored:
    case kAudioDevicePropertyZeroTimeStampPeriod:
    case kAudioDevicePropertyClockAlgorithm:
    case kAudioDevicePropertyClockIsStable:
      return true;
    case kAudioObjectPropertyOwnedObjects:
      return OpenSoundcardIsGlobalScope(address->mScope);
    case kAudioDevicePropertyStreams:
      return OpenSoundcardIsGlobalScope(address->mScope) ||
             address->mScope == kAudioObjectPropertyScopeInput ||
             address->mScope == kAudioObjectPropertyScopeOutput;
    case kAudioDevicePropertyPreferredChannelsForStereo:
      return OpenSoundcardIsInputScope(address->mScope);
    default:
      return false;
    }

  case OPENSOUNDCARD_INPUT_STREAM_OBJECT_ID:
    if (!OpenSoundcardIsGlobalScope(address->mScope)) {
      return false;
    }
    switch (address->mSelector) {
    case kAudioObjectPropertyBaseClass:
    case kAudioObjectPropertyClass:
    case kAudioObjectPropertyOwner:
    case kAudioObjectPropertyName:
    case kAudioObjectPropertyOwnedObjects:
    case kAudioStreamPropertyIsActive:
    case kAudioStreamPropertyDirection:
    case kAudioStreamPropertyTerminalType:
    case kAudioStreamPropertyStartingChannel:
    case kAudioStreamPropertyLatency:
    case kAudioStreamPropertyVirtualFormat:
    case kAudioStreamPropertyAvailableVirtualFormats:
    case kAudioStreamPropertyPhysicalFormat:
    case kAudioStreamPropertyAvailablePhysicalFormats:
      return true;
    default:
      return false;
    }

  default:
    return false;
  }
}

OSStatus
OpenSoundcardDeviceIsPropertySettable(AudioObjectID object_id,
                                      const AudioObjectPropertyAddress *address,
                                      Boolean *out_is_settable) {
  if (out_is_settable == NULL) {
    return kAudioHardwareBadPropertySizeError;
  }

  if (!OpenSoundcardDeviceHasProperty(object_id, address)) {
    return OpenSoundcardObjectExists(object_id)
               ? kAudioHardwareUnknownPropertyError
               : kAudioHardwareBadObjectError;
  }

  *out_is_settable = false;
  return kAudioHardwareNoError;
}

OSStatus OpenSoundcardDeviceGetPropertyDataSize(
    AudioObjectID object_id, const AudioObjectPropertyAddress *address,
    UInt32 qualifier_data_size, const void *qualifier_data,
    UInt32 *out_data_size) {
  (void)qualifier_data_size;
  (void)qualifier_data;

  if (out_data_size == NULL) {
    return kAudioHardwareBadPropertySizeError;
  }

  if (!OpenSoundcardDeviceHasProperty(object_id, address)) {
    return OpenSoundcardObjectExists(object_id)
               ? kAudioHardwareUnknownPropertyError
               : kAudioHardwareBadObjectError;
  }

  switch (address->mSelector) {
  case kAudioObjectPropertyName:
  case kAudioObjectPropertyModelName:
  case kAudioObjectPropertyManufacturer:
  case kAudioPlugInPropertyBundleID:
  case kAudioDevicePropertyDeviceUID:
  case kAudioDevicePropertyModelUID:
    *out_data_size = sizeof(CFStringRef);
    return kAudioHardwareNoError;

  case kAudioPlugInPropertyDeviceList:
  case kAudioDevicePropertyRelatedDevices:
    *out_data_size = sizeof(AudioObjectID);
    return kAudioHardwareNoError;

  case kAudioObjectPropertyOwnedObjects:
    *out_data_size = object_id == OPENSOUNDCARD_INPUT_STREAM_OBJECT_ID
                         ? 0
                         : sizeof(AudioObjectID);
    return kAudioHardwareNoError;

  case kAudioDevicePropertyStreams:
    *out_data_size = OpenSoundcardScopeExposesInputStream(address->mScope)
                         ? sizeof(AudioObjectID)
                         : 0;
    return kAudioHardwareNoError;

  case kAudioObjectPropertyControlList:
    *out_data_size = 0;
    return kAudioHardwareNoError;

  case kAudioDevicePropertyNominalSampleRate:
    *out_data_size = sizeof(Float64);
    return kAudioHardwareNoError;

  case kAudioDevicePropertyAvailableNominalSampleRates:
    *out_data_size = sizeof(AudioValueRange);
    return kAudioHardwareNoError;

  case kAudioDevicePropertyPreferredChannelsForStereo:
    if (!OpenSoundcardIsInputScope(address->mScope)) {
      return kAudioHardwareUnknownPropertyError;
    }
    *out_data_size = sizeof(UInt32) * 2;
    return kAudioHardwareNoError;

  case kAudioStreamPropertyVirtualFormat:
  case kAudioStreamPropertyPhysicalFormat:
    *out_data_size = sizeof(AudioStreamBasicDescription);
    return kAudioHardwareNoError;

  case kAudioStreamPropertyAvailableVirtualFormats:
  case kAudioStreamPropertyAvailablePhysicalFormats:
    *out_data_size = sizeof(AudioStreamRangedDescription);
    return kAudioHardwareNoError;

  default:
    *out_data_size = sizeof(UInt32);
    return kAudioHardwareNoError;
  }
}

OSStatus OpenSoundcardDeviceGetPropertyData(
    AudioObjectID object_id, const AudioObjectPropertyAddress *address,
    UInt32 qualifier_data_size, const void *qualifier_data, UInt32 data_size,
    UInt32 *out_data_size, void *out_data) {
  if (!OpenSoundcardDeviceHasProperty(object_id, address)) {
    return OpenSoundcardObjectExists(object_id)
               ? kAudioHardwareUnknownPropertyError
               : kAudioHardwareBadObjectError;
  }

  switch (object_id) {
  case kAudioObjectPlugInObject:
    switch (address->mSelector) {
    case kAudioObjectPropertyBaseClass:
      return OpenSoundcardCopyUInt32(data_size, out_data_size, out_data,
                                     kAudioObjectClassID);
    case kAudioObjectPropertyClass:
      return OpenSoundcardCopyUInt32(data_size, out_data_size, out_data,
                                     kAudioPlugInClassID);
    case kAudioObjectPropertyOwner:
      return OpenSoundcardCopyObjectID(data_size, out_data_size, out_data,
                                       kAudioObjectUnknown);
    case kAudioObjectPropertyOwnedObjects:
    case kAudioPlugInPropertyDeviceList:
      return OpenSoundcardCopyDeviceList(data_size, out_data_size, out_data);
    case kAudioPlugInPropertyBundleID:
      return OpenSoundcardCopyCFString(data_size, out_data_size, out_data,
                                       "org.opensoundcard.coreaudio.driver");
    case kAudioPlugInPropertyTranslateUIDToDevice:
      return OpenSoundcardCopyDeviceForUID(qualifier_data_size, qualifier_data,
                                           data_size, out_data_size, out_data);
    default:
      return kAudioHardwareUnknownPropertyError;
    }

  case OPENSOUNDCARD_DEVICE_OBJECT_ID:
    switch (address->mSelector) {
    case kAudioObjectPropertyBaseClass:
      return OpenSoundcardCopyUInt32(data_size, out_data_size, out_data,
                                     kAudioObjectClassID);
    case kAudioObjectPropertyClass:
      return OpenSoundcardCopyUInt32(data_size, out_data_size, out_data,
                                     kAudioDeviceClassID);
    case kAudioObjectPropertyOwner:
      return OpenSoundcardCopyObjectID(data_size, out_data_size, out_data,
                                       kAudioObjectPlugInObject);
    case kAudioObjectPropertyName:
    case kAudioObjectPropertyModelName:
      return OpenSoundcardCopyCFString(data_size, out_data_size, out_data,
                                       OPENSOUNDCARD_DEVICE_NAME);
    case kAudioObjectPropertyManufacturer:
      return OpenSoundcardCopyCFString(data_size, out_data_size, out_data,
                                       OPENSOUNDCARD_MANUFACTURER_NAME);
    case kAudioObjectPropertyOwnedObjects:
    case kAudioDevicePropertyStreams:
      return OpenSoundcardCopyStreamList(data_size, out_data_size, out_data,
                                         address->mScope);
    case kAudioObjectPropertyControlList:
      return OpenSoundcardCopyEmptyObjectList(data_size, out_data_size,
                                              out_data);
    case kAudioDevicePropertyDeviceUID:
      return OpenSoundcardCopyCFString(data_size, out_data_size, out_data,
                                       OPENSOUNDCARD_DEVICE_UID);
    case kAudioDevicePropertyModelUID:
      return OpenSoundcardCopyCFString(data_size, out_data_size, out_data,
                                       OPENSOUNDCARD_MODEL_UID);
    case kAudioDevicePropertyTransportType:
      return OpenSoundcardCopyUInt32(data_size, out_data_size, out_data,
                                     kAudioDeviceTransportTypeVirtual);
    case kAudioDevicePropertyRelatedDevices:
      return OpenSoundcardCopyDeviceList(data_size, out_data_size, out_data);
    case kAudioDevicePropertyClockDomain:
    case kAudioDevicePropertyLatency:
    case kAudioDevicePropertySafetyOffset:
    case kAudioDevicePropertyIsHidden:
    case kAudioDevicePropertyWantsControlsRestored:
    case kAudioDevicePropertyWantsStreamFormatsRestored:
      return OpenSoundcardCopyUInt32(data_size, out_data_size, out_data, 0);
    case kAudioDevicePropertyDeviceIsAlive:
    case kAudioDevicePropertyClockIsStable:
      return OpenSoundcardCopyUInt32(data_size, out_data_size, out_data, 1);
    case kAudioDevicePropertyDeviceIsRunning:
      return OpenSoundcardCopyUInt32(data_size, out_data_size, out_data,
                                     OpenSoundcardDeviceRunning());
    case kAudioDevicePropertyDeviceCanBeDefaultDevice:
      return OpenSoundcardCopyUInt32(
          data_size, out_data_size, out_data,
          OpenSoundcardIsInputScope(address->mScope) ? 1 : 0);
    case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
      return OpenSoundcardCopyUInt32(data_size, out_data_size, out_data, 0);
    case kAudioDevicePropertyNominalSampleRate:
      return OpenSoundcardCopyFloat64(data_size, out_data_size, out_data,
                                      OPENSOUNDCARD_SAMPLE_RATE);
    case kAudioDevicePropertyAvailableNominalSampleRates:
      return OpenSoundcardCopyAvailableSampleRates(data_size, out_data_size,
                                                   out_data);
    case kAudioDevicePropertyPreferredChannelsForStereo:
      return OpenSoundcardCopyPreferredStereoChannels(
          data_size, out_data_size, out_data, address->mScope);
    case kAudioDevicePropertyZeroTimeStampPeriod:
      return OpenSoundcardCopyUInt32(data_size, out_data_size, out_data,
                                     OPENSOUNDCARD_ZERO_TIMESTAMP_PERIOD);
    case kAudioDevicePropertyClockAlgorithm:
      return OpenSoundcardCopyUInt32(data_size, out_data_size, out_data,
                                     kAudioDeviceClockAlgorithmRaw);
    default:
      return kAudioHardwareUnknownPropertyError;
    }

  case OPENSOUNDCARD_INPUT_STREAM_OBJECT_ID:
    switch (address->mSelector) {
    case kAudioObjectPropertyBaseClass:
      return OpenSoundcardCopyUInt32(data_size, out_data_size, out_data,
                                     kAudioObjectClassID);
    case kAudioObjectPropertyClass:
      return OpenSoundcardCopyUInt32(data_size, out_data_size, out_data,
                                     kAudioStreamClassID);
    case kAudioObjectPropertyOwner:
      return OpenSoundcardCopyObjectID(data_size, out_data_size, out_data,
                                       OPENSOUNDCARD_DEVICE_OBJECT_ID);
    case kAudioObjectPropertyName:
      return OpenSoundcardCopyCFString(data_size, out_data_size, out_data,
                                       "OpenSoundcard GigaACE Input Stream");
    case kAudioObjectPropertyOwnedObjects:
      return OpenSoundcardCopyEmptyObjectList(data_size, out_data_size,
                                              out_data);
    case kAudioStreamPropertyIsActive:
    case kAudioStreamPropertyDirection:
      return OpenSoundcardCopyUInt32(data_size, out_data_size, out_data, 1);
    case kAudioStreamPropertyTerminalType:
      return OpenSoundcardCopyUInt32(data_size, out_data_size, out_data,
                                     kAudioStreamTerminalTypeMicrophone);
    case kAudioStreamPropertyStartingChannel:
      return OpenSoundcardCopyUInt32(data_size, out_data_size, out_data, 1);
    case kAudioStreamPropertyLatency:
      return OpenSoundcardCopyUInt32(data_size, out_data_size, out_data, 0);
    case kAudioStreamPropertyVirtualFormat:
    case kAudioStreamPropertyPhysicalFormat:
      return OpenSoundcardCopyStreamFormat(data_size, out_data_size, out_data);
    case kAudioStreamPropertyAvailableVirtualFormats:
    case kAudioStreamPropertyAvailablePhysicalFormats:
      return OpenSoundcardCopyAvailableStreamFormats(data_size, out_data_size,
                                                     out_data);
    default:
      return kAudioHardwareUnknownPropertyError;
    }

  default:
    return kAudioHardwareBadObjectError;
  }
}

OSStatus
OpenSoundcardDeviceSetPropertyData(AudioObjectID object_id,
                                   const AudioObjectPropertyAddress *address,
                                   UInt32 data_size, const void *data) {
  (void)data_size;
  (void)data;

  if (!OpenSoundcardDeviceHasProperty(object_id, address)) {
    return OpenSoundcardObjectExists(object_id)
               ? kAudioHardwareUnknownPropertyError
               : kAudioHardwareBadObjectError;
  }

  return kAudioHardwareIllegalOperationError;
}

OSStatus OpenSoundcardDeviceStartIO(AudioObjectID device_object_id,
                                    UInt32 client_id) {
  (void)client_id;

  if (device_object_id != OPENSOUNDCARD_DEVICE_OBJECT_ID) {
    return kAudioHardwareBadDeviceError;
  }

  if (!g_device.initialized && !OpenSoundcardDeviceInitialize()) {
    return kAudioHardwareNotReadyError;
  }

  const UInt32 previous = atomic_fetch_add_explicit(
      &g_device.running_client_count, 1, memory_order_relaxed);
  if (previous == 0) {
    g_device.clock_seed += 1;
    osc_engine_set_running(g_device.engine, true);
  }

  return kAudioHardwareNoError;
}

OSStatus OpenSoundcardDeviceStopIO(AudioObjectID device_object_id,
                                   UInt32 client_id) {
  (void)client_id;

  if (device_object_id != OPENSOUNDCARD_DEVICE_OBJECT_ID) {
    return kAudioHardwareBadDeviceError;
  }

  const UInt32 previous = atomic_load_explicit(&g_device.running_client_count,
                                               memory_order_relaxed);
  if (previous == 0) {
    return kAudioHardwareNoError;
  }

  const UInt32 prior = atomic_fetch_sub_explicit(&g_device.running_client_count,
                                                 1, memory_order_relaxed);
  if (prior == 1) {
    osc_engine_set_running(g_device.engine, false);
  }

  return kAudioHardwareNoError;
}

OSStatus OpenSoundcardDeviceGetZeroTimeStamp(AudioObjectID device_object_id,
                                             Float64 *out_sample_time,
                                             UInt64 *out_host_time,
                                             UInt64 *out_seed) {
  if (device_object_id != OPENSOUNDCARD_DEVICE_OBJECT_ID) {
    return kAudioHardwareBadDeviceError;
  }

  if (out_sample_time == NULL || out_host_time == NULL || out_seed == NULL) {
    return kAudioHardwareBadPropertySizeError;
  }

  if (!g_device.initialized && !OpenSoundcardDeviceInitialize()) {
    return kAudioHardwareNotReadyError;
  }

  const UInt64 now = mach_absolute_time();
  const UInt64 elapsed_ticks = now - g_device.host_time_anchor;
  const Float64 elapsed_frames =
      floor((Float64)elapsed_ticks / g_device.host_ticks_per_frame);
  const UInt64 period = OPENSOUNDCARD_ZERO_TIMESTAMP_PERIOD;
  const UInt64 period_count = (UInt64)(elapsed_frames / (Float64)period);
  const UInt64 sample_frame = period_count * period;

  *out_sample_time = (Float64)sample_frame;
  *out_host_time =
      g_device.host_time_anchor +
      (UInt64)((Float64)sample_frame * g_device.host_ticks_per_frame);
  *out_seed = g_device.clock_seed;
  return kAudioHardwareNoError;
}

OSStatus OpenSoundcardDeviceWillDoIOOperation(AudioObjectID device_object_id,
                                              UInt32 operation_id,
                                              Boolean *out_will_do,
                                              Boolean *out_will_do_in_place) {
  if (device_object_id != OPENSOUNDCARD_DEVICE_OBJECT_ID) {
    return kAudioHardwareBadDeviceError;
  }

  if (out_will_do == NULL || out_will_do_in_place == NULL) {
    return kAudioHardwareBadPropertySizeError;
  }

  const Boolean handles_read =
      operation_id == kAudioServerPlugInIOOperationReadInput;
  *out_will_do = handles_read;
  *out_will_do_in_place = handles_read;
  return kAudioHardwareNoError;
}

OSStatus OpenSoundcardDeviceBeginIOOperation(AudioObjectID device_object_id,
                                             UInt32 operation_id) {
  (void)operation_id;

  if (device_object_id != OPENSOUNDCARD_DEVICE_OBJECT_ID) {
    return kAudioHardwareBadDeviceError;
  }

  return kAudioHardwareNoError;
}

OSStatus OpenSoundcardDeviceDoIOOperation(AudioObjectID device_object_id,
                                          AudioObjectID stream_object_id,
                                          UInt32 operation_id,
                                          UInt32 io_buffer_frame_size,
                                          void *io_main_buffer) {
  if (device_object_id != OPENSOUNDCARD_DEVICE_OBJECT_ID) {
    return kAudioHardwareBadDeviceError;
  }

  if (stream_object_id != OPENSOUNDCARD_INPUT_STREAM_OBJECT_ID) {
    return kAudioHardwareBadStreamError;
  }

  if (operation_id != kAudioServerPlugInIOOperationReadInput) {
    return kAudioHardwareUnsupportedOperationError;
  }

  if (io_main_buffer == NULL) {
    return kAudioHardwareBadPropertySizeError;
  }

  const size_t sample_count =
      (size_t)io_buffer_frame_size * (size_t)OPENSOUNDCARD_CHANNEL_COUNT;
  Float32 *output = (Float32 *)io_main_buffer;

  if (!g_device.initialized || g_device.engine == NULL ||
      OpenSoundcardDeviceRunning() == 0) {
    memset(output, 0, sample_count * sizeof(Float32));
    return kAudioHardwareNoError;
  }

  const uint32_t frames_read = osc_engine_read_interleaved(
      g_device.engine, output, (uint32_t)io_buffer_frame_size);
  if (frames_read < io_buffer_frame_size) {
    Float32 *silence_start =
        output + ((size_t)frames_read * OPENSOUNDCARD_CHANNEL_COUNT);
    const size_t silence_count = ((size_t)io_buffer_frame_size - frames_read) *
                                 OPENSOUNDCARD_CHANNEL_COUNT;
    memset(silence_start, 0, silence_count * sizeof(Float32));
  }

  return kAudioHardwareNoError;
}

OSStatus OpenSoundcardDeviceEndIOOperation(AudioObjectID device_object_id,
                                           UInt32 operation_id) {
  (void)operation_id;

  if (device_object_id != OPENSOUNDCARD_DEVICE_OBJECT_ID) {
    return kAudioHardwareBadDeviceError;
  }

  return kAudioHardwareNoError;
}
