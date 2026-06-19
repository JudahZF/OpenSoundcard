use std::{error::Error, fmt};

const BROADCAST_MAC: [u8; 6] = [0xff; 6];
const COUNTER_OFFSET: usize = 19;
const STREAM_TYPE_OFFSET: usize = 20;
const AUDIO_BASE_OFFSET: usize = 24;
const BYTES_PER_SAMPLE: usize = 3;
const MIN_FRAME_SIZE: usize = AUDIO_BASE_OFFSET + BYTES_PER_SAMPLE;
const PCM24_SCALE: f32 = 8_388_608.0;

#[derive(Clone, Debug, PartialEq)]
pub struct DecodedGigaAceFrame {
    pub dst_mac: [u8; 6],
    pub src_mac: [u8; 6],
    pub ethertype: u16,
    pub counter: u8,
    pub stream_type: u8,
    pub channel_count: usize,
    pub pcm: Vec<f32>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum DecodeError {
    FrameTooShort { len: usize, min_len: usize },
    NonBroadcastDestination { dst_mac: [u8; 6] },
}

impl fmt::Display for DecodeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::FrameTooShort { len, min_len } => {
                write!(
                    f,
                    "GigaACE frame is {len} bytes, expected at least {min_len}"
                )
            }
            Self::NonBroadcastDestination { dst_mac } => {
                write!(
                    f,
                    "GigaACE frame destination is not broadcast: {dst_mac:02x?}"
                )
            }
        }
    }
}

impl Error for DecodeError {}

pub fn decode_frame(frame: &[u8], max_channels: usize) -> Result<DecodedGigaAceFrame, DecodeError> {
    if frame.len() < MIN_FRAME_SIZE {
        return Err(DecodeError::FrameTooShort {
            len: frame.len(),
            min_len: MIN_FRAME_SIZE,
        });
    }

    let dst_mac = read_mac(&frame[..6]);
    let src_mac = read_mac(&frame[6..12]);
    let ethertype = u16::from_be_bytes([frame[12], frame[13]]);
    let counter = frame[COUNTER_OFFSET] & 0x1f;
    let stream_type = frame[STREAM_TYPE_OFFSET];

    if dst_mac != BROADCAST_MAC {
        return Err(DecodeError::NonBroadcastDestination { dst_mac });
    }

    let available_audio = frame.len().saturating_sub(AUDIO_BASE_OFFSET);
    let channel_count = (available_audio / BYTES_PER_SAMPLE).min(max_channels);
    let mut pcm = Vec::with_capacity(channel_count);

    for channel in 0..channel_count {
        let offset = AUDIO_BASE_OFFSET + channel * BYTES_PER_SAMPLE;
        pcm.push(pcm24_to_float(decode_pcm24(
            &frame[offset..offset + BYTES_PER_SAMPLE],
        )));
    }

    Ok(DecodedGigaAceFrame {
        dst_mac,
        src_mac,
        ethertype,
        counter,
        stream_type,
        channel_count,
        pcm,
    })
}

fn read_mac(bytes: &[u8]) -> [u8; 6] {
    let mut mac = [0; 6];
    mac.copy_from_slice(bytes);
    mac
}

fn decode_pcm24(packed: &[u8]) -> i32 {
    let raw = ((packed[0] as u32) << 16) | ((packed[1] as u32) << 8) | packed[2] as u32;
    sign_extend24(raw)
}

fn sign_extend24(sample24: u32) -> i32 {
    let sample24 = sample24 & 0x00ff_ffff;
    if sample24 & 0x0080_0000 != 0 {
        (sample24 | 0xff00_0000) as i32
    } else {
        sample24 as i32
    }
}

fn pcm24_to_float(sample: i32) -> f32 {
    sample as f32 / PCM24_SCALE
}

#[cfg(test)]
mod tests {
    use super::*;

    const SRC_MAC: [u8; 6] = [0x00, 0x04, 0xc4, 0x0b, 0xa5, 0x28];

    #[test]
    fn decoder_parses_ethernet_and_gigaace_header_from_synthetic_frame() {
        let frame = synthetic_frame(0x04ee, 0x3f, 0x02, &[0]);

        let decoded = decode_frame(&frame, 64).expect("synthetic frame should decode");

        assert_eq!(decoded.dst_mac, BROADCAST_MAC);
        assert_eq!(decoded.src_mac, SRC_MAC);
        assert_eq!(decoded.ethertype, 0x04ee);
        assert_eq!(decoded.counter, 0x1f);
        assert_eq!(decoded.stream_type, 0x02);
        assert_eq!(decoded.channel_count, 1);
    }

    #[test]
    fn decoder_sign_extends_pcm24_and_converts_to_float() {
        let frame = synthetic_frame(
            0x04ee,
            0,
            0x02,
            &[0x000000, 0x000001, 0x7fffff, -0x800000, -1],
        );

        let decoded = decode_frame(&frame, 64).expect("synthetic frame should decode");

        assert_eq!(decoded.channel_count, 5);
        assert_eq!(decoded.pcm[0], 0.0);
        assert_eq!(decoded.pcm[1], 1.0 / PCM24_SCALE);
        assert_eq!(decoded.pcm[2], 8_388_607.0 / PCM24_SCALE);
        assert_eq!(decoded.pcm[3], -1.0);
        assert_eq!(decoded.pcm[4], -1.0 / PCM24_SCALE);
    }

    #[test]
    fn decoder_extracts_at_most_requested_channels() {
        let frame = synthetic_frame(0x04ee, 0, 0x02, &[1, 2, 3, 4]);

        let decoded = decode_frame(&frame, 2).expect("synthetic frame should decode");

        assert_eq!(decoded.channel_count, 2);
        assert_eq!(decoded.pcm, vec![1.0 / PCM24_SCALE, 2.0 / PCM24_SCALE]);
    }

    #[test]
    fn decoder_accepts_synthetic_sixty_four_channel_shape() {
        let samples: Vec<i32> = (0..64).map(|channel| channel * 257 - 8192).collect();
        let frame = synthetic_frame(0x04ee, 7, 0x02, &samples);

        let decoded = decode_frame(&frame, 128).expect("synthetic frame should decode");

        assert_eq!(frame.len(), AUDIO_BASE_OFFSET + 64 * BYTES_PER_SAMPLE);
        assert_eq!(decoded.channel_count, 64);
        assert_eq!(decoded.pcm.len(), 64);
        assert_eq!(decoded.pcm[0], -8192.0 / PCM24_SCALE);
        assert_eq!(decoded.pcm[63], (63 * 257 - 8192) as f32 / PCM24_SCALE);
    }

    #[test]
    fn decoder_rejects_too_short_frames() {
        let error = decode_frame(&[0; MIN_FRAME_SIZE - 1], 64).unwrap_err();

        assert_eq!(
            error,
            DecodeError::FrameTooShort {
                len: MIN_FRAME_SIZE - 1,
                min_len: MIN_FRAME_SIZE,
            }
        );
    }

    #[test]
    fn decoder_rejects_non_broadcast_destination() {
        let mut frame = synthetic_frame(0x04ee, 0, 0x02, &[0]);
        frame[0] = 0;

        let error = decode_frame(&frame, 64).unwrap_err();

        assert_eq!(
            error,
            DecodeError::NonBroadcastDestination {
                dst_mac: [0x00, 0xff, 0xff, 0xff, 0xff, 0xff],
            }
        );
    }

    fn synthetic_frame(ethertype: u16, counter: u8, stream_type: u8, samples: &[i32]) -> Vec<u8> {
        let mut frame = vec![0; AUDIO_BASE_OFFSET + samples.len() * BYTES_PER_SAMPLE];
        frame[..6].copy_from_slice(&BROADCAST_MAC);
        frame[6..12].copy_from_slice(&SRC_MAC);
        frame[12..14].copy_from_slice(&ethertype.to_be_bytes());
        frame[COUNTER_OFFSET] = counter;
        frame[STREAM_TYPE_OFFSET] = stream_type;

        for (channel, sample) in samples.iter().enumerate() {
            let offset = AUDIO_BASE_OFFSET + channel * BYTES_PER_SAMPLE;
            frame[offset..offset + BYTES_PER_SAMPLE].copy_from_slice(&encode_pcm24(*sample));
        }

        frame
    }

    fn encode_pcm24(sample: i32) -> [u8; 3] {
        let raw = sample as u32 & 0x00ff_ffff;
        [(raw >> 16) as u8, (raw >> 8) as u8, raw as u8]
    }
}
