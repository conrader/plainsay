import Foundation

/// Strips control characters that a terminal or other focused app could
/// interpret specially, right before text is pasted or copied.
///
/// `normalizeTranscript` runs only on raw ASR output and only collapses
/// whitespace; it never sees Polishing's output, which comes back from a
/// remote LLM that is explicitly asked for paragraph breaks (real newlines)
/// and — being a remote text generator, not a fixed local transform — has no
/// guarantee of never emitting a bare ESC or another C0/C1 control byte. A
/// synthetic ⌘V carries whatever a string contains straight to whatever is
/// focused; into a terminal, a literal `\n` is an Enter keypress and an ESC
/// begins a control sequence the terminal itself will act on.
///
/// `\n` and `\t` survive — real, useful formatting Polishing is asked to
/// produce — everything else in the C0/C1 control ranges does not.
public func sanitizeForInsertion(_ text: String) -> String {
    String(
        String.UnicodeScalarView(
            text.unicodeScalars.filter { scalar in
                scalar == "\n" || scalar == "\t" || !CharacterSet.controlCharacters.contains(scalar)
            }
        )
    )
}
