#include "OpenSoundcardAudioServerPlugIn.h"

#include "OpenSoundcardDevice.h"

#include <CoreFoundation/CFPlugInCOM.h>
#include <stdatomic.h>

static HRESULT OpenSoundcardDriverQueryInterface(void *driver, REFIID uuid,
                                                 LPVOID *out_interface);
static ULONG OpenSoundcardDriverAddRef(void *driver);
static ULONG OpenSoundcardDriverRelease(void *driver);
static OSStatus OpenSoundcardDriverInitialize(AudioServerPlugInDriverRef driver,
                                              AudioServerPlugInHostRef host);
static OSStatus
OpenSoundcardDriverCreateDevice(AudioServerPlugInDriverRef driver,
                                CFDictionaryRef description,
                                const AudioServerPlugInClientInfo *client_info,
                                AudioObjectID *out_device_object_id);
static OSStatus
OpenSoundcardDriverDestroyDevice(AudioServerPlugInDriverRef driver,
                                 AudioObjectID device_object_id);
static OSStatus OpenSoundcardDriverAddDeviceClient(
    AudioServerPlugInDriverRef driver, AudioObjectID device_object_id,
    const AudioServerPlugInClientInfo *client_info);
static OSStatus OpenSoundcardDriverRemoveDeviceClient(
    AudioServerPlugInDriverRef driver, AudioObjectID device_object_id,
    const AudioServerPlugInClientInfo *client_info);
static OSStatus OpenSoundcardDriverPerformDeviceConfigurationChange(
    AudioServerPlugInDriverRef driver, AudioObjectID device_object_id,
    UInt64 change_action, void *change_info);
static OSStatus OpenSoundcardDriverAbortDeviceConfigurationChange(
    AudioServerPlugInDriverRef driver, AudioObjectID device_object_id,
    UInt64 change_action, void *change_info);
static Boolean
OpenSoundcardDriverHasProperty(AudioServerPlugInDriverRef driver,
                               AudioObjectID object_id, pid_t client_process_id,
                               const AudioObjectPropertyAddress *address);
static OSStatus OpenSoundcardDriverIsPropertySettable(
    AudioServerPlugInDriverRef driver, AudioObjectID object_id,
    pid_t client_process_id, const AudioObjectPropertyAddress *address,
    Boolean *out_is_settable);
static OSStatus OpenSoundcardDriverGetPropertyDataSize(
    AudioServerPlugInDriverRef driver, AudioObjectID object_id,
    pid_t client_process_id, const AudioObjectPropertyAddress *address,
    UInt32 qualifier_data_size, const void *qualifier_data,
    UInt32 *out_data_size);
static OSStatus OpenSoundcardDriverGetPropertyData(
    AudioServerPlugInDriverRef driver, AudioObjectID object_id,
    pid_t client_process_id, const AudioObjectPropertyAddress *address,
    UInt32 qualifier_data_size, const void *qualifier_data, UInt32 data_size,
    UInt32 *out_data_size, void *out_data);
static OSStatus OpenSoundcardDriverSetPropertyData(
    AudioServerPlugInDriverRef driver, AudioObjectID object_id,
    pid_t client_process_id, const AudioObjectPropertyAddress *address,
    UInt32 qualifier_data_size, const void *qualifier_data, UInt32 data_size,
    const void *data);
static OSStatus OpenSoundcardDriverStartIO(AudioServerPlugInDriverRef driver,
                                           AudioObjectID device_object_id,
                                           UInt32 client_id);
static OSStatus OpenSoundcardDriverStopIO(AudioServerPlugInDriverRef driver,
                                          AudioObjectID device_object_id,
                                          UInt32 client_id);
static OSStatus
OpenSoundcardDriverGetZeroTimeStamp(AudioServerPlugInDriverRef driver,
                                    AudioObjectID device_object_id,
                                    UInt32 client_id, Float64 *out_sample_time,
                                    UInt64 *out_host_time, UInt64 *out_seed);
static OSStatus OpenSoundcardDriverWillDoIOOperation(
    AudioServerPlugInDriverRef driver, AudioObjectID device_object_id,
    UInt32 client_id, UInt32 operation_id, Boolean *out_will_do,
    Boolean *out_will_do_in_place);
static OSStatus OpenSoundcardDriverBeginIOOperation(
    AudioServerPlugInDriverRef driver, AudioObjectID device_object_id,
    UInt32 client_id, UInt32 operation_id, UInt32 io_buffer_frame_size,
    const AudioServerPlugInIOCycleInfo *io_cycle_info);
static OSStatus OpenSoundcardDriverDoIOOperation(
    AudioServerPlugInDriverRef driver, AudioObjectID device_object_id,
    AudioObjectID stream_object_id, UInt32 client_id, UInt32 operation_id,
    UInt32 io_buffer_frame_size,
    const AudioServerPlugInIOCycleInfo *io_cycle_info, void *io_main_buffer,
    void *io_secondary_buffer);
static OSStatus OpenSoundcardDriverEndIOOperation(
    AudioServerPlugInDriverRef driver, AudioObjectID device_object_id,
    UInt32 client_id, UInt32 operation_id, UInt32 io_buffer_frame_size,
    const AudioServerPlugInIOCycleInfo *io_cycle_info);

static AudioServerPlugInDriverInterface g_driver_vtable = {
    NULL,
    OpenSoundcardDriverQueryInterface,
    OpenSoundcardDriverAddRef,
    OpenSoundcardDriverRelease,
    OpenSoundcardDriverInitialize,
    OpenSoundcardDriverCreateDevice,
    OpenSoundcardDriverDestroyDevice,
    OpenSoundcardDriverAddDeviceClient,
    OpenSoundcardDriverRemoveDeviceClient,
    OpenSoundcardDriverPerformDeviceConfigurationChange,
    OpenSoundcardDriverAbortDeviceConfigurationChange,
    OpenSoundcardDriverHasProperty,
    OpenSoundcardDriverIsPropertySettable,
    OpenSoundcardDriverGetPropertyDataSize,
    OpenSoundcardDriverGetPropertyData,
    OpenSoundcardDriverSetPropertyData,
    OpenSoundcardDriverStartIO,
    OpenSoundcardDriverStopIO,
    OpenSoundcardDriverGetZeroTimeStamp,
    OpenSoundcardDriverWillDoIOOperation,
    OpenSoundcardDriverBeginIOOperation,
    OpenSoundcardDriverDoIOOperation,
    OpenSoundcardDriverEndIOOperation,
};

static AudioServerPlugInDriverInterface *g_driver_interface = &g_driver_vtable;
static atomic_uint g_reference_count = 1;
static AudioServerPlugInHostRef g_host = NULL;

void *AudioServerPlugInFactory(CFAllocatorRef allocator, CFUUIDRef type_uuid) {
  (void)allocator;

  if (type_uuid != NULL && CFEqual(type_uuid, kAudioServerPlugInTypeUUID)) {
    OpenSoundcardDriverAddRef(&g_driver_interface);
    return &g_driver_interface;
  }

  return NULL;
}

static HRESULT OpenSoundcardDriverQueryInterface(void *driver, REFIID uuid,
                                                 LPVOID *out_interface) {
  (void)driver;

  if (out_interface == NULL) {
    return E_POINTER;
  }

  *out_interface = NULL;

  CFUUIDRef requested_uuid = CFUUIDCreateFromUUIDBytes(NULL, uuid);
  if (requested_uuid == NULL) {
    return E_NOINTERFACE;
  }

  const Boolean matches_driver =
      CFEqual(requested_uuid, kAudioServerPlugInDriverInterfaceUUID);
  const Boolean matches_unknown = CFEqual(requested_uuid, IUnknownUUID);
  CFRelease(requested_uuid);

  if (!matches_driver && !matches_unknown) {
    return E_NOINTERFACE;
  }

  OpenSoundcardDriverAddRef(&g_driver_interface);
  *out_interface = &g_driver_interface;
  return S_OK;
}

static ULONG OpenSoundcardDriverAddRef(void *driver) {
  (void)driver;
  return atomic_fetch_add_explicit(&g_reference_count, 1,
                                   memory_order_relaxed) +
         1;
}

static ULONG OpenSoundcardDriverRelease(void *driver) {
  (void)driver;

  const UInt32 previous =
      atomic_fetch_sub_explicit(&g_reference_count, 1, memory_order_relaxed);
  if (previous == 1) {
    atomic_store_explicit(&g_reference_count, 1, memory_order_relaxed);
    OpenSoundcardDeviceDestroy();
    return 0;
  }

  return previous - 1;
}

static OSStatus OpenSoundcardDriverInitialize(AudioServerPlugInDriverRef driver,
                                              AudioServerPlugInHostRef host) {
  (void)driver;
  g_host = host;
  return OpenSoundcardDeviceInitialize() ? kAudioHardwareNoError
                                         : kAudioHardwareNotReadyError;
}

static OSStatus
OpenSoundcardDriverCreateDevice(AudioServerPlugInDriverRef driver,
                                CFDictionaryRef description,
                                const AudioServerPlugInClientInfo *client_info,
                                AudioObjectID *out_device_object_id) {
  (void)driver;
  (void)description;
  (void)client_info;
  (void)out_device_object_id;
  return kAudioHardwareUnsupportedOperationError;
}

static OSStatus
OpenSoundcardDriverDestroyDevice(AudioServerPlugInDriverRef driver,
                                 AudioObjectID device_object_id) {
  (void)driver;
  (void)device_object_id;
  return kAudioHardwareUnsupportedOperationError;
}

static OSStatus OpenSoundcardDriverAddDeviceClient(
    AudioServerPlugInDriverRef driver, AudioObjectID device_object_id,
    const AudioServerPlugInClientInfo *client_info) {
  (void)driver;
  (void)client_info;

  if (device_object_id != OPENSOUNDCARD_DEVICE_OBJECT_ID) {
    return kAudioHardwareBadDeviceError;
  }

  return kAudioHardwareNoError;
}

static OSStatus OpenSoundcardDriverRemoveDeviceClient(
    AudioServerPlugInDriverRef driver, AudioObjectID device_object_id,
    const AudioServerPlugInClientInfo *client_info) {
  (void)driver;
  (void)client_info;

  if (device_object_id != OPENSOUNDCARD_DEVICE_OBJECT_ID) {
    return kAudioHardwareBadDeviceError;
  }

  return kAudioHardwareNoError;
}

static OSStatus OpenSoundcardDriverPerformDeviceConfigurationChange(
    AudioServerPlugInDriverRef driver, AudioObjectID device_object_id,
    UInt64 change_action, void *change_info) {
  (void)driver;
  (void)device_object_id;
  (void)change_action;
  (void)change_info;
  return kAudioHardwareNoError;
}

static OSStatus OpenSoundcardDriverAbortDeviceConfigurationChange(
    AudioServerPlugInDriverRef driver, AudioObjectID device_object_id,
    UInt64 change_action, void *change_info) {
  (void)driver;
  (void)device_object_id;
  (void)change_action;
  (void)change_info;
  return kAudioHardwareNoError;
}

static Boolean
OpenSoundcardDriverHasProperty(AudioServerPlugInDriverRef driver,
                               AudioObjectID object_id, pid_t client_process_id,
                               const AudioObjectPropertyAddress *address) {
  (void)driver;
  (void)client_process_id;
  return OpenSoundcardDeviceHasProperty(object_id, address);
}

static OSStatus OpenSoundcardDriverIsPropertySettable(
    AudioServerPlugInDriverRef driver, AudioObjectID object_id,
    pid_t client_process_id, const AudioObjectPropertyAddress *address,
    Boolean *out_is_settable) {
  (void)driver;
  (void)client_process_id;
  return OpenSoundcardDeviceIsPropertySettable(object_id, address,
                                               out_is_settable);
}

static OSStatus OpenSoundcardDriverGetPropertyDataSize(
    AudioServerPlugInDriverRef driver, AudioObjectID object_id,
    pid_t client_process_id, const AudioObjectPropertyAddress *address,
    UInt32 qualifier_data_size, const void *qualifier_data,
    UInt32 *out_data_size) {
  (void)driver;
  (void)client_process_id;
  return OpenSoundcardDeviceGetPropertyDataSize(
      object_id, address, qualifier_data_size, qualifier_data, out_data_size);
}

static OSStatus OpenSoundcardDriverGetPropertyData(
    AudioServerPlugInDriverRef driver, AudioObjectID object_id,
    pid_t client_process_id, const AudioObjectPropertyAddress *address,
    UInt32 qualifier_data_size, const void *qualifier_data, UInt32 data_size,
    UInt32 *out_data_size, void *out_data) {
  (void)driver;
  (void)client_process_id;
  return OpenSoundcardDeviceGetPropertyData(object_id, address,
                                            qualifier_data_size, qualifier_data,
                                            data_size, out_data_size, out_data);
}

static OSStatus OpenSoundcardDriverSetPropertyData(
    AudioServerPlugInDriverRef driver, AudioObjectID object_id,
    pid_t client_process_id, const AudioObjectPropertyAddress *address,
    UInt32 qualifier_data_size, const void *qualifier_data, UInt32 data_size,
    const void *data) {
  (void)driver;
  (void)client_process_id;
  (void)qualifier_data_size;
  (void)qualifier_data;
  return OpenSoundcardDeviceSetPropertyData(object_id, address, data_size,
                                            data);
}

static OSStatus OpenSoundcardDriverStartIO(AudioServerPlugInDriverRef driver,
                                           AudioObjectID device_object_id,
                                           UInt32 client_id) {
  (void)driver;
  return OpenSoundcardDeviceStartIO(device_object_id, client_id);
}

static OSStatus OpenSoundcardDriverStopIO(AudioServerPlugInDriverRef driver,
                                          AudioObjectID device_object_id,
                                          UInt32 client_id) {
  (void)driver;
  return OpenSoundcardDeviceStopIO(device_object_id, client_id);
}

static OSStatus
OpenSoundcardDriverGetZeroTimeStamp(AudioServerPlugInDriverRef driver,
                                    AudioObjectID device_object_id,
                                    UInt32 client_id, Float64 *out_sample_time,
                                    UInt64 *out_host_time, UInt64 *out_seed) {
  (void)driver;
  (void)client_id;
  return OpenSoundcardDeviceGetZeroTimeStamp(device_object_id, out_sample_time,
                                             out_host_time, out_seed);
}

static OSStatus OpenSoundcardDriverWillDoIOOperation(
    AudioServerPlugInDriverRef driver, AudioObjectID device_object_id,
    UInt32 client_id, UInt32 operation_id, Boolean *out_will_do,
    Boolean *out_will_do_in_place) {
  (void)driver;
  (void)client_id;
  return OpenSoundcardDeviceWillDoIOOperation(
      device_object_id, operation_id, out_will_do, out_will_do_in_place);
}

static OSStatus OpenSoundcardDriverBeginIOOperation(
    AudioServerPlugInDriverRef driver, AudioObjectID device_object_id,
    UInt32 client_id, UInt32 operation_id, UInt32 io_buffer_frame_size,
    const AudioServerPlugInIOCycleInfo *io_cycle_info) {
  (void)driver;
  (void)client_id;
  (void)io_buffer_frame_size;
  (void)io_cycle_info;
  return OpenSoundcardDeviceBeginIOOperation(device_object_id, operation_id);
}

static OSStatus OpenSoundcardDriverDoIOOperation(
    AudioServerPlugInDriverRef driver, AudioObjectID device_object_id,
    AudioObjectID stream_object_id, UInt32 client_id, UInt32 operation_id,
    UInt32 io_buffer_frame_size,
    const AudioServerPlugInIOCycleInfo *io_cycle_info, void *io_main_buffer,
    void *io_secondary_buffer) {
  (void)driver;
  (void)client_id;
  (void)io_cycle_info;
  (void)io_secondary_buffer;
  return OpenSoundcardDeviceDoIOOperation(device_object_id, stream_object_id,
                                          operation_id, io_buffer_frame_size,
                                          io_main_buffer);
}

static OSStatus OpenSoundcardDriverEndIOOperation(
    AudioServerPlugInDriverRef driver, AudioObjectID device_object_id,
    UInt32 client_id, UInt32 operation_id, UInt32 io_buffer_frame_size,
    const AudioServerPlugInIOCycleInfo *io_cycle_info) {
  (void)driver;
  (void)client_id;
  (void)io_buffer_frame_size;
  (void)io_cycle_info;
  return OpenSoundcardDeviceEndIOOperation(device_object_id, operation_id);
}
