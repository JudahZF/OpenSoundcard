/// Stream lifecycle state shared by the CoreAudio plug-in and manager.
#[repr(C)]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum OscStreamState {
    Stopped = 0,
    Starting = 1,
    Running = 2,
    Underrun = 3,
    Error = 4,
}

impl Default for OscStreamState {
    fn default() -> Self {
        Self::Stopped
    }
}

/// Point-in-time stream status for FFI consumers.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct OscStatusSnapshot {
    pub state: OscStreamState,
    pub sample_rate: f64,
    pub channel_count: u32,
    pub capacity_frames: u32,
    pub read_index: u64,
    pub write_index: u64,
    pub packet_count: u64,
    pub decoded_frame_count: u64,
    pub underrun_count: u64,
    pub overrun_count: u64,
    pub last_error_code: i32,
}

impl Default for OscStatusSnapshot {
    fn default() -> Self {
        Self {
            state: OscStreamState::Stopped,
            sample_rate: 0.0,
            channel_count: 0,
            capacity_frames: 0,
            read_index: 0,
            write_index: 0,
            packet_count: 0,
            decoded_frame_count: 0,
            underrun_count: 0,
            overrun_count: 0,
            last_error_code: 0,
        }
    }
}
