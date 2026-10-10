import Foundation

/// Common metadata promotion used by every authorization completion route.
/// Native admission still requires the exact enrolled self/root and role policy.
@discardableResult
func switchAuthorizationRecord(transaction: AccountManagerModifier<TelegramAccountManagerTypes>, id: AccountRecordId,
    testingEnvironment: Bool, isSupportUser: Bool) -> Bool {
    // An old server completion must never allocate an arbitrary record, replace
    // existing membership, or remove a newer current authorization flow.
    guard let auth = transaction.getCurrentAuth(), auth.id == id,
          !transaction.getRecords().contains(where: { $0.id == id }) else { return false }
    let environments = auth.attributes.compactMap { attribute -> Bool? in
        guard case let .environment(value) = attribute else { return nil }
        switch value.environment {
        case .production: return false
        case .test: return true
        }
    }
    // Older records without the attribute use upstream's production default.
    // Duplicate environment attributes are ambiguous and grant no promotion.
    guard environments.count <= 1, (environments.first ?? false) == testingEnvironment else { return false }
    let nextSortOrder = (transaction.getRecords().map({ record -> Int32 in
        for attribute in record.attributes {
            if case let .sortOrder(sortOrder) = attribute {
                return sortOrder.order
            }
        }
        return 0
    }).max() ?? 0) + 1
    transaction.updateRecord(id, { _ in
        var attributes: [TelegramAccountManagerTypes.Attribute] = [
            .environment(AccountEnvironmentAttribute(environment: testingEnvironment ? .test : .production)),
            .sortOrder(AccountSortOrderAttribute(order: nextSortOrder))
        ]
        if isSupportUser {
            attributes.append(.supportUserInfo(AccountSupportUserInfo()))
        }
        return AccountRecord(id: id, attributes: attributes, temporarySessionId: nil)
    })
    transaction.setCurrentId(id)
    transaction.removeAuth()
    return true
}
