import SlateKittyGraphics
import SlateTerminal
import Testing

@Test func kittyRepliesParseUnorderedKeysFullIDsAndOwnedMessages() throws {
  for body in ["Gi=4294967295,p=2;OK", "Gp=2,i=4294967295;OK", "Gp=2,e=T,C=1,i=4294967295;OK"] {
    let reply = try #require(KittyGraphicsReply(ApplicationCommand(body.utf8Span.span)))
    #expect(reply.imageID == .max && reply.placementID == 2)
    #expect(reply.isSuccess && !reply.messageTruncated)
    #expect(String(copying: reply.message) == "OK")
  }
  let reply = try #require(KittyGraphicsReply(ApplicationCommand("Gi=31;ENOENT:missing image".utf8Span.span)))
  #expect(reply.imageID == 31 && reply.placementID == nil && !reply.isSuccess)
  #expect(String(copying: reply.message) == "ENOENT:missing image")
  let detail = "Gi=31;EINVAL:" + String(repeating: "x", count: 256)
  let long = try #require(KittyGraphicsReply(ApplicationCommand(detail.utf8Span.span)))
  #expect(long.messageTruncated && !long.isSuccess)
  #expect(long.message.count == ApplicationCommand.maximumBytes - 6)
}

@Test func kittyReplyParserRejectsMalformedOrUnrelatedCommands() {
  for body in [
    "", "anything", "G", "Gi=1", "Gi=1;", "Gi=0;OK", "Gi=-1;OK", "Gi=4294967296;OK",
    "Gi=999999999999999999999;OK", "Gi=;OK", "Gi=a;OK", "Gp=1;OK", "Gi=1,p=0;OK",
    "Gi=1,i=2;OK", "Gi=1,p=2,p=3;OK", "Gi=1,;OK", "Gii=1;OK", "Gi=1;bad\nmessage",
    "Gi=1;é", "Gi=1,p=;OK", "Gi=1,p=2", "Gi=1,"
  ] {
    #expect(KittyGraphicsReply(ApplicationCommand(body.utf8Span.span)) == nil, "Accepted \(body)")
  }
  let truncatedHeader = "Gx=" + String(repeating: "1", count: 200) + ",i=1;OK"
  #expect(KittyGraphicsReply(ApplicationCommand(truncatedHeader.utf8Span.span)) == nil)
}
