import XCTest
@testable import BoothStorage

/// Guest lead storage, and specifically the removal paths.
///
/// These exist because `leads.json` is the one file on a booth iPad holding
/// other people's personal data: names, emails and phone numbers collected
/// under a consent checkbox. Until recently the only way to remove any of it
/// was `deleteEvent`, which also destroys the photos, so in practice nobody
/// ever did and a device accumulated every guest from every event it had run.
///
/// The failure mode being defended against is silent: a deletion that
/// reports success while leaving the file behind looks identical to one that
/// worked, and nobody would notice until the data showed up somewhere it
/// should not have.
final class LeadStorageTests: XCTestCase {
    private let storage = EventStorage.shared
    private var eventIds: [String] = []

    /// Unique per test so cases cannot contaminate each other through the
    /// shared singleton's on-disk state.
    ///
    /// upsertEvent, not just an id: EventStorage writes into the event's
    /// folder and both appendLead and savePhoto fail if it does not exist
    /// yet. appendLead swallows that failure through `try?`, which is fine
    /// in the app (nothing reaches lead capture without an event) but means
    /// a test that skips this step silently stores nothing and then asserts
    /// against zero.
    private func makeEvent(_ label: String) throws -> String {
        let id = "test-\(label)-\(UUID().uuidString.prefix(8))"
        eventIds.append(id)
        try storage.upsertEvent(EventConfig.standardDefault(eventId: id))
        return id
    }

    private func lead(_ name: String) -> EventStorage.GuestLead {
        EventStorage.GuestLead(
            name: name,
            email: "\(name.lowercased())@example.test",
            phone: "0400000000",
            consented: true
        )
    }

    override func tearDown() {
        for id in eventIds { try? storage.deleteEvent(id) }
        eventIds = []
        super.tearDown()
    }

    func testDeleteLeadsRemovesContactsAndReportsHowMany() throws {
        let event = try makeEvent("delete")
        storage.appendLead(lead("Alex"), eventId: event)
        storage.appendLead(lead("Sam"), eventId: event)
        XCTAssertEqual(storage.leadCount(eventId: event), 2)

        let removed = storage.deleteLeads(eventId: event)

        XCTAssertEqual(removed, 2, "count is what the confirmation shows the attendant")
        XCTAssertEqual(storage.leadCount(eventId: event), 0)
        XCTAssertTrue(storage.loadLeads(eventId: event).isEmpty)
    }

    func testDeleteLeadsKeepsThePhotos() throws {
        // The entire reason this is separate from deleteEvent. If contacts
        // could only be removed by destroying the operator's work product,
        // they would never be removed at all, which is exactly what happened.
        let event = try makeEvent("keepphotos")
        storage.appendLead(lead("Alex"), eventId: event)
        _ = try storage.savePhoto(Data([0xFF, 0xD8, 0xFF]), eventId: event)
        XCTAssertEqual(storage.listPhotos(eventId: event).count, 1, "fixture must exist first")

        storage.deleteLeads(eventId: event)

        XCTAssertEqual(storage.leadCount(eventId: event), 0)
        XCTAssertEqual(storage.listPhotos(eventId: event).count, 1, "photos must survive")
    }

    func testDeleteLeadsOnAnEventWithNoneIsHarmless() throws {
        let event = try makeEvent("empty")

        XCTAssertEqual(storage.deleteLeads(eventId: event), 0)
        XCTAssertEqual(storage.leadCount(eventId: event), 0)
    }

    func testPurgeAllLeadsClearsEveryEventAndLeavesPhotos() throws {
        // The handover case: an iPad sold, returned to a rental pool, or
        // passed to another operator must not carry the previous one's
        // guest lists, but must not lose their photos either.
        let a = try makeEvent("purge-a")
        let b = try makeEvent("purge-b")
        storage.appendLead(lead("Alex"), eventId: a)
        storage.appendLead(lead("Sam"), eventId: b)
        storage.appendLead(lead("Jo"), eventId: b)
        _ = try storage.savePhoto(Data([0xFF, 0xD8, 0xFF]), eventId: b)

        let removed = storage.purgeAllLeads()

        XCTAssertEqual(removed, 3)
        XCTAssertEqual(storage.leadCount(eventId: a), 0)
        XCTAssertEqual(storage.leadCount(eventId: b), 0)
        XCTAssertEqual(storage.listPhotos(eventId: b).count, 1)
    }

    func testEventsHoldingLeadsExcludesEmptyOnes() throws {
        // Drives whether the device-wide purge button appears at all. If it
        // counted events with zero contacts, the button would offer to
        // delete nothing.
        let withLeads = try makeEvent("holding")
        let without = try makeEvent("notholding")
        storage.appendLead(lead("Alex"), eventId: withLeads)

        let holding = storage.eventsHoldingLeads()

        XCTAssertTrue(holding.contains { $0.eventId == withLeads && $0.count == 1 })
        XCTAssertFalse(holding.contains { $0.eventId == without })
    }

    func testOldestLeadDateIsTheEarliestNotTheLatest() throws {
        // Shown in Admin as "oldest contact on this event". Returning the
        // newest would make a device holding year-old contacts look fresh,
        // which is the opposite of the point.
        let event = try makeEvent("oldest")
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let recent = Date(timeIntervalSince1970: 1_800_000_000)
        storage.appendLead(EventStorage.GuestLead(name: "Recent", capturedAt: recent), eventId: event)
        storage.appendLead(EventStorage.GuestLead(name: "Old", capturedAt: old), eventId: event)

        XCTAssertEqual(storage.oldestLeadDate(eventId: event), old)
    }

    func testOldestLeadDateIsNilWithNoLeads() throws {
        XCTAssertNil(storage.oldestLeadDate(eventId: try makeEvent("nooldest")))
    }

    func testLeadsCSVEscapesAFormulaSoASpreadsheetCannotRunIt() throws {
        // Guest-typed text lands in the operator's spreadsheet. A value
        // starting with = + - @ is executed as a live formula by Excel and
        // Sheets, so an export is a CSV-injection surface.
        let event = try makeEvent("csv")
        storage.appendLead(
            EventStorage.GuestLead(name: "=1+1", email: "a@b.test", phone: "+61400", consented: true),
            eventId: event
        )

        let csv = storage.leadsCSV(eventId: event)

        XCTAssertTrue(csv.contains("\"'=1+1\""), "formula must be prefixed so it renders as text")
        XCTAssertFalse(csv.contains("\"=1+1\""))
    }

    func testLeadsCSVIsJustTheHeaderAfterDeletion() throws {
        // What an attendant gets if they export after clearing. It must be
        // an empty sheet, not stale rows read from a file that survived.
        let event = try makeEvent("csvafter")
        storage.appendLead(lead("Alex"), eventId: event)
        storage.deleteLeads(eventId: event)

        XCTAssertEqual(storage.leadsCSV(eventId: event), "Name,Email,Phone,Consented,CapturedAt")
    }
}
