module BatchStrings

using RustCall

# One call receives the text and a length-prefixed UTF-8 sequence of pairs.
# This is a textual framing protocol, not the in-memory layout of Rust Vec.
rust"""
fn field<'a>(rest: &mut &'a str) -> Result<&'a str, String> {
    let colon = rest.find(':').ok_or("missing field length")?;
    let digits = &rest[..colon];
    if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
        return Err("invalid field length".into());
    }
    let len: usize = digits.parse().map_err(|_| "field length overflow")?;
    let data = &rest[colon + 1..];
    let value = data.get(..len).ok_or("truncated field or invalid UTF-8 boundary")?;
    *rest = &data[len..];
    Ok(value)
}

#[julia]
pub fn batch_replace(text: String, encoded: String) -> Result<String, String> {
    let mut rest = encoded.as_str();
    let mut pairs = Vec::new();
    while !rest.is_empty() {
        let key = field(&mut rest)?;
        let value = field(&mut rest)?;
        if key.is_empty() { return Err("empty search string".into()); }
        pairs.push((key, value));
    }
    // Validate the entire input before performing any operation. In a facade
    // holding mutable state, compute a candidate here and commit only on Ok.
    let mut result = text;
    for (key, value) in pairs { result = result.replace(key, value); }
    Ok(result)
}
"""

"""Apply pairs in iteration order in one Rust call; reject an empty key."""
function replace_batch(text::AbstractString, pairs)
    text = String(text)
    isvalid(text) || throw(ArgumentError("text must be UTF-8"))
    io = IOBuffer()
    for (key, value) in pairs
        for item in (key, value)
            item isa AbstractString || throw(ArgumentError("pairs must contain strings"))
            s = String(item)
            isvalid(s) || throw(ArgumentError("pair strings must be UTF-8"))
            print(io, ncodeunits(s), ':', s)
        end
    end
    encoded = String(take!(io))
    result = batch_replace(text, encoded)
    return RustCall.is_ok(result) ? RustCall.unwrap(result) : throw(ArgumentError(result.value))
end

end # module
