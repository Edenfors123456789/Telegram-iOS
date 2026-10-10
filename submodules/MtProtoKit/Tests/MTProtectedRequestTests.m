#import <XCTest/XCTest.h>

#import <MtProtoKit/MTRequest.h>
#import <MtProtoKit/MTRequestContext.h>
#import <MtProtoKit/MTRequestMessageService.h>
#import <MtProtoKit/MTMessageTransaction.h>
#import <MtProtoKit/MTOutgoingMessage.h>
#import <MtProtoKit/MTSessionInfo.h>
#import <MtProtoKit/MTEncryption.h>
#import <MtProtoKit/MTBindKeyMessageService.h>
#import <MtProtoKit/MTTransport.h>
#import <MtProtoKit/MTTcpTransport.h>
#import <objc/message.h>

#import "MTTestSupport.h"

@protocol MTProtectedPrivateAuthInfo
- (instancetype)initWithAuthInfo:(MTDatacenterAuthInfo *)authInfo selector:(MTDatacenterAuthInfoSelector)selector;
@end

@interface MTProto (MTProtectedRequestTests)
- (void)transportReadyForTransaction:(MTTransport *)transport scheme:(MTTransportScheme *)scheme transportSpecificTransaction:(MTMessageTransaction *)transaction forceConfirmations:(bool)forceConfirmations transactionReady:(void (^)(NSArray *))ready;
@end

static NSData *scopeKey(uint8_t value, NSUInteger length) {
    NSMutableData *data = [NSMutableData dataWithLength:length];
    memset(data.mutableBytes, value, length);
    return data;
}

// Independent SHA-256 vector for 256 bytes of 0x51, rather than deriving the
// expected permanent binding through the implementation under test.
static NSData *scopeDigest(void) {
    uint8_t bytes[] = {0x98,0xbd,0x3b,0x0a,0xa6,0x2e,0x65,0x42,0xed,0x6a,0xcd,0x8d,0x29,0x7e,0xf2,0xe5,0xf7,0x1f,0x19,0x1b,0x45,0x8d,0xcb,0x11,0x0a,0x82,0xd1,0xbf,0x47,0x2e,0x6f,0xd0};
    return [NSData dataWithBytes:bytes length:sizeof(bytes)];
}

static MTDatacenterAuthInfo *scopeAuth(uint8_t value, int32_t lifetime, NSDictionary *attributes) {
    return [[MTDatacenterAuthInfo alloc] initWithAuthKey:scopeKey(value, 256) authKeyId:value validUntilTimestamp:lifetime saltSet:@[] authKeyAttributes:attributes];
}

static NSDictionary *scopeTempAttributes(NSData *permanent, NSData *temporary, int32_t dc) {
    return @{@"boundPermanentAuthKeySHA256":permanent, @"boundTemporaryAuthKeySHA256":temporary, @"boundAuthKeyDatacenterId":@(dc)};
}

@interface MTDatacenterAuthAction (MTProtectedRequestTests)
- (void)bindAuthKey:(MTDatacenterAuthKey *)authKey persistentAuthInfo:(MTDatacenterAuthInfo *)persistentAuthInfo timestamp:(int64_t)timestamp serverSalt:(int64_t)serverSalt connection:(id)connection;
- (void)completeWithAuthKey:(MTDatacenterAuthKey *)authKey timestamp:(int64_t)timestamp serverSalt:(int64_t)serverSalt;
@end

@interface MTBindKeyMessageService (MTProtectedRequestTests)
- (void)finishWithSuccess:(bool)success error:(MTRpcError *)error;
@end

@interface MTProtectedPreparationProto : MTProto
@end
@implementation MTProtectedPreparationProto
- (bool)canAskForTransactions { return true; }
@end

@interface MTSelectedKeyObserver : NSObject <MTMessageService>
@property (nonatomic, strong) MTDatacenterAuthInfo *observed;
@property (nonatomic) NSInteger oldSelectorCalls;
@end
@implementation MTSelectedKeyObserver
- (MTMessageTransaction *)mtProtoMessageTransaction:(MTProto *)__unused proto authInfoSelector:(MTDatacenterAuthInfoSelector)__unused selector selectedAuthInfo:(MTDatacenterAuthInfo *)selected sessionInfo:(MTSessionInfo *)__unused session scheme:(MTTransportScheme *)__unused scheme {
    self.observed = selected;
    return nil;
}
- (MTMessageTransaction *)mtProtoMessageTransaction:(MTProto *)__unused proto authInfoSelector:(MTDatacenterAuthInfoSelector)__unused selector sessionInfo:(MTSessionInfo *)__unused session scheme:(MTTransportScheme *)__unused scheme {
    self.oldSelectorCalls += 1;
    return nil;
}
@end

@interface MTProtectedRequestTests : XCTestCase
@end

@implementation MTProtectedRequestTests {
    MTContext *_context;
    MTProto *_proto;
    MTRequestMessageService *_service;
    MTSessionInfo *_session;
    NSMutableArray<MTRpcError *> *_errors;
}

- (void)setUp {
    [super setUp];
    _context = MTTestMakeContext(false);
    _proto = [[MTProto alloc] initWithContext:_context datacenterId:2 usageCalculationInfo:nil requiredAuthToken:nil authTokenMasterDatacenterId:0];
    _service = [[MTRequestMessageService alloc] initWithContext:_context];
    _session = [[MTSessionInfo alloc] initWithRandomSessionIdAndContext:_context];
    _errors = [[NSMutableArray alloc] init];
    MTTestOnManagerQueue(^{
        [self->_service mtProtoWillAddService:self->_proto];
        [self->_service mtProtoDidAddService:self->_proto];
        self->_service.apiEnvironment = nil;
    });
}

- (void)tearDown {
    [_proto stop];
    MTTestOnManagerQueue(^{});
    _service = nil;
    _proto = nil;
    [super tearDown];
}

- (MTRequest *)addWithScope:(MTRequestAuthKeyScope *)scope {
    MTRequest *request = [[MTRequest alloc] initWithAuthKeyScope:scope];
    [request setPayload:[NSData dataWithBytes:"TEST" length:4] metadata:@"offline protected test" shortMetadata:@"offline" responseParser:^id(__unused NSData *data) { return @YES; }];
    request.dependsOnPasswordEntry = false;
    NSMutableArray *errors = _errors;
    request.completed = ^(__unused id result, __unused MTRequestResponseInfo *info, MTRpcError *error) {
        if (error != nil) { [errors addObject:error]; }
    };
    [_service addRequest:request];
    MTTestOnManagerQueue(^{});
    return request;
}

- (MTRequestAuthKeyScope *)originalScope {
    return [[MTRequestAuthKeyScope alloc] initWithDatacenterId:2 permanentKeyDigest:scopeDigest()];
}

- (MTMessageTransaction *)prepare:(MTDatacenterAuthInfo *)selected selector:(MTDatacenterAuthInfoSelector)selector {
    __block MTMessageTransaction *transaction = nil;
    MTTestOnManagerQueue(^{
        transaction = [self->_service mtProtoMessageTransaction:self->_proto authInfoSelector:selector selectedAuthInfo:selected sessionInfo:self->_session scheme:nil];
    });
    MTTestOnManagerQueue(^{});
    return transaction;
}

- (void)assertDenied:(MTDatacenterAuthInfo *)selected selector:(MTDatacenterAuthInfoSelector)selector {
    NSUInteger previousErrors = _errors.count;
    XCTAssertNil([self prepare:selected selector:selector], @"No protected payload may be prepared");
    XCTAssertEqual(_errors.count, previousErrors + 1);
    XCTAssertEqual(_errors.lastObject.errorCode, 403);
    XCTAssertEqualObjects(_errors.lastObject.errorDescription, @"AUTHORIZATION_SCOPE_CHANGED");
    XCTAssertNil([self prepare:selected selector:selector]);
    XCTAssertEqual(_errors.count, previousErrors + 1, @"Completion is single-use");
}

- (void)testPermanentOriginalPreparesItsPayload {
    [self addWithScope:[self originalScope]];
    MTMessageTransaction *transaction = [self prepare:scopeAuth(0x51, INT32_MAX, nil) selector:MTDatacenterAuthInfoSelectorPersistent];
    XCTAssertEqual(transaction.messagePayload.count, 1u);
    XCTAssertEqualObjects(((MTOutgoingMessage *)transaction.messagePayload.firstObject).data, [NSData dataWithBytes:"TEST" length:4]);
    XCTAssertEqual(_errors.count, 0u);
}

- (void)testChangedPermanentKeyCannotUseMatchingContextSnapshot {
    [_context updateAuthInfoForDatacenterWithId:2 authInfo:scopeAuth(0x51, INT32_MAX, nil) selector:MTDatacenterAuthInfoSelectorPersistent];
    [self addWithScope:[self originalScope]];
    [self assertDenied:scopeAuth(0x52, INT32_MAX, nil) selector:MTDatacenterAuthInfoSelectorPersistent];
}

- (void)testMissingAndMalformedActualKeysDeny {
    for (MTDatacenterAuthInfo *auth in @[[NSNull null], [[MTDatacenterAuthInfo alloc] initWithAuthKey:scopeKey(0x51, 255) authKeyId:1 validUntilTimestamp:INT32_MAX saltSet:@[] authKeyAttributes:nil], scopeAuth(0x51, 1800000000, nil)]) {
        [self addWithScope:[self originalScope]];
        [self assertDenied:(id)auth == [NSNull null] ? nil : auth selector:MTDatacenterAuthInfoSelectorPersistent];
    }
}

- (void)testMalformedScopeAndWrongDatacenterNeverDowngrade {
    for (MTRequestAuthKeyScope *scope in @[
        [[MTRequestAuthKeyScope alloc] initWithDatacenterId:3 permanentKeyDigest:scopeDigest()],
        [[MTRequestAuthKeyScope alloc] initWithDatacenterId:0 permanentKeyDigest:scopeDigest()],
        [[MTRequestAuthKeyScope alloc] initWithDatacenterId:2 permanentKeyDigest:scopeKey(1, 31)],
        [[MTRequestAuthKeyScope alloc] initWithDatacenterId:2 permanentKeyDigest:nil]]) {
        [self addWithScope:scope];
        [self assertDenied:scopeAuth(0x51, INT32_MAX, nil) selector:MTDatacenterAuthInfoSelectorPersistent];
    }
}

- (void)testTemporaryKeyNeedsItsOwnSuccessfulOriginalBinding {
    NSData *tempDigest = MTSha256(scopeKey(0x61, 256));
    NSArray *badAttributes = @[[NSNull null], scopeTempAttributes(scopeKey(1, 32), tempDigest, 2), scopeTempAttributes(scopeDigest(), scopeKey(1, 32), 2), scopeTempAttributes(scopeDigest(), tempDigest, 3), @{@"boundPermanentAuthKeySHA256":scopeDigest()}];
    for (NSDictionary *attrs in badAttributes) {
        [self addWithScope:[self originalScope]];
        [self assertDenied:scopeAuth(0x61, 1800000000, (id)attrs == [NSNull null] ? nil : attrs) selector:MTDatacenterAuthInfoSelectorEphemeralMain];
    }
}

- (void)testCorrectTemporaryMainAndMediaKeysPrepare {
    for (NSNumber *selector in @[@(MTDatacenterAuthInfoSelectorEphemeralMain), @(MTDatacenterAuthInfoSelectorEphemeralMedia)]) {
        MTRequest *request = [self addWithScope:[self originalScope]];
        MTDatacenterAuthInfo *temp = scopeAuth(0x61, 1800000000, scopeTempAttributes(scopeDigest(), MTSha256(scopeKey(0x61, 256)), 2));
        XCTAssertEqual([self prepare:temp selector:selector.longLongValue].messagePayload.count, 1u);
        [_service removeRequestByInternalId:request.internalId];
        MTTestOnManagerQueue(^{});
    }
    XCTAssertEqual(_errors.count, 0u);
}

- (void)testCorruptBindingAndUnknownSelectorsDeny {
    for (NSDictionary *attributes in @[
        @{MTBoundPermanentAuthKeyDigestAttribute:@"invalid", MTBoundTemporaryAuthKeyDigestAttribute:MTSha256(scopeKey(0x61, 256)), MTBoundAuthKeyDatacenterAttribute:@2},
        @{MTBoundPermanentAuthKeyDigestAttribute:scopeDigest(), MTBoundTemporaryAuthKeyDigestAttribute:@"invalid", MTBoundAuthKeyDatacenterAttribute:@2},
        @{MTBoundPermanentAuthKeyDigestAttribute:scopeDigest(), MTBoundTemporaryAuthKeyDigestAttribute:MTSha256(scopeKey(0x61, 256)), MTBoundAuthKeyDatacenterAttribute:@2.5}]) {
        [self addWithScope:[self originalScope]];
        [self assertDenied:scopeAuth(0x61, 1800000000, attributes) selector:MTDatacenterAuthInfoSelectorEphemeralMedia];
    }
    [self addWithScope:[self originalScope]];
    [self assertDenied:scopeAuth(0x51, INT32_MAX, nil) selector:(MTDatacenterAuthInfoSelector)999];
    [self addWithScope:[self originalScope]];
    [self assertDenied:scopeAuth(0x61, INT32_MAX, scopeTempAttributes(scopeDigest(), MTSha256(scopeKey(0x61, 256)), 2)) selector:MTDatacenterAuthInfoSelectorEphemeralMain];
}

- (void)testForeignTemporaryKeyOnRetryCannotReuseEarlierAdmission {
    MTRequest *request = [self addWithScope:[self originalScope]];
    MTDatacenterAuthInfo *original = scopeAuth(0x61, 1800000000, scopeTempAttributes(scopeDigest(), MTSha256(scopeKey(0x61, 256)), 2));
    XCTAssertEqual([self prepare:original selector:MTDatacenterAuthInfoSelectorEphemeralMain].messagePayload.count, 1u);
    MTTestOnManagerQueue(^{ request.requestContext = [[MTRequestContext alloc] initWithMessageId:100 messageSeqNo:1 transactionId:nil quickAckId:0]; });
    MTDatacenterAuthInfo *replacement = scopeAuth(0x62, 1800000000, scopeTempAttributes(scopeKey(1, 32), MTSha256(scopeKey(0x62, 256)), 2));
    [self assertDenied:replacement selector:MTDatacenterAuthInfoSelectorEphemeralMain];
}

- (void)testLegacySelectorCannotInferSelectedKeyFromContext {
    [_context updateAuthInfoForDatacenterWithId:2 authInfo:scopeAuth(0x51, INT32_MAX, nil) selector:MTDatacenterAuthInfoSelectorPersistent];
    [self addWithScope:[self originalScope]];
    __block MTMessageTransaction *transaction;
    MTTestOnManagerQueue(^{ transaction = [self->_service mtProtoMessageTransaction:self->_proto authInfoSelector:MTDatacenterAuthInfoSelectorPersistent sessionInfo:self->_session scheme:nil]; });
    MTTestOnManagerQueue(^{});
    XCTAssertNil(transaction);
    XCTAssertEqual(_errors.count, 1u);
}

- (void)testOrdinaryPayloadSurvivesProtectedRejectionAndReentrantCompletion {
    MTRequest *rejected = [self addWithScope:[self originalScope]];
    [self addWithScope:nil];
    rejected.completed = ^(__unused id result, __unused MTRequestResponseInfo *info, __unused MTRpcError *error) { [self addWithScope:nil]; };
    XCTAssertEqual([self prepare:scopeAuth(0x52, INT32_MAX, nil) selector:MTDatacenterAuthInfoSelectorPersistent].messagePayload.count, 1u);
    XCTAssertEqual([self prepare:nil selector:MTDatacenterAuthInfoSelectorPersistent].messagePayload.count, 2u);
}

- (void)testScopeCopiesMutableDigest {
    NSMutableData *digest = [scopeDigest() mutableCopy];
    MTRequestAuthKeyScope *scope = [[MTRequestAuthKeyScope alloc] initWithDatacenterId:2 permanentKeyDigest:digest];
    memset(digest.mutableBytes, 0, digest.length);
    [self addWithScope:scope];
    XCTAssertEqual([self prepare:scopeAuth(0x51, INT32_MAX, nil) selector:MTDatacenterAuthInfoSelectorPersistent].messagePayload.count, 1u);
}

- (void)testSuccessfulBindRecordsCapturedOriginalNotAReplacementSnapshot {
    MTContext *context = MTTestMakeContext(true);
    MTTestSetAddress(context, 2, false);
    MTDatacenterAuthInfo *persistent = scopeAuth(0x51, INT32_MAX, nil);
    MTDatacenterAuthKey *temporary = [[MTDatacenterAuthKey alloc] initWithAuthKey:scopeKey(0x61, 256) authKeyId:7 validUntilTimestamp:1800000000 notBound:true];
    MTDatacenterAuthAction *action = [[MTDatacenterAuthAction alloc] initWithAuthKeyInfoSelector:MTDatacenterAuthInfoSelectorEphemeralMain isCdn:false skipBind:false completion:nil];
    MTTestOnManagerQueue(^{
        [action setValue:context forKey:@"_context"];
        [action setValue:@2 forKey:@"_datacenterId"];
        [action bindAuthKey:temporary persistentAuthInfo:persistent timestamp:100 serverSalt:0 connection:nil];
        MTProto *bindProto = [action valueForKey:@"_bindMtProto"];
        MTBindKeyMessageService *bind = [[bindProto valueForKey:@"_messageServices"] firstObject];
        XCTAssertTrue([bind isKindOfClass:[MTBindKeyMessageService class]]);
        [context updateAuthInfoForDatacenterWithId:2 authInfo:scopeAuth(0x52, INT32_MAX, nil) selector:MTDatacenterAuthInfoSelectorPersistent];
        [bind finishWithSuccess:true error:nil];
    });
    MTDatacenterAuthInfo *recorded = [context authInfoForDatacenterWithId:2 selector:MTDatacenterAuthInfoSelectorEphemeralMain];
    XCTAssertEqualObjects(recorded.authKeyAttributes[MTBoundPermanentAuthKeyDigestAttribute], scopeDigest());
    XCTAssertEqualObjects(recorded.authKeyAttributes[MTBoundTemporaryAuthKeyDigestAttribute], MTSha256(temporary.authKey));
    XCTAssertEqualObjects(recorded.authKeyAttributes[MTBoundAuthKeyDatacenterAttribute], @2);
    NSError *archiveError = nil;
    NSData *archive = [NSKeyedArchiver archivedDataWithRootObject:recorded requiringSecureCoding:false error:&archiveError];
    XCTAssertNil(archiveError);
    NSKeyedUnarchiver *reader = [[NSKeyedUnarchiver alloc] initForReadingFromData:archive error:&archiveError];
    reader.requiresSecureCoding = false;
    MTDatacenterAuthInfo *reopened = [reader decodeObjectForKey:NSKeyedArchiveRootObjectKey];
    [reader finishDecoding];
    XCTAssertNil(archiveError);
    XCTAssertEqualObjects(reopened.authKeyAttributes, recorded.authKeyAttributes);
}

- (void)testFailedBindAndSkipBindCannotRecordProvenance {
    MTContext *context = MTTestMakeContext(true);
    MTTestSetAddress(context, 2, false);
    MTDatacenterAuthKey *temporary = [[MTDatacenterAuthKey alloc] initWithAuthKey:scopeKey(0x61, 256) authKeyId:7 validUntilTimestamp:1800000000 notBound:true];
    MTDatacenterAuthAction *failed = [[MTDatacenterAuthAction alloc] initWithAuthKeyInfoSelector:MTDatacenterAuthInfoSelectorEphemeralMain isCdn:false skipBind:false completion:nil];
    MTDatacenterAuthAction *skipped = [[MTDatacenterAuthAction alloc] initWithAuthKeyInfoSelector:MTDatacenterAuthInfoSelectorEphemeralMain isCdn:false skipBind:true completion:nil];
    MTTestOnManagerQueue(^{
        [failed setValue:context forKey:@"_context"]; [failed setValue:@2 forKey:@"_datacenterId"];
        [failed bindAuthKey:temporary persistentAuthInfo:scopeAuth(0x51, INT32_MAX, nil) timestamp:100 serverSalt:0 connection:nil];
        MTBindKeyMessageService *bind = [[[failed valueForKey:@"_bindMtProto"] valueForKey:@"_messageServices"] firstObject];
        [bind finishWithSuccess:false error:[[MTRpcError alloc] initWithErrorCode:400 errorDescription:@"TEMP_AUTH_KEY_EMPTY"]];
        [skipped setValue:context forKey:@"_context"]; [skipped setValue:@2 forKey:@"_datacenterId"];
        XCTAssertNil([context authInfoForDatacenterWithId:2 selector:MTDatacenterAuthInfoSelectorEphemeralMain]);
        [skipped completeWithAuthKey:temporary timestamp:100 serverSalt:0];
    });
    MTDatacenterAuthInfo *unbound = [context authInfoForDatacenterWithId:2 selector:MTDatacenterAuthInfoSelectorEphemeralMain];
    XCTAssertNotNil(unbound);
    XCTAssertNil(unbound.authKeyAttributes[MTBoundPermanentAuthKeyDigestAttribute]);
    [self addWithScope:[self originalScope]];
    [self assertDenied:unbound selector:MTDatacenterAuthInfoSelectorEphemeralMain];
}

- (void)testMTProtoForwardsItsCachedSelectedInfoRatherThanContext {
    MTProtectedPreparationProto *proto = [[MTProtectedPreparationProto alloc] initWithContext:_context datacenterId:2 usageCalculationInfo:nil requiredAuthToken:nil authTokenMasterDatacenterId:0];
    MTSelectedKeyObserver *observer = [[MTSelectedKeyObserver alloc] init];
    MTDatacenterAuthInfo *cached = scopeAuth(0x51, INT32_MAX, nil);
    [_context updateAuthInfoForDatacenterWithId:2 authInfo:scopeAuth(0x52, INT32_MAX, nil) selector:MTDatacenterAuthInfoSelectorPersistent];
    MTTransportScheme *scheme = [[MTTransportScheme alloc] initWithTransportClass:[MTTcpTransport class] address:MTTestMakeAddress(false) media:false];
    MTTransport *transport = [[MTTransport alloc] initWithDelegate:nil context:_context datacenterId:2 schemes:@[scheme] proxySettings:nil usageCalculationInfo:nil getLogPrefix:nil];
    [proto addMessageService:observer];
    MTTestOnManagerQueue(^{
        id validAuthInfo = ((id (*)(id, SEL, id, MTDatacenterAuthInfoSelector))objc_msgSend)([NSClassFromString(@"MTProtoValidAuthInfo") alloc], @selector(initWithAuthInfo:selector:), cached, MTDatacenterAuthInfoSelectorPersistent);
        [proto setValue:validAuthInfo forKey:@"_validAuthInfo"];
        [proto setValue:transport forKey:@"_transport"];
        [proto transportReadyForTransaction:transport scheme:scheme transportSpecificTransaction:nil forceConfirmations:false transactionReady:nil];
    });
    MTTestOnManagerQueue(^{});
    XCTAssertEqual(observer.observed, cached);
    XCTAssertEqual(observer.oldSelectorCalls, 0);
    [proto stop];
}

@end
