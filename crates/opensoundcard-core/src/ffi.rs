use std::ffi::c_void;
use std::slice;
use std::sync::Mutex;

use crate::ring::OscPcmRing;
use crate::status::{OscStatusSnapshot, OscStreamState};

struct OscEngineInner {
    ring: OscPcmRing,
    state: OscStreamState,
    sample_rate: f64,
    packet_count: u64,
    decoded_frame_count: u64,
    last_error_code: i32,
}

struct OscEngine {
    inner: Mutex<OscEngineInner>,
}

impl OscEngineInner {
    fn new(channel_count: usize, capacity_frames: usize, sample_rate: f64) -> Self {
        Self {
            ring: OscPcmRing::with_channel_count(channel_count, capacity_frames),
            state: OscStreamState::Stopped,
            sample_rate,
            packet_count: 0,
            decoded_frame_count: 0,
            last_error_code: 0,
        }
    }

    fn status_snapshot(&self) -> OscStatusSnapshot {
        self.ring.status_snapshot(
            self.state,
            self.sample_rate,
            self.packet_count,
            self.decoded_frame_count,
            self.last_error_code,
        )
    }
}

fn engine_from_raw<'a>(engine: *mut c_void) -> Option<&'a OscEngine> {
    if engine.is_null() {
        return None;
    }

    Some(unsafe { &*(engine.cast::<OscEngine>()) })
}

fn sample_len(engine: &OscEngineInner, frame_count: u32) -> Option<usize> {
    (frame_count as usize).checked_mul(engine.ring.channel_count())
}

/// Create an opaque OpenSoundcard engine for use through the C ABI.
///
/// Returns null when any engine parameter is invalid.
#[no_mangle]
pub extern "C" fn osc_engine_create(
    channels: u32,
    capacity_frames: u32,
    sample_rate: f64,
) -> *mut c_void {
    if channels == 0 || capacity_frames == 0 || !sample_rate.is_finite() || sample_rate <= 0.0 {
        return std::ptr::null_mut();
    }

    let channel_count = channels as usize;
    let capacity_frames = capacity_frames as usize;
    if channel_count.checked_mul(capacity_frames).is_none() {
        return std::ptr::null_mut();
    }

    let engine = OscEngine {
        inner: Mutex::new(OscEngineInner::new(
            channel_count,
            capacity_frames,
            sample_rate,
        )),
    };

    Box::into_raw(Box::new(engine)).cast::<c_void>()
}

/// Destroy an engine created by `osc_engine_create`.
///
/// Passing null is allowed and has no effect.
#[no_mangle]
///
/// # Safety
///
/// `engine` must be either null or a pointer returned by `osc_engine_create`
/// that has not already been destroyed.
pub unsafe extern "C" fn osc_engine_destroy(engine: *mut c_void) {
    if engine.is_null() {
        return;
    }

    unsafe {
        drop(Box::from_raw(engine.cast::<OscEngine>()));
    }
}

/// Read interleaved float32 frames from the engine into `output`.
///
/// Missing frames are zero-filled by the core ring buffer.
#[no_mangle]
///
/// # Safety
///
/// `engine` must be either null or a live pointer returned by
/// `osc_engine_create`. When `frame_count` is non-zero, `output` must point to
/// writable storage for `frame_count * channel_count` float samples.
pub unsafe extern "C" fn osc_engine_read_interleaved(
    engine: *mut c_void,
    output: *mut f32,
    frame_count: u32,
) -> u32 {
    let Some(engine) = engine_from_raw(engine) else {
        return 0;
    };

    let Ok(mut inner) = engine.inner.lock() else {
        return 0;
    };

    let Some(sample_count) = sample_len(&inner, frame_count) else {
        return 0;
    };

    if sample_count == 0 {
        return 0;
    }

    if output.is_null() {
        return 0;
    }

    let output = unsafe { slice::from_raw_parts_mut(output, sample_count) };
    let previous_underruns = inner.ring.underrun_count();
    let frames_read = inner.ring.read_interleaved(output);

    if inner.state == OscStreamState::Running && inner.ring.underrun_count() > previous_underruns {
        inner.state = OscStreamState::Underrun;
    }

    frames_read as u32
}

/// Write interleaved float32 frames into the engine.
#[no_mangle]
///
/// # Safety
///
/// `engine` must be either null or a live pointer returned by
/// `osc_engine_create`. When `frame_count` is non-zero, `input` must point to
/// readable storage for `frame_count * channel_count` float samples.
pub unsafe extern "C" fn osc_engine_write_interleaved(
    engine: *mut c_void,
    input: *const f32,
    frame_count: u32,
) {
    let Some(engine) = engine_from_raw(engine) else {
        return;
    };

    let Ok(mut inner) = engine.inner.lock() else {
        return;
    };

    let Some(sample_count) = sample_len(&inner, frame_count) else {
        return;
    };

    if sample_count == 0 {
        return;
    }

    if input.is_null() {
        return;
    }

    let input = unsafe { slice::from_raw_parts(input, sample_count) };
    let frames_written = inner.ring.write_interleaved(input);
    inner.packet_count += 1;
    inner.decoded_frame_count += frames_written as u64;

    if inner.state == OscStreamState::Underrun {
        inner.state = OscStreamState::Running;
    }
}

/// Copy the current engine status into `out_status`.
#[no_mangle]
///
/// # Safety
///
/// `engine` must be either null or a live pointer returned by
/// `osc_engine_create`. `out_status` must be either null or point to writable
/// storage for one `OscStatusSnapshot`.
pub unsafe extern "C" fn osc_engine_get_status(
    engine: *mut c_void,
    out_status: *mut OscStatusSnapshot,
) {
    if out_status.is_null() {
        return;
    }

    let Some(engine) = engine_from_raw(engine) else {
        unsafe {
            *out_status = OscStatusSnapshot::default();
        }
        return;
    };

    let Ok(inner) = engine.inner.lock() else {
        unsafe {
            *out_status = OscStatusSnapshot::default();
        }
        return;
    };

    unsafe {
        *out_status = inner.status_snapshot();
    }
}

/// Set whether the engine should report itself as running.
#[no_mangle]
///
/// # Safety
///
/// `engine` must be either null or a live pointer returned by
/// `osc_engine_create`.
pub unsafe extern "C" fn osc_engine_set_running(engine: *mut c_void, running: bool) {
    let Some(engine) = engine_from_raw(engine) else {
        return;
    };

    let Ok(mut inner) = engine.inner.lock() else {
        return;
    };

    inner.state = if running {
        OscStreamState::Running
    } else {
        OscStreamState::Stopped
    };
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn create_rejects_invalid_parameters() {
        assert!(osc_engine_create(0, 16, 48_000.0).is_null());
        assert!(osc_engine_create(2, 0, 48_000.0).is_null());
        assert!(osc_engine_create(2, 16, 0.0).is_null());
        assert!(osc_engine_create(2, 16, f64::NAN).is_null());
    }

    #[test]
    fn writes_reads_and_reports_status() {
        let engine = osc_engine_create(2, 4, 48_000.0);
        assert!(!engine.is_null());

        unsafe {
            osc_engine_set_running(engine, true);
        }

        let input = [0.1, 0.2, 1.1, 1.2, 2.1, 2.2];
        unsafe {
            osc_engine_write_interleaved(engine, input.as_ptr(), 3);
        }

        let mut output = [0.0; 6];
        assert_eq!(
            unsafe { osc_engine_read_interleaved(engine, output.as_mut_ptr(), 3) },
            3
        );
        assert_eq!(output, input);

        let mut status = OscStatusSnapshot::default();
        unsafe {
            osc_engine_get_status(engine, &mut status);
        }

        assert_eq!(status.state, OscStreamState::Running);
        assert_eq!(status.sample_rate, 48_000.0);
        assert_eq!(status.channel_count, 2);
        assert_eq!(status.capacity_frames, 4);
        assert_eq!(status.read_index, 3);
        assert_eq!(status.write_index, 3);
        assert_eq!(status.packet_count, 1);
        assert_eq!(status.decoded_frame_count, 3);

        unsafe {
            osc_engine_destroy(engine);
        }
    }

    #[test]
    fn read_nulls_are_noops() {
        let engine = osc_engine_create(2, 4, 48_000.0);
        assert!(!engine.is_null());

        let mut status = OscStatusSnapshot {
            sample_rate: 1.0,
            ..OscStatusSnapshot::default()
        };

        assert_eq!(
            unsafe { osc_engine_read_interleaved(std::ptr::null_mut(), std::ptr::null_mut(), 1) },
            0
        );
        assert_eq!(
            unsafe { osc_engine_read_interleaved(engine, std::ptr::null_mut(), 1) },
            0
        );
        unsafe {
            osc_engine_write_interleaved(engine, std::ptr::null(), 1);
            osc_engine_get_status(std::ptr::null_mut(), &mut status);
        }
        assert_eq!(status, OscStatusSnapshot::default());

        unsafe {
            osc_engine_destroy(engine);
            osc_engine_destroy(std::ptr::null_mut());
        }
    }
}
