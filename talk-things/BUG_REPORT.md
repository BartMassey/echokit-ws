# Bug Report: `src/audio.rs`

Review of the `unsafe` code and surrounding buffer logic in
`src/audio.rs`. One clear unsafe-buffer bug, one likely logic
bug behind "weird buffered audio," and one minor suspect.

## 1. Heap over-read in `AFE::fetch()` (lines 121-157)

`vad_cache_size` is used directly as the slice length, while
`data_size` is divided by 2:

```rust
let data_ = std::slice::from_raw_parts(
    result.vad_cache,
    result.vad_cache_size as usize,        // <-- should be / 2
);
...
let data_ = std::slice::from_raw_parts(result.data, data_size as usize / 2);  // correct
```

`vad_cache` is `*mut i16` (same type as `data`), and the
ESP-SR API reports both sizes in bytes. As written, the slice
covers `vad_cache_size` `i16` elements — twice as many bytes
as actually exist in the buffer. That is a heap over-read of
`vad_cache_size` bytes past the end of the cache.

The `Vec::with_capacity` on line 136 is also internally
inconsistent: `(data_size + vad_cache_size) / 2` mixes a
"divided" term with a "raw" term.

Currently `fetch` is `#[allow(dead_code)]` — only
`fetch_without_cache` is wired into `afe_worker` — so this is
not the *active* bug, but it will trigger UB the moment anyone
switches the worker over.

**Fix:** divide `vad_cache_size` by 2 in both the
`from_raw_parts` length and the `with_capacity` calculation.

## 2. AEC reference-buffer alignment in `audio_task_run` (lines 591-594)

```rust
for i in 0..total {
    samples_with_ref.push(read_buffer[i]);
    samples_with_ref.push(ring_cache_buffer.index_form_end(offset - i))
}
```

This is the most likely cause of weird buffered audio. Several
issues compound:

### 2a. `usize` underflow risk

`offset - i` is unsigned arithmetic. Today, with
`total == feed_chunksize == CHUNK_SIZE == 256` and
`AFE_AEC_OFFSET == 256` (cube/cube2/base) or `512`
(atom_box), it just barely does not underflow. But if anyone
ever switches to the commented-out `CHUNK_SIZE: usize = 512`
on line 477 without bumping every board's offset, `i > offset`
will silently wrap to a near-`usize::MAX` value.

`index_form_end` then does a second wrapping subtract, and the
final modular index lands on some arbitrary stale chunk in the
ring — exactly the sort of thing that produces unintelligible
or warbling echo-cancelled audio rather than a panic.

### 2b. Push-after-loop timing

`ring_cache_buffer.push(play_data.to_vec())` happens *after*
the loop (line 598). So the reference samples never come from
the chunk just queued for output — only from previously
played chunks. Whether that is correct depends on the I2S DMA
latency (`dma_buffer_count(2).frames_per_buffer(512)` adds
~64 ms on top of any acoustic delay), and `AFE_AEC_OFFSET`
has to be calibrated to match. Today the boards just hard-code
`256` or `512` with no comment explaining the derivation.

### 2c. Undocumented invariant

The pairing semantics — as `i` grows, `offset - i` shrinks,
so newer mic samples pair with newer reference samples — are
correct in direction, but they assume
`AFE_AEC_OFFSET >= feed_chunksize - 1`. That invariant is
undocumented and is not asserted anywhere.

**Fix candidates:**

- Replace `offset - i` with a checked / saturating subtract,
  or restructure as `offset + (total - 1 - i)` if the intent
  is "delay back from the most recent sample."
- Add a debug-assert linking `AFE_AEC_OFFSET` and
  `feed_chunksize`.
- Document how `AFE_AEC_OFFSET` is derived from DMA buffering
  + acoustic delay so future changes to `frames_per_buffer`
  / `dma_buffer_count` / `CHUNK_SIZE` stay consistent.

## 3. WAV header treated as PCM in the wake sound (line 521, 531)

```rust
let mut hello_wav = WAKE_WAV.to_vec();
...
AudioEvent::Hello(notify) => {
    send_buffer.clear();
    send_buffer.push_u8(&hello_wav);   // includes 44-byte WAV header
    send_buffer.push_back_end_speech(notify);
}
```

`WAKE_WAV` is `include_bytes!("../assets/hello_beep.wav")`,
which still has its RIFF/WAV header. `push_u8` interprets the
bytes as little-endian `i16` PCM, so the header bytes get
played as audio. If the symptom is a click or pop at the start
of the wake sound rather than residual echo, this is the
likely culprit.

**Fix:** strip the WAV header (skip past the `data` chunk
header) before pushing, or pre-process the asset at build
time.
