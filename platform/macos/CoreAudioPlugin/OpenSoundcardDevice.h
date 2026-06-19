#ifndef OPENSOUNDCARD_DEVICE_H
#define OPENSOUNDCARD_DEVICE_H

#include <CoreAudio/AudioServerPlugIn.h>
#include <stdbool.h>

#define OPENSOUNDCARD_DEVICE_OBJECT_ID ((AudioObjectID)2)
#define OPENSOUNDCARD_INPUT_STREAM_OBJECT_ID ((AudioObjectID)3)

#define OPENSOUNDCARD_DEVICE_NAME "OpenSoundcard GigaACE"
#define OPENSOUNDCARD_MANUFACTURER_NAME "OpenSoundcard"
#define OPENSOUNDCARD_DEVICE_UID "org.opensoundcard.gigace.input"
#define OPENSOUNDCARD_MODEL_UID "org.opensoundcard.gigace"
#define OPENSOUNDCARD_CHANNEL_COUNT ((UInt32)64)
#define OPENSOUNDCARD_SAMPLE_RATE ((Float64)48000.0)
#define OPENSOUNDCARD_ENGINE_CAPACITY_FRAMES ((UInt32)48000)
#define OPENSOUNDCARD_ZERO_TIMESTAMP_PERIOD ((UInt32)16384)
#define OPENSOUNDCARD_BRIDGE_CONTROL_PATH "/tmp/opensoundcard_manager_control"
#define OPENSOUNDCARD_BRIDGE_STATUS_PATH "/tmp/opensoundcard_manager_status"

bool OpenSoundcardDeviceInitialize(void);
void OpenSoundcardDeviceDestroy(void);

Boolean
OpenSoundcardDeviceHasProperty(AudioObjectID object_id,
                               const AudioObjectPropertyAddress *address);
OSStatus
OpenSoundcardDeviceIsPropertySettable(AudioObjectID object_id,
                                      const AudioObjectPropertyAddress *address,
                                      Boolean *out_is_settable);
OSStatus OpenSoundcardDeviceGetPropertyDataSize(
    AudioObjectID object_id, const AudioObjectPropertyAddress *address,
    UInt32 qualifier_data_size, const void *qualifier_data,
    UInt32 *out_data_size);
OSStatus OpenSoundcardDeviceGetPropertyData(
    AudioObjectID object_id, const AudioObjectPropertyAddress *address,
    UInt32 qualifier_data_size, const void *qualifier_data, UInt32 data_size,
    UInt32 *out_data_size, void *out_data);
OSStatus
OpenSoundcardDeviceSetPropertyData(AudioObjectID object_id,
                                   const AudioObjectPropertyAddress *address,
                                   UInt32 data_size, const void *data);

OSStatus OpenSoundcardDeviceStartIO(AudioObjectID device_object_id,
                                    UInt32 client_id);
OSStatus OpenSoundcardDeviceStopIO(AudioObjectID device_object_id,
                                   UInt32 client_id);
OSStatus OpenSoundcardDeviceGetZeroTimeStamp(AudioObjectID device_object_id,
                                             Float64 *out_sample_time,
                                             UInt64 *out_host_time,
                                             UInt64 *out_seed);
OSStatus OpenSoundcardDeviceWillDoIOOperation(AudioObjectID device_object_id,
                                              UInt32 operation_id,
                                              Boolean *out_will_do,
                                              Boolean *out_will_do_in_place);
OSStatus OpenSoundcardDeviceBeginIOOperation(AudioObjectID device_object_id,
                                             UInt32 operation_id);
OSStatus OpenSoundcardDeviceDoIOOperation(AudioObjectID device_object_id,
                                          AudioObjectID stream_object_id,
                                          UInt32 operation_id,
                                          UInt32 io_buffer_frame_size,
                                          void *io_main_buffer);
OSStatus OpenSoundcardDeviceEndIOOperation(AudioObjectID device_object_id,
                                           UInt32 operation_id);

#endif
