import Testing
import SwiftServeCapability
@testable import SwiftServeSurface

@Suite("ObjC header extraction")
struct ObjCHeaderParserTests {

    // MARK: - shapes

    @Test func interfaceMethodsAndProperties() {
        let header = """
        NS_ASSUME_NONNULL_BEGIN
        /// The manager that coordinates downloads.
        @interface SDWebImageManager : NSObject

        @property (nonatomic, strong, readonly, nullable) SDImageCache *imageCache;

        - (nullable id <SDWebImageOperation>)loadImageWithURL:(nullable NSURL *)url
                                                      options:(SDWebImageOptions)options
                                                     progress:(nullable SDImageLoaderProgressBlock)progressBlock
                                                    completed:(nonnull SDInternalCompletionBlock)completedBlock;

        + (nonnull instancetype)sharedManager;

        - (void)cancelAll;

        @end
        NS_ASSUME_NONNULL_END
        """
        let decls = ObjCHeaderParser.decls(in: header, file: "SDWebImage/SDWebImageManager.h")
        let names = decls.map(\.name)
        #expect(names.contains("SDWebImageManager"))
        #expect(names.contains("SDWebImageManager.imageCache"))
        #expect(names.contains("SDWebImageManager.loadImageWithURL:options:progress:completed:"))
        #expect(names.contains("SDWebImageManager.sharedManager"))
        #expect(names.contains("SDWebImageManager.cancelAll"))
        #expect(decls.first { $0.name == "SDWebImageManager" }?.kind == .class)
        #expect(decls.first { $0.name == "SDWebImageManager" }?.docSummary == "The manager that coordinates downloads.")
        #expect(decls.first { $0.name == "SDWebImageManager.imageCache" }?.kind == .property)
        #expect(decls.first { $0.name == "SDWebImageManager.cancelAll" }?.kind == .function)
    }

    @Test func protocolAndForwardDeclarations() {
        let header = """
        @protocol SDWebImageOperation;
        @class SDWebImageDownloader;

        @protocol SDImageLoader <NSObject>
        - (BOOL)canRequestImageForURL:(nullable NSURL *)url;
        @end
        """
        let decls = ObjCHeaderParser.decls(in: header, file: "L.h")
        #expect(decls.map(\.name) == ["SDImageLoader", "SDImageLoader.canRequestImageForURL:"])
        #expect(decls[0].kind == .protocol)
    }

    @Test func categoryMembersQualifyUnderBaseType() {
        let header = """
        @interface UIImageView (WebCache)
        - (void)sd_setImageWithURL:(nullable NSURL *)url;
        @end
        """
        let decls = ObjCHeaderParser.decls(in: header, file: "C.h")
        // The category emits no container decl (UIKit owns UIImageView) —
        // just the members, anchored under the base type.
        #expect(decls.map(\.name) == ["UIImageView.sd_setImageWithURL:"])
    }

    @Test func enumsAndCases() {
        let header = """
        typedef NS_ENUM(NSInteger, SDImageFormat) {
            SDImageFormatUndefined = -1,
            SDImageFormatJPEG = 0,
            SDImageFormatWebP,
        };
        """
        let decls = ObjCHeaderParser.decls(in: header, file: "F.h")
        let names = decls.map(\.name)
        #expect(names.contains("SDImageFormat"))
        #expect(names.contains("SDImageFormat.SDImageFormatWebP"))
        #expect(decls.first { $0.name == "SDImageFormat" }?.kind == .enum)
        #expect(decls.first { $0.name == "SDImageFormat.SDImageFormatWebP" }?.kind == .enumCase)
    }

    @Test func typedExtensibleEnumConstants() {
        let header = """
        typedef NSInteger SDImageFormat NS_TYPED_EXTENSIBLE_ENUM;
        static const SDImageFormat SDImageFormatUndefined = -1;
        static const SDImageFormat SDImageFormatWebP      = 4;
        """
        let decls = ObjCHeaderParser.decls(in: header, file: "N.h")
        let names = decls.map(\.name)
        #expect(names.contains("SDImageFormatWebP"))
        #expect(names.contains("SDImageFormatUndefined"))
        #expect(decls.first { $0.name == "SDImageFormatWebP" }?.kind == .enumCase)
    }

    @Test func externConstantsAndBlockProperties() {
        let header = """
        FOUNDATION_EXPORT NSString * _Nonnull const SDWebImageErrorDomain;
        @interface SDCallbackQueue : NSObject
        @property (nonatomic, copy, nullable) void (^completionBlock)(BOOL finished);
        @end
        """
        let decls = ObjCHeaderParser.decls(in: header, file: "E.h")
        #expect(decls.map(\.name).contains("SDWebImageErrorDomain"))
        #expect(decls.map(\.name).contains("SDCallbackQueue.completionBlock"))
    }

    // MARK: - conditions

    @Test func targetOSConditionsMapAndNegate() {
        let header = """
        #if TARGET_OS_IOS && !TARGET_OS_MACCATALYST
        @interface SDPhone : NSObject
        @end
        #else
        @interface SDElsewhere : NSObject
        @end
        #endif
        """
        let decls = ObjCHeaderParser.decls(in: header, file: "T.h")
        let phone = decls.first { $0.name == "SDPhone" }
        #expect(phone?.rawCondition == "os(iOS) && !targetEnvironment(macCatalyst)")
        let elsewhere = decls.first { $0.name == "SDElsewhere" }
        #expect(elsewhere?.rawCondition == "!(os(iOS) && !targetEnvironment(macCatalyst))")
    }

    @Test func packageMacrosStayOpaqueAndTargetOSMacIsNeverMacOS() {
        let header = """
        #if SD_UIKIT
        @interface SDOnUIKit : NSObject
        @end
        #endif
        #if TARGET_OS_MAC
        @interface SDOnMac : NSObject
        @end
        #endif
        """
        let decls = ObjCHeaderParser.decls(in: header, file: "M.h")
        #expect(decls.first { $0.name == "SDOnUIKit" }?.rawCondition == "SD_UIKIT")
        // TARGET_OS_MAC is 1 on every Apple platform — it must survive as an
        // opaque flag (resolver says conditional), never become os(macOS).
        #expect(decls.first { $0.name == "SDOnMac" }?.rawCondition == "TARGET_OS_MAC")
    }

    @Test func hasIncludeBecomesCanImport() {
        let header = """
        #if __has_include(<UIKit/UIKit.h>)
        @interface SDUIKitThing : NSObject
        @end
        #endif
        """
        let decls = ObjCHeaderParser.decls(in: header, file: "H.h")
        #expect(decls.first?.rawCondition == "canImport(UIKit)")
    }

    @Test func nestedConditionsConjoin() {
        let header = """
        #if TARGET_OS_IOS
        #if SD_ANIMATION
        @interface SDNested : NSObject
        @end
        #endif
        #endif
        """
        let decls = ObjCHeaderParser.decls(in: header, file: "N.h")
        #expect(decls.first?.rawCondition == "os(iOS) && SD_ANIMATION")
    }

    // MARK: - availability

    @Test func apiAvailableAndUnavailable() {
        let header = """
        API_AVAILABLE(ios(14.0), macos(11.0)) API_UNAVAILABLE(watchos)
        @interface SDModern : NSObject
        - (void)refresh API_AVAILABLE(ios(15.0));
        @end
        """
        let decls = ObjCHeaderParser.decls(in: header, file: "A.h")
        let type = decls.first { $0.name == "SDModern" }
        #expect(type?.availability.contains(AvailabilityConstraint(platform: "iOS", introduced: "14.0")) == true)
        #expect(type?.availability.contains(AvailabilityConstraint(platform: "macOS", introduced: "11.0")) == true)
        #expect(type?.availability.contains(AvailabilityConstraint(platform: "watchOS", unavailable: true)) == true)
        // Members merge the container's constraints with their own.
        let method = decls.first { $0.name == "SDModern.refresh" }
        #expect(method?.availability.contains(AvailabilityConstraint(platform: "watchOS", unavailable: true)) == true)
        #expect(method?.availability.contains(AvailabilityConstraint(platform: "iOS", introduced: "15.0")) == true)
    }

    @Test func legacyNSMacros() {
        let header = """
        NS_CLASS_AVAILABLE_IOS(8_0)
        @interface SDLegacy : NSObject
        - (void)oldWay NS_DEPRECATED_IOS(8_0, 13_0);
        - (instancetype)init NS_UNAVAILABLE;
        @end
        """
        let decls = ObjCHeaderParser.decls(in: header, file: "G.h")
        #expect(decls.first { $0.name == "SDLegacy" }?.availability
            .contains(AvailabilityConstraint(platform: "iOS", introduced: "8.0")) == true)
        let deprecated = decls.first { $0.name == "SDLegacy.oldWay" }
        #expect(deprecated?.availability.contains(
            AvailabilityConstraint(platform: "iOS", introduced: "8.0", deprecated: "13.0")) == true)
        let banned = decls.first { $0.name == "SDLegacy.init" }
        #expect(banned?.availability.contains(AvailabilityConstraint(platform: "*", unavailable: true)) == true)
    }

    @Test func availabilityMacrosNeverPolluteNames() {
        let header = """
        @interface SDNamed : NSObject
        @property (nonatomic) NSInteger retryCount API_AVAILABLE(ios(13.0));
        - (void)runWithSpeed:(CGFloat)speed NS_SWIFT_NAME(run(speed:));
        @end
        """
        let decls = ObjCHeaderParser.decls(in: header, file: "P.h")
        #expect(decls.map(\.name).contains("SDNamed.retryCount"))
        #expect(decls.map(\.name).contains("SDNamed.runWithSpeed:"))
    }

    // MARK: - resolver integration

    @Test func resolverTreatsMappedConditionsLikeSwiftOnes() {
        let header = """
        #if TARGET_OS_WATCH
        @interface SDWatchOnly : NSObject
        @end
        #endif
        """
        let decl = ObjCHeaderParser.decls(in: header, file: "W.h")[0]
        let resolved = decl.resolving(PlatformResolver.resolve(
            condition: decl.condition, availability: decl.availability,
            modules: ModulePlatformTable(version: 1, modules: [:])))
        #expect(resolved.resolvedPlatforms?["watchOS"] == PlatformPresence.present)
        #expect(resolved.resolvedPlatforms?["iOS"] == PlatformPresence.absent)
        #expect(resolved.resolvedPlatforms?["linux"] == PlatformPresence.absent)
    }
}
