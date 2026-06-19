use crate::status::{OscStatusSnapshot, OscStreamState};

pub const OSC_CHANNEL_COUNT: usize = 64;

/// Interleaved float32 PCM ring buffer for the first 64-channel MVP.
#[derive(Clone, Debug)]
pub struct OscPcmRing {
    channel_count: usize,
    capacity_frames: usize,
    samples: Vec<f32>,
    read_index: u64,
    write_index: u64,
    underrun_count: u64,
    overrun_count: u64,
}

impl OscPcmRing {
    pub fn new(capacity_frames: usize) -> Self {
        Self::with_channel_count(OSC_CHANNEL_COUNT, capacity_frames)
    }

    pub fn with_channel_count(channel_count: usize, capacity_frames: usize) -> Self {
        assert!(channel_count > 0, "channel count must be greater than zero");
        assert!(capacity_frames > 0, "capacity must be greater than zero");

        Self {
            channel_count,
            capacity_frames,
            samples: vec![0.0; channel_count * capacity_frames],
            read_index: 0,
            write_index: 0,
            underrun_count: 0,
            overrun_count: 0,
        }
    }

    pub fn channel_count(&self) -> usize {
        self.channel_count
    }

    pub fn capacity_frames(&self) -> usize {
        self.capacity_frames
    }

    pub fn read_index(&self) -> u64 {
        self.read_index
    }

    pub fn write_index(&self) -> u64 {
        self.write_index
    }

    pub fn available_frames(&self) -> usize {
        (self.write_index - self.read_index) as usize
    }

    pub fn underrun_count(&self) -> u64 {
        self.underrun_count
    }

    pub fn overrun_count(&self) -> u64 {
        self.overrun_count
    }

    pub fn write_interleaved(&mut self, input: &[f32]) -> usize {
        assert_eq!(
            input.len() % self.channel_count,
            0,
            "input must contain whole interleaved frames"
        );

        let frame_count = input.len() / self.channel_count;
        if frame_count == 0 {
            return 0;
        }

        if self.available_frames() + frame_count > self.capacity_frames {
            self.overrun_count += 1;
        }

        let old_write_index = self.write_index;
        let first_retained_frame = frame_count.saturating_sub(self.capacity_frames);

        for frame_offset in first_retained_frame..frame_count {
            let source_start = frame_offset * self.channel_count;
            let source_end = source_start + self.channel_count;
            let frame_index = old_write_index + frame_offset as u64;
            let destination_start =
                (frame_index as usize % self.capacity_frames) * self.channel_count;
            let destination_end = destination_start + self.channel_count;

            self.samples[destination_start..destination_end]
                .copy_from_slice(&input[source_start..source_end]);
        }

        self.write_index += frame_count as u64;
        self.read_index = self
            .read_index
            .max(self.write_index.saturating_sub(self.capacity_frames as u64));

        frame_count
    }

    pub fn read_interleaved(&mut self, output: &mut [f32]) -> usize {
        assert_eq!(
            output.len() % self.channel_count,
            0,
            "output must contain whole interleaved frames"
        );

        let requested_frames = output.len() / self.channel_count;
        if requested_frames == 0 {
            return 0;
        }

        output.fill(0.0);

        let readable_frames = requested_frames.min(self.available_frames());
        for frame_offset in 0..readable_frames {
            let frame_index = self.read_index + frame_offset as u64;
            let source_start = (frame_index as usize % self.capacity_frames) * self.channel_count;
            let source_end = source_start + self.channel_count;
            let destination_start = frame_offset * self.channel_count;
            let destination_end = destination_start + self.channel_count;

            output[destination_start..destination_end]
                .copy_from_slice(&self.samples[source_start..source_end]);
        }

        self.read_index += readable_frames as u64;

        if readable_frames < requested_frames {
            self.underrun_count += 1;
        }

        readable_frames
    }

    pub fn status_snapshot(
        &self,
        state: OscStreamState,
        sample_rate: f64,
        packet_count: u64,
        decoded_frame_count: u64,
        last_error_code: i32,
    ) -> OscStatusSnapshot {
        OscStatusSnapshot {
            state,
            sample_rate,
            channel_count: self.channel_count as u32,
            capacity_frames: self.capacity_frames as u32,
            read_index: self.read_index,
            write_index: self.write_index,
            packet_count,
            decoded_frame_count,
            underrun_count: self.underrun_count,
            overrun_count: self.overrun_count,
            last_error_code,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ring_with_channels(channel_count: usize, capacity_frames: usize) -> OscPcmRing {
        OscPcmRing::with_channel_count(channel_count, capacity_frames)
    }

    #[test]
    fn reads_silence_before_first_write() {
        let mut ring = ring_with_channels(2, 4);
        let mut output = [1.0; 4];

        let frames_read = ring.read_interleaved(&mut output);

        assert_eq!(frames_read, 0);
        assert_eq!(output, [0.0; 4]);
        assert_eq!(ring.underrun_count(), 1);
    }

    #[test]
    fn writes_and_reads_interleaved_frames() {
        let mut ring = ring_with_channels(2, 4);
        let input = [0.1, 0.2, 1.1, 1.2, 2.1, 2.2];
        let mut output = [0.0; 6];

        assert_eq!(ring.write_interleaved(&input), 3);
        assert_eq!(ring.read_interleaved(&mut output), 3);

        assert_eq!(output, input);
        assert_eq!(ring.read_index(), 3);
        assert_eq!(ring.write_index(), 3);
    }

    #[test]
    fn handles_64_channel_frame_writes() {
        let mut ring = OscPcmRing::new(2);
        let input: Vec<f32> = (0..OSC_CHANNEL_COUNT * 2)
            .map(|sample| sample as f32)
            .collect();
        let mut output = vec![0.0; OSC_CHANNEL_COUNT * 2];

        assert_eq!(ring.channel_count(), OSC_CHANNEL_COUNT);
        assert_eq!(ring.write_interleaved(&input), 2);
        assert_eq!(ring.read_interleaved(&mut output), 2);

        assert_eq!(output, input);
    }

    #[test]
    fn overrun_replaces_oldest_audio() {
        let mut ring = ring_with_channels(2, 2);
        let input = [0.0, 0.1, 1.0, 1.1, 2.0, 2.1];
        let mut output = [0.0; 4];

        assert_eq!(ring.write_interleaved(&input), 3);
        assert_eq!(ring.overrun_count(), 1);
        assert_eq!(ring.read_index(), 1);
        assert_eq!(ring.write_index(), 3);

        assert_eq!(ring.read_interleaved(&mut output), 2);
        assert_eq!(output, [1.0, 1.1, 2.0, 2.1]);
    }

    #[test]
    fn underrun_increments_counter_and_returns_silence() {
        let mut ring = ring_with_channels(2, 4);
        let input = [0.3, 0.4, 1.3, 1.4];
        let mut output = [9.0; 6];

        ring.write_interleaved(&input);
        assert_eq!(ring.read_interleaved(&mut output), 2);

        assert_eq!(output, [0.3, 0.4, 1.3, 1.4, 0.0, 0.0]);
        assert_eq!(ring.underrun_count(), 1);
        assert_eq!(ring.read_index(), ring.write_index());
    }
}
