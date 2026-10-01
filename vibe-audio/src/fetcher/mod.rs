//! Each struct here can be used to fetch the audio data from various sources.
//! Pick the one you need to fetch from.
mod dummy;
mod system_audio;

use cpal::SampleRate;
use std::sync::{Arc, Mutex};

pub use dummy::DummyFetcher;
pub use system_audio::{
    Descriptor as SystemAudioFetcherDescriptor, SystemAudio as SystemAudioFetcher, SystemAudioError,
};

/// Interface for all structs (fetchers) which are listed in the [fetcher module](crate::fetcher).
pub trait Fetcher {
    /// Returns the [SampleBuffer] (aka the input for the fft calculations).
    fn sample_buffer(&self) -> Arc<Mutex<SampleBuffer>>;

    /// Returns the amount of channels which are used from the fetcher.
    fn channels(&self) -> u16;
}

/// Holds the audio samples which gets filled by the fetcher
#[derive(Debug, Clone)]
pub struct SampleBuffer {
    buffer: Box<[f32]>,
    sample_rate: SampleRate,
}

impl SampleBuffer {
    /// Create a new instance for the given sample rate.
    pub fn new(sample_rate: SampleRate) -> Self {
        // props to cava for this heuristic.
        let factor = if sample_rate < 8_125 {
            1
        } else if sample_rate <= 16_250 {
            2
        } else if sample_rate <= 32_500 {
            4
        } else if sample_rate <= 75_000 {
            8
        } else if sample_rate <= 150_000 {
            16
        } else if sample_rate <= 300_000 {
            32
        } else {
            64
        };

        let buffer = vec![0f32; factor * 128].into_boxed_slice();

        Self {
            buffer,
            sample_rate,
        }
    }

    /// Pushes the given data to the front of `buffer` and moves the current data to the right.
    /// Basically a `VecDeque::push_before` just on a `Box<[f32]>`.
    pub fn push_before(&mut self, data: &[f32]) {
        let data_len = data.len();
        let buffer_len = self.buffer.len();

        // split point
        let split_point = buffer_len.min(data_len);

        // Keep the retained history directly after the new samples.
        self.buffer
            .copy_within(..buffer_len - split_point, split_point);

        // write the new data [at the beginning]/[on the left] of the buffer
        self.buffer[..split_point].copy_from_slice(&data[..split_point]);
    }

    pub fn sample_rate(&self) -> SampleRate {
        self.sample_rate
    }

    pub fn capacity(&self) -> usize {
        self.buffer.len()
    }

    pub fn buffer(&self) -> &[f32] {
        &self.buffer
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    mod sample_buffer {
        use super::*;

        #[test]
        fn push_more_than_capacity() {
            // buffer should have length of `1` * `128`
            let mut sample_buffer = SampleBuffer::new(1);
            sample_buffer.push_before(&[1f32; 129]);

            assert_eq!(sample_buffer.buffer.len(), 128);
            assert!(sample_buffer.buffer.iter().all(|&value| value == 1f32));
        }

        #[test]
        fn new_values_are_moved_to_the_beginning() {
            let mut sample_buffer = SampleBuffer::new(1);
            sample_buffer.push_before(&[69f32]);

            assert_eq!(sample_buffer.buffer.len(), 128);
            assert_eq!(sample_buffer.buffer[0], 69f32);
            assert!(sample_buffer.buffer[1..].iter().all(|&value| value == 0f32));
        }

        #[test]
        fn short_chunk_keeps_previous_samples_adjacent() {
            let mut sample_buffer = SampleBuffer::new(1);
            sample_buffer.push_before(&[1.0, 2.0, 3.0, 4.0]);
            sample_buffer.push_before(&[5.0, 6.0]);
            assert_eq!(
                &sample_buffer.buffer()[..6],
                &[5.0, 6.0, 1.0, 2.0, 3.0, 4.0]
            );
            assert!(sample_buffer.buffer()[6..]
                .iter()
                .all(|&value| value == 0.0));
        }

        #[test]
        fn varying_chunk_sizes_preserve_the_latest_window() {
            let mut sample_buffer = SampleBuffer::new(1);
            let capacity = sample_buffer.capacity();
            let mut expected = vec![0.0; capacity];
            let mut next_sample = 1;
            for chunk_len in [
                1,
                0,
                3,
                capacity / 2 - 1,
                capacity / 2,
                capacity / 2 + 1,
                capacity - 1,
                capacity,
                capacity + 1,
                2,
                0,
            ] {
                let chunk: Vec<f32> = (next_sample..next_sample + chunk_len)
                    .map(|sample| sample as f32)
                    .collect();
                next_sample += chunk_len;
                expected.splice(..0, chunk.iter().copied());
                expected.truncate(capacity);
                sample_buffer.push_before(&chunk);
                assert_eq!(sample_buffer.buffer(), expected, "chunk length {chunk_len}");
            }
        }

        #[test]
        fn no_values_pushed() {
            let mut sample_buffer = SampleBuffer::new(1);
            sample_buffer.push_before(&[]);

            assert_eq!(sample_buffer.buffer.len(), 128);
            assert!(sample_buffer.buffer.iter().all(|&value| value == 0f32));
        }
    }
}
