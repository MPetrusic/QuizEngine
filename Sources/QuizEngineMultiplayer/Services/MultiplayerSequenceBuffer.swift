import Foundation

/// The bounded contiguous-sequence buffer that gives a hardened match one ordering policy.
///
/// A peer numbers every envelope it sends from zero without gaps, so the receiver can require
/// contiguity rather than reasoning about each payload's tolerance for reordering:
///
/// - a sequence below the next expected one has already been committed and is ignored;
/// - the next expected sequence is committed immediately, then any buffered successors drain in
///   order;
/// - a higher sequence is buffered until the gap closes;
/// - a gap wider than `maximumSequenceGap`, or more than `maximumBufferedMessages` waiting
///   envelopes, ends the match deterministically instead of guessing;
/// - the buffer is cleared at match teardown so a later match cannot inherit it.
///
/// Because every payload is delivered in send order, phase-sensitive effects such as pause and
/// resume, round transitions, and terminal processing need no per-payload ordering rules.
struct MultiplayerSequenceBuffer {
    /// How far ahead of the expected sequence a message may be before the gap is unrecoverable.
    static let maximumSequenceGap: UInt64 = 32
    /// How many out-of-order messages may wait for a gap to close.
    static let maximumBufferedMessages = 16

    enum Admission: Equatable {
        /// Already committed, or already waiting in the buffer.
        case duplicate
        /// This envelope is the next expected one.
        case ready
        /// Held until the missing sequences arrive.
        case buffered
        /// The gap is wider than the policy accepts.
        case gapTooLarge
        /// The buffer is full.
        case bufferOverflow
    }

    private(set) var expectedSequence: UInt64 = 0
    private var buffered: [UInt64: MultiplayerWireEnvelope] = [:]

    var bufferedCount: Int { buffered.count }
    var hasBufferedMessages: Bool { !buffered.isEmpty }

    /// Classifies `envelope` and buffers it when it is a future message the policy accepts.
    mutating func admit(_ envelope: MultiplayerWireEnvelope) -> Admission {
        if envelope.sequence < expectedSequence { return .duplicate }
        if envelope.sequence == expectedSequence { return .ready }
        if buffered[envelope.sequence] != nil { return .duplicate }
        guard envelope.sequence - expectedSequence <= Self.maximumSequenceGap else { return .gapTooLarge }
        guard buffered.count < Self.maximumBufferedMessages else { return .bufferOverflow }
        buffered[envelope.sequence] = envelope
        return .buffered
    }

    /// Records that the envelope at the expected sequence has been handled.
    mutating func commit(_ envelope: MultiplayerWireEnvelope) {
        expectedSequence = envelope.sequence &+ 1
    }

    /// Removes and returns the buffered envelope that is now contiguous, if any.
    mutating func takeNextContiguous() -> MultiplayerWireEnvelope? {
        buffered.removeValue(forKey: expectedSequence)
    }

    mutating func reset() {
        expectedSequence = 0
        buffered.removeAll()
    }
}
