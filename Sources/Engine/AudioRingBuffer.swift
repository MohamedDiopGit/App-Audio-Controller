//
//  AudioRingBuffer.swift
//  Engine
//
//  A lock-free, single-producer / single-consumer (SPSC) ring buffer of
//  INTERLEAVED Float32 frames in the tap's format.
//
//  ARCHITECTURAL ROLE (see BUILD SPEC):
//  ------------------------------------
//  The capture half and the playback half of this app are two *separate*
//  Core Audio clients running on two *independent device clocks*. They are
//  joined ONLY by this ring buffer:
//
//    PRODUCER  (sole writer):  ProcessTap's AudioDeviceIOBlock, invoked on the
//                              aggregate device's Core Audio REALTIME thread.
//                              It calls `write(_:frames:)` exactly once per IO
//                              cycle and nothing else.
//    CONSUMER  (sole reader):  TapProcessingEngine's AVAudioSourceNode render
//                              block, invoked on AVAudioEngine's REALTIME render
//                              thread. It calls `read(into:frames:)` exactly
//                              once per render cycle and nothing else.
//
//  Because exactly one realtime thread writes and exactly one realtime thread
//  reads, this is a strict SPSC structure. That lets us synchronise with just
//  two atomic indices (head/tail) using acquire/release ordering — no mutex,
//  no os_unfair_lock (which can priority-invert and is NOT safe to *spin* on a
//  realtime thread), no allocation, and no ARC traffic on the hot paths.
//
//  REALTIME SAFETY CONTRACT (load-bearing — every method below honours it):
//    * Backing storage is allocated EXACTLY ONCE, in `init`.
//    * `write` / `read` perform NO heap allocation, NO locking, NO ARC
//      retain/release, NO Foundation calls, NO logging, NO throwing.
//    * They touch only: the preallocated Float buffer, two atomic UInt indices,
//      and the caller-supplied AudioBufferList (whose memory the caller owns).
//
//  CLOCK DRIFT:
//  The producer (capture device clock) and consumer (output device clock) tick
//  at slightly different rates, so over time one will outpace the other. The
//  aggregate device's per-sub-tap drift compensation absorbs most of it; this
//  buffer's headroom (sized for >= ~0.5 s by AudioTapManager) absorbs the rest.
//  On overflow we drop the incoming block (write returns false); on underflow
//  we report empty (read returns false) and the consumer emits silence.
//

import AVFoundation
import CoreAudio
import Atomics   // swift-atomics (https://github.com/apple/swift-atomics)
                 // ASSUMPTION: this package is the spec's first-named option
                 // ("std atomics via Atomics package"). It provides
                 // ManagedAtomic<UInt> with explicit memory orderings and is
                 // the only realtime-safe, deployment-target-portable
                 // (macOS 14.4) way to get acquire/release atomics. The stdlib
                 // `Synchronization.Atomic` requires macOS 15+, which is above
                 // this app's 14.4 floor, so it is deliberately NOT used here.

/// Lock-free SPSC ring buffer of interleaved `Float32` frames matching the
/// tap's `AVAudioFormat`. One realtime writer, one realtime reader.
///
/// - Important: This type is `@unchecked Sendable` because its safety is
///   guaranteed by the SPSC discipline + atomic indices rather than by the
///   compiler. Callers MUST honour the single-producer / single-consumer
///   contract: at most one thread ever calls `write`, at most one (different)
///   thread ever calls `read`. Violating this voids the lock-freedom guarantee.
final class AudioRingBuffer: @unchecked Sendable {

    // MARK: - Stored layout (all fixed at init; never mutated on hot paths)

    /// The format the producer writes and the consumer reads. Must equal the
    /// tap-ASBD-derived `AVAudioFormat` so byte layout matches end to end.
    let format: AVAudioFormat

    /// Number of interleaved channels (e.g. 2 for the stereo-mixdown tap).
    /// Read from the format once; used to translate frames <-> Float samples.
    private let channelCount: Int

    /// Bytes per interleaved frame = channelCount * MemoryLayout<Float>.size.
    /// We deliberately recompute lengths in frames/samples rather than trusting
    /// `frames * bytesPerFrame` blindly — but we DO clamp against each
    /// AudioBuffer.mDataByteSize so we never read/write past a caller buffer.
    private let bytesPerFrame: Int

    /// Capacity expressed in FRAMES. We allocate one extra "slack" frame
    /// (capacityFrames + 1 frames of storage) so the classic head==tail test
    /// can distinguish "empty" from "full" without a separate count field —
    /// the canonical lock-free ring-buffer trick. `availableFramesToRead` and
    /// the fill/drain logic all operate modulo `slotCount`.
    private let capacityFrames: Int

    /// Total storage slots in frames = capacityFrames + 1 (the +1 slack frame).
    private let slotCount: Int

    /// Total Float samples in storage = slotCount * channelCount.
    private let sampleCapacity: Int

    /// The single, once-allocated interleaved Float32 backing store.
    /// Layout: [f0c0, f0c1, ..., f1c0, f1c1, ...]. Owned by us; freed in deinit.
    private let storage: UnsafeMutablePointer<Float>

    // MARK: - Atomic synchronisation state (the only cross-thread mutable state)

    /// Write index in FRAMES, monotonic modulo `slotCount`. Owned by the
    /// PRODUCER. The producer advances it with .release so that the Float
    /// samples it stored *happen-before* the consumer's .acquire load sees the
    /// new value (publishes the data). The consumer only ever LOADS it.
    private let writeIndex = ManagedAtomic<UInt>(0)

    /// Read index in FRAMES, monotonic modulo `slotCount`. Owned by the
    /// CONSUMER. The consumer advances it with .release so the producer's
    /// .acquire load observes that those slots are now free for reuse. The
    /// producer only ever LOADS it.
    private let readIndex = ManagedAtomic<UInt>(0)

    // MARK: - Init / deinit (the ONLY places allocation happens)

    /// - Parameters:
    ///   - format: The interleaved Float32 format (tap ASBD -> AVAudioFormat).
    ///   - capacityFrames: Usable capacity in frames. One extra slack frame is
    ///     allocated internally so full/empty are distinguishable.
    ///
    /// - Precondition: `format` must be Float32. Only its `channelCount` and
    ///   sample rate matter — the backing store is ALWAYS interleaved Float32
    ///   regardless of whether `format` itself is interleaved. The endpoints may
    ///   present either layout: `storeFromABL`/`loadIntoABL` interleave/de-
    ///   interleave per-AudioBuffer as needed (the tap is usually non-interleaved;
    ///   the consumer's AVAudioEngine standard format is non-interleaved too).
    init(format: AVAudioFormat, capacityFrames: Int) {
        precondition(capacityFrames > 0, "AudioRingBuffer capacity must be > 0")

        self.format = format
        // `channelCount` drives our frame<->sample math. Float32 is assumed
        // (the spec pins the whole chain to Float32); we read the channel count
        // from the format rather than the ASBD to stay in sync with the
        // AVAudioFormat the source node will use.
        let channels = Int(format.channelCount)
        precondition(channels > 0, "AudioRingBuffer requires >= 1 channel")
        self.channelCount = channels
        self.bytesPerFrame = channels * MemoryLayout<Float>.size

        self.capacityFrames = capacityFrames
        // +1 slack frame: enables the head==tail (empty) vs
        // head==tail-1 (full) discrimination used throughout.
        self.slotCount = capacityFrames + 1
        self.sampleCapacity = self.slotCount * channels

        // SINGLE allocation for the lifetime of the buffer. We zero-initialise
        // so an early underrun (consumer racing ahead before any write) reads
        // silence rather than garbage, even though read() also returns false in
        // that case. Allocation/zeroing happen here on a non-realtime thread.
        self.storage = UnsafeMutablePointer<Float>.allocate(capacity: self.sampleCapacity)
        self.storage.initialize(repeating: 0, count: self.sampleCapacity)
    }

    deinit {
        // Deinit runs on whichever thread releases the last reference — by
        // contract this is NOT a realtime thread (AudioTapManager tears the
        // engines down first, on the main actor, so no IOProc/render block can
        // still be touching `storage`). Safe to free here.
        storage.deinitialize(count: sampleCapacity)
        storage.deallocate()
    }

    // MARK: - Public query

    /// Number of frames currently available for the consumer to read.
    ///
    /// Realtime-safe. Computed from a snapshot of both atomic indices. May be a
    /// slight under-estimate if the producer writes concurrently (the producer
    /// can only ADD frames after this load), which is the safe direction for a
    /// consumer deciding how much it can drain.
    var availableFramesToRead: Int {
        // .acquire on the write index pairs with the producer's .release store
        // so that if we observe a given write position, we also observe all the
        // sample data written before it.
        let w = writeIndex.load(ordering: .acquiring)
        // .relaxed is fine for our own (consumer-side) read index here: only
        // the consumer mutates it, and we don't need ordering against our own
        // prior stores for a pure size query.
        let r = readIndex.load(ordering: .relaxed)
        return frameDistance(from: r, to: w)
    }

    /// Total usable capacity in frames (excludes the internal slack frame).
    /// Handy for callers sizing latency; not on any hot path.
    var capacityInFrames: Int { capacityFrames }

    // MARK: - Producer path (REALTIME — called from the capture IOProc only)

    /// Copy `frames` worth of interleaved Float32 audio out of `abl` into the
    /// ring buffer. Sole caller: the `AudioDeviceIOBlock` (`inInputData`).
    ///
    /// - Returns: `true` if the whole block fit and was written; `false` on
    ///   overflow (not enough free space) — in which case NOTHING is written and
    ///   the block is dropped. Dropping (rather than partial-writing) keeps the
    ///   interleaved stream frame-aligned and avoids tearing a frame.
    ///
    /// - Note: REALTIME-SAFE. No alloc, no lock, no ARC, no throwing.
    @discardableResult
    func write(_ abl: UnsafePointer<AudioBufferList>, frames: AVAudioFrameCount) -> Bool {
        let frameCount = Int(frames)
        if frameCount <= 0 { return true } // nothing to do; trivially "succeeded"

        // Snapshot indices. The producer OWNS writeIndex, so a .relaxed load of
        // our own value is correct (no other thread writes it). We need .acquire
        // on readIndex to observe the consumer's latest progress (released by
        // the consumer) so our free-space calc isn't stale in the unsafe
        // direction.
        let w = writeIndex.load(ordering: .relaxed)
        let r = readIndex.load(ordering: .acquiring)

        // Free space = capacityFrames - currentlyStored. (We can use at most
        // `capacityFrames`, never the slack frame, so full is detectable.)
        let used = frameDistance(from: r, to: w)
        let free = capacityFrames - used
        if frameCount > free {
            // OVERFLOW: consumer is behind / clocks drifted such that the
            // producer outran the buffer. Drop this block wholesale. The caller
            // (IOProc) ignores the Bool; the headroom + drift compensation are
            // expected to make this rare. We do NOT block or grow — both would
            // violate realtime safety.
            return false
        }

        // Copy from the AudioBufferList into `storage`, honouring each
        // AudioBuffer.mDataByteSize. The interleaved tap normally presents a
        // SINGLE buffer of `channelCount` interleaved channels; we still iterate
        // mNumberBuffers defensively. For interleaved data there is exactly one
        // buffer holding all channels, so we write it straight into the
        // interleaved store. (If the format were non-interleaved this single
        // flat-store layout would be wrong; the spec pins us to the interleaved
        // stereo-mixdown tap, so one interleaved buffer is the expected shape.)
        let startFrame = Int(w % UInt(slotCount))
        let didCopy = storeFromABL(abl,
                                   frameCount: frameCount,
                                   intoStorageStartingAtFrame: startFrame)
        if !didCopy {
            // Source provided fewer bytes than `frames` implies (mDataByteSize
            // too small). We refused to over-read, so we publish nothing.
            return false
        }

        // PUBLISH: advance writeIndex with .release. This release pairs with the
        // consumer's .acquire load of writeIndex, guaranteeing the sample
        // stores above are visible before the consumer can observe the new
        // position and read them.
        let newW = (w &+ UInt(frameCount)) % UInt(slotCount)
        writeIndex.store(newW, ordering: .releasing)
        return true
    }

    // MARK: - Consumer path (REALTIME — called from the source-node render block)

    /// Fill `abl` with up to `frames` interleaved Float32 frames drained from
    /// the ring buffer. Sole caller: the `AVAudioSourceNodeRenderBlock`
    /// (`outputData`).
    ///
    /// - Returns: `true` if `frames` frames were available and fully written
    ///   into `abl`; `false` on underrun (fewer than `frames` available). On
    ///   `false`, the render block should set `isSilence.pointee = true` and
    ///   return `noErr`. We intentionally do NOT do a partial read: AVAudio
    ///   render expects exactly `frameCount` frames, and emitting silence for a
    ///   whole cycle is cleaner than splicing a partial buffer with stale tail
    ///   samples (which would click).
    ///
    /// - Note: REALTIME-SAFE. No alloc, no lock, no ARC, no throwing.
    @discardableResult
    func read(into abl: UnsafeMutablePointer<AudioBufferList>, frames: AVAudioFrameCount) -> Bool {
        let frameCount = Int(frames)
        if frameCount <= 0 { return true }

        // Consumer OWNS readIndex (.relaxed load of our own value is correct).
        // .acquire on writeIndex to observe the producer's published samples.
        let r = readIndex.load(ordering: .relaxed)
        let w = writeIndex.load(ordering: .acquiring)

        let available = frameDistance(from: r, to: w)
        if frameCount > available {
            // UNDERRUN: producer is behind (e.g. tapautostart hasn't begun, or
            // clock drift left us empty). Report empty; caller emits silence.
            // We do NOT advance readIndex, so no data is consumed/lost.
            return false
        }

        let startFrame = Int(r % UInt(slotCount))
        let didCopy = loadIntoABL(abl,
                                  frameCount: frameCount,
                                  fromStorageStartingAtFrame: startFrame)
        if !didCopy {
            // Destination AudioBuffer too small to hold `frames` — refuse to
            // over-write the caller's memory and do not consume input.
            return false
        }

        // FREE: advance readIndex with .release so the producer's .acquire load
        // observes that these slots are now reusable (and so the samples it
        // later writes there aren't reordered before we finished reading them).
        let newR = (r &+ UInt(frameCount)) % UInt(slotCount)
        readIndex.store(newR, ordering: .releasing)
        return true
    }

    // MARK: - Index math

    /// Forward distance in frames from `r` to `w` modulo `slotCount`, i.e. the
    /// number of frames currently stored. Both indices are already kept in
    /// [0, slotCount); this handles the wrap where w < r.
    @inline(__always)
    private func frameDistance(from r: UInt, to w: UInt) -> Int {
        let slots = UInt(slotCount)
        // (w - r) mod slotCount, using wrapping subtraction to stay correct
        // even though both are bounded; the +slots/% keeps the result in range.
        let diff = (w &+ slots &- r) % slots
        return Int(diff)
    }

    // MARK: - Sample-movement helpers (interleaved + planar aware)
    //
    // The ring's backing store is ALWAYS interleaved Float32. The two endpoints,
    // however, may hand us either layout in their AudioBufferList:
    //
    //   * PRODUCER (the process tap): macOS process taps very frequently deliver
    //     Float32 as NON-INTERLEAVED — mChannelsPerFrame == N but the buffer list
    //     carries N separate single-channel AudioBuffers (mNumberBuffers == N,
    //     each mDataByteSize == frames * 4). Some taps deliver interleaved (a
    //     single buffer of N channels). `storeFromABL` handles BOTH and writes
    //     interleaved into `storage`.
    //   * CONSUMER (the AVAudioSourceNode): we build it with AVAudioEngine's
    //     STANDARD format, which is non-interleaved, so its render ABL carries N
    //     single-channel buffers. `loadIntoABL` de-interleaves `storage` into
    //     them. (It also supports a single interleaved consumer buffer.)
    //
    // Both helpers are realtime-safe: only pointer arithmetic and scalar/`memcpy`
    // moves over preallocated memory — no allocation, ARC, locks, or throwing.
    // We detect the layout purely from `mNumberBuffers` (1 == interleaved/mono,
    // == channelCount == planar) so neither endpoint has to agree out of band.

    /// Copy `frameCount` frames FROM an input AudioBufferList INTO the interleaved
    /// `storage`, starting at frame `startFrame` (wrapping at `slotCount`).
    /// Accepts interleaved (1 buffer) or planar (one buffer per channel) input.
    /// Returns false if any source buffer is missing or too small for `frameCount`.
    @inline(__always)
    private func storeFromABL(_ abl: UnsafePointer<AudioBufferList>,
                              frameCount: Int,
                              intoStorageStartingAtFrame startFrame: Int) -> Bool {
        // UnsafeMutableAudioBufferListPointer gives bounds-checked access to the
        // variable-length mBuffers flexible array member. We pass a mutable view
        // over the (logically const) input purely to read it; we never mutate it.
        let mutABL = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: abl)
        )
        let bufferCount = mutABL.count
        guard bufferCount > 0 else { return false }

        if bufferCount == 1 {
            // INTERLEAVED (or mono): one buffer holds all `channelCount` channels.
            guard let rawSrc = mutABL[0].mData else { return false }
            // Honour mDataByteSize: never over-read the IO buffer.
            if Int(mutABL[0].mDataByteSize) < frameCount * bytesPerFrame { return false }
            let src = rawSrc.assumingMemoryBound(to: Float.self)
            let totalSamples = frameCount * channelCount
            let startSample = startFrame * channelCount
            let samplesToEnd = sampleCapacity - startSample
            if totalSamples <= samplesToEnd {
                (storage + startSample).update(from: src, count: totalSamples)
            } else {
                let firstChunk = samplesToEnd
                (storage + startSample).update(from: src, count: firstChunk)
                storage.update(from: src + firstChunk, count: totalSamples - firstChunk)
            }
            return true
        }

        // PLANAR / NON-INTERLEAVED: one single-channel buffer per channel.
        let planes = min(bufferCount, channelCount)
        let bytesPerChannelFrame = MemoryLayout<Float>.size
        // Validate every plane up front so we never publish a partially-written frame.
        for ch in 0..<planes {
            guard mutABL[ch].mData != nil else { return false }
            if Int(mutABL[ch].mDataByteSize) < frameCount * bytesPerChannelFrame { return false }
        }
        // Interleave plane-by-plane into storage, walking the slot ring manually
        // (no modulo per sample — just a branch on the wrap point).
        for ch in 0..<planes {
            let src = mutABL[ch].mData!.assumingMemoryBound(to: Float.self)
            var slot = startFrame
            for f in 0..<frameCount {
                storage[slot * channelCount + ch] = src[f]
                slot += 1
                if slot == slotCount { slot = 0 }
            }
        }
        // Defensive: if the tap somehow gave fewer planes than channels, zero the
        // missing channels rather than leaking stale samples into them.
        if planes < channelCount {
            for ch in planes..<channelCount {
                var slot = startFrame
                for _ in 0..<frameCount {
                    storage[slot * channelCount + ch] = 0
                    slot += 1
                    if slot == slotCount { slot = 0 }
                }
            }
        }
        return true
    }

    /// Copy `frameCount` frames FROM the interleaved `storage` (starting at frame
    /// `startFrame`, wrapping) INTO an output AudioBufferList. Accepts a planar
    /// destination (one buffer per channel — the AVAudioEngine standard format) or
    /// a single interleaved destination buffer.
    /// Returns false if any destination buffer is missing or too small.
    @inline(__always)
    private func loadIntoABL(_ abl: UnsafeMutablePointer<AudioBufferList>,
                             frameCount: Int,
                             fromStorageStartingAtFrame startFrame: Int) -> Bool {
        let mutABL = UnsafeMutableAudioBufferListPointer(abl)
        let bufferCount = mutABL.count
        guard bufferCount > 0 else { return false }

        if bufferCount == 1 {
            // INTERLEAVED destination: one buffer for all channels.
            guard let rawDst = mutABL[0].mData else { return false }
            if Int(mutABL[0].mDataByteSize) < frameCount * bytesPerFrame { return false }
            let dst = rawDst.assumingMemoryBound(to: Float.self)
            let totalSamples = frameCount * channelCount
            let startSample = startFrame * channelCount
            let samplesToEnd = sampleCapacity - startSample
            if totalSamples <= samplesToEnd {
                dst.update(from: storage + startSample, count: totalSamples)
            } else {
                let firstChunk = samplesToEnd
                dst.update(from: storage + startSample, count: firstChunk)
                (dst + firstChunk).update(from: storage, count: totalSamples - firstChunk)
            }
            return true
        }

        // PLANAR destination: de-interleave storage into one buffer per channel.
        let planes = min(bufferCount, channelCount)
        let bytesPerChannelFrame = MemoryLayout<Float>.size
        for ch in 0..<planes {
            guard mutABL[ch].mData != nil else { return false }
            if Int(mutABL[ch].mDataByteSize) < frameCount * bytesPerChannelFrame { return false }
        }
        for ch in 0..<planes {
            let dst = mutABL[ch].mData!.assumingMemoryBound(to: Float.self)
            var slot = startFrame
            for f in 0..<frameCount {
                dst[f] = storage[slot * channelCount + ch]
                slot += 1
                if slot == slotCount { slot = 0 }
            }
        }
        return true
    }
}
