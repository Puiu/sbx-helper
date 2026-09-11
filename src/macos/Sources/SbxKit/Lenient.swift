// Shared lenient-decoding primitives. A naive `Codable` conformance regresses
// on a hand-edited (or partially malformed) JSON payload: `decodeIfPresent`
// *throws* on a type mismatch rather than returning nil, so one wrong-typed
// field turns into a total decode failure — one bad preset loses every
// preset, one malformed sandbox loses the whole list. Used by SbxModels.swift
// and ConfigCodec.swift.

/// Decodes `T`, swallowing any failure — used as the element type of a
/// lenient array/map decode so one bad element doesn't fail the whole
/// container. Does NOT loop an UnkeyedDecodingContainer catching errors:
/// whether `currentIndex` advances past a throwing `decode` call is
/// unspecified, which risks spinning forever. Decoding element-by-element
/// through `Decodable` conformance sidesteps that entirely.
struct Failable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

extension KeyedDecodingContainer {
    /// Decodes a scalar field, falling back to `fallback` if the key is
    /// absent, its value is `null`, or its type doesn't match.
    func lenient<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }

    /// Decodes an array field, dropping any element that fails to decode
    /// rather than failing the whole array. Falls back to `fallback` if the
    /// key is absent, `null`, or not an array at all.
    func lenientArray<T: Decodable>(_ key: Key, _ fallback: [T]) -> [T] {
        guard let raw = try? decodeIfPresent([Failable<T>].self, forKey: key) else { return fallback }
        return raw.compactMap(\.value)
    }

    /// Decodes a `[String: T]` field, dropping any value that fails to
    /// decode. Falls back to `[:]` if the key is absent, `null`, or not an
    /// object.
    func lenientMap<T: Decodable>(_ key: Key) -> [String: T] {
        guard let raw = try? decodeIfPresent([String: Failable<T>].self, forKey: key) else { return [:] }
        return raw.compactMapValues(\.value)
    }
}
