import CoreData

final class PersistenceController {

    static let shared = PersistenceController()
    static let test = PersistenceController(inMemory: true)

    let container: NSPersistentContainer
    var ctx: NSManagedObjectContext { container.viewContext }

    private init(inMemory: Bool = false) {
        container = NSPersistentContainer(
            name: "TurtleSoup",
            managedObjectModel: Self.makeModel()
        )
        if inMemory {
            container.persistentStoreDescriptions.first!.url = URL(fileURLWithPath: "/dev/null")
        }
        container.loadPersistentStores { _, error in
            if let error { fatalError("CoreData load error: \(error)") }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    private static func makeModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()

        let puzzleE = entity("UserPuzzleEntity", attrs: [
            attr("id",         .UUIDAttributeType,      optional: false),
            attr("title",      .stringAttributeType,    optional: false),
            attr("difficulty", .stringAttributeType,    optional: false),
            attr("scenario",   .stringAttributeType,    optional: false),
            attr("answer",     .stringAttributeType,    optional: false),
            attr("hint",       .stringAttributeType,    optional: true),
            attr("author",     .stringAttributeType,    optional: false),
            attr("createdAt",  .dateAttributeType,      optional: false),
        ])

        let recordE = entity("GameRecordEntity", attrs: [
            attr("id",            .UUIDAttributeType,      optional: false),
            attr("puzzleID",      .UUIDAttributeType,      optional: false),
            attr("puzzleTitle",   .stringAttributeType,    optional: false),
            attr("startedAt",     .dateAttributeType,      optional: false),
            attr("endedAt",       .dateAttributeType,      optional: true),
            attr("isWon",         .booleanAttributeType,   optional: false),
            attr("questionCount", .integer32AttributeType, optional: false),
        ])

        let messageE = entity("GameMessageEntity", attrs: [
            attr("id",        .UUIDAttributeType,   optional: false),
            attr("role",      .stringAttributeType, optional: false),
            attr("text",      .stringAttributeType, optional: false),
            attr("verdict",   .stringAttributeType, optional: true),
            attr("timestamp", .dateAttributeType,   optional: false),
        ])

        let recToMsg = rel("messages", dest: messageE, toMany: true,  delete: .cascadeDeleteRule)
        let msgToRec = rel("record",   dest: recordE,  toMany: false, delete: .nullifyDeleteRule)
        recToMsg.inverseRelationship = msgToRec
        msgToRec.inverseRelationship = recToMsg
        recordE.properties  += [recToMsg]
        messageE.properties += [msgToRec]

        model.entities = [puzzleE, recordE, messageE]
        return model
    }

    private static func entity(_ name: String, attrs: [NSAttributeDescription]) -> NSEntityDescription {
        let e = NSEntityDescription()
        e.name = name
        e.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        e.properties = attrs
        return e
    }

    private static func attr(_ name: String, _ type: NSAttributeType, optional: Bool) -> NSAttributeDescription {
        let a = NSAttributeDescription()
        a.name = name
        a.attributeType = type
        a.isOptional = optional
        return a
    }

    private static func rel(_ name: String, dest: NSEntityDescription, toMany: Bool, delete: NSDeleteRule) -> NSRelationshipDescription {
        let r = NSRelationshipDescription()
        r.name = name
        r.destinationEntity = dest
        r.isOptional = true
        r.deleteRule = delete
        r.minCount = 0
        r.maxCount = toMany ? 0 : 1
        return r
    }

    func save() {
        guard ctx.hasChanges else { return }
        try? ctx.save()
    }
}
