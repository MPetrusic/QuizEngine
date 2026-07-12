//
//  SeededRNG.swift
//  QuizEngineCore
//
//  Created by Milos Petrusic on 14.3.26..
//

import Foundation

public struct SeededRandomNumberGenerator: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64) {
        // Avoid zero state which would produce all zeros
        state = seed == 0 ? 1 : seed
    }

    public mutating func next() -> UInt64 {
        // xorshift64 — fast, deterministic, sufficient for answer shuffling
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
