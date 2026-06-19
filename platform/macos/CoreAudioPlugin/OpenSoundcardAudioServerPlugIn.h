#ifndef OPENSOUNDCARD_AUDIO_SERVER_PLUGIN_H
#define OPENSOUNDCARD_AUDIO_SERVER_PLUGIN_H

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>

void *AudioServerPlugInFactory(CFAllocatorRef allocator, CFUUIDRef type_uuid);

#endif
