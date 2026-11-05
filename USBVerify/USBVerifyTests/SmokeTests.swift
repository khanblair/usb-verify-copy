import Testing

@testable import USBVerify

@Test
func formattingUsesHexOffsetsAndHumanBytes() {
    #expect(Formatting.hex(255) == "0xFF")
    #expect(Formatting.bytes(1_024).contains("KB"))
    #expect(Formatting.duration(65) == "1m 5s left")
}
