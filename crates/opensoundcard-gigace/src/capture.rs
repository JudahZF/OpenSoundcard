use std::{error::Error, fmt, time::Instant};

use crate::decoder::{decode_frame, DecodeError, DecodedGigaAceFrame};
use crate::stagebox_identity::{is_console_response, ConsoleResponse};

const DEFAULT_MAX_CHANNELS: usize = 64;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct NetworkInterface {
    pub name: String,
    pub description: Option<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct CapturedGigaAceFrame {
    pub decoded: DecodedGigaAceFrame,
    pub console_response: Option<ConsoleResponse>,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct CaptureCounters {
    pub packet_count: u64,
    pub decoded_frame_count: u64,
    pub console_response_count: u64,
    pub last_console_response: Option<ConsoleResponse>,
}

#[derive(Clone, Debug, PartialEq)]
pub enum CapturedPacket {
    Decoded(CapturedGigaAceFrame),
    ConsoleResponse(ConsoleResponse),
    Ignored(DecodeError),
}

#[derive(Clone, Debug, PartialEq)]
pub struct CaptureSnapshot {
    pub counters: CaptureCounters,
    pub elapsed_seconds: f64,
    pub packets_per_second: f64,
    pub decoded_frames_per_second: f64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum CaptureError {
    UnsupportedPlatform,
    InterfaceListFailed(String),
    InterfaceOpenFailed { interface: String, error: String },
    PacketReadFailed(String),
    PacketInjectFailed(String),
    UnknownIdentityVariant(u8),
}

impl fmt::Display for CaptureError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UnsupportedPlatform => write!(f, "packet capture is only supported on macOS"),
            Self::InterfaceListFailed(error) => write!(f, "failed to list interfaces: {error}"),
            Self::InterfaceOpenFailed { interface, error } => {
                write!(f, "failed to open interface {interface}: {error}")
            }
            Self::PacketReadFailed(error) => write!(f, "failed to read packet: {error}"),
            Self::PacketInjectFailed(error) => write!(f, "failed to inject packet: {error}"),
            Self::UnknownIdentityVariant(variant_id) => {
                write!(f, "unknown stagebox identity variant {variant_id}")
            }
        }
    }
}

impl Error for CaptureError {}

#[derive(Debug)]
pub struct GigaAceCaptureAnalyzer {
    max_channels: usize,
    counters: CaptureCounters,
    started_at: Instant,
}

impl Default for GigaAceCaptureAnalyzer {
    fn default() -> Self {
        Self::new(DEFAULT_MAX_CHANNELS)
    }
}

impl GigaAceCaptureAnalyzer {
    pub fn new(max_channels: usize) -> Self {
        Self {
            max_channels,
            counters: CaptureCounters::default(),
            started_at: Instant::now(),
        }
    }

    pub fn observe_packet(&mut self, frame: &[u8]) -> CapturedPacket {
        self.counters.packet_count += 1;

        let console_response = is_console_response(frame);
        if let Some(response) = console_response {
            self.counters.console_response_count += 1;
            self.counters.last_console_response = Some(response);
        }

        match decode_frame(frame, self.max_channels) {
            Ok(decoded) => {
                self.counters.decoded_frame_count += 1;
                CapturedPacket::Decoded(CapturedGigaAceFrame {
                    decoded,
                    console_response,
                })
            }
            Err(error) => {
                if let Some(response) = console_response {
                    CapturedPacket::ConsoleResponse(response)
                } else {
                    CapturedPacket::Ignored(error)
                }
            }
        }
    }

    pub fn snapshot(&self) -> CaptureSnapshot {
        let elapsed_seconds = self.started_at.elapsed().as_secs_f64();
        let rate_window = elapsed_seconds.max(f64::EPSILON);
        CaptureSnapshot {
            counters: self.counters.clone(),
            elapsed_seconds,
            packets_per_second: self.counters.packet_count as f64 / rate_window,
            decoded_frames_per_second: self.counters.decoded_frame_count as f64 / rate_window,
        }
    }
}

#[cfg(all(target_os = "macos", not(test)))]
mod pcap_macos {
    use std::ffi::{CStr, CString};
    use std::os::raw::{c_char, c_int, c_uchar, c_void};
    use std::ptr;

    use crate::stagebox_identity::build_identity_frame;

    use super::{CaptureError, NetworkInterface};

    const PCAP_ERRBUF_SIZE: usize = 256;

    #[repr(C)]
    struct PcapInterface {
        next: *mut PcapInterface,
        name: *mut c_char,
        description: *mut c_char,
        addresses: *mut c_void,
        flags: u32,
    }

    #[repr(C)]
    struct Timeval {
        tv_sec: isize,
        tv_usec: isize,
    }

    #[repr(C)]
    struct PcapPacketHeader {
        ts: Timeval,
        caplen: u32,
        len: u32,
    }

    #[link(name = "pcap")]
    extern "C" {
        fn pcap_findalldevs(alldevs: *mut *mut PcapInterface, errbuf: *mut c_char) -> c_int;
        fn pcap_freealldevs(alldevs: *mut PcapInterface);
        fn pcap_open_live(
            device: *const c_char,
            snaplen: c_int,
            promisc: c_int,
            to_ms: c_int,
            errbuf: *mut c_char,
        ) -> *mut c_void;
        fn pcap_close(handle: *mut c_void);
        fn pcap_next_ex(
            handle: *mut c_void,
            header: *mut *const PcapPacketHeader,
            data: *mut *const c_uchar,
        ) -> c_int;
        fn pcap_inject(handle: *mut c_void, buf: *const c_void, size: usize) -> isize;
        fn pcap_geterr(handle: *mut c_void) -> *const c_char;
    }

    pub fn list_interfaces() -> Result<Vec<NetworkInterface>, CaptureError> {
        let mut errbuf = [0 as c_char; PCAP_ERRBUF_SIZE];
        let mut devices: *mut PcapInterface = ptr::null_mut();
        let result = unsafe { pcap_findalldevs(&mut devices, errbuf.as_mut_ptr()) };
        if result != 0 {
            return Err(CaptureError::InterfaceListFailed(errbuf_to_string(&errbuf)));
        }

        let mut interfaces = Vec::new();
        let mut cursor = devices;
        while !cursor.is_null() {
            let device = unsafe { &*cursor };
            if !device.name.is_null() {
                let name = unsafe { CStr::from_ptr(device.name) }
                    .to_string_lossy()
                    .into_owned();
                let description = if device.description.is_null() {
                    None
                } else {
                    Some(
                        unsafe { CStr::from_ptr(device.description) }
                            .to_string_lossy()
                            .into_owned(),
                    )
                };
                interfaces.push(NetworkInterface { name, description });
            }
            cursor = device.next;
        }

        if !devices.is_null() {
            unsafe {
                pcap_freealldevs(devices);
            }
        }

        Ok(interfaces)
    }

    pub struct PcapCapture {
        handle: *mut c_void,
        interface: String,
    }

    impl PcapCapture {
        pub fn open(interface: &str) -> Result<Self, CaptureError> {
            let c_interface =
                CString::new(interface).map_err(|_| CaptureError::InterfaceOpenFailed {
                    interface: interface.to_string(),
                    error: "interface name contains an embedded NUL".to_string(),
                })?;
            let mut errbuf = [0 as c_char; PCAP_ERRBUF_SIZE];
            let handle = unsafe {
                pcap_open_live(c_interface.as_ptr(), 65_535, 1, 250, errbuf.as_mut_ptr())
            };

            if handle.is_null() {
                return Err(CaptureError::InterfaceOpenFailed {
                    interface: interface.to_string(),
                    error: errbuf_to_string(&errbuf),
                });
            }

            Ok(Self {
                handle,
                interface: interface.to_string(),
            })
        }

        pub fn next_packet(&mut self) -> Result<Option<Vec<u8>>, CaptureError> {
            let mut header: *const PcapPacketHeader = ptr::null();
            let mut data: *const c_uchar = ptr::null();
            match unsafe { pcap_next_ex(self.handle, &mut header, &mut data) } {
                1 if !header.is_null() && !data.is_null() => {
                    let caplen = unsafe { (*header).caplen as usize };
                    let packet = unsafe { std::slice::from_raw_parts(data, caplen) }.to_vec();
                    Ok(Some(packet))
                }
                0 => Ok(None),
                -2 => Ok(None),
                _ => Err(CaptureError::PacketReadFailed(self.last_error())),
            }
        }

        pub fn inject(&mut self, frame: &[u8]) -> Result<(), CaptureError> {
            let sent =
                unsafe { pcap_inject(self.handle, frame.as_ptr().cast::<c_void>(), frame.len()) };
            if sent < 0 || sent as usize != frame.len() {
                return Err(CaptureError::PacketInjectFailed(self.last_error()));
            }

            Ok(())
        }

        pub fn inject_identity_frame(&mut self, variant_id: u8) -> Result<(), CaptureError> {
            let frame = build_identity_frame(variant_id)
                .map_err(|_| CaptureError::UnknownIdentityVariant(variant_id))?;
            self.inject(&frame)
        }

        pub fn interface(&self) -> &str {
            &self.interface
        }

        fn last_error(&self) -> String {
            let error = unsafe { pcap_geterr(self.handle) };
            if error.is_null() {
                return "unknown pcap error".to_string();
            }

            unsafe { CStr::from_ptr(error) }
                .to_string_lossy()
                .into_owned()
        }
    }

    impl Drop for PcapCapture {
        fn drop(&mut self) {
            if !self.handle.is_null() {
                unsafe {
                    pcap_close(self.handle);
                }
            }
        }
    }

    fn errbuf_to_string(errbuf: &[c_char; PCAP_ERRBUF_SIZE]) -> String {
        unsafe { CStr::from_ptr(errbuf.as_ptr()) }
            .to_string_lossy()
            .trim()
            .to_string()
    }
}

#[cfg(all(target_os = "macos", not(test)))]
pub use pcap_macos::{list_interfaces, PcapCapture};

#[cfg(any(not(target_os = "macos"), test))]
pub fn list_interfaces() -> Result<Vec<NetworkInterface>, CaptureError> {
    Err(CaptureError::UnsupportedPlatform)
}

#[cfg(test)]
mod tests {
    use super::*;

    const BROADCAST_MAC: [u8; 6] = [0xff; 6];
    const SRC_MAC: [u8; 6] = [0x00, 0x04, 0xc4, 0x0b, 0xa5, 0x28];

    #[test]
    fn analyzer_counts_packets_and_decoded_frames() {
        let mut analyzer = GigaAceCaptureAnalyzer::default();

        let packet = analyzer.observe_packet(&synthetic_audio_frame());

        assert!(matches!(packet, CapturedPacket::Decoded(_)));
        let snapshot = analyzer.snapshot();
        assert_eq!(snapshot.counters.packet_count, 1);
        assert_eq!(snapshot.counters.decoded_frame_count, 1);
        assert_eq!(snapshot.counters.console_response_count, 0);
        assert!(snapshot.packets_per_second.is_finite());
    }

    #[test]
    fn analyzer_tracks_console_responses_without_decoding_audio() {
        let mut analyzer = GigaAceCaptureAnalyzer::default();
        let src_mac = [0x00, 0x04, 0xc4, 0x12, 0x34, 0x56];

        let packet = analyzer.observe_packet(&synthetic_console_response(src_mac));

        assert!(matches!(packet, CapturedPacket::ConsoleResponse(_)));
        let snapshot = analyzer.snapshot();
        assert_eq!(snapshot.counters.packet_count, 1);
        assert_eq!(snapshot.counters.decoded_frame_count, 0);
        assert_eq!(snapshot.counters.console_response_count, 1);
        assert_eq!(
            snapshot
                .counters
                .last_console_response
                .map(|response| response.src_mac),
            Some(src_mac)
        );
    }

    fn synthetic_audio_frame() -> Vec<u8> {
        let mut frame = vec![0; 27];
        frame[..6].copy_from_slice(&BROADCAST_MAC);
        frame[6..12].copy_from_slice(&SRC_MAC);
        frame[12..14].copy_from_slice(&0x04ee_u16.to_be_bytes());
        frame[20] = 0x02;
        frame
    }

    fn synthetic_console_response(src_mac: [u8; 6]) -> Vec<u8> {
        let mut frame = vec![0; 24];
        frame[..6].copy_from_slice(&[0x00, 0x04, 0xc4, 0x06, 0xcf, 0xe8]);
        frame[6..12].copy_from_slice(&src_mac);
        frame[12..14].copy_from_slice(&0x04ee_u16.to_be_bytes());
        frame[14..19].copy_from_slice(&[0x00, 0x00, 0x04, 0xea, 0x00]);
        frame
    }
}
