use std::{error::Error, fmt};

const BROADCAST_MAC: [u8; 6] = [0xff; 6];
const GX4816_MAC: [u8; 6] = [0x00, 0x04, 0xc4, 0x06, 0xcf, 0xe8];
const KNOWN_AVANTIS_MAC: [u8; 6] = [0x00, 0x04, 0xc4, 0x08, 0xc8, 0x54];
const GIGAACE_SLINK_ETHERTYPE: u16 = 0x04ee;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct StageboxIdentityVariant {
    pub id: u8,
    pub name: &'static str,
    pub note: &'static str,
    pub ethertype: u16,
    pub stream_type: u8,
    pub frame_len: usize,
    pub packet_rate: f64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ConsoleResponse {
    pub src_mac: [u8; 6],
    pub known_avantis_mac: bool,
    pub allen_heath_oui: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum StageboxIdentityError {
    UnknownVariant { variant_id: u8 },
}

impl fmt::Display for StageboxIdentityError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UnknownVariant { variant_id } => {
                write!(f, "unknown GigaACE stagebox identity variant {variant_id}")
            }
        }
    }
}

impl Error for StageboxIdentityError {}

pub fn identity_variants() -> &'static [StageboxIdentityVariant] {
    &IDENTITY_VARIANTS
}

pub fn build_identity_frame(variant_id: u8) -> Result<Vec<u8>, StageboxIdentityError> {
    let spec =
        variant_spec(variant_id).ok_or(StageboxIdentityError::UnknownVariant { variant_id })?;
    let variant = &IDENTITY_VARIANTS[spec.variant_index];
    let mut frame = vec![0; variant.frame_len];

    frame[..6].copy_from_slice(&BROADCAST_MAC);
    frame[6..12].copy_from_slice(&GX4816_MAC);
    frame[12..14].copy_from_slice(&variant.ethertype.to_be_bytes());
    frame[14..19].copy_from_slice(&spec.header);
    frame[19] = 0;
    frame[20] = variant.stream_type;

    if spec.short_identity && frame.len() >= 52 {
        frame[24..28].copy_from_slice(b"GACE");
        frame[28] = 0x01;
        frame[29] = 0x48;
        frame[30] = 0x00;
        frame[31] = 0x40;
        frame[32] = 0x00;
        frame[33] = 0x01;
        frame[34] = 0x77;
        frame[35] = 0x00;
        frame[36..42].copy_from_slice(b"GX4816");
    }

    Ok(frame)
}

pub fn is_console_response(frame: &[u8]) -> Option<ConsoleResponse> {
    if frame.len() < 24 {
        return None;
    }

    let ethertype = u16::from_be_bytes([frame[12], frame[13]]);
    if ethertype != GIGAACE_SLINK_ETHERTYPE {
        return None;
    }

    let src_mac = read_mac(&frame[6..12]);
    if src_mac == GX4816_MAC {
        return None;
    }

    let known_avantis_mac = src_mac == KNOWN_AVANTIS_MAC;
    let allen_heath_oui = is_allen_heath_oui(&src_mac);
    let console_header = frame[14..19] == [0x00, 0x00, 0x04, 0xea, 0x00];

    if known_avantis_mac || (allen_heath_oui && console_header) {
        Some(ConsoleResponse {
            src_mac,
            known_avantis_mac,
            allen_heath_oui,
        })
    } else {
        None
    }
}

#[derive(Clone, Copy)]
struct IdentityVariantFrameSpec {
    variant_index: usize,
    header: [u8; 5],
    short_identity: bool,
}

const IDENTITY_VARIANTS: [StageboxIdentityVariant; 6] = [
    StageboxIdentityVariant {
        id: 0,
        name: "gx4816-slink-48k",
        note: "Reference GX4816/SLink shape from captures: 0x04EE, 00 0A 04 EA 00, stream 0x02, 48k packets/s.",
        ethertype: GIGAACE_SLINK_ETHERTYPE,
        stream_type: 0x02,
        frame_len: 1276,
        packet_rate: 48_000.0,
    },
    StageboxIdentityVariant {
        id: 1,
        name: "gx4816-slink-96k",
        note: "Reference GX4816 header, but free-running at 96k packets/s.",
        ethertype: GIGAACE_SLINK_ETHERTYPE,
        stream_type: 0x02,
        frame_len: 1276,
        packet_rate: 96_000.0,
    },
    StageboxIdentityVariant {
        id: 2,
        name: "avantis-header-gx-mac",
        note: "Console-style 00 00 04 EA 00 header, but with GX4816 source MAC.",
        ethertype: GIGAACE_SLINK_ETHERTYPE,
        stream_type: 0x02,
        frame_len: 1276,
        packet_rate: 48_000.0,
    },
    StageboxIdentityVariant {
        id: 3,
        name: "gx4816-stream01",
        note: "GX4816 header with stream type 0x01 instead of 0x02.",
        ethertype: GIGAACE_SLINK_ETHERTYPE,
        stream_type: 0x01,
        frame_len: 1276,
        packet_rate: 48_000.0,
    },
    StageboxIdentityVariant {
        id: 4,
        name: "gx4816-zero-prefix",
        note: "GX4816 MAC and stream 0x02, but bytes 14-18 zeroed.",
        ethertype: GIGAACE_SLINK_ETHERTYPE,
        stream_type: 0x02,
        frame_len: 1276,
        packet_rate: 48_000.0,
    },
    StageboxIdentityVariant {
        id: 5,
        name: "short-gace-identity",
        note: "Short experimental identity frame with ASCII GACE/GX4816 payload.",
        ethertype: GIGAACE_SLINK_ETHERTYPE,
        stream_type: 0xf0,
        frame_len: 64,
        packet_rate: 1_000.0,
    },
];

const FRAME_SPECS: [IdentityVariantFrameSpec; 6] = [
    IdentityVariantFrameSpec {
        variant_index: 0,
        header: [0x00, 0x0a, 0x04, 0xea, 0x00],
        short_identity: false,
    },
    IdentityVariantFrameSpec {
        variant_index: 1,
        header: [0x00, 0x0a, 0x04, 0xea, 0x00],
        short_identity: false,
    },
    IdentityVariantFrameSpec {
        variant_index: 2,
        header: [0x00, 0x00, 0x04, 0xea, 0x00],
        short_identity: false,
    },
    IdentityVariantFrameSpec {
        variant_index: 3,
        header: [0x00, 0x0a, 0x04, 0xea, 0x00],
        short_identity: false,
    },
    IdentityVariantFrameSpec {
        variant_index: 4,
        header: [0x00, 0x00, 0x00, 0x00, 0x00],
        short_identity: false,
    },
    IdentityVariantFrameSpec {
        variant_index: 5,
        header: [0x00, 0x00, 0x00, 0x00, 0x00],
        short_identity: true,
    },
];

fn variant_spec(variant_id: u8) -> Option<&'static IdentityVariantFrameSpec> {
    FRAME_SPECS
        .iter()
        .find(|spec| IDENTITY_VARIANTS[spec.variant_index].id == variant_id)
}

fn read_mac(bytes: &[u8]) -> [u8; 6] {
    let mut mac = [0; 6];
    mac.copy_from_slice(bytes);
    mac
}

fn is_allen_heath_oui(mac: &[u8; 6]) -> bool {
    mac[..3] == [0x00, 0x04, 0xc4]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stagebox_identity_models_all_six_variants() {
        let variants = identity_variants();

        assert_eq!(variants.len(), 6);
        assert_eq!(
            variants
                .iter()
                .map(|variant| variant.id)
                .collect::<Vec<_>>(),
            vec![0, 1, 2, 3, 4, 5]
        );
        assert_eq!(variants[0].name, "gx4816-slink-48k");
        assert_eq!(variants[1].packet_rate, 96_000.0);
        assert_eq!(variants[3].stream_type, 0x01);
        assert_eq!(variants[5].frame_len, 64);
        assert_eq!(variants[5].stream_type, 0xf0);
    }

    #[test]
    fn build_identity_frame_matches_variant_headers() {
        let expected_headers = [
            [0x00, 0x0a, 0x04, 0xea, 0x00],
            [0x00, 0x0a, 0x04, 0xea, 0x00],
            [0x00, 0x00, 0x04, 0xea, 0x00],
            [0x00, 0x0a, 0x04, 0xea, 0x00],
            [0x00, 0x00, 0x00, 0x00, 0x00],
            [0x00, 0x00, 0x00, 0x00, 0x00],
        ];

        for (variant, expected_header) in identity_variants().iter().zip(expected_headers) {
            let frame = build_identity_frame(variant.id).expect("known variant should build");

            assert_eq!(frame.len(), variant.frame_len);
            assert_eq!(frame[..6], BROADCAST_MAC);
            assert_eq!(frame[6..12], GX4816_MAC);
            assert_eq!(
                u16::from_be_bytes([frame[12], frame[13]]),
                variant.ethertype
            );
            assert_eq!(frame[14..19], expected_header);
            assert_eq!(frame[19], 0);
            assert_eq!(frame[20], variant.stream_type);
        }
    }

    #[test]
    fn build_identity_frame_includes_short_ascii_identity_payload() {
        let frame = build_identity_frame(5).expect("short variant should build");

        assert_eq!(&frame[24..28], b"GACE");
        assert_eq!(
            frame[28..36],
            [0x01, 0x48, 0x00, 0x40, 0x00, 0x01, 0x77, 0x00]
        );
        assert_eq!(&frame[36..42], b"GX4816");
    }

    #[test]
    fn build_identity_frame_rejects_unknown_variant() {
        let error = build_identity_frame(6).unwrap_err();

        assert_eq!(
            error,
            StageboxIdentityError::UnknownVariant { variant_id: 6 }
        );
    }

    #[test]
    fn console_response_detects_known_avantis_mac_without_header_match() {
        let mut frame = synthetic_response(KNOWN_AVANTIS_MAC, [0, 0, 0, 0, 0]);

        let response = is_console_response(&frame).expect("known Avantis MAC should match");

        assert_eq!(response.src_mac, KNOWN_AVANTIS_MAC);
        assert!(response.known_avantis_mac);
        assert!(response.allen_heath_oui);

        frame[12..14].copy_from_slice(&0x00e1_u16.to_be_bytes());
        assert_eq!(is_console_response(&frame), None);
    }

    #[test]
    fn console_response_detects_allen_heath_oui_with_console_header() {
        let src_mac = [0x00, 0x04, 0xc4, 0x12, 0x34, 0x56];
        let frame = synthetic_response(src_mac, [0x00, 0x00, 0x04, 0xea, 0x00]);

        let response =
            is_console_response(&frame).expect("Allen & Heath console header should match");

        assert_eq!(response.src_mac, src_mac);
        assert!(!response.known_avantis_mac);
        assert!(response.allen_heath_oui);
    }

    #[test]
    fn console_response_rejects_gx_mac_and_non_matching_sources() {
        let console_header = [0x00, 0x00, 0x04, 0xea, 0x00];

        assert_eq!(
            is_console_response(&synthetic_response(GX4816_MAC, console_header)),
            None
        );
        assert_eq!(
            is_console_response(&synthetic_response(
                [0x00, 0x04, 0xc4, 0xaa, 0xbb, 0xcc],
                [0, 0, 0, 0, 0],
            )),
            None
        );
        assert_eq!(
            is_console_response(&synthetic_response(
                [0x02, 0x00, 0x00, 0xaa, 0xbb, 0xcc],
                console_header,
            )),
            None
        );
        assert_eq!(is_console_response(&[0; 23]), None);
    }

    fn synthetic_response(src_mac: [u8; 6], header: [u8; 5]) -> Vec<u8> {
        let mut frame = vec![0; 24];
        frame[..6].copy_from_slice(&GX4816_MAC);
        frame[6..12].copy_from_slice(&src_mac);
        frame[12..14].copy_from_slice(&GIGAACE_SLINK_ETHERTYPE.to_be_bytes());
        frame[14..19].copy_from_slice(&header);
        frame
    }
}
