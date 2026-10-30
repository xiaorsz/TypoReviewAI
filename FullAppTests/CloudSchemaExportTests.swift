import CoreData
import SwiftData
import XCTest
@testable import CoachLab

/// Offline schema evidence for deployment tooling. This never opens a persistent
/// store or a CKContainer, and never reads a family's learning data.
@MainActor final class CloudSchemaExportTests: XCTestCase {
    private let modelTypes: [any PersistentModel.Type] = [
        ReviewItem.self, ReviewRecord.self, SyncDeletion.self, ReviewDailyPlan.self,
        TaskItem.self, TaskCompletion.self, TaskSubitem.self, TaskExecutionRecord.self,
        TaskSubitemExecutionRecord.self, AppSettings.self, DictationSession.self,
        DictationEntry.self, ScheduleItem.self, MediaAsset.self, PointLedgerEntry.self,
        PointRewardState.self, CalculationRound.self
    ]

    func testExportExactManagedObjectModelWithoutOpeningAnyStore() throws {
        let model = try XCTUnwrap(NSManagedObjectModel.makeManagedObjectModel(for: modelTypes))
        let names = Set(model.entities.compactMap(\.name))
        XCTAssertEqual(names.count, 17)
        XCTAssertTrue(names.contains("ReviewDailyPlan"))
        XCTAssertTrue(names.contains("CalculationRound"))
        XCTAssertTrue(names.contains("SyncDeletion"))
        let daily = try XCTUnwrap(model.entitiesByName["ReviewDailyPlan"])
        for field in ["coachSubjectRawValue", "coachRationale", "startedAt"] {
            XCTAssertNotNil(daily.attributesByName[field], field)
        }

        let entities: [[String: Any]] = model.entities.sorted { ($0.name ?? "") < ($1.name ?? "") }.map { entity in
            let attributes: [[String: Any]] = entity.attributesByName.values.sorted { $0.name < $1.name }.map { attribute in
                [
                    "name": attribute.name,
                    "attributeType": attribute.attributeType.rawValue,
                    "attributeTypeName": typeName(attribute.attributeType),
                    "valueClassName": attribute.attributeValueClassName ?? "",
                    "optional": attribute.isOptional,
                    "transient": attribute.isTransient,
                    "allowsCloudEncryption": attribute.allowsCloudEncryption,
                    "allowsExternalBinaryDataStorage": attribute.allowsExternalBinaryDataStorage,
                    "valueTransformerName": attribute.valueTransformerName ?? ""
                ]
            }
            let relationships: [[String: Any]] = entity.relationshipsByName.values.sorted { $0.name < $1.name }.map { relationship in
                [
                    "name": relationship.name,
                    "destination": relationship.destinationEntity?.name ?? "",
                    "inverse": relationship.inverseRelationship?.name ?? "",
                    "toMany": relationship.isToMany,
                    "ordered": relationship.isOrdered,
                    "optional": relationship.isOptional
                ]
            }
            return ["name": entity.name ?? "", "attributes": attributes, "relationships": relationships]
        }
        let json = try JSONSerialization.data(withJSONObject: [
            "containerIdentifier": CloudStorageConfiguration.containerIdentifier,
            "source": "NSManagedObjectModel.makeManagedObjectModel(for:)",
            "entities": entities
        ], options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: json, uniformTypeIdentifier: "public.json")
        attachment.name = "coach-native-cloud-model.json"
        attachment.lifetime = .keepAlways
        add(attachment)

        // Developer-only evidence lives under the experiment's ignored artifacts,
        // rather than in the app sandbox or either app's database.
        let lab = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let destination = lab.appendingPathComponent("artifacts/cloud-schema", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try json.write(to: destination.appendingPathComponent("coach-native-cloud-model.json"), options: .atomic)
        let archive = try NSKeyedArchiver.archivedData(withRootObject: model, requiringSecureCoding: false)
        try archive.write(to: destination.appendingPathComponent("coach-native-cloud-model.mom"), options: .atomic)
    }

    private func typeName(_ type: NSAttributeType) -> String {
        switch type {
        case .integer16AttributeType: return "Int16"
        case .integer32AttributeType: return "Int32"
        case .integer64AttributeType: return "Int64"
        case .decimalAttributeType: return "Decimal"
        case .doubleAttributeType: return "Double"
        case .floatAttributeType: return "Float"
        case .stringAttributeType: return "String"
        case .booleanAttributeType: return "Bool"
        case .dateAttributeType: return "Date"
        case .binaryDataAttributeType: return "Data"
        case .UUIDAttributeType: return "UUID"
        case .URIAttributeType: return "URI"
        case .transformableAttributeType: return "Transformable"
        case .objectIDAttributeType: return "ObjectID"
        default: return "Unsupported:\(type.rawValue)"
        }
    }
}
