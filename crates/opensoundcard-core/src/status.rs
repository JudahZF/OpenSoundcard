/// Stream lifecycle state shared by the CoreAudio plug-in and manager.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum OscStreamState {
    #[default]
    Stopped = 0,
    Starting = 1,
    Running = 2,
    Underrun = 3,
    Error = 4,
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::mem::{align_of, offset_of, size_of};

    #[test]
    fn stream_state_has_c_abi_layout() {
        assert_eq!(size_of::<OscStreamState>(), 4);
        assert_eq!(align_of::<OscStreamState>(), 4);
        assert_eq!(OscStreamState::Stopped as u32, 0);
        assert_eq!(OscStreamState::Starting as u32, 1);
        assert_eq!(OscStreamState::Running as u32, 2);
        assert_eq!(OscStreamState::Underrun as u32, 3);
        assert_eq!(OscStreamState::Error as u32, 4);
    }

    #[test]
    fn status_snapshot_has_c_abi_layout() {
        assert_eq!(size_of::<OscStatusSnapshot>(), 80);
        assert_eq!(align_of::<OscStatusSnapshot>(), 8);
        assert_eq!(offset_of!(OscStatusSnapshot, state), 0);
        assert_eq!(offset_of!(OscStatusSnapshot, sample_rate), 8);
        assert_eq!(offset_of!(OscStatusSnapshot, channel_count), 16);
        assert_eq!(offset_of!(OscStatusSnapshot, capacity_frames), 20);
        assert_eq!(offset_of!(OscStatusSnapshot, read_index), 24);
        assert_eq!(offset_of!(OscStatusSnapshot, write_index), 32);
        assert_eq!(offset_of!(OscStatusSnapshot, packet_count), 40);
        assert_eq!(offset_of!(OscStatusSnapshot, decoded_frame_count), 48);
        assert_eq!(offset_of!(OscStatusSnapshot, underrun_count), 56);
        assert_eq!(offset_of!(OscStatusSnapshot, overrun_count), 64);
        assert_eq!(offset_of!(OscStatusSnapshot, last_error_code), 72);
    }
}
